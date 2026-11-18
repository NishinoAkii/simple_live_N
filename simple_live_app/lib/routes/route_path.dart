/// 路由路径
class RoutePath {
  /// 首页
  static const kIndex = "/index";

  /// 搜索
  static const kSearch = "/search";

  /// 分类详情
  static const kCategoryDetail = "/category/detail";

  /// 直播间
  static const kLiveRoomDetail = "/room/detail";

  /// 弹幕设置
  static const kSettingsDanmu = "/settings/danmu";

  /// 定时关闭设置
  static const kSettingsAutoExit = "/settings/auto_exit";

  /// 直播间设置
  static const kSettingsPlay = "/settings/play";

  /// 弹幕关键词屏蔽
  static const kSettingsDanmuShield = "/settings/danmu/shield";

  /// 其他设置
  static const kSettingsOther = "/settings/other";

  /// 赞助
  static const kSponsor = "/sponsor";

  /// 历史记录
  static const kHistory = "/user/history";

  /// 我的关注
  static const kFollowUser = "/user/follow";

  /// 工具箱
  static const kTools = "/other/tools";

  /// 主页设置
  static const kSettingsIndexed = "/settings/indexed";

  /// 外观设置
  static const kAppstyleSetting = "/settings/appstyle";

  /// 账号管理
  static const kSettingsAccount = "/settings/account";

  /// 关注设置
  static const kSettingsFollow = "/settings/follow";

  /// 直播源订阅（.live.js 脚本平台）
  static const kSettingsLiveSource = "/settings/live_source";

  /// 电脑端设置：快捷键、记住窗口、显卡偏好
  static const kSettingsDesktop = "/settings/desktop";

  /// 更新：检查更新、启动时检查、下载源、翻译源
  static const kSettingsUpdate = "/settings/update";

  /// 一个直播源的详情（权限、签名、设置项），参数为源的 key
  static const kSettingsLiveSourceDetail = "/settings/live_source/detail";

  /// BiliBili Web登录
  static const kBiliBiliWebLogin = "/settings/account/bilibili/web_login";

  /// BiliBili 二维码登录
  static const kBiliBiliQRLogin = "/settings/account/bilibili/qr_login";

  /// 斗鱼二维码登录
  static const kDouyuScanLogin = "/settings/account/douyu/scan_login";

  /// 网页登录（Twitch/Kick/YouTube，从 Cookie 读取令牌）
  static const kWebCookieLogin = "/settings/account/web_cookie_login";

  /// YouTube 账号（谷歌官方授权与网页 Cookie）
  static const kYouTubeAccount = "/settings/account/youtube";

  /// 账号关注：从账号导入、与账号同步、同步到账号的开关和待同步列表
  static const kAccountFollow = "/settings/account/follow";

  /// 从账号导入关注（参数：平台 id，可省略）
  static const kAccountFollowImport = "/settings/account/follow/import";

  /// 与账号同步（参数：平台 id，可省略）
  static const kAccountFollowSync = "/settings/account/follow/sync";

  /// 数据同步
  static const kLocalSync = "/local_sync";

  /// 数据同步
  static const kSync = "/sync";

  /// 扫描
  static const kSyncScan = "/sync/scan";

  /// 同步设备
  static const kLocalSyncDevice = "/sync/device";

  /// 远程同步-房间
  static const kRemoteSyncRoom = "/remote_sync/room";

  /// 远程同步-WebDAV
  static const kRemoteSyncWebDav = "/remote_sync/webDAV";

  /// 远程同步-WebDAVConfig
  static const kRemoteSyncWebDavConfig = "/remote_sync/webDAVConfig";

  /// 测试页面
  static const kTest = "/test";
}
