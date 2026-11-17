import 'dart:async';
import 'dart:math';

import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/script/script_convert.dart';
import 'package:simple_live_core/src/script/script_live_site.dart';
import 'package:simple_live_core/src/script/script_worker.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 脚本的弹幕（doc/live_source_api.md §3）
///
/// start(args) 在直播源的后台 isolate 里执行 `danmaku.start(room, session)`；
/// 会话失败（session.fail、WebSocket 意外断开、start 抛错或超时）后按
/// 2、4、8…最长 30 秒退避，用新的 session 重新调用 start。脚本没有 danmaku 时 start 什么也不做。
class ScriptLiveDanmaku extends LiveDanmaku {
  final ScriptLiveSite site;

  ScriptLiveDanmaku(this.site);

  /// `{ type: "system", text }` 消息（只显示在聊天区）。没有设置时交给 [onClose]，
  /// App 现有的 onClose 处理就是在聊天区加一条系统提示。
  Function(String text)? onSystemMessage;

  /// 从来没有就绪过（第一次连接就失败）时调用；返回 true 表示调用方接手（如内置平台的修正
  /// 改用内置弹幕），这时不再重连
  bool Function(String reason)? onFirstFailure;
  bool _everReady = false;

  /// 第 n 次连续失败后的等待时间：2、4、8、16、30、30…秒
  static Duration retryDelay(int failures) =>
      Duration(seconds: min(30, 1 << min(failures, 5)));

  Map<String, dynamic>? _room;
  bool _running = false;
  int? _sid;
  bool _ready = false;
  int _failures = 0;
  Timer? _retry;
  late final _Listener _listener = _Listener(this);

  /// 正在运行（包括等待重连）
  bool get running => _running;

  @override
  Future start(dynamic args) async {
    await stop();
    if (!site.hasDanmaku) {
      // 脚本没有实现 danmaku：什么也不做
      return;
    }
    var room = _roomFrom(args);
    if (room == null) {
      onClose?.call("没有弹幕参数".t);
      return;
    }
    _room = room;
    _running = true;
    _failures = 0;
    _everReady = false;
    await _connect();
  }

  Map<String, dynamic>? _roomFrom(dynamic args) {
    if (args is ScriptDanmakuArgs) return Map<String, dynamic>.from(args.room);
    if (args is Map) return Map<String, dynamic>.from(args);
    return null;
  }

  Future<void> _connect() async {
    if (!_running) return;
    var worker = site.worker;
    var sid = worker.newSessionId();
    _sid = sid;
    _ready = false;
    try {
      await worker.startSession(sid, _room, _listener);
    } catch (e) {
      _ended(sid, e is CoreError ? e.message : e.toString());
    }
  }

  void _ended(int sid, String reason) {
    if (sid != _sid) return;
    _sid = null;
    unawaited(site.worker.stopSession(sid));
    if (!_running) return;
    if (!_everReady && (onFirstFailure?.call(reason) ?? false)) {
      _running = false;
      return;
    }
    _failures++;
    var delay = retryDelay(_failures);
    onClose?.call("{reason}，{delay} 秒后重新连接".tf({"reason": reason, "delay": delay.inSeconds}));
    _retry?.cancel();
    _retry = Timer(delay, () {
      _retry = null;
      unawaited(_connect());
    });
  }

  void _onReady(int sid) {
    if (sid != _sid || _ready) return;
    _ready = true;
    _everReady = true;
    _failures = 0;
    onReady?.call();
  }

  void _onMessages(int sid, List<dynamic> list) {
    if (sid != _sid) return;
    for (var item in list) {
      if (item is! Map) continue;
      var type = item["type"];
      if (type == "system") {
        var text = scriptString(item["text"]);
        if (text.isEmpty) continue;
        if (onSystemMessage != null) {
          onSystemMessage!(text);
        } else {
          onClose?.call(text);
        }
        continue;
      }
      LiveMessage? message;
      try {
        message = _convert(type, item);
      } catch (_) {
        message = null;
      }
      if (message == null) continue;
      if (!_ready) _onReady(sid);
      onMessage?.call(message);
      if (sid != _sid) return;
    }
  }

  LiveMessage? _convert(dynamic type, Map item) {
    switch (type) {
      case "chat":
        var text = scriptString(item["text"]);
        if (text.isEmpty) return null;
        var face = item["face"]?.toString();
        return LiveMessage(
          type: LiveMessageType.chat,
          userName: scriptString(item["user"]),
          message: text,
          color: scriptColor(item["color"]),
          face: face == null || face.isEmpty ? null : face,
          emotes: scriptEmotes(item["emotes"], text),
          sticker: scriptEmote(item["sticker"]),
          history: scriptBool(item["history"]),
          userId: liveUserId(item["userId"]),
        );
      case "superChat":
        var sc = scriptSuperChat(item);
        return LiveMessage(
          type: LiveMessageType.superChat,
          userName: sc.userName,
          message: sc.message,
          color: LiveMessageColor.white,
          data: sc,
          face: sc.face.isEmpty ? null : sc.face,
          userId: sc.userId,
        );
      case "online":
        return LiveMessage(
          type: LiveMessageType.online,
          userName: "",
          message: "",
          color: LiveMessageColor.white,
          data: scriptInt(item["online"]),
        );
    }
    return null;
  }

  @override
  Future stop() async {
    _running = false;
    _retry?.cancel();
    _retry = null;
    var sid = _sid;
    _sid = null;
    if (sid != null) {
      await site.worker.stopSession(sid);
    }
  }
}

class _Listener implements ScriptSessionListener {
  final ScriptLiveDanmaku danmaku;
  _Listener(this.danmaku);

  @override
  void onSessionReady(int sid) => danmaku._onReady(sid);

  @override
  void onSessionMessages(int sid, List<dynamic> messages) =>
      danmaku._onMessages(sid, messages);

  @override
  void onSessionEnd(int sid, String reason) => danmaku._ended(sid, reason);
}
