import 'dart:ffi' show Abi;

import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/app_update/installers/install_common.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';
import 'package:url_launcher/url_launcher.dart';

/// macOS：App 开着沙盒（Release.entitlements 的 app-sandbox），不能自己换掉 .app。
/// 下载、校验以后打开 dmg，由用户把 Simple Live 拖进“应用程序”文件夹替换旧版本。
/// 更新对话框里先说明（[installNote]），打开 dmg 后再提示一次，可以直接退出 App 再拖
class MacosInstaller implements UpdateInstaller {
  @override
  bool get canInstallInApp => false;

  @override
  String get installNote => "下载完成后打开 dmg，需要将 Simple Live 拖入“应用程序”文件夹".t;

  @override
  ReleaseAsset? pickAsset(List<ReleaseAsset> assets) =>
      pickForAbi(assets, Abi.current());

  /// 优先通用版（universal），没有时按 CPU 选
  static ReleaseAsset? pickForAbi(List<ReleaseAsset> assets, Abi abi) =>
      pickAssetBySuffix(assets, [
        "-macos-universal.dmg",
        if (abi == Abi.macosArm64) "-macos-arm64.dmg",
        if (abi == Abi.macosX64) "-macos-x86_64.dmg",
      ]);

  @override
  Future<void> install(
    String filePath,
    ReleaseAsset asset, {
    required String version,
    String? tempUrl,
  }) async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.file(filePath));
    } catch (e) {
      Log.w("打开 dmg 失败：$e");
    }
    if (!ok) {
      throw UpdateInstallError("无法打开安装包".t);
    }
    // 开着的 App 替换不了：先退出再拖
    if (await Utils.showAlertDialog(
      "请先退出 Simple Live，再将安装包中的 Simple Live 拖入“应用程序”文件夹，替换旧版本。".t,
      title: "安装包已打开".t,
      confirm: "退出 Simple Live".t,
      cancel: "稍后".t,
    )) {
      await quitForUpdate();
    }
  }
}
