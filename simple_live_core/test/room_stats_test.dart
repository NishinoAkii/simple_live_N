import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/bilibili_room_stats.dart';
import 'package:simple_live_core/src/danmaku/proto/douyin.pb.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:test/test.dart';

/// 直播间的热度、在线人数、贵宾数、看过、点赞：各平台弹幕连接里推送的那几条消息。
/// 斗鱼、虎牙、抖音的数据是 2026-11-13 在真的直播间里抓到的；
/// 哔哩哔哩是照着它的消息格式写的

/// 收到的消息里和这几个数有关的两种
class Counts {
  final out = <LiveMessage>[];

  /// 热度（[LiveMessageType.online]）
  List<Object?> get online => [
    for (var m in out)
      if (m.type == LiveMessageType.online) m.data,
  ];

  List<LiveRoomStats> get stats => [
    for (var m in out)
      if (m.type == LiveMessageType.stats) m.data as LiveRoomStats,
  ];
}

Counts bili(void Function(BiliBiliDanmaku danmaku) feed) {
  var counts = Counts();
  feed(BiliBiliDanmaku()..onMessage = counts.out.add);
  return counts;
}

Counts biliMessages(List<Map> messages) => bili((danmaku) {
  for (var m in messages) {
    danmaku.parseMessage(json.encode(m));
  }
});

Counts douyu(List<String> lines) {
  var counts = Counts();
  var danmaku = DouyuDanmaku()
    ..roomId = "338281"
    ..onMessage = counts.out.add;
  for (var line in lines) {
    danmaku.decodeMessage(danmaku.serializeDouyu(line));
  }
  return counts;
}

/// 虎牙的一条推送（命令 7，WSPushMessage），msg 是只有几个整数的结构
List<int> huyaPush(int uri, Map<int, int> fields, {String group = ""}) {
  var msg = TarsOutputStream();
  fields.forEach((tag, value) => msg.write(value, tag));
  var push = TarsOutputStream();
  push.write(group.isEmpty ? 3 : 5, 0);
  push.write(uri, 1);
  push.write(msg.toUint8List(), 2);
  push.write(0, 3);
  if (group.isNotEmpty) {
    push.write(group, 4);
  }
  var cmd = TarsOutputStream();
  cmd.write(7, 0);
  cmd.write(push.toUint8List(), 1);
  return cmd.toUint8List();
}

Counts huya(List<List<int>> frames) {
  var counts = Counts();
  var danmaku = HuyaDanmaku()..onMessage = counts.out.add;
  for (var frame in frames) {
    danmaku.decodeMessage(frame);
  }
  return counts;
}

Counts douyin(List<Message> messages) {
  var counts = Counts();
  var response = Response()..messagesList.addAll(messages);
  var frame =
      (PushFrame()
            ..payloadType = "msg"
            ..payload = gzip.encode(response.writeToBuffer()))
          .writeToBuffer();
  (DouyinDanmaku()..onMessage = counts.out.add).decodeMessage(frame);
  return counts;
}

Message douyinMessage(String method, List<int> payload) => Message()
  ..method = method
  ..payload = payload;

