import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/huya_gifts.dart';
import 'package:simple_live_core/src/model/tars/huya_gift.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';
import 'package:test/test.dart';

const _dir = 'test/fixtures/gifts';

/// 实抓的道具列表（只留了 5 个道具，保持原始编码）
Map<int, HuyaGiftInfo> props() {
  var rsp = HuyaGetPropsListRsp()
    ..readFrom(
      TarsInputStream(File('$_dir/huya_props_list.bin').readAsBytesSync()),
    );
  return parseHuyaPropsList(rsp.vPropsItemList);
}

/// 实抓的送礼广播（昵称等已替换），原始字节
List<Uint8List> rawGifts() => File('$_dir/huya_send_item.txt')
    .readAsLinesSync()
    .where((e) => e.isNotEmpty && !e.startsWith('#'))
    .map(base64.decode)
    .toList();

HuyaSendItemPacket packet(List<int> raw) =>
    HuyaSendItemPacket()..readFrom(TarsInputStream(Uint8List.fromList(raw)));

/// 服务器推送的一帧（命令 7）；[group] 不为空时是消息组推来的
List<int> frame(int uri, List<int> msg, {String group = ""}) {
  var push = TarsOutputStream();
  push.write(group.isEmpty ? 3 : 5, 0);
  push.write(uri, 1);
  push.write(Uint8List.fromList(msg), 2);
  push.write(0, 3);
  push.write(group, 4);
  var cmd = TarsOutputStream();
  cmd.write(7, 0);
  cmd.write(push.toUint8List(), 1);
  return cmd.toUint8List();
}

/// 一条聊天（HYMessage：tag 0 发送人、tag 3 内容、tag 20 消息 id）
List<int> chat(String nick, String content, String id) {
  var os = TarsOutputStream();
  os.writeHead(TarsStructType.STRUCT_BEGIN.index, 0);
  os.write(10001, 0);
  os.write(nick, 2);
  os.writeHead(TarsStructType.STRUCT_END.index, 0);
  os.write(content, 3);
  os.write(id, 20);
  return os.toUint8List();
}

