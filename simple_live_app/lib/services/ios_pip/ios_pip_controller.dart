// iOS 画中画的 Dart 端：与 ios/Runner/IosPictureInPictureController.swift 通信。
// Adapted from Kazumi (GPL-3.0), Predidit/Kazumi PR #2646.
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/ios_pip/async_utils.dart';

enum IosPipEntryResult { entered, unsupported, notReady, failed }

const _kChannel = MethodChannel('simple_live/ios_pip');

class IosPipPlaybackState {
  const IosPipPlaybackState({
    required this.textureId,
    required this.playing,
    required this.position,
    required this.duration,
    required this.rate,
    required this.sourceRect,
  });

  final int? textureId;
  final bool playing;
  final Duration position;

  /// 直播传 [Duration.zero]：系统按直播显示，没有进度条
  final Duration duration;
  final double rate;

  /// UIKit 的逻辑坐标（point），与 Flutter 的逻辑像素一致
  final Rect? sourceRect;

  Map<String, Object> toArguments() => {
        if (textureId != null) 'textureId': textureId!,
        'playing': playing,
        'positionMillis': position.inMilliseconds,
        'durationMillis': duration.inMilliseconds,
        'rate': rate,
        if (sourceRect != null)
          'sourceRect': {
            'left': sourceRect!.left,
            'top': sourceRect!.top,
            'width': sourceRect!.width,
            'height': sourceRect!.height,
          },
      };
}

/// 一个播放页面的画中画会话；页面保留原来的播放器，原生端只显示它的画面并转发操作
class IosPipController {
  /// 外接显示器（屏幕镜像）是否连接；所有播放页共用
  static final externalDisplayConnected = false.obs;

