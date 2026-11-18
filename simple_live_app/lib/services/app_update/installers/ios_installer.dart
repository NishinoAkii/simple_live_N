import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/app_update/installers/install_common.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// iOS 的 IPA 交给谁装
enum IosInstallTarget {
  /// 依次试 TrollStore、AltStore、SideStore，都没有就分享
  auto,
  trollStore,
  altStore,
  sideStore,

  /// 系统的分享（用其他应用打开下载好的文件）
  share,
}

/// 选的安装方式，只存本机（SyncCompat.localOnlySettingKeys）
class IosInstallSetting {
  IosInstallSetting._();

  static const String kKey = "AppUpdateIosInstallTarget";

  static final Rx<IosInstallTarget> _value = IosInstallTarget.auto.obs;
  static bool _loaded = false;

  static LocalStorageService? get _storage =>
      Get.isRegistered<LocalStorageService>()
          ? LocalStorageService.instance
          : null;

  static Rx<IosInstallTarget> get value {
    if (!_loaded) {
      _loaded = true;
      _value.value = parse(_storage?.getValue<String>(kKey, ""));
    }
    return _value;
  }

  static Future<void> set(IosInstallTarget target) async {
    _loaded = true;
    _value.value = target;
    await _storage?.setValue<String>(kKey, target.name);
  }

  static IosInstallTarget parse(String? text) => IosInstallTarget.values
      .firstWhere((e) => e.name == text, orElse: () => IosInstallTarget.auto);

  @visibleForTesting
  static void reset() {
    _loaded = false;
    _value.value = IosInstallTarget.auto;
  }
}

/// iOS：未签名的 IPA 不能自己装，交给 TrollStore / AltStore / SideStore 的安装链接，
/// 或者用系统分享交给别的应用。要登录的仓库用 tempUrl（几分钟内有效的下载链接）
class IosInstaller implements UpdateInstaller {
  /// 自动时按这个顺序试
  static const List<IosInstallTarget> storeOrder = [
    IosInstallTarget.trollStore,
    IosInstallTarget.altStore,
    IosInstallTarget.sideStore,
  ];

  @override
  bool get canInstallInApp => false;

  @override
  String get installNote => "下载完成后交给 TrollStore 等工具安装".t;

  @override
  ReleaseAsset? pickAsset(List<ReleaseAsset> assets) =>
      pickAssetBySuffix(assets, const ["-ios-arm64-unsigned.ipa"]);

  /// 安装链接；分享、自动没有链接，返回 null
  static Uri? storeUrl(IosInstallTarget target, String ipaUrl) {
    var scheme = switch (target) {
      IosInstallTarget.trollStore => "apple-magnifier",
      IosInstallTarget.altStore => "altstore",
      IosInstallTarget.sideStore => "sidestore",
      _ => null,
    };
    if (scheme == null) {
      return null;
    }
    return Uri.parse("$scheme://install?url=${Uri.encodeComponent(ipaUrl)}");
  }

  /// 按选的方式依次要试的商店
  static List<IosInstallTarget> storesFor(IosInstallTarget target) =>
      switch (target) {
        IosInstallTarget.auto => storeOrder,
        IosInstallTarget.share => const [],
        _ => [target],
      };

  static String targetName(IosInstallTarget target) => switch (target) {
        IosInstallTarget.auto => "自动".t,
        IosInstallTarget.trollStore => "TrollStore",
        IosInstallTarget.altStore => "AltStore",
        IosInstallTarget.sideStore => "SideStore",
        IosInstallTarget.share => "分享".t,
      };

  @override
  Future<void> install(
    String filePath,
    ReleaseAsset asset, {
    required String version,
    String? tempUrl,
  }) async {
    var url = tempUrl ?? asset.browserUrl;
    var target = IosInstallSetting.value.value;
    var stores = url.isEmpty ? const <IosInstallTarget>[] : storesFor(target);
    for (var store in stores) {
      var uri = storeUrl(store, url)!;
      try {
        // 自动时先看装没装；指定了的直接打开
        if (target == IosInstallTarget.auto && !await canLaunchUrl(uri)) {
          continue;
        }
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return;
        }
      } catch (e) {
        Log.w("打开 ${targetName(store)} 失败：$e");
      }
    }
    await _share(filePath);
  }

  Future<void> _share(String filePath) async {
    // iPad 上分享面板要有一个弹出的位置，放在屏幕中间
    var dispatcher = WidgetsBinding.instance.platformDispatcher;
    var view = dispatcher.implicitView ?? dispatcher.views.first;
    var size = view.physicalSize / view.devicePixelRatio;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(filePath)],
        sharePositionOrigin: Rect.fromCenter(
          center: Offset(size.width / 2, size.height / 2),
          width: 1,
          height: 1,
        ),
      ),
    );
  }
}
