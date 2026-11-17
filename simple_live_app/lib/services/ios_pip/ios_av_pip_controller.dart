// iOS 系统播放器（AVPlayer）小窗的 Dart 端：与 ios/Runner/AvPlayerPipController.swift 通信。
// 前台仍由 mpv 播放；开小窗时原生端用 AVPlayer 播同一直播间的 HLS，
// 小窗开始时请 Dart 暂停 mpv，关闭时把进度交回来。
import 'package:flutter/services.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_core/simple_live_core.dart';

const _kAvChannel = MethodChannel('simple_live/ios_avpip');

/// 系统播放器的播放进度
class IosAvPipState {
  const IosAvPipState({
    required this.playing,
    required this.position,
    required this.rate,
  });

  factory IosAvPipState.fromMap(Map map) {
    var position = map['positionMillis'];
    var rate = map['rate'];
    return IosAvPipState(
      playing: map['playing'] == true,
      position: Duration(milliseconds: position is num ? position.toInt() : 0),
      rate: rate is num && rate > 0 ? rate.toDouble() : 1.0,
    );
  }

  final bool playing;
  final Duration position;
  final double rate;
}

/// 小窗关闭（或切到后台自动开小窗失败）
class IosAvPipStopInfo {
  const IosAvPipStopInfo({
    required this.restored,
    required this.tookOver,
    required this.prewarmed,
    required this.failed,
    required this.state,
  });

  factory IosAvPipStopInfo.fromMap(Map map) => IosAvPipStopInfo(
        restored: map['restored'] == true,
        tookOver: map['tookOver'] == true,
        prewarmed: map['prewarmed'] == true,
        failed: map['failed'] == true,
        state: map['available'] == true ? IosAvPipState.fromMap(map) : null,
      );

  /// 点了小窗的“返回应用”
  final bool restored;

  /// mpv 已为小窗暂停
  final bool tookOver;

  /// 原生端继续静音预热（直播间开着“退到后台自动小窗”）
  final bool prewarmed;

  /// 连续出错后关闭的
  final bool failed;

  /// 关闭时系统播放器的进度
  final IosAvPipState? state;
}

/// 一个播放页面的系统播放器小窗。原生端只有一个，归最上层的播放页使用
class IosAvPipController {
  IosAvPipController({
    required this.onTakeOver,
    required this.onStarted,
    required this.onStopped,
    required this.onPrewarmEnded,
    required this.requestUrl,
    required this.canRestore,
    required this.onCurrentChanged,
    required this.onReleased,
  }) {
    _bridge = _IosAvPipBridge.attach(this);
  }

  static bool? _supported;

