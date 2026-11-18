// 主 isolate 里代表一个直播源的后台 isolate
//
// 第一次调用时启动后台 isolate（每个源一个，内含独立的 QuickJS 引擎），
// 空闲几分钟后关闭。每次调用有超时；连续超时或脚本同步执行超时（被引擎中断）
// 时丢弃这个 isolate，下次调用重新启动。
//
// 引擎装了中断回调，同步死循环会在期限（默认 10 秒）后被打断；如果 isolate 仍然
// 没有响应（比如卡在原生代码里），关闭请求 2 秒后直接 kill —— 卡在 FFI 调用里的
// isolate 要等调用返回才会真正退出，期间它的引擎内存不会释放。

import 'dart:async';
import 'dart:isolate';

import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/script/live_source_overrides.dart';
import 'package:simple_live_core/src/script/script_host.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 弹幕会话的事件
abstract class ScriptSessionListener {
  void onSessionReady(int sid);
  void onSessionMessages(int sid, List<dynamic> messages);
  void onSessionEnd(int sid, String reason);
}

/// 运行参数（测试里可以调小）
class ScriptWorkerSettings {
  /// 每次调用的超时
  static Duration callTimeout = const Duration(seconds: 20);

  /// 没有调用、没有弹幕会话多久后关闭后台 isolate
  static Duration idleTimeout = const Duration(minutes: 3);

  /// 单次同步执行的期限，超过后中断脚本并重启
  static Duration sliceTimeout = const Duration(seconds: 10);

  /// 连续超时几次后重启
  static int maxTimeouts = 2;

  /// hls.rewrite 单次同步执行的期限（超过后这次用原列表）
  static Duration rewriteTimeout = const Duration(milliseconds: 200);

  /// 只给测试用：useAccount 带登录信息的主机（替换 kBuiltInAccountHosts，平台 id → 主机），
  /// 设置后这些主机的 http 请求也带（本机的假服务器没有 https）。App 里永远是 null
  static Map<String, List<String>>? accountHostsForTest;
}

class _Pending {
  final Completer<dynamic> completer;
  final String label;
  final _Connection conn;
  Timer? timer;
  _Pending(this.completer, this.label, this.conn);
}

class _Connection {
  final ReceivePort port = ReceivePort();
  final ReceivePort exitPort = ReceivePort();
  final ReceivePort errorPort = ReceivePort();
  Isolate? isolate;
  SendPort? sendPort;
  final Completer<SendPort> hello = Completer();
  final Completer<void> loaded = Completer();
  bool closed = false;
  Timer? killTimer;

  /// isolate 真正退出（或被强制结束）时完成。退出前它还会把设置写回 settings.json，
  /// 下一个 isolate 要等它完成再启动，不然可能读到旧的设置
  final Completer<void> gone = Completer();

  void send(Map<String, dynamic> message) {
    if (!closed) sendPort?.send(message);
  }

  void close() {
    if (closed) return;
    closed = true;
    sendPort?.send({"op": "shutdown"});
    killTimer = Timer(const Duration(seconds: 2), () {
      isolate?.kill(priority: Isolate.immediate);
      _closePorts();
    });
  }

  void _closePorts() {
    killTimer?.cancel();
    port.close();
    exitPort.close();
    errorPort.close();
    if (!gone.isCompleted) gone.complete();
  }
}

class ScriptSourceWorker {
  final String key;
  final String name;
  final String scriptPath;
  final String dataDirectory;
  final String appVersion;

  ScriptSourceWorker({
    required this.key,
    required this.name,
    required this.scriptPath,
    required this.dataDirectory,
    required this.appVersion,
  });

  _Connection? _conn;
  Future<_Connection>? _starting;

  /// 修正用的内置平台帐号（useAccount），变了时在下一次请求前交给后台 isolate
  LiveSourceAccountAuth? _auth;
  _Connection? _authSentTo;

  LiveSourceAccountAuth? get accountAuth => _auth;
  set accountAuth(LiveSourceAccountAuth? value) {
    var next = value == null || value.isEmpty ? null : value;
    if (next == _auth) return;
    _auth = next;
    _authSentTo = null;
  }

