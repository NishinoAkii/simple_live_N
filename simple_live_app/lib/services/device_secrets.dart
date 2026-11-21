import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 设置里加密保存的项：所有账号类设置（各平台的 Cookie、令牌、别的账号、GitHub 令牌……，
/// 见 [LocalStorageService.isAccountKey]）和 WebDAV 密码。
/// [LocalStorageService.getValue]、[LocalStorageService.setValue] 自动解密、加密。
///
/// 存的是 `sec1:` 加 AES-256-GCM 的密文（随机 12 字节 nonce + 密文 + 标签，Base64），
/// 不存明文。密钥是每台设备自己的 32 字节随机数，放在设置文件旁边的 `device.key`：
/// Windows 上用 DPAPI（CryptProtectData，绑定当前 Windows 账号）加密后再存，
/// 别的账号、拷走文件到别的电脑都解不开；其他系统放在 App 自己的数据目录里。
///
/// 同步到别的设备时（WebDAV 存档、导出配置），这些项先解开，再和别的账号一起用
/// [SyncVault] 加密（密钥由 WebDAV 账号密码算出）；那台设备收到后用它自己的密钥
/// 重新加密再写进设置（[protectSettings]）。任何时候都不以明文写进文件
class DeviceSecrets {
  DeviceSecrets._();

  static final DeviceSecrets instance = DeviceSecrets._();

  static const String prefix = "sec1:";

  /// 这一项要不要加密保存
  static bool isSecretKey(String key) =>
      LocalStorageService.isAccountKey(key) ||
      key == LocalStorageService.kWebDAVPassword;

  /// 这个值要加密：要加密的项、非空字符串、还不是密文
  static bool needsProtect(String key, Object? value) =>
      isSecretKey(key) &&
      value is String &&
      value.isNotEmpty &&
      !isProtected(value);

  static const String _keyFile = "device.key";
  static const String _dpapiTag = "dpapi1:";
  static const String _rawTag = "raw1:";

  /// DPAPI 的附加熵：别的程序不知道它就解不开（同一个 Windows 账号也不行）
  static final Uint8List _entropy =
      Uint8List.fromList(utf8.encode("SimpleLive device secrets v1"));

  Uint8List? _key;
  bool _initialized = false;

  /// 测试用：直接给一个密钥，不读写文件
  void useKeyForTest(Uint8List? key) {
    _key = key;
    _initialized = true;
  }

  /// 单元测试里没调用 [init] 时用一把临时密钥，测试照常读写设置
  Uint8List? get _activeKey {
    if (_key == null &&
        !_initialized &&
        Platform.environment.containsKey("FLUTTER_TEST")) {
      _key = _random(32);
    }
    return _key;
  }

  bool get ready => _activeKey != null;

  /// 读出（没有就生成）这台设备的密钥。[migrate] 为 true 时把设置里还是明文的项加密
  /// （从旧版本升级上来时）。只在主进程迁移，多开的副窗口只读
  Future<void> init({bool migrate = true}) async {
    String dir;
    try {
      dir = (await getApplicationSupportDirectory()).path;
    } catch (e) {
      Log.e("设备密钥读取失败：$e", StackTrace.current);
      _key = null;
      return;
    }
    await initAt(dir, migrate: migrate);
  }

  /// 密钥文件放在 [dir] 里（测试时用临时目录）
  Future<void> initAt(String dir, {bool migrate = false}) async {
    _initialized = true;
    try {
      _key = await _loadOrCreate(File("$dir${Platform.pathSeparator}$_keyFile"));
    } catch (e) {
      Log.e("设备密钥读取失败：$e", StackTrace.current);
      _key = null;
    }
    if (migrate && _key != null) {
      await _migrate();
    }
  }

  Future<Uint8List> _loadOrCreate(File file) async {
    if (await file.exists()) {
      var text = (await file.readAsString()).trim();
      if (text.startsWith(_dpapiTag)) {
        var key = _Dpapi.unprotect(base64.decode(text.substring(_dpapiTag.length)));
        if (key != null && key.length == 32) return key;
        throw StateError("DPAPI unprotect failed");
      }
      if (text.startsWith(_rawTag)) {
        var key = base64.decode(text.substring(_rawTag.length));
        if (key.length == 32) return Uint8List.fromList(key);
      }
      throw const FormatException("device.key");
    }
    var key = _random(32);
    String text;
    if (Platform.isWindows) {
      var blob = _Dpapi.protect(key);
      if (blob == null) throw StateError("DPAPI protect failed");
      text = "$_dpapiTag${base64.encode(blob)}";
    } else {
      text = "$_rawTag${base64.encode(key)}";
    }
    await file.parent.create(recursive: true);
    // 先写临时文件再改名，写到一半不会留下坏的密钥
    var temp = File("${file.path}.tmp");
    await temp.writeAsString(text, flush: true);
    await temp.rename(file.path);
    if (Platform.isLinux || Platform.isMacOS) {
      try {
        await Process.run("chmod", ["600", file.path]);
      } catch (_) {}
    }
    return key;
  }

  static Uint8List _random(int length) {
    var random = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
  }

  static bool isProtected(Object? value) =>
      value is String && value.startsWith(prefix);

