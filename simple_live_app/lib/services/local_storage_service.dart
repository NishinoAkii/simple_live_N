import 'package:simple_live_app/services/device_secrets.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/log_mask.dart';

class LocalStorageService extends GetxService {
  static LocalStorageService get instance => Get.find<LocalStorageService>();

  /// 首次运行
  static const String kFirstRun = "FirstRun";

  /// 缩放模式
  static const String kPlayerScaleMode = "ScaleMode";

  /// 网站排序
  static const String kSiteSort = "SiteSort";

  /// 首页排序
  static const String kHomeSort = "HomeSort";

  /// 不在首页、分类、搜索里显示的平台（逗号分隔的平台 id）。
  /// 新装时默认隐藏本版本新增的平台，只显示最初的四个
  static const String kHiddenSites = "HiddenSites";

  /// 显示模式
  /// * [0] 跟随系统
  /// * [1] 浅色模式
  /// * [2] 深色模式
  static const String kThemeMode = "ThemeMode";

  /// 界面语言：空 = 跟随系统，否则是语言代码（zh-Hans、zh-Hant、en 或导入的翻译的代码）。
  /// 每台设备各自选，不同步
  static const String kAppLanguage = "AppLanguage";

  /// DEBUG模式
  static const String kDebugModeKey = "DebugMode";

  /// 弹幕大小
  static const String kDanmuSize = "DanmuSize";

  /// 弹幕速度
  static const String kDanmuSpeed = "DanmuSpeed";

  /// 手机、平板全屏时的弹幕大小（非全屏用 [kDanmuSize]）
  static const String kDanmuSizeFullscreen = "DanmuSizeFullscreen";

  /// 手机、平板小窗（画中画）的弹幕大小和速度
  static const String kDanmuPipSize = "DanmuPipSize";
  static const String kDanmuPipSpeed = "DanmuPipSpeed";

  /// 弹幕区域
  static const String kDanmuArea = "DanmuArea";

  /// 弹幕透明度
  static const String kDanmuOpacity = "DanmuOpacity";

  /// 弹幕描边大小
  static const String kDanmuStrokeWidth = "DanmuStrokeWidth";

  /// 弹幕-屏蔽滚动
  static const String kDanmuHideScroll = "DanmuHideScroll";

  /// 弹幕-屏蔽底部
  static const String kDanmuHideBottom = "DanmuHideBottom";

  /// 弹幕-屏蔽顶部
  static const String kDanmuHideTop = "DanmuHideTop";

  /// 弹幕-顶部边距
  static const String kDanmuTopMargin = "DanmuTopMargin";

  /// 弹幕-底部边距
  static const String kDanmuBottomMargin = "DanmuBottomMargin";

  /// 弹幕开启
  static const String kDanmuEnable = "DanmuEnable";

  /// 弹幕字重
  static const String kDanmuFontWeight = "DanmuFontWeight";

  /// 弹幕和聊天栏把表情显示为图片（平台给出图片时，如哔哩哔哩、YouTube）
  static const String kDanmuEmoteImage = "DanmuEmoteImage";

  /// 付费礼物飞过视频
  static const String kDanmuGiftFly = "DanmuGiftFly";

  /// SC 页和礼物页：最新的在下面（和弹幕一样），false 时在上面
  static const String kNoticeNewestAtBottom = "NoticeNewestAtBottom";

  /// 聊天（弹幕）列表：最新的在下面，false 时在上面
  static const String kChatNewestAtBottom = "ChatNewestAtBottom";

  /// 聊天区顶上的直播间公告卡片：显示（默认开）、收起成小条。只存本机，不进备份
  static const String kChatNoticeCard = "ChatNoticeCard";
  static const String kChatNoticeFolded = "ChatNoticeFolded";

  /// 直播间、平台单独的设置（和 Venera 的“本漫画特定设置”一样）：
  /// 键是这个前缀加“room:平台_房间号”或“site:平台”，值是 JSON：
  /// enabled（开关），以及打开后调过的项（没调过的沿用平台的、再沿用全局的）
  static const String kRoomSettingsPrefix = "RoomSettings_";

  /// 直播间里的定时关闭：进这个直播间时自动开始（只记在直播间、平台单独设置里）
  static const String kRoomAutoExitEnable = "RoomAutoExitEnable";


  /// 直播间显示榜单（默认开；键名沿用原来的“榜单页”）
  static const String kLiveRankTab = "LiveRankTab";