void main() {
  group("LiveRoomStats", () {
    test("数字：整数、小数、数字字符串都认，其余算没给", () {
      expect(LiveRoomStats.count(198183), 198183);
      expect(LiveRoomStats.count(12.0), 12);
      expect(LiveRoomStats.count(" 213 "), 213);
      expect(LiveRoomStats.count(0), 0);
      expect(LiveRoomStats.count(-1), isNull);
      expect(LiveRoomStats.count("19.8万"), isNull);
      expect(LiveRoomStats.count(null), isNull);
      expect(LiveRoomStats.count({"num": 1}), isNull);
    });

    test("新收到的只盖掉带了的那几项", () {
      var stats = const LiveRoomStats(watched: 100, likes: 5)
          .merge(const LiveRoomStats(likes: 6))
          .merge(const LiveRoomStats(viewers: 30))
          .merge(const LiveRoomStats(nobles: 7))
          .merge(null);
      expect(
        stats,
        const LiveRoomStats(viewers: 30, nobles: 7, watched: 100, likes: 6),
      );
      expect(stats.isEmpty, isFalse);
      expect(const LiveRoomStats(nobles: 0).isEmpty, isFalse);
      expect(LiveRoomStats.none.isEmpty, isTrue);
      expect(LiveRoomStats.none.merge(LiveRoomStats.none).isEmpty, isTrue);
    });

    test("发给直播间的消息不带聊天内容", () {
      var message = const LiveRoomStats(watched: 1).toMessage();
      expect(message.type, LiveMessageType.stats);
      expect(message.message, "");
      expect(message.data, const LiveRoomStats(watched: 1));
    });
  });

  group("哔哩哔哩", () {
    test("长连接：房间观众数、看过、点赞", () {
      var counts = biliMessages([
        {
          "cmd": "ONLINE_RANK_COUNT",
          "data": {
            "count": 320,
            "count_text": "320",
            "online_count": 996,
            "online_count_text": "996",
          },
        },
        {
          "cmd": "WATCHED_CHANGE",
          "data": {
            "num": 7519,
            "text_small": "7519",
            "text_large": "7519人看过",
          },
        },
        {
          "cmd": "LIKE_INFO_V3_UPDATE",
          "data": {"click_count": 16213},
        },
      ]);
      expect(counts.stats, const [
        LiveRoomStats(viewers: 996),
        LiveRoomStats(watched: 7519),
        LiveRoomStats(likes: 16213),
      ]);
      expect(counts.out.length, 3);
    });

    test("早先的 ONLINE_RANK_COUNT 只有 count", () {
      expect(
        biliMessages([
          {
            "cmd": "ONLINE_RANK_COUNT",
            "data": {"count": 4},
          },
        ]).stats,
        const [LiveRoomStats(viewers: 4)],
      );
    });

    test("没带数字或格式不对的不发消息", () {
      expect(
        biliMessages([
          {"cmd": "WATCHED_CHANGE"},
          {"cmd": "WATCHED_CHANGE", "data": "x"},
          {
            "cmd": "WATCHED_CHANGE",
            "data": {"text_small": "1.2万"},
          },
          {
            "cmd": "LIKE_INFO_V3_UPDATE",
            "data": {"click_count": null},
          },
          {"cmd": "ONLINE_RANK_COUNT", "data": {}},
        ]).out,
        isEmpty,
      );
    });

    test("别的消息不当成直播间数据", () {
      expect(BiliRoomStats.handles("ONLINE_RANK_V2"), isFalse);
      expect(BiliRoomStats.handles("LIKE_INFO_V3_CLICK"), isFalse);
      expect(
        BiliRoomStats.fromMessage({
          "cmd": "ONLINE_RANK_V2",
          "data": {"count": 5, "num": 6, "click_count": 7},
        }),
        isNull,
      );
    });

    test("心跳回应里的人气值：停用后的 1 不发，真的数照发", () {
      List<int> heartbeat(BiliBiliDanmaku danmaku, int value) =>
          danmaku.encodeData(
            String.fromCharCodes(
              (ByteData(4)..setUint32(0, value)).buffer.asUint8List(),
            ),
            3,
          );
      var counts = bili((danmaku) {
        danmaku.decodeMessage(heartbeat(danmaku, 1));
        danmaku.decodeMessage(heartbeat(danmaku, 0));
        danmaku.decodeMessage(heartbeat(danmaku, 12345));
      });
      expect(counts.online, [12345]);
    });

    test("房间信息里的初值", () {
      expect(
        BiliRoomStats.fromRoomInfo({
          "room_info": {"room_id": 1, "online": 20000},
          "watched_show": {
            "switch": true,
            "num": 198183,
            "text_small": "19.8万",
            "text_large": "19.8万人看过",
          },
          "like_info_v3": {"total_likes": 16213, "count_block": false},
        }),
        const LiveRoomStats(watched: 198183, likes: 16213),
      );
    });

    test("主播关掉显示的那项不取；都没有时为 null", () {
      expect(
        BiliRoomStats.fromRoomInfo({
          "watched_show": {"switch": false, "num": 198183},
          "like_info_v3": {"total_likes": 16213, "count_block": true},
        }),
        isNull,
      );
      expect(
        BiliRoomStats.fromRoomInfo({
          "watched_show": {"switch": false, "num": 198183},
          "like_info_v3": {"total_likes": 5},
        }),
        const LiveRoomStats(likes: 5),
      );
      expect(BiliRoomStats.fromRoomInfo({"room_info": {}}), isNull);
      expect(BiliRoomStats.fromRoomInfo({"watched_show": "x"}), isNull);
      expect(BiliRoomStats.fromRoomInfo(null), isNull);
    });
  });

  group("斗鱼", () {
    test("oun 是在线人数，oni 是贵宾数（在 338281 抓到的原文）", () {
      var counts = douyu([
        "type@=oni/vn@=116/rid@=338281/list@=/un@=116/",
        "type@=oun/un@=213/rid@=338281/",
        "type@=oun/un@=214/rid@=338281/",
        "type@=oni/vn@=118/rid@=338281/list@=/un@=118/",
      ]);
      expect(counts.stats, const [
        LiveRoomStats(nobles: 116),
        LiveRoomStats(viewers: 213),
        LiveRoomStats(viewers: 214),
        LiveRoomStats(nobles: 118),
      ]);
      expect(counts.out.length, 4);
    });

    test("没带数字的不发消息", () {
      expect(
        douyu([
          "type@=oun/rid@=338281/",
          "type@=oun/un@=/rid@=338281/",
          "type@=oni/rid@=338281/list@=/",
        ]).out,
        isEmpty,
      );
    });
  });

  group("虎牙", () {
    test("6211 是贵宾数，8006 是人气（抓到的原文：{0: 主播 uid, 1: 7991, 2: 0}）", () {
      var counts = huya([
        huyaPush(6211, {0: 1199668582454, 1: 7991, 2: 0}, group: "chat:1"),
        huyaPush(8006, {0: 3330087}),
        huyaPush(6211, {0: 1199668582454, 1: 7979, 2: 0}, group: "chat:1"),
      ]);
      expect(counts.stats, const [
        LiveRoomStats(nobles: 7991),
        LiveRoomStats(nobles: 7979),
      ]);
      expect(counts.online, [3330087]);
    });

    test("没带人数的 6211 不发消息", () {
      expect(huya([huyaPush(6211, {0: 1199668582454})]).out, isEmpty);
    });
  });

  group("抖音", () {
    test("在线人数用 total，累计看过用 totalUser（抓到的一条）", () {
      var counts = douyin([
        douyinMessage(
          "WebcastRoomUserSeqMessage",
          (RoomUserSeqMessage()
                ..total = Int64(33039)
                ..totalStr = "3万+"
                ..totalUser = Int64(570304)
                ..totalUserStr = "10万+"
                ..onlineUserForAnchor = "3.3万"
                ..totalPvForAnchor = "57.0万")
              .writeToBuffer(),
        ),
      ]);
      expect(counts.online, [33039]);
      expect(counts.stats, const [LiveRoomStats(watched: 570304)]);
    });

    test("点赞用本场总数 total，不是这一条点了几下", () {
      var counts = douyin([
        douyinMessage(
          "WebcastLikeMessage",
          (LikeMessage()
                ..count = Int64(18)
                ..total = Int64(188093))
              .writeToBuffer(),
        ),
      ]);
      expect(counts.stats, const [LiveRoomStats(likes: 188093)]);
      expect(counts.online, isEmpty);
    });

    test("没带数的不发消息", () {
      var counts = douyin([
        douyinMessage(
          "WebcastRoomUserSeqMessage",
          RoomUserSeqMessage().writeToBuffer(),
        ),
        douyinMessage("WebcastLikeMessage", LikeMessage().writeToBuffer()),
      ]);
      expect(counts.out, isEmpty);
    });
  });
}