  static Future<bool> isSupported() async {
    var cached = _supported;
    if (cached != null) return cached;
    try {
      var value = await _kAvChannel.invokeMethod<bool>('isSupported') ?? false;
      _supported = value;
      return value;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 小窗即将开始：暂停 mpv，返回 mpv 的进度
  final Future<Map<String, Object>> Function(bool auto) onTakeOver;

  final void Function() onStarted;
  final void Function(IosAvPipStopInfo info) onStopped;

  /// 这次小窗实际用的弹幕方式（原生端开始时告知：通话式、叠加、无弹幕）
  String? startedMode;

  /// 预热的播放器连续出错，原生端已停掉
  final void Function(String reason) onPrewarmEnded;

  /// 断流、地址过期：重新取地址
  final Future<LivePlayUrl?> Function() requestUrl;
  final bool Function() canRestore;

  /// 被新的播放页盖住，或上面的播放页关了
  final void Function() onCurrentChanged;

  /// 原生端被别的播放页接手（那个页面开了小窗或预热），这个页面的小窗和预热已关掉
  final void Function() onReleased;

  late final _IosAvPipBridge _bridge;
  bool _disposed = false;

  /// 是否是最上层的播放页
  bool get isCurrentPage => !_disposed && _bridge.isCurrent(this);

  static Map<String, Object> _urlArgs(LivePlayUrl url) => {
        'urls': url.urls,
        if (url.headers != null) 'headers': url.headers!,
      };

  static Map<String, Object> _rectArgs(Rect rect) => {
        'left': rect.left,
        'top': rect.top,
        'width': rect.width,
        'height': rect.height,
      };

  Future<void> configure(Map<String, Object> args) async {
    if (!isCurrentPage) return;
    await _invoke('configure', args);
  }

  /// 静音预热（只有直播）
  Future<bool> prewarm(LivePlayUrl url, {Rect? sourceRect}) async {
    if (!isCurrentPage) return false;
    await _bridge.acquireNative(this);
    if (!isCurrentPage) return false;
    try {
      return await _kAvChannel.invokeMethod<bool>('prewarm', {
            ..._urlArgs(url),
            'live': true,
            if (sourceRect != null && !sourceRect.isEmpty)
              'sourceRect': _rectArgs(sourceRect),
          }) ==
          true;
    } on PlatformException catch (error) {
      Log.logPrint('iOS AVPiP: prewarm failed: $error');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> stopPrewarm() async {
    if (_disposed || !_bridge.ownsNative(this)) return;
    await _invoke('stopPrewarm');
  }

  /// 开小窗。[url] 为空时用预热的播放器。成功返回 null，否则返回原因
  Future<String?> start({
    LivePlayUrl? url,
    required bool live,
    required bool playing,
    required Duration position,
    required double rate,
    Rect? sourceRect,
  }) async {
    if (!isCurrentPage) return "不是当前页面".t;
    await _bridge.acquireNative(this);
    if (!isCurrentPage) return "不是当前页面".t;
    try {
      var entered = await _kAvChannel.invokeMethod<bool>('start', {
        if (url != null) ..._urlArgs(url),
        'live': live,
        'playing': playing,
        'positionMillis': position.inMilliseconds,
        'rate': rate,
        if (sourceRect != null && !sourceRect.isEmpty)
          'sourceRect': _rectArgs(sourceRect),
      });
      return entered == true ? null : "没有开起来".t;
    } on PlatformException catch (error) {
      return "{message}（{code}）".tf({
            "message": error.message ?? error.code,
            "code": error.code,
          }) +
          (error.details == null ? "" : " ${error.details}");
    } on MissingPluginException {
      return "没有原生实现".t;
    }
  }

  /// 系统播放器现在的进度；没有播放器时为 null
  Future<IosAvPipState?> state() async {
    if (_disposed || !_bridge.ownsNative(this)) return null;
    try {
      var map = await _kAvChannel.invokeMethod<Map>('state');
      if (map == null || map['available'] != true) return null;
      return IosAvPipState.fromMap(map);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> stop(String reason) async {
    if (_disposed || !_bridge.ownsNative(this)) return;
    await _invoke('stop', {'reason': reason});
  }

  Future<void> pushDanmaku(List<Map<String, Object>> items) =>
      _invoke('danmaku', {'items': items});

  Future<void> sendSuperChat(Map<String, Object> item) =>
      _invoke('superChat', item);

  Future<void> clearDanmaku() => _invoke('clearDanmaku');

  Future<void> _invoke(String method, [Object? arguments]) async {
    try {
      await _kAvChannel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      Log.logPrint('iOS AVPiP: $method failed: $error');
    } on MissingPluginException {
      // 没有原生实现
    }
  }

  Future<Object?> _handleMethodCall(String method, Map args) async {
    if (_disposed) {
      return method == 'onRestore' ? false : null;
    }
    switch (method) {
      case 'onTakeOver':
        return await onTakeOver(args['auto'] == true);
      case 'onPipStateChanged':
        if (args['state'] == 'started') {
          startedMode = args['mode']?.toString();
          onStarted();
        } else if (args['state'] == 'stopped') {
          onStopped(IosAvPipStopInfo.fromMap(args));
        }
        return null;
      case 'onRestore':
        return canRestore();
      case 'requestUrl':
        var url = await requestUrl();
        return url == null || url.urls.isEmpty ? null : _urlArgs(url);
      case 'onPrewarmEnded':
        onPrewarmEnded('${args['reason']}');
        return null;
    }
    return null;
  }

  /// 释放原生端（被别的页面接手时）
  Future<void> _releaseNative() => _invoke('dispose');

  Future<void> dispose() async {
    if (_disposed) return;
    var ownsNative = _bridge.ownsNative(this);
    _disposed = true;
    try {
      if (ownsNative) {
        await _releaseNative();
      }
    } finally {
      _bridge.detach(this);
    }
  }
}

/// 所有播放页共用一个原生控制器：按页面先后排队，最上层的页面可以使用
class _IosAvPipBridge {
  static _IosAvPipBridge? _instance;

  static _IosAvPipBridge attach(IosAvPipController owner) {
    var bridge = _instance;
    if (bridge == null) {
      bridge = _IosAvPipBridge();
      _kAvChannel.setMethodCallHandler(bridge._handleMethodCall);
      _instance = bridge;
    }
    var previous = bridge._current;
    bridge._owners.add(owner);
    // 下面的页面被盖住：停掉它的预热
    previous?.onCurrentChanged();
    return bridge;
  }

  final List<IosAvPipController> _owners = [];
  IosAvPipController? _nativeOwner;

  IosAvPipController? get _current => _owners.isEmpty ? null : _owners.last;
  bool isCurrent(IosAvPipController owner) => identical(_current, owner);
  bool ownsNative(IosAvPipController owner) => identical(_nativeOwner, owner);

  Future<void> acquireNative(IosAvPipController owner) async {
    var previous = _nativeOwner;
    if (previous != null && !identical(previous, owner)) {
      _nativeOwner = null;
      // 原生端拆掉时不再回调，直接告诉原来的页面
      await previous._releaseNative();
      if (!previous._disposed) previous.onReleased();
    }
    _nativeOwner = owner;
  }

  Future<Object?> _handleMethodCall(MethodCall call) async {
    var args = call.arguments is Map ? call.arguments as Map : const {};
    if (call.method == 'onDiagnostics') {
      // 开启日志记录后写进日志文件，便于排查小窗被系统结束的原因
      Log.i("iOS 画中画：${args['message']}");
      return null;
    }
    // 只交给正在用原生端的页面（开了小窗或预热的那个）
    var owner = _nativeOwner;
    if (owner == null) {
      return call.method == 'onRestore' ? false : null;
    }
    return owner._handleMethodCall(call.method, args);
  }

  void detach(IosAvPipController owner) {
    var wasCurrent = isCurrent(owner);
    _owners.remove(owner);
    if (identical(_nativeOwner, owner)) _nativeOwner = null;
    if (_owners.isEmpty) {
      _kAvChannel.setMethodCallHandler(null);
      _instance = null;
      return;
    }
    // 上面的页面关了：下面的页面可以重新预热
    if (wasCurrent) _current?.onCurrentChanged();
  }
}
