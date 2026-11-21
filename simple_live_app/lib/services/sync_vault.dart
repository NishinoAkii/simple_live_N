import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';
import 'package:simple_live_app/services/device_secrets.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_backup_format.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 加密账号用的密钥，由 WebDAV 账号和密码算出
class SyncVaultKey {
  final Uint8List salt;
  final int iterations;
  final Uint8List bytes;
  const SyncVaultKey(this.salt, this.iterations, this.bytes);
}

/// 同步存档和导出的配置文件里的账号。
///
/// 账号类设置（各平台的 Cookie、令牌、登录名，见 [LocalStorageService.isAccountKey]）
/// 不写明文，加密后放进 [extraKey] 一项；WebDAV 的地址、账号、密码不写进文件。
///
/// 密钥由 WebDAV 账号和密码经 PBKDF2-HMAC-SHA256 算出，登录同一个 WebDAV 账号的设备
/// 直接就能解开；只拿到文件的人看不到账号。加密用 AES-256-GCM，附加数据里有文件的
/// 时间戳：改动密文，或者换上别的文件里的这一项，都会解密失败。
///
/// 官方版和本版本的旧版不认这一项，从新存档恢复时拿不到账号。
class SyncVault {
  static const String extraKey = "vault";
  static const int _version = 1;
  static const String _kdf = "pbkdf2-sha256";

  /// PBKDF2 的迭代次数。电脑上约 0.4 秒，在后台 isolate 里算，每次运行只算一次
  static const int defaultIterations = 300000;
  static const int _maxIterations = 3000000;

  static String get openFailedText => "存档中的账号无法解密，已保留本机登录".t;

  /// 不写进文件的设置：WebDAV 的连接（密钥就从它算出）
  static const Set<String> connectionKeys = {
    LocalStorageService.kWebDAVUri,
    LocalStorageService.kWebDAVUser,
    LocalStorageService.kWebDAVPassword,
  };

  /// 拆开设置，返回（可以写明文的设置，要加密的账号）。
  ///
  /// WebDAV 连接两边都不放；没登录的账号（空值）不放。
  /// [includeLocalOnly] 为 false 时（WebDAV 存档）只在本机的设置也不放进账号，
  /// 比如录屏接口的令牌
  static (Map<String, dynamic>, Map<String, dynamic>) split(
    Map settings, {
    bool includeLocalOnly = false,
  }) {
    var plain = <String, dynamic>{};
    var accounts = <String, dynamic>{};
    settings.forEach((key, value) {
      var name = key.toString();
      if (connectionKeys.contains(name)) {
        return;
      }
      if (LocalStorageService.isAccountKey(name)) {
        if (value != null &&
            value != "" &&
            (includeLocalOnly || !SyncCompat.isLocalOnlySetting(name))) {
          accounts[name] = value;
        }
        return;
      }
      plain[name] = value;
    });
    return (plain, accounts);
  }

  // ---------------------------------------------------------------------
  // 密钥
  // ---------------------------------------------------------------------

  static final Map<String, SyncVaultKey> _keys = {};
  static final Map<String, Uint8List> _lastSalt = {};

  /// 账号名不分大小写、去掉首尾空格：WebDAV 服务器一般也不区分
  static List<int> _secret(String user, String password) =>
      utf8.encode("SimpleLive-WebDAV\n${user.trim().toLowerCase()}\n$password");

