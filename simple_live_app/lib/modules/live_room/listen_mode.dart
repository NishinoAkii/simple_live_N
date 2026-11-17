import 'dart:async';

import 'package:extended_image/extended_image.dart'
    show ExtendedNetworkImageProvider;
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_playback.dart';
import 'package:simple_live_app/services/background_playback.dart';
import 'package:simple_live_app/services/live_notify_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// 头像下载（多半已在磁盘缓存里）后转成 192×192 的 PNG，给通知和锁屏卡片用
Future<Uint8List?> loadListenArtwork(String url) async {
  try {
    if (url.startsWith("//")) {
      url = "https:$url";
    }
    var bytes =
        await ExtendedNetworkImageProvider(url, cache: true).getNetworkImageData();
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    return await compute(LiveNotifyService.avatarPng, bytes);
  } catch (e) {
    Log.d("听直播：头像读取失败：$e");
    return null;
  }
}

/// 听直播和后台播放在一个直播间里的状态
class ListenModeState {
  /// 开着听直播：视频轨关掉，画面的位置显示主播卡片，视频上不出弹幕
  final active = false.obs;

  /// 正在断流重连（卡片和通知上显示“正在重新连接”）
  final reconnecting = false.obs;

  /// 点了通知或锁屏上的“停止”：暂停着，通知收起；在卡片上点继续时再显示
  bool stopped = false;

  /// 别的应用出声、来电、拔耳机时怎么办
  final focus = AudioFocusPolicy();

  /// 头像 PNG（测试里换掉，不联网）
  Future<Uint8List?> Function(String url) loadArtwork = loadListenArtwork;

  /// 屏幕常亮：听直播时关掉，屏幕可以自己熄灭（测试里换掉）
  Future<void> Function(bool on) keepScreenOn = _keepScreenOn;

  static Future<void> _keepScreenOn(bool on) async {
    try {
      await (on ? WakelockPlus.enable() : WakelockPlus.disable());
    } catch (e) {
      Log.logPrint(e);
    }
  }

  Uint8List? artwork;
  String _artworkUrl = "";

  late final BackgroundPlaybackClient client;
  final List<Worker> _workers = [];
  final List<StreamSubscription> _subscriptions = [];
  Timer? _ticker;
  bool _initialized = false;
}

/// 听直播：入口在直播间“更多”里。关掉视频轨（每次重新打开播放都再关一次），
/// 视频弹幕停掉，聊天照常，画面的位置换成主播卡片；不开小窗。
/// 手机上同时显示媒体通知（安卓前台服务）或锁屏卡片（iOS），可以在后台一直听
extension LiveRoomListen on LiveRoomController {
  BackgroundPlayback get _background => BackgroundPlayback.instance;

  /// 直播间打开时调用
  void initListenMode() {
    var state = listen;
    if (state._initialized) return;
    state._initialized = true;
    state.client = BackgroundPlaybackClient(
      onAction: onBackgroundAction,
      onFocus: onAudioFocus,
    );
    _background.attach(state.client);
    var settings = AppSettingsController.instance;
    state._subscriptions.addAll([
      // 打开、换线路、断流重连以后 mpv 换了内容：视频轨再关一次
      player.stream.playlist.listen((_) => _keepVideoOff()),
      // 安卓兼容模式的输出换画布时会把视频轨打开：有了画面参数就再关
      player.stream.videoParams.listen((_) => _keepVideoOff()),
      // iOS：mpv 重开音频输出时会把音频会话改回默认，“同时播放”要再设一次
      player.stream.audioParams.listen((_) {
        if (settings.playWithOthers.value && livePause.playing.value) {
          syncAudioActive();
        }
      }),
    ]);
    state._workers.addAll([
      ever<bool>(livePause.playing, (playing) {
        // 播放器开始播时会打开屏幕常亮，听直播时再关掉
        if (playing && state.active.value) state.keepScreenOn(false);
        syncAudioActive();
        syncListenInfo();
      }),
      ever<bool>(livePause.paused, (paused) {
        if (!paused) {
          // 继续了（自己点的，或者焦点回来了）：不再等焦点
          state.focus.pausedByFocus = false;
          if (state.stopped && state.active.value) {
            state.stopped = false;
            _startBackground();
          }
        }
        syncAudioActive();
        syncListenInfo();
      }),
      ever<bool>(settings.playWithOthers, (_) => syncAudioActive()),
      ever(detail, (_) {
        _loadArtwork();
        syncListenInfo();
      }),
      ever<bool>(liveStatus, (_) => syncListenInfo()),
    ]);
    syncAudioActive();
  }

  /// 直播间关闭时调用
  void disposeListenMode() {
    var state = listen;
    if (!state._initialized) return;
    state._ticker?.cancel();
    for (var worker in state._workers) {
      worker.dispose();
    }
    state._workers.clear();
    for (var subscription in state._subscriptions) {
      subscription.cancel();
    }
    state._subscriptions.clear();
    _background.stop(state.client);
    _background.setAudioActive(state.client, active: false, mix: false);
    _background.detach(state.client);
  }

  void toggleListenMode() {
    if (listen.active.value) {
      exitListenMode();
    } else {
      enterListenMode();
    }
  }

