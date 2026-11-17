import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 通知（安卓）和锁屏卡片（iOS）上显示的播放状态
enum BackgroundPlaybackStatus { playing, paused, buffering }

/// 通知和锁屏卡片上的内容（听直播）
@immutable
class BackgroundPlaybackInfo {
  /// 主播名
  final String title;

  /// 直播间标题；断流重连时是“正在重新连接”
  final String subtitle;

  final BackgroundPlaybackStatus status;

  /// 头像（PNG）
  final Uint8List? artwork;

  const BackgroundPlaybackInfo({
    required this.title,
    required this.subtitle,
    required this.status,
    this.artwork,
  });

  /// 原生端的参数。通知渠道名和按钮文字在这里翻译好，原生端不查语言表
  Map<String, Object?> toArguments() => {
        "title": title,
        "subtitle": subtitle,
        "state": status.name,
        "artwork": artwork,
        "channelName": "后台播放".t,
        "playLabel": "继续".t,
        "pauseLabel": "暂停".t,
        "stopLabel": "停止".t,
      };

  /// 内容一样就不用再发给原生端（头像只看是不是同一份）
  bool sameAs(BackgroundPlaybackInfo? other) =>
      other != null &&
      title == other.title &&
      subtitle == other.subtitle &&
      status == other.status &&
      identical(artwork, other.artwork);
}

/// 别的应用出声、来电、拔耳机。安卓来自音频焦点和 ACTION_AUDIO_BECOMING_NOISY，
/// iOS 来自音频会话的中断和线路变化
enum AudioFocusEvent {
  /// 焦点回来了（别的应用停了、来电结束）
  gain,

  /// 别的应用长时间占用（比如开始放音乐）：暂停，不自动恢复
  loss,

  /// 短时间占用（来电、语音助手）：暂停，结束后恢复
  lossTransient,

  /// 短时间占用、可以小声（导航播报）：压低音量
  duck,

  /// 中断结束了，但系统说不要自动恢复（iOS）
  ended,

  /// 耳机拔掉了：暂停
  noisy;

  static AudioFocusEvent? parse(Object? name) {
    for (var e in values) {
      if (e.name == name) return e;
    }
    return null;
  }
}

/// 音频焦点要做的事，按顺序执行
enum AudioFocusAction { pause, duck, restoreVolume, resume }

/// 别的应用出声时暂停或压低音量，对方停了以后恢复。只做决定，不碰播放器
class AudioFocusPolicy {
  /// 压低音量时的比例
  static const double duckVolume = 0.2;

  /// 因为短时间占用暂停的：焦点回来时继续
  bool pausedByFocus = false;

  /// 音量压低着
  bool ducked = false;

  /// [playing] 是现在在不在播；[mixWithOthers] 是设置“与其他应用同时播放”
  List<AudioFocusAction> decide(
    AudioFocusEvent event, {
    required bool playing,
    required bool mixWithOthers,
  }) {
    var actions = <AudioFocusAction>[];
    void restore() {
      if (ducked) {
        ducked = false;
        actions.add(AudioFocusAction.restoreVolume);
      }
    }

    switch (event) {
      case AudioFocusEvent.gain:
        restore();
        if (pausedByFocus) {
          pausedByFocus = false;
          actions.add(AudioFocusAction.resume);
        }
        break;
      case AudioFocusEvent.ended:
        restore();
        pausedByFocus = false;
        break;
      case AudioFocusEvent.loss:
        // 同时播放时别的应用出声不管
        if (mixWithOthers) break;
        restore();
        pausedByFocus = false;
        if (playing) actions.add(AudioFocusAction.pause);
        break;
      case AudioFocusEvent.lossTransient:
        // 来电和语音助手：同时播放时也要停
        if (playing) {
          pausedByFocus = true;
          actions.add(AudioFocusAction.pause);
        }
        break;
      case AudioFocusEvent.duck:
        if (mixWithOthers || !playing || ducked) break;
        ducked = true;
        actions.add(AudioFocusAction.duck);
        break;
      case AudioFocusEvent.noisy:
        restore();
        pausedByFocus = false;
        if (playing) actions.add(AudioFocusAction.pause);
        break;
    }
    return actions;
  }
}

/// 一个直播间收通知按钮和音频焦点的回调
class BackgroundPlaybackClient {
  /// 通知、锁屏上的按钮：play、pause、toggle、stop
  final void Function(String action) onAction;
  final void Function(AudioFocusEvent event) onFocus;
  BackgroundPlaybackClient({required this.onAction, required this.onFocus});
}

