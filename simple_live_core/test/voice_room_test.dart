import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/bilibili_voice_room.dart';
import 'package:test/test.dart';

/// 哔哩哔哩语聊房：房间信息里的 multi_voice（真的聊天室里抓的，名字等换成了假的）
Map<String, dynamic> fixture() => jsonDecode(
  File("test/fixtures/bili_voice_room.json").readAsStringSync(),
);

void main() {
  test("房主和麦位：按麦位号排，闭麦、魅力值、PK 的队都读到", () {
    var room = BiliVoiceRoom.fromRoomInfo(fixture())!;
    expect(room.seats.map((e) => e.position), [0, 1, 2, 3, 7, 8]);
    expect(room.host!.name, "房主甲");
    expect(room.host!.position, 0);
    expect(room.host!.muted, isTrue);
    expect(room.host!.score, "1455");
    expect(room.seatAt(1)!.name, "嘉宾乙");
    expect(room.seatAt(1)!.host, isFalse);
    expect(room.seatAt(1)!.team, "1");
    expect(room.seatAt(7)!.muted, isTrue);
    expect(room.seatAt(4), isNull);
    expect(room.guestSeats, 8);
    expect(room.teams.map((e) => "${e.id}:${e.score}"), ["1:92", "2:321"]);
    // http 的背景图换成 https，Windows 上不让明文请求
    expect(room.background, startsWith("https://i0.hdslb.com/"));
  });

  test("不是语聊房、没开、没人时为 null", () {
    var data = fixture();
    expect(BiliVoiceRoom.fromRoomInfo({"room_info": data["room_info"]}), isNull);
    data["multi_voice"]["switch_status"] = 0;
    expect(BiliVoiceRoom.fromRoomInfo(data), isNull);
    data = fixture();
    data["multi_voice"]["members"] = [];
    expect(BiliVoiceRoom.fromRoomInfo(data), isNull);
    expect(BiliVoiceRoom.fromRoomInfo(null), isNull);
  });

  test("麦位号超过 8 时嘉宾麦跟着变多", () {
    var data = fixture();
    (data["multi_voice"]["members"] as List).add({
      "uid": 9,
      "nickname": "嘉宾庚",
      "avatar": "",
      "role": 0,
      "pos": 10,
      "is_mute": 0,
      "price_text": "",
    });
    expect(BiliVoiceRoom.fromRoomInfo(data)!.guestSeats, 10);
  });

  test("同一份数据相等，换了人不相等", () {
    var a = BiliVoiceRoom.fromRoomInfo(fixture())!;
    var b = BiliVoiceRoom.fromRoomInfo(fixture())!;
    expect(a, b);
    var data = fixture();
    data["multi_voice"]["members"][1]["is_mute"] = 1;
    expect(BiliVoiceRoom.fromRoomInfo(data), isNot(a));
    expect(a.toMessage().type, LiveMessageType.voiceRoom);
  });

  test("弹幕连接里的语音转文字（UNIVERSAL_ASR_TEXT）", () {
    var out = <LiveMessage>[];
    var danmaku = BiliBiliDanmaku()..onMessage = out.add;
    danmaku.parseMessage(
      jsonEncode({
        "cmd": "UNIVERSAL_ASR_TEXT",
        "data": {
          "channel_id": 1,
          "uid": 1001,
          "uname": "嘉宾乙",
          "sentences": [
            {"start_time": 1, "end_time": 2, "text": "能不能给我一个", "is_append": false},
          ],
        },
      }),
    );
    // 没有文字的不发
    danmaku.parseMessage(
      jsonEncode({
        "cmd": "UNIVERSAL_ASR_TEXT",
        "data": {"uid": 1001, "uname": "嘉宾乙", "sentences": []},
      }),
    );
    expect(out.length, 1);
    expect(out.single.type, LiveMessageType.voiceCaption);
    var caption = out.single.data as LiveVoiceCaption;
    expect(caption.uid, "1001");
    expect(caption.name, "嘉宾乙");
    expect(caption.text, "能不能给我一个");
  });
}