  static Future<bool> externalStatus() async {
    try {
      return await _kChannel.invokeMethod<bool>('externalStatus') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> isSupported() async {
    try {
      return await _kChannel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  IosPipController({
    required this.playbackState,
    required this.playerHandle,
    required this.suspendVideo,
    required this.resumeVideo,
    required this.switchCustomOutput,
    required this.onPlay,
    required this.onPause,
    required this.onSeek,
    required this.onModeChanged,
    required this.canRestore,
  }) {
    _bridge = _IosPipChannelBridge.attach(this, _kChannel);
  }

  final IosPipPlaybackState Function() playbackState;
  final Future<int?> Function() playerHandle;
  final Future<bool> Function(int handle) suspendVideo;
  final Future<bool> Function(int handle, {required bool waitForTexture})
      resumeVideo;

  /// 后台小窗改用（或换回）补丁版 libmpv 的 vo_simplelive，由原生端发起
  final Future<bool> Function(int handle, bool enabled) switchCustomOutput;
  final Future<void> Function() onPlay;
  final Future<void> Function() onPause;
  final Future<void> Function(Duration position) onSeek;
  final void Function(bool active, bool restored) onModeChanged;
  final bool Function() canRestore;
  late final _IosPipChannelBridge _bridge;
  final AsyncSingleFlight<IosPipEntryResult> _entry = AsyncSingleFlight();
  Future<void>? _disposeFuture;
  bool _active = false;
  bool _disposed = false;

  bool get _ownsPage => !_disposed && _bridge.isCurrent(this);
  bool get isActive => _ownsPage && _active;

  /// 是否是最上层的播放页：只有它把画面和弹幕交给原生端
  bool get isCurrentPage => _ownsPage;

  /// 弹幕样式和画中画/投屏设置
  Future<void> configureOverlay(Map<String, Object> args) =>
      _invoke('configureOverlay', args);

  /// 弹幕/聊天消息：画中画画进小窗，投屏显示在电视上
  Future<void> pushDanmaku(List<Map<String, Object>> items) =>
      _invoke('danmaku', {'items': items});

  Future<void> clearDanmaku() => _invoke('clearDanmaku');

  /// 投屏：告诉原生端当前播放页的画面
  Future<void> updateExternal(Map<String, Object> args) =>
      _invoke('updateExternal', args);

  /// 投屏：播放页关闭，电视恢复镜像
  Future<void> detachExternal() => _invoke('detachExternal');

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _kChannel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      Log.logPrint('iOS PiP: $method failed: $error');
    } on MissingPluginException {
      // 没有原生实现
    }
  }

  /// 小窗或正在进入小窗时，切到后台要继续播放
  bool get keepPlaybackInBackground =>
      _ownsPage && (_active || _entry.isRunning);

  Future<IosPipEntryResult> enter() async {
    if (!_ownsPage) return IosPipEntryResult.failed;
    if (_active) return IosPipEntryResult.entered;
    if (_entry.isRunning) return IosPipEntryResult.notReady;
    var state = playbackState();
    if (state.textureId == null || state.sourceRect?.isEmpty != false) {
      return IosPipEntryResult.notReady;
    }
    return _entry.run(() => _enter(state));
  }

  Future<IosPipEntryResult> _enter(IosPipPlaybackState state) async {
    try {
      var supported = await _kChannel.invokeMethod<bool>('isSupported');
      if (!_ownsPage) return IosPipEntryResult.failed;
      if (supported != true) return IosPipEntryResult.unsupported;
      var handle = await playerHandle();
      if (!_ownsPage) return IosPipEntryResult.failed;
      if (handle == null) return IosPipEntryResult.notReady;
      if (!await _bridge.acquireNative(this) || !_ownsPage) {
        return IosPipEntryResult.failed;
      }
      var prepared = await _kChannel.invokeMethod<bool>('prepare', {
        ...state.toArguments(),
        'handle': handle,
      });
      if (!_ownsPage) return IosPipEntryResult.failed;
      if (prepared != true) return IosPipEntryResult.notReady;
      // 准备阶段会重建原生输出、换新纹理，进入前先同步一次最新状态
      await _kChannel.invokeMethod<void>(
        'updatePlaybackState',
        playbackState().toArguments(),
      );
      if (!_ownsPage) return IosPipEntryResult.failed;
      var entered = await _kChannel.invokeMethod<bool>('enter');
      if (!_ownsPage) return IosPipEntryResult.failed;
      _active = entered == true;
      return _active ? IosPipEntryResult.entered : IosPipEntryResult.failed;
    } on PlatformException catch (error) {
      Log.logPrint('iOS PiP: entry failed: ${error.code} ${error.message} '
          '${error.details}');
      return error.code == 'pip_not_ready'
          ? IosPipEntryResult.notReady
          : IosPipEntryResult.failed;
    } on MissingPluginException {
      return IosPipEntryResult.unsupported;
    }
  }

  Future<void> synchronize() async {
    if (!keepPlaybackInBackground || !_bridge.ownsNative(this)) return;
    try {
      await _kChannel.invokeMethod<void>(
        'updatePlaybackState',
        playbackState().toArguments(),
      );
    } on PlatformException catch (error) {
      Log.logPrint('iOS PiP: state synchronization failed: $error');
    } on MissingPluginException {
      // 没有原生实现时不会建立会话
    }
  }

  Future<Object?> _handleMethodCall(MethodCall call) async {
    var args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'onVideoOutputWillChange':
        var handle = args['handle'];
        return handle is int ? await suspendVideo(handle) : false;
      case 'onVideoOutputDidChange':
        var handle = args['handle'];
        return handle is int
            ? await resumeVideo(
                handle,
                waitForTexture: args['waitForTexture'] != false,
              )
            : false;
      case 'onCustomOutput':
        var handle = args['handle'];
        return handle is int
            ? await switchCustomOutput(handle, args['enabled'] == true)
            : false;
      case 'onModeChanged':
        if (!_ownsPage) return null;
        if (args['isInPipMode'] == true && !keepPlaybackInBackground) {
          return null;
        }
        _active = args['isInPipMode'] == true;
        onModeChanged(_active, args['restored'] == true);
        return null;
      case 'onRestore':
        return _ownsPage && canRestore();
      case 'onAction':
        if (!keepPlaybackInBackground) return null;
        switch (args['action']) {
          case 'play':
            await onPlay();
            break;
          case 'pause':
            await onPause();
            break;
          case 'seek':
            var position = args['positionMillis'];
            if (position is num && position.isFinite) {
              var duration = playbackState().duration.inMilliseconds;
              var target = position.toInt();
              await onSeek(
                Duration(
                  milliseconds: duration > 0
                      ? target.clamp(0, duration)
                      : (target < 0 ? 0 : target),
                ),
              );
            }
            break;
        }
        await synchronize();
        return null;
    }
    return null;
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _active = false;
    try {
      if (_bridge.shouldDisposeNative(this)) {
        // 原生端等进行中的输出切换完成后才返回
        await _kChannel.invokeMethod<void>('dispose');
      }
    } on PlatformException catch (error) {
      Log.logPrint('iOS PiP: disposal failed: $error');
    } on MissingPluginException {
      // 不支持的系统没有原生会话
    } finally {
      _bridge.detach(this);
    }
  }
}

/// 同名 MethodChannel 共用一个处理器；旧页面释放、新页面接入时保持稳定
class _IosPipChannelBridge {
  _IosPipChannelBridge(this.channel);