  static Uint8List _random(int length) {
    var random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  /// 由 WebDAV 账号和密码算出密钥；没有密码时返回 null，这时账号不写进文件。
  ///
  /// [salt] 为空时沿用这次运行里同一账号用过的盐（比如刚解开的云端存档的），
  /// 没有就新生成
  static Future<SyncVaultKey?> keyFor(
    String user,
    String password, {
    List<int>? salt,
    int iterations = defaultIterations,
  }) async {
    if (password.isEmpty) {
      return null;
    }
    var secret = _secret(user, password);
    var id = crypto.sha256.convert(secret).toString();
    var useSalt = salt == null
        ? (_lastSalt[id] ?? _random(16))
        : Uint8List.fromList(salt);
    var cacheKey = "$id|${base64.encode(useSalt)}|$iterations";
    var key = _keys[cacheKey];
    if (key == null) {
      var bytes = await Isolate.run(() => pbkdf2(secret, useSalt, iterations));
      key = SyncVaultKey(useSalt, iterations, bytes);
      _keys[cacheKey] = key;
    }
    _lastSalt[id] = useSalt;
    return key;
  }

  /// PBKDF2-HMAC-SHA256，输出 32 字节（一块）
  static Uint8List pbkdf2(List<int> secret, List<int> salt, int iterations) {
    var hmac = crypto.Hmac(crypto.sha256, secret);
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    var out = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------
  // 加密和解密
  // ---------------------------------------------------------------------

  /// WebDAV 存档的附加数据：存档时间戳
  static String webDavContext(int dataTime) => "webdav|$dataTime";

  /// 导出配置的附加数据：导出时间
  static String configContext(int time) => "config|$time";

  static Uint8List _aad(String context) =>
      Uint8List.fromList(utf8.encode("SimpleLive-vault-v$_version|$context"));

  static Map<String, dynamic> seal(
    Map<String, dynamic> accounts,
    SyncVaultKey key,
    String context,
  ) {
    // 设置里加密保存的项先用本机密钥解开（一般已经是明文），再一起用 WebDAV 账号算出的
    // 密钥加密：别的设备没有这台设备的密钥
    accounts = DeviceSecrets.instance.revealSettings(accounts);
    var nonce = _random(12);
    var cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(KeyParameter(key.bytes), 128, nonce, _aad(context)),
      );
    var data = cipher.process(
      Uint8List.fromList(utf8.encode(jsonEncode(accounts))),
    );
    return {
      "v": _version,
      "kdf": _kdf,
      "iter": key.iterations,
      "salt": base64.encode(key.salt),
      "nonce": base64.encode(nonce),
      "data": base64.encode(data),
    };
  }

  /// 解开账号。格式不认识、WebDAV 账号密码不对、内容被改过，都返回 null
  static Future<Map<String, dynamic>?> open(
    Map vault, {
    required String user,
    required String password,
    required String context,
  }) async {
    try {
      var iterations = vault["iter"];
      if (vault["v"] != _version ||
          vault["kdf"] != _kdf ||
          iterations is! int ||
          iterations < 1 ||
          iterations > _maxIterations) {
        return null;
      }
      var salt = base64.decode(vault["salt"] as String);
      var nonce = base64.decode(vault["nonce"] as String);
      var data = base64.decode(vault["data"] as String);
      var key = await keyFor(
        user,
        password,
        salt: salt,
        iterations: iterations,
      );
      if (key == null) {
        return null;
      }
      var cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(KeyParameter(key.bytes), 128, nonce, _aad(context)),
        );
      var json = jsonDecode(utf8.decode(cipher.process(data)));
      return json is Map ? Map<String, dynamic>.from(json) : null;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // WebDAV 存档
  // ---------------------------------------------------------------------

  /// 把账号放回存档，后面的恢复流程和明文的旧存档一样：
  /// 本版本专用的账号放进 ext，其余放进 data。
  /// [bilibiliFile] 为 true 时哔哩哔哩 Cookie 另外放进账号文件（没登录为空，和旧存档一样），
  /// 为 false 时去掉账号文件
  static SyncBackupFormat withAccounts(
    SyncBackupFormat backup,
    Map<String, dynamic> accounts, {
    bool bilibiliFile = true,
  }) {
    var files = Map<String, dynamic>.from(backup.files);
    const settingsFile = SyncBackupFormat.settingsFile;
    var file = files[settingsFile];
    if (file is Map) {
      var copy = Map<String, dynamic>.from(file);
      var main = copy["data"] is Map
          ? Map<String, dynamic>.from(copy["data"])
          : <String, dynamic>{};
      var ext = copy[SyncBackupFormat.extKey] is Map
          ? Map<String, dynamic>.from(copy[SyncBackupFormat.extKey])
          : null;
      accounts.forEach((key, value) {
        if (ext != null && SyncCompat.isExtSetting(key)) {
          ext[key] = value;
        } else {
          main[key] = value;
        }
      });
      copy["data"] = main;
      if (ext != null) {
        copy[SyncBackupFormat.extKey] = ext;
      }
      files[settingsFile] = copy;
    }
    const accountFile = SyncBackupFormat.bilibiliAccountFile;
    if (bilibiliFile) {
      files[accountFile] = SyncBackupFormat.pack({
        "cookie": accounts[LocalStorageService.kBilibiliCookie] ?? "",
      });
    } else {
      files.remove(accountFile);
    }
    return SyncBackupFormat(files);
  }

  /// 解开存档里的账号，返回账号放好后的存档和是否解开了。
  ///
  /// 官方版和旧版的存档没有这一项（账号是明文的），原样返回。
  /// 解不开时（各设备的 WebDAV 账号密码不一样、文件被改过）换成本机 [localSettings]
  /// 里的账号，恢复后本机登录不变
  static Future<(SyncBackupFormat, bool)> openBackup(
    SyncBackupFormat backup, {
    required String user,
    required String password,
    required Map localSettings,
  }) async {
    var vault = backup.extraMap(SyncBackupFormat.settingsFile, extraKey);
    if (vault == null) {
      return (backup, true);
    }
    var accounts = await open(
      vault,
      user: user,
      password: password,
      context: webDavContext(backup.dataTime ?? 0),
    );
    if (accounts != null) {
      return (withAccounts(backup, accounts), true);
    }
    var (_, local) = split(localSettings);
    return (withAccounts(backup, local, bilibiliFile: false), false);
  }
}
