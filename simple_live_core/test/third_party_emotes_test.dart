import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 实测的接口返回（已精简），见 test/fixtures/emotes
dynamic fixture(String name) =>
    json.decode(File('test/fixtures/emotes/$name').readAsStringSync());

/// 实抓的 IRC 消息（xqc 频道，匿名 justinfan）
const _ircEmoteOnly =
    "@badge-info=;badges=moments/1;client-nonce=tn75i7mi11;color=#0000FF;"
    "display-name=mokoto05;emote-only=1;emotes=425618:0-2,4-6;first-msg=0;"
    "flags=;id=3680185a-6a8b-4ae7-b144-540045922e5c;mod=0;returning-chatter=0;"
    "room-id=71092938;subscriber=0;tmi-sent-ts=1793173013032;turbo=0;"
    "user-id=121919606;user-type= "
    ":mokoto05!mokoto05@mokoto05.tmi.twitch.tv PRIVMSG #xqc :LUL LUL";
const _ircSevenTv =
    "@badge-info=subscriber/84;badges=subscriber/84,pichu/1;"
    "client-nonce=3d4c7675699541f78e475169f438fec0;color=#FF0000;"
    "display-name=Kubz1;emotes=;first-msg=0;flags=;"
    "id=e27e17ca-523f-40b7-9ae5-c6594e2c6367;mod=0;returning-chatter=0;"
    "room-id=71092938;subscriber=1;tmi-sent-ts=1793173010877;turbo=0;"
    "user-id=55540150;user-type= "
    ":kubz1!kubz1@kubz1.tmi.twitch.tv PRIVMSG #xqc :omeDamn";

