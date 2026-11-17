import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/douyu_emotes_table.dart';
import 'package:test/test.dart';

/// 实测的 dfans/emojis 返回（182102，已精简）
dynamic dfans() => json.decode(
  File('test/fixtures/emotes/douyu_dfans_182102.json').readAsStringSync(),
);

/// 实抓的 chatmsg（74751）。表情样本那条没有 dms（是机器人弹幕），
/// 这里换成同一房间一条正常弹幕的字段
const _realChat =
    "type@=chatmsg/rid@=74751/ct@=2/uid@=148690008/nn@=六月是你的幸福/"
    "txt@=茶茶丸是妹妹/cid@=9b87e28e0e264eefd404000000000000/"
    "ic@=avanew@Sface@S201707@S09@S00@S1c5afe8f55200a42fdaeb7bb9f23aea7/"
    "level@=10/sahf@=0/cst@=1793172844805/bnn@=耀西/bl@=8/brid@=74751/"
    "hc@=e782738ead01e0978d3f351801f920f2/lk@=/fl@=8/dms@=4/pdg@=31/pdk@=96/"
    "ext@=/if@=1/";

/// 没有 dms 的机器人弹幕（实抓，唯一一条带表情的样本）
const _botChat =
    "type@=chatmsg/rid@=74751/uid@=358008435/nn@=1年少莫轻狂/txt@=主播666666[奈斯]/"
    "cid@=896d7cef37824cbc02f0800a00000000/"
    "ic@=avatar_v3@S202102@S9eb2b7219b14489c84a5dc5a3560dc6b/level@=14/sahf@=0/"
    "cst@=1793172915398/bnn@=/bl@=0/brid@=0/hc@=/lk@=/pdg@=8/pdk@=21/ext@=/";

void main() {
  group('内置表情', () {
    test('生成的表', () {
      expect(kDouyuEmotes, hasLength(265));
      expect(kDouyuLegacyEmotes, hasLength(78));
      expect(kDouyuLegacyEmotes.keys.first, "dy001");
    });

    test('“[名称]”', () {
      var emotes = parseDouyuEmotes("主播666666[奈斯]")!;
      expect(emotes.single.text, "[奈斯]");
      expect(
        emotes.single.url,
        startsWith(
          "https://shark2.douyucdn.cn/front-publish/"
          "live-next-player-aside-master/assets/images/naisi_",
        ),
      );
      expect([emotes.single.width, emotes.single.height], [1, 1]);
      expect(parseDouyuEmotes("普通弹幕"), isNull);
    });

    test('旧版“[emot:dyNNN]”，不认识的不算', () {
      var emotes = parseDouyuEmotes("[emot:dy101]好[不存在][emot:dy999]")!;
      expect(emotes.single.text, "[emot:dy101]");
      expect(emotes.single.url, contains("/dy101_"));
      var parts = splitLiveEmotes("[emot:dy101]好[不存在]", emotes);
      expect(parts.map((e) => e.text), ["[emot:dy101]", "好[不存在]"]);
    });

    test('同名时用前面的组：[666] 是 douyu 组的，不是 dy101', () {
      var emote = parseDouyuEmotes("[666][666]")!.single;
      expect(emote.url, contains("/liuliuliu_"));
    });
  });

  group('房间表情', () {
    var room = parseDouyuRoomEmojiList(dfans());

    test('钻粉表情和热门梗', () {
      expect(room.keys, ["[大舅哥1]", "[大舅哥2]", "[梗已老实]", "[梗亲亲]"]);
      expect(room["[大舅哥1]"]!.url, startsWith("https://sta-op.douyucdn.cn/"));
      expect([room["[梗已老实]"]!.width, room["[梗已老实]"]!.height], [200, 200]);
      // 开关关掉时不用
      var off = Map<String, dynamic>.from(dfans()["data"])..["allSwitch"] = 0;
      expect(parseDouyuRoomEmojiList(off).keys, ["[梗已老实]", "[梗亲亲]"]);
      expect(parseDouyuRoomEmojiList({"error": 0, "data": null}), isEmpty);
    });

    test('消息里的房间表情，整条是热门梗时是大表情', () {
      var emotes = parseDouyuEmotes("[大舅哥1]哈哈[奈斯]", room: room)!;
      expect(emotes.map((e) => e.text), ["[大舅哥1]", "[奈斯]"]);
      expect(douyuEmoteSticker("[大舅哥1]", room), isNull);
      var sticker = douyuEmoteSticker("[梗已老实]", room)!;
      expect(sticker.text, "[梗已老实]");
      expect([sticker.width, sticker.height], [200, 200]);
      expect(douyuEmoteSticker("好[梗已老实]", room), isNull);
      // 旧版写法也能指房间表情
      expect(
        parseDouyuEmotes("[emot:dy大舅哥2]", room: room)!.single.url,
        room["[大舅哥2]"]!.url,
      );
    });
  });

  group('弹幕', () {
    setUp(DouyuRoomEmotes.debugReset);
    tearDown(DouyuRoomEmotes.debugReset);

    List<LiveMessage> decode(List<String> raws) {
      var danmaku = DouyuDanmaku()..roomId = "74751";
      var messages = <LiveMessage>[];
      danmaku.onMessage = messages.add;
      for (var raw in raws) {
        danmaku.decodeMessage(danmaku.serializeDouyu(raw));
      }
      return messages;
    }

    test('正常弹幕带表情，没有 dms 的机器人弹幕照旧屏蔽', () {
      DouyuRoomEmotes.debugSet("74751", parseDouyuRoomEmojiList(dfans()));
      var messages = decode([
        _realChat.replaceFirst("txt@=茶茶丸是妹妹", "txt@=茶茶丸是妹妹[奈斯][大舅哥1]"),
        _realChat.replaceFirst("txt@=茶茶丸是妹妹", "txt@=[梗已老实]"),
        _botChat,
      ]);
      expect(messages, hasLength(2));
      expect(messages.first.userName, "六月是你的幸福");
      expect(messages.first.emotes!.map((e) => e.text), ["[奈斯]", "[大舅哥1]"]);
      expect(messages.last.sticker!.height, 200);
      expect(messages.last.emotes, isNull);
    });

    test('房间表情没读到时只有内置表情', () {
      var messages = decode([
        _realChat.replaceFirst("txt@=茶茶丸是妹妹", "txt@=[梗已老实][奈斯]"),
      ]);
      expect(messages.single.emotes!.single.text, "[奈斯]");
      expect(messages.single.sticker, isNull);
    });

    test('房间表情每个房间读一次，失败后不马上重试', () async {
      var calls = <String>[];
      DouyuRoomEmotes.debugFetch = (rid) async {
        calls.add(rid);
        if (rid == "1") {
          throw StateError("network");
        }
        return json.encode(dfans());
      };
      await DouyuRoomEmotes.load("182102");
      await DouyuRoomEmotes.load("182102");
      await DouyuRoomEmotes.load("1");
      await DouyuRoomEmotes.load("1");
      expect(calls, ["182102", "1"]);
      expect(DouyuRoomEmotes.of("182102")!.keys, contains("[大舅哥1]"));
      expect(DouyuRoomEmotes.of("1"), isNull);
    });
  });
}