/// 后台播放的原生部分：
/// - 安卓：前台服务（mediaPlayback 类型，媒体通知、MediaSession、WifiLock），音频焦点；
/// - iOS：锁屏和控制中心的“正在播放”，音频会话（与其他应用同时播放），中断和拔耳机。
/// 电脑上什么都不做。原生端见 BackgroundPlayback.kt、BackgroundAudio.swift
class BackgroundPlayback {
  BackgroundPlayback({MethodChannel? channel, bool? supported})
      : _channel = channel ?? const MethodChannel(channelName),
        supported = supported ?? (Platform.isAndroid || Platform.isIOS);

  static const channelName = "simple_live/background_playback";

  static BackgroundPlayback? _instance;
  static BackgroundPlayback get instance => _instance ??= BackgroundPlayback();

  /// 测试里换成假的
  static set instance(BackgroundPlayback? value) => _instance = value;

  final MethodChannel _channel;

  /// 安卓和 iOS
  final bool supported;

  /// 打开着的直播间，最后一个在最上面
  final List<BackgroundPlaybackClient> _clients = [];
  bool _handlerSet = false;

  /// 通知和锁屏卡片归谁（同时只有一个）
  BackgroundPlaybackClient? _serviceOwner;
  BackgroundPlaybackInfo? _lastInfo;

  /// 音频焦点归谁
  BackgroundPlaybackClient? _focusOwner;

  void attach(BackgroundPlaybackClient client) {
    _clients
      ..remove(client)
      ..add(client);
    if (supported && !_handlerSet) {
      _handlerSet = true;
      _channel.setMethodCallHandler(_onCall);
    }
  }

  void detach(BackgroundPlaybackClient client) {
    _clients.remove(client);
    if (identical(_serviceOwner, client)) _serviceOwner = null;
    if (identical(_focusOwner, client)) _focusOwner = null;
    if (_clients.isEmpty && _handlerSet) {
      _handlerSet = false;
      _channel.setMethodCallHandler(null);
    }
  }

  BackgroundPlaybackClient? get _top => _clients.isEmpty ? null : _clients.last;

  Future<Object?> _onCall(MethodCall call) async {
    var args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case "onAction":
        var action = args["action"];
        if (action is String) (_serviceOwner ?? _top)?.onAction(action);
        break;
      case "onFocus":
        var event = AudioFocusEvent.parse(args["event"]);
        if (event != null) (_focusOwner ?? _top)?.onFocus(event);
        break;
    }
    return null;
  }

  /// 通知或锁屏卡片是不是 [owner] 的
  bool isShowing(BackgroundPlaybackClient owner) =>
      identical(owner, _serviceOwner);

  /// 显示通知（安卓启动前台服务，要在 App 还在前台时调用）或锁屏卡片（iOS）
  Future<bool> start(
    BackgroundPlaybackClient owner,
    BackgroundPlaybackInfo info,
  ) async {
    if (!supported) return false;
    _serviceOwner = owner;
    _lastInfo = info;
    try {
      return await _channel.invokeMethod<bool>(
            "startService",
            info.toArguments(),
          ) ??
          false;
    } on PlatformException catch (e) {
      Log.d("后台播放没有启动：$e");
    } on MissingPluginException {
      // 没有原生实现
    }
    return false;
  }

  /// 换内容（换直播间、暂停、断流）：只更新通知，不重开服务
  Future<void> update(
    BackgroundPlaybackClient owner,
    BackgroundPlaybackInfo info,
  ) async {
    if (!supported || !identical(owner, _serviceOwner) || info.sameAs(_lastInfo)) {
      return;
    }
    _lastInfo = info;
    await _invoke("updateService", info.toArguments());
  }

  /// 收起通知、停掉前台服务，或者清掉锁屏卡片
  Future<void> stop(BackgroundPlaybackClient owner) async {
    if (!supported || !identical(owner, _serviceOwner)) return;
    _serviceOwner = null;
    _lastInfo = null;
    await _invoke("stopService");
  }

  /// 在播（或者因为来电等暂停着、等着恢复）时为 true：安卓申请音频焦点、监听拔耳机；
  /// iOS 按 [mix] 设置音频会话，转发中断和拔耳机。[mix] 是“与其他应用同时播放”
  Future<void> setAudioActive(
    BackgroundPlaybackClient owner, {
    required bool active,
    required bool mix,
  }) async {
    if (!supported) return;
    if (active) {
      _focusOwner = owner;
    } else if (identical(owner, _focusOwner)) {
      _focusOwner = null;
    } else {
      // 别的直播间占着焦点，这里不用放
      return;
    }
    await _invoke("audioActive", {"active": active, "mix": mix});
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (e) {
      Log.d("后台播放 $method 失败：$e");
    } on MissingPluginException {
      // 没有原生实现
    }
  }
}
