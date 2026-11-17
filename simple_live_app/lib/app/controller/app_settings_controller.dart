import 'dart:convert';
import 'dart:io';

import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/danmaku_filter_settings.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 弹幕显示在哪里：非全屏、全屏、小窗（画中画）
enum DanmakuViewMode { normal, fullscreen, pip }

class AppSettingsController extends GetxController
    with DanmakuFilterSettings {
  static AppSettingsController get instance =>
      Get.find<AppSettingsController>();

  /// 缩放模式
  var scaleMode = 0.obs;

  var themeMode = 0.obs;

  var firstRun = false;

  @override
  void onInit() {
    themeMode.value = LocalStorageService.instance
        .getValue(LocalStorageService.kThemeMode, 0);
    firstRun = LocalStorageService.instance
        .getValue(LocalStorageService.kFirstRun, true);
    danmuSize.value = LocalStorageService.instance
        .getValue(LocalStorageService.kDanmuSize, 16.0);
    danmuOpacity.value = LocalStorageService.instance
        .getValue(LocalStorageService.kDanmuOpacity, 1.0);
    danmuArea.value = LocalStorageService.instance
        .getValue(LocalStorageService.kDanmuArea, 0.8);
    danmuSpeed.value = LocalStorageService.instance
        .getValue(LocalStorageService.kDanmuSpeed, 10.0);
    danmuEnable.value = LocalStorageService.instance
        .getValue(LocalStorageService.kDanmuEnable, true);
    danmuStrokeWidth.value = LocalStorageService.instance
        .getValue(LocalStorageService.kDanmuStrokeWidth, 2.0);
    danmuTopMargin.value = LocalStorageService.instance
        .getValue(LocalStorageService.kDanmuTopMargin, 0.0);
    danmuBottomMargin.value = LocalStorageService.instance
        .getValue(LocalStorageService.kDanmuBottomMargin, 0.0);
    danmuFontWeight.value = LocalStorageService.instance
        .getValue(LocalStorageService.kDanmuFontWeight, 4);
    danmuEmoteImage.value = LocalStorageService.instance
        .getValue(LocalStorageService.kDanmuEmoteImage, true);
    danmuColorful.value = LocalStorageService.instance
        .getValue(LocalStorageService.kDanmuColorful, false);
    danmuBufferBoost.value = LocalStorageService.instance
        .getValue(LocalStorageService.kDanmuBufferBoost, true);
    danmuBufferMinRate.value = LocalStorageService.instance.getValue(
      LocalStorageService.kDanmuBufferMinRate,
      kDefaultDanmuBufferMinRate,
    );
    // 重复弹幕过滤、弹幕延迟（见 DanmakuFilterSettings）
    loadDanmakuFilterSettings();
    chatShowBadges.value = LocalStorageService.instance
        .getValue(LocalStorageService.kChatShowBadges, false);
    danmuGiftFly.value = LocalStorageService.instance
        .getValue(LocalStorageService.kDanmuGiftFly, true);
    noticeNewestAtBottom.value = LocalStorageService.instance
        .getValue(LocalStorageService.kNoticeNewestAtBottom, true);
    liveRankTab.value = LocalStorageService.instance
        .getValue(LocalStorageService.kLiveRankTab, true);
    chatNewestAtBottom.value = LocalStorageService.instance
        .getValue(LocalStorageService.kChatNewestAtBottom, true);
    chatNoticeCard.value = LocalStorageService.instance
        .getValue(LocalStorageService.kChatNoticeCard, true);
    chatNoticeFolded.value = LocalStorageService.instance
        .getValue(LocalStorageService.kChatNoticeFolded, false);

    hardwareDecode.value = LocalStorageService.instance
        .getValue(LocalStorageService.kHardwareDecode, true);
    chatTextSize.value = LocalStorageService.instance
        .getValue(LocalStorageService.kChatTextSize, 14.0);
    emoteSizeSeparate.value = LocalStorageService.instance
        .getValue(LocalStorageService.kEmoteSizeSeparate, false);
    emoteScale.value = LocalStorageService.instance
        .getValue(LocalStorageService.kEmoteScale, 1.0);

    chatTextGap.value = LocalStorageService.instance
        .getValue(LocalStorageService.kChatTextGap, 4.0);

    chatBubbleStyle.value = LocalStorageService.instance.getValue(
      LocalStorageService.kChatBubbleStyle,
      false,
    );
    chatNameColor.value = LocalStorageService.instance
        .getValue(LocalStorageService.kChatNameColor, true);
    chatKeepLimit.value = LocalStorageService.instance
        .getValue(LocalStorageService.kChatKeepLimit, kDefaultChatKeepLimit);
    chatShowFace.value = LocalStorageService.instance
        .getValue(LocalStorageService.kChatShowFace, true);
    chatAnimatedEmotes.value = LocalStorageService.instance
        .getValue(LocalStorageService.kChatAnimatedEmotes, false);

    qualityLevel.value = LocalStorageService.instance
        .getValue(LocalStorageService.kQualityLevel, 1);
    qualityLevelCellular.value = LocalStorageService.instance
        .getValue(LocalStorageService.kQualityLevelCellular, 1);

    autoExitEnable.value = LocalStorageService.instance
        .getValue(LocalStorageService.kAutoExitEnable, false);

    autoExitDuration.value = LocalStorageService.instance
        .getValue(LocalStorageService.kAutoExitDuration, 60);

    roomAutoExitDuration.value = LocalStorageService.instance
        .getValue(LocalStorageService.kRoomAutoExitDuration, 60);

    playerCompatMode.value = LocalStorageService.instance
        .getValue(LocalStorageService.kPlayerCompatMode, false);

    playerAutoPause.value = LocalStorageService.instance
        .getValue(LocalStorageService.kPlayerAutoPause, false);

    playWithOthers.value = LocalStorageService.instance
        .getValue(LocalStorageService.kPlayWithOthers, false);

    playerForceHttps.value = LocalStorageService.instance
        .getValue(LocalStorageService.kPlayerForceHttps, false);

    autoFullScreen.value = LocalStorageService.instance
        .getValue(LocalStorageService.kAutoFullScreen, false);

    playerVideoStats.value = LocalStorageService.instance
        .getValue(LocalStorageService.kPlayerVideoStats, false);

    // ignore: invalid_use_of_protected_member
    shieldList.value = LocalStorageService.instance.shieldBox.values.toSet();

    scaleMode.value = LocalStorageService.instance.getValue(
      LocalStorageService.kPlayerScaleMode,
      0,
    );

    playerVolume.value = LocalStorageService.instance.getValue(
      LocalStorageService.kPlayerVolume,
      100.0,
    );
    pipHideDanmu.value = LocalStorageService.instance
        .getValue(LocalStorageService.kPIPHideDanmu, true);

    superChatDisplayMode.value = LocalStorageService.instance
        .getValue(LocalStorageService.kSuperChatDisplayMode, 0);
    liveCatchUp.value = LocalStorageService.instance
        .getValue(LocalStorageService.kLiveCatchUp, false);
    liveCatchUpMaxRate.value = LocalStorageService.instance
        .getValue(LocalStorageService.kLiveCatchUpMaxRate, 1.5);
    liveCatchUpTarget.value = LocalStorageService.instance
        .getValue(LocalStorageService.kLiveCatchUpTarget, 2.0);
    iosPipDanmaku.value = LocalStorageService.instance
        .getValue(LocalStorageService.kIosPipDanmaku, true);
    iosPipDanmakuScale.value = LocalStorageService.instance
        .getValue(LocalStorageService.kIosPipDanmakuScale, 1.0);
    initDanmakuModes();
    iosPipDanmakuLines.value = LocalStorageService.instance
        .getValue(LocalStorageService.kIosPipDanmakuLines, 3);
    iosPipFrameRate.value = LocalStorageService.instance
        .getValue(LocalStorageService.kIosPipFrameRate, 60);
    iosPipQuality.value = LocalStorageService.instance
        .getValue(LocalStorageService.kIosPipQuality, 540);
    iosPipEngine.value = LocalStorageService.instance
        .getValue(LocalStorageService.kIosPipEngine, 0);
    iosPipDanmakuMode.value = LocalStorageService.instance
        .getValue(LocalStorageService.kIosPipDanmakuMode, 0);
    iosPipSuperChat.value = LocalStorageService.instance
        .getValue(LocalStorageService.kIosPipSuperChat, true);
    iosPipAutoStart.value = LocalStorageService.instance
        .getValue(LocalStorageService.kIosPipAutoStart, false);
    iosExternalDisplay.value = LocalStorageService.instance
        .getValue(LocalStorageService.kIosExternalDisplay, true);
    iosExternalSidebar.value = LocalStorageService.instance
        .getValue(LocalStorageService.kIosExternalSidebar, false);

    styleColor.value = LocalStorageService.instance
        .getValue(LocalStorageService.kStyleColor, 0xff3498db);

    isDynamic.value = LocalStorageService.instance
        .getValue(LocalStorageService.kIsDynamic, false);

    bilibiliLoginTip.value = LocalStorageService.instance
        .getValue(LocalStorageService.kBilibiliLoginTip, true);

    playerBufferSize.value = LocalStorageService.instance
        .getValue(LocalStorageService.kPlayerBufferSize, 32);

    logEnable.value = LocalStorageService.instance
        .getValue(LocalStorageService.kLogEnable, false);
    if (logEnable.value) {
      Log.initWriter();
    }

    customPlayerOutput.value = LocalStorageService.instance
        .getValue(LocalStorageService.kCustomPlayerOutput, false);

    videoOutputDriver.value = LocalStorageService.instance.getValue(
      LocalStorageService.kVideoOutputDriver,
      Platform.isAndroid ? "gpu" : "libmpv",
    );

    audioOutputDriver.value = LocalStorageService.instance.getValue(
      LocalStorageService.kAudioOutputDriver,
      Platform.isAndroid
          ? "audiotrack"
          : Platform.isLinux
              ? "pulse"
              : Platform.isWindows
                  ? "wasapi"
                  : Platform.isIOS
                      ? "audiounit"
                      : Platform.isMacOS
                          ? "coreaudio"
                          : "sdl",
    );

    videoHardwareDecoder.value = LocalStorageService.instance.getValue(
      LocalStorageService.kVideoHardwareDecoder,
      Platform.isAndroid ? "auto-safe" : "auto",
    );

    autoUpdateFollowEnable.value = LocalStorageService.instance
        .getValue(LocalStorageService.kAutoUpdateFollowEnable, true);

    autoUpdateFollowDuration.value = LocalStorageService.instance
        .getValue(LocalStorageService.kUpdateFollowDuration, 10);

    updateFollowThreadCount.value = LocalStorageService.instance
        .getValue(LocalStorageService.kUpdateFollowThreadCount, 0); // 默认 0 = 自动

    liveNotifyEnable.value = LocalStorageService.instance
        .getValue(LocalStorageService.kLiveNotifyEnable, true);
    liveNotifyInterval.value = LocalStorageService.instance
        .getValue(LocalStorageService.kLiveNotifyInterval, 3);
    liveNotifyShowBell.value = LocalStorageService.instance
        .getValue(LocalStorageService.kLiveNotifyShowBell, false);
    liveRoomFollowCheck.value = LocalStorageService.instance
        .getValue(LocalStorageService.kLiveRoomFollowCheck, "all");
    manyFollowsHinted.value = LocalStorageService.instance
        .getValue(LocalStorageService.kManyFollowsHinted, false);

    initHiddenSites();
    initSiteSort();
    initHomeSort();

    super.onInit();
  }

  void initSiteSort() {
    var sort = LocalStorageService.instance
        .getValue(
          LocalStorageService.kSiteSort,
          Sites.allSites.keys.join(","),
        )
        .split(",")
        .where((e) => e.isNotEmpty)
        .toList();
    // 将缺失的平台添加上。排序里可能有已删除的直播源（js:xxx），
    // 数量相同不代表没有缺失，逐个检查
    var keys = Sites.allSites.keys.toList();
    for (var i = 0; i < keys.length; i++) {
      if (!sort.contains(keys[i])) {
        sort.add(keys[i]);
      }
    }

    siteSort.value = sort;
  }

  void initHomeSort() {
    var sort = LocalStorageService.instance
        .getValue(
          LocalStorageService.kHomeSort,
          Constant.allHomePages.keys.join(","),
        )
        .split(",");
    //如果数量与allSites的数量不一致，将缺失的添加上
    if (sort.length != Constant.allHomePages.length) {
      var keys = Constant.allHomePages.keys.toList();
      for (var i = 0; i < keys.length; i++) {
        if (!sort.contains(keys[i])) {
          sort.add(keys[i]);
        }
      }
    }

    homeSort.value = sort;
  }

  void setNoFirstRun() {
    LocalStorageService.instance.setValue(LocalStorageService.kFirstRun, false);
  }

  void changeTheme() {
    Get.dialog(
      RadioGroup(
        groupValue: themeMode.value,
        onChanged: (e) {
          Get.back();
          setTheme(e ?? 0);
        },
        child: SimpleDialog(
          title: Text("选择主题".t),
          children: [
            RadioListTile<int>(
              title: Text("跟随系统".t),
              value: 0,
            ),
            RadioListTile<int>(
              title: Text("浅色模式".t),
              value: 1,
            ),
            RadioListTile<int>(
              title: Text("深色模式".t),
              value: 2,
            ),
          ],
        ),
      ),
    );
  }

  void setTheme(int i) {
    themeMode.value = i;
    var mode = ThemeMode.values[i];

    LocalStorageService.instance.setValue(LocalStorageService.kThemeMode, i);
    Get.changeThemeMode(mode);
  }

  var hardwareDecode = true.obs;
  void setHardwareDecode(bool e) {
    hardwareDecode.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kHardwareDecode, e);
  }

  var chatTextSize = 14.0.obs;
  void setChatTextSize(double e) {
    chatTextSize.value = e;
    _saveScoped(LocalStorageService.kChatTextSize, e);
  }

  /// 单独调整表情图片大小；关闭时表情随文字大小一起变化
  var emoteSizeSeparate = false.obs;
  void setEmoteSizeSeparate(bool e) {
    emoteSizeSeparate.value = e;
    _saveScoped(LocalStorageService.kEmoteSizeSeparate, e);
  }

  /// 表情图片大小（相对文字大小，0.5~3.0 倍），视频弹幕和聊天栏都适用
  var emoteScale = 1.0.obs;
  void setEmoteScale(double e) {
    var value = (e.clamp(0.5, 3.0) * 10).round() / 10;
    emoteScale.value = value;
    _saveScoped(LocalStorageService.kEmoteScale, value);
  }

  /// 实际使用的表情大小：没有单独调整时为 1
  double get effectiveEmoteScale =>
      emoteSizeSeparate.value ? emoteScale.value : 1.0;

  var chatTextGap = 4.0.obs;
  void setChatTextGap(double e) {
    chatTextGap.value = e;
    _saveScoped(LocalStorageService.kChatTextGap, e);
  }

  var chatBubbleStyle = false.obs;
  void setChatBubbleStyle(bool e) {
    chatBubbleStyle.value = e;
    _saveScoped(LocalStorageService.kChatBubbleStyle, e);
  }

  /// 聊天区的用户名用发言人自己的颜色（Twitch、Kick），关掉时为灰色
  var chatNameColor = true.obs;
  void setChatNameColor(bool e) {
    chatNameColor.value = e;
    _saveScoped(LocalStorageService.kChatNameColor, e);
  }

  /// 直播间最多保留的弹幕条数（0 为不限），超出后丢掉最早的
  static const int kDefaultChatKeepLimit = 100000;
  static const List<int> chatKeepLimitOptions = [
    10000,
    50000,
    100000,
    300000,
    0,
  ];
  var chatKeepLimit = kDefaultChatKeepLimit.obs;
  void setChatKeepLimit(int e) {
    chatKeepLimit.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kChatKeepLimit, e);
  }

  /// 聊天栏在名字前显示头像（只有部分平台提供头像，如 YouTube）
  var chatShowFace = true.obs;
  void setChatShowFace(bool e) {
    chatShowFace.value = e;
    LocalStorageService.instance.setValue(LocalStorageService.kChatShowFace, e);
  }

  /// 聊天区的表情播放动图。默认关：只显示第一帧，和视频弹幕一样。
  /// 动图按原图大小解码、一直在播，聊天刷得快时很占 CPU 和内存
  var chatAnimatedEmotes = false.obs;
  void setChatAnimatedEmotes(bool e) {
    chatAnimatedEmotes.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kChatAnimatedEmotes, e);
  }

  var danmuSize = 16.0.obs;
  void setDanmuSize(double e) {
    danmuSize.value = e;
    _saveScoped(LocalStorageService.kDanmuSize, e);
  }

  var danmuSpeed = 10.0.obs;
  void setDanmuSpeed(double e) {
    danmuSpeed.value = e;
    _saveScoped(LocalStorageService.kDanmuSpeed, e);
  }

  /// 手机、平板上非全屏、全屏、小窗（画中画）各用一套弹幕大小，小窗还有自己的速度；
  /// 桌面只有一套
  static bool get danmakuPerMode =>
      debugDanmakuPerMode ?? (Platform.isAndroid || Platform.isIOS);

  /// 测试里按手机、平板的方式运行
  @visibleForTesting
  static bool? debugDanmakuPerMode;

  /// 全屏时的弹幕大小（非全屏用 [danmuSize]）
  var danmuSizeFullscreen = 16.0.obs;
  void setDanmuSizeFullscreen(double e) {
    danmuSizeFullscreen.value = e;
    _saveScoped(LocalStorageService.kDanmuSizeFullscreen, e);
  }

  /// 小窗（画中画）的弹幕大小
  var danmuPipSize = 16.0.obs;
  void setDanmuPipSize(double e) {
    danmuPipSize.value = e;
    _saveScoped(LocalStorageService.kDanmuPipSize, e);
  }

  /// 小窗（画中画）的弹幕滚动时间（秒）
  var danmuPipSpeed = 10.0.obs;
  void setDanmuPipSpeed(double e) {
    danmuPipSpeed.value = e;
    _saveScoped(LocalStorageService.kDanmuPipSpeed, e);
  }

  /// 第一次用时全屏、小窗沿用原来的大小和速度（iOS 小窗按原来的“画中画弹幕大小”
  /// 倍数换算），并存下来，之后各管各的。桌面不存，免得同步到手机时盖掉手机上的设置
  @visibleForTesting
  void initDanmakuModes() {
    var storage = LocalStorageService.instance;
    double load(String key, double initial) {
      var value = storage.getValue<double?>(key, null);
      if (value != null) return value;
      if (danmakuPerMode) storage.setValue(key, initial);
      return initial;
    }

    danmuSizeFullscreen.value =
        load(LocalStorageService.kDanmuSizeFullscreen, danmuSize.value);
    var pipScale = Platform.isIOS ? iosPipDanmakuScale.value : 1.0;
    danmuPipSize.value = load(
      LocalStorageService.kDanmuPipSize,
      (danmuSize.value * pipScale).roundToDouble().clamp(8.0, 48.0),
    );
    danmuPipSpeed.value =
        load(LocalStorageService.kDanmuPipSpeed, danmuSpeed.value);
  }

  /// 弹幕在 [mode] 下的大小
  double danmuSizeFor(DanmakuViewMode mode) {
    if (!danmakuPerMode) return danmuSize.value;
    return switch (mode) {
      DanmakuViewMode.normal => danmuSize.value,
      DanmakuViewMode.fullscreen => danmuSizeFullscreen.value,
      DanmakuViewMode.pip => danmuPipSize.value,
    };
  }

  /// 弹幕在 [mode] 下的滚动时间（秒）；非全屏和全屏共用一个
  int danmuSpeedFor(DanmakuViewMode mode) {
    if (danmakuPerMode && mode == DanmakuViewMode.pip) {
      return danmuPipSpeed.value.toInt();
    }
    return danmuSpeed.value.toInt();
  }

  /// 各种显示方式里最大的弹幕大小（表情图片按它解码，全屏时也清晰）
  double get danmuSizeMax {
    if (!danmakuPerMode) return danmuSize.value;
    return [danmuSize.value, danmuSizeFullscreen.value, danmuPipSize.value]
        .reduce((a, b) => a > b ? a : b);
  }

  var danmuArea = 0.8.obs;
  void setDanmuArea(double e) {
    danmuArea.value = e;
    _saveScoped(LocalStorageService.kDanmuArea, e);
  }

  var danmuOpacity = 1.0.obs;
  void setDanmuOpacity(double e) {
    danmuOpacity.value = e;
    _saveScoped(LocalStorageService.kDanmuOpacity, e);
  }

  var danmuEnable = true.obs;
  void setDanmuEnable(bool e) {
    danmuEnable.value = e;
    _saveScoped(LocalStorageService.kDanmuEnable, e);
  }

  var danmuStrokeWidth = 2.0.obs;
  void setDanmuStrokeWidth(double e) {
    danmuStrokeWidth.value = e;
    _saveScoped(LocalStorageService.kDanmuStrokeWidth, e);
  }

  var danmuFontWeight = 4.obs;
  void setDanmuFontWeight(int e) {
    danmuFontWeight.value = e;
    _saveScoped(LocalStorageService.kDanmuFontWeight, e);
  }

  /// 弹幕和聊天栏把表情显示为图片，关闭后显示为文字（如“[doge]”）
  var danmuEmoteImage = true.obs;
  void setDanmuEmoteImage(bool e) {
    danmuEmoteImage.value = e;
    _saveScoped(LocalStorageService.kDanmuEmoteImage, e);
  }

  /// 视频上的弹幕用平台给的颜色；默认关，全部为白色
  var danmuColorful = false.obs;
  void setDanmuColorful(bool e) {
    danmuColorful.value = e;
    _saveScoped(LocalStorageService.kDanmuColorful, e);
  }

  /// 弹幕缓冲增强：平台一阵一阵发弹幕时先攒一会儿再匀速放出，不断流；
  /// 关掉后到了就放（见 DanmakuPacer）
  var danmuBufferBoost = true.obs;
  void setDanmuBufferBoost(bool e) {
    danmuBufferBoost.value = e;
    _saveScoped(LocalStorageService.kDanmuBufferBoost, e);
  }

  /// 缓冲增强的起始弹幕量：平均每秒少于这么多条时不缓冲，到了就放
  static const int kDefaultDanmuBufferMinRate = 2;
  var danmuBufferMinRate = kDefaultDanmuBufferMinRate.obs;
  void setDanmuBufferMinRate(int e) {
    danmuBufferMinRate.value = e;
    _saveScoped(LocalStorageService.kDanmuBufferMinRate, e);
  }

  /// 聊天区的名字前面显示粉丝牌、舰长等
  var chatShowBadges = false.obs;
  void setChatShowBadges(bool e) {
    chatShowBadges.value = e;
    _saveScoped(LocalStorageService.kChatShowBadges, e);
  }

  /// 付费礼物在视频左下角弹出（和 SC 共用位置，不进弹幕；礼物页照常记录全部礼物）
  var danmuGiftFly = true.obs;
  void setDanmuGiftFly(bool e) {
    danmuGiftFly.value = e;
    _saveScoped(LocalStorageService.kDanmuGiftFly, e);
  }

  /// SC 页和礼物页最新的在下面（和弹幕一样），关掉时在上面
  var noticeNewestAtBottom = true.obs;
  void setNoticeNewestAtBottom(bool e) {
    noticeNewestAtBottom.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kNoticeNewestAtBottom, e);
  }

  /// 聊天（弹幕）列表最新的在下面，关掉时在上面
  var chatNewestAtBottom = true.obs;
  void setChatNewestAtBottom(bool e) {
    chatNewestAtBottom.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kChatNewestAtBottom, e);
  }

  /// 聊天区顶上显示直播间公告卡片（标题、公告、时间）；只存本机
  var chatNoticeCard = true.obs;
  void setChatNoticeCard(bool e) {
    chatNoticeCard.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kChatNoticeCard, e);
  }

  /// 公告卡片收起成小条（只剩标题和时间）；只存本机
  var chatNoticeFolded = false.obs;
  void setChatNoticeFolded(bool e) {
    chatNoticeFolded.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kChatNoticeFolded, e);
  }

  // ---------------- 直播间、平台单独的设置 ----------------
  //
  // 和 Venera 的“本漫画特定设置”一样：在直播间里打开
  // “这个直播间单独设置”（或“这个平台单独设置”）后，调的设置只记到它名下：
  // 弹幕、聊天区、追帧、视频信息、画面尺寸、关键词屏蔽、定时关闭都算。
  // 没调过的项沿用平台的、再沿用全局的。关掉开关后记下的值还在，再打开就回来；
  // “清除”才删掉。所有平台（包括直播源）都一样。设置页里调的始终是全局

  /// 正在看的直播间、平台的名字，没有时为空（这时不显示两个开关）
  var specificRoomLabel = "".obs;
  var specificSiteLabel = "".obs;

  /// 这个直播间、这个平台单独设置的开关
  var roomSpecific = false.obs;
  var siteSpecific = false.obs;

  /// 单独设置里已经记下了值（显示“清除”按钮）
  var roomSpecificHasValues = false.obs;
  var siteSpecificHasValues = false.obs;

  /// 可以单独设置的项：存储键 → (当前值, 全局也没有时的默认值)。
  /// 按顺序读（全屏、小窗的大小和速度默认跟着前面的大小和速度）
  late final Map<String, (Rx<dynamic>, Object Function())> _scoped = {
    LocalStorageService.kDanmuSize: (danmuSize, () => 16.0),
    LocalStorageService.kDanmuSpeed: (danmuSpeed, () => 10.0),
    LocalStorageService.kDanmuArea: (danmuArea, () => 0.8),
    LocalStorageService.kDanmuOpacity: (danmuOpacity, () => 1.0),
    LocalStorageService.kDanmuStrokeWidth: (danmuStrokeWidth, () => 2.0),
    LocalStorageService.kDanmuFontWeight: (danmuFontWeight, () => 4),
    LocalStorageService.kDanmuTopMargin: (danmuTopMargin, () => 0.0),
    LocalStorageService.kDanmuBottomMargin: (danmuBottomMargin, () => 0.0),
    LocalStorageService.kDanmuSizeFullscreen: (
      danmuSizeFullscreen,
      () => danmuSize.value,
    ),
    LocalStorageService.kDanmuPipSize: (danmuPipSize, () => danmuSize.value),
    LocalStorageService.kDanmuPipSpeed: (danmuPipSpeed, () => danmuSpeed.value),
    LocalStorageService.kDanmuEnable: (danmuEnable, () => true),
    LocalStorageService.kDanmuEmoteImage: (danmuEmoteImage, () => true),
    LocalStorageService.kEmoteSizeSeparate: (emoteSizeSeparate, () => false),
    LocalStorageService.kEmoteScale: (emoteScale, () => 1.0),
    LocalStorageService.kDanmuColorful: (danmuColorful, () => false),
    LocalStorageService.kDanmuBufferBoost: (danmuBufferBoost, () => true),
    LocalStorageService.kDanmuBufferMinRate: (
      danmuBufferMinRate,
      () => kDefaultDanmuBufferMinRate
    ),
    LocalStorageService.kChatShowBadges: (chatShowBadges, () => false),
    LocalStorageService.kDanmuGiftFly: (danmuGiftFly, () => true),
    LocalStorageService.kChatTextSize: (chatTextSize, () => 14.0),
    LocalStorageService.kChatTextGap: (chatTextGap, () => 4.0),
    LocalStorageService.kChatBubbleStyle: (chatBubbleStyle, () => false),
    LocalStorageService.kChatNameColor: (chatNameColor, () => true),
    LocalStorageService.kPlayerShowSuperChat: (playershowSuperChat, () => true),
    LocalStorageService.kPlayerVideoStats: (playerVideoStats, () => false),
    LocalStorageService.kLiveCatchUp: (liveCatchUp, () => false),
    LocalStorageService.kLiveCatchUpMaxRate: (liveCatchUpMaxRate, () => 1.5),
    LocalStorageService.kLiveCatchUpTarget: (liveCatchUpTarget, () => 2.0),
    LocalStorageService.kPlayerScaleMode: (scaleMode, () => 0),
    LocalStorageService.kRoomAutoExitDuration: (
      roomAutoExitDuration,
      () => 60,
    ),
    LocalStorageService.kRoomAutoExitEnable: (roomAutoExitEnable, () => false),
    ...danmakuFilterScoped,
  };

  /// 单独设置里关键词屏蔽的字段名
  static const String _shieldField = "ShieldList";

  /// 可以单独设置的项的存储键（测试、说明用）
  List<String> get scopedSettingKeys => [..._scoped.keys, _shieldField];

  /// 打开的直播间、设置页（后打开的在后面，用最后一个）
  final List<RoomContext> _roomContexts = [];

  /// 正在看的直播间；最后打开的是设置页（全局）时为 null
  RoomContext? get _roomContext {
    var last = _roomContexts.isEmpty ? null : _roomContexts.last;
    return last == null || last.isGlobal ? null : last;
  }

  /// 直播间那一份的存储键
  static String roomSettingsKey(RoomContext context) =>
      "${LocalStorageService.kRoomSettingsPrefix}room:${context.siteId}_${context.roomId}";

  /// 平台那一份的存储键
  static String siteSettingsKey(RoomContext context) =>
      "${LocalStorageService.kRoomSettingsPrefix}site:${context.siteId}";

  /// 进直播间或设置页时调用：有单独设置时换成它
  void enterRoomContext(RoomContext context) {
    _roomContexts.removeWhere((e) => e.id == context.id);
    _roomContexts.add(context);
    _applyScoped();
  }

  /// 离开时调用：回到上一个打开的，或者全局设置
  void leaveRoomContext(String id) {
    _roomContexts.removeWhere((e) => e.id == id);
    _applyScoped();
  }

  void setRoomSpecific(bool e) => _setSpecific(
        _roomContext == null ? null : roomSettingsKey(_roomContext!),
        e,
      );

  void setSiteSpecific(bool e) => _setSpecific(
        _roomContext == null ? null : siteSettingsKey(_roomContext!),
        e,
      );

  /// 清除这个直播间（或平台）的单独设置
  void clearRoomSpecific() => _clearSpecific(
      _roomContext == null ? null : roomSettingsKey(_roomContext!));

  void clearSiteSpecific() => _clearSpecific(
      _roomContext == null ? null : siteSettingsKey(_roomContext!));

  void _setSpecific(String? key, bool enabled) {
    if (key == null) {
      return;
    }
    var profile = _readScoped(key)..["enabled"] = enabled;
    LocalStorageService.instance.setValue(key, json.encode(profile));
    _applyScoped();
  }

  void _clearSpecific(String? key) {
    if (key == null) {
      return;
    }
    LocalStorageService.instance.settingsBox.delete(key);
    _applyScoped();
  }

  Map<String, dynamic> _readScoped(String? key) {
    if (key == null) {
      return {};
    }
    var raw = LocalStorageService.instance.getValue<String>(key, "");
    if (raw.isEmpty) {
      return {};
    }
    try {
      return Map<String, dynamic>.from(json.decode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  /// 调的设置记到哪一份：直播间开着记到直播间，否则平台开着记到平台，否则全局（null）
  String? get _scopedWriteKey {
    var context = _roomContext;
    if (context == null) {
      return null;
    }
    if (roomSpecific.value) {
      return roomSettingsKey(context);
    }
    if (siteSpecific.value) {
      return siteSettingsKey(context);
    }
    return null;
  }

  void _markHasValues(String key) {
    if (key.contains("${LocalStorageService.kRoomSettingsPrefix}room:")) {
      roomSpecificHasValues.value = true;
    } else {
      siteSpecificHasValues.value = true;
    }
  }

  @override
  void saveScopedSetting(String field, Object value) =>
      _saveScoped(field, value);

  /// 正在看的直播间；设置页（全局）打开着时为 null
  RoomContext? get currentRoomContext => _roomContext;

  /// 保存一项可以单独设置的设置（见 [_scopedWriteKey]）
  void _saveScoped(String field, Object value) {
    var key = _scopedWriteKey;
    if (key == null) {
      LocalStorageService.instance.setValue(field, value);
      return;
    }
    var profile = _readScoped(key)..[field] = value;
    LocalStorageService.instance.setValue(key, json.encode(profile));
    _markHasValues(key);
  }

  /// 单独设置打开时把关键词屏蔽存进那一份，返回 true；全局时返回 false
  bool _saveScopedShield() {
    var key = _scopedWriteKey;
    if (key == null) {
      return false;
    }
    var profile = _readScoped(key)..[_shieldField] = shieldList.toList();
    LocalStorageService.instance.setValue(key, json.encode(profile));
    _markHasValues(key);
    return true;
  }

  /// 按开关把各项换成直播间的、平台的或全局的（没调过的项依次往后沿用）
  void _applyScoped() {
    var context = _roomContext;
    var room = context == null
        ? <String, dynamic>{}
        : _readScoped(roomSettingsKey(context));
    var site = context == null
        ? <String, dynamic>{}
        : _readScoped(siteSettingsKey(context));
    var roomOn = room["enabled"] == true;
    var siteOn = site["enabled"] == true;
    dynamic pick(String field) =>
        (roomOn ? room[field] : null) ?? (siteOn ? site[field] : null);
    var storage = LocalStorageService.instance;
    for (var entry in _scoped.entries) {
      var (rx, initial) = entry.value;
      var value = pick(entry.key) ?? storage.getValue<dynamic>(entry.key, null);
      var current = rx.value;
      if (current is double) {
        rx.value = value is num ? value.toDouble() : initial();
      } else if (current is int) {
        rx.value = value is num ? value.toInt() : initial();
      } else if (current is bool) {
        rx.value = value is bool ? value : initial();
      }
    }
    var shield = pick(_shieldField);
    shieldList.assignAll(
      shield is List
          ? shield.map((e) => e.toString())
          : storage.shieldBox.values.whereType<String>(),
    );
    roomSpecific.value = roomOn;
    siteSpecific.value = siteOn;
    roomSpecificHasValues.value = room.keys.any((k) => k != "enabled");
    siteSpecificHasValues.value = site.keys.any((k) => k != "enabled");
    specificRoomLabel.value = context == null
        ? ""
        : (context.roomLabel.isEmpty ? context.roomId : context.roomLabel);
    specificSiteLabel.value = context?.siteName ?? "";
  }


  /// 直播间显示榜单：礼物页里的“礼物 | 榜单”、点在线人数打开榜单、全屏时的榜单按钮
  var liveRankTab = true.obs;
  void setLiveRankTab(bool e) {
    liveRankTab.value = e;
    LocalStorageService.instance.setValue(LocalStorageService.kLiveRankTab, e);
  }

  var qualityLevel = 1.obs;
  void setQualityLevel(int level) {
    qualityLevel.value = level;
    LocalStorageService.instance
        .setValue(LocalStorageService.kQualityLevel, level);
  }

  var qualityLevelCellular = 1.obs;
  void setQualityLevelCellular(int level) {
    qualityLevelCellular.value = level;
    LocalStorageService.instance
        .setValue(LocalStorageService.kQualityLevelCellular, level);
  }

  var autoExitEnable = false.obs;
  void setAutoExitEnable(bool e) {
    autoExitEnable.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kAutoExitEnable, e);
  }

  var autoExitDuration = 60.obs;
  void setAutoExitDuration(int e) {
    autoExitDuration.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kAutoExitDuration, e);
  }

  /// 进这个直播间时自动开始定时关闭（只在直播间、平台单独设置打开时记住）
  var roomAutoExitEnable = false.obs;
  void setRoomAutoExitEnable(bool e) {
    roomAutoExitEnable.value = e;
    if (_scopedWriteKey != null) {
      _saveScoped(LocalStorageService.kRoomAutoExitEnable, e);
    }
  }

  var roomAutoExitDuration = 60.obs;
  void setRoomAutoExitDuration(int e) {
    roomAutoExitDuration.value = e;
    _saveScoped(LocalStorageService.kRoomAutoExitDuration, e);
  }

  var playerCompatMode = false.obs;
  void setPlayerCompatMode(bool e) {
    playerCompatMode.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kPlayerCompatMode, e);
  }

  var playerBufferSize = 32.obs;
  void setPlayerBufferSize(int e) {
    playerBufferSize.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kPlayerBufferSize, e);
  }

  var playerAutoPause = false.obs;
  void setPlayerAutoPause(bool e) {
    playerAutoPause.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kPlayerAutoPause, e);
  }

  /// 与其他应用同时播放：关着时（默认）别的应用出声会让直播暂停或压低音量
  var playWithOthers = false.obs;
  void setPlayWithOthers(bool e) {
    playWithOthers.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kPlayWithOthers, e);
  }

  var autoFullScreen = false.obs;
  void setAutoFullScreen(bool e) {
    autoFullScreen.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kAutoFullScreen, e);
  }

  var playershowSuperChat = true.obs;
  void setPlayerShowSuperChat(bool e) {
    playershowSuperChat.value = e;
    _saveScoped(LocalStorageService.kPlayerShowSuperChat, e);
  }

  /// 直播间的播放器左上角显示视频信息（分辨率、帧率、码率、丢帧、缓冲等）
  var playerVideoStats = false.obs;
  void setPlayerVideoStats(bool e) {
    playerVideoStats.value = e;
    _saveScoped(LocalStorageService.kPlayerVideoStats, e);
  }

  /// 关键词屏蔽。直播间、平台单独设置打开时，改的是它那一份
  /// （第一次改时从当前生效的复制一份）
  RxSet<String> shieldList = <String>{}.obs;
  void addShieldList(String e) {
    shieldList.add(e);
    if (_saveScopedShield()) return;
    LocalStorageService.instance.shieldBox.put(e, e);
  }

  void removeShieldList(String e) {
    shieldList.remove(e);
    if (_saveScopedShield()) return;
    LocalStorageService.instance.shieldBox.delete(e);
  }

  Future clearShieldList() async {
    shieldList.clear();
    if (_saveScopedShield()) return;
    await LocalStorageService.instance.shieldBox.clear();
  }

  /// 全局的关键词。备份和同步只用这一份：开着直播间、平台单独设置时，
  /// [shieldList] 是那个直播间的，不能当成全局的发出去
  List<String> get globalShieldList =>
      LocalStorageService.instance.shieldBox.values.toList();

  /// 改全局的关键词（恢复备份、局域网同步），不管现在开没开单独设置
  Future<void> updateGlobalShieldList({
    Iterable<String> add = const [],
    Iterable<String> remove = const [],
    bool clear = false,
  }) async {
    var box = LocalStorageService.instance.shieldBox;
    if (clear) {
      await box.clear();
    }
    await box.deleteAll(remove.toList());
    await box.putAll({
      for (var e in add)
        if (e.trim().isNotEmpty) e.trim(): e.trim(),
    });
    _applyScoped();
  }

  void setScaleMode(int value) {
    scaleMode.value = value;
    _saveScoped(LocalStorageService.kPlayerScaleMode, value);
  }

  RxList<String> siteSort = RxList<String>();
  void setSiteSort(List<String> e) {
    siteSort.value = e;
    LocalStorageService.instance.setValue(
      LocalStorageService.kSiteSort,
      siteSort.join(","),
    );
  }

  /// 新装的直播源排到最后
  void appendSiteSort(Iterable<String> ids) {
    var missing = ids.where((e) => !siteSort.contains(e)).toList();
    if (missing.isEmpty) {
      return;
    }
    setSiteSort([...siteSort, ...missing]);
  }

  /// 删除直播源后从排序里去掉
  void removeSiteSort(String id) {
    if (!siteSort.contains(id)) {
      return;
    }
    setSiteSort(siteSort.where((e) => e != id).toList());
  }

  /// 不在首页、分类、搜索里显示的平台（关注、历史里的直播间照常能打开）
  RxList<String> hiddenSites = RxList<String>();

  /// 没保存过时：新装默认只显示最初的四个平台；已经在用的保持原样（全部显示）。
  /// 同步过来的设置里有这一项时以同步的为准
  void initHiddenSites() {
    const unset = "__unset__";
    var saved = LocalStorageService.instance
        .getValue<String>(LocalStorageService.kHiddenSites, unset);
    if (saved == unset) {
      var hidden = firstRun ? Constant.kForkExtraSites : const <String>[];
      hiddenSites.value = List.of(hidden);
      LocalStorageService.instance
          .setValue(LocalStorageService.kHiddenSites, hidden.join(","));
      return;
    }
    hiddenSites.value = saved.split(",").where((e) => e.isNotEmpty).toList();
  }

  void setSiteHidden(String id, bool hidden) {
    var next = hiddenSites.where((e) => e != id).toList();
    if (hidden) {
      next.add(id);
    }
    hiddenSites.value = next;
    LocalStorageService.instance
        .setValue(LocalStorageService.kHiddenSites, next.join(","));
    // 首页、分类页的标签跟着刷新
    Sites.version.value++;
  }

  RxList<String> homeSort = RxList<String>();
  void setHomeSort(List<String> e) {
    homeSort.value = e;
    LocalStorageService.instance.setValue(
      LocalStorageService.kHomeSort,
      homeSort.join(","),
    );
  }

  Rx<double> playerVolume = 100.0.obs;
  void setPlayerVolume(double value) {
    playerVolume.value = value;
    LocalStorageService.instance.setValue(
      LocalStorageService.kPlayerVolume,
      value,
    );
  }

  var pipHideDanmu = true.obs;
  void setPIPHideDanmu(bool e) {
    pipHideDanmu.value = e;
    LocalStorageService.instance.setValue(LocalStorageService.kPIPHideDanmu, e);
  }

  /// SC 显示方式：0 按直播间显示时长，1 一直显示
  var superChatDisplayMode = 0.obs;
  void setSuperChatDisplayMode(int e) {
    superChatDisplayMode.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kSuperChatDisplayMode, e);
  }

  /// 直播追帧加速：缓冲超过目标时加快播放，追上后恢复正常速度
  var liveCatchUp = false.obs;
  void setLiveCatchUp(bool e) {
    liveCatchUp.value = e;
    _saveScoped(LocalStorageService.kLiveCatchUp, e);
  }

  /// 追帧最高倍速（1.01~2.00，步长 0.01）
  var liveCatchUpMaxRate = 1.5.obs;
  void setLiveCatchUpMaxRate(double e) {
    var value = (e.clamp(1.01, 2.0) * 100).round() / 100;
    liveCatchUpMaxRate.value = value;
    _saveScoped(LocalStorageService.kLiveCatchUpMaxRate, value);
  }

  /// 追帧目标缓冲（秒），缓冲高于该值才加速
  var liveCatchUpTarget = 2.0.obs;
  void setLiveCatchUpTarget(double e) {
    var value = (e.clamp(0.5, 10.0) * 10).round() / 10;
    liveCatchUpTarget.value = value;
    _saveScoped(LocalStorageService.kLiveCatchUpTarget, value);
  }

  /// iOS 画中画显示弹幕
  var iosPipDanmaku = true.obs;
  void setIosPipDanmaku(bool e) {
    iosPipDanmaku.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kIosPipDanmaku, e);
  }

  /// iOS 画中画弹幕大小（0.5~2.0 倍）。已改为 [danmuPipSize]，只在第一次换算时读取
  var iosPipDanmakuScale = 1.0.obs;

  /// iOS 画中画弹幕行数（1~10）
  var iosPipDanmakuLines = 3.obs;
  void setIosPipDanmakuLines(int e) {
    var value = e.clamp(1, 10);
    iosPipDanmakuLines.value = value;
    LocalStorageService.instance
        .setValue(LocalStorageService.kIosPipDanmakuLines, value);
  }

  /// iOS 画中画帧率：60 更流畅，30 更省电（被系统在后台结束时可改回 30）
  var iosPipFrameRate = 60.obs;
  void setIosPipFrameRate(int e) {
    var value = e >= 60 ? 60 : 30;
    iosPipFrameRate.value = value;
    LocalStorageService.instance
        .setValue(LocalStorageService.kIosPipFrameRate, value);
  }

  /// iOS 画中画画质：小窗画面的最大高度（540 / 720 / 1080），越高越清晰也越耗电
  var iosPipQuality = 540.obs;
  void setIosPipQuality(int e) {
    var value = const [540, 720, 1080].contains(e) ? e : 540;
    iosPipQuality.value = value;
    LocalStorageService.instance
        .setValue(LocalStorageService.kIosPipQuality, value);
  }

  /// iOS 小窗播放方式：0 系统播放器（AVPlayer，前台仍是 mpv，小窗交给系统播放器），
  /// 1 mpv（旧方式：mpv 的画面逐帧交给系统小窗）
  var iosPipEngine = 0.obs;
  void setIosPipEngine(int e) {
    var value = e == 1 ? 1 : 0;
    iosPipEngine.value = value;
    LocalStorageService.instance
        .setValue(LocalStorageService.kIosPipEngine, value);
  }

  /// iOS 小窗弹幕方式（系统播放器方式）：0 通话式，1 叠加到系统小窗（实验）
  var iosPipDanmakuMode = 0.obs;
  void setIosPipDanmakuMode(int e) {
    var value = e == 1 ? 1 : 0;
    iosPipDanmakuMode.value = value;
    LocalStorageService.instance
        .setValue(LocalStorageService.kIosPipDanmakuMode, value);
  }

  /// iOS 小窗显示醒目留言（系统播放器方式）
  var iosPipSuperChat = true.obs;
  void setIosPipSuperChat(bool e) {
    iosPipSuperChat.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kIosPipSuperChat, e);
  }

  /// iOS 退到后台自动开小窗（系统播放器方式）：直播间里静音预热一路系统播放器
  var iosPipAutoStart = false.obs;
  void setIosPipAutoStart(bool e) {
    iosPipAutoStart.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kIosPipAutoStart, e);
  }

  /// iOS 投屏（屏幕镜像）时电视只显示画面和弹幕
  var iosExternalDisplay = true.obs;
  void setIosExternalDisplay(bool e) {
    iosExternalDisplay.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kIosExternalDisplay, e);
  }

  /// iOS 投屏时电视显示右侧聊天栏
  var iosExternalSidebar = false.obs;
  void setIosExternalSidebar(bool e) {
    iosExternalSidebar.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kIosExternalSidebar, e);
  }

  var styleColor = 0xff3498db.obs;
  void setStyleColor(int e) {
    styleColor.value = e;
    LocalStorageService.instance.setValue(LocalStorageService.kStyleColor, e);
  }

  var isDynamic = false.obs;
  void setIsDynamic(bool e) {
    isDynamic.value = e;
    LocalStorageService.instance.setValue(LocalStorageService.kIsDynamic, e);
  }

  var danmuTopMargin = 0.0.obs;
  void setDanmuTopMargin(double e) {
    danmuTopMargin.value = e;
    _saveScoped(LocalStorageService.kDanmuTopMargin, e);
  }

  var danmuBottomMargin = 0.0.obs;
  void setDanmuBottomMargin(double e) {
    danmuBottomMargin.value = e;
    _saveScoped(LocalStorageService.kDanmuBottomMargin, e);
  }

  var bilibiliLoginTip = true.obs;
  void setBiliBiliLoginTip(bool e) {
    bilibiliLoginTip.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kBilibiliLoginTip, e);
  }

  var logEnable = false.obs;
  void setLogEnable(bool e) {
    logEnable.value = e;
    LocalStorageService.instance.setValue(LocalStorageService.kLogEnable, e);
  }

  var customPlayerOutput = false.obs;
  void setCustomPlayerOutput(bool e) {
    customPlayerOutput.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kCustomPlayerOutput, e);
  }

  var videoOutputDriver = "".obs;
  void setVideoOutputDriver(String e) {
    videoOutputDriver.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kVideoOutputDriver, e);
  }

  var audioOutputDriver = "".obs;
  void setAudioOutputDriver(String e) {
    audioOutputDriver.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kAudioOutputDriver, e);
  }

  var videoHardwareDecoder = "".obs;
  void setVideoHardwareDecoder(String e) {
    videoHardwareDecoder.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kVideoHardwareDecoder, e);
  }

  var autoUpdateFollowEnable = false.obs;
  void setAutoUpdateFollowEnable(bool e) {
    autoUpdateFollowEnable.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kAutoUpdateFollowEnable, e);
  }

  var autoUpdateFollowDuration = 10.obs;
  void setAutoUpdateFollowDuration(int e) {
    autoUpdateFollowDuration.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kUpdateFollowDuration, e);
  }

  var updateFollowThreadCount = 4.obs;
  void setUpdateFollowThreadCount(int e) {
    updateFollowThreadCount.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kUpdateFollowThreadCount, e);
  }

  /// 开播提醒（总开关；具体提醒哪些直播间在关注列表里点铃铛）
  var liveNotifyEnable = true.obs;
  void setLiveNotifyEnable(bool e) {
    liveNotifyEnable.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kLiveNotifyEnable, e);
  }

  /// 关注列表里所有直播间都显示铃铛；关掉时只有开了提醒的直播间显示
  var liveNotifyShowBell = false.obs;
  void setLiveNotifyShowBell(bool e) {
    liveNotifyShowBell.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kLiveNotifyShowBell, e);
  }

  /// 直播间里切到“关注”时查哪些主播：all、current（正在看的主播所在的分组）、
  /// tag:<分组 id>、none
  var liveRoomFollowCheck = "all".obs;
  void setLiveRoomFollowCheck(String e) {
    liveRoomFollowCheck.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kLiveRoomFollowCheck, e);
  }

  /// 关注很多时的提示已经出现过
  var manyFollowsHinted = false.obs;
  void setManyFollowsHinted(bool e) {
    manyFollowsHinted.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kManyFollowsHinted, e);
  }

  /// 开播提醒多久查一次（分钟）
  var liveNotifyInterval = 3.obs;
  void setLiveNotifyInterval(int e) {
    liveNotifyInterval.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kLiveNotifyInterval, e);
  }

  var playerForceHttps = false.obs;
  void setPlayerForceHttps(bool e) {
    playerForceHttps.value = e;
    LocalStorageService.instance
        .setValue(LocalStorageService.kPlayerForceHttps, e);
  }
}

/// 直播间、平台单独设置用：正在看的是哪个平台的哪个直播间
class RoomContext {
  /// 用来区分同时打开的直播间（离开时按它找）
  final String id;
  final String siteId;
  final String siteName;
  final String roomId;

  /// 设置页里显示的直播间名字（主播名），没有时用房间号
  final String roomLabel;
  const RoomContext({
    required this.id,
    required this.siteId,
    required this.siteName,
    required this.roomId,
    this.roomLabel = "",
  });

  /// 设置页：在它关掉之前用全局设置
  const RoomContext.global(this.id)
      : siteId = "",
        siteName = "",
        roomId = "",
        roomLabel = "";

  bool get isGlobal => siteId.isEmpty;
}