  /// 硬件解码
  static const String kHardwareDecode = "HardwareDecode";

  /// 聊天区文字大小
  static const String kChatTextSize = "ChatTextSize";

  /// 单独调整表情图片大小；表情图片大小（相对文字大小的倍数）
  static const String kEmoteSizeSeparate = "EmoteSizeSeparate";
  static const String kEmoteScale = "EmoteScale";

  /// 聊天区间隔
  static const String kChatTextGap = "ChatTextGap";

  /// 聊天区-气泡样式
  static const String kChatBubbleStyle = "ChatBubbleStyle";

  /// 聊天区-用户名用发言人自己的颜色（Twitch、Kick）
  static const String kChatNameColor = "ChatNameColor";

  /// 弹幕设置-视频上的弹幕保留平台给的颜色（关掉全部为白色）
  static const String kDanmuColorful = "DanmuColorful";

  /// 弹幕设置-弹幕缓冲增强：弹幕一阵一阵来时先攒一会儿再匀速放出
  static const String kDanmuBufferBoost = "DanmuBufferBoost";

  /// 弹幕设置-平均每秒弹幕少于这个数时不缓冲
  static const String kDanmuBufferMinRate = "DanmuBufferMinRate";

  /// 聊天区-名字前面显示粉丝牌、舰长等
  static const String kChatShowBadges = "ChatShowBadges";

  /// 聊天区-直播间保留的弹幕条数（0 为不限）
  static const String kChatKeepLimit = "ChatKeepLimit";

  /// 聊天区-显示头像（平台提供头像时，如 YouTube）
  static const String kChatShowFace = "ChatShowFace";

  /// 聊天区-表情动图（默认关，显示第一帧）
  static const String kChatAnimatedEmotes = "ChatAnimatedEmotes";

  /// 播放清晰度，0=低，1=中，2=高
  static const String kQualityLevel = "QualityLevel";

  /// 蜂窝网络下播放清晰度，0=低，1=中，2=高
  static const String kQualityLevelCellular = "QualityLevelCellular";

  /// 默认清晰度、数据网络清晰度选了“记住上次”；各平台上次手动选的清晰度（JSON）。
  /// 只在本机，不同步（PlayPrefs）
  static const String kQualityRemember = "QualityRemember";
  static const String kQualityRememberCellular = "QualityRememberCellular";
  static const String kQualityMemory = "QualityMemory";
  static const String kQualityMemoryCellular = "QualityMemoryCellular";

  /// 开启定时关闭
  static const String kAutoExitEnable = "AutoExitEnable";

  /// 定时关闭时间（分钟）
  static const String kAutoExitDuration = "AutoExitDuration";

  /// 房间内定时关闭时间（分钟）
  /// 需要一个不同的 key，因为用户在房间内设置的倒计时和全局的可能不同。
  static const String kRoomAutoExitDuration = "RoomAutoExitDuration";

  /// 播放器兼容模式
  static const String kPlayerCompatMode = "PlayerCompatMode";

  /// 播放器后台自动暂停
  static const String kPlayerAutoPause = "PlayerAutoPause";

  /// 与其他应用同时播放（不抢音频焦点）。只在本机，不同步
  static const String kPlayWithOthers = "PlayWithOthers";

  /// 播放器缓冲区大小
  static const String kPlayerBufferSize = "PlayerBufferSize";

  /// 播放器强制使用HTTPS
  static const String kPlayerForceHttps = "PlayerForceHttps";

  /// 自动全屏
  static const String kAutoFullScreen = "AutoFullScreen";

  /// 全屏方向（安卓）：0 智能，1 强制横屏，2 跟随系统。只在本机，不同步
  static const String kFullscreenOrientation = "FullscreenOrientation";

  /// 显示SC
  static const String kPlayerShowSuperChat = "PlayerShowSuperChat";

  /// 播放器左上角显示视频信息（帧率、码率等）
  static const String kPlayerVideoStats = "PlayerVideoStats";

  /// 播放器音量
  static const String kPlayerVolume = "PlayerVolume";

  /// 小窗隐藏弹幕
  static const String kPIPHideDanmu = "PIPHideDanmu";

  /// SC 显示方式：0 按直播间显示时长，1 一直显示
  static const String kSuperChatDisplayMode = "SuperChatDisplayMode";

  /// 直播追帧加速
  static const String kLiveCatchUp = "LiveCatchUp";

