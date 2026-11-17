import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/youtube_chat_parser.dart';
import 'package:simple_live_core/src/common/youtube_innertube.dart';
import 'package:simple_live_core/src/common/youtube_parser.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/youtube_site.dart';
import 'package:simple_live_core/src/common/core_text.dart';

class YouTubeDanmakuArgs {
  /// 当前直播的视频 ID，未开播时为空
  final String videoId;

  /// 频道 ID（房间号）
  final String channelId;

  YouTubeDanmakuArgs({required this.videoId, required this.channelId});

  @override
  String toString() => videoId;
}

/// YouTube 直播聊天
///
/// 接收：匿名读取 live_chat 页面拿到“所有聊天”的令牌，再轮询
/// InnerTube 的 live_chat/get_live_chat。网页端靠推送通知新消息，
/// 轮询间隔（timeoutMs）给的是 10 秒，这里压到 1–5 秒；
/// 每批消息在下一次轮询前均匀放出，弹幕不会一阵一阵地出现。
class YouTubeDanmaku implements LiveDanmaku {
  final YouTubeSite? site;
  YouTubeDanmaku({this.site});

  @override
  int heartbeatTime = 60 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;

  YouTubeDanmakuArgs? _args;
  YouTubeDanmakuArgs get danmakuArgs => _args!;
  set danmakuArgs(YouTubeDanmakuArgs value) => _args = value;

  /// 每批消息是否在轮询间隔内均匀放出（测试时可关闭）
  bool smoothDelivery = true;

  /// 进入直播间（或重新连接）时最多显示的历史消息条数
  static const int kHistoryLimit = 20;

  static const int kMinPollMs = 1000;
  static const int kMaxPollMs = 5000;

  /// 在线人数的刷新间隔
  static const Duration kViewerInterval = Duration(seconds: 30);

  bool _running = false;

  /// 每次 start/stop 递增，旧的轮询循环据此退出
  int _generation = 0;
  CancelToken? _cancel;
  Timer? _waitTimer;
  Completer<void>? _waitCompleter;
  Timer? _drainTimer;
  final Queue<LiveMessage> _queue = Queue();
  int _drainTicks = 1;
  static const Duration _drainTick = Duration(milliseconds: 200);

  String? _continuation;
  bool _historyBatch = false;
  bool _ready = false;
  int _failures = 0;
  DateTime _lastViewers = DateTime.fromMillisecondsSinceEpoch(0);

  /// 已显示的消息 ID，只保留最近的一部分
  final LinkedHashSet<String> _seen = LinkedHashSet();
  static const int _seenLimit = 3000;

  @override
  Future start(dynamic args) async {
    await stop(clearCallbacks: false);
    danmakuArgs = args as YouTubeDanmakuArgs;
    if (danmakuArgs.videoId.isEmpty) {
      onClose?.call("主播现在没在直播，没有连接聊天".t);
      return;
    }
    _running = true;
    _generation++;
    _cancel = CancelToken();
    _continuation = null;
    _ready = false;
    _failures = 0;
    _seen.clear();
    _lastViewers = DateTime.fromMillisecondsSinceEpoch(0);
    unawaited(_loop(_generation));
  }

  bool _alive(int generation) => _running && generation == _generation;

  Future<void> _loop(int generation) async {
    while (_alive(generation)) {
      var delay = kMaxPollMs;
      try {
        if (_continuation == null) {
          await _bootstrap();
          if (!_alive(generation)) {
            return;
          }
        }
        var history = _historyBatch;
        var response = await YouTubeInnertube.post("live_chat/get_live_chat", {
          "continuation": _continuation,
        }, cancel: _cancel);
        if (!_alive(generation)) {
          return;
        }
        var batch = parseYouTubeChatResponse(response, useTimestamps: history);
        if (!batch.valid) {
          // 响应里没有聊天数据：令牌可能已失效，重新读取页面
          throw CoreError("聊天数据异常".t, statusCode: 400);
        }
        if (batch.ended) {
          _running = false;
          onClose?.call("直播聊天已结束".t);
          return;
        }
        _continuation = batch.continuation;
        _historyBatch = false;
        delay = batch.timeoutMs.clamp(kMinPollMs, kMaxPollMs);
        _deliver(batch.items, history: history, intervalMs: delay);
        if (!_ready || _failures > 0) {
          _ready = true;
          onReady?.call();
        }
        _failures = 0;
        _refreshViewers(generation);
      } on _ChatUnavailable catch (e) {
        if (_alive(generation)) {
          _running = false;
          onClose?.call(e.message);
        }
        return;
      } catch (e) {
        if (!_alive(generation)) {
          return;
        }
        _failures++;
        if (_failures == 1) {
          onClose?.call("和聊天服务器断开了，正在重连".t);
        }
        // 令牌失效（4xx）或连续失败时重新读取页面获取新令牌
        var status = e is CoreError ? e.statusCode : 0;
        if ((status >= 400 && status < 500) || _failures % 3 == 0) {
          _continuation = null;
        }
        delay = min(30000, 2000 * pow(2, min(_failures - 1, 4)).toInt());
      }
      await _wait(delay, generation);
    }
  }

