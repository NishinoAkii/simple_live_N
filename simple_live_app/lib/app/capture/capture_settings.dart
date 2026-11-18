import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 截图和录屏里的图层。[player] 只用来量播放器的位置（视频帧单独取），
/// [page] 是整个页面（截图范围选“完整窗口”时）
enum CaptureLayer {
  player,
  page,
  danmaku,

  /// 哔哩哔哩语聊房自己画的房主和麦位（盖住平台合成的画面）
  voiceRoom,
  videoStats,

  /// 视频左下角的连麦标签、SC 卡片、礼物卡片
  linkMic,
  superChat,
  gifts,

  /// 侧栏（聊天、公告卡片、身份提示等），手机竖屏时是视频下面的聊天区
  sidePanel,
}

/// 截图范围：直播画面（播放器那一块，选了侧栏时加上侧栏）或完整窗口
enum CaptureRange { player, window }

/// 录屏方式：流录制 = mpv 把收到的视频流原样存下来（不带弹幕）；
/// 画面录制 = 原生端把窗口里播放器那一块录成 MP4
enum CaptureRecordMode { stream, screen }

/// 流录制存成什么：视频（原样的流，MKV）或 GIF（只有画面，最长 1 分钟）
enum CaptureRecordFormat { video, gif }

/// 截图、录屏结束后做什么
enum CaptureAfterAction { ask, save, copy }

/// 截图尺寸：原画 = 按视频帧的分辨率（有像素上限，见 planCapture）；
/// 和屏幕一样 = 按屏幕上的物理像素
enum CaptureImageSize { source, screen }

/// 编译时的功能开关
class CaptureFeatures {
  CaptureFeatures._();

  /// 流录制（mpv 原样存流，或存成 GIF）。1.26.0 打开
  static const bool streamRecordingEnabled = true;

  /// 画面录制（原生端录窗口）。1.26.0 还关着：录屏方式的选择、原生录屏、
  /// 录制时藏起没选的层都不出现，多开窗口也照旧直接启动
  static const bool screenRecordingEnabled = false;

  /// 测试里临时换掉（null = 用上面的常量）
  @visibleForTesting
  static bool? debugStreamRecording;
  @visibleForTesting
  static bool? debugScreenRecording;

  static bool get streamRecording =>
      debugStreamRecording ?? streamRecordingEnabled;
  static bool get screenRecording =>
      debugScreenRecording ?? screenRecordingEnabled;

  /// 有录屏（录屏键、录屏的设置）：两种里开着一种就有
  static bool get recording => streamRecording || screenRecording;
}

/// “截图和录屏”的设置。
///
/// 图层、截图范围、截图尺寸、录屏方式、录屏保存为、截图后、最长录制时间、图片信息、全屏按键和视频信息显示的内容
/// 进 WebDAV 的扩展部分
/// （[syncKeys]，见 SyncCompat.forkSettingKeys）；保存位置只在本机（[kSaveDir]）。
/// 没注册存储时（测试里）用默认值，改动也不保存
class CaptureSettings {
  CaptureSettings._();

  static CaptureSettings? _instance;
  static CaptureSettings get instance =>
      _instance ??= CaptureSettings._().._load();

  @visibleForTesting
  static void reset() => _instance = null;

  static const String kLayerDanmaku = "CaptureLayerDanmaku";
  static const String kLayerSidePanel = "CaptureLayerSidePanel";
  static const String kLayerVideoStats = "CaptureLayerVideoStats";
  static const String kLayerSuperChat = "CaptureLayerSuperChat";
  static const String kLayerGifts = "CaptureLayerGifts";
  static const String kLayerLinkMic = "CaptureLayerLinkMic";
  static const String kLayerVoiceRoom = "CaptureLayerVoiceRoom";
  static const String kRecordMode = "CaptureRecordMode";
  static const String kRecordFormat = "CaptureRecordFormat";
  static const String kAfterAction = "CaptureAfterAction";

  /// 以前的最长录制时间（分钟，0 = 不限）：只在没有 [kMaxSeconds] 时读一次
  static const String kMaxMinutes = "CaptureMaxMinutes";
  static const String kMaxSeconds = "CaptureMaxSeconds";
  static const String kMetadata = "CaptureMetadata";
  static const String kRange = "CaptureRange";
  static const String kFullscreenButtons = "CaptureFullscreenButtons";
  static const String kVideoStatsFields = "PlayerVideoStatsFields";
  static const String kImageSize = "CaptureImageSize";

