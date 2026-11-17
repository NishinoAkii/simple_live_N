import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/youtube_chat_parser.dart';
import 'package:simple_live_core/src/danmaku/twitch_gifts.dart';
import 'package:test/test.dart';

// 发言人身份（LiveMessage.badges）：Twitch、Kick、YouTube。
// test/fixtures/badges 里的是 2026-11-13 匿名抓到的（用户名、id、消息已替换），
// 标“拼的”的几条是照抓到的格式拼的，见各文件开头的说明

/// 一个身份写成“种类:文字[:等级]”
String fmt(LiveBadge b) =>
    [b.kind.name, b.text, if (b.level != null) b.level].join(':');

List<String>? show(List<LiveBadge>? badges) => badges?.map(fmt).toList();

List<String> fixtureLines(String path) => File(
  path,
).readAsLinesSync().where((e) => e.isNotEmpty && !e.startsWith('#')).toList();

void main() {
  group('Twitch', () {
    List<String>? badgesOf(String raw) => show(
      TwitchDanmaku.privmsgToMessage(TwitchIrcLine.parse(raw), null).badges,
    );

    test('抓到的 PRIVMSG：订阅月数取 badge-info，纪念徽章不要', () {
      var lines = fixtureLines('test/fixtures/badges/twitch_irc.txt');
      expect(lines.map(badgesOf).toList(), [
        ['admin:房管', 'subscriber:订阅:44'],
        ['vip:VIP'],
        ['vip:VIP', 'subscriber:订阅:68'],
        ['subscriber:订阅:22', 'title:Prime'],
        ['title:Turbo'],
        ['subscriber:订阅:71'],
        null, // bits
        null, // 活动徽章
        null, // 没有徽章
        ['admin:房管'],
        // 拼的：没有 badge-info 时按档位，3012 是 Tier 3 的 12 个月
        ['broadcaster:主播', 'title:认证', 'subscriber:订阅:12'],
        ['subscriber:创始订阅:14', 'title:Prime'],
        // 首席房管和房管只出一个，竞猜不要
        ['admin:房管', 'title:官方', 'subscriber:订阅:26'],
      ]);
    });

    test('没有图标和颜色，顺序和 badges 标签一样', () {
      var line = TwitchIrcLine.parse(
        "@badge-info=subscriber/5;badges=subscriber/3,vip/1,broadcaster/1 "
        ":a!a@a.tmi.twitch.tv PRIVMSG #a :hi",
      );
      var badges = TwitchDanmaku.parseBadges(line.tags)!;
      expect(badges.map(fmt), ['subscriber:订阅:5', 'vip:VIP', 'broadcaster:主播']);
      expect(badges.every((e) => e.icon == null && e.color == null), isTrue);
    });

    test('标签转义：badge-info 里的 \\s、\\: 不影响月数', () {
      var line = TwitchIrcLine.parse(
        r"@badge-info=predictions/A\sB\:C,subscriber/7;"
        r"badges=predictions/pink-2,subscriber/6 "
        ":a!a@a.tmi.twitch.tv PRIVMSG #a :hi",
      );
      expect(line.tags["badge-info"], "predictions/A B;C,subscriber/7");
      expect(show(TwitchDanmaku.parseBadges(line.tags)), ['subscriber:订阅:7']);
    });

    test('坏数据', () {
      List<String>? parse(Map<String, String> tags) =>
          show(TwitchDanmaku.parseBadges(tags));
      expect(parse({}), isNull);
      expect(parse({"badges": ""}), isNull);
      expect(parse({"badges": ",,,"}), isNull);
      expect(parse({"badges": "/1,unknown/1"}), isNull);
      // 没有斜杠、版本不是数字、月数不是数字或不是正数：订阅照出，没有月数
      expect(parse({"badges": "subscriber"}), ['subscriber:订阅']);
      expect(
        parse({"badges": "subscriber/abc", "badge-info": "subscriber/xyz"}),
        ['subscriber:订阅'],
      );
      expect(
        parse({"badges": "subscriber/-5", "badge-info": "subscriber/-2"}),
        ['subscriber:订阅'],
      );
      expect(parse({"badges": "subscriber/0", "badge-info": "subscriber/0"}), [
        'subscriber:订阅',
      ]);
      // badge-info 坏了时按档位
      expect(parse({"badges": "subscriber/2006", "badge-info": "subscriber"}), [
        'subscriber:订阅:6',
      ]);
      expect(parse({"badges": "moderator/,vip,moderator/1"}), [
        'admin:房管',
        'vip:VIP',
      ]);
      // 只有 badge-info 没有 badges
      expect(parse({"badge-info": "subscriber/12"}), isNull);
    });

    test('USERNOTICE 和 Cheer 的礼物消息带上送礼人的身份', () {
      var lines = fixtureLines(
        'test/fixtures/gifts/twitch_irc.txt',
      ).map(TwitchIrcLine.parse).toList();
      var parser = TwitchGiftParser();
      var withBadges = <String>[];
      var withoutBadges = 0;
      for (var line in lines) {
        LiveGiftMessage? gift;
        if (line.command == 'USERNOTICE') {
          gift = parser.userNotice(line);
        } else if (line.command == 'PRIVMSG') {
          gift = TwitchGiftParser.cheer(line);
          if (gift != null) {
            // Cheer 的礼物和聊天消息身份一样
            expect(
              show(TwitchDanmaku.giftToMessage(gift, line).badges),
              show(TwitchDanmaku.privmsgToMessage(line, null).badges),
            );
          }
        }
        if (gift == null) {
          continue;
        }
        var message = TwitchDanmaku.giftToMessage(gift, line);
        expect(message.type, LiveMessageType.gift);
        expect(message.data, same(gift));
        expect(message.userName, gift.userName);
        expect(message.message, gift.text);
        if (message.badges == null) {
          withoutBadges++;
        } else {
          withBadges.add('${gift.userName} ${show(message.badges)!.join(",")}');
        }
      }
      expect(withBadges, contains('ViewerOne subscriber:订阅:1'));
      expect(withBadges, contains('ViewerTwo subscriber:订阅:63'));
      // 送礼人的送订阅徽章不要
      expect(withBadges, contains('送礼人 subscriber:订阅:1'));
      expect(withoutBadges, greaterThan(0));
    });

    test('toString 带 badges，可以读回来', () {
      var raw = fixtureLines('test/fixtures/badges/twitch_irc.txt').first;
      var message = TwitchDanmaku.privmsgToMessage(
        TwitchIrcLine.parse(raw),
        null,
      );
      var decoded = json.decode(message.toString())["badges"] as List;
      expect(decoded.map(LiveBadge.fromJson).toList(), message.badges);
    });
  });

  group('Kick', () {
    List<LiveMessage> run(Iterable<String> frames) {
      var messages = <LiveMessage>[];
      var danmaku = KickDanmaku()
        ..danmakuArgs = KickDanmakuArgs(
          chatroomId: 1000,
          channelId: 2000,
          slug: 'channel-a',
        )
        ..onMessage = messages.add;
      frames.forEach(danmaku.handleFrame);
      return messages;
    }

    String frame(Map<String, dynamic> data) => json.encode({
      "event": r"App\Events\ChatMessageEvent",
      "data": json.encode(data),
      "channel": "chatrooms.1000.v2",
    });

    test('抓到的帧：按数组顺序，订阅月数是 count，选了显示的等级放最后', () {
      var messages = run(
        fixtureLines('test/fixtures/badges/kick_pusher.jsonl'),
      );
      expect(messages.map((e) => show(e.badges)).toList(), [
        ['subscriber:订阅:30', 'level:等级:36'],
        ['admin:房管', 'vip:VIP', 'title:OG', 'level:等级:46'],
        ['subscriber:创始订阅', 'subscriber:订阅:1'],
        ['admin:房管', 'title:认证'],
        ['level:等级:54'],
        null,
        ['vip:VIP', 'title:OG', 'subscriber:订阅:8'],
        ['broadcaster:主播', 'title:官方', 'subscriber:订阅:13'],
      ]);
      expect(messages.map((e) => e.userName), contains('viewer_01'));
      var level = messages.first.badges!.last;
      expect(
        level.icon,
        'https://ext.cdn.kick.com/chat/badges/'
        '36_019f35ce-472c-788f-b36a-dbedaa04d6c5.png',
      );
      // 只有等级带图标
      expect(
        messages
            .expand((e) => e.badges ?? <LiveBadge>[])
            .where((e) => e.icon != null)
            .every((e) => e.kind == LiveBadgeKind.level),
        isTrue,
      );
    });

    test('旧的聊天帧（gifts 里的，badges 为空）没有身份', () {
      var messages = run(fixtureLines('test/fixtures/gifts/kick_pusher.jsonl'));
      var chat = messages.where((e) => e.type == LiveMessageType.chat);
      expect(chat.length, 1);
      expect(chat.single.badges, isNull);
    });

    test('坏数据', () {
      List<String>? parse(dynamic identity) =>
          show(KickDanmaku.parseBadges(identity));
      expect(parse(null), isNull);
      expect(parse("x"), isNull);
      expect(parse({}), isNull);
      expect(parse({"badges": "abc", "badges_v2": 5}), isNull);
      expect(
        parse({
          "badges": [
            1,
            "x",
            null,
            {},
            {"type": 5},
            {"type": null},
            {"type": "sidekick"},
          ],
        }),
        isNull,
      );
      expect(
        parse({
          "badges": [
            {"type": "subscriber", "count": "7"},
          ],
        }),
        ['subscriber:订阅:7'],
      );
      expect(
        parse({
          "badges": [
            {"type": "subscriber", "count": -1},
          ],
        }),
        ['subscriber:订阅'],
      );
      expect(
        parse({
          "badges": [
            {"type": "subscriber", "count": 2.9},
          ],
        }),
        ['subscriber:订阅:2'],
      );
      expect(
        parse({
          "badges": [
            {"type": "subscriber", "count": "abc"},
            {"type": " MODERATOR "},
            {"type": "moderator"},
          ],
        }),
        ['subscriber:订阅', 'admin:房管'],
      );
      // 等级：没选显示、等级不是数字、selected 不是 true 的都不要
      expect(
        parse({
          "badges_v2": [
            {
              "name": "level",
              "selected": true,
              "metadata": {"level": "x"},
            },
            {
              "name": "level",
              "selected": "true",
              "metadata": {"level": 3},
            },
            {"name": "level", "selected": true, "metadata": "5"},
            {"name": "level", "selected": true},
          ],
        }),
        isNull,
      );
      var level = KickDanmaku.parseBadges({
        "badges_v2": [
          {
            "name": "level",
            "selected": true,
            "metadata": {"level": "12"},
            "image_url": "//ext.cdn.kick.com/chat/badges/12.png",
          },
        ],
      })!.single;
      expect(fmt(level), 'level:等级:12');
      expect(level.icon, 'https://ext.cdn.kick.com/chat/badges/12.png');
      expect(
        KickDanmaku.parseBadges({
          "badges_v2": [
            {
              "name": "level",
              "selected": true,
              "metadata": {"level": 3},
              "image_url": 5,
            },
          ],
        })!.single.icon,
        isNull,
      );
    });

    test('sender、identity 坏了也照常出消息', () {
      var messages = run([
        frame({"content": "a", "sender": "abc"}),
        frame({
          "content": "b",
          "sender": {"username": "u", "identity": "x"},
        }),
        frame({
          "content": "c",
          "sender": {
            "username": "v",
            "identity": {"color": 5, "badges": {}},
          },
        }),
      ]);
      expect(messages.map((e) => e.message), ['a', 'b', 'c']);
      expect(messages.map((e) => e.userName), ['', 'u', 'v']);
      expect(messages.every((e) => e.badges == null), isTrue);
      expect(messages.map((e) => e.color.toString()).toSet(), {'#ffffff'});
    });
  });

  group('YouTube', () {
    Map<String, LiveMessage> parseFixture(String path) {
      var batch = parseYouTubeChatResponse(
        json.decode(File(path).readAsStringSync()),
      );
      return {for (var item in batch.items) item.id: item.message};
    }

    test('抓到的：房管、会员（月数从 tooltip 读，图标取 32px 的）', () {
      var messages = parseFixture(
        'test/fixtures/badges/youtube_live_chat.json',
      );
      expect(messages.map((id, m) => MapEntry(id, show(m.badges))), {
        'TEXT_1': ['admin:房管', 'member:会员:6'],
        'TEXT_2': ['member:会员'], // 新会员
        'TEXT_3': ['member:会员:12'],
        'TEXT_4': ['member:会员:24'],
        'TEXT_5': null,
        'TEXT_6': ['broadcaster:主播'],
        'TEXT_7': ['title:认证', 'admin:房管'],
        'PAID_8': ['admin:房管', 'member:会员:1'],
        'MEMBER_9': ['member:会员:1'],
      });
      expect(
        messages['TEXT_1']!.badges!.last.icon,
        'https://yt3.ggpht.com/badge-a-6m=s32-c-k',
      );
      expect(messages['TEXT_1']!.badges!.first.icon, isNull);
      // 醒目留言、会员消息照旧
      expect(messages['PAID_8']!.type, LiveMessageType.superChat);
      expect(messages['PAID_8']!.data, isA<LiveSuperChatMessage>());
      expect(messages['MEMBER_9']!.type, LiveMessageType.gift);
      expect((messages['MEMBER_9']!.data as LiveGiftMessage).text, '加入 会员');
    });

    test('gifts 里的旧抓包：只有 16px 的图时用它', () {
      var messages = parseFixture('test/fixtures/gifts/youtube_live_chat.json');
      var badge = messages['TEXT_1']!.badges!.single;
      expect(fmt(badge), 'member:会员:6');
      expect(badge.icon, 'https://yt3.ggpht.com/badge=s16-c-k');
    });

    test('tooltip 里的会龄，各语言', () {
      var cases = {
        '会员（6 个月）': 6,
        '会员（1 年）': 12,
        '会员（2 年）': 24,
        '會員 (6 個月)': 6,
        'Member (1 month)': 1,
        'Member (6 months)': 6,
        'Member (1 year)': 12,
        'Member (2 years)': 24,
        'Tier 2 (6 months)': 6,
        'メンバー（6 か月）': 6,
        'メンバー（1 年）': 12,
        '회원(2년)': 24,
        'Mitglied (2 Jahre)': 24,
        'Miembro (1 año)': 12,
        'Membre (2 ans)': 24,
        'Membro (6 meses)': 6,
        'Спонсор (1 год)': 12,
        'Спонсор (5 лет)': 60,
        'Anggota (2 tahun)': 24,
      };
      for (var entry in cases.entries) {
        expect(ytMemberMonths(entry.key), entry.value, reason: entry.key);
      }
      for (var none in [
        '',
        '新会员',
        'New member',
        'Tier 2 (New member)',
        '会员（0 个月）',
      ]) {
        expect(ytMemberMonths(none), isNull, reason: none);
      }
    });

    test('坏数据', () {
      expect(ytAuthorBadges(null), isNull);
      expect(ytAuthorBadges("x"), isNull);
      expect(ytAuthorBadges({}), isNull);
      expect(ytAuthorBadges([]), isNull);
      expect(
        ytAuthorBadges([
          1,
          "x",
          {},
          {"liveChatAuthorBadgeRenderer": "x"},
          {
            "liveChatAuthorBadgeRenderer": {
              "icon": {"iconType": "SOMETHING_NEW"},
            },
          },
          {
            "liveChatAuthorBadgeRenderer": {"icon": "OWNER"},
          },
        ]),
        isNull,
      );
      // 会员：图片列表坏了时不要图标，同一种身份只出一个
      var broken = ytAuthorBadges([
        {
          "liveChatAuthorBadgeRenderer": {
            "customThumbnail": {"thumbnails": "abc"},
          },
        },
        {
          "liveChatAuthorBadgeRenderer": {
            "icon": {"iconType": "MODERATOR"},
          },
        },
        {
          "liveChatAuthorBadgeRenderer": {
            "icon": {"iconType": "MODERATOR"},
          },
        },
      ])!;
      expect(broken.map(fmt), ['member:会员', 'admin:房管']);
      expect(broken.every((e) => e.icon == null), isTrue);
      // 宽度不是数字时不要图标；没有 tooltip 时读 accessibility
      var member = ytAuthorBadges([
        {
          "liveChatAuthorBadgeRenderer": {
            "customThumbnail": {
              "thumbnails": [
                {"url": "https://yt3.ggpht.com/x=s16-c-k", "width": "16"},
              ],
            },
            "accessibility": {
              "accessibilityData": {"label": "Member (2 years)"},
            },
          },
        },
      ])!.single;
      expect(fmt(member), 'member:会员:24');
      expect(member.icon, isNull);
    });

    test('文字消息没有 authorBadges、authorBadges 坏了照常出消息', () {
      Map renderer(dynamic badges) => {
        "addChatItemAction": {
          "item": {
            "liveChatTextMessageRenderer": {
              "id": "X",
              "message": {"simpleText": "hi"},
              "authorName": {"simpleText": "@a"},
              "authorBadges": ?badges,
            },
          },
        },
      };
      for (var badges in [
        null,
        "x",
        5,
        [],
        [null],
      ]) {
        var items = parseYouTubeChatActions([renderer(badges)]);
        expect(items.single.message.message, "hi");
        expect(items.single.message.badges, isNull);
      }
    });
  });
}