  /// 追帧最高倍速
  static const String kLiveCatchUpMaxRate = "LiveCatchUpMaxRate";

  /// 追帧目标缓冲（秒）
  static const String kLiveCatchUpTarget = "LiveCatchUpTarget";

  /// iOS 画中画显示弹幕
  static const String kIosPipDanmaku = "IosPipDanmaku";

  /// iOS 画中画弹幕大小（倍数）
  static const String kIosPipDanmakuScale = "IosPipDanmakuScale";

  /// iOS 画中画弹幕行数
  static const String kIosPipDanmakuLines = "IosPipDanmakuLines";

  /// iOS 画中画帧率（30 / 60）
  static const String kIosPipFrameRate = "IosPipFrameRate";

  /// iOS 画中画画质（最大高度：540 / 720 / 1080）
  static const String kIosPipQuality = "IosPipQuality";

  /// iOS 小窗播放方式：0 系统播放器（AVPlayer），1 mpv（旧方式）
  static const String kIosPipEngine = "IosPipEngine";

  /// iOS 小窗弹幕方式：0 通话式，1 叠加到系统小窗（实验）
  static const String kIosPipDanmakuMode = "IosPipDanmakuMode";

  /// iOS 小窗显示醒目留言
  static const String kIosPipSuperChat = "IosPipSuperChat";

  /// iOS 退到后台自动开小窗（系统播放器方式）
  static const String kIosPipAutoStart = "IosPipAutoStart";

  /// iOS 投屏时电视只显示画面和弹幕
  static const String kIosExternalDisplay = "IosExternalDisplay";

  /// iOS 投屏时电视显示右侧聊天栏
  static const String kIosExternalSidebar = "IosExternalSidebar";

  /// 哔哩哔哩cookie
  static const String kBilibiliCookie = "BilibiliCookie";

  /// 哔哩哔哩网页端的 LIVE_BUVID（生成一次后一直沿用，同浏览器保存的 Cookie）
  static const String kBiliLiveBuvid = "BiliLiveBuvid";

  /// 平台发的 LIVE_BUVID，有它时不用上面生成的
  static const String kBiliLiveBuvidCookie = "BiliLiveBuvidCookie";

  /// 抖音cookie
  static const String kDouyinCookie = "DouyinCookie";

  /// 斗鱼登录 Cookie
  static const String kDouyuCookie = "DouyuCookie";

  /// 斗鱼续期凭据 LTP0
  static const String kDouyuLtp0 = "DouyuLtp0";

  /// 斗鱼登录设备号 dy_did
  static const String kDouyuPassportDid = "DouyuPassportDid";

  /// Twitch OAuth 令牌
  static const String kTwitchToken = "TwitchToken";

  /// Twitch 登录名
  static const String kTwitchLogin = "TwitchLogin";

  /// Twitch 显示名称
  static const String kTwitchDisplayName = "TwitchDisplayName";

  /// Kick 会话令牌
  static const String kKickToken = "KickToken";

  /// Kick 用户名
  static const String kKickUserName = "KickUserName";

  /// YouTube 官方授权：用户自建的 OAuth 客户端 ID
  static const String kYouTubeClientId = "YouTubeClientId";

  /// YouTube 官方授权：OAuth 客户端密钥
  static const String kYouTubeClientSecret = "YouTubeClientSecret";

  /// YouTube 官方授权的令牌（JSON）
  static const String kYouTubeOAuthToken = "YouTubeOAuthToken";

  /// YouTube 官方授权的频道（JSON：id、title、avatar）
  static const String kYouTubeOAuthChannel = "YouTubeOAuthChannel";

  /// YouTube 网页 Cookie
  static const String kYouTubeCookie = "YouTubeCookie";

  /// YouTube 网页 Cookie 登录的频道（JSON：id、title、avatar）
  static const String kYouTubeCookieChannel = "YouTubeCookieChannel";


  /// 账号类设置：各平台的 Cookie、令牌和登录名。
  /// 日志里隐藏，WebDAV 存档和导出的配置里加密（见 SyncVault）
  static const Set<String> accountKeys = {
    kBilibiliCookie,
    kBiliLiveBuvid,
    kBiliLiveBuvidCookie,
    kDouyinCookie,
    kDouyuCookie,
    kDouyuLtp0,
    kDouyuPassportDid,
    kTwitchToken,
    kTwitchLogin,
    kTwitchDisplayName,
    kKickToken,
    kKickUserName,
    kYouTubeClientId,
    kYouTubeClientSecret,
    kYouTubeOAuthToken,
    kYouTubeOAuthChannel,
    kYouTubeCookie,
    kYouTubeCookieChannel,
  };

