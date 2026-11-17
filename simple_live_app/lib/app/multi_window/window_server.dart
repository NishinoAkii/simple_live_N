import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/multi_window/window_changes.dart';

/// 主窗口收到改动后真正保存的地方
abstract class WindowChangeSink {
  Future<void> apply(WindowChange change);
}

class _Peer {
  _Peer(this.token);
  final String token;
  Completer<String>? waiting;
  String? command;
}

/// 主窗口给副窗口开的本机服务。
///
/// - 只听 127.0.0.1，端口由系统随机给；
/// - 每个副窗口一个口令（[WindowToken]），放在请求头 [tokenHeader] 里，
///   按固定时间比较，副窗口关了口令就作废；
/// - 浏览器发来的请求（带 Origin）一律不收；
/// - 只有三个地址：`GET /ping` 看主窗口在不在，`POST /op` 交一条改动
///   （只收 [WindowChange] 列出的几种，内容不对回 400），
///   `GET /wait` 等主窗口的指令（要它关掉时回 close，没事时过一会儿回 none）
class WindowServer {
  WindowServer(
    this.sink, {
    this.pollTimeout = const Duration(seconds: 25),
    this.maxBody = 256 * 1024,
  });

  static const tokenHeader = "x-sl-token";

  final WindowChangeSink sink;
  final Duration pollTimeout;
  final int maxBody;

  HttpServer? _server;
  final List<_Peer> _peers = [];
  Future<void> _tail = Future.value();

  bool get running => _server != null;
  InternetAddress? get address => _server?.address;
  int get port => _server?.port ?? 0;
  int get peerCount => _peers.length;

  Future<int> start() async {
    if (_server == null) {
      var server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.idleTimeout = const Duration(seconds: 60);
      _server = server;
      server.listen((request) => unawaited(_handle(request)));
    }
    return _server!.port;
  }

  /// 给一个新的副窗口发口令
  String addPeer() {
    var token = WindowToken.generate();
    _peers.add(_Peer(token));
    return token;
  }

  /// 副窗口关了：口令作废
  void removePeer(String token) {
    var peer = _find(token);
    if (peer == null) {
      return;
    }
    _peers.remove(peer);
    _complete(peer, "none");
  }

  /// 让这个副窗口自己正常退出
  void requestClose(String token) {
    var peer = _find(token);
    if (peer == null) {
      return;
    }
    peer.command = "close";
    _complete(peer, "close");
  }

  Future<void> close() async {
    for (var peer in _peers) {
      _complete(peer, "none");
    }
    _peers.clear();
    var server = _server;
    _server = null;
    await server?.close(force: true);
  }

  _Peer? _find(String token) {
    for (var p in _peers) {
      if (p.token == token) {
        return p;
      }
    }
    return null;
  }

  void _complete(_Peer peer, String command) {
    var waiting = peer.waiting;
    peer.waiting = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.complete(command);
    }
  }

  /// 每个口令都比一遍，用时和对上了哪一个、错在哪一位无关
  _Peer? _auth(String? token) {
    if (!WindowToken.isWellFormed(token)) {
      return null;
    }
    _Peer? found;
    for (var p in _peers) {
      if (WindowToken.equals(token!, p.token)) {
        found = p;
      }
    }
    return found;
  }

  Future<void> _handle(HttpRequest request) async {
    var response = request.response;
    try {
      if (request.headers.value("origin") != null) {
        return await _reply(response, HttpStatus.forbidden);
      }
      var peer = _auth(request.headers.value(tokenHeader));
      if (peer == null) {
        return await _reply(response, HttpStatus.unauthorized);
      }
      var path = request.uri.path;
      if (request.method == "GET" && path == "/ping") {
        return await _reply(response, HttpStatus.ok, {"ok": true});
      }
      if (request.method == "GET" && path == "/wait") {
        return await _wait(peer, response);
      }
      if (request.method == "POST" && path == "/op") {
        return await _op(request, response);
      }
      await _reply(response, HttpStatus.notFound);
    } catch (_) {
      try {
        await _reply(response, HttpStatus.internalServerError);
      } catch (_) {}
    }
  }

  Future<void> _wait(_Peer peer, HttpResponse response) async {
    var command = peer.command;
    if (command == null) {
      _complete(peer, "none");
      var waiting = Completer<String>();
      peer.waiting = waiting;
      command = await waiting.future.timeout(
        pollTimeout,
        onTimeout: () => "none",
      );
      if (identical(peer.waiting, waiting)) {
        peer.waiting = null;
      }
    }
    await _reply(response, HttpStatus.ok, {"cmd": command});
  }

  Future<void> _op(HttpRequest request, HttpResponse response) async {
    // 只有口令对的副窗口能走到这里；太大的读完扔掉再回 413，对方能收到回复
    var bytes = <int>[];
    var tooLarge = false;
    await for (var chunk in request) {
      if (tooLarge) {
        continue;
      }
      bytes.addAll(chunk);
      if (bytes.length > maxBody) {
        tooLarge = true;
        bytes = const [];
      }
    }
    if (tooLarge) {
      return _reply(response, HttpStatus.requestEntityTooLarge);
    }
    WindowChange change;
    try {
      var body = json.decode(utf8.decode(bytes));
      if (body is! Map || body["op"] is! String) {
        throw const FormatException("body");
      }
      change = WindowChange.decode(body["op"] as String, body["data"]);
    } on FormatException {
      return _reply(response, HttpStatus.badRequest);
    }
    // 一条一条按到达顺序存
    var done = _tail.then((_) => sink.apply(change));
    _tail = done.catchError((_) {});
    try {
      await done;
    } catch (_) {
      return _reply(response, HttpStatus.internalServerError);
    }
    await _reply(response, HttpStatus.ok, {"ok": true});
  }

  Future<void> _reply(HttpResponse response, int status,
      [Map<String, Object?>? body]) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(json.encode(body ?? {"ok": false}));
    await response.close();
  }
}