  Future<void> enterListenMode() async {
    var state = listen;
    if (state.active.value || isClosed) return;
    // 卡片在页面里，全屏和电脑小窗都先退出来
    if (smallWindowState.value) {
      exitSmallWindow();
    } else if (fullScreenState.value) {
      exitFull();
    }
    state.active.value = true;
    state.stopped = false;
    state.keepScreenOn(false);
    clearDanmaku();
    // iOS：不再预热系统播放器，切到后台时不会自动开小窗
    iosPip?.refreshPrewarm();
    state._ticker?.cancel();
    state._ticker = Timer.periodic(
      const Duration(seconds: 2),
      (_) => syncListenInfo(),
    );
    await _keepVideoOff();
    await _startBackground();
  }

  /// 恢复画面
  Future<void> exitListenMode() async {
    var state = listen;
    if (!state.active.value) return;
    state.active.value = false;
    state.stopped = false;
    state.reconnecting.value = false;
    state._ticker?.cancel();
    await _background.stop(state.client);
    iosPip?.refreshPrewarm();
    if (livePause.playing.value) state.keepScreenOn(true);
    try {
      await player.setVideoTrack(VideoTrack.auto());
    } catch (e) {
      Log.logPrint(e);
    }
  }

  Future<void> _keepVideoOff() async {
    if (!listen.active.value || isClosed) return;
    try {
      await player.setVideoTrack(VideoTrack.no());
    } catch (e) {
      Log.logPrint(e);
    }
  }

  Future<void> _startBackground() async {
    var state = listen;
    if (!state.active.value || state.stopped || _background.isShowing(state.client)) {
      return;
    }
    _loadArtwork();
    var shown = await _background.start(state.client, listenInfo());
    if (!shown && _background.supported) {
      Log.d("听直播：通知或锁屏卡片没有显示出来");
    }
  }

  Future<void> _loadArtwork() async {
    var state = listen;
    var url = detail.value?.userAvatar ?? "";
    if (!state.active.value || url == state._artworkUrl) return;
    state._artworkUrl = url;
    state.artwork = null;
    if (url.isEmpty) return;
    var png = await state.loadArtwork(url);
    if (isClosed || url != state._artworkUrl) return;
    state.artwork = png;
    syncListenInfo();
  }

  /// 通知和锁屏卡片上的内容
  BackgroundPlaybackInfo listenInfo() {
    var room = detail.value;
    var status = BackgroundPlaybackStatus.playing;
    var subtitle = room?.title ?? "";
    if (!liveStatus.value) {
      status = BackgroundPlaybackStatus.paused;
      subtitle = "未开播".t;
    } else if (recovering) {
      status = BackgroundPlaybackStatus.buffering;
      subtitle = "正在重新连接".t;
    } else if (showResume) {
      status = BackgroundPlaybackStatus.paused;
    }
    var name = room?.userName ?? "";
    return BackgroundPlaybackInfo(
      title: name.isEmpty ? site.name : name,
      subtitle: subtitle,
      status: status,
      artwork: listen.artwork,
    );
  }

  /// 状态变了：更新卡片上的“正在重新连接”和通知
  void syncListenInfo() {
    var state = listen;
    if (!state.active.value || isClosed) return;
    state.reconnecting.value = recovering && liveStatus.value;
    if (state.stopped) return;
    _background.update(state.client, listenInfo());
  }

  /// 在播，或者因为来电等暂停着、等焦点回来时占着音频焦点
  void syncAudioActive() {
    var state = listen;
    if (!state._initialized) return;
    var active = !isClosed &&
        (livePause.playing.value || state.focus.pausedByFocus);
    _background.setAudioActive(
      state.client,
      active: active,
      mix: AppSettingsController.instance.playWithOthers.value,
    );
  }

  /// 通知、锁屏、耳机线控上的按钮
  void onBackgroundAction(String action) {
    if (isClosed) return;
    switch (action) {
      case "play":
        if (showResume) resumeLive();
        break;
      case "pause":
        if (!showResume) pauseLive();
        break;
      case "toggle":
        toggleLivePause();
        break;
      case "stop":
        stopListenPlayback();
        break;
    }
  }

  /// 通知、锁屏上的“停止”：暂停，收起通知和锁屏卡片；在卡片上点继续时再显示
  Future<void> stopListenPlayback() async {
    var state = listen;
    state.stopped = true;
    await _background.stop(state.client);
    await pauseLive();
  }

  /// 别的应用出声、来电、拔耳机（安卓音频焦点，iOS 音频中断）
  void onAudioFocus(AudioFocusEvent event) {
    if (isClosed) return;
    // iOS 画中画开着时它自己处理中断
    if (iosPip?.active.value ?? false) return;
    var settings = AppSettingsController.instance;
    var playing = livePause.playing.value && !livePause.paused.value;
    var actions = listen.focus.decide(
      event,
      playing: playing,
      mixWithOthers: settings.playWithOthers.value,
    );
    for (var action in actions) {
      switch (action) {
        case AudioFocusAction.pause:
          pauseLive();
          break;
        case AudioFocusAction.duck:
          player.setVolume(
              settings.playerVolume.value * AudioFocusPolicy.duckVolume);
          break;
        case AudioFocusAction.restoreVolume:
          player.setVolume(settings.playerVolume.value);
          break;
        case AudioFocusAction.resume:
          resumeLive();
          break;
      }
    }
  }
}
