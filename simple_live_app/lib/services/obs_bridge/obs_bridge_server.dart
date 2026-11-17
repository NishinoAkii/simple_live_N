import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:simple_live_app/services/obs_bridge/ass_writer.dart';
import 'package:simple_live_app/services/obs_bridge/obs_bridge_hub.dart';
import 'package:simple_live_app/services/obs_bridge/obs_events.dart';
import 'package:simple_live_app/services/obs_bridge/obs_pages.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 录屏接口的 HTTP 服务（dart:io，不用第三方包）。
///
/// 页面：/、/overlay、/chat、/sc；WebSocket：/ws；
/// 数据：/api/room、/api/messages、/api/config、/api/ass；ASS 字幕流：/ass/live。
/// 默认只监听 127.0.0.1；[lan] 时监听 0.0.0.0，并且每个请求都要带 [token]
class ObsBridgeServer {
  ObsBridgeServer({
    required this.hub,
    required this.config,
    this.port = 25789,
    this.lan = false,
    this.token,
    this.address,
  });

  final ObsBridgeHub hub;

  /// 应用当前的弹幕设置（/api/config，也是 ASS 的默认样式）
  final Map<String, dynamic> Function() config;

  /// 端口，0 为系统分配（测试用）
  final int port;

  /// 允许局域网访问
  final bool lan;

  /// 局域网访问时每个请求都要带的令牌（地址参数 token 或请求头 X-Token）；
  /// 局域网访问而没有令牌时拒绝所有请求
  final String? token;

  /// 监听的地址，为空时按 [lan] 选择（测试里局域网模式也只监听本机）
  final InternetAddress? address;

  HttpServer? _server;
  StreamSubscription<ObsHubEvent>? _subscription;
  final Set<WebSocket> _sockets = {};
  final Set<_AssLiveClient> _assClients = {};

  bool get running => _server != null;

  /// 实际监听的端口
  int get boundPort => _server?.port ?? 0;

  int get webSocketCount => _sockets.length;
  int get assStreamCount => _assClients.length;

  bool get _needToken => lan;

  Future<void> start() async {
    if (_server != null) {
      return;
    }
    var server = await HttpServer.bind(
      address ?? (lan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4),
      port,
    );
    _server = server;
    _subscription = hub.events.listen(_onEvent);
    server.listen(
      (request) => _handle(request).catchError((_) {}),
      onError: (_) {},
    );
  }

  Future<void> stop() async {
    var server = _server;
    _server = null;
    await _subscription?.cancel();
    _subscription = null;
    for (var socket in _sockets.toList()) {
      try {
        await socket.close(WebSocketStatus.goingAway);
      } catch (_) {}
    }
    _sockets.clear();
    for (var client in _assClients.toList()) {
      await client.close();
    }
    _assClients.clear();
    await server?.close(force: true);
  }

  // ---------------- 请求 ----------------

  Future<void> _handle(HttpRequest request) async {
    var response = request.response;
    try {
      if (!lan && !_isLocalHost(request)) {
        // 只监听本机时，拒绝 Host 不是本机的请求（防止网页借 DNS 重绑定读取）
        await _json(response, {"error": "host"}, status: HttpStatus.forbidden);
        return;
      }
      if (!_authorized(request)) {
        await _json(
          response,
          {"error": "token", "message": "已允许局域网访问，地址里需要带上 token".t},
          status: HttpStatus.forbidden,
        );
        return;
      }
      response.headers.set("access-control-allow-origin", "*");
      if (request.method == "OPTIONS") {
        response.headers.set("access-control-allow-headers", "x-token");
        response.statusCode = HttpStatus.noContent;
        await response.close();
        return;
      }
      if (request.method != "GET") {
        await _json(response, {"error": "method"},
            status: HttpStatus.methodNotAllowed);
        return;
      }
      var path = request.uri.path;
      if (path.length > 1 && path.endsWith("/")) {
        path = path.substring(0, path.length - 1);
      }
      switch (path) {
        case "/":
        case "/index.html":
          await _html(
            response,
            ObsPages.index(
              base:
                  "http://${request.headers.value(HttpHeaders.hostHeader) ?? "127.0.0.1:$boundPort"}",
              token: _needToken ? token : null,
            ),
          );
        case "/overlay":
          await _html(response, ObsPages.overlay);
        case "/chat":
          await _html(response, ObsPages.chat);
        case "/sc":
          await _html(response, ObsPages.superChat);
        case "/ws":
          await _webSocket(request);
        case "/api/room":
          await _json(response, {
            "v": kObsSchemaVersion,
            "instance": hub.instance,
            "room": hub.room?.toJson(),
          });
        case "/api/messages":
          var since =
              int.tryParse(request.uri.queryParameters["since"] ?? "") ?? 0;
          await _json(response, {
            "v": kObsSchemaVersion,
            "instance": hub.instance,
            "room": hub.room?.toJson(),
            "lastId": hub.lastId,
            "messages": hub.messagesSince(since),
          });
        case "/api/config":
          await _json(response, {"v": kObsSchemaVersion, ...config()});
        case "/api/ass":
          await _assDownload(request);
        case "/ass/live":
          await _assLive(request);
        case "/favicon.ico":
          response.statusCode = HttpStatus.noContent;
          await response.close();
        default:
          await _json(response, {"error": "not found"},
              status: HttpStatus.notFound);
      }
    } catch (_) {
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
    }
  }

