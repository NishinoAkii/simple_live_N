import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 读出包头：总长、头长、版本、操作、序号
List<int> _header(List<int> p) {
  int read(int offset, int len) {
    var v = 0;
    for (var i = 0; i < len; i++) {
      v = (v << 8) | p[offset + i];
    }
    return v;
  }

  return [read(0, 4), read(4, 2), read(6, 2), read(8, 4), read(12, 4)];
}

Map _codec(String name, int qn, List<int> accept, String base, List<String> hosts) => {
  "codec_name": name,
  "current_qn": qn,
  "accept_qn": accept,
  "base_url": base,
  "url_info": [
    for (var h in hosts) {"host": h, "extra": "?sign=1"},
  ],
};

Map _playData() => {
  "room_id": 1000,
  "playurl_info": {
    "playurl": {
      "g_qn_desc": [
        {"qn": 10000, "desc": "原画"},
        {"qn": 400, "desc": "蓝光"},
        {"qn": 150, "desc": "高清"},
      ],
      "stream": [
        {
          "protocol_name": "http_stream",
          "format": [
            {
              "format_name": "flv",
              "codec": [
                _codec("avc", 10000, [10000, 400, 150], "/live/a.flv", [
                  "https://x.mcdn.bilivideo.cn",
                  "https://cn-gotcha.bilivideo.com",
                ]),
              ],
            },
          ],
        },
        {
          "protocol_name": "http_hls",
          "format": [
            {
              "format_name": "ts",
              "codec": [
                _codec("avc", 10000, [10000, 400, 150], "/live/a.m3u8", ["https://ts.host"]),
              ],
            },
            {
              "format_name": "fmp4",
              "codec": [
                _codec("hevc", 10000, [10000, 400], "/live/h.m3u8", ["https://hevc.host"]),
                _codec("avc", 10000, [10000, 400, 150], "/live/f.m3u8", ["https://fmp4.host"]),
              ],
            },
          ],
        },
      ],
    },
  },
};

void main() {
  group('danmaku packets like the web page', () {
    var args = BiliBiliDanmakuArgs(
      roomId: 1000,
      uid: 42,
      token: "tok",
      serverHost: "zj-cn-live-comet.chat.bilibili.com",
      buvid: "B3",
      cookie: "",
    );

    test('auth packet: web fields in the web order', () {
      var body = biliAuthBody(args, "g0myt1hu");
      expect(
        body,
        '{"uid":42,"roomid":1000,"protover":3,"buvid":"B3","support_ack":true,'
        '"queue_uuid":"g0myt1hu","scene":"room","platform":"web","type":2,"key":"tok"}',
      );
    });

    test('queue_uuid is 8 lowercase letters or digits', () {
      for (var i = 0; i < 50; i++) {
        expect(biliQueueUuid(Random(i)), matches(RegExp(r"^[0-9a-z]{8}$")));
      }
    });

    test('packet header: version 1, sequence 1; heartbeat body is [object Object]', () {
      var d = BiliBiliDanmaku();
      var heartbeat = d.encodeData("[object Object]", 2);
      expect(_header(heartbeat), [31, 16, 1, 2, 1]);
      expect(utf8.decode(heartbeat.sublist(16)), "[object Object]");
      expect(d.heartbeatTime, 30 * 1000);
      expect(_header(d.encodeData(biliAuthBody(args, "abcdefgh"), 7))[3], 7);
    });

    test('ack body only for p_is_ack messages', () {
      expect(biliAckBody({"cmd": "DANMU_MSG"}), isNull);
      expect(biliAckBody({"cmd": "SUPER_CHAT_MESSAGE", "p_is_ack": false}), isNull);
      expect(
        jsonDecode(biliAckBody({
          "cmd": "SUPER_CHAT_MESSAGE",
          "msg_id": "123:456",
          "p_is_ack": true,
          "p_msg_type": 1,
          "data": {},
        })!),
        {"msg_id": "123:456", "cmd": "SUPER_CHAT_MESSAGE", "p_msg_type": 1},
      );
    });
  });

  group('room page and play info', () {
    test('room page: reads roomInfoRes and roomInitRes', () {
      var state = {
        "roomInitRes": {"code": 0, "data": _playData()},
        "roomInfoRes": {
          "code": 0,
          "data": {
            "room_info": {"room_id": 1000, "title": "t"},
            "anchor_info": {"base_info": {"uname": "u"}},
          },
        },
      };
      var html =
          '<html><head></head><body><script>window.__NEPTUNE_IS_MY_WAIFU__='
          '${jsonEncode(state)};</script><script>var x=1</script></body></html>';
      var page = parseBiliRoomPage(html)!;
      expect(page.info["room_info"]["room_id"], 1000);
      expect(page.play?["room_id"], 1000);
    });

    test('room page: missing or broken data gives null', () {
      expect(parseBiliRoomPage("<html></html>"), isNull);
      expect(
        parseBiliRoomPage('<script>window.__NEPTUNE_IS_MY_WAIFU__={"a":</script>'),
        isNull,
      );
      expect(
        parseBiliRoomPage(
          '<script>window.__NEPTUNE_IS_MY_WAIFU__={"roomInfoRes":{"code":-352}}</script>',
        ),
        isNull,
      );
      // 没开播：房间信息有，播放信息没有
      var offline = parseBiliRoomPage(
        '<script>window.__NEPTUNE_IS_MY_WAIFU__={"roomInfoRes":{"code":0,"data":'
        '{"room_info":{"room_id":5}}},"roomInitRes":{"code":0,"data":{"playurl_info":null}}}</script>',
      )!;
      expect(offline.play, isNull);
    });

    test('qualities come from the first H.264 codec', () {
      var q = parseBiliQualities(_playData());
      expect(q.map((e) => e.data), [10000, 400, 150]);
      expect(q.map((e) => e.quality), ["原画", "蓝光", "高清"]);
      expect(parseBiliQualities(const {}), isEmpty);
    });

    test('play urls: FLV and fMP4 H.264 only, mcdn last', () {
      expect(parseBiliPlayUrls(_playData()), [
        "https://cn-gotcha.bilivideo.com/live/a.flv?sign=1",
        "https://fmp4.host/live/f.m3u8?sign=1",
        "https://x.mcdn.bilivideo.cn/live/a.flv?sign=1",
      ]);
      expect(parseBiliLiveHlsUrls(_playData()), [
        "https://fmp4.host/live/f.m3u8?sign=1",
        "https://ts.host/live/a.m3u8?sign=1",
      ]);
    });

    test('cached play info is used only for its own quality', () {
      expect(biliPlayInfoHasQn(_playData(), 10000), isTrue);
      expect(biliPlayInfoHasQn(_playData(), 400), isFalse);
    });
  });

  test('danmaku uid comes from the cookie account', () {
    var site = BiliBiliSite()
      ..cookie = "SESSDATA=s; bili_jct=c; DedeUserID=123; DedeUserID__ckMd5=ab";
    expect(site.cookieUid, 123);
    site.cookie = "SESSDATA=s; DedeUserID__ckMd5=ab";
    expect(site.cookieUid, 0);
    site.cookie = "DedeUserID=77";
    expect(site.cookieUid, 77);
  });
}