  final Map<int, _Pending> _calls = {};
  final Map<int, ScriptSessionListener> _sessions = {};
  int _nextId = 0;
  int _timeouts = 0;
  Timer? _idle;
  bool _disposed = false;

  static int _sessionSeq = 0;

  /// 后台 isolate 是否在运行
  bool get running => _conn != null;

  int newSessionId() => ++_sessionSeq;

  /// [countTimeout] 为 false 时超时不算进“连续超时就重启”（联想这类随手调用的）
  Future<dynamic> call(
    String method,
    List<dynamic> args, {
    Duration? timeout,
    bool countTimeout = true,
  }) {
    return _request(
      {"op": "call", "m": method, "a": args},
      label: "$method()",
      timeout: timeout,
      countTimeout: countTimeout,
    );
  }

  Future<void> startSession(
    int sid,
    dynamic room,
    ScriptSessionListener listener,
  ) async {
    _sessions[sid] = listener;
    try {
      await _request({
        "op": "dmStart",
        "sid": sid,
        "room": room,
      }, label: "danmaku.start()");
    } catch (_) {
      _sessions.remove(sid);
      // 超时时后台的会话还在：让它清理（id 为 0 不需要回复）
      _conn?.send({"op": "dmStop", "id": 0, "sid": sid});
      rethrow;
    }
  }

  Future<void> stopSession(int sid) async {
    var hadSession = _sessions.remove(sid) != null;
    if (_conn == null || !hadSession) {
      _scheduleIdle();
      return;
    }
    try {
      await _request(
        {"op": "dmStop", "sid": sid},
        label: "danmaku.stop()",
        timeout: const Duration(seconds: 5),
      );
    } catch (_) {}
  }

  Future<String> getCookies(String url) async {
    return (await _request({
      "op": "getCookies",
      "url": url,
    }, label: "getCookies")).toString();
  }

  Future<void> setCookies(String url, String cookies) async {
    await _request({
      "op": "setCookies",
      "url": url,
      "cookies": cookies,
    }, label: "setCookies");
  }

  /// 删除发往 [url] 的全部 Cookie，返回删除的个数
  Future<int> clearCookies(String url) async {
    var v = await _request({
      "op": "clearCookies",
      "url": url,
    }, label: "clearCookies");
    return v is int ? v : 0;
  }

  /// 设置项的当前值（没改过的为默认值）
  Future<Map<String, dynamic>> getSettings() async {
    var v = await _request({"op": "getSettings"}, label: "读取设置".t);
    return v is Map ? Map<String, dynamic>.from(v) : {};
  }

  /// 改设置项（null 恢复默认），返回改后的全部值
  Future<Map<String, dynamic>> setSettings(Map<String, dynamic> values) async {
    var v = await _request({
      "op": "setSettings",
      "values": values,
    }, label: "保存设置".t);
    return v is Map ? Map<String, dynamic>.from(v) : {};
  }

  /// 调用脚本的 hls.rewrite(text, info)，返回改过的列表；null 表示不改。
  /// 同步执行限时 [ScriptWorkerSettings.rewriteTimeout]；超时不算进“连续超时就重启”
  Future<String?> hlsRewrite(String text, Map<String, dynamic> info) async {
    var v = await _request(
      {"op": "hlsRewrite", "text": text, "info": info},
      label: "hls.rewrite()",
      timeout: const Duration(seconds: 3),
      countTimeout: false,
    );
    return v is String ? v : null;
  }