  static bool _isLocalHost(HttpRequest request) {
    var host = request.headers.host;
    if (host == null || host.isEmpty) {
      return true;
    }
    host = host.toLowerCase();
    return host == "127.0.0.1" ||
        host == "localhost" ||
        host == "::1" ||
        host == "[::1]";
  }

  bool _authorized(HttpRequest request) {
    if (!_needToken) {
      return true;
    }
    var expected = token ?? "";
    if (expected.isEmpty) {
      return false;
    }
    var given = request.uri.queryParameters["token"] ??
        request.headers.value("x-token") ??
        "";
    return _sameText(given, expected);
  }

  /// 逐字比较完，耗时与第几个字不同无关
  static bool _sameText(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static Future<void> _html(HttpResponse response, String body) async {
    response.headers.contentType = ContentType.html;
    response.headers.set("cache-control", "no-store");
    response.write(body);
    await response.close();
  }

  static Future<void> _json(
    HttpResponse response,
    Object body, {
    int status = HttpStatus.ok,
  }) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.set("cache-control", "no-store");
    response.write(jsonEncode(body));
    await response.close();
  }

  // ---------------- WebSocket ----------------

  Future<void> _webSocket(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      await _json(request.response, {"error": "需要 WebSocket 连接".t},
          status: HttpStatus.badRequest);
      return;
    }
    var query = request.uri.queryParameters;
    var history = (int.tryParse(query["history"] ?? "") ?? 0)
        .clamp(0, hub.bufferSize)
        .toInt();
    var superChats = query["superchats"] == "1";
    var socket = await WebSocketTransformer.upgrade(request);
    socket.pingInterval = const Duration(seconds: 15);
    _sockets.add(socket);
    socket.listen(
      (_) {},
      onDone: () => _sockets.remove(socket),
      onError: (_) => _sockets.remove(socket),
      cancelOnError: true,
    );
    // 先发当前直播间，再补发最近的消息
    _send(socket, jsonEncode(ObsEvents.room(hub.room, time: hub.now())));
    for (var item in hub.recentChats(history)) {
      _send(socket, jsonEncode(item));
    }
    if (superChats) {
      for (var item in hub.activeSuperChats()) {
        _send(socket, jsonEncode(item));
      }
    }
  }

  void _send(WebSocket socket, String data) {
    try {
      socket.add(data);
    } catch (_) {
      _sockets.remove(socket);
    }
  }

  void _onEvent(ObsHubEvent event) {
    if (_sockets.isNotEmpty) {
      var data = event.encoded;
      for (var socket in _sockets.toList()) {
        _send(socket, data);
      }
    }
    for (var client in _assClients.toList()) {
      client.onEvent(event);
    }
  }

  // ---------------- ASS ----------------

  /// ASS 的样式：应用的弹幕设置，加上地址参数 w、h、size、speed、area、
  /// opacity、stroke、font、all、sc
  AssOptions assOptions(Map<String, String> query) {
    double? number(String key) => double.tryParse(query[key] ?? "");
    int? integer(String key) => int.tryParse(query[key] ?? "");
    var font = query["font"]?.trim();
    return AssOptions.fromConfig(
      config(),
      width: (integer("w") ?? 1920).clamp(160, 7680).toInt(),
      height: (integer("h") ?? 1080).clamp(120, 4320).toInt(),
      fontSize: number("size")?.clamp(4.0, 400.0).toDouble(),
      speed: number("speed"),
      area: number("area"),
      opacity: number("opacity"),
      outline: number("stroke")?.clamp(0.0, 40.0).toDouble(),
      fontName: font == null || font.isEmpty ? null : font,
      keepAll: query["all"] == "1",
      superChats: query["sc"] != "0",
    );
  }

  String _assTitle() {
    var room = hub.room;
    return room == null ? "SimpleLive 弹幕".t : "SimpleLive 弹幕 - {label}".tf({"label": room.label});
  }

  /// /api/ass?from=&to=：本次开启接口以来的弹幕，时间从 from 算起
  Future<void> _assDownload(HttpRequest request) async {
    var query = request.uri.queryParameters;
    int? from, to;
    for (var key in ["from", "to"]) {
      var raw = query[key];
      if (raw == null || raw.isEmpty) {
        continue;
      }
      var value = int.tryParse(raw);
      if (value == null) {
        await _json(request.response, {"error": "{key} 应为 Unix 毫秒时间".tf({"key": key})},
            status: HttpStatus.badRequest);
        return;
      }
      if (key == "from") {
        from = value;
      } else {
        to = value;
      }
    }
    var entries = hub.history(from: from, to: to);
    var start =
        from ?? (entries.isNotEmpty ? entries.first.time : null) ?? hub.now();
    var text = AssDanmakuWriter.build(
      assOptions(query),
      entries.map((e) => e.comment.at(Duration(milliseconds: e.time - start))),
      title: _assTitle(),
    );
    var room = hub.room;
    var name = assFileName(
      site: room?.site,
      roomId: room?.roomId,
      time: DateTime.fromMillisecondsSinceEpoch(start),
    );
    var asciiName = name.replaceAll(RegExp(r'[^\x20-\x7e]'), "_");
    var response = request.response;
    response.headers.contentType =
        ContentType("text", "x-ssa", charset: "utf-8");
    response.headers.set("cache-control", "no-store");
    response.headers.set(
      "content-disposition",
      "attachment; filename=\"$asciiName\"; "
          "filename*=UTF-8''${Uri.encodeComponent(name)}",
    );
    response.write("\uFEFF");
    response.write(text);
    await response.close();
  }

  /// /ass/live：先写文件头，之后每条弹幕写一行（时间从这次请求开始算）。
  ///
  /// dart:io 在响应没写完时不读这个连接，发现不了对方断开；所以接管 socket，
  /// 自己按 chunked 分块写，并监听对方关闭
  Future<void> _assLive(HttpRequest request) async {
    var response = request.response;
    response.headers.contentType =
        ContentType("text", "plain", charset: "utf-8");
    response.headers.set("cache-control", "no-store");
    response.headers.set("x-content-type-options", "nosniff");
    response.headers.chunkedTransferEncoding = true;
    response.persistentConnection = false;
    var writer = AssDanmakuWriter(assOptions(request.uri.queryParameters));
    var start = hub.now();
    var socket = await response.detachSocket();
    late _AssLiveClient client;
    client = _AssLiveClient(
      socket,
      writer,
      start: start,
      onClosed: () => _assClients.remove(client),
    );
    if (_server == null) {
      // 已经停止
      await client.close();
      return;
    }
    _assClients.add(client);
    socket.listen(
      (_) {},
      onDone: client.disconnected,
      onError: (_) => client.disconnected(),
      cancelOnError: true,
    );
    client.write("\uFEFF${writer.header(title: _assTitle())}");
    var room = hub.room;
    if (room != null) {
      client.writeLine(
          writer.line(AssComment.note(Duration.zero, "直播间：{label}".tf({"label": room.label}))));
    }
  }
}

