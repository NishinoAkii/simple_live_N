import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/twitch_gifts.dart';
import 'package:test/test.dart';

/// 抓到的原始行（test/fixtures/gifts/twitch_irc.txt，注释行除外）
List<TwitchIrcLine> fixtureLines() => File('test/fixtures/gifts/twitch_irc.txt')
    .readAsLinesSync()
    .where((e) => e.isNotEmpty && !e.startsWith('#'))
    .map(TwitchIrcLine.parse)
    .toList();

/// 和 TwitchDanmaku 一样处理：PRIVMSG 出聊天（Cheer 再多一条礼物），USERNOTICE 出礼物
List<LiveMessage> run(List<TwitchIrcLine> lines) {
  var parser = TwitchGiftParser();
  var result = <LiveMessage>[];
  for (var line in lines) {
    if (line.command == 'PRIVMSG') {
      result.add(TwitchDanmaku.privmsgToMessage(line, null));
      var cheer = TwitchGiftParser.cheer(line);
      if (cheer != null) {
        result.add(cheer.toMessage());
      }
    } else if (line.command == 'USERNOTICE') {
      var gift = parser.userNotice(line);
      if (gift != null) {
        result.add(gift.toMessage());
      }
    }
  }
  return result;
}

LiveGiftMessage giftOf(LiveMessage m) => m.data as LiveGiftMessage;

