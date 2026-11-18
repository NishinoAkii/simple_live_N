import 'package:hive/hive.dart';
import 'package:simple_live_app/app/capture/capture_settings.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/danmaku_filter_settings.dart';
import 'package:simple_live_app/app/controller/follow_view_settings.dart';
import 'package:simple_live_app/app/desktop_shortcuts.dart';
import 'package:simple_live_app/app/gpu_preference.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';
import 'package:simple_live_app/app/window_memory.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/app_update/installers/ios_installer.dart';
import 'package:simple_live_app/services/app_update/update_settings.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/kick_account_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';
import 'package:simple_live_app/services/youtube_account_service.dart';

/// 与官方版之间的同步兼容
///
/// 官方版对平台 id 直接做非空断言（首页平台排序、关注、历史等），
/// 收到 Twitch、Kick、YouTube 的数据会报错甚至无法启动。因此：
/// - 发往官方版（或可能是官方版）的数据只保留官方支持的平台；
/// - 新平台的关注、历史、账号等放在官方版会忽略的扩展部分；
/// - 接收官方版的数据时，保留本地新平台的数据，不被覆盖清空。
///
/// 直播源（.live.js，平台 id 为 js:xxx）同样只在扩展部分；本版本里还不支持
/// 直播源的旧版也不认识它们，只发给声明了 [kScriptSitesWildcard] 的设备，
/// 接收旧版数据时保留本地直播源平台的数据。
class SyncCompat {
  /// 官方版支持的平台
  static const Set<String> upstreamSiteIds = {
    Constant.kBiliBili,
    Constant.kDouyu,
    Constant.kHuya,
    Constant.kDouyin,
  };

  /// LAN 同步 /info 中声明支持扩展数据的字段；官方版没有这个字段
  static const String kInfoExtKey = "extSites";

  /// /info 的 extSites 里声明“接受所有直播源平台（js:*）”。
  /// 直播源由用户安装，对方不一定装了同样的源；支持直播源的版本收到
  /// 没装的平台只会灰色显示，所以按这一项决定是否发送，而不是逐个平台比对
  static const String kScriptSitesWildcard = "${Constant.kScriptSitePrefix}*";

  static bool isUpstreamSite(String siteId) => upstreamSiteIds.contains(siteId);

  /// 直播源（.live.js 脚本）平台，id 形如 js:acfun
  static bool isScriptSite(String siteId) =>
      siteId.startsWith(Constant.kScriptSitePrefix);

  /// 关注 id 形如 js:acfun_123；直播源的 key 里也可能有下划线，只按前缀判断
  static bool isScriptFollowId(String id) =>
      id.startsWith(Constant.kScriptSitePrefix);

  /// 新平台账号（斗鱼、Twitch、Kick、YouTube），不发给官方版。
  /// YouTube 的 OAuth 客户端密钥和令牌与其它账号一样，只在勾选同步账号时恢复
  static const Set<String> extSettingKeys = {
    LocalStorageService.kDouyuCookie,
    LocalStorageService.kDouyuLtp0,
    LocalStorageService.kDouyuPassportDid,
    LocalStorageService.kTwitchToken,
    LocalStorageService.kTwitchLogin,
    LocalStorageService.kTwitchDisplayName,
    LocalStorageService.kKickToken,
    LocalStorageService.kKickUserName,
    LocalStorageService.kYouTubeClientId,
    LocalStorageService.kYouTubeClientSecret,
    LocalStorageService.kYouTubeOAuthToken,
    LocalStorageService.kYouTubeOAuthChannel,
    LocalStorageService.kYouTubeCookie,
    LocalStorageService.kYouTubeCookieChannel,
  };

