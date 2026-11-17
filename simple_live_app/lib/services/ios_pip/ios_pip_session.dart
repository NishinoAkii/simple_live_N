import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/ios_pip/ios_av_pip_controller.dart';
import 'package:simple_live_app/services/ios_pip/ios_pip_controller.dart';
import 'package:simple_live_app/services/ios_pip/ios_pip_custom_output.dart';
import 'package:simple_live_app/services/ios_pip/ios_pip_video_output_transition.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// iOS 上选了 mpv 小窗（[AppSettingsController.iosPipEngine] 为 1）时，硬件解码改为
/// “解码后拷回内存”：画中画时要切到软件渲染，软件渲染读不了显存里的帧。
/// 默认的系统播放器小窗用不到 mpv 的画面，前台照常用不拷贝的硬件解码，省电也省 CPU
String? iosPipHwdec(String? hwdec, {required bool hardware}) {
  if (!Platform.isIOS ||
      !hardware ||
      AppSettingsController.instance.iosPipEngine.value != 1) {
    return hwdec;
  }
  switch (hwdec ?? 'auto') {
    case 'auto':
      return 'auto-copy';
    case 'auto-safe':
      return 'auto-copy-safe';
    case 'videotoolbox':
      return 'videotoolbox-copy';
    default:
      return hwdec;
  }
}

/// 一个直播间的 iOS 画中画会话，也负责投屏到外接显示器
///
/// 小窗有两种播放方式（设置“小窗播放方式”）：
/// - 系统播放器（默认）：前台仍是 mpv，开小窗时由 AVPlayer 播 [avSource] 给的 HLS/MP4，
///   mpv 暂停；关闭小窗时 mpv 重新拉到最新画面接着播。
///   没有可用地址或系统播放器没开起来时，自动改用 mpv 小窗。
/// - mpv（旧方式）：mpv 软件渲染的画面逐帧交给系统小窗。
class IosPipSession {
  final Player player;
  final VideoController videoController;

  /// 页面上视频组件的 key，用来算画中画动画的起始位置
  final GlobalKey videoKey;

  /// 直播没有时长，系统不显示进度条
  final bool isLive;

  /// 画中画开始/结束
  final void Function(bool active)? onModeChanged;

  /// 系统播放器小窗用的地址（HLS）。
  /// 不传或返回 null 时用 mpv 小窗
  final Future<LivePlayUrl?> Function()? avSource;

  /// 系统播放器小窗结束后，让 mpv 重新打开当前线路、拉到直播最新的画面（直播间传入）
  final Future<void> Function()? reopenLive;

  /// 返回 true 时不开小窗、不预热（听直播）
  final bool Function()? blocked;

  late final IosPipVideoOutputTransition _transition;
  late final IosPipCustomOutput _customOutput;
  late final IosPipController _controller;
  late final IosAvPipController _av;
  Timer? _syncTimer;
  Timer? _externalTimer;
  Timer? _flushTimer;
  final List<Worker> _workers = [];
  final List<StreamSubscription> _subscriptions = [];
  final List<Map<String, Object>> _pendingDanmaku = [];
  bool _externalAttached = false;
  AppLifecycleListener? _lifecycleListener;

  // ---- 系统播放器小窗 ----
  /// 小窗显示中
  bool _avActive = false;

  /// 每关一次小窗加一（开小窗的结果晚于关闭时不再当作开着）
  int _avStopCount = 0;

  /// 正在开小窗（等系统播放器准备好）
  bool _avStarting = false;

  /// mpv 已为小窗暂停，小窗结束时要让它接着播
  bool _avTookOver = false;
  bool _avMpvWasPlaying = false;

  /// 原生端静音预热着（直播间开着“退到后台自动小窗”）
  bool _avPrewarmed = false;
  bool _prewarming = false;
  bool _prewarmDirty = false;
  bool _prewarmRefresh = false;
  bool _skipPrewarmRefresh = false;
  bool _noAvSourceLogged = false;
  Timer? _prewarmTimer;

