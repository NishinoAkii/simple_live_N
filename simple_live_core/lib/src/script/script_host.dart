// 直播源的后台 isolate：一个 QuickJS 引擎 + 消息泵
//
// 脚本没有办法直接调用 Dart。脚本把请求放进发件箱并返回 Promise；这里每次
// 执行完（eval / call / Promise 任务）就取走发件箱，做完 HTTP、WebSocket、定时器、
// 存储等工作后用 __dispatch 把结果送回去，再执行一轮，直到没有事情可做。

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:brotli/brotli.dart';
import 'package:crypto/crypto.dart';
import 'package:simple_live_core/src/common/youtube_innertube.dart'
    show youTubeCookieAuthorization;
import 'package:simple_live_core/src/script/live_source_models.dart';
import 'package:simple_live_core/src/script/live_source_overrides.dart';
import 'package:simple_live_core/src/script/script_cookie_jar.dart';
import 'package:simple_live_core/src/script/script_engine.dart';
import 'package:simple_live_core/src/script/script_metadata.dart';
import 'package:simple_live_core/src/common/core_text.dart';

const String kLiveSourceUserAgent =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

/// 启动后台 isolate 的参数
class ScriptHostConfig {
  final SendPort mainPort;
  final String key;
  final String name;
  final String scriptPath;
  final String dataDirectory;
  final String appVersion;
  final int sliceTimeoutMs;

  /// hls.rewrite 单次同步执行的期限
  final int rewriteTimeoutMs;

  /// 只给测试用（ScriptWorkerSettings.accountHostsForTest）
  final Map<String, List<String>>? accountHostsForTest;

  /// 界面语言的表（[CoreText.snapshot]），后台出的报错用同一种语言；简体中文时为 null
  final Map<String, String>? texts;

  const ScriptHostConfig({
    required this.mainPort,
    required this.key,
    required this.name,
    required this.scriptPath,
    required this.dataDirectory,
    required this.appVersion,
    required this.sliceTimeoutMs,
    this.rewriteTimeoutMs = 200,
    this.accountHostsForTest,
    this.texts,
  });
}

/// 后台 isolate 的入口
Future<void> scriptHostMain(ScriptHostConfig config) async {
  CoreText.use(config.texts);
  var host = _ScriptHost(config);
  await host.run();
}

class _HostSession {
  final int sid;
  final Set<int> sockets = {};
  final Set<int> timers = {};
  bool ending = false;
  int? stopCallId;
  Timer? forceClose;
  _HostSession(this.sid);
}

class _HostSocket {
  final int id;
  final int sid;
  final WebSocket socket;
  bool closedLocally = false;
  _HostSocket(this.id, this.sid, this.socket);
}

class _ScriptHost {
  final ScriptHostConfig config;
  final ReceivePort _port = ReceivePort();
  ScriptEngine? _engineOrNull;
  bool _loaded = false;

  ScriptEngine get _engine => _engineOrNull!;
  bool _closing = false;

  final Queue<String> _queue = Queue();
  bool _pumping = false;

  List<String> _domains = const [];
  List<LiveSourceSetting> _settingSchema = const [];

  /// 修正（§9）：替换的内置平台、是否用帐号。从这里自己读到的脚本元数据来，不听主 isolate 的
  String? _overrides;
  bool _useAccount = false;

  /// 主 isolate 交来的内置平台帐号（只在内存里，从不放进脚本引擎）
  LiveSourceAccountAuth? _account;

  final Map<int, Timer> _timers = {};
  final Map<int, int> _timerSession = {};
  final Map<int, _HostSession> _sessions = {};
  final Map<int, _HostSocket> _sockets = {};

  /// 主 isolate 的 dmStart 调用 id → 会话
  final Map<int, int> _startCalls = {};

  HttpClient? _http;
  late final LiveSourceCookieJar _cookies;
  late final _JsonStore _storage;

  /// 用户在 App 里改的设置项（settings.json），脚本只能读
  late final _JsonStore _settings;

  _ScriptHost(this.config) {
    var dir = config.dataDirectory;
    _cookies = LiveSourceCookieJar(
      File("$dir${Platform.pathSeparator}cookies.json"),
    );
    _storage = _JsonStore(File("$dir${Platform.pathSeparator}storage.json"));
    _settings = _JsonStore(File("$dir${Platform.pathSeparator}settings.json"));
  }

  Map<String, dynamic> get _settingValues =>
      liveSourceSettingValues(_settingSchema, _settings.snapshot());

  void _pushSettings() {
    if (_settingSchema.isEmpty) return;
    _send({"t": "settings", "values": _settingValues});
  }