  /// 名字里带 Cookie、令牌、密码的设置也算账号，以后新加的不会漏
  static final RegExp _accountKeyName = RegExp(
    r"cookie|token|password|secret|passport",
    caseSensitive: false,
  );

  static bool isAccountKey(String key) =>
      accountKeys.contains(key) || _accountKeyName.hasMatch(key);

  /// 日志里只记校验码的设置：账号和 WebDAV 账号密码
  static Object? _logValue(dynamic key, Object? value) {
    var name = key.toString();
    return isAccountKey(name) || name == kWebDAVUser
        ? LogMask.hide(value)
        : value;
  }

  ///主题色
  static const String kStyleColor = "kStyleColor";

  ///动态取色
  static const String kIsDynamic = "kIsDynamic";

  /// 提示哔哩哔哩登录
  static const String kBilibiliLoginTip = "BilibiliLoginTip";

  /// 日志记录
  static const String kLogEnable = "LogEnable";

  /// 开启自定义播放器视频输出
  static const String kCustomPlayerOutput = "CustomPlayerOutput";

  /// 视频输出驱动
  static const String kVideoOutputDriver = "VideoOutputDriver";

  /// 视频硬件解码器
  static const String kVideoHardwareDecoder = "VideoHardwareDecoder";

  /// 音频输出驱动
  static const String kAudioOutputDriver = "AudioOutputDriver";

  /// 开启自动更新关注
  static const String kAutoUpdateFollowEnable = "AutoUpdateFollowEnable";

  /// 定时自动更新关注间隔（分钟）
  static const String kUpdateFollowDuration = "AutoUpdateFollowDuration";

  /// 开启多线程更新关注
  static const String kUpdateFollowThreadCount = "UpdateFollowThreadCount";

  /// 开播提醒：订阅的直播间开播时发通知
  static const String kLiveNotifyEnable = "LiveNotifyEnable";

  /// 开播提醒多久查一次订阅的直播间（分钟）
  static const String kLiveNotifyInterval = "LiveNotifyInterval";

  /// 关注列表里所有直播间都显示铃铛（关掉时只有开了提醒的显示）
  static const String kLiveNotifyShowBell = "LiveNotifyShowBell";

  /// 直播间里切到“关注”时查哪些主播：all 全部，current 正在看的主播所在的分组，
  /// tag:<分组 id> 一个分组，none 不查
  static const String kLiveRoomFollowCheck = "LiveRoomFollowCheck";

  /// 关注很多时的提示已经出现过（只提示一次）
  static const String kManyFollowsHinted = "ManyFollowsHinted";

  /// WebDAV_服务器地址
  static const String kWebDAVUri = "WebDAVUri";

  /// WebDAV_登录账号
  static const String kWebDAVUser = "WebDAVUser";

  /// WebDAV_登录密码
  static const String kWebDAVPassword = "kWebDAVPassword";

  /// WebDAV_最后一次上传时间
  static const String kWebDAVLastUploadTime = "kWebDAVLastUploadTime";

  /// WebDAV_最后一次备份时间
  static const String kWebDAVLastRecoverTime = "kWebDAVLastRecoverTime";

  /// WebDAV_自动同步开关：启动时比较时间戳、退出时上传。默认关，各设备各自设置
  static const String kWebDAVAutoSync = "WebDAVAutoSync";

  /// WebDAV_自动同步时也同步设置（弹幕大小、播放方式等），默认不同步
  static const String kWebDAVAutoSyncSettings = "WebDAVAutoSyncSettings";

  /// WebDAV_本机存档的时间戳（毫秒）：关注、观看记录等最后一次变化的时间
  static const String kWebDAVDataTime = "WebDAVDataTime";

  /// WebDAV_上次和云端对齐时的时间戳
  static const String kWebDAVSyncedTime = "WebDAVSyncedTime";

  /// WebDAV_上次和云端对齐时云端文件的版本
  static const String kWebDAVRemoteVersion = "WebDAVRemoteVersion";

  /// WebDAV_关掉的同步选项（逗号分隔）
  static const String kWebDAVSyncOff = "WebDAVSyncOff";

