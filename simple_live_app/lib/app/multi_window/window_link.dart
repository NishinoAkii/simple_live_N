import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:simple_live_app/app/multi_window/window_changes.dart';
import 'package:simple_live_app/app/multi_window/window_server.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';

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
    this.pollGrace = const Duration(seconds: 10),
  }) : _client = HttpClient()..connectionTimeout = const Duration(seconds: 3);

  final int port;
  final String token;
  final UnsavedCallback? onUnsaved;
  final void Function()? onMainGone;
  final Duration timeout;

  /// 主窗口那边等指令的时长，这边多等一会儿（[pollGrace]）再算超时
  final Duration pollTimeout;
  final Duration pollGrace;

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

  /// 发一个 POST，返回状态码；连不上时抛错。没回应、连接断了但主窗口还在
  /// （电脑睡了一觉、主窗口卡了一会儿）时再发一次
  Future<int> _post(String path, Object body) async {
    try {
      return await _postOnce(path, body);
    } catch (_) {
      if (_closed || !await _reachable()) {
        rethrow;
      }
      return _postOnce(path, body);
    }
  }

  Future<int> _postOnce(String path, Object body) async {
    var request = await _client
        .post(InternetAddress.loopbackIPv4.address, port, path)
        .timeout(timeout);
    request.headers.set(WindowServer.tokenHeader, token);
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(json.encode(body)));
    var response = await request.close().timeout(timeout);
    await response.drain<void>();
    return response.statusCode;
  }

  /// 告诉主窗口这个窗口在看的直播间、挪到了哪里，和改动排在一起按顺序发。
  /// 没送到不提示（连不上时照常算主窗口不在了）
  Future<bool> report(WindowReport report) {
    var result = _tail.then((_) => _report(report));
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<bool> _report(WindowReport report) async {
    if (!_online || _closed) {
      return false;
    }
    try {
      var status = await _post("/state", report.toJson());
      if (status == HttpStatus.unauthorized) {
        _goOffline();
      }
      return status == HttpStatus.ok;
    } catch (_) {
      _goOffline();
      return false;
    }
  }

  Future<bool> _send(WindowChange change) async {
    if (!_online || _closed) {
      onUnsaved?.call(change, true);
      return false;
    }
    try {
      var status = await _post("/op", {"op": change.op, "data": change.data});
      if (status == HttpStatus.ok) {
        return true;
      }
      if (status == HttpStatus.unauthorized) {
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
    if (await _reachable()) {
      return true;
    }
    _goOffline();
    return false;
  }

  /// 主窗口应不应。端口没了、口令作废了马上就知道；没回应、旧连接断了的再试两次
  Future<bool> _reachable() async {
    for (var i = 0; i < 3 && !_closed; i++) {
      try {
        var request = await _client
            .get(InternetAddress.loopbackIPv4.address, port, "/ping")
            .timeout(timeout);
        request.headers.set(WindowServer.tokenHeader, token);
        var response = await request.close().timeout(timeout);
        await response.drain<void>();
        return response.statusCode == HttpStatus.ok;
      } on TimeoutException {
        continue;
      } on HttpException {
        continue;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// 一直等主窗口的指令：要这个窗口关掉时调用 [onClose]；主窗口的置顶变了时调用
  /// [onPin]（跟着置顶或取消）；连不上时算主窗口不在了（电脑睡醒、主窗口卡住以后
  /// 没回应的不算，接着等）
  Future<void> watch({
    required void Function() onClose,
    void Function(bool pinned)? onPin,
  }) async {
    while (_online && !_closed) {
      String? command;
      try {
        var request = await _client
            .get(InternetAddress.loopbackIPv4.address, port, "/wait")
            .timeout(timeout);
        request.headers.set(WindowServer.tokenHeader, token);
        var response = await request
            .close()
            .timeout(pollTimeout + pollGrace);
        var text = await response.transform(utf8.decoder).join();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException("status ${response.statusCode}");
        }
        var body = json.decode(text);
        command = body is Map ? body["cmd"]?.toString() : null;
      } catch (_) {
        if (_closed) {
          return;
        }
        if (await _reachable()) {
          continue;
        }
        _goOffline();
        return;
      }
      if (command == "close") {
        onClose();
        return;
      }
      if (command == "pin" || command == "unpin") {
        onPin?.call(command == "pin");
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
