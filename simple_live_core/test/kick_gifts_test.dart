import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/kick_gifts.dart';
import 'package:test/test.dart';

/// 抓到的 Pusher 帧（test/fixtures/gifts/kick_pusher.jsonl，注释行除外）
List<String> fixtureFrames() => File(
  'test/fixtures/gifts/kick_pusher.jsonl',
).readAsLinesSync().where((e) => e.isNotEmpty && !e.startsWith('#')).toList();

LiveGiftMessage giftOf(LiveMessage m) => m.data as LiveGiftMessage;

void main() {
  late List<LiveMessage> messages;
  late List<LiveGiftMessage> gifts;
  late int ready;
  setUp(() {
    messages = [];
    ready = 0;
    var danmaku = KickDanmaku()
      ..danmakuArgs = KickDanmakuArgs(
        chatroomId: 1000,
        channelId: 2000,
        slug: 'channel-a',
      )
      ..onMessage = messages.add
      ..onReady = () => ready++;
    fixtureFrames().forEach(danmaku.handleFrame);
    gifts = messages
        .where((e) => e.type == LiveMessageType.gift)
        .map(giftOf)
        .toList();
  });

  test('only the chat channel counts as ready', () {
    expect(ready, 1);
  });

  test('gift-like events map once each, others are ignored', () {
    expect(gifts.map((e) => '${e.userName} ${e.text}'), [
      'viewer_two 开通 订阅',
      'viewer_three 续订 订阅',
      'gifter_one 赠送 订阅 ×3',
      'gifter_two 赠送 订阅 ×250',
      'kicker_one 赠送 Rage Quit',
      'kicker_two 赠送 Hell Yeah',
      'kicker_two 赠送 Hell Yeah',
      'kicker_three 赠送 Space Rocket',
    ]);
    expect(gifts.every((e) => e.paid), isTrue);
  });

  test('subscriptions: months as price text', () {
    expect(gifts[0].priceText, isNull);
    expect(gifts[1].priceText, '3 个月');
  });

  test('gifted subscriptions: total once, later chunks skipped', () {
    expect(gifts[2].comboId, 'kick:pi_00000000000000000000001');
    expect(gifts[2].count, 3);
    expect(gifts[3].comboId, 'kick:pi_00000000000000000000002');
    expect(gifts[3].count, 250);
  });

  test('a new gift after the last chunk is counted again', () {
    var parser = KickGiftParser();
    Map chunk(int index, [String id = 'c1']) => {
      'gifter_username': 'g',
      'gifted_usernames': ['a'],
      'gifted_total': 2,
      'chunk_details': {
        'correlation_id': id,
        'chunk_index': index,
        'total_chunks': 2,
      },
    };
    expect(parser.giftedSubscriptions(chunk(0))?.count, 2);
    expect(parser.giftedSubscriptions(chunk(1)), isNull);
    expect(parser.giftedSubscriptions(chunk(0, 'c2'))?.count, 2);
    // 没有总数时按名单人数
    expect(
      parser.giftedSubscriptions({
        'gifter_username': '',
        'gifted_usernames': ['a', 'b'],
      })?.text,
      '赠送 订阅 ×2',
    );
    expect(
      parser.giftedSubscriptions({
        'gifted_usernames': ['a'],
      })?.userName,
      '匿名',
    );
  });

  test('Kicks gifts: image, price, sender avatar, time', () {
    var rage = gifts[4];
    expect(rage.comboId, 'kick:00000000-0000-0000-0000-000000000010');
    expect(rage.priceText, '500 Kicks');
    expect(rage.count, 1);
    expect(
      rage.face,
      'https://kick.com/img/default-profile-pictures/default-avatar-3.webp',
    );
    expect(rage.icon?.url, 'https://files.kick.com/kicks/gifts/rage-quit.webp');
    expect(
      rage.icon?.staticUrl,
      'https://files.kick.com/kicks/gifts/rage-quit-static.webp',
    );
    expect(rage.time.toUtc(), DateTime.utc(2026, 11, 12, 17, 14, 52, 503, 794));

    var hell = gifts[5];
    expect(hell.priceText, '1 Kicks');
    expect(hell.icon?.url, 'https://files.kick.com/kicks/gifts/hell-yeah.webp');
    expect(hell.icon?.staticUrl, isNull);
    // 同一笔交易重复推送：comboId 相同，界面上替换而不是多一行
    expect(gifts[6].comboId, hell.comboId);

    var unknown = gifts[7];
    expect(
      unknown.icon?.url,
      'https://files.kick.com/kicks/gifts/space-rocket.webp',
    );
    expect(unknown.face, '');
    expect(
      KickGiftParser.kicksGiftIcon('boooom', 'Boom')?.url,
      'https://files.kick.com/kicks/gifts/boom.webp',
    );
  });

  test('normal chat is unchanged', () {
    var chats = messages.where((e) => e.type == LiveMessageType.chat).toList();
    expect(chats, hasLength(1));
    var chat = chats.single;
    expect(chat.userName, 'viewer_one');
    expect(chat.message, 'hi KEKW');
    expect(chat.color.toString(), '#75fd46');
    expect(
      chat.emotes?.single.url,
      'https://files.kick.com/emotes/37226/fullsize',
    );
  });

  test('broken or unrelated payloads are ignored', () {
    var parser = KickGiftParser();
    expect(parser.parse('KicksGifted', 'not json'), isNull);
    expect(parser.parse('KicksGifted', '{"gift":null}'), isNull);
    expect(parser.parse('RewardRedeemedEvent', '{}'), isNull);
    expect(
      parser.parse(r'App\Events\SubscriptionEvent', '{"months":2}'),
      isNull,
    );
  });
}