  /// WebDAV_上次自动同步的结果
  static const String kWebDAVAutoSyncStatus = "WebDAVAutoSyncStatus";

  /// WebDAV_恢复时遇到的、本版本不认识的附加数据（JSON），打包时原样写回去
  static const String kWebDAVPassThrough = "WebDAVPassThrough";

  /// 直播源：启动时每天检查一次更新
  static const String kLiveSourceAutoCheck = "LiveSourceAutoCheck";

  /// 直播源：上次自动检查更新的时间（毫秒），各设备各自记录
  static const String kLiveSourceLastCheck = "LiveSourceLastCheck";

  /// 录屏接口（OBS 等）：开关、端口、允许局域网访问、局域网访问令牌。
  /// 各设备各自的设置，不同步
  static const String kObsBridgeEnable = "ObsBridgeEnable";
  static const String kObsBridgePort = "ObsBridgePort";
  static const String kObsBridgeLan = "ObsBridgeLan";
  static const String kObsBridgeToken = "ObsBridgeToken";

  /// 直播间“记录弹幕（ASS）”的保存位置（电脑上），空为下载文件夹里的 SimpleLive。不同步
  static const String kDanmakuRecordDir = "DanmakuRecordDir";

  /// 搜索历史（JSON 数组，最多 30 条，新的在前）
  static const String kSearchHistory = "SearchHistory";

  /// 在 App 里关注/取关时同步到账号：每个平台一个开关，默认关闭。
  /// 只在本机，不同步（待同步队列也只在本机，避免两台设备重复回写）
  static const String kFollowWriteBackBiliBili = "FollowWriteBack_bilibili";
  static const String kFollowWriteBackDouyu = "FollowWriteBack_douyu";
  static const String kFollowWriteBackKick = "FollowWriteBack_kick";
  static const String kFollowWriteBackYouTube = "FollowWriteBack_youtube";

  late Box settingsBox;
  late Box<String> shieldBox;

  /// 设置的值真的变了时调用，WebDAV 自动同步用它记录本机存档的时间戳
  void Function(String key)? onSettingChanged;

  Future init() async {
    settingsBox = await Hive.openBox(
      "LocalStorage",
    );
    shieldBox = await Hive.openBox(
      "DanmuShield",
    );
  }

  /// 账号、令牌、Cookie 和 WebDAV 密码在设置里是密文（DeviceSecrets），这里解开；
  /// 原版和旧版本留下的明文原样读出。解不开时返回 [defaultValue]
  T getValue<T>(dynamic key, T defaultValue) {
    try {
      var raw = settingsBox.get(key, defaultValue: defaultValue);
      if (DeviceSecrets.isProtected(raw)) {
        var plain = DeviceSecrets.instance.reveal(raw);
        raw = plain ?? defaultValue;
      }
      var value = raw as T;
      Log.d("Get LocalStorage：$key\r\n${_logValue(key, value)}");
      return value;
    } catch (e) {
      Log.logPrint(e);
      return defaultValue;
    }
  }

  /// 账号、令牌、Cookie 和 WebDAV 密码加密后再存（DeviceSecrets），不写明文；
  /// 设备密钥不可用时不保存
  Future setValue<T>(dynamic key, T value) async {
    Log.d("Set LocalStorage：$key\r\n${_logValue(key, value)}");
    var old = settingsBox.get(key);
    if (DeviceSecrets.isProtected(old)) {
      old = DeviceSecrets.instance.reveal(old);
    }
    var changed = old != value;
    Object? stored = value;
    if (DeviceSecrets.needsProtect(key.toString(), value)) {
      if (!DeviceSecrets.instance.ready) {
        Log.e("设备密钥不可用，没有保存 $key", StackTrace.current);
        return;
      }
      stored = DeviceSecrets.instance.protect(value as String);
    }
    var result = await settingsBox.put(key, stored);
    if (changed) {
      onSettingChanged?.call(key.toString());
    }
    return result;
  }

  /// 整份设置，密文都解开（同步、导出配置、合并时用；账号随后由 SyncVault 加密）
  Map<String, dynamic> plainSettings() =>
      DeviceSecrets.instance.revealSettings(settingsBox.toMap());

  Future removeValue<T>(dynamic key) async {
    Log.d("Remove LocalStorage：$key");
    var changed = settingsBox.containsKey(key);
    await settingsBox.delete(key);
    if (changed) {
      onSettingChanged?.call(key.toString());
    }
  }
}