  /// 其它只有本版本才有的设置（追帧、SC 显示、聊天头像、表情图片、视频信息浮层、分场景弹幕大小、iOS 画中画与投屏）
  static const Set<String> forkSettingKeys = {
    // 多开时各直播间的设置（音量、静音、弹幕开关、清晰度），位置不在这里
    WindowSetRecorder.kRoomSettings,
    LocalStorageService.kLiveCatchUp,
    LocalStorageService.kLiveCatchUpMaxRate,
    LocalStorageService.kLiveCatchUpTarget,
    LocalStorageService.kSuperChatDisplayMode,
    // 聊天栏头像
    LocalStorageService.kChatShowFace,
    // 直播间保留的弹幕条数、聊天区表情动图
    LocalStorageService.kChatKeepLimit,
    LocalStorageService.kChatAnimatedEmotes,
    // 弹幕与聊天栏的表情图片和表情大小
    LocalStorageService.kDanmuEmoteImage,
    // 彩色弹幕、聊天区彩色用户名
    LocalStorageService.kDanmuColorful,
    LocalStorageService.kChatNameColor,
    // 弹幕缓冲增强、聊天区显示牌子
    LocalStorageService.kDanmuBufferBoost,
    LocalStorageService.kDanmuBufferMinRate,
    LocalStorageService.kChatShowBadges,
    LocalStorageService.kDanmuGiftFly,
    // SC 页和礼物页的排序
    LocalStorageService.kNoticeNewestAtBottom,
    LocalStorageService.kChatNewestAtBottom,
    // 直播间的榜单页
    LocalStorageService.kLiveRankTab,
    LocalStorageService.kEmoteSizeSeparate,
    LocalStorageService.kEmoteScale,
    // 播放器视频信息浮层
    LocalStorageService.kPlayerVideoStats,
    // 手机、平板全屏和小窗各自的弹幕大小、速度
    LocalStorageService.kDanmuSizeFullscreen,
    LocalStorageService.kDanmuPipSize,
    LocalStorageService.kDanmuPipSpeed,
    LocalStorageService.kIosPipDanmaku,
    LocalStorageService.kIosPipDanmakuScale,
    LocalStorageService.kIosPipDanmakuLines,
    LocalStorageService.kIosPipFrameRate,
    // 首页、分类、搜索里显示哪些平台
    LocalStorageService.kHiddenSites,
    LocalStorageService.kIosPipQuality,
    LocalStorageService.kIosPipEngine,
    LocalStorageService.kIosPipDanmakuMode,
    LocalStorageService.kIosPipSuperChat,
    LocalStorageService.kIosPipAutoStart,
    LocalStorageService.kIosExternalDisplay,
    LocalStorageService.kIosExternalSidebar,
    LocalStorageService.kLiveSourceAutoCheck,
    // 重复弹幕过滤、各平台的弹幕延迟
    ...DanmakuFilterSettings.storageKeys,
    // 被屏蔽的人发的 SC 和礼物也不显示
    ChatUsersService.kHidePaid,
    // 直播间的快捷键（开关和按键表）
    ...DesktopShortcuts.storageKeys,
    // 截图：图层、范围、截图后、图片信息、全屏按键、视频信息显示的内容
    ...CaptureSettings.syncKeys,
  };

  /// 与屏幕大小有关的界面尺寸（宽屏侧栏宽度），各设备不同，恢复时保留本机值
  static const Set<String> layoutSettingKeys = {
    "LiveSidePanelWidth",
  };

  /// 本版本专用、各设备各自记录的值（如直播源上次自动检查更新的时间），
  /// 不发给官方版，恢复时保留本机值
  static const Set<String> forkDeviceSettingKeys = {
    LocalStorageService.kLiveSourceLastCheck,
  };