  /// 连续失败次数（开小窗、预热）；到 3 次后不再自动预热，成功开一次小窗后清零
  int _avFailures = 0;

  /// 在后台关了小窗、按设置没有接着播：回到应用时再重新拉流
  bool _liveReloadPending = false;

  /// 别的播放页接手了系统播放器，这个页面的 mpv 停着：回到这个页面时接着播
  bool _resumeWhenCurrent = false;

  /// 画中画中（或正在进入），供页面决定切后台时不要暂停
  final active = false.obs;

  /// 外接显示器（屏幕镜像）是否连接
  static RxBool get externalConnected =>
      IosPipController.externalDisplayConnected;

  IosPipSession({
    required this.player,
    required this.videoController,
    required this.videoKey,
    required this.isLive,
    this.onModeChanged,
    this.avSource,
    this.reopenLive,
    this.blocked,
  }) {
    _transition = IosPipVideoOutputTransition(
      resolveBinding: (expectedHandle) async {
        var native = player.platform;
        if (native is! NativePlayer) {
          return null;
        }
        var handle = await player.handle;
        if (handle != expectedHandle) return null;
        return IosPipVideoOutputBinding(
          handle: handle,
          textureId: videoController.id,
          isCurrent: () => !_disposed,
          readVid: () => native.getProperty('vid'),
          writeVid: (value) => native.setProperty('vid', value),
        );
      },
    );
    _customOutput = IosPipCustomOutput(
      resolveBinding: (expectedHandle) async {
        var native = player.platform;
        if (native is! NativePlayer || native.disposed) {
          return null;
        }
        var handle = await player.handle;
        if (handle != expectedHandle) return null;
        // 页面关闭时也要能换回原来的输出，只要播放器还在
        return IosPipPropertyBinding(
          handle: handle,
          isCurrent: () => !native.disposed,
          read: (name) => native.getProperty(name),
          write: (name, value) => native.setProperty(name, value),
        );
      },
    );
    _controller = IosPipController(
      playbackState: _playbackState,
      playerHandle: () async => _disposed ? null : await player.handle,
      suspendVideo: _transition.suspendVideo,
      resumeVideo: _transition.resumeVideo,
      switchCustomOutput: (handle, enabled) => enabled
          ? _customOutput.enable(handle)
          : _customOutput.disable(handle),
      onPlay: () => player.play(),
      onPause: () => player.pause(),
      onSeek: (position) => player.seek(position),
      onModeChanged: _modeChanged,
      canRestore: () => !_disposed,
    );
    _av = IosAvPipController(
      onTakeOver: _avTakeOver,
      onStarted: _onAvStarted,
      onStopped: _onAvStopped,
      onPrewarmEnded: _onAvPrewarmEnded,
      requestUrl: _fetchAvSource,
      canRestore: () => !_disposed,
      onCurrentChanged: _onAvCurrentChanged,
      onReleased: _onAvReleased,
    );
    var settings = AppSettingsController.instance;
    _workers.add(
      everAll(
        [
          settings.danmuSizeFullscreen,
          settings.danmuPipSize,
          settings.danmuPipSpeed,
          settings.danmuOpacity,
          settings.danmuArea,
          settings.danmuSpeed,
          settings.danmuStrokeWidth,
          settings.danmuFontWeight,
          settings.iosPipDanmaku,
          settings.iosPipDanmakuLines,
          settings.iosPipFrameRate,
          settings.iosPipQuality,
          settings.iosExternalDisplay,
          settings.iosExternalSidebar,
          settings.iosPipEngine,
          settings.iosPipDanmakuMode,
          settings.iosPipSuperChat,
        ],
        (_) => _configure(),
      ),
    );
    if (isLive) {
      // 退到后台自动小窗：直播间里静音预热一路系统播放器（mpv 在播时）
      _workers.add(
        everAll(
          [settings.iosPipEngine, settings.iosPipAutoStart],
          (_) {
            _avFailures = 0;
            _schedulePrewarm(delay: Duration.zero);
          },
        ),
      );
      _subscriptions.add(
        player.stream.playing.listen(
          (playing) =>
              _schedulePrewarm(delay: Duration(seconds: playing ? 2 : 8)),
        ),
      );
    }
    _subscriptions.add(player.stream.playlist.listen((_) => _onMediaOpened()));
    _lifecycleListener = AppLifecycleListener(onStateChange: _onAppLifecycle);
    _workers.add(
      everAll(
        [externalConnected, settings.iosExternalDisplay],
        (_) => _updateExternal(announce: true),
      ),
    );
    IosPipController.externalStatus().then((connected) {
      if (_disposed) return;
      externalConnected.value = connected;
      _updateExternal(announce: true);
    });
  }