  /// 保存位置（电脑），只在本机
  static const String kSaveDir = "CaptureSaveDir";

  static const List<String> syncKeys = [
    kLayerDanmaku,
    kLayerSidePanel,
    kLayerVideoStats,
    kLayerSuperChat,
    kLayerGifts,
    kLayerLinkMic,
    kLayerVoiceRoom,
    kRecordMode,
    kRecordFormat,
    kAfterAction,
    kMaxMinutes,
    kMaxSeconds,
    kMetadata,
    kRange,
    kFullscreenButtons,
    kVideoStatsFields,
    kImageSize,
  ];

  static const List<String> localKeys = [kSaveDir];

  /// 最长录制时间（秒）：最多 2 分钟，只能改短，没有“不限”
  static const List<int> maxSecondsOptions = [30, 60, 120];
  static const int defaultMaxSeconds = 120;

  /// 存成 GIF 时最长 1 分钟
  static const int gifMaxSeconds = 60;

  /// 存着的时间换成能选的：超过 2 分钟（或以前的“不限”）按 2 分钟，
  /// 其余取不超过它的最长一档
  static int clampMaxSeconds(int seconds) {
    if (seconds <= 0 || seconds >= defaultMaxSeconds) {
      return defaultMaxSeconds;
    }
    return maxSecondsOptions.lastWhere(
      (e) => e <= seconds,
      orElse: () => maxSecondsOptions.first,
    );
  }

  /// 截图和录屏里有什么：默认只有弹幕（视频本身总是有）
  final danmaku = true.obs;
  final sidePanel = false.obs;
  final videoStats = false.obs;
  final superChat = false.obs;
  final gifts = false.obs;
  final linkMic = false.obs;
  final voiceRoom = false.obs;
  final recordMode = CaptureRecordMode.screen.obs;
  final recordFormat = CaptureRecordFormat.video.obs;
  final afterAction = CaptureAfterAction.ask.obs;
  final maxSeconds = defaultMaxSeconds.obs;
  final metadata = true.obs;
  final range = CaptureRange.player.obs;
  final imageSize = CaptureImageSize.source.obs;

  /// 全屏时截图、录屏键一直显示（控制栏收起后也在，小一点、半透明）
  final fullscreenButtons = false.obs;
  final saveDir = "".obs;

  /// 视频信息浮层显示哪些行（VideoStats.fieldIds 里的），空 = 全部
  final videoStatsFields = <String>[].obs;

  static LocalStorageService? get _storage =>
      Get.isRegistered<LocalStorageService>()
          ? LocalStorageService.instance
          : null;