void main() {
  group('道具列表', () {
    test('名称、价格、图片（去掉“&md5”）', () {
      var gifts = props();
      expect(gifts, hasLength(5));
      var food = gifts[4]!;
      expect(food.name, '虎粮');
      expect(food.price, 10);
      expect(
        food.icon,
        'https://fileserver.cdn.huya.com/admin_gift_merge/'
        '11d634bb72034859afdb93c7217b2268/150.png',
      );
      expect(gifts[20823]!.name, '金话筒');
      expect(gifts[20823]!.price, 100);
    });

    test('价值文字', () {
      expect(huyaYuanText(10), '¥0.1');
      expect(huyaYuanText(90), '¥0.9');
      expect(huyaYuanText(131400), '¥1314');
    });
  });

  group('送礼广播', () {
    late Map<int, HuyaGiftInfo> gifts;
    late List<HuyaSendItemPacket> raw;
    setUp(() {
      gifts = props();
      raw = rawGifts().map(packet).toList();
    });

    LiveGiftMessage parse(HuyaSendItemPacket p, [HuyaGiftCombos? combos]) =>
        parseHuyaGift(p, info: gifts[p.iItemType], combos: combos)!;

    test('新版字段：名称、连击 id、实付金额', () {
      expect(raw.first.sPropsName, '虎粮');
      expect(raw.first.lComboSeqId, greaterThan(0));
      expect(raw.first.lRoomId, 60066);
      expect(raw[5].lPayTotal, 100);
    });

    test('一个一个连送虎粮：同一个连击，数量是个数 × 组号，银豆送的免费', () {
      var list = raw.take(3).map(parse).toList();
      expect(list.map((e) => e.count), [1, 2, 3]);
      expect(list.map((e) => e.comboId).toSet(), hasLength(1));
      var g = list.last;
      expect(g.userName, '用户A');
      expect(g.giftName, '虎粮');
      expect(g.paid, isFalse);
      expect(g.priceText, isNull);
      expect(g.icon!.url, gifts[4]!.icon);
      expect(g.face, startsWith('https://huyaimg.msstatic.com/avatar/'));
      expect(g.text, '送出 虎粮 ×3');
    });

    test('超粉虎粮 ×10 连送两组：20 个，免费', () {
      var list = raw.skip(3).take(2).map(parse).toList();
      expect(list.map((e) => e.count), [10, 20]);
      expect(list.first.comboId, list.last.comboId);
      expect(list.last.paid, isFalse);
    });

    test('金话筒：付费，价值按道具列表的单价', () {
      var g = parse(raw[5]);
      expect(g.giftName, '金话筒');
      expect(g.paid, isTrue);
      expect(g.priceText, '¥1');
    });

    test('用虎牙币买的虎粮是付费的', () {
      var g = parse(raw[6]);
      expect(g.giftName, '虎粮');
      expect(g.count, 9);
      expect(g.paid, isTrue);
      expect(g.priceText, '¥0.9');
      // 道具列表没读到时按实付金额算单价
      expect(parseHuyaGift(raw[6])!.priceText, '¥0.9');
    });

    test('贵族的热火 ×20 免费', () {
      var g = parse(raw[7]);
      expect([g.giftName, g.count, g.paid], ['热火', 20, false]);
    });

    test('没有连击 id 的（盲盒送出的虎粮 ×5）自己合并、累加', () {
      var combos = HuyaGiftCombos();
      var p = raw[8];
      expect([p.lComboSeqId, p.iItemCount, p.iItemGroup], [0, 5, 1]);
      var t = DateTime(2026, 11, 13, 2);
      LiveGiftMessage at(int seconds) => parseHuyaGift(
        p,
        info: gifts[p.iItemType],
        combos: combos,
        now: t.add(Duration(seconds: seconds)),
      )!;
      var a = at(0);
      expect([a.count, a.paid], [5, false]);
      // 内容完全相同的又一次：同一个连击，数量累加
      var b = at(2);
      expect([b.comboId, b.count], [a.comboId, 10]);
      // 组号递增（中间缺了一组）只加多出来的
      p.iItemGroup = 3;
      expect(at(4).count, 20);
      // 隔太久是新的连击
      p.iItemGroup = 1;
      var c = at(60);
      expect(c.comboId, isNot(a.comboId));
      expect(c.count, 5);
      // 没给 combos 时每条单独算
      expect(parseHuyaGift(p)!.comboId, isNull);
    });

    test('不认识的礼物：名称用“礼物”，没有图片', () {
      var p = raw.first
        ..iItemType = 99999
        ..sPropsName = "";
      var g = parseHuyaGift(p, info: gifts[p.iItemType])!;
      expect(g.giftName, '礼物');
      expect(g.icon, isNull);
      expect(parseHuyaGift(HuyaSendItemPacket()), isNull);
    });
  });

  group('弹幕连接', () {
    setUp(HuyaRoomGifts.debugReset);
    tearDown(HuyaRoomGifts.debugReset);

    test('订阅消息组的包', () {
      var data = HuyaDanmaku.getRegisterGroupData(123);
      var stream = TarsInputStream(Uint8List.fromList(data));
      expect(stream.read(0, 0, false), 16);
      var req = HuyaRegisterGroupReq()
        ..readFrom(TarsInputStream(stream.readBytes(1, false)));
      expect(req.vGroupId, ['chat:123']);
    });

    test('聊天两边各来一份时只发一次，礼物和在线人数照常', () async {
      HuyaRoomGifts.debugSet(0, props());
      var danmaku = HuyaDanmaku();
      var out = <LiveMessage>[];
      danmaku.onMessage = out.add;
      var a = chat('用户A', '你好', '2082324260034187264');
      var b = chat('用户B', '你好', '2082324260101293056');
      danmaku.decodeMessage(frame(1400, a));
      danmaku.decodeMessage(frame(1400, a, group: 'chat:1'));
      danmaku.decodeMessage(frame(1400, b, group: 'chat:1'));
      danmaku.decodeMessage(frame(1400, b));
      for (var g in rawGifts().take(3)) {
        danmaku.decodeMessage(frame(6501, g, group: 'chat:1'));
      }
      danmaku.decodeMessage(
        frame(8006, (TarsOutputStream()..write(4321, 0)).toUint8List()),
      );
      await Future.delayed(const Duration(milliseconds: 50));
      var chats = out.where((e) => e.type == LiveMessageType.chat).toList();
      expect(chats.map((e) => e.userName), ['用户A', '用户B']);
      expect(chats.first.message, '你好');
      expect(
        out.where((e) => e.type == LiveMessageType.online).single.data,
        4321,
      );
      var gifts = out
          .where((e) => e.type == LiveMessageType.gift)
          .map((e) => e.data as LiveGiftMessage)
          .toList();
      expect(gifts.map((e) => e.count), [1, 2, 3]);
      expect(gifts.first.icon, isNotNull);
      expect(
        out.where((e) => e.type == LiveMessageType.gift).last.message,
        '送出 虎粮 ×3',
      );
    });
  });
}