  /// App 改设置：只接受声明过的 key、合法的值；null 恢复默认
  Map<String, dynamic> _setSettings(dynamic values) {
    if (values is Map) {
      values.forEach((k, v) {
        var s = _settingSchema.where((e) => e.key == k).firstOrNull;
        if (s == null) return;
        if (v == null) {
          _settings.removeSync(s.key);
        } else {
          var value = s.coerce(v);
          if (value == null) throw "设置项 {label} 的值不对".tf({"label": s.label});
          _settings.setSync(s.key, value);
        }
      });
    }
    _pushSettings();
    return _settingValues;
  }

  void _toMain(Map<String, dynamic> message) {
    config.mainPort.send(message);
  }

  void _log(String level, String msg) {
    _toMain({"ev": "log", "level": level, "msg": msg});
  }

  Future<void> run() async {
    _toMain({"ev": "hello", "port": _port.sendPort});
    _port.listen(_onMainMessage);
    try {
      var code = await File(config.scriptPath).readAsString();
      _engineOrNull = ScriptEngine(
        memoryLimit: 64 * 1024 * 1024,
        sliceTimeout: Duration(milliseconds: config.sliceTimeoutMs),
      );
      prepareLiveSourceEngine(_engine, appVersion: config.appVersion);
      var name = config.scriptPath.split(RegExp(r'[\\/]')).last;
      var meta = loadLiveSourceScript(
        _engine,
        code,
        filename: name,
        create: true,
      );
      _domains = meta.domains;
      _settingSchema = meta.settings;
      _overrides = meta.overrides;
      _useAccount = meta.overrides != null && meta.useAccount;
      _loaded = true;
      _pushSettings();
      // 构造函数里可能已经发出了请求、定时器
      _drainAndHandle();
      _pump();
      _toMain({"ev": "loaded"});
    } catch (e) {
      _toMain({"ev": "loadError", "e": e.toString()});
    }
  }

  // ---------------------------------------------------------------------
  // 主 isolate 的消息
  // ---------------------------------------------------------------------

  void _onMainMessage(dynamic message) {
    if (message is! Map) return;
    var op = message["op"];
    if (op == "shutdown") {
      unawaited(_shutdown());
      return;
    }
    var id = message["id"] as int? ?? 0;
    if (!_loaded) {
      _result(id, false, error: "直播源没有加载".t);
      return;
    }
    try {
      _onCall(op, id, message);
    } catch (e) {
      // 比如参数不能转成 JSON
      _result(id, false, error: "调用失败：{e}".tf({"e": e}));
    }
  }

  void _onCall(dynamic op, int id, Map message) {
    switch (op) {
      case "call":
        _send({
          "t": "call",
          "id": id,
          "m": message["m"],
          "a": message["a"] ?? [],
        });
        break;
      case "dmStart":
        var sid = message["sid"] as int;
        _sessions[sid] = _HostSession(sid);
        _startCalls[id] = sid;
        _send({"t": "dmStart", "id": id, "sid": sid, "room": message["room"]});
        break;
      case "dmStop":
        var sid = message["sid"] as int;
        var s = _sessions[sid];
        if (s == null) {
          _result(id, true);
        } else {
          s.stopCallId = id;
          _endSession(sid, null);
        }
        break;
      case "getCookies":
      case "setCookies":
      case "clearCookies":
        try {
          var uri = _parseUrl(message["url"]);
          if (op == "getCookies") {
            _result(id, true, value: _cookies.header(uri));
          } else if (op == "clearCookies") {
            _result(id, true, value: _cookies.removeFor(uri));
          } else {
            _cookies.setFromHeader(uri, message["cookies"].toString());
            _result(id, true);
          }
        } catch (e) {
          // 出错信息里不带 Cookie 内容
          _result(id, false, error: "Cookie 操作失败：{runtimeType}".tf({"runtimeType": e.runtimeType}));
        }
        break;
      case "hlsRewrite":
        _hlsRewrite(id, message);
        break;
      case "setAccount":
        // 没有声明 useAccount 的脚本收不到
        _account = _useAccount
            ? LiveSourceAccountAuth.fromMessage(message["auth"])
            : null;
        _result(id, true);
        break;
      case "getSettings":
        _result(id, true, value: _settingValues);
        break;
      case "setSettings":
        try {
          _result(id, true, value: _setSettings(message["values"]));
        } catch (e) {
          _result(id, false, error: e.toString());
        }
        break;
      default:
        _result(id, false, error: "未知操作 {op}".tf({"op": op}));
    }
  }

  static const int _maxRewriteText = 2 * 1024 * 1024;