  /// 读取 live_chat 页面，取“所有聊天”的令牌
  Future<void> _bootstrap() async {
    String html;
    try {
      html = await YouTubeInnertube.getPage(
        "https://www.youtube.com/live_chat?v=${danmakuArgs.videoId}&is_popout=1",
        cancel: _cancel,
      );
    } on CoreError catch (e) {
      if (e.statusCode == 404) {
        throw _ChatUnavailable("这场直播没有开放聊天".t);
      }
      rethrow;
    }
    var page = YouTubeLiveChatPage.parse(html);
    var token = page.continuation;
    if (token == null) {
      throw _ChatUnavailable(page.unavailableReason ?? "这场直播没有开放聊天".t);
    }
    _continuation = token;
    _historyBatch = true;
  }

  /// 去重后交给 App
  ///
  /// 首批（及重连后）是最近的历史消息：只显示最后 [kHistoryLimit] 条，
  /// 醒目留言按发送时间计算，已过显示时长的不再显示。
  void _deliver(
    List<YouTubeChatItem> items, {
    required bool history,
    required int intervalMs,
  }) {
    var fresh = <YouTubeChatItem>[];
    for (var item in items) {
      if (_seen.add(item.id)) {
        fresh.add(item);
      }
    }
    while (_seen.length > _seenLimit) {
      _seen.remove(_seen.first);
    }
    if (history) {
      var now = DateTime.now();
      var superChats = fresh.where((e) {
        if (!e.isSuperChat) {
          return false;
        }
        var data = e.message.data;
        return data is LiveSuperChatMessage && data.endTime.isAfter(now);
      });
      var chats = fresh.where((e) => !e.isSuperChat).toList();
      if (chats.length > kHistoryLimit) {
        chats = chats.sublist(chats.length - kHistoryLimit);
      }
      // 聊天只进聊天区，不一下子飞过视频；醒目留言照常显示
      for (var item in superChats) {
        onMessage?.call(item.message);
      }
      for (var item in chats) {
        onMessage?.call(item.message.asHistory());
      }
      return;
    }
    var chats = <LiveMessage>[];
    for (var item in fresh) {
      if (item.isSuperChat) {
        // 醒目留言立即显示
        onMessage?.call(item.message);
      } else {
        chats.add(item.message);
      }
    }
    if (!smoothDelivery) {
      chats.forEach(_emit);
      return;
    }
    if (chats.isEmpty) {
      return;
    }
    _queue.addAll(chats);
    _drainTicks = max(1, intervalMs ~/ _drainTick.inMilliseconds);
    _drainTimer ??= Timer.periodic(_drainTick, (_) => _drain());
  }

  void _emit(LiveMessage message) {
    onMessage?.call(message);
  }

  /// 按剩余时间均匀放出队列中的消息；积压时（下一批已到）自动加快
  void _drain() {
    if (_queue.isEmpty) {
      _drainTimer?.cancel();
      _drainTimer = null;
      return;
    }
    var count = (_queue.length / _drainTicks).ceil();
    for (var i = 0; i < count && _queue.isNotEmpty; i++) {
      _emit(_queue.removeFirst());
    }
    if (_drainTicks > 1) {
      _drainTicks--;
    }
  }

  /// 在线人数（updated_metadata，约 2KB），每 [kViewerInterval] 刷新一次
  void _refreshViewers(int generation) {
    var now = DateTime.now();
    if (now.difference(_lastViewers) < kViewerInterval) {
      return;
    }
    _lastViewers = now;
    YouTubeInnertube.post("updated_metadata", {
          "videoId": danmakuArgs.videoId,
        }, cancel: _cancel)
        .then((response) {
          var viewers = parseYouTubeViewers(response);
          if (viewers != null && _alive(generation)) {
            onMessage?.call(
              LiveMessage(
                type: LiveMessageType.online,
                userName: "",
                message: "",
                color: LiveMessageColor.white,
                data: viewers,
              ),
            );
          }
        })
        .catchError((_) {});
  }

  /// 可被 [stop] 打断的等待
  Future<void> _wait(int milliseconds, int generation) {
    if (!_alive(generation)) {
      return Future.value();
    }
    var completer = Completer<void>();
    _waitCompleter = completer;
    _waitTimer = Timer(Duration(milliseconds: milliseconds), () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future;
  }

  @override
  void heartbeat() {}

  @override
  Future stop({bool clearCallbacks = true}) async {
    _running = false;
    _generation++;
    _cancel?.cancel();
    _cancel = null;
    _waitTimer?.cancel();
    _waitTimer = null;
    var waiting = _waitCompleter;
    if (waiting != null && !waiting.isCompleted) {
      waiting.complete();
    }
    _waitCompleter = null;
    _drainTimer?.cancel();
    _drainTimer = null;
    _queue.clear();
    if (clearCallbacks) {
      onMessage = null;
      onClose = null;
    }
  }
}

/// 聊天不可用（未开放聊天等），不再重试
class _ChatUnavailable implements Exception {
  final String message;
  _ChatUnavailable(this.message);
}