  /// 只在本机、完全不进备份的设置：录屏接口（开关、端口、局域网访问与令牌）、
  /// 弹幕记录的保存位置、各平台“同步关注到账号”的开关。官方版和扩展部分都不发，
  /// 恢复时保留本机值（待同步队列在单独的 Hive box 里，本来就不进备份）
  static const Set<String> localOnlySettingKeys = {
    LocalStorageService.kObsBridgeEnable,
    LocalStorageService.kObsBridgePort,
    LocalStorageService.kObsBridgeLan,
    LocalStorageService.kObsBridgeToken,
    LocalStorageService.kDanmakuRecordDir,
    LocalStorageService.kFollowWriteBackBiliBili,
    LocalStorageService.kFollowWriteBackDouyu,
    LocalStorageService.kFollowWriteBackKick,
    LocalStorageService.kFollowWriteBackYouTube,
    // WebDAV 自动同步的开关、时间戳和选项，各设备各自的
    LocalStorageService.kWebDAVAutoSync,
    LocalStorageService.kWebDAVAutoSyncSettings,
    LocalStorageService.kWebDAVDataTime,
    LocalStorageService.kWebDAVSyncedTime,
    LocalStorageService.kWebDAVRemoteVersion,
    LocalStorageService.kWebDAVSyncOff,
    LocalStorageService.kWebDAVAutoSyncStatus,
    LocalStorageService.kWebDAVPassThrough,
    // 记住上次的清晰度、全屏方向
    LocalStorageService.kQualityRemember,
    LocalStorageService.kQualityRememberCellular,
    LocalStorageService.kQualityMemory,
    LocalStorageService.kQualityMemoryCellular,
    LocalStorageService.kFullscreenOrientation,
    // 关注页的分组、排序、样式和折叠了哪些组
    ...FollowViewSettings.storageKeys,
    // 与其他应用同时播放
    LocalStorageService.kPlayWithOthers,
    // 记住窗口（开关、主窗口和小窗的位置）、显卡偏好
    ...WindowMemory.storageKeys,
    // 多开窗口：上次的一组和各主窗口直播间的那一组（直播间、位置）、每个编号的位置和
    // 声音输出设备、启动时要不要打开、新开的默认静音、单独选声音输出设备，各设备屏幕不同
    ...WindowSetRecorder.storageKeys,
    ...MultiWindowPrefs.storageKeys,
    // iOS 更新的安装方式（TrollStore 等），各设备装的工具不同
    IosInstallSetting.kKey,
    ...GpuPreferenceSetting.storageKeys,
    // 聊天区顶上的直播间公告卡片：显示、收起（各设备屏幕大小不同）
    LocalStorageService.kChatNoticeCard,
    LocalStorageService.kChatNoticeFolded,
    // 应用内更新：启动时检查、跳过的版本、下载源
    ...UpdateSettings.storageKeys,
    // 截图的保存位置（电脑上的文件夹，各设备不同）
    ...CaptureSettings.localKeys,
  };

  static bool isLocalOnlySetting(String key) =>
      localOnlySettingKeys.contains(key);

  /// 放在扩展部分、官方版不会读取的设置
  static bool isExtSetting(String key) =>
      extSettingKeys.contains(key) ||
      // 直播间、平台单独的设置
      key.startsWith(LocalStorageService.kRoomSettingsPrefix) ||
      forkSettingKeys.contains(key) ||
      layoutSettingKeys.contains(key) ||
      forkDeviceSettingKeys.contains(key);

  static List<FollowUser> upstreamFollows(Iterable<FollowUser> follows) =>
      follows.where((e) => isUpstreamSite(e.siteId)).toList();

  /// 备份的 ext：自带的新平台。不含直播源平台，它们另放在
  /// [SyncBackupFormat.scriptsKey]（不支持直播源的旧版读 ext 时会出错）
  static List<FollowUser> extFollows(Iterable<FollowUser> follows) => follows
      .where((e) => !isUpstreamSite(e.siteId) && !isScriptSite(e.siteId))
      .toList();

  /// 直播源平台的关注
  static List<FollowUser> scriptFollows(Iterable<FollowUser> follows) =>
      follows.where((e) => isScriptSite(e.siteId)).toList();

  static List<History> upstreamHistories(Iterable<History> histories) =>
      histories.where((e) => isUpstreamSite(e.siteId)).toList();

  /// 规则同 [extFollows]
  static List<History> extHistories(Iterable<History> histories) => histories
      .where((e) => !isUpstreamSite(e.siteId) && !isScriptSite(e.siteId))
      .toList();

  /// 直播源平台的历史
  static List<History> scriptHistories(Iterable<History> histories) =>
      histories.where((e) => isScriptSite(e.siteId)).toList();

  /// 关注的 id 形如 siteId_roomId
  static bool isUpstreamFollowId(String id) {
    var index = id.indexOf('_');
    return index > 0 && isUpstreamSite(id.substring(0, index));
  }

  /// 对方能接收的平台：官方版（[peerExtSites] 为空）只有官方平台，
  /// 本版本还有它在 /info 中声明的新平台。
  /// 本版本的旧版（如还没有 YouTube）收到不认识的平台同样会出错，
  /// 所以按对方声明的平台过滤，而不是对方支持扩展就全部发送。
  /// 直播源平台（js:*）只发给声明了 [kScriptSitesWildcard] 的版本。
  static bool peerSupportsSite(String siteId, Iterable<String> peerExtSites) {
    if (isUpstreamSite(siteId)) {
      return true;
    }
    if (isScriptSite(siteId)) {
      return peerSupportsScripts(peerExtSites);
    }
    return peerExtSites.contains(siteId);
  }

