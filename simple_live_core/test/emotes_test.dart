import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/youtube_chat_parser.dart';
import 'package:simple_live_core/src/common/youtube_parser.dart';
import 'package:test/test.dart';

/// 按直播间里收到的 DANMU_MSG 精简：info[0] 只保留用到的位置
Map<String, dynamic> biliDanmu(
  String text, {
  dynamic big = "{}",
  Map<String, dynamic>? emots,
}) {
  var meta = List<dynamic>.filled(16, 0);
  meta[3] = 16777215;
  meta[12] = big is Map ? 1 : 0;
  meta[13] = big;
  meta[15] = {
    "extra": json.encode({
      "dm_type": big is Map ? 1 : 0,
      "content": text,
      "emots": emots,
    }),
  };
  return {
    "cmd": "DANMU_MSG",
    "info": [
      meta,
      text,
      [1, "用户"],
    ],
  };
}

void main() {
  group('splitLiveEmotes', () {
    test('括号表情与文字', () {
      var parts = splitLiveEmotes("ttg又要输了[手机][手机]哈", const [
        LiveEmote(text: "[手机]", url: "https://a/1.png"),
      ]);
      expect(parts.map((e) => e.text), ["ttg又要输了", "[手机]", "[手机]", "哈"]);
      expect(parts.map((e) => e.isEmote), [false, true, true, false]);
    });

    test('字母表情名不匹配单词的一部分', () {
      var parts = splitLiveEmotes("LUL LULW xLUL LUL!", const [
        LiveEmote(text: "LUL", url: "https://a/lul"),
      ]);
      expect(parts.where((e) => e.isEmote), hasLength(2));
      expect(parts.map((e) => e.text).join(), "LUL LULW xLUL LUL!");
      expect(parts.first.isEmote, isTrue);
      expect(parts.last.text, "!");
    });

    test('长的优先', () {
      var parts = splitLiveEmotes(":_Bond::Bond:", const [
        LiveEmote(text: ":Bond:", url: "https://a/b"),
        LiveEmote(text: ":_Bond:", url: "https://a/a"),
      ]);
      expect(parts.map((e) => e.emote?.url), ["https://a/a", "https://a/b"]);
    });

    test('没有表情时整段文字', () {
      expect(splitLiveEmotes("abc", null).single.text, "abc");
      expect(splitLiveEmotes("abc", const []).single.isEmote, isFalse);
    });

    test('spaced 的表情只认整个词', () {
      const emotes = [
        LiveEmote(text: "???", url: "https://a/q", spaced: true),
        LiveEmote(text: "D:", url: "https://a/d", spaced: true),
      ];
      var parts = splitLiveEmotes("what??? ??? D: xD: D:", emotes);
      expect(parts.where((e) => e.isEmote).map((e) => e.text), [
        "???",
        "D:",
        "D:",
      ]);
      expect(parts.map((e) => e.text).join(), "what??? ??? D: xD: D:");
      // 聊天客户端为绕过重复消息检查加的不可见字符也算空白
      expect(splitLiveEmotes("D:\u{E0000}", emotes).first.isEmote, isTrue);
      expect(
        splitLiveEmotes(
          "\u{E0000}D: \u034f",
          emotes,
        ).where((e) => e.isEmote).single.text,
        "D:",
      );
    });

    test('新字段只在有值时输出', () {
      const plain = LiveEmote(text: "a", url: "https://a/a");
      expect(plain.toJson().keys, ["text", "url"]);
      const full = LiveEmote(
        text: "a",
        url: "https://a/a.webp",
        staticUrl: "https://a/a_static.webp",
        width: 32,
        height: 32,
        spaced: true,
        cacheKey: "k",
      );
      expect(full.toJson(), {
        "text": "a",
        "url": "https://a/a.webp",
        "staticUrl": "https://a/a_static.webp",
        "width": 32,
        "height": 32,
        "spaced": true,
        "cacheKey": "k",
      });
    });

    test('地址补全为 https', () {
      expect(
        liveEmoteUrl("http://i0.hdslb.com/a.png"),
        "https://i0.hdslb.com/a.png",
      );
      expect(
        liveEmoteUrl("//i0.hdslb.com/a.png"),
        "https://i0.hdslb.com/a.png",
      );
      expect(liveEmoteUrl(null), "");
    });
  });

  group('哔哩哔哩', () {
    test('文字里的小表情', () {
      var msg = BiliBiliDanmaku.parseBiliDanmuMsg(
        biliDanmu(
          "教练上场解说？[滑稽]",
          emots: {
            "[滑稽]": {
              "count": 1,
              "descript": "[滑稽]",
              "emoji": "[滑稽]",
              "emoticon_id": 219,
              "emoticon_unique": "emoji_219",
              "height": 20,
              "url":
                  "http://i0.hdslb.com/bfs/live/8624fd172037573c8600b2597e3731ef0e5ea983.png",
              "width": 20,
            },
          },
        ),
      )!;
      expect(msg.message, "教练上场解说？[滑稽]");
      expect(msg.sticker, isNull);
      var emote = msg.emotes!.single;
      expect(emote.text, "[滑稽]");
      expect(emote.url, startsWith("https://i0.hdslb.com/bfs/live/"));
      expect(emote.aspectRatio, 1);
      expect(msg.hasEmotes, isTrue);
    });

    test('表情包弹幕', () {
      var msg = BiliBiliDanmaku.parseBiliDanmuMsg(
        biliDanmu(
          "很蓝的啦",
          big: {
            "bulge_display": 0,
            "emoticon_unique": "official_139",
            "height": 60,
            "in_player_area": 1,
            "is_dynamic": 1,
            "url":
                "http://i0.hdslb.com/bfs/live/5f979e87fb45537652e7ff5b37365b4551bcb84e.png",
            "width": 198,
          },
        ),
      )!;
      expect(msg.message, "很蓝的啦");
      expect(msg.sticker!.text, "很蓝的啦");
      expect(msg.sticker!.width, 198);
      expect(msg.sticker!.height, 60);
      expect(msg.sticker!.url, startsWith("https://"));
      expect(msg.emotes, isNull);
    });

    test('普通弹幕没有表情', () {
      var msg = BiliBiliDanmaku.parseBiliDanmuMsg(biliDanmu("jdg夺了"))!;
      expect(msg.userName, "用户");
      expect(msg.hasEmotes, isFalse);
      expect(BiliBiliDanmaku.parseBiliDanmuMsg({"info": []}), isNull);
    });
  });

  group('YouTube', () {
    var customEmoji = {
      "emojiId": "UCS0FZc0K6vo3C0WDM3vZ0Jw/-Nl2Z6mmGKC8_9EP19PD4Qs",
      "shortcuts": [":_BottmlnglvBond:", ":BottmlnglvBond:"],
      "searchTerms": ["_BottmlnglvBond"],
      "image": {
        "thumbnails": [
          {
            "url": "https://yt3.ggpht.com/SKfu=w24-h24-c-k-nd",
            "width": 24,
            "height": 24,
          },
          {
            "url": "https://yt3.ggpht.com/SKfu=w48-h48-c-k-nd",
            "width": 48,
            "height": 48,
          },
        ],
        "accessibility": {
          "accessibilityData": {"label": "BottmlnglvBond"},
        },
      },
      "isCustomEmoji": true,
    };

    test('频道自定义表情显示为图片，标准表情保留字符', () {
      var items = parseYouTubeChatActions([
        {
          "addChatItemAction": {
            "item": {
              "liveChatTextMessageRenderer": {
                "id": "a1",
                "authorName": {"simpleText": "@JolenaTaborn"},
                "message": {
                  "runs": [
                    {"text": "GLOVE UP ! "},
                    {"emoji": customEmoji},
                    {
                      "emoji": {
                        "emojiId": "✨",
                        "shortcuts": [":sparkles:"],
                        "image": {
                          "thumbnails": [
                            {
                              "url":
                                  "https://fonts.gstatic.com/s/e/notoemoji/15.1/2728/72.png",
                            },
                          ],
                        },
                      },
                    },
                  ],
                },
              },
            },
          },
        },
      ]);
      var msg = items.single.message;
      expect(msg.message, "GLOVE UP ! :_BottmlnglvBond:✨");
      var emote = msg.emotes!.single;
      expect(emote.text, ":_BottmlnglvBond:");
      expect(emote.url, "https://yt3.ggpht.com/SKfu=w48-h48-c-k-nd");
      var parts = splitLiveEmotes(msg.message, msg.emotes);
      expect(parts.map((e) => e.isEmote), [false, true, false]);
    });

    test('付费贴纸带图片', () {
      var items = parseYouTubeChatActions([
        {
          "addChatItemAction": {
            "item": {
              "liveChatPaidStickerRenderer": {
                "id": "s1",
                "authorName": {"simpleText": "@fan"},
                "purchaseAmountText": {"simpleText": r"$2.00"},
                "backgroundColor": 4278248959,
                "moneyChipBackgroundColor": 4278248959,
                "sticker": {
                  "thumbnails": [
                    {
                      "url": "//lh3.googleusercontent.com/st=s40-rp",
                      "width": 40,
                      "height": 40,
                    },
                    {
                      "url": "//lh3.googleusercontent.com/st=s80-rp",
                      "width": 80,
                      "height": 80,
                    },
                  ],
                  "accessibility": {
                    "accessibilityData": {"label": "Hi 5"},
                  },
                },
              },
            },
          },
        },
      ], now: DateTime(2026, 10, 27));
      var msg = items.single.message;
      expect(msg.type, LiveMessageType.superChat);
      var sc = msg.data as LiveSuperChatMessage;
      expect(sc.message, "Hi 5");
      expect(sc.sticker!.url, "https://lh3.googleusercontent.com/st=s80-rp");
      expect(msg.sticker!.url, sc.sticker!.url);
    });

    test('runs 里没有自定义表情时为 null', () {
      expect(ytEmotes({"simpleText": "abc"}), isNull);
      expect(
        ytEmotes({
          "runs": [
            {"text": "hi"},
          ],
        }),
        isNull,
      );
    });
  });

  group('Twitch', () {
    test('emotes 标签按 Unicode 字符计位置', () {
      var emotes = TwitchDanmaku.parseTwitchEmotes(
        "emotesv2_db3cd788399347a8b2ebfb8a85f5badb:8-13",
        "LRがんばえー BigSad",
      )!;
      expect(emotes.single.text, "BigSad");
      expect(
        emotes.single.url,
        "https://static-cdn.jtvnw.net/emoticons/v2/"
        "emotesv2_db3cd788399347a8b2ebfb8a85f5badb/default/dark/2.0",
      );
    });

    test('多个表情与重复位置', () {
      var emotes = TwitchDanmaku.parseTwitchEmotes(
        "41:0-7,9-16/58765:18-28",
        "Kreygasm Kreygasm NotLikeThis",
      )!;
      expect(emotes.map((e) => e.text), ["Kreygasm", "NotLikeThis"]);
      expect(TwitchDanmaku.parseTwitchEmotes("", "x"), isNull);
      // 越界的位置忽略
      expect(TwitchDanmaku.parseTwitchEmotes("41:0-20", "abc"), isNull);
    });
  });

  test('Kick 表情', () {
    const content =
        "ADINNN [emote:3769161:adinARL2] bro![emote:5748007:collectiblesGoldenW]";
    var text = KickDanmaku.replaceEmotes(content);
    expect(text, "ADINNN adinARL2 bro!collectiblesGoldenW");
    var emotes = KickDanmaku.parseEmotes(content)!;
    expect(emotes.map((e) => e.url), [
      "https://files.kick.com/emotes/3769161/fullsize",
      "https://files.kick.com/emotes/5748007/fullsize",
    ]);
    expect(splitLiveEmotes(text, emotes).where((e) => e.isEmote), hasLength(2));
    expect(KickDanmaku.parseEmotes("hello"), isNull);

    // 紧挨着的表情和文字之间补空格，才认得出表情
    const joined =
        "rb jhonson008[emote:3769161:adinARL2][emote:3769161:adinARL2]x";
    var joinedText = KickDanmaku.replaceEmotes(joined);
    expect(joinedText, "rb jhonson008 adinARL2 adinARL2 x");
    expect(
      splitLiveEmotes(
        joinedText,
        KickDanmaku.parseEmotes(joined),
      ).where((e) => e.isEmote),
      hasLength(2),
    );
    expect(KickDanmaku.replaceEmotes("[emote:1:a]待って"), "a待って");
  });

  test('虎牙默认表情', () {
    var emotes = parseHuyaEmotes("[赞][赞][不看]/{dx 不是表情[哈哈]")!;
    expect(emotes.map((e) => e.text), ["[赞]", "[不看]", "/{dx"]);
    expect(
      emotes.first.url,
      "https://a.msstatic.com/huya/main/emot_png/zan.png",
    );
    expect(parseHuyaEmotes("普通弹幕"), isNull);
  });

  test('抖音表情列表', () {
    var urls = parseDouyinEmojiList({
      "status_code": 0,
      "emoji_list": [
        {
          "origin_uri": "wulian.png",
          "display_name": "[捂脸]",
          "hide": 0,
          "emoji_url": {
            "uri": "tos-cn-i-tsj2vxp0zn/abc",
            "url_list": [
              "https://p3-pc-sign.douyinpic.com/obj/tos-cn-i-tsj2vxp0zn/abc?x-expires=2108458800&x-signature=s",
              "https://p9-pc-sign.douyinpic.com/obj/tos-cn-i-tsj2vxp0zn/abc",
            ],
          },
        },
        {
          "display_name": "[坏的]",
          "emoji_url": {"url_list": []},
        },
      ],
    });
    expect(urls.keys, ["[捂脸]"]);
    expect(urls["[捂脸]"], startsWith("https://p3-pc-sign.douyinpic.com/"));
    expect(parseDouyinEmojiList(null), isEmpty);

    expect(DouyinEmotes.parse("[捂脸]"), isNull);
    DouyinEmotes.debugSet(urls);
    addTearDown(() => DouyinEmotes.debugSet(const {}));
    var emotes = DouyinEmotes.parse("哈哈[捂脸][捂脸][看]")!;
    expect(emotes.single.text, "[捂脸]");
    expect(DouyinEmotes.parse("没有表情"), isNull);
    // 实抓的弹幕
    expect(DouyinEmotes.parse("你这个bgm，我觉得我的童年又回来了[捂脸][捂脸][捂脸]"), hasLength(1));
  });

  test('抖音表情的缓存键不随签名变', () {
    Map<String, dynamic> list(String signature) => {
      "emoji_list": [
        {
          "display_name": "[捂脸]",
          "emoji_url": {
            "uri": "tos-cn-i-tsj2vxp0zn/abc",
            "url_list": [
              "https://p3-pc-sign.douyinpic.com/obj/tos-cn-i-tsj2vxp0zn/abc"
                  "?x-expires=2108530800&x-signature=$signature",
            ],
          },
        },
        {
          "display_name": "[没有uri]",
          "emoji_url": {
            "url_list": ["https://p3-pc-sign.douyinpic.com/obj/x"],
          },
        },
      ],
    };
    var a = parseDouyinEmojiTable(list("a"))["[捂脸]"]!;
    var b = parseDouyinEmojiTable(list("b"))["[捂脸]"]!;
    expect(a.url, isNot(b.url));
    expect(a.cacheKey, "douyin-emoji:tos-cn-i-tsj2vxp0zn/abc");
    expect(a.cacheKey, b.cacheKey);
    expect(parseDouyinEmojiTable(list("a"))["[没有uri]"]!.cacheKey, isNull);
  });
}
