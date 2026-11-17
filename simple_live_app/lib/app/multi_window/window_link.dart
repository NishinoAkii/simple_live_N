import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:simple_live_app/app/multi_window/window_changes.dart';
import 'package:simple_live_app/app/multi_window/window_server.dart';

/// 改动没交给主窗口：[mainGone] 为 true 是主窗口不在了（关了或崩了），
/// 否则是主窗口没收（内容不对，或者保存时出错）
typedef UnsavedCallback = void Function(WindowChange change, bool mainGone);

/// 副窗口这边：把要留下的改动交给主窗口保存，等主窗口的指令。
///
/// 主窗口连不上以后就当它不在了，之后的改动都不再发，直接算没保存
class MainWindowLink {
  MainWindowLink({
    required this.port,
    required this.token,
    this.onUnsaved,
    this.onMainGone,
    this.timeout = const Duration(seconds: 5),
    this.pollTimeout = const Duration(seconds: 25),
  }) : _client = HttpClient()..connectionTimeout = const Duration(seconds: 3);

  final int port;
  final String token;
  final UnsavedCallback? onUnsaved;
  final void Function()? onMainGone;
  final Duration timeout;

  /// 主窗口那边等指令的时长，这边多等一会儿再算超时
  final Duration pollTimeout;

  final HttpClient _client;
  bool _online = true;
  bool _closed = false;
  Future<void> _tail = Future.value();

  bool get online => _online;

  /// 交一条改动，按调用顺序一条一条发。主窗口存好了返回 true
  Future<bool> send(WindowChange change) {
    var result = _tail.then((_) => _send(change));
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<bool> _send(WindowChange change) async {
    if (!_online || _closed) {
      onUnsaved?.call(change, true);
      return false;
    }
    try {
      var request = await _client
          .post(InternetAddress.loopbackIPv4.address, port, "/op")
          .timeout(timeout);
      request.headers.set(WindowServer.tokenHeader, token);
      request.headers.contentType = ContentType.json;
      request.add(
          utf8.encode(json.encode({"op": change.op, "data": change.data})));
      var response = await request.close().timeout(timeout);
      await response.drain<void>();
      if (response.statusCode == HttpStatus.ok) {
        return true;
      }
      if (response.statusCode == HttpStatus.unauthorized) {
        // 口令作废了：主窗口已经不认这个窗口
        _goOffline();
        onUnsaved?.call(change, true);
        return false;
      }
      onUnsaved?.call(change, false);
      return false;
    } catch (_) {
      _goOffline();
      onUnsaved?.call(change, true);
      return false;
    }
  }

  /// 主窗口在不在
  Future<bool> ping() async {
    try {
      var request = await _client
          .get(InternetAddress.loopbackIPv4.address, port, "/ping")
          .timeout(timeout);
      request.headers.set(WindowServer.tokenHeader, token);
      var response = await request.close().timeout(timeout);
      await response.drain<void>();
      if (response.statusCode == HttpStatus.ok) {
        return true;
      }
    } catch (_) {}
    _goOffline();
    return false;
  }

  /// 一直等主窗口的指令：要这个窗口关掉时调用 [onClose]；连不上时算主窗口不在了
  Future<void> watch({required void Function() onClose}) async {
    while (_online && !_closed) {
      String? command;
      try {
        var request = await _client
            .get(InternetAddress.loopbackIPv4.address, port, "/wait")
            .timeout(timeout);
        request.headers.set(WindowServer.tokenHeader, token);
        var response = await request
            .close()
            .timeout(pollTimeout + const Duration(seconds: 10));
        var text = await response.transform(utf8.decoder).join();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException("status ${response.statusCode}");
        }
        var body = json.decode(text);
        command = body is Map ? body["cmd"]?.toString() : null;
      } catch (_) {
        if (!_closed) {
          _goOffline();
        }
        return;
      }
      if (command == "close") {
        onClose();
        return;
      }
    }
  }

  void _goOffline() {
    if (!_online) {
      return;
    }
    _online = false;
    onMainGone?.call();
  }

  void dispose() {
    _closed = true;
    _client.close(force: true);
  }
}
