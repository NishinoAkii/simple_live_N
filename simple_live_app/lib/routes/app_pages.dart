// ignore_for_file: prefer_inlined_adds

import 'package:get/get.dart';
import 'package:simple_live_app/modules/category/detail/category_detail_controller.dart';
import 'package:simple_live_app/modules/category/detail/category_detail_page.dart';
import 'package:simple_live_app/modules/indexed/indexed_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_page.dart';
import 'package:simple_live_app/modules/settings/desktop_settings_page.dart';
import 'package:simple_live_app/modules/settings/follow_settings_page.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/remote_sync_webdav_config_page.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/remote_sync_webdav_controller.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/remote_sync_webdav_page.dart';
import 'package:simple_live_app/modules/sync/sync_page.dart';
import 'package:simple_live_app/modules/sync/remote_sync/room/remote_sync_room_controller.dart';
import 'package:simple_live_app/modules/sync/remote_sync/room/remote_sync_room_page.dart';
import 'package:simple_live_app/modules/search/search_controller.dart';
import 'package:simple_live_app/modules/search/search_page.dart';
import 'package:simple_live_app/modules/sync/local_sync/device/sync_device_controller.dart';
import 'package:simple_live_app/modules/sync/local_sync/device/sync_device_page.dart';
import 'package:simple_live_app/modules/sync/local_sync/scan_qr/sync_scan_qr_controller.dart';
import 'package:simple_live_app/modules/sync/local_sync/scan_qr/sync_scan_qr_page.dart';
import 'package:simple_live_app/modules/mine/parse/parse_controller.dart';
import 'package:simple_live_app/modules/mine/parse/parse_page.dart';
import 'package:simple_live_app/modules/sync/local_sync/local_sync_controller.dart';
import 'package:simple_live_app/modules/sync/local_sync/local_sync_page.dart';
import 'package:simple_live_app/modules/mine/account/account_controller.dart';
import 'package:simple_live_app/modules/mine/account/account_page.dart';
import 'package:simple_live_app/modules/mine/account/bilibili/qr_login_controller.dart';
import 'package:simple_live_app/modules/mine/account/bilibili/qr_login_page.dart';
import 'package:simple_live_app/modules/mine/account/bilibili/web_login_controller.dart';
import 'package:simple_live_app/modules/mine/account/bilibili/web_login_page.dart';
import 'package:simple_live_app/modules/mine/account/douyu/scan_login_controller.dart';
import 'package:simple_live_app/modules/mine/account/douyu/scan_login_page.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_controller.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_import_controller.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_import_page.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_page.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_sync_controller.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_sync_page.dart';
import 'package:simple_live_app/modules/mine/account/web_cookie_login_page.dart';
import 'package:simple_live_app/modules/mine/account/youtube/youtube_account_controller.dart';
import 'package:simple_live_app/modules/mine/account/youtube/youtube_account_page.dart';
import 'package:simple_live_app/modules/settings/appstyle_setting_page.dart';
import 'package:simple_live_app/modules/settings/auto_exit_settings_page.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/modules/settings/danmu_shield/danmu_shield_controller.dart';
import 'package:simple_live_app/modules/settings/danmu_shield/danmu_shield_page.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_controller.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_page.dart';
import 'package:simple_live_app/modules/mine/history/history_controller.dart';
import 'package:simple_live_app/modules/mine/history/history_page.dart';
import 'package:simple_live_app/modules/settings/indexed_settings/indexed_settings_controller.dart';
import 'package:simple_live_app/modules/settings/indexed_settings/indexed_settings_page.dart';
import 'package:simple_live_app/modules/settings/live_source/live_source_detail_page.dart';
import 'package:simple_live_app/modules/settings/live_source/live_source_settings_controller.dart';
import 'package:simple_live_app/modules/settings/live_source/live_source_settings_page.dart';
import 'package:simple_live_app/modules/settings/other/other_settings_controller.dart';
import 'package:simple_live_app/modules/settings/other/other_settings_page.dart';
import 'package:simple_live_app/modules/settings/play_settings_page.dart';

