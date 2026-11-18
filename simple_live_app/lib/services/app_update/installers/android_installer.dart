import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/app_update/installers/install_common.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';

/// 安卓：按设备的 ABI 选 APK，下载后调起系统的安装界面（AppUpdate.kt 里的通道
/// simple_live/app_update，APK 经 FileProvider 交给系统）。
/// 系统一定会让用户确认一次；第一次还要允许“安装未知应用”。签名和已装的不同就装不上
class AndroidInstaller implements UpdateInstaller {
  static const MethodChannel channel = MethodChannel("simple_live/app_update");

  /// Release 里有的三种 APK
  static const List<String> knownAbis = ["arm64-v8a", "armeabi-v7a", "x86_64"];

  static List<String>? _deviceAbis;

  /// 读设备支持的 ABI（按设备的优先顺序）。pickAsset 是同步的，所以先读好；
  /// 没读到时按当前进程的 ABI 选（就是现在装着的那种）
  static Future<void> loadAbis() async {
    if (_deviceAbis != null || !Platform.isAndroid) {
      return;
    }
    try {
      _deviceAbis = (await DeviceInfoPlugin().androidInfo).supportedAbis;
    } catch (e) {
      Log.w("读取设备 ABI 失败：$e");
    }
  }

  static List<String> get abis {
    if (_deviceAbis case var list? when list.isNotEmpty) {
      return list;
    }
    var abi = processAbi(Abi.current());
    return abi == null ? const [] : [abi];
  }

  static String? processAbi(Abi abi) => switch (abi) {
        Abi.androidArm64 => "arm64-v8a",
        Abi.androidArm => "armeabi-v7a",
        Abi.androidX64 => "x86_64",
        _ => null,
      };

  /// 按 [abis] 的顺序找第一个有 APK 的
  static ReleaseAsset? pickForAbis(
    List<ReleaseAsset> assets,
    List<String> abis,
  ) {
    for (var abi in abis) {
      if (!knownAbis.contains(abi)) {
        continue;
      }
      var asset = pickAssetBySuffix(assets, ["-android-$abi.apk"]);
      if (asset != null) {
        return asset;
      }
    }
    return null;
  }

  @override
  bool get canInstallInApp => true;

  @override
  String get installNote => "下载完成后打开系统安装界面".t;

  @override
  ReleaseAsset? pickAsset(List<ReleaseAsset> assets) =>
      pickForAbis(assets, abis);

  @override
  Future<void> install(
    String filePath,
    ReleaseAsset asset, {
    required String version,
    String? tempUrl,
  }) async {
    var apk = await _stage(filePath);
    var allowed = await channel.invokeMethod<bool>("canInstall") ?? false;
    if (!allowed) {
      try {
        await channel.invokeMethod<bool>("openInstallSettings");
      } catch (e) {
        Log.w("打开“安装未知应用”设置失败：$e");
      }
      throw UpdateInstallError("请允许“安装未知应用”，然后重新更新".t);
    }
    try {
      await channel.invokeMethod<bool>("installApk", {"path": apk});
    } on PlatformException catch (e) {
      Log.w("调起安装界面失败：${e.code} ${e.message}");
      throw UpdateInstallError("无法打开系统安装界面".t);
    }
  }

  /// FileProvider 只开放缓存目录的 update 文件夹（res/xml/update_paths.xml），不在那里就拷过去。
  /// 以前版本拷过去的 APK 删掉，只留这一个
  Future<String> _stage(String filePath) async {
    var dir = await UpdatePaths.updateDir();
    if (p.isWithin(dir.path, filePath)) {
      return filePath;
    }
    var target = p.join(dir.path, p.basename(filePath));
    await for (var entry in dir.list(followLinks: false)) {
      if (entry is File &&
          entry.path.toLowerCase().endsWith(".apk") &&
          !p.equals(entry.path, target)) {
        try {
          await entry.delete();
        } catch (_) {}
      }
    }
    await File(filePath).copy(target);
    return target;
  }
}