  static final _bridges = <String, _IosPipChannelBridge>{};

  static _IosPipChannelBridge attach(
    IosPipController owner,
    MethodChannel channel,
  ) {
    var bridge = _bridges.putIfAbsent(channel.name, () {
      var value = _IosPipChannelBridge(channel);
      channel.setMethodCallHandler(value.handleMethodCall);
      return value;
    });
    bridge._owners.add(owner);
    return bridge;
  }

  final MethodChannel channel;
  final List<IosPipController> _owners = [];
  IosPipController? _nativeOwner;

  IosPipController? get _current => _owners.isEmpty ? null : _owners.last;
  bool isCurrent(IosPipController owner) => identical(_current, owner);
  bool ownsNative(IosPipController owner) => identical(_nativeOwner, owner);

  Future<bool> acquireNative(IosPipController owner) async {
    var previous = _nativeOwner;
    if (previous != null && !identical(previous, owner)) {
      await previous.dispose();
    }
    if (!owner._ownsPage) return false;
    _nativeOwner = owner;
    return true;
  }

  bool shouldDisposeNative(IosPipController owner) =>
      identical(_nativeOwner, owner) ||
      (_nativeOwner == null && isCurrent(owner));

  Future<Object?> handleMethodCall(MethodCall call) async {
    var args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'onExternalDisplayChanged':
        IosPipController.externalDisplayConnected.value =
            args['connected'] == true;
        return null;
      case 'onDiagnostics':
        // 开启日志记录后写进日志文件，便于排查小窗被系统结束的原因
        Log.i("iOS 画中画：${args['message']}");
        return null;
    }
    // 输出切换属于原生会话所在的播放器，页面正在释放时也要处理完
    var outputChange = call.method == 'onVideoOutputWillChange' ||
        call.method == 'onVideoOutputDidChange' ||
        call.method == 'onCustomOutput';
    var owner = outputChange ? (_nativeOwner ?? _current) : _current;
    if (owner == null) return false;
    // 正在释放的原生会话发来的播放操作不能传给新页面
    if (!outputChange &&
        (_nativeOwner != null && !identical(_nativeOwner, owner))) {
      return false;
    }
    return owner._handleMethodCall(call);
  }

  void detach(IosPipController owner) {
    _owners.remove(owner);
    if (identical(_nativeOwner, owner)) _nativeOwner = null;
    if (_owners.isEmpty) {
      channel.setMethodCallHandler(null);
      _bridges.remove(channel.name);
    }
  }
}