  /// 加密。密钥不可用时抛 [StateError]（这时不能保存）
  String protect(String plain) {
    var key = _activeKey;
    if (key == null) throw StateError("device key unavailable");
    var nonce = _random(12);
    var cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, nonce, _aad));
    var data = cipher.process(Uint8List.fromList(utf8.encode(plain)));
    return "$prefix${base64.encode([...nonce, ...data])}";
  }

  /// 解密。旧版本存的明文原样返回；密文解不开（密钥没了、内容被改过）返回 null
  String? reveal(Object? stored) {
    if (stored is! String) return null;
    if (!stored.startsWith(prefix)) return stored;
    var key = _activeKey;
    if (key == null) return null;
    try {
      var bytes = base64.decode(stored.substring(prefix.length));
      if (bytes.length < 12 + 16) return null;
      var cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(KeyParameter(key), 128, bytes.sublist(0, 12), _aad),
        );
      return utf8.decode(cipher.process(Uint8List.fromList(bytes.sublist(12))));
    } catch (_) {
      return null;
    }
  }

  static final Uint8List _aad =
      Uint8List.fromList(utf8.encode("SimpleLive-device-secret-v1"));

  /// 要写进设置前调用：要加密的项里还是明文的值加密（同步、导入配置、原版收到的是明文）。
  /// 密钥不可用时去掉这些项，宁可没登录也不存明文
  Map<String, dynamic> protectSettings(Map<String, dynamic> settings) {
    var result = Map<String, dynamic>.of(settings);
    var usable = ready;
    for (var entry in settings.entries) {
      if (!needsProtect(entry.key, entry.value)) continue;
      if (usable) {
        result[entry.key] = protect(entry.value as String);
      } else {
        result.remove(entry.key);
      }
    }
    return result;
  }

  /// 读出整份设置时调用（同步、导出、合并）：密文解开成明文，解不开的去掉。
  /// 之后账号会用 SyncVault 加密，不会以明文写进文件
  Map<String, dynamic> revealSettings(Map settings) {
    var result = <String, dynamic>{};
    settings.forEach((key, value) {
      var name = key.toString();
      if (isProtected(value)) {
        var plain = reveal(value);
        if (plain != null && plain.isNotEmpty) result[name] = plain;
      } else {
        result[name] = value;
      }
    });
    return result;
  }

  Future<void> _migrate() async {
    try {
      var box = LocalStorageService.instance.settingsBox;
      var count = 0;
      for (var key in box.keys.toList()) {
        var value = box.get(key);
        if (needsProtect(key.toString(), value)) {
          await box.put(key, protect(value as String));
          count++;
        }
      }
      if (count > 0) {
        Log.i("已把 $count 项账号、令牌改为加密保存");
      }
    } catch (e) {
      Log.e("加密旧设置失败：$e", StackTrace.current);
    }
  }
}

/// Windows 的 DPAPI（crypt32.dll），只用 dart:ffi
final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptNative = Int32 Function(
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_DataBlob>,
);
typedef _CryptDart = int Function(
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_DataBlob>,
);

class _Dpapi {
  static const int _uiForbidden = 0x1;
  static final DynamicLibrary _kernel32 = DynamicLibrary.open("kernel32.dll");
  static final DynamicLibrary _crypt32 = DynamicLibrary.open("crypt32.dll");
  static final Pointer<Void> Function(int, int) _localAlloc = _kernel32
      .lookupFunction<Pointer<Void> Function(Uint32, IntPtr),
          Pointer<Void> Function(int, int)>("LocalAlloc");
  static final Pointer<Void> Function(Pointer<Void>) _localFree = _kernel32
      .lookupFunction<Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)>("LocalFree");
  static final _CryptDart _protect =
      _crypt32.lookupFunction<_CryptNative, _CryptDart>("CryptProtectData");
  static final _CryptDart _unprotect =
      _crypt32.lookupFunction<_CryptNative, _CryptDart>("CryptUnprotectData");

  static Uint8List? protect(Uint8List data) => _run(_protect, data, true);

  static Uint8List? unprotect(Uint8List data) => _run(_unprotect, data, false);

  static Pointer<_DataBlob> _blob(Uint8List bytes, List<Pointer<Void>> owned) {
    var blob = _localAlloc(0x40, sizeOf<_DataBlob>()).cast<_DataBlob>();
    owned.add(blob.cast());
    var data = _localAlloc(0x40, max(bytes.length, 1)).cast<Uint8>();
    owned.add(data.cast());
    data.asTypedList(bytes.length).setAll(0, bytes);
    blob.ref
      ..cbData = bytes.length
      ..pbData = data;
    return blob;
  }

  static Uint8List? _run(_CryptDart fn, Uint8List data, bool protect) {
    var owned = <Pointer<Void>>[];
    try {
      var input = _blob(data, owned);
      var entropy = _blob(DeviceSecrets._entropy, owned);
      var output = _localAlloc(0x40, sizeOf<_DataBlob>()).cast<_DataBlob>();
      owned.add(output.cast());
      var ok = fn(input, nullptr, entropy, nullptr, nullptr, _uiForbidden, output);
      if (ok == 0) return null;
      var result =
          Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
      _localFree(output.ref.pbData.cast());
      return result;
    } catch (e) {
      Log.logPrint("DPAPI ${protect ? "protect" : "unprotect"}: $e");
      return null;
    } finally {
      for (var p in owned) {
        _localFree(p);
      }
    }
  }
}