  Future<dynamic> _request(
    Map<String, dynamic> message, {
    required String label,
    Duration? timeout,
    bool countTimeout = true,
  }) async {
    if (_disposed) {
      throw CoreError("{name} 已关闭".tf({"name": name}));
    }
    _idle?.cancel();
    _Connection conn;
    try {
      conn = await _ensure();
    } catch (e) {
      _scheduleIdle();
      rethrow;
    }
    if (_authSentTo != conn) {
      // 同一个端口按顺序送达：后台先收到帐号，再收到这次调用
      conn.send({"op": "setAccount", "id": 0, "auth": _auth?.toMessage()});
      _authSentTo = conn;
    }
    var id = ++_nextId;
    message["id"] = id;
    var pending = _Pending(Completer<dynamic>(), label, conn);
    var limit = timeout ?? ScriptWorkerSettings.callTimeout;
    pending.timer = Timer(limit, () {
      if (_calls.remove(id) == null) return;
      var text = limit.inMilliseconds >= 1000
          ? "{limit} 秒".tf({"limit": limit.inSeconds})
          : "{inMilliseconds} 毫秒".tf({"inMilliseconds": limit.inMilliseconds});
      pending.completer.completeError(CoreError("{name}：{label} 超时（{text}没有返回）".tf({"name": name, "label": label, "text": text})));
      if (countTimeout) _onTimeout(conn);
    });
    _calls[id] = pending;
    conn.send(message);
    try {
      return await pending.completer.future;
    } finally {
      _scheduleIdle();
    }
  }

  void _onTimeout(_Connection conn) {
    if (conn != _conn) return;
    _timeouts++;
    if (_timeouts >= ScriptWorkerSettings.maxTimeouts) {
      CoreLog.w("[$name] 连续 $_timeouts 次调用超时，重启直播源");
      _restart("{name} 多次超时，已重启".tf({"name": name}));
    }
  }

  void _scheduleIdle() {
    _idle?.cancel();
    if (_conn == null || _calls.isNotEmpty || _sessions.isNotEmpty) return;
    _idle = Timer(ScriptWorkerSettings.idleTimeout, () {
      if (_calls.isEmpty && _sessions.isEmpty && _conn != null) {
        var conn = _conn!;
        _conn = null;
        conn.close();
      }
    });
  }

  Future<_Connection> _ensure() {
    var conn = _conn;
    if (conn != null && !conn.closed) {
      return Future.value(conn);
    }
    return _starting ??= _spawn().whenComplete(() => _starting = null);
  }

  /// 上一个 isolate 退出的时候（见 [_Connection.gone]）
  Future<void>? _lastGone;

  /// 等上一个 isolate 退出，最多 3 秒
  Future<void> _waitLastGone() async {
    var gone = _lastGone;
    if (gone != null) {
      await gone.timeout(const Duration(seconds: 3), onTimeout: () {});
    }
  }

  Future<_Connection> _spawn() async {
    await _waitLastGone();
    var conn = _Connection();
    conn.port.listen((m) => _onMessage(conn, m));
    conn.errorPort.listen((e) {
      if (e is List && e.isNotEmpty) {
        CoreLog.w("[$name] 后台出错：${e.first}");
      }
    });
    conn.exitPort.listen((_) => _onExit(conn));
    try {
      conn.isolate = await Isolate.spawn(
        scriptHostMain,
        ScriptHostConfig(
          mainPort: conn.port.sendPort,
          key: key,
          name: name,
          scriptPath: scriptPath,
          dataDirectory: dataDirectory,
          appVersion: appVersion,
          sliceTimeoutMs: ScriptWorkerSettings.sliceTimeout.inMilliseconds,
          rewriteTimeoutMs: ScriptWorkerSettings.rewriteTimeout.inMilliseconds,
          accountHostsForTest: ScriptWorkerSettings.accountHostsForTest,
          texts: CoreText.snapshot?.call(),
        ),
        onExit: conn.exitPort.sendPort,
        onError: conn.errorPort.sendPort,
        errorsAreFatal: false,
        debugName: "live_source_$key",
      );
      conn.sendPort = await conn.hello.future.timeout(
        const Duration(seconds: 15),
      );
      await conn.loaded.future.timeout(ScriptWorkerSettings.callTimeout);
    } on TimeoutException {
      conn.close();
      throw CoreError("{name}：启动直播源超时".tf({"name": name}));
    } catch (e) {
      conn.close();
      if (e is CoreError) rethrow;
      throw CoreError("{name}：启动直播源失败：{e}".tf({"name": name, "e": e}));
    }
    if (_disposed) {
      conn.close();
      throw CoreError("{name} 已关闭".tf({"name": name}));
    }
    _conn = conn;
    _timeouts = 0;
    return conn;
  }