  /// hls.rewrite(text, info)：直接同步调用（限时 rewriteTimeoutMs），不经消息泵。
  /// 超时被中断时引擎仍可用，这里不当作脚本卡死（中转会改用原列表）
  void _hlsRewrite(int id, Map message) {
    var text = message["text"]?.toString() ?? "";
    if (text.length > _maxRewriteText) {
      _result(id, false, error: "播放列表太大，没有调用 hls.rewrite".t);
      return;
    }
    String? out;
    String? error;
    try {
      out = _engine.call("__hlsRewrite", [
        text,
        jsonEncode(message["info"] ?? const {}),
      ], timeout: Duration(milliseconds: config.rewriteTimeoutMs));
    } on ScriptEngineException catch (e) {
      error = e.interrupted
          ? "hls.rewrite 超时（同步执行超过 {rewriteTimeoutMs} 毫秒）".tf({"rewriteTimeoutMs": config.rewriteTimeoutMs})
          : "hls.rewrite 出错：{describeScriptError}".tf({"describeScriptError": describeScriptError(e)});
    }
    try {
      _engine.call("__hlsRewriteEnd", const []);
    } on ScriptEngineException catch (_) {}
    // 只会有日志：hls.rewrite 里不能发请求、开定时器
    _drainAndHandle();
    if (error != null) {
      _result(id, false, error: error);
    } else {
      _result(id, true, value: out);
    }
  }

  void _result(int id, bool ok, {dynamic value, String? error}) {
    if (id == 0) return;
    _toMain({"ev": "result", "id": id, "ok": ok, "v": value, "e": error});
  }

  // ---------------------------------------------------------------------
  // 消息泵
  // ---------------------------------------------------------------------

  void _send(Map<String, dynamic> command) {
    var engine = _engineOrNull;
    if (_closing || engine == null || engine.isDisposed) return;
    _queue.add(jsonEncode(command));
    _pump();
  }