import '../modules/indexed/indexed_page.dart';
import 'route_path.dart';

class AppPages {
  AppPages._();
  static final routes = [
    // 首页
    GetPage(
      name: RoutePath.kIndex,
      page: () => const IndexedPage(),
      bindings: [
        BindingsBuilder.put(() => IndexedController()),
        //BindingsBuilder.put(() => HomeController()),
      ],
    ),
    // 观看记录
    GetPage(
      name: RoutePath.kHistory,
      page: () => const HistoryPage(),
      bindings: [
        BindingsBuilder.put(() => HistoryController()),
      ],
    ),
    // 关注用户
    GetPage(
      name: RoutePath.kFollowUser,
      page: () => const FollowUserPage(),
      bindings: [
        BindingsBuilder.put(() => FollowUserController()),
      ],
    ),
    // 搜索
    GetPage(
      name: RoutePath.kSearch,
      page: () => const SearchPage(),
      bindings: [
        BindingsBuilder.put(() => AppSearchController()),
      ],
    ),
    //分类详情
    GetPage(
      name: RoutePath.kCategoryDetail,
      page: () => const CategoryDetailPage(),
      // 每一层分类一个控制器，用路由参数里的 tag 区分
      binding: BindingsBuilder(() {
        Get.put<CategoryDetailController>(
          CategoryDetailController(
            site: Get.arguments[0],
            subCategory: Get.arguments[1],
          ),
          tag: CategoryDetailPage.tagOf(Get.arguments),
        );
      }),
    ),
    //直播间
    GetPage(
      name: RoutePath.kLiveRoomDetail,
      page: () => const LiveRoomPage(),
      binding: BindingsBuilder.put(
        () => LiveRoomController(
          pSite: Get.arguments,
          pRoomId: Get.parameters["roomId"] ?? "",
        ),
      ),
    ),
    //弹幕设置
    GetPage(
      name: RoutePath.kSettingsDanmu,
      page: () => const DanmuSettingsPage(),
    ),
    //外观设置
    GetPage(
        name: RoutePath.kAppstyleSetting,
        page: () => const AppstyleSettingPage()),
    //播放设置
    GetPage(
      name: RoutePath.kSettingsPlay,
      page: () => const PlaySettingsPage(),
    ),
    //自动关闭
    GetPage(
      name: RoutePath.kSettingsAutoExit,
      page: () => const AutoExitSettingsPage(),
    ),
    //工具箱
    GetPage(
      name: RoutePath.kTools,
      page: () => const ParsePage(),
      bindings: [
        BindingsBuilder.put(() => ParseController()),
      ],
    ),
    //关键词屏蔽
    GetPage(
      name: RoutePath.kSettingsDanmuShield,
      page: () => const DanmuShieldPage(),
      bindings: [
        BindingsBuilder.put(() => DanmuShieldController()),
      ],
    ),
    //主页设置
    GetPage(
      name: RoutePath.kSettingsIndexed,
      page: () => const IndexedSettingsPage(),
      bindings: [
        BindingsBuilder.put(() => IndexedSettingsController()),
      ],
    ),
    //账号设置
    GetPage(
      name: RoutePath.kSettingsAccount,
      page: () => const AccountPage(),
      bindings: [
        BindingsBuilder.put(() => AccountController()),
      ],
    ),
    //哔哩哔哩Web登录
    GetPage(
      name: RoutePath.kBiliBiliWebLogin,
      page: () => const BiliBiliWebLoginPage(),
      bindings: [
        BindingsBuilder.put(() => BiliBiliWebLoginController()),
      ],
    ),
    //哔哩哔哩二维码登录
    GetPage(
      name: RoutePath.kBiliBiliQRLogin,
      page: () => const BiliBiliQRLoginPage(),
      bindings: [
        BindingsBuilder.put(() => BiliBiliQRLoginController()),
      ],
    ),
    //斗鱼扫码登录
    GetPage(
      name: RoutePath.kDouyuScanLogin,
      page: () => const DouyuScanLoginPage(),
      bindings: [
        BindingsBuilder.put(() => DouyuScanLoginController()),
      ],
    ),
    //网页登录（Twitch/Kick/YouTube）
    GetPage(
      name: RoutePath.kWebCookieLogin,
      page: () => const WebCookieLoginPage(),
    ),
    //YouTube 账号
    GetPage(
      name: RoutePath.kYouTubeAccount,
      page: () => const YouTubeAccountPage(),
      bindings: [
        BindingsBuilder.put(() => YouTubeAccountController()),
      ],
    ),
    // 账号关注
    GetPage(
      name: RoutePath.kAccountFollow,
      page: () => const AccountFollowPage(),
      bindings: [
        BindingsBuilder.put(() => AccountFollowController()),
      ],
    ),
    GetPage(
      name: RoutePath.kAccountFollowImport,
      page: () => const AccountFollowImportPage(),
      bindings: [
        BindingsBuilder.put(() => AccountFollowImportController()),
      ],
    ),
    GetPage(
      name: RoutePath.kAccountFollowSync,
      page: () => const AccountFollowSyncPage(),
      bindings: [
        BindingsBuilder.put(() => AccountFollowSyncController()),
      ],
    ),
    // 数据同步
    GetPage(
      name: RoutePath.kSync,
      page: () => const SyncPage(),
    ),
    // 本地同步
    GetPage(
      name: RoutePath.kLocalSync,
      page: () => const LocalSyncPage(),
      bindings: [
        BindingsBuilder.put(
          () => LocalSyncController(
            Get.arguments ?? "",
          ),
        ),
      ],
    ),
    //扫码
    GetPage(
      name: RoutePath.kSyncScan,
      page: () => const SyncScanQRPage(),
      bindings: [
        BindingsBuilder.put(() => SyncScanQRControlelr()),
      ],
    ),
    //同步设备
    GetPage(
      name: RoutePath.kLocalSyncDevice,
      page: () => const SyncDevicePage(),
      bindings: [
        BindingsBuilder.put(
          () => SyncDeviceController(
            client: Get.arguments['client'],
            info: Get.arguments['info'],
          ),
        ),
      ],
    ),
    //远程同步-房间
    GetPage(
      name: RoutePath.kRemoteSyncRoom,
      page: () => const RemoteSyncRoomPage(),
      bindings: [
        BindingsBuilder.put(
          () => RemoteSyncRoomController(Get.arguments ?? ""),
        ),
      ],
    ),
    //远程同步-WebDAV
    GetPage(
      name: RoutePath.kRemoteSyncWebDav,
      page: () => const RemoteSyncWebDAVPage(),
      bindings: [
        BindingsBuilder.put(
          () => RemoteSyncWebDAVController(),
        ),
      ],
    ),
    //远程同步-WebDAVConfig
    GetPage(
      name: RoutePath.kRemoteSyncWebDavConfig,
      page: () => const RemoteSyncWebDAVConfigPage(),
    ),
    //其他设置
    GetPage(
      name: RoutePath.kSettingsOther,
      page: () => const OtherSettingsPage(),
      bindings: [
        BindingsBuilder.put(() => OtherSettingsController()),
      ],
    ),
    //关注设置
    GetPage(
      name: RoutePath.kSettingsFollow,
      page: () => const FollowSettingsPage(),
    ),
    //电脑端设置
    GetPage(
      name: RoutePath.kSettingsDesktop,
      page: () => const DesktopSettingsPage(),
    ),
    //直播源订阅
    GetPage(
      name: RoutePath.kSettingsLiveSource,
      page: () => const LiveSourceSettingsPage(),
      bindings: [
        BindingsBuilder.put(() => LiveSourceSettingsController()),
      ],
    ),
    GetPage(
      name: RoutePath.kSettingsLiveSourceDetail,
      page: () => const LiveSourceDetailPage(),
    ),
  ];
}