  /// 对方是否支持直播源平台
  static bool peerSupportsScripts(Iterable<String> peerExtSites) =>
      peerExtSites.contains(kScriptSitesWildcard);

  /// 关注 id（siteId_roomId）对应的平台对方是否支持
  static bool peerSupportsFollowId(String id, Iterable<String> peerExtSites) {
    if (isScriptFollowId(id)) {
      return peerSupportsScripts(peerExtSites);
    }
    var index = id.indexOf('_');
    return index > 0 && peerSupportsSite(id.substring(0, index), peerExtSites);
  }

  /// 本机 /info 声明的扩展平台：自带的新平台，加上 [kScriptSitesWildcard]
  static List<String> localExtSites(Iterable<String> builtInSiteIds) => [
        ...builtInSiteIds.where((e) => !isUpstreamSite(e) && !isScriptSite(e)),
        kScriptSitesWildcard,
      ];

  static List<FollowUser> followsForPeer(
          Iterable<FollowUser> follows, Iterable<String> peerExtSites) =>
      follows.where((e) => peerSupportsSite(e.siteId, peerExtSites)).toList();

  static List<History> historiesForPeer(
          Iterable<History> histories, Iterable<String> peerExtSites) =>
      histories.where((e) => peerSupportsSite(e.siteId, peerExtSites)).toList();

  /// 标签中去掉对方不支持的平台的关注
  static List<FollowUserTag> tagsForPeer(
          Iterable<FollowUserTag> tags, Iterable<String> peerExtSites) =>
      tags
          .map((e) => e.copyWith(
                userId: e.userId
                    .where((id) => peerSupportsFollowId(id, peerExtSites))
                    .toList(),
              ))
          .toList();

  /// 标签中去掉新平台关注的 id
  static List<FollowUserTag> upstreamTags(Iterable<FollowUserTag> tags) => tags
      .map((e) => e.copyWith(
            userId: e.userId.where(isUpstreamFollowId).toList(),
          ))
      .toList();

  /// 备份 ext 里的完整标签：去掉直播源平台的关注（另放在 [scriptTagMembers]）
  static List<FollowUserTag> extTags(Iterable<FollowUserTag> tags) => tags
      .map((e) => e.copyWith(
            userId: e.userId.where((id) => !isScriptFollowId(id)).toList(),
          ))
      .toList();

  /// 各标签里直播源平台的关注：标签 id → 关注 id
  static Map<String, List<String>> scriptTagMembers(
      Iterable<FollowUserTag> tags) {
    var result = <String, List<String>>{};
    for (var tag in tags) {
      var ids = tag.userId.where(isScriptFollowId).toList();
      if (ids.isNotEmpty) {
        result[tag.id] = ids;
      }
    }
    return result;
  }

  /// 设置：去掉本版本专用项，平台排序只保留官方支持的平台
  static Map<String, dynamic> upstreamSettings(Map settings) {
    var result = <String, dynamic>{};
    settings.forEach((key, value) {
      var name = key.toString();
      if (isExtSetting(name) || isLocalOnlySetting(name)) {
        return;
      }
      if (name == LocalStorageService.kSiteSort && value is String) {
        value = value.split(',').where(isUpstreamSite).join(',');
      }
      result[name] = value;
    });
    return result;
  }

  /// 设置的扩展部分：本版本专用项（账号等）与平台排序。
  /// 排序里去掉直播源平台：旧版按排序逐个取平台，不认识的会出错
  static Map<String, dynamic> extSettings(Map settings) {
    var result = <String, dynamic>{};
    settings.forEach((key, value) {
      var name = key.toString();
      if (isLocalOnlySetting(name)) {
        return;
      }
      if (name == LocalStorageService.kSiteSort && value is String) {
        value = value.split(',').where((e) => !isScriptSite(e)).join(',');
      }
      if (isExtSetting(name) || name == LocalStorageService.kSiteSort) {
        result[name] = value;
      }
    });
    return result;
  }

  /// 含直播源平台的设置（完整的平台排序），恢复时覆盖 ext 里的同名项
  static Map<String, dynamic> scriptSettings(Map settings) {
    var sort = settings[LocalStorageService.kSiteSort];
    if (sort is String && sort.split(',').any(isScriptSite)) {
      return {LocalStorageService.kSiteSort: sort};
    }
    return {};
  }