  void _pump() {
    if (_pumping || _closing) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty && !_closing) {
        var command = _queue.removeFirst();
        try {
          _engine.call("__dispatch", [command]);
        } on ScriptEngineException catch (e) {
          if (_onEngineError(e)) return;
        }
        _drainAndHandle();
      }
    } finally {
      _pumping = false;
    }
  }

  void _drainAndHandle() {
    if (_closing) return;
    for (var errors = _engine.runJobs(); ; errors = _engine.runJobs()) {
      for (var e in errors) {
        if (_onEngineError(e)) return;
      }
      String? out;
      try {
        out = _engine.call("__drain", const []);
      } on ScriptEngineException catch (e) {
        if (_onEngineError(e)) return;
      }
      if (out != null) {
        for (var item in jsonDecode(out) as List) {
          try {
            _handle(item as Map<String, dynamic>);
          } catch (e, st) {
            _log("error", "处理脚本请求出错：$e\n$st");
          }
        }
      }
      if (!_engine.hasPendingJobs) break;
    }
  }

  /// 返回 true 表示引擎已不可用（被中断），停止处理
  bool _onEngineError(ScriptEngineException e) {
    if (e.interrupted) {
      _toMain({"ev": "interrupted", "e": "${config.name}：${e.message}"});
      _closing = true;
      return true;
    }
    _log("error", "脚本出错：${describeScriptError(e)}");
    return false;
  }

  // ---------------------------------------------------------------------
  // 发件箱
  // ---------------------------------------------------------------------

  void _handle(Map<String, dynamic> item) {
    var id = item["id"] as int? ?? 0;
    var op = item["op"] as String;
    var args = item["args"];
    switch (op) {
      case "return":
        var callId = args["id"] as int;
        _startCalls.remove(callId);
        _result(callId, true, value: args["v"]);
        break;
      case "throw":
        var callId = args["id"] as int;
        var sid = _startCalls.remove(callId);
        if (sid != null) {
          _endSession(sid, null);
        }
        // 只有栈里有脚本自己的位置时才值得记下来
        var stack = args["stack"]?.toString();
        if (stack != null && RegExp(r'\.live\.js:\d').hasMatch(stack)) {
          _log("debug", "${args["e"]}\n$stack");
        }
        _result(callId, false, error: args["e"]?.toString() ?? "脚本出错".t);
        break;
      case "log":
        _log(
          args["level"]?.toString() ?? "info",
          args["msg"]?.toString() ?? "",
        );
        break;
      case "timer":
        _setTimer(args);
        break;
      case "clearTimer":
        var tid = args["id"] as int;
        _timers.remove(tid)?.cancel();
        var sid = _timerSession.remove(tid);
        if (sid != null) _sessions[sid]?.timers.remove(tid);
        break;
      case "emit":
        var sid = args["sid"] as int;
        var s = _sessions[sid];
        if (s != null && !s.ending) {
          _toMain({"ev": "dmEmit", "sid": sid, "messages": args["messages"]});
        }
        break;
      case "ready":
        var sid = args["sid"] as int;
        var s = _sessions[sid];
        if (s != null && !s.ending) {
          _toMain({"ev": "dmReady", "sid": sid});
        }
        break;
      case "fail":
        var message = args["message"]?.toString() ?? "";
        _endSession(args["sid"] as int, message.isEmpty ? "弹幕连接断开".t : message);
        break;
      case "sessionClosed":
        _finalizeSession(args["sid"] as int);
        break;
      case "wsSend":
        var socket = _sockets[args["ws"]];
        if (socket != null && !socket.closedLocally) {
          try {
            if (args["b64"] != null) {
              socket.socket.add(base64.decode(args["b64"]));
            } else {
              socket.socket.add(args["text"]?.toString() ?? "");
            }
          } catch (e) {
            _log("warn", "弹幕连接发数据失败：$e");
          }
        }
        break;
      case "wsClose":
        var socket = _sockets.remove(args["ws"]);
        if (socket != null) {
          socket.closedLocally = true;
          _sessions[socket.sid]?.sockets.remove(socket.id);
          _closeSocket(
            socket.socket,
            args["code"] as int? ?? 1000,
            args["reason"]?.toString(),
          );
        }
        break;
      default:
        _async(id, op, args);
    }
  }

  /// 需要回复的请求：完成后 resolve / reject
  void _async(int id, String op, dynamic args) {
    Future<dynamic> work;
    switch (op) {
      case "http":
        work = _httpRequest(args);
        break;
      case "zip":
        work = Future(() => _zip(args));
        break;
      case "hash":
        work = Future(() => _hash(args));
        break;
      case "storageGet":
        work = _storage.get(args["key"]);
        break;
      case "storageSet":
        work = _storage.set(args["key"], args["value"]);
        break;
      case "storageRemove":
        work = _storage.remove(args["key"]);
        break;
      case "getCookies":
        work = Future(() => _cookies.header(_parseUrl(args["url"])));
        break;
      case "setCookies":
        work = Future(
          () => _cookies.setFromHeader(_parseUrl(args["url"]), args["cookies"]),
        );
        break;
      case "wsOpen":
        work = _wsOpen(args);
        break;
      default:
        work = Future.error("不支持的操作 {op}".tf({"op": op}));
    }
    work.then(
      (value) {
        _send({"t": "resolve", "id": id, "v": value});
      },
      onError: (Object e) {
        _send({"t": "reject", "id": id, "e": _errorText(e)});
      },
    );
  }

  static String _errorText(Object e) {
    if (e is TimeoutException) return "请求超时".t;
    if (e is SocketException) {
      return "网络错误：{p}".tf({"p": e.osError?.message ?? e.message});
    }
    if (e is HandshakeException) return "TLS 握手失败：{message}".tf({"message": e.message});
    if (e is HttpException) return "HTTP 错误：{message}".tf({"message": e.message});
    if (e is WebSocketException) return "WebSocket 错误：{message}".tf({"message": e.message});
    return e.toString();
  }

  // ---------------------------------------------------------------------
  // 定时器
  // ---------------------------------------------------------------------

  void _setTimer(dynamic args) {
    var tid = args["id"] as int;
    var ms = (args["ms"] as num).toInt();
    var repeat = args["repeat"] == true;
    var sid = args["sid"] as int? ?? 0;
    if (sid != 0) {
      var s = _sessions[sid];
      if (s == null || s.ending) return;
      s.timers.add(tid);
      _timerSession[tid] = sid;
    }
    var duration = Duration(milliseconds: ms);
    if (repeat) {
      _timers[tid] = Timer.periodic(duration, (_) {
        _send({"t": "timer", "id": tid});
      });
    } else {
      _timers[tid] = Timer(duration, () {
        _timers.remove(tid);
        var owner = _timerSession.remove(tid);
        if (owner != null) _sessions[owner]?.timers.remove(tid);
        _send({"t": "timer", "id": tid});
      });
    }
  }

  // ---------------------------------------------------------------------
  // 弹幕会话
  // ---------------------------------------------------------------------

  /// 结束会话：先让脚本执行 danmaku.stop，再关闭连接和定时器。
  /// [reason] 不为空时通知主 isolate（App 按退避重连）
  void _endSession(int sid, String? reason) {
    var s = _sessions[sid];
    if (s == null || s.ending) return;
    s.ending = true;
    if (reason != null) {
      _toMain({"ev": "dmEnd", "sid": sid, "reason": reason});
    }
    s.forceClose = Timer(
      const Duration(seconds: 3),
      () => _finalizeSession(sid),
    );
    _send({"t": "dmEnd", "sid": sid});
  }

  void _finalizeSession(int sid) {
    var s = _sessions.remove(sid);
    if (s == null) return;
    s.forceClose?.cancel();
    for (var tid in s.timers) {
      _timers.remove(tid)?.cancel();
      _timerSession.remove(tid);
    }
    for (var wid in s.sockets) {
      var socket = _sockets.remove(wid);
      if (socket != null) {
        socket.closedLocally = true;
        _closeSocket(socket.socket, 1000, null);
      }
    }
    _startCalls.removeWhere((_, v) => v == sid);
    if (s.stopCallId != null) {
      _result(s.stopCallId!, true);
    }
  }

  Future<dynamic> _wsOpen(dynamic args) async {
    var sid = args["sid"] as int;
    var wid = args["ws"] as int;
    var url = args["url"].toString();
    var uri = _parseUrl(url);
    if (uri.scheme != "ws" && uri.scheme != "wss") {
      throw "WebSocket 地址必须以 ws:// 或 wss:// 开头：{url}".tf({"url": url});
    }
    _checkDomain(uri);
    var session = _sessions[sid];
    if (session == null || session.ending) {
      throw "弹幕会话已结束".t;
    }
    var headers = <String, dynamic>{};
    (args["headers"] as Map?)?.forEach(
      (k, v) => headers[k.toString()] = v.toString(),
    );
    var lower = headers.keys.map((e) => e.toLowerCase()).toSet();
    if (!lower.contains("user-agent")) {
      headers["User-Agent"] = kLiveSourceUserAgent;
    }
    var account = _accountFor(uri);
    if (account != null) {
      // 帐号的 Cookie 在前，Authorization 之类由 App 给
      var accountHeaders = _accountHeaders(account);
      var names = accountHeaders.keys.map((e) => e.toLowerCase()).toSet();
      String? userCookie;
      headers.removeWhere((k, v) {
        var l = k.toLowerCase();
        if (l == "cookie") userCookie = v.toString();
        return l == "cookie" || names.contains(l);
      });
      var own =
          userCookie ??
          _cookies.header(
            uri.replace(scheme: uri.scheme == "wss" ? "https" : "http"),
          );
      var cookie = account.cookie.isEmpty
          ? own
          : mergeAccountCookie(account.cookie, [own]);
      if (cookie.isNotEmpty) headers["Cookie"] = cookie;
      headers.addAll(accountHeaders);
    } else if (!lower.contains("cookie")) {
      var cookie = _cookies.header(
        uri.replace(scheme: uri.scheme == "wss" ? "https" : "http"),
      );
      if (cookie.isNotEmpty) headers["Cookie"] = cookie;
    }
    var protocols = ((args["protocols"] as List?) ?? const []).cast<String>();
    var timeout = Duration(
      milliseconds: (args["timeout"] as num? ?? 15000).toInt(),
    );
    WebSocket socket;
    try {
      socket = await WebSocket.connect(
        url,
        headers: headers,
        protocols: protocols.isEmpty ? null : protocols,
      ).timeout(timeout);
    } on TimeoutException {
      throw "连接弹幕服务器超时".t;
    } catch (e) {
      throw "连接弹幕服务器失败：{errorText}".tf({"errorText": _errorText(e)});
    }
    session = _sessions[sid];
    if (session == null || session.ending || _closing) {
      _closeSocket(socket, 1000, null);
      throw "弹幕会话已结束".t;
    }
    var hostSocket = _HostSocket(wid, sid, socket);
    _sockets[wid] = hostSocket;
    session.sockets.add(wid);
    socket.listen(
      (data) {
        if (hostSocket.closedLocally) return;
        if (data is String) {
          _send({"t": "ws", "ws": wid, "text": data});
        } else {
          _send({
            "t": "ws",
            "ws": wid,
            "b64": base64.encode(data as List<int>),
          });
        }
      },
      onDone: () => _onSocketDone(hostSocket),
      onError: (Object e) {
        _log("warn", "弹幕连接出错：${_errorText(e)}");
      },
      cancelOnError: false,
    );
    return null;
  }

  static void _closeSocket(WebSocket socket, int code, String? reason) {
    try {
      var valid = code == 1000 || (code >= 3000 && code <= 4999);
      unawaited(socket.close(valid ? code : 1000, reason).catchError((_) {}));
    } catch (_) {}
  }

  void _onSocketDone(_HostSocket socket) {
    if (socket.closedLocally || _closing) return;
    _sockets.remove(socket.id);
    var code = socket.socket.closeCode;
    var reason = socket.socket.closeReason ?? "";
    _sessions[socket.sid]?.sockets.remove(socket.id);
    _send({"t": "wsClosed", "ws": socket.id, "code": code, "reason": reason});
    var s = _sessions[socket.sid];
    if (s != null && !s.ending) {
      _endSession(
        socket.sid,
        "与弹幕服务器的连接断开{p}".tf({"p": code == null
              ? ""
              : "（{detail}）".tf({
                  "detail": "$code${reason.isEmpty ? "" : " $reason"}",
                })}),
      );
    }
  }

  // ---------------------------------------------------------------------
  // Http
  // ---------------------------------------------------------------------

  Uri _parseUrl(dynamic url) {
    var uri = Uri.tryParse(url?.toString() ?? "");
    if (uri == null || uri.host.isEmpty) {
      throw "无效的地址：{url}".tf({"url": url});
    }
    return uri;
  }

  void _checkDomain(Uri uri) {
    if (!liveSourceDomainAllowed(_domains, uri.host)) {
      throw "不允许访问 {host}：没有写在直播源的 domains 里".tf({"host": uri.host});
    }
  }

  /// useAccount：发往 [uri] 的请求要不要带内置平台的帐号，不带时为 null。
  /// 要同时满足：脚本声明了 overrides 和 useAccount；App 交来了帐号；https / wss；
  /// 主机在 App 写死的 kBuiltInAccountHosts[平台] 里（脚本的 domains 另外检查）
  LiveSourceAccountAuth? _accountFor(Uri uri) {
    var auth = _account;
    var target = _overrides;
    if (!_useAccount || target == null || auth == null) return null;
    var test = config.accountHostsForTest;
    var hosts = test?[target] ?? kBuiltInAccountHosts[target] ?? const [];
    var secure = uri.scheme == "https" || uri.scheme == "wss";
    if (!secure && test == null) return null;
    return liveSourceDomainAllowed(hosts, uri.host) ? auth : null;
  }

  /// 帐号的请求头（Cookie 另外合并）：Authorization，YouTube 每次现算 SAPISIDHASH
  static Map<String, String> _accountHeaders(LiveSourceAccountAuth auth) {
    if (auth.youTube) {
      var authorization = youTubeCookieAuthorization(auth.cookie);
      if (authorization == null) return const {};
      return {
        "Authorization": authorization,
        "X-Origin": "https://www.youtube.com",
        "X-Goog-AuthUser": "0",
      };
    }
    return auth.authorization.isEmpty
        ? const {}
        : {"Authorization": auth.authorization};
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  Future<Map<String, dynamic>> _httpRequest(dynamic args) async {
    var uri = _parseUrl(args["url"]);
    if (uri.scheme != "http" && uri.scheme != "https") {
      throw "只支持 http(s) 地址：{args}".tf({"args": args["url"]});
    }
    _checkDomain(uri);
    var method = (args["method"] ?? "GET").toString();
    var headers = <String, String>{};
    (args["headers"] as Map?)?.forEach(
      (k, v) => headers[k.toString()] = v.toString(),
    );
    List<int>? body;
    if (args["b64"] != null) {
      body = base64.decode(args["b64"]);
    } else if (args["text"] != null) {
      body = utf8.encode(args["text"].toString());
    }
    var timeout = Duration(
      milliseconds: (args["timeout"] as num? ?? 15000).toInt(),
    );
    var follow = args["followRedirects"] != false;
    var wantBytes = args["bytes"] == true;
    var stopwatch = Stopwatch()..start();
    Duration remaining() {
      var left = timeout - stopwatch.elapsed;
      if (left <= Duration.zero) throw TimeoutException("请求超时".t);
      return left;
    }

    var client = _http ??= HttpClient()
      ..userAgent = null
      ..autoUncompress = true
      ..idleTimeout = const Duration(seconds: 15);
    var redirects = 0;
    while (true) {
      // 每一跳（包括重定向后的）重新判断要不要带帐号
      var account = _accountFor(uri);
      var accountHeaders = account == null
          ? const <String, String>{}
          : _accountHeaders(account);
      var accountNames = accountHeaders.keys.map((e) => e.toLowerCase());
      var request = await client.openUrl(method, uri).timeout(remaining());
      HttpClientResponse response;
      try {
        request.followRedirects = false;
        var hasUa = false;
        var userCookie = "";
        headers.forEach((name, value) {
          var lower = name.toLowerCase();
          if (lower == "user-agent") hasUa = true;
          if (lower == "cookie") {
            userCookie = value;
            return;
          }
          if (lower == "content-length" || lower == "host") return;
          // 带帐号时这几个头由 App 给，脚本盖不掉
          if (accountNames.contains(lower)) return;
          request.headers.set(name, value, preserveHeaderCase: true);
        });
        if (!hasUa) {
          request.headers.set("User-Agent", kLiveSourceUserAgent);
        }
        var jarCookie = _cookies.header(uri);
        var cookie = account != null && account.cookie.isNotEmpty
            ? mergeAccountCookie(account.cookie, [jarCookie, userCookie])
            : [jarCookie, userCookie].where((e) => e.isNotEmpty).join("; ");
        if (cookie.isNotEmpty) {
          request.headers.set("Cookie", cookie);
        }
        accountHeaders.forEach((name, value) {
          request.headers.set(name, value, preserveHeaderCase: true);
        });
        if (body != null) {
          request.contentLength = body.length;
          request.add(body);
        }
        response = await request.close().timeout(remaining());
      } catch (e) {
        request.abort();
        rethrow;
      }
      // 带帐号的请求：平台下发（刷新）的登录 Cookie 不进脚本的 Cookie 罐
      if (account == null) {
        _cookies.storeResponse(
          uri,
          response.headers[HttpHeaders.setCookieHeader],
        );
      }
      var location = response.headers.value(HttpHeaders.locationHeader);
      if (follow && _isRedirect(response.statusCode) && location != null) {
        await response.drain<void>().catchError((_) {});
        if (++redirects > 10) {
          throw "重定向次数过多".t;
        }
        uri = uri.resolve(location);
        if (uri.scheme != "http" && uri.scheme != "https") {
          throw "重定向到了不支持的地址：{uri}".tf({"uri": uri});
        }
        _checkDomain(uri);
        if (response.statusCode == 303 ||
            ((response.statusCode == 301 || response.statusCode == 302) &&
                method == "POST")) {
          method = "GET";
          body = null;
          headers.removeWhere((k, _) => k.toLowerCase() == "content-type");
        }
        continue;
      }
      var bytes = await _readBody(response).timeout(remaining());
      // dart:io 只自动解压 gzip；脚本自己要了 br / deflate 时在这里解
      var encoding = response.headers
          .value(HttpHeaders.contentEncodingHeader)
          ?.toLowerCase()
          .trim();
      if (encoding == "br") {
        try {
          bytes = decodeLimited(brotli.decoder, bytes, _maxBody);
        } on DecodedTooLarge {
          throw "响应内容过大（解压后超过 32 MB）".t;
        } catch (_) {}
      } else if (encoding == "deflate") {
        try {
          bytes = decodeLimited(ZLibDecoder(), bytes, _maxBody);
        } on DecodedTooLarge {
          throw "响应内容过大（解压后超过 32 MB）".t;
        } catch (_) {
          try {
            bytes = decodeLimited(ZLibDecoder(raw: true), bytes, _maxBody);
          } catch (_) {}
        }
      }
      var resultHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        var lower = name.toLowerCase();
        // 带帐号的请求：Set-Cookie 也不给脚本看
        if (account != null && lower == "set-cookie") return;
        resultHeaders[lower] = values.join(lower == "set-cookie" ? "\n" : ", ");
      });
      return {
        "status": response.statusCode,
        "headers": resultHeaders,
        "url": uri.toString(),
        if (wantBytes) "b64": base64.encode(bytes),
        if (!wantBytes) "text": utf8.decode(bytes, allowMalformed: true),
      };
    }
  }

  static const int _maxBody = 32 * 1024 * 1024;

  Future<List<int>> _readBody(HttpClientResponse response) async {
    var builder = BytesBuilder(copy: false);
    await for (var chunk in response) {
      builder.add(chunk);
      if (builder.length > _maxBody) {
        throw "响应内容过大（超过 32 MB）".t;
      }
    }
    return builder.takeBytes();
  }

  // ---------------------------------------------------------------------
  // Zip
  // ---------------------------------------------------------------------

  /// Zip、Hash 的输入和解压结果的上限（结果要转成 Base64 放进 64 MB 的引擎）
  static const int _maxHelperBytes = 16 * 1024 * 1024;

  String _zip(dynamic args) {
    var data = base64.decode(args["b64"]);
    var mode = args["mode"].toString();
    if (data.length > _maxHelperBytes) throw "Zip 的输入太大（超过 16 MB）".t;
    List<int> out;
    try {
      switch (mode) {
        case "gunzip":
          out = decodeLimited(gzip.decoder, data, _maxHelperBytes);
          break;
        case "inflate":
          out = decodeLimited(ZLibDecoder(), data, _maxHelperBytes);
          break;
        case "inflateRaw":
          out = decodeLimited(ZLibDecoder(raw: true), data, _maxHelperBytes);
          break;
        case "brotli":
          out = decodeLimited(brotli.decoder, data, _maxHelperBytes);
          break;
        case "gzip":
          out = gzip.encode(data);
          break;
        case "deflate":
          out = ZLibCodec().encode(data);
          break;
        case "deflateRaw":
          out = ZLibCodec(raw: true).encode(data);
          break;
        default:
          throw "不支持的压缩格式 {mode}".tf({"mode": mode});
      }
    } on String {
      rethrow;
    } on DecodedTooLarge {
      throw "解压后的内容太大（超过 16 MB）".t;
    } catch (e) {
      var compress = const {"gzip", "deflate", "deflateRaw"}.contains(mode);
      throw "{p}失败：{e}".tf({"p": compress ? "压缩".t : "解压".t, "e": e});
    }
    return base64.encode(out);
  }

  String _hash(dynamic args) {
    var data = base64.decode(args["b64"]);
    if (data.length > _maxHelperBytes) throw "Hash 的输入太大（超过 16 MB）".t;
    var alg = args["alg"].toString();
    Hash hash = switch (alg) {
      "md5" => md5,
      "sha1" => sha1,
      "sha256" => sha256,
      "sha512" => sha512,
      _ => throw "不支持的摘要算法 {alg}（支持 md5、sha1、sha256、sha512）".tf({"alg": alg}),
    };
    var key = args["key"];
    var digest = key == null
        ? hash.convert(data)
        : Hmac(hash, base64.decode(key)).convert(data);
    return base64.encode(digest.bytes);
  }

  // ---------------------------------------------------------------------
  // 关闭
  // ---------------------------------------------------------------------

  Future<void> _shutdown() async {
    _closing = true;
    for (var t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    for (var s in _sessions.values) {
      s.forceClose?.cancel();
    }
    for (var socket in _sockets.values) {
      socket.closedLocally = true;
      _closeSocket(socket.socket, 1000, null);
    }
    _sockets.clear();
    _http?.close(force: true);
    await _cookies.flush();
    await _storage.flush();
    await _settings.flush();
    try {
      _engineOrNull?.dispose();
    } catch (_) {}
    _port.close();
    _toMain({"ev": "closed"});
    Isolate.exit();
  }
}

