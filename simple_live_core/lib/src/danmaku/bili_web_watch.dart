import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:simple_live_core/src/bilibili_site.dart';
import 'package:simple_live_core/src/common/bili_watch_heart.dart';
import 'package:simple_live_core/src/common/bili_web.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/http_client.dart';

/// 已登录时，像网页端打开直播间一样上报“在看”：
/// 进房记录（roomEntryAction）一次，观看时长心跳 E 一次，之后按服务器给的间隔发 X
/// （签名见 [BiliWatchHeart]）。跟着弹幕连接开始和结束；出错只记日志，不影响观看。
class BiliWebWatch {
  BiliWebWatch(this.site, this.room, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final BiliBiliSite site;
  final BiliHeartRoom room;
  final DateTime Function() _now;

  bool _closed = false;
  Timer? _timer;
  Completer<void>? _sleep;

  static const String roomEntryUrl =
      "https://api.live.bilibili.com/xlive/web-room/v1/index/roomEntryAction";

  int get _nowMs => _now().millisecondsSinceEpoch;

  Future<void> run() async {
    var csrf = site.csrf;
    var buvid = site.liveBuvid;
    if (csrf.isEmpty || buvid.isEmpty || !room.valid) {
      return;
    }
    var uuid = BiliWatchHeart.newUuid();
    var userAgent = BiliWeb.userAgent();
    try {
      await _send(
        roomEntryUrl,
        {"csrf": csrf},
        body: "room_id=${room.roomId}&platform=pc",
      );
    } catch (e) {
      CoreLog.error(e);
    }
    if (_closed) {
      return;
    }
    try {
      var state = BiliHeartState.fromEnter(
        await _send(
          BiliWatchHeart.enterUrl,
          BiliWatchHeart.enterParams(
            room: room,
            buvid: buvid,
            uuid: uuid,
            ts: _nowMs,
            userAgent: userAgent,
            csrf: csrf,
          ),
        ),
      );
      // 每次按服务器给的时间戳排下一次：返回的时间戳正好是上一次的加上间隔，
      // 以本机收到 E 的时刻为起点，本机的钟不准也不影响
      var startMs = _nowMs;
      var startEts = state.ets;
      while (!_closed) {
        var dueMs = startMs + (state.ets + state.interval - startEts) * 1000;
        var wait = dueMs - _nowMs;
        if (wait < -state.interval * 1000 || wait > 2 * state.interval * 1000) {
          // 电脑睡过一觉或钟被拨过：网页那边这时也断了，不再补发
          return;
        }
        await _wait(Duration(milliseconds: wait < 1000 ? 1000 : wait));
        if (_closed) {
          return;
        }
        state = state.next(
          await _send(
            BiliWatchHeart.beatUrl,
            BiliWatchHeart.beatParams(
              room: room,
              state: state,
              buvid: buvid,
              uuid: uuid,
              ts: _nowMs,
              userAgent: userAgent,
              csrf: csrf,
            ),
          ),
        );
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  void close() {
    _closed = true;
    _timer?.cancel();
    if (_sleep != null && !_sleep!.isCompleted) {
      _sleep!.complete();
    }
  }

  Future<void> _wait(Duration duration) {
    var sleep = Completer<void>();
    _sleep = sleep;
    _timer = Timer(duration, () {
      if (!sleep.isCompleted) {
        sleep.complete();
      }
    });
    return sleep.future;
  }

  /// POST，参数在地址里并做 WBI 签名（空格按 %20 算，见 [biliWbiSigned]），请求头同网页端
  Future<dynamic> _send(
    String url,
    Map<String, String> params, {
    String? body,
  }) async {
    var (imgKey, subKey) = await site.getWbiKeys();
    var query = biliWbiSigned(
      params,
      mixinKey: site.getMixinKey(imgKey + subKey),
      wts: _nowMs ~/ 1000,
    );
    var headers = await site.getHeader();
    var response = await HttpClient.instance.dio.post(
      url,
      queryParameters: query,
      data: body,
      options: Options(
        responseType: ResponseType.json,
        contentType: body == null ? null : Headers.formUrlEncodedContentType,
        headers: headers,
      ),
    );
    var result = response.data;
    return result is String ? json.decode(result) : result;
  }
}