  /// 覆盖时是否清掉本地这个平台的数据：
  /// 来自官方版（[includeExt] 为 false）时只清官方平台；
  /// 来自还不支持直播源的本版本旧版（[includeScripts] 为 false）时保留直播源平台
  static bool shouldClearSite(
    String siteId, {
    required bool includeExt,
    bool includeScripts = true,
  }) {
    if (isUpstreamSite(siteId)) {
      return true;
    }
    if (!includeExt) {
      return false;
    }
    return includeScripts || !isScriptSite(siteId);
  }

  /// 覆盖本地关注前清空：来自官方版（[includeExt] 为 false）时保留新平台的关注，
  /// 来自不支持直播源的旧版（[includeScripts] 为 false）时保留直播源平台的关注
  static Future<void> clearFollows({
    required bool includeExt,
    bool includeScripts = true,
  }) async {
    var box = DBService.instance.followBox;
    if (includeExt && includeScripts) {
      await box.clear();
      return;
    }
    var keys = box.values
        .where((e) => shouldClearSite(e.siteId,
            includeExt: includeExt, includeScripts: includeScripts))
        .map((e) => e.id)
        .toList();
    await box.deleteAll(keys);
  }

  /// 覆盖本地历史前清空，规则同 [clearFollows]
  static Future<void> clearHistories({
    required bool includeExt,
    bool includeScripts = true,
  }) async {
    var box = DBService.instance.historyBox;
    if (includeExt && includeScripts) {
      await box.clear();
      return;
    }
    var keys = box.values
        .where((e) => shouldClearSite(e.siteId,
            includeExt: includeExt, includeScripts: includeScripts))
        .map((e) => e.id)
        .toList();
    await box.deleteAll(keys);
  }

  /// 记录各标签中新平台关注的 id，用于接收官方版标签后补回；
  /// [scriptsOnly] 只记录直播源平台的（接收不支持直播源的旧版标签时）
  static Map<String, List<String>> snapshotExtTagMembers({
    bool scriptsOnly = false,
  }) {
    var result = <String, List<String>>{};
    for (var tag in DBService.instance.tagBox.values) {
      var ids = tag.userId
          .where(
              (e) => scriptsOnly ? isScriptFollowId(e) : !isUpstreamFollowId(e))
          .toList();
      if (ids.isNotEmpty) {
        result[tag.id] = ids;
      }
    }
    return result;
  }

  static Future<void> restoreExtTagMembers(
      Map<String, List<String>> snapshot) async {
    var box = DBService.instance.tagBox;
    for (var entry in snapshot.entries) {
      var tag = box.get(entry.key);
      if (tag == null) {
        continue;
      }
      var ids = [...tag.userId];
      for (var id in entry.value) {
        if (!ids.contains(id)) {
          ids.add(id);
        }
      }
      await box.put(tag.id, tag.copyWith(userId: ids));
    }
  }

  /// 恢复设置后重新读取新平台账号
  static void reloadAccounts() {
    TwitchAccountService.instance.reload();
    KickAccountService.instance.reload();
    YouTubeAccountService.instance.reload();
    DouyuAccountService.instance.reload();
  }

  /// 本设备的 WebDAV 连接与同步时间：各设备可能不同（如本机用 localhost），
  /// 恢复时始终保留本地值
  static const Set<String> deviceSettingKeys = {
    LocalStorageService.kWebDAVUri,
    LocalStorageService.kWebDAVUser,
    LocalStorageService.kWebDAVPassword,
    LocalStorageService.kWebDAVLastUploadTime,
    LocalStorageService.kWebDAVLastRecoverTime,
  };

  /// 恢复后的完整设置：备份覆盖本地，但以下保留本机的值——
  /// WebDAV 连接与界面尺寸；备份来自官方版（[ext] 为空）时的本版本专用项；
  /// 没有勾选同步的新平台账号。
  static Map<String, dynamic> mergeRestoredSettings(
    Map local,
    Map<String, dynamic> main,
    Map<String, dynamic>? ext, {
    bool syncAccounts = true,
  }) {
    bool keepLocal(String key) {
      if (deviceSettingKeys.contains(key) ||
          layoutSettingKeys.contains(key) ||
          forkDeviceSettingKeys.contains(key) ||
          isLocalOnlySetting(key)) {
        return true;
      }
      if (ext == null) {
        return isExtSetting(key);
      }
      return !syncAccounts && extSettingKeys.contains(key);
    }

    var result = <String, dynamic>{};
    // 旧版本的备份把部分专用项放在 data 里，同样按规则处理
    for (var source in [main, if (ext != null) ext]) {
      source.forEach((key, value) {
        if (!keepLocal(key)) {
          result[key] = value;
        }
      });
    }
    local.forEach((key, value) {
      var name = key.toString();
      if (keepLocal(name)) {
        result[name] = value;
      }
    });
    return result;
  }