/// 解压结果超过上限
class DecodedTooLarge implements Exception {}

class _LimitSink implements Sink<List<int>> {
  final int limit;
  final BytesBuilder out = BytesBuilder();
  _LimitSink(this.limit);

  @override
  void add(List<int> chunk) {
    // 复制：brotli 的解码器会重复使用同一块缓冲区
    out.add(chunk);
    if (out.length > limit) throw DecodedTooLarge();
  }

  @override
  void close() {}
}

/// 分块解压，结果超过 [limit] 字节时抛 [DecodedTooLarge]（防止“压缩炸弹”）
List<int> decodeLimited(
  Converter<List<int>, List<int>> decoder,
  List<int> data,
  int limit,
) {
  var sink = _LimitSink(limit);
  var input = decoder.startChunkedConversion(sink);
  for (var i = 0; i < data.length; i += 16384) {
    input.add(
      data.sublist(i, i + 16384 > data.length ? data.length : i + 16384),
    );
  }
  input.close();
  return sink.out.takeBytes();
}

/// 一个 JSON 文件里的键值对（Storage、设置项）
class _JsonStore {
  final File file;
  Map<String, dynamic>? _data;
  Timer? _saveTimer;

  _JsonStore(this.file);

  Map<String, dynamic> _load() {
    if (_data != null) return _data!;
    var data = <String, dynamic>{};
    try {
      if (file.existsSync()) {
        var j = jsonDecode(file.readAsStringSync());
        if (j is Map) data = Map<String, dynamic>.from(j);
      }
    } catch (_) {}
    return _data = data;
  }

  Future<dynamic> get(dynamic key) async => _load()[key.toString()];

  Map<String, dynamic> snapshot() => Map.of(_load());

  void setSync(String key, dynamic value) {
    _load()[key] = value;
    _schedule();
  }

  void removeSync(String key) {
    _load().remove(key);
    _schedule();
  }

  Future<void> set(dynamic key, dynamic value) async {
    _load()[key.toString()] = value;
    _schedule();
  }

  Future<void> remove(dynamic key) async {
    _load().remove(key.toString());
    _schedule();
  }

  void _schedule() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(flush());
    });
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    var data = _data;
    if (data == null) return;
    try {
      await file.parent.create(recursive: true);
      await writeFileAtomic(file, jsonEncode(data));
    } catch (_) {}
  }
}
