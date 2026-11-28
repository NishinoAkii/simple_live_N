import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/youtube_chat_parser.dart';
import 'package:test/test.dart';

// test/fixtures/gifts/youtube_live_chat.json：匿名 get_live_chat 抓到的（2026-11-13，
// 用户名、头像、id 已替换）。会员里程碑、礼物（giftMessageViewModel）、文字消息、
// 占位消息是抓到的原样结构；新会员、赠送会员（GIFT_PURCHASE_*）、收到赠送
// （GIFT_REDEMPTION_*）抓包时段内没出现，按 YouTube 网页端聊天脚本
// （live_chat_base.js 里这三种渲染器读取的字段）和 YouTube.js 的
// LiveChatMembershipItem / LiveChatSponsorshipsHeader /
// LiveChatSponsorshipsGiftRedemptionAnnouncement 拼的。
dynamic fixture() => json.decode(
  File('test/fixtures/gifts/youtube_live_chat.json').readAsStringSync(),
);

LiveGiftMessage giftOf(YouTubeChatItem item) =>
    item.message.data as LiveGiftMessage;

void main() {
  late YouTubeChatBatch batch;
  late List<YouTubeChatItem> gifts;
  setUp(() {
    batch = parseYouTubeChatResponse(fixture());
    gifts = batch.items
        .where((e) => e.message.type == LiveMessageType.gift)
        .toList();
  });

  test('kept items: chat, memberships, gift purchases and gifts', () {
    expect(batch.items.map((e) => e.id), [
      'TEXT_1',
      'MEMBER_MILESTONE_1',
      'MEMBER_MILESTONE_2',
      'MEMBER_NEW_1',
      'GIFT_PURCHASE_1',
      'GIFT_PURCHASE_2',
      'GIFT_MSG_1',
      'GIFT_MSG_2',
    ]);
    expect(gifts.map((e) => '${e.message.userName} ${e.message.message}'), [
      '@member-one 续订 会员',
      '@member-two 续订 会员',
      '@member-new 加入 会员',
      '@gifter-one 赠送 会员 ×5',
      '匿名 赠送 会员 ×20',
      '@gift-sender-one 赠送 爱心',
      '@gift-sender-two 赠送 100',
    ]);
    expect(gifts.every((e) => giftOf(e).paid), isTrue);
    expect(gifts.every((e) => !e.isSuperChat), isTrue);
  });

  test('gift redemptions are per recipient and not counted', () {
    expect(
      batch.items.where((e) => e.id.startsWith('GIFT_REDEMPTION')),
      isEmpty,
    );
  });

  test('membership milestone: level and months, face, timestamp', () {
    var item = gifts[0];
    var gift = giftOf(item);
    expect(gift.action, '续订');
    expect(gift.giftName, '会员');
    expect(gift.priceText, 'KAELUARGA · 9 个月');
    expect(
      gift.face,
      'https://yt4.ggpht.com/avatar-member-one=s64-c-k-c0x00ffffff-no-rj',
    );
    expect(item.message.face, gift.face);
    expect(item.time, DateTime.fromMicrosecondsSinceEpoch(1794503449491428));
    expect(gift.time, item.time);
    expect(giftOf(gifts[1]).priceText, 'KAELUARGA · 53 个月');
  });

  test('new member has no price text', () {
    var gift = giftOf(gifts[2]);
    expect(gift.action, '加入');
    expect(gift.priceText, isNull);
  });

  test('gift purchase: count from its own run, image, anonymous', () {
    var gift = giftOf(gifts[3]);
    expect(gift.count, 5);
    expect(
      gift.face,
      'https://yt4.ggpht.com/avatar-gifter-one=s64-c-k-c0x00ffffff-no-rj',
    );
    expect(gift.icon?.url, contains('sponsorships_gift_purchase_announcement'));
    expect(gift.comboId, isNull);
    // 送的会员没有价格：每份按 4.99 美元估
    expect(gift.estimate, r'$24.95');
    var anonymous = giftOf(gifts[4]);
    expect(anonymous.userName, '匿名');
    expect(anonymous.count, 20);
    expect(anonymous.estimate, r'$99.80');
    expect(anonymous.face, '');
    expect(anonymous.icon, isNull);
  });

  test('gift messages: name after the colon, small gstatic image', () {
    var gift = giftOf(gifts[5]);
    expect(gift.userName, '@gift-sender-one');
    expect(gift.giftName, '爱心');
    expect(gift.count, 1);
    expect(gift.priceText, isNull);
    expect(
      gift.icon?.url,
      'https://www.gstatic.com/youtube/img/pdg/gift/assets/heart.png=w96-h96',
    );
    expect(
      gift.face,
      'https://yt4.ggpht.com/avatar-gift-one=s64-c-k-c0x00ffffff-no-rj',
    );
    // 没有时间戳：按收到的时间
    expect(gifts[5].time, isNull);
    expect(giftOf(gifts[6]).giftName, '100');
  });

  test('gift names in other wordings', () {
    expect(ytGiftNameAndCount('已发送：甜甜圈上的狐狸'), ('甜甜圈上的狐狸', 1));
    expect(ytGiftNameAndCount('Sent: Heart'), ('Heart', 1));
    expect(ytGiftNameAndCount('sent Heart'), ('Heart', 1));
    expect(ytGiftNameAndCount('sent Heart x3'), ('Heart', 3));
    expect(ytGiftNameAndCount('送出了「爱心」×2'), ('爱心', 2));
    expect(ytGiftNameAndCount('Fox2'), ('Fox2', 1));
    expect(ytGiftNameAndCount('ハートを送りました'), ('ハートを送りました', 1));
  });

  test('normal chat and the old fixture are unchanged', () {
    var text = batch.items.first;
    expect(text.message.type, LiveMessageType.chat);
    expect(text.message.userName, '@chat-viewer');
    expect(text.message.message, 'lol');
    expect(text.message.data, isNull);
    // 旧样本里没有作者的礼物消息仍然跳过
    var old = parseYouTubeChatResponse(
      json.decode(
        File('test/fixtures/youtube/get_live_chat.json').readAsStringSync(),
      ),
    );
    expect(old.items.map((e) => e.id), [
      'MSG_TEXT_1',
      'MSG_PAID_1',
      'MSG_PAID_2',
      'MSG_STICKER_1',
    ]);
  });

  test('history: gifts go to the chat list, not flying', () {
    // YouTubeDanmaku 把历史消息里的礼物和聊天一样标成历史消息
    var marked = gifts.first.message.asHistory();
    expect(marked.type, LiveMessageType.gift);
    expect(marked.history, isTrue);
    expect(marked.data, isA<LiveGiftMessage>());
  });
}