/// 一个 /ass/live 连接：每批内容写成一个 chunk 并立即发出；
/// 写完一批再写下一批（flush 进行中不能写入）
class _AssLiveClient {
  _AssLiveClient(
    this.socket,
    this.writer, {
    required this.start,
    required this.onClosed,
  });

  final Socket socket;
  final AssDanmakuWriter writer;

  /// 开始时间（Unix 毫秒），弹幕时间从这里算起
  final int start;
  final void Function() onClosed;

  final StringBuffer _pending = StringBuffer();
  Future<void>? _pumping;
  bool _busy = false;
  bool _closed = false;

  void onEvent(ObsHubEvent event) {
    var time = Duration(milliseconds: event.time - start);
    if (event.type == "room") {
      if (event.roomChanged) {
        var room = event.room;
        writeLine(writer.line(AssComment.note(
          time,
          room == null ? "直播间已关闭".t : "直播间：{label}".tf({"label": room.label}),
        )));
      }
      return;
    }
    var comment = event.comment;
    if (comment != null) {
      writeLine(writer.line(comment.at(time)));
    }
  }

  void writeLine(String? line) {
    if (line != null) {
      write("$line\n");
    }
  }

  void write(String text) {
    if (_closed || text.isEmpty) {
      return;
    }
    _pending.write(text);
    if (!_busy) {
      _pumping = _pump();
    }
  }

  void _addChunk(List<int> bytes) {
    socket.add(ascii.encode("${bytes.length.toRadixString(16)}\r\n"));
    socket.add(bytes);
    socket.add(const [13, 10]);
  }

  Future<void> _pump() async {
    _busy = true;
    try {
      while (_pending.isNotEmpty && !_closed) {
        var bytes = utf8.encode(_pending.toString());
        _pending.clear();
        _addChunk(bytes);
        await socket.flush();
      }
    } catch (_) {
      disconnected();
    } finally {
      _busy = false;
    }
  }

  /// 对方断开：直接丢掉连接
  void disconnected() {
    if (_closed) {
      return;
    }
    _closed = true;
    onClosed();
    socket.destroy();
  }

  /// 接口停止：写完已有的内容和结束标记再关闭
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    onClosed();
    try {
      await _pumping;
      if (_pending.isNotEmpty) {
        _addChunk(utf8.encode(_pending.toString()));
        _pending.clear();
      }
      socket.add(ascii.encode("0\r\n\r\n"));
      await socket.flush().timeout(const Duration(seconds: 2));
      await socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      socket.destroy();
    }
  }
}
