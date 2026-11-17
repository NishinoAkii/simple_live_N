import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/douyin_gifts.dart';
import 'package:simple_live_core/src/danmaku/proto/douyin.pb.dart';
import 'package:test/test.dart';

/// fixtures/gifts/douyin_gifts.json：chat 是抓到的聊天（用户已换成占位符），
/// gifts 是按 douyin.proto 构造的送礼（匿名连接收不到礼物，没有真的可抓）
Map<String, dynamic> loadFixture() => json.decode(
  File('test/fixtures/gifts/douyin_gifts.json').readAsStringSync(),
);

List<GiftMessage> loadGifts() => [
  for (var g in loadFixture()["gifts"])
    GiftMessage.fromBuffer(base64.decode(g)),
];

/// 一帧 PushFrame（gzip 的 Response），和服务器推来的一样
List<int> pushFrame(List<Message> messages) {
  var response = Response()..messagesList.addAll(messages);
  return (PushFrame()
        ..payloadType = "msg"
        ..payload = gzip.encode(response.writeToBuffer()))
      .writeToBuffer();
}

Message message(String method, String payloadBase64) => Message()
  ..method = method
  ..payload = base64.decode(payloadBase64);

void main() {
  group('抖音礼物', () {
    late List<LiveGiftMessage> gifts;
    setUp(() {
      gifts = [for (var g in loadGifts()) parseDouyinGift(g)!];
    });

    test('连击：数量是 groupCount × repeatCount，同一个 groupId 合并', () {
      var rose = gifts.take(5).toList();
      expect(rose.map((g) => g.count), [1, 2, 2, 3, 3]);
      expect(rose.map((g) => g.comboId).toSet(), {
        "10000001:463:1794504000111",
      });
      expect(rose.map((g) => g.comboEnd), [false, false, false, false, true]);
      expect(rose.last.priceText, "3 钻");
      expect(rose.last.text, "送出 玫瑰 ×3");
    });

    test('字段', () {
      var g = gifts.first;
      expect(g.userName, "用户A");
      expect(
        g.face,
        "https://p3-pc.douyinpic.com/aweme/100x100/placeholder.jpeg",
      );
      expect(g.action, "送出");
      expect(g.giftName, "玫瑰");
      expect(g.paid, isTrue);
      expect(g.priceText, "1 钻");
      expect(g.time, DateTime.fromMillisecondsSinceEpoch(1794504001000));
      // 地址带签名，按图片 uri 缓存
      expect(g.icon?.url, startsWith("https://p3-webcast.douyinpic.com/"));
      expect(
        g.icon?.cacheKey,
        "douyin-gift:webcast/7ef47758a435313180e6b78b056dda4e.png",
      );
      expect(g.icon?.text, "玫瑰");
      expect(g.icon?.width, 100);
      expect(g.icon?.height, 100);
    });

    test('一次送一组', () {
      var g = gifts[5];
      expect(g.userName, "用户B");
      expect(g.face, "");
      expect(g.count, 20);
      expect(g.priceText, "20 钻");
      expect(g.comboId, "10000002:463:1794504000222");
      expect(g.toMessage().face, isNull);
    });

    test('没有 groupId 时按消息 id 合并（重复推送的同一条）', () {
      expect(gifts[6].comboId, "msg:7300000000000000006");
      expect(gifts[6].count, 1);
      expect(gifts[6].text, "送出 粉丝团灯牌");
    });

    test('0 钻的礼物是免费的', () {
      expect(gifts[7].giftName, "点亮粉丝团");
      expect(gifts[7].paid, isFalse);
      expect(gifts[7].priceText, isNull);
    });

    test('只有 comboCount、没有 repeatCount', () {
      var g = loadGifts()[5]..repeatCount = Int64(0);
      expect(parseDouyinGift(g)!.count, 20);
    });

    test('没有礼物名时不显示', () {
      var g = loadGifts().first..gift.name = "";
      expect(parseDouyinGift(g), isNull);
    });

    test('完整的一帧：聊天和礼物一起', () {
      var fixture = loadFixture();
      var chats = (fixture["chat"] as List).cast<String>();
      var giftPayloads = (fixture["gifts"] as List).cast<String>();
      var online = RoomUserSeqMessage()..total = Int64(1234);
      var frame = pushFrame([
        message("WebcastChatMessage", chats[0]),
        message("WebcastGiftMessage", giftPayloads[0]),
        message("WebcastChatMessage", chats[1]),
        Message()
          ..method = "WebcastRoomUserSeqMessage"
          ..payload = online.writeToBuffer(),
        message("WebcastGiftMessage", giftPayloads[7]),
        // 坏的礼物消息不影响后面的
        Message()
          ..method = "WebcastGiftMessage"
          ..payload = [0xff, 0xff, 0xff],
        message("WebcastChatMessage", chats[0]),
      ]);
      var out = <LiveMessage>[];
      CoreLog.enableLog = false;
      var danmaku = DouyinDanmaku()..onMessage = out.add;
      danmaku.decodeMessage(frame);
      expect(out.map((m) => m.type).toList(), [
        LiveMessageType.chat,
        LiveMessageType.gift,
        LiveMessageType.chat,
        LiveMessageType.online,
        LiveMessageType.gift,
        LiveMessageType.chat,
      ]);
      expect(out[0].userName, "用户A");
      expect(out[0].message, "主播好");
      expect(out[2].userName, "用户B");
      expect(out[3].data, 1234);
      expect(out[1].message, "送出 玫瑰");
      expect((out[4].data as LiveGiftMessage).paid, isFalse);
    });
  });
}