  void _load() {
    var s = _storage;
    if (s == null) {
      return;
    }
    danmaku.value = s.getValue(kLayerDanmaku, true);
    sidePanel.value = s.getValue(kLayerSidePanel, false);
    videoStats.value = s.getValue(kLayerVideoStats, false);
    superChat.value = s.getValue(kLayerSuperChat, false);
    gifts.value = s.getValue(kLayerGifts, false);
    linkMic.value = s.getValue(kLayerLinkMic, false);
    voiceRoom.value = s.getValue(kLayerVoiceRoom, false);
    recordMode.value = _pick(CaptureRecordMode.values,
        s.getValue(kRecordMode, 1), CaptureRecordMode.screen);
    recordFormat.value = _pick(CaptureRecordFormat.values,
        s.getValue(kRecordFormat, 0), CaptureRecordFormat.video);
    afterAction.value = _pick(CaptureAfterAction.values,
        s.getValue(kAfterAction, 0), CaptureAfterAction.ask);
    var seconds = s.getValue(kMaxSeconds, -1);
    if (seconds < 0) {
      // 以前的测试版存的是分钟
      seconds = s.getValue(kMaxMinutes, 0) * 60;
    }
    maxSeconds.value = clampMaxSeconds(seconds);
    metadata.value = s.getValue(kMetadata, true);
    range.value =
        _pick(CaptureRange.values, s.getValue(kRange, 0), CaptureRange.player);
    imageSize.value = _pick(CaptureImageSize.values, s.getValue(kImageSize, 0),
        CaptureImageSize.source);
    fullscreenButtons.value = s.getValue(kFullscreenButtons, false);
    saveDir.value = s.getValue(kSaveDir, "");
    videoStatsFields.assignAll(
      s
          .getValue(kVideoStatsFields, "")
          .split(",")
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty),
    );
  }

  static T _pick<T>(List<T> values, int index, T fallback) =>
      index >= 0 && index < values.length ? values[index] : fallback;

  void _save(String key, Object value) => _storage?.setValue(key, value);

  /// 可以选的层（设置里按这个顺序列出）
  static const List<CaptureLayer> optionalLayers = [
    CaptureLayer.danmaku,
    CaptureLayer.sidePanel,
    CaptureLayer.videoStats,
    CaptureLayer.gifts,
    CaptureLayer.superChat,
    CaptureLayer.linkMic,
    CaptureLayer.voiceRoom,
  ];

  /// 选了的层
  Set<CaptureLayer> get chosenLayers => {
        for (var layer in optionalLayers)
          if (includes(layer)) layer
      };

  RxBool? _rx(CaptureLayer layer) => switch (layer) {
        CaptureLayer.danmaku => danmaku,
        CaptureLayer.sidePanel => sidePanel,
        CaptureLayer.videoStats => videoStats,
        CaptureLayer.superChat => superChat,
        CaptureLayer.gifts => gifts,
        CaptureLayer.linkMic => linkMic,
        CaptureLayer.voiceRoom => voiceRoom,
        CaptureLayer.player || CaptureLayer.page => null,
      };

  static String? _key(CaptureLayer layer) => switch (layer) {
        CaptureLayer.danmaku => kLayerDanmaku,
        CaptureLayer.sidePanel => kLayerSidePanel,
        CaptureLayer.videoStats => kLayerVideoStats,
        CaptureLayer.superChat => kLayerSuperChat,
        CaptureLayer.gifts => kLayerGifts,
        CaptureLayer.linkMic => kLayerLinkMic,
        CaptureLayer.voiceRoom => kLayerVoiceRoom,
        CaptureLayer.player || CaptureLayer.page => null,
      };

  /// 截图、录屏里有没有这一层（播放器本身总是有）
  bool includes(CaptureLayer layer) => switch (layer) {
        CaptureLayer.player => true,
        CaptureLayer.page => range.value == CaptureRange.window,
        _ => _rx(layer)?.value ?? false,
      };

  void setLayer(CaptureLayer layer, bool value) {
    var rx = _rx(layer);
    var key = _key(layer);
    if (rx == null || key == null) {
      return;
    }
    rx.value = value;
    _save(key, value);
  }

  void setRecordMode(CaptureRecordMode value) {
    recordMode.value = value;
    _save(kRecordMode, value.index);
  }

  void setAfterAction(CaptureAfterAction value) {
    afterAction.value = value;
    _save(kAfterAction, value.index);
  }

  void setRecordFormat(CaptureRecordFormat value) {
    recordFormat.value = value;
    _save(kRecordFormat, value.index);
  }

  void setMaxSeconds(int value) {
    value = clampMaxSeconds(value);
    maxSeconds.value = value;
    _save(kMaxSeconds, value);
  }

  void setMetadata(bool value) {
    metadata.value = value;
    _save(kMetadata, value);
  }

  void setRange(CaptureRange value) {
    range.value = value;
    _save(kRange, value.index);
  }

  void setImageSize(CaptureImageSize value) {
    imageSize.value = value;
    _save(kImageSize, value.index);
  }

  void setFullscreenButtons(bool value) {
    fullscreenButtons.value = value;
    _save(kFullscreenButtons, value);
  }

  void setSaveDir(String value) {
    saveDir.value = value;
    _save(kSaveDir, value);
  }

  void setVideoStatsFields(Iterable<String> ids) {
    videoStatsFields.assignAll(ids);
    _save(kVideoStatsFields, ids.join(","));
  }

  /// 流录制存成 GIF
  bool get gif => recordFormat.value == CaptureRecordFormat.gif;

  /// 录到多长自动停下：设置里的时间，[gif] 时最长 1 分钟
  Duration recordLimit({required bool gif}) => Duration(
        seconds: gif && maxSeconds.value > gifMaxSeconds
            ? gifMaxSeconds
            : maxSeconds.value,
      );

  /// 按现在的“录屏保存为”，录到多长自动停下
  Duration get maxDuration => recordLimit(gif: gif);
}
