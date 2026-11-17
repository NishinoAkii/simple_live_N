import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/bilibili_gifts.dart';
import 'package:test/test.dart';

/// 匿名连接抓到的消息（用户信息已换成占位符），见 fixtures/gifts/bilibili_gifts.json
List<Map<String, dynamic>> loadMessages() {
  var text = File('test/fixtures/gifts/bilibili_gifts.json').readAsStringSync();
  return (json.decode(text)["messages"] as List).cast<Map<String, dynamic>>();
}

/// 按 BiliBiliDanmaku.parseMessage 的路径解析，收集发出的消息
List<LiveMessage> runDanmaku(List<Map<String, dynamic>> messages) {
  var out = <LiveMessage>[];
  var danmaku = BiliBiliDanmaku()..onMessage = out.add;
  for (var m in messages) {
    danmaku.parseMessage(json.encode(m));
  }
  return out;
}

/// 界面上的做法：comboId 相同的后一条代替前一条
Map<String, LiveGiftMessage> mergeCombos(Iterable<LiveGiftMessage> gifts) {
  var rows = <String, LiveGiftMessage>{};
  for (var g in gifts) {
    rows[g.comboId ?? identityHashCode(g).toString()] = g;
  }
  return rows;
}

const kFace = "https://i0.hdslb.com/bfs/face/member/noface.jpg@100w.jpg";