void main() {
  group('7TV', () {
    var table = parseSevenTvEmoteSet(fixture("7tv_user_twitch_xqc.json"));

    test('用频道里的别名，2x.webp，宽高用 1x 的', () {
      // reeferSad 的原名是 TriSad
      expect(table.containsKey("TriSad"), isFalse);
      var emote = table["reeferSad"]!;
      expect(emote.text, "reeferSad");
      expect(
        emote.url,
        "https://cdn.7tv.app/emote/01EZPGQES8000C438200A44F0M/2x.webp",
      );
      expect(
        emote.staticUrl,
        "https://cdn.7tv.app/emote/01EZPGQES8000C438200A44F0M/2x_static.webp",
      );
      expect([emote.width, emote.height], [32, 32]);
      expect(emote.spaced, isTrue);
      // 宽表情按 1x 的比例
      expect([table["GAMBA"]!.width, table["GAMBA"]!.height], [39, 32]);
      expect(table.values.every((e) => e.height < 36), isTrue);
    });

    test('不用 avif，静态表情没有 staticUrl', () {
      expect(table.values.any((e) => e.url.endsWith(".avif")), isFalse);
      expect(table["D:"]!.url, endsWith("/2x.webp"));
      expect(table["D:"]!.staticUrl, isNull);
      expect(table["???"]!.staticUrl, isNull);
    });

    test('零宽表情跳过', () {
      expect(table.containsKey("notL"), isFalse);
      var global = parseSevenTvEmoteSet(fixture("7tv_global.json"));
      expect(global.containsKey("PETPET"), isFalse);
      expect(global.keys, containsAll(["FeelsDankMan", "Clap"]));
    });

    test('emote-set 对象和用户返回都能解析，没有 webp 时退回 png/gif', () {
      var set = parseSevenTvEmoteSet({
        "id": "s",
        "emotes": [
          {
            "id": "1",
            "name": "a",
            "flags": 0,
            "data": {
              "flags": 0,
              "animated": false,
              "host": {
                "url": "//cdn.7tv.app/emote/1",
                "files": [
                  {"name": "1x.avif", "width": 32, "height": 32},
                  {"name": "2x.png", "width": 64, "height": 64},
                ],
              },
            },
          },
          {
            "id": "2",
            "name": "only avif",
            "data": {
              "host": {
                "url": "//cdn.7tv.app/emote/2",
                "files": [
                  {"name": "2x.avif"},
                ],
              },
            },
          },
          {
            "id": "3",
            "name": "b",
            "data": {
              "host": {
                "url": "//cdn.7tv.app/emote/3",
                "files": [
                  {"name": "2x.avif"},
                ],
              },
            },
          },
        ],
      });
      expect(set.keys, ["a"]);
      expect(set["a"]!.url, "https://cdn.7tv.app/emote/1/2x.png");
      // 没有 1x.png 时按 2x 的一半，不会被当成大表情
      expect([set["a"]!.width, set["a"]!.height], [32, 32]);
      expect(parseSevenTvEmoteSet(null), isEmpty);
      expect(parseSevenTvEmoteSet({"error": "user not found"}), isEmpty);
    });
  });

  group('BTTV', () {
    test('全局：修饰符跳过，标点名字保留', () {
      var table = parseBttvEmotes(fixture("bttv_global.json"));
      expect(table.containsKey("h!"), isFalse);
      expect(table.containsKey("w!"), isFalse);
      expect(table.keys, containsAll([":tf:", "D:", "monkaS"]));
      expect(
        table[":tf:"]!.url,
        "https://cdn.betterttv.net/emote/54fa8f1401e468494b85b537/2x.webp",
      );
      // 有宽高时用它，没有时按正方形
      expect(
        [table["FeelsBirthdayMan"]!.width, table["FeelsBirthdayMan"]!.height],
        [19, 28],
      );
      expect([table["monkaS"]!.width, table["monkaS"]!.height], [1, 1]);
    });

    test('频道：只有动图才有 staticUrl', () {
      var table = parseBttvEmotes(fixture("bttv_user_forsen.json"));
      expect(table.keys, [
        "forsenBlunder",
        "YESIDOTHINKSOr",
        "RareParrot",
        "RebeccaBlack",
      ]);
      expect(
        table["YESIDOTHINKSOr"]!.staticUrl,
        "https://cdn.betterttv.net/emote/6027ea208fbb823604bde323/static/2x.webp",
      );
      expect(table["forsenBlunder"]!.staticUrl, isNull);
      // 零宽表情跳过
      expect(
        parseBttvEmotes([
          {"id": "1", "code": "cvMask", "imageType": "png"},
        ]),
        isEmpty,
      );
      expect(parseBttvEmotes({"message": "user not found"}), isEmpty);
    });
  });

  group('FFZ', () {
    test('BTTV 缓存的格式', () {
      var table = parseFfzEmotes(fixture("bttv_ffz_user_xqc.json"));
      expect(
        table["WideHard"]!.url,
        "https://cdn.betterttv.net/frankerfacez_emote/246878/2",
      );
      expect(table["WideHard"]!.staticUrl, isNull);
      var global = parseFfzEmotes(fixture("bttv_ffz_global.json"));
      expect(global.keys, ["ZrehplaR", "YooHoo"]);
      expect(parseFfzEmotes(<dynamic>[]), isEmpty);
      var animated = parseFfzEmotes([
        {
          "code": "a",
          "images": {
            "2x": "https://cdn.betterttv.net/frankerfacez_emote/1/animated/2",
          },
          "animated": true,
        },
      ]);
      expect(
        animated["a"]!.staticUrl,
        "https://cdn.betterttv.net/frankerfacez_emote/1/2",
      );
    });

    test('官方格式：全局只用 default_sets，房间用 room.set', () {
      var global = parseFfzEmotes(fixture("ffz_global.json"));
      // 1532818 不在 default_sets 里；修饰符跳过
      expect(global.keys, ["ZrehplaR", "YooHoo"]);
      expect([global["ZrehplaR"]!.width, global["ZrehplaR"]!.height], [33, 30]);
      expect(global["ZrehplaR"]!.url, "https://cdn.frankerfacez.com/emote/9/2");
      var room = parseFfzEmotes(fixture("ffz_room_xqc.json"));
      expect(room["WideHard"]!.width, 50);
    });
  });

  group('按词匹配', () {
    var table = {
      ...parseSevenTvEmoteSet(fixture("7tv_user_twitch_xqc.json")),
      ...parseBttvEmotes(fixture("bttv_user_forsen.json")),
      "LUL": const LiveEmote(
        text: "LUL",
        url: "https://cdn.7tv.app/emote/lul/2x.webp",
        spaced: true,
      ),
    };

    test('只有完整的词算', () {
      var emotes = matchWordEmotes(
        "LUL LULW forsenBlunder what??? ??? D: xD:",
        table,
      )!;
      expect(emotes.map((e) => e.text), ["LUL", "forsenBlunder", "???", "D:"]);
      var parts = splitLiveEmotes(
        "LUL LULW forsenBlunder what??? ??? D: xD:",
        emotes,
      );
      expect(parts.where((e) => e.isEmote).map((e) => e.text), [
        "LUL",
        "forsenBlunder",
        "???",
        "D:",
      ]);
      expect(matchWordEmotes("没有表情", table), isNull);
      expect(matchWordEmotes("LUL", null), isNull);
    });

    test('和原生表情合并时原生的优先', () {
      var native = TwitchDanmaku.parseTwitchEmotes("425618:0-2,4-6", "LUL LUL");
      var emotes = matchWordEmotes("LUL LUL omeDamn", table, native: native)!;
      expect(emotes.map((e) => e.text), ["LUL", "omeDamn"]);
      expect(emotes.first.url, contains("static-cdn.jtvnw.net"));
      var parts = splitLiveEmotes("LUL LUL omeDamn", emotes);
      expect(
        parts.where((e) => e.isEmote).map((e) => e.emote!.url).first,
        contains("static-cdn.jtvnw.net"),
      );
      // 没有第三方表情时照常返回原生表情
      expect(matchWordEmotes("LUL", const {}, native: native), same(native));
    });

    test('消息末尾的不可见字符不影响', () {
      var emotes = matchWordEmotes("omeDamn \u{E0000}", table)!;
      expect(emotes.single.text, "omeDamn");
      emotes = matchWordEmotes("omeDamn͏", table)!;
      expect(splitLiveEmotes("omeDamn͏", emotes).first.text, "omeDamn");
    });
  });

  group('Twitch 聊天', () {
    setUp(ThirdPartyEmotes.debugReset);
    tearDown(ThirdPartyEmotes.debugReset);

    test('IRC 消息里的 7TV 表情', () {
      ThirdPartyEmotes.debugSet(
        twitchChannels: {
          "71092938": parseSevenTvEmoteSet(fixture("7tv_user_twitch_xqc.json")),
        },
      );
      var msg = TwitchDanmaku.privmsgToMessage(
        TwitchIrcLine.parse(_ircSevenTv),
        ThirdPartyEmotes.twitch("71092938"),
      );
      expect(msg.userName, "Kubz1");
      expect(msg.message, "omeDamn");
      expect(msg.emotes!.single.url, endsWith("/2x.webp"));
      expect(msg.sticker, isNull);
      // 频道表还没读到时只有全局表情
      var plain = TwitchDanmaku.privmsgToMessage(
        TwitchIrcLine.parse(_ircSevenTv),
        ThirdPartyEmotes.twitch(""),
      );
      expect(plain.emotes, isNull);
    });

    test('只有原生表情的消息', () {
      var line = TwitchIrcLine.parse(_ircEmoteOnly);
      var msg = TwitchDanmaku.privmsgToMessage(line, const {});
      // 两个 LUL 不是一张大表情
      expect(msg.sticker, isNull);
      expect(msg.emotes!.single.text, "LUL");

      var single = TwitchDanmaku.privmsgToMessage(
        TwitchIrcLine.parse(
          _ircEmoteOnly
              .replaceFirst("425618:0-2,4-6", "425618:0-2")
              .replaceFirst(":LUL LUL", ":LUL"),
        ),
        const {},
      );
      expect(single.sticker!.text, "LUL");
      expect(single.sticker!.url, contains("/425618/default/"));
      expect(single.emotes, isNull);
    });

    test('频道 id 默认为空', () {
      expect(TwitchDanmakuArgs(channel: "xqc").userId, "");
    });
  });

  group('Kick', () {
    test('7TV 按 user_id 查，不是 channel id', () {
      expect(
        kickChannelUserId({
          "id": 668,
          "user_id": 676,
          "slug": "xqc",
          "chatroom": {"id": 668},
        }),
        676,
      );
      expect(
        kickChannelUserId({
          "id": 1,
          "user": {"id": 2},
        }),
        2,
      );
      expect(kickChannelUserId(null), 0);
      expect(KickDanmakuArgs(chatroomId: 1, channelId: 1, slug: "a").userId, 0);
    });

    test('Kick 表情和 7TV 表情一起认', () {
      // 实测 users/kick/676 和 Twitch 的 xqc 是同一套表情
      var table = parseSevenTvEmoteSet(fixture("7tv_user_twitch_xqc.json"));
      const content = "GAMBA [emote:1153261:xqcLK] what??? D:";
      var emotes = KickDanmaku.matchKickEmotes(content, table)!;
      expect(emotes.map((e) => e.text), ["xqcLK", "GAMBA", "D:"]);
      expect(
        emotes.first.url,
        "https://files.kick.com/emotes/1153261/fullsize",
      );
      var text = KickDanmaku.replaceEmotes(content);
      expect(
        splitLiveEmotes(
          text,
          emotes,
        ).where((e) => e.isEmote).map((e) => e.text),
        ["GAMBA", "xqcLK", "D:"],
      );
      // 没有 7TV 表时和原来一样
      expect(KickDanmaku.matchKickEmotes(content, null)!.single.text, "xqcLK");
      expect(KickDanmaku.matchKickEmotes("hello", const {}), isNull);
    });
  });

  group('表的缓存', () {
    late List<String> requests;
    late Map<String, dynamic> responses;
    setUp(() {
      ThirdPartyEmotes.debugReset();
      requests = [];
      responses = {};
      ThirdPartyEmotes.debugGetJson = (url) async {
        requests.add(url);
        var result = responses[url];
        if (result == null) {
          throw CoreError("not found", statusCode: 404);
        }
        if (result is Error) {
          throw result;
        }
        return result;
      };
    });
    tearDown(ThirdPartyEmotes.debugReset);

    const api7tv = ThirdPartyEmotes.kSevenTvApi;
    const apiBttv = ThirdPartyEmotes.kBttvApi;

    test('全局表每次运行只读一次，频道表重连时不重新读', () async {
      responses["$api7tv/emote-sets/global"] = fixture("7tv_global.json");
      responses["$apiBttv/emotes/global"] = fixture("bttv_global.json");
      responses["$apiBttv/frankerfacez/emotes/global"] = fixture(
        "bttv_ffz_global.json",
      );
      responses["$api7tv/users/twitch/71092938"] = fixture(
        "7tv_user_twitch_xqc.json",
      );
      responses["$apiBttv/frankerfacez/users/twitch/71092938"] = fixture(
        "bttv_ffz_user_xqc.json",
      );
      await ThirdPartyEmotes.loadGlobal();
      await ThirdPartyEmotes.loadTwitchChannel("71092938");
      expect(requests, hasLength(6));
      // 重连、重新进入直播间
      await ThirdPartyEmotes.loadGlobal();
      await ThirdPartyEmotes.loadTwitchChannel("71092938");
      expect(requests, hasLength(6));

      var table = ThirdPartyEmotes.twitch("71092938");
      // BTTV 频道是 404：当作没有表情
      expect(
        table.keys,
        containsAll(["reeferSad", "WideHard", ":tf:", "Clap"]),
      );
      expect(identical(table, ThirdPartyEmotes.twitch("71092938")), isTrue);
      // Kick 只用 7TV 的全局表
      expect(ThirdPartyEmotes.kick(676).containsKey(":tf:"), isFalse);
      expect(ThirdPartyEmotes.kick(676).containsKey("Clap"), isTrue);
    });

    test('重名时频道表优先，7TV 优先于 BTTV', () {
      const global7tv = LiveEmote(
        text: "D:",
        url: "https://7tv/g",
        spaced: true,
      );
      const globalBttv = LiveEmote(
        text: "D:",
        url: "https://bttv/g",
        spaced: true,
      );
      const channel = LiveEmote(text: "D:", url: "https://7tv/c", spaced: true);
      ThirdPartyEmotes.debugSet(
        bttvGlobal: {"D:": globalBttv},
        sevenTvGlobal: {"D:": global7tv},
      );
      expect(ThirdPartyEmotes.twitch("1")["D:"]!.url, "https://7tv/g");
      ThirdPartyEmotes.debugSet(
        twitchChannels: {
          "1": {"D:": channel},
        },
      );
      expect(ThirdPartyEmotes.twitch("1")["D:"]!.url, "https://7tv/c");
      expect(ThirdPartyEmotes.twitch("2")["D:"]!.url, "https://7tv/g");
    });

    test('失败后 10 分钟内不再请求', () async {
      responses["$api7tv/users/kick/676"] = CoreError("发送GET请求失败");
      await ThirdPartyEmotes.loadKickChannel(676);
      await ThirdPartyEmotes.loadKickChannel(676);
      expect(
        requests.where((e) => e == "$api7tv/users/kick/676"),
        hasLength(1),
      );
      expect(ThirdPartyEmotes.kick(676), isEmpty);
    });

    test('频道太多时清掉最久没用的', () async {
      for (var i = 1; i <= ThirdPartyEmotes.kMaxChannels + 3; i++) {
        responses["$api7tv/users/kick/$i"] = {
          "emote_set": {
            "emotes": [
              {
                "id": "$i",
                "name": "e$i",
                "data": {
                  "host": {
                    "url": "//cdn.7tv.app/emote/$i",
                    "files": [
                      {"name": "2x.webp", "width": 64, "height": 64},
                    ],
                  },
                },
              },
            ],
          },
        };
        await ThirdPartyEmotes.loadKickChannel(i);
      }
      expect(ThirdPartyEmotes.debugChannelCount, ThirdPartyEmotes.kMaxChannels);
      // 最早的没了，最新的还在
      expect(ThirdPartyEmotes.kick(1).containsKey("e1"), isFalse);
      var last = ThirdPartyEmotes.kMaxChannels + 3;
      expect(ThirdPartyEmotes.kick(last).containsKey("e$last"), isTrue);
    });
  });
}