  bool _disposed = false;

  /// 切到后台时是否应该继续播放
  bool get keepPlaybackInBackground => _controller.keepPlaybackInBackground;

  bool get _externalWanted =>
      externalConnected.value &&
      AppSettingsController.instance.iosExternalDisplay.value;

  /// 需要把弹幕交给原生端（画中画或投屏）
  bool get _overlayActive =>
      _controller.isCurrentPage && (active.value || _externalWanted);

  IosPipPlaybackState _playbackState() {
    return IosPipPlaybackState(
      textureId: videoController.id.value,
      playing: player.state.playing,
      position: isLive ? Duration.zero : player.state.position,
      duration: isLive ? Duration.zero : player.state.duration,
      rate: player.state.rate,
      sourceRect: _sourceRect(),
    );
  }

  Rect? _sourceRect() {
    var box = videoKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) {
      return null;
    }
    var offset = box.localToGlobal(Offset.zero);
    return offset & box.size;
  }

  void _modeChanged(bool isActive, bool restored) {
    active.value = isActive;
    if (isActive) {
      _configure();
      _startSync();
    } else {
      _syncTimer?.cancel();
      // 在后台点了小窗的关闭：按“后台自动暂停”的设置暂停
      if (!restored &&
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed &&
          AppSettingsController.instance.playerAutoPause.value) {
        player.pause();
      }
    }
    onModeChanged?.call(isActive);
    if (!isActive) {
      // mpv 小窗关了：可以重新预热系统播放器
      _schedulePrewarm();
    }
  }

  void _startSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _controller.synchronize();
    });
  }

  /// 系统播放器小窗开着时，可以从应用里关掉它、回到应用内播放
  /// （mpv 小窗没有从应用里关闭的接口，只能点小窗上的按钮）
  bool get canExit => _avActive;

  /// 现在开着的是哪种小窗（显示在应用内的提示里，方便确认实际用了哪种方式）
  String get activeKind {
    if (_avActive) {
      var mode = _av.startedMode;
      return mode == null || mode.isEmpty ? "系统播放器".t : "系统播放器 · {mode}".tf({"mode": mode});
    }
    if (_controller.isActive) {
      return "mpv（系统播放器没有开起来时改用）".t;
    }
    return "";
  }

  /// 关掉系统播放器小窗，回到应用内播放（mpv 接着播）
  Future<void> exit() async {
    if (_disposed || !_avActive) return;
    await _av.stop("回到应用内播放".t);
  }

  Future<void> enter() async {
    if (_disposed ||
        _controller.isActive ||
        _avActive ||
        _avStarting ||
        (blocked?.call() ?? false)) {
      return;
    }
    if (_avEngine) {
      var reason = await _enterAv();
      if (_disposed || reason == null) return;
      _log("系统播放器小窗没有开起来（$reason），改用 mpv 小窗");
      if (_controller.isActive) return;
    }
    active.value = true;
    _configure();
    var result = await _controller.enter();
    if (_disposed) return;
    active.value = _controller.isActive;
    switch (result) {
      case IosPipEntryResult.entered:
        _startSync();
        return;
      case IosPipEntryResult.unsupported:
        SmartDialog.showToast("不支持画中画，需要 iOS 15 或更高版本".t);
        break;
      case IosPipEntryResult.notReady:
        SmartDialog.showToast("画面还没准备好，请稍后再试".t);
        break;
      case IosPipEntryResult.failed:
        SmartDialog.showToast("没能打开画中画".t);
        break;
    }
    _schedulePrewarm();
  }

  // ---------------- 系统播放器小窗 ----------------

  void _log(String message) => Log.i("iOS 画中画：$message");

  /// 选了系统播放器方式，且这个页面能给地址
  bool get _avEngine =>
      avSource != null &&
      AppSettingsController.instance.iosPipEngine.value == 0;

  String get _danmakuModeName {
    var settings = AppSettingsController.instance;
    if (!settings.iosPipDanmaku.value) return "关".t;
    return settings.iosPipDanmakuMode.value == 1 ? "叠加".t : "通话式".t;
  }

  Future<LivePlayUrl?> _fetchAvSource() async {
    var source = avSource;
    if (source == null || _disposed) return null;
    try {
      var url = await source().timeout(const Duration(seconds: 8));
      if (url == null || url.urls.isEmpty) return null;
      return url;
    } catch (e) {
      _log("取系统播放器的地址失败：$e");
      return null;
    }
  }

  /// 用系统播放器开小窗；开起来返回 null，否则返回原因（改用 mpv 小窗）
  Future<String?> _enterAv() async {
    _avStarting = true;
    // 进入中：切到后台不要暂停
    active.value = true;
    try {
      if (!await IosAvPipController.isSupported()) return "设备不支持".t;
      if (_disposed) return "页面已关闭".t;
      _configure();
      LivePlayUrl? url;
      var prewarmed = isLive && _avPrewarmed;
      if (!prewarmed) {
        url = await _fetchAvSource();
        if (_disposed) return "页面已关闭".t;
        if (url == null) return "没有可用的 HLS/MP4 地址".t;
      }
      var state = player.state;
      var stopCount = _avStopCount;
      _log("开系统播放器小窗：${prewarmed ? "用预热的播放器".t : "新开".t}，"
          "${"直播".t}，弹幕：$_danmakuModeName");
      var error = await _av.start(
        url: url,
        live: isLive,
        playing: isLive || state.playing,
        position: isLive ? Duration.zero : state.position,
        rate: state.rate,
        sourceRect: _sourceRect(),
      );
      if (prewarmed && error != null && error.contains("av_no_source")) {
        // 原生端的预热已经没了：取地址重新开
        _avPrewarmed = false;
        url = await _fetchAvSource();
        if (_disposed) return "页面已关闭".t;
        if (url == null) return "没有可用的 HLS/MP4 地址".t;
        error = await _av.start(
          url: url,
          live: isLive,
          playing: true,
          position: Duration.zero,
          rate: state.rate,
          sourceRect: _sourceRect(),
        );
      }
      if (_disposed) return error ?? "页面已关闭".t;
      if (error != null) {
        // 原生端失败时已拆掉播放器（包括预热的）
        _avPrewarmed = false;
        _avFailures++;
        if (_avTookOver) {
          _avTookOver = false;
          if (_avMpvWasPlaying) await player.play();
        }
        return error;
      }
      if (stopCount == _avStopCount) _onAvStarted();
      return null;
    } finally {
      _avStarting = false;
    }
  }

  /// 小窗即将开始（按钮或切到后台自动）：暂停 mpv，把进度交给系统播放器
  Future<Map<String, Object>> _avTakeOver(bool auto) async {
    if (_disposed) return const {'ok': false};
    _log(auto ? "切到后台，系统自动开了小窗，mpv 暂停".t : "小窗开始，mpv 暂停".t);
    active.value = true;
    var state = player.state;
    if (!_avTookOver) {
      _avTookOver = true;
      _avMpvWasPlaying = state.playing;
    }
    // 只暂停，不能停掉或释放 mpv：mpv 关闭音频输出时会停用整个音频会话，
    // 系统播放器也会没声音
    await player.pause();
    return {
      'ok': true,
      'playing': isLive || state.playing,
      'positionMillis': isLive ? 0 : state.position.inMilliseconds,
      'rate': state.rate,
    };
  }

  void _onAvStarted() {
    if (_disposed || _avActive) return;
    _avActive = true;
    _avFailures = 0;
    _liveReloadPending = false;
    active.value = true;
    _configure();
    _startSync();
    onModeChanged?.call(true);
  }

  Future<void> _onAvStopped(IosAvPipStopInfo info) async {
    if (_disposed) return;
    var wasActive = _avActive;
    _avStopCount++;
    _avActive = false;
    _avPrewarmed = info.prewarmed;
    if (info.failed) _avFailures++;
    if (!_controller.isActive) _syncTimer?.cancel();
    active.value = _controller.isActive || _avStarting;
    if (_avTookOver) {
      _avTookOver = false;
      await _resumeMpv(info, wasActive);
    }
    if (_disposed) return;
    if (wasActive) onModeChanged?.call(false);
    _schedulePrewarm();
  }

  /// 小窗结束后 mpv 接着播：重新拉到最新画面
  Future<void> _resumeMpv(IosAvPipStopInfo info, bool wasActive) async {
    var foreground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    // 在后台点了小窗的关闭：按“进入后台自动暂停”的设置不再播放（和 mpv 小窗一样）
    var stayPaused = !info.restored &&
        !foreground &&
        AppSettingsController.instance.playerAutoPause.value;
    if (isLive) {
      if (!wasActive) {
        // 小窗没开起来，mpv 只停了一下
        if (_avMpvWasPlaying) await player.play();
        return;
      }
      if (stayPaused) {
        _liveReloadPending = true;
        _log("小窗在后台关闭，回到应用时再重新拉流");
        return;
      }
      await _reloadLive();
      return;
    }
  }

  Future<void> _reloadLive() async {
    _log("mpv 重新拉到最新的直播画面");
    _skipPrewarmRefresh = true;
    var reopen = reopenLive;
    if (reopen != null) {
      await reopen();
    } else {
      await player.play();
    }
  }

  void _onAppLifecycle(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      if (_liveReloadPending && !_avActive && !_avTookOver) {
        _liveReloadPending = false;
        _reloadLive();
      }
      _schedulePrewarm();
    } else if (state == AppLifecycleState.paused) {
      // 切到后台没有自动开小窗：停掉预热（多等一会儿，自动小窗可能稍晚才开始）
      _schedulePrewarm(delay: const Duration(seconds: 8));
    }
  }

  void _onAvCurrentChanged() {
    if (_disposed) return;
    if (_resumeWhenCurrent && _av.isCurrentPage) {
      _resumeWhenCurrent = false;
      if (isLive) {
        _reloadLive();
      }
    }
    _schedulePrewarm(delay: Duration.zero);
  }

  /// 别的播放页开了系统播放器小窗：这个页面的小窗或预热已被关掉
  void _onAvReleased() {
    if (_disposed) return;
    var wasActive = _avActive;
    if (_avTookOver && _avMpvWasPlaying) _resumeWhenCurrent = true;
    _avActive = false;
    _avTookOver = false;
    _avPrewarmed = false;
    if (!_controller.isActive) _syncTimer?.cancel();
    active.value = _controller.isActive;
    if (wasActive) onModeChanged?.call(false);
  }

  void _onAvPrewarmEnded(String reason) {
    if (_disposed) return;
    _avPrewarmed = false;
    _avFailures++;
    _log("预热的系统播放器连续出错，已停止（$reason）");
  }

  /// mpv 打开了新的内容
  void _onMediaOpened() {
    if (_disposed) return;
    if (!isLive) return;
    if (_skipPrewarmRefresh) {
      _skipPrewarmRefresh = false;
      return;
    }
    if (!_avActive && !_avStarting && !_avTookOver) {
      // 换了直播间、线路或重新连接：预热的地址也换一下
      _noAvSourceLogged = false;
      _schedulePrewarm(delay: const Duration(seconds: 5), refresh: true);
    }
  }

  /// 直播：系统播放器小窗期间 mpv 暂停着，不要重连 mpv（小窗结束后会重新拉流）
  bool get mpvSuspended => _avActive || _avTookOver;

  bool get _wantPrewarm {
    if (_disposed || !isLive || !_avEngine) return false;
    if (blocked?.call() ?? false) return false;
    return AppSettingsController.instance.iosPipAutoStart.value &&
        _av.isCurrentPage &&
        !_controller.isActive &&
        !_controller.keepPlaybackInBackground &&
        !_avActive &&
        !_avStarting &&
        !_avTookOver &&
        _avFailures < 3 &&
        player.state.playing &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  /// [blocked] 变了（开关听直播）：马上按现在的状态开始或停止预热
  void refreshPrewarm() => _schedulePrewarm(delay: Duration.zero);

  void _schedulePrewarm({
    Duration delay = const Duration(seconds: 2),
    bool refresh = false,
  }) {
    if (_disposed || !isLive) return;
    if (refresh) _prewarmRefresh = true;
    _prewarmTimer?.cancel();
    _prewarmTimer = Timer(delay, _updatePrewarm);
  }

  /// 按现在的状态开始、刷新或停止预热
  Future<void> _updatePrewarm() async {
    if (_disposed) return;
    if (_prewarming) {
      _prewarmDirty = true;
      return;
    }
    if (!_wantPrewarm) {
      _prewarmRefresh = false;
      if (_avPrewarmed && !_avActive && !_avStarting && !_avTookOver) {
        _avPrewarmed = false;
        await _av.stopPrewarm();
      }
      return;
    }
    if (_avPrewarmed && !_prewarmRefresh) return;
    _prewarmRefresh = false;
    _prewarming = true;
    try {
      var url = await _fetchAvSource();
      if (_disposed || !_wantPrewarm) return;
      if (url == null) {
        if (!_noAvSourceLogged) {
          _noAvSourceLogged = true;
          _log("没有系统播放器能播的直播地址，不预热（切到后台不会自动开小窗）");
        }
        return;
      }
      _configure();
      _avPrewarmed = await _av.prewarm(url, sourceRect: _sourceRect());
      if (!_avPrewarmed) {
        _avFailures++;
        _log("预热系统播放器失败（第 $_avFailures 次）");
      }
    } finally {
      _prewarming = false;
      if (_prewarmDirty) {
        _prewarmDirty = false;
        _schedulePrewarm(delay: Duration.zero);
      }
    }
  }

  // ---------------- 弹幕 ----------------

  void _configure() {
    if (_disposed || !_controller.isCurrentPage) return;
    var settings = AppSettingsController.instance;
    var args = <String, Object>{
      // 投屏到电视：和全屏一样
      "fontSize": settings.danmuSizeFor(DanmakuViewMode.fullscreen),
      "duration": settings.danmuSpeedFor(DanmakuViewMode.fullscreen),
      // 小窗（画中画）单独一套
      "pipFontSize": settings.danmuSizeFor(DanmakuViewMode.pip),
      "pipDuration": settings.danmuSpeedFor(DanmakuViewMode.pip),
      "opacity": settings.danmuOpacity.value,
      "area": settings.danmuArea.value,
      "strokeWidth": settings.danmuStrokeWidth.value,
      "fontWeight": settings.danmuFontWeight.value,
      "pipEnabled": settings.iosPipDanmaku.value,
      "pipLines": settings.iosPipDanmakuLines.value,
      "pipFrameRate": settings.iosPipFrameRate.value,
      "pipQuality": settings.iosPipQuality.value,
      "externalEnabled": settings.iosExternalDisplay.value,
      "externalSidebar": settings.iosExternalSidebar.value,
    };
    _controller.configureOverlay(args);
    if (_avEngine || _avActive || _avPrewarmed) {
      _av.configure({
        ...args,
        // 0 通话式，1 叠加到系统小窗
        "danmakuMode": settings.iosPipDanmakuMode.value,
        "superChat": settings.iosPipSuperChat.value,
      });
    }
  }

  /// 醒目留言（直播间收到的 SC）：系统播放器小窗顶部按它的颜色显示一会儿
  void addSuperChat(LiveSuperChatMessage message) {
    var settings = AppSettingsController.instance;
    if (_disposed ||
        !_avActive ||
        !settings.iosPipDanmaku.value ||
        !settings.iosPipSuperChat.value) {
      return;
    }
    var price = message.priceText ?? "￥${message.price}";
    var text = message.message.isEmpty
        ? "$price ${message.userName}"
        : "$price ${message.userName}${"：".t}${message.message}";
    _av.sendSuperChat({
      "t": text,
      "c": _parseColor(message.backgroundBottomColor, 0xE54D4D),
    });
  }

  /// "#RRGGBB" 或 "#AARRGGBB" 转成 RGB
  static int _parseColor(String value, int fallback) {
    var hex = value.replaceAll("#", "").trim();
    if (hex.length == 8) hex = hex.substring(2);
    if (hex.length != 6) return fallback;
    return int.tryParse(hex, radix: 16) ?? fallback;
  }

  /// 一条弹幕或聊天消息。[onVideo] 为 false 时只进电视侧栏（播放器里关了弹幕）
  void addMessage({
    required String text,
    required int color,
    int mode = 0,
    String user = "",
    required bool onVideo,
  }) {
    if (_disposed || !_overlayActive || text.isEmpty) return;
    _pendingDanmaku.add({
      "t": text,
      "c": color & 0xFFFFFF,
      "m": mode,
      "u": user,
      "v": onVideo,
    });
    if (_pendingDanmaku.length > 200) {
      _pendingDanmaku.removeRange(0, _pendingDanmaku.length - 200);
    }
    _flushTimer ??= Timer(const Duration(milliseconds: 100), _flushDanmaku);
  }

  void _flushDanmaku() {
    _flushTimer = null;
    if (_disposed || _pendingDanmaku.isEmpty) return;
    var items = List.of(_pendingDanmaku);
    _pendingDanmaku.clear();
    if (_avActive) {
      _av.pushDanmaku(items);
      // 没有投屏时不用再交给 mpv 小窗那一路
      if (!_externalWanted) return;
    }
    _controller.pushDanmaku(items);
  }

  /// 拖动进度、关闭弹幕时清空画面上的弹幕
  void clearDanmaku() {
    _pendingDanmaku.clear();
    if (_disposed || !_overlayActive) return;
    if (_avActive) _av.clearDanmaku();
    _controller.clearDanmaku();
  }

  // ---------------- 投屏 ----------------

  void _updateExternal({bool announce = false}) {
    if (_disposed) return;
    if (_externalWanted) {
      _configure();
      if (_externalTimer == null) {
        _externalTimer = Timer.periodic(
          const Duration(seconds: 1),
          (_) => _syncExternal(),
        );
        _syncExternal();
        if (announce && _controller.isCurrentPage) {
          SmartDialog.showToast("已连接外接显示器，画面和弹幕会显示在电视上".t);
        }
      }
    } else {
      _externalTimer?.cancel();
      _externalTimer = null;
      if (_externalAttached) {
        _externalAttached = false;
        _controller.detachExternal();
      }
    }
  }

  void _syncExternal() {
    // 只有最上层的播放页把画面交给电视
    if (_disposed || !_controller.isCurrentPage) return;
    var textureId = videoController.id.value;
    if (textureId == null) return;
    _externalAttached = true;
    _controller.updateExternal({
      "textureId": textureId,
      "playing": player.state.playing,
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _syncTimer?.cancel();
    _externalTimer?.cancel();
    _flushTimer?.cancel();
    _prewarmTimer?.cancel();
    _lifecycleListener?.dispose();
    for (var worker in _workers) {
      worker.dispose();
    }
    for (var subscription in _subscriptions) {
      subscription.cancel();
    }
    if (_externalAttached) {
      _externalAttached = false;
      _controller.detachExternal();
    }
    // 系统播放器小窗和预热（原生端只有一个，归最上层的页面）
    await _av.dispose();
    // 先把 mpv 换回原来的输出（用过 vo_simplelive 时），再等原生端完成输出切换，
    // 最后恢复视频轨道
    await _customOutput.dispose();
    await _controller.dispose();
    await _transition.dispose();
  }
}