void main() {
  group('哔哩哔哩礼物（抓到的消息）', () {
    late List<LiveMessage> out;
    late List<LiveGiftMessage> gifts;
    setUp(() {
      out = runDanmaku(loadMessages());
      gifts = [
        for (var m in out)
          if (m.type == LiveMessageType.gift) m.data as LiveGiftMessage,
      ];
    });

    test('聊天照常解析', () {
      var chats = out.where((m) => m.type == LiveMessageType.chat).toList();
      expect(chats.map((m) => m.userName), ["用户A", "用户B"]);
      expect(chats.map((m) => m.message), ["主播好", "主播好"]);
    });

    test('SEND_GIFT_V2 的字段', () {
      // 8 条 SEND_GIFT_V2 + 2 条 COMBO_SEND
      expect(gifts, hasLength(10));
      var first = gifts.first;
      expect(first.userName, "用户C");
      expect(first.face, kFace);
      expect(first.action, "投喂");
      expect(first.giftName, "粉丝团灯牌");
      expect(first.count, 1);
      expect(first.paid, isTrue);
      expect(first.priceText, "¥0.1");
      expect(first.comboEnd, isFalse);
      expect(
        first.comboId,
        "batch:gift:combo_id:10000003:20000001:31164:1794503531.8911",
      );
      expect(
        first.time,
        DateTime.fromMillisecondsSinceEpoch(1794503531 * 1000),
      );
      expect(
        first.icon?.url,
        "https://i0.hdslb.com/bfs/live/32b799120e1614fa6275b6d15da7a52b21dd019d.webp",
      );
      expect(
        first.icon?.staticUrl,
        "https://s1.hdslb.com/bfs/live/e051dfd4557678f8edcac4993ed00a0935cbd9cc.png",
      );
      expect(first.icon?.text, "粉丝团灯牌");
      // 包成的消息
      var msg = out.firstWhere((m) => m.type == LiveMessageType.gift);
      expect(msg.userName, "用户C");
      expect(msg.message, "投喂 粉丝团灯牌");
      expect(msg.face, kFace);
    });

    test('连击：同一个 batch_combo_id，数量是累计的', () {
      var votes = gifts.where((g) => g.giftName == "人气票").toList();
      expect(votes.map((g) => g.count), [1, 2, 3, 31, 31]);
      expect(votes.map((g) => g.comboId).toSet(), hasLength(1));
      expect(votes.map((g) => g.priceText).toList(), [
        "¥0.1",
        "¥0.2",
        "¥0.3",
        "¥3.1",
        "¥3.1",
      ]);
      // 最后一条是 COMBO_SEND：连击结束，数量和最后一下相同，不是再加一遍
      expect(votes.last.comboEnd, isTrue);
      expect(votes.where((g) => g.comboEnd), hasLength(1));
      expect(votes.last.userName, "用户D");
      expect(votes.last.icon?.url, endsWith(".webp"));
    });

    test('合并后每次连击一行', () {
      var rows = mergeCombos(gifts);
      expect(rows, hasLength(4));
      var byName = {
        for (var g in rows.values) "${g.userName} ${g.giftName}": g,
      };
      expect(byName["用户C 粉丝团灯牌"]?.count, 1);
      expect(byName["用户D 人气票"]?.count, 31);
      expect(byName["用户E 粉丝团灯牌"]?.count, 2);
      expect(byName["用户E 粉丝团灯牌"]?.comboEnd, isTrue);
      expect(byName["用户F 小花花"]?.count, 30);
      expect(byName["用户F 小花花"]?.priceText, "¥3");
      expect(byName["用户F 小花花"]?.text, "投喂 小花花 ×30");
    });

    test('经过完整的解包路径（protover 0 的通知帧）', () {
      var received = <LiveMessage>[];
      var danmaku = BiliBiliDanmaku()..onMessage = received.add;
      for (var m in loadMessages()) {
        danmaku.decodeMessage(danmaku.encodeData(json.encode(m), 5));
      }
      expect(
        received.map((m) => m.type).toList(),
        out.map((m) => m.type).toList(),
      );
    });

    test('pb 坏了返回 null，不抛出', () {
      expect(
        parseBiliGift({
          "cmd": "SEND_GIFT_V2",
          "data": {"pb": "not base64!"},
        }),
        isNull,
      );
      expect(
        parseBiliGift({
          "cmd": "SEND_GIFT_V2",
          "data": {
            "pb": base64.encode([0xff, 0xff, 0xff]),
          },
        }),
        isNull,
      );
      expect(parseBiliGift({"cmd": "SEND_GIFT_V2", "data": {}}), isNull);
    });
  });

  // 旧格式（JSON 的 SEND_GIFT）和 GUARD_BUY 匿名连接没有收到，
  // 下面的消息按文档里的字段名构造
  group('哔哩哔哩礼物（构造的消息）', () {
    Map<String, dynamic> sendGift({
      String coinType = "gold",
      int price = 100,
      int num = 1,
      int superGiftNum = 1,
      String batchComboId = "batch:gift:combo_id:10000001:20000001:31036:1.1",
    }) => {
      "cmd": "SEND_GIFT",
      "data": {
        "action": "投喂",
        "batch_combo_id": batchComboId,
        "coin_type": coinType,
        "face": "http://i0.hdslb.com/bfs/face/member/noface.jpg",
        "giftId": 31036,
        "giftName": "小花花",
        "gift_info": {
          "img_basic":
              "https://s1.hdslb.com/bfs/live/5126973892625f3a43a8290be6b625b5e54261a5.png",
          "webp":
              "https://i0.hdslb.com/bfs/live/28357ba4cd566418730ca29da2c552efa7e4a390.webp",
        },
        "num": num,
        "price": price,
        "super_gift_num": superGiftNum,
        "tid": "1700000000110000001",
        "timestamp": 1700000000,
        "total_coin": price * num,
        "uid": 10000001,
        "uname": "用户A",
      },
    };

    test('SEND_GIFT（JSON）', () {
      var g = parseBiliGift(sendGift(num: 10, superGiftNum: 3))!;
      expect(g.userName, "用户A");
      expect(g.face, kFace);
      expect(g.giftName, "小花花");
      expect(g.count, 30);
      expect(g.paid, isTrue);
      expect(g.priceText, "¥3");
      expect(g.comboId, "batch:gift:combo_id:10000001:20000001:31036:1.1");
      expect(g.icon?.url, endsWith(".webp"));
      expect(g.icon?.staticUrl, endsWith(".png"));
      expect(g.time, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    });

    test('没有 batch_combo_id 时用 tid', () {
      var g = parseBiliGift(sendGift(batchComboId: ""))!;
      expect(g.comboId, "tid:1700000000110000001");
    });

    test('免费礼物：银瓜子或价格为 0', () {
      var silver = parseBiliGift(sendGift(coinType: "silver", price: 100))!;
      expect(silver.paid, isFalse);
      expect(silver.priceText, isNull);
      var zero = parseBiliGift(sendGift(price: 0))!;
      expect(zero.paid, isFalse);
      expect(zero.priceText, isNull);
    });

    test('COMBO_SEND 只用 batch_combo_id 更新数量', () {
      var g = parseBiliGift({
        "cmd": "COMBO_SEND",
        "data": {
          "action": "投喂",
          "batch_combo_id": "batch:gift:combo_id:10000001:20000001:31036:1.1",
          "combo_id": "gift:combo_id:10000001:20000001:31036:1.0",
          "batch_combo_num": 3,
          "combo_num": 3,
          "total_num": 30,
          "combo_total_coin": 3000,
          "coin_type": "gold",
          "gift_name": "小花花",
          "uname": "用户A",
        },
      })!;
      expect(g.comboId, "batch:gift:combo_id:10000001:20000001:31036:1.1");
      expect(g.count, 30);
      expect(g.priceText, "¥3");
      expect(g.comboEnd, isTrue);
    });

    test('GUARD_BUY', () {
      var g = parseBiliGift({
        "cmd": "GUARD_BUY",
        "data": {
          "uid": 10000001,
          "username": "用户A",
          "guard_level": 3,
          "num": 1,
          "price": 198000,
          "gift_id": 10003,
          "gift_name": "舰长",
          "start_time": 1700000000,
          "end_time": 1700000000,
        },
      })!;
      // GUARD_BUY 分不出开通还是续费，先写“上舰”（提示消息到了再改）
      expect(g.text, "上舰 舰长");
      expect(g.userName, "用户A");
      expect(g.paid, isTrue);
      expect(g.priceText, "¥198");
      // 和同一次上舰的提示消息合成一行
      expect(g.comboId, "guard:3:1700000000");
      expect(g.time, DateTime.fromMillisecondsSinceEpoch(1700000000000));

      var admiral = parseBiliGift({
        "cmd": "GUARD_BUY",
        "data": {
          "username": "用户B",
          "guard_level": 2,
          "num": 3,
          "price": 1998000,
        },
      })!;
      expect(admiral.text, "上舰 提督 ×3");
      expect(admiral.comboId, isNull);
      expect(admiral.priceText, "¥5994");
    });

    test('不是礼物的消息', () {
      expect(parseBiliGift({"cmd": "DANMU_MSG", "info": []}), isNull);
      expect(parseBiliGift({"cmd": "SEND_GIFT"}), isNull);
    });
  });

  test('金瓜子换成人民币', () {
    expect(biliPriceText(100), "¥0.1");
    expect(biliPriceText(1900), "¥1.9");
    expect(biliPriceText(52000), "¥52");
    expect(biliPriceText(1250), "¥1.25");
    expect(biliPriceText(1), "¥0.001");
  });
}