void main() {
  late List<LiveMessage> messages;
  late List<LiveGiftMessage> gifts;
  setUp(() {
    messages = run(fixtureLines());
    gifts = messages
        .where((e) => e.type == LiveMessageType.gift)
        .map(giftOf)
        .toList();
  });

  test('every gift-like notice maps once, others are ignored', () {
    expect(gifts.map((e) => e.text), [
      '开通 订阅',
      '续订 订阅',
      '续订 订阅',
      '赠送 订阅 ×5',
      '赠送 订阅 ×2',
      '赠送 订阅',
      '赠送 订阅 ×2',
      '赠送 订阅',
      '续订 订阅',
      '赠送 Bits ×500',
      '赠送 Bits',
    ]);
  });

  test('sub and resub: tier, months, Prime is not paid', () {
    var sub = gifts[0];
    expect(sub.userName, 'ViewerOne');
    expect(sub.priceText, 'Tier 1');
    expect(sub.paid, isTrue);
    expect(sub.time, DateTime.fromMillisecondsSinceEpoch(1794503613373));
    expect(sub.icon, isNull);
    expect(sub.face, '');

    var prime = gifts[1];
    expect(prime.userName, 'ViewerTwo');
    expect(prime.priceText, 'Prime · 63 个月');
    expect(prime.paid, isFalse);

    expect(gifts[2].userName, 'viewer_three');
    expect(gifts[2].priceText, 'Tier 1 · 2 个月');
  });

  test('mystery gift counts once; per-recipient subgifts are skipped', () {
    var mystery = gifts[3];
    expect(mystery.userName, '送礼人');
    expect(mystery.count, 5);
    expect(mystery.comboId, 'twitch:11111111111111111111');
    expect(mystery.priceText, 'Tier 1');
    expect(mystery.paid, isTrue);

    var anonymous = gifts[4];
    expect(anonymous.userName, '匿名');
    expect(anonymous.count, 2);
    expect(anonymous.comboId, 'twitch:22222222222222222222');
  });

  test('subgifts without a known total add up under one comboId', () {
    expect(gifts[5].comboId, 'twitch:33333333333333333333');
    expect(gifts[5].count, 1);
    expect(gifts[6].comboId, gifts[5].comboId);
    expect(gifts[6].count, 2);
    expect(gifts[6].priceText, 'Tier 2');
    expect(gifts[6].userName, 'GifterTwo');
  });

  test(
    'a total that arrives after its subgifts replaces the running count',
    () {
      var parser = TwitchGiftParser();
      var lines = fixtureLines();
      var mystery = lines.firstWhere(
        (e) => e.tags['msg-id'] == 'submysterygift',
      );
      var subgifts = lines
          .where(
            (e) =>
                e.tags['msg-param-community-gift-id'] ==
                    mystery.tags['msg-param-community-gift-id'] &&
                e.tags['msg-id'] == 'subgift',
          )
          .toList();
      var early = parser.userNotice(subgifts[0])!;
      expect(early.count, 1);
      var total = parser.userNotice(mystery)!;
      expect(total.comboId, early.comboId);
      expect(total.count, 5);
      expect(subgifts.skip(1).map(parser.userNotice), everyElement(isNull));
    },
  );

  test('legacy anonymous ids and origin-id only subgifts', () {
    var parser = TwitchGiftParser();
    TwitchIrcLine notice(String tags) => TwitchIrcLine.parse(
      '@$tags;room-id=1;tmi-sent-ts=1 :tmi.twitch.tv USERNOTICE #a',
    );
    var mystery = parser.userNotice(
      notice(
        'login=ananonymousgifter;display-name=AnAnonymousGifter;'
        'msg-id=anonsubmysterygift;msg-param-mass-gift-count=3;'
        'msg-param-origin-id=777;msg-param-sub-plan=1000',
      ),
    );
    expect(mystery?.userName, '匿名');
    expect(mystery?.count, 3);
    expect(mystery?.comboId, 'twitch:777');
    var recipient = notice(
      'login=ananonymousgifter;msg-id=anonsubgift;msg-param-origin-id=777;'
      'msg-param-sub-plan=1000',
    );
    expect(parser.userNotice(recipient), isNull);
  });

  test('single subgift, paid upgrade', () {
    var single = gifts[7];
    expect(single.userName, 'GifterThree');
    expect(single.comboId, isNull);
    expect(single.priceText, 'Tier 3 · 3 个月');
    var upgrade = gifts[8];
    expect(upgrade.userName, 'ViewerFour');
    expect(upgrade.action, '续订');
    expect(upgrade.priceText, isNull);
  });

  test('cheers keep the chat message and add a Bits gift', () {
    var index = messages.indexWhere(
      (e) => e.type == LiveMessageType.chat && e.message.startsWith('Cheer500'),
    );
    expect(index, greaterThanOrEqualTo(0));
    expect(messages[index].userName, 'ViewerSeven');
    expect(messages[index].message, 'Cheer500 Hola 💗');
    var gift = giftOf(messages[index + 1]);
    expect(gift.userName, 'ViewerSeven');
    expect(gift.giftName, 'Bits');
    expect(gift.count, 500);
    expect(gift.priceText, '500 Bits');
    expect(gift.paid, isTrue);
    expect(
      gift.icon?.url,
      'https://d3aqoihi2n8ty8.cloudfront.net/actions/cheer/dark/animated/100/2.gif',
    );
    expect(gift.icon?.staticUrl, endsWith('/static/100/2.png'));
    expect(gifts.last.userName, '喵喵');
    expect(gifts.last.priceText, '1 Bits');
    expect(gifts.last.icon?.url, contains('/animated/1/2.gif'));
  });

  test('shared chat: other rooms give chat only, no gifts', () {
    var shared = messages.where((e) => e.message == 'cheer100 hi').toList();
    expect(shared, hasLength(1));
    expect(shared.single.type, LiveMessageType.chat);
    expect(gifts.where((e) => e.userName == 'ViewerFive'), isEmpty);
    expect(gifts.where((e) => e.userName == 'ViewerNine'), isEmpty);
  });

  test('normal chat is unchanged', () {
    var chats = messages.where((e) => e.type == LiveMessageType.chat).toList();
    expect(chats.map((e) => e.message), [
      'Cheer500 Hola 💗',
      'Cheer1 手不要遮',
      'cheer100 hi',
      'Kappa',
    ]);
    var kappa = chats.last;
    expect(kappa.userName, 'ViewerTen');
    expect(kappa.color.toString(), '#1e90ff');
    expect(kappa.sticker?.url, TwitchDanmaku.emoteUrl('25'));
    expect(chats.every((e) => e.data == null), isTrue);
  });

  test('subscriptions carry an estimate: tier price x paid months', () {
    expect(gifts[0].estimate, r'$5.99');
    // Prime 不用另外花钱
    expect(gifts[1].estimate, isNull);
    // 续订：累计月数不是这次付的
    expect(gifts[2].estimate, r'$5.99');
    // 一次送 5 份、2 份
    expect(gifts[3].estimate, r'$29.95');
    expect(gifts[4].estimate, '\$${(5.99 * gifts[4].count).toStringAsFixed(2)}');
    // 总数不知道时按收到的份数
    expect(gifts[5].estimate, r'$9.99');
    expect(gifts[6].estimate, r'$19.98');
    // 送 3 个月的 Tier 3
    expect(gifts[7].estimate, r'$74.97');
    // 升级没写档位
    expect(gifts[8].estimate, isNull);
    // 一次预付 6 个月
    var prepaid = TwitchGiftParser().userNotice(TwitchIrcLine.parse(
      '@display-name=Six;login=six;msg-id=sub;msg-param-sub-plan=2000;'
      'msg-param-multimonth-duration=6;room-id=1;user-id=9;tmi-sent-ts=1 '
      ':tmi.twitch.tv USERNOTICE #room',
    ))!;
    expect(prepaid.estimate, r'$59.94');
    // 预付期里第 3 个月分享的续订：没有新付钱
    var shared = TwitchGiftParser().userNotice(TwitchIrcLine.parse(
      '@display-name=Six;login=six;msg-id=resub;msg-param-sub-plan=2000;'
      'msg-param-cumulative-months=3;msg-param-multimonth-duration=6;'
      'msg-param-multimonth-tenure=2;room-id=1;user-id=9;tmi-sent-ts=2 '
      ':tmi.twitch.tv USERNOTICE #room',
    ))!;
    expect(shared.estimate, isNull);
    expect(shared.priceText, 'Tier 2 · 3 个月');
    expect(TwitchGiftParser.twitchSubPrice('Prime'), isNull);
    expect(TwitchGiftParser.twitchSubEstimate(null, 3), isNull);
    expect(TwitchGiftParser.twitchSubEstimate(5.99, 0), isNull);
  });

  test('bits icon tiers and tier names', () {
    String tier(int bits) =>
        TwitchGiftParser.bitsIcon(bits).url.split('/').reversed.skip(1).first;
    expect([1, 99, 100, 999, 1000, 4999, 5000, 10000, 50000].map(tier), [
      '1',
      '1',
      '100',
      '100',
      '1000',
      '1000',
      '5000',
      '10000',
      '10000',
    ]);
    expect(TwitchGiftParser.twitchTierText('2000'), 'Tier 2');
    expect(TwitchGiftParser.twitchTierText(null), isNull);
  });
}