  /// 恢复设置
  ///
  /// [ext] 为空表示备份来自官方版（或不含新平台数据），此时保留本地的本版本专用项。
  static Future<void> restoreSettings(
    Map<String, dynamic> main,
    Map<String, dynamic>? ext, {
    bool syncAccounts = true,
  }) async {
    var box = LocalStorageService.instance.settingsBox;
    var merged = mergeRestoredSettings(
      box.toMap(),
      main,
      ext,
      syncAccounts: syncAccounts,
    );
    await _replaceSettings(box, merged);
  }

  /// 先写后删，不留“设置全空”的空档：自动同步时 App 正在运行，这时读到的就是默认值
  static Future<void> _replaceSettings(
    Box box,
    Map<String, dynamic> merged,
  ) async {
    await box.putAll(merged);
    await box.deleteAll(
      box.keys.where((key) => !merged.containsKey(key)).toList(),
    );
  }

  /// 自动同步时当作账号处理的设置（哔哩哔哩的单独按 [syncBilibili]）
  static const Set<String> autoAccountKeys = {
    ...extSettingKeys,
    LocalStorageService.kDouyinCookie,
  };

  /// 这个设置变了，算不算本机存档变了（要不要更新时间戳、退出时上传）
  static bool isAutoSyncedSetting(String key, {required bool syncSettings}) {
    if (deviceSettingKeys.contains(key) ||
        layoutSettingKeys.contains(key) ||
        forkDeviceSettingKeys.contains(key) ||
        isLocalOnlySetting(key)) {
      return false;
    }
    if (autoAccountKeys.contains(key) ||
        key == LocalStorageService.kBilibiliCookie) {
      return true;
    }
    return syncSettings;
  }

  /// 自动同步后的完整设置。和手动恢复（[mergeRestoredSettings]）的不同：
  /// - 弹幕大小这些设置手机和电脑常常不一样，[syncSettings] 关着时保留本机的；
  /// - 账号只在云端有值时才用云端的。一台设备没登录，它的备份里就没有这个账号，
  ///   不能因为拉取了它的存档，这台设备就退出登录。
  static Map<String, dynamic> mergeAutoSettings(
    Map local,
    Map<String, dynamic> main,
    Map<String, dynamic>? ext, {
    required bool syncSettings,
    required bool syncAccounts,
    required bool syncBilibili,
  }) {
    var result = syncSettings
        ? mergeRestoredSettings(
            local,
            main,
            ext,
            syncAccounts: syncAccounts,
          )
        : <String, dynamic>{
            for (var entry in local.entries) entry.key.toString(): entry.value,
          };
    var backup = {...main, ...?ext};
    void account(String key, bool sync) {
      var value = backup[key];
      if (sync && value != null && value != "") {
        result[key] = value;
      } else if (local.containsKey(key)) {
        result[key] = local[key];
      } else {
        result.remove(key);
      }
    }

    for (var key in autoAccountKeys) {
      account(key, syncAccounts);
    }
    account(LocalStorageService.kBilibiliCookie, syncBilibili);
    return result;
  }

  /// 自动同步写入设置，返回账号有没有变（变了才需要重新读取账号）
  static Future<bool> restoreAutoSettings(
    Map<String, dynamic> main,
    Map<String, dynamic>? ext, {
    required bool syncSettings,
    required bool syncAccounts,
    required bool syncBilibili,
  }) async {
    var box = LocalStorageService.instance.settingsBox;
    var local = box.toMap();
    var merged = mergeAutoSettings(
      local,
      main,
      ext,
      syncSettings: syncSettings,
      syncAccounts: syncAccounts,
      syncBilibili: syncBilibili,
    );
    await _replaceSettings(box, merged);
    return autoAccountKeys.any((key) => local[key] != merged[key]);
  }
}