  void _onMessage(_Connection conn, dynamic message) {
    if (message is! Map) return;
    switch (message["ev"]) {
      case "hello":
        if (!conn.hello.isCompleted) conn.hello.complete(message["port"]);
        break;
      case "loaded":
        if (!conn.loaded.isCompleted) conn.loaded.complete();
        break;
      case "loadError":
        if (!conn.loaded.isCompleted) {
          conn.loaded.completeError(CoreError("$name：${message["e"]}"));
        }
        break;
      case "result":
        var pending = _calls.remove(message["id"]);
        if (pending == null) return;
        pending.timer?.cancel();
        if (message["ok"] == true) {
          if (conn == _conn) _timeouts = 0;
          pending.completer.complete(message["v"]);
        } else {
          pending.completer.completeError(
            CoreError(message["e"]?.toString() ?? "{name} 出错".tf({"name": name})),
          );
        }
        break;
      case "log":
        _log(message["level"]?.toString(), message["msg"]?.toString() ?? "");
        break;
      case "dmReady":
        if (conn != _conn) return;
        _sessions[message["sid"]]?.onSessionReady(message["sid"]);
        break;
      case "dmEmit":
        if (conn != _conn) return;
        var list = message["messages"];
        if (list is List) {
          _sessions[message["sid"]]?.onSessionMessages(message["sid"], list);
        }
        break;
      case "dmEnd":
        if (conn != _conn) return;
        var sid = message["sid"] as int;
        var listener = _sessions.remove(sid);
        listener?.onSessionEnd(sid, message["reason"]?.toString() ?? "弹幕连接断开".t);
        _scheduleIdle();
        break;
      case "interrupted":
        CoreLog.w("[$name] ${message["e"]}");
        if (conn == _conn) {
          _restart(message["e"]?.toString() ?? "{name} 脚本执行超时".tf({"name": name}));
        } else {
          conn.close();
        }
        break;
      case "closed":
        conn._closePorts();
        break;
    }
  }

  void _onExit(_Connection conn) {
    conn._closePorts();
    if (conn == _conn) {
      _restart("{name} 的后台已退出".tf({"name": name}));
    }
  }

  /// 丢弃当前 isolate：进行中的调用报错，弹幕会话结束（各自按退避重连）
  void _restart(String reason) {
    var conn = _conn;
    _conn = null;
    conn?.close();
    if (conn != null) {
      _lastGone = conn.gone.future;
    }
    _timeouts = 0;
    for (var entry in _calls.entries.toList()) {
      if (entry.value.conn == conn) {
        _calls.remove(entry.key);
        entry.value.timer?.cancel();
        entry.value.completer.completeError(CoreError(reason));
      }
    }
    var sessions = Map.of(_sessions);
    _sessions.clear();
    sessions.forEach((sid, listener) => listener.onSessionEnd(sid, reason));
  }

  void _log(String? level, String msg) {
    var text = "[$name] $msg";
    switch (level) {
      case "error":
        CoreLog.e(text, StackTrace.empty);
        break;
      case "warn":
        CoreLog.w(text);
        break;
      case "debug":
        CoreLog.d(text);
        break;
      default:
        CoreLog.i(text);
    }
  }

  /// 关闭后台 isolate（之后的调用会重新启动它）
  Future<void> shutdown() async {
    _idle?.cancel();
    if (_conn != null) {
      _restart("{name} 已关闭".tf({"name": name}));
    }
    // 等它真的退出（设置写回 settings.json 之后），之后的调用才不会读到旧设置
    await _waitLastGone();
  }

  /// 彻底关闭，之后不能再调用
  Future<void> dispose() async {
    _disposed = true;
    await shutdown();
  }
}
