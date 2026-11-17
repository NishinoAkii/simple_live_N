import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/douyu_gifts.dart';
import 'package:test/test.dart';

const _dir = 'test/fixtures/gifts';

/// 实抓的消息（用户名等已替换），按行
List<String> messages() => File(
  '$_dir/douyu_messages.txt',
).readAsLinesSync().where((e) => e.isNotEmpty && !e.startsWith('#')).toList();

dynamic fixture(String name) =>
    json.decode(File('$_dir/$name').readAsStringSync());

Map<String, String> stt(String raw) => {
  for (var f in raw.split('/'))
    if (f.contains('@='))
      f.substring(0, f.indexOf('@=')): f
          .substring(f.indexOf('@=') + 2)
          .replaceAll('@S', '/')
          .replaceAll('@A', '@'),
};

void main() {
  group('礼物列表', () {
    test('房间礼物：鱼翅付费、鱼丸免费，图片补全前缀', () {
      var gifts = parseDouyuRoomGiftList(fixture('douyu_gift_list_74751.json'));
      expect(gifts, hasLength(6));
      var guard = gifts['24478']!;
      expect(guard.name, '全力守护');
      expect(guard.price, 10);
      expect(guard.paid, isTrue);
      expect(
        guard.icon,
        'https://gfs-op.douyucdn.cn/dygift/2021/08/03/4b701faa9f25bc0e85aad44ef3275d06.png',
      );
      var yuwan = gifts['20000']!;
      expect(yuwan.name, '100鱼丸');
      expect([yuwan.yuwan, yuwan.paid, yuwan.price], [true, false, 100]);
      expect(gifts['20003']!.price, 10000);
    });

    test('背包道具：isValuable 决定付费', () {
      var glow = parseDouyuPropSingle(fixture('douyu_prop_268.json'))!;
      expect(glow.name, '粉丝荧光棒');
      expect(glow.paid, isFalse);
      expect(glow.icon, startsWith('https://gfs-op.douyucdn.cn/dygift/1705/'));
      var dragon = parseDouyuPropSingle(fixture('douyu_prop_3287.json'))!;
      expect(dragon.name, '四翼魔龙');
      expect([dragon.paid, dragon.price], [true, 50000]);
      expect(parseDouyuPropSingle({'error': 0, 'data': null}), isNull);
    });

    test('价值文字', () {
      expect(douyuYuanText(10), '¥0.1');
      expect(douyuYuanText(15), '¥0.15');
      expect(douyuYuanText(1530), '¥15.3');
      expect(douyuYuanText(50000), '¥500');
    });

    test('头像', () {
      expect(
        douyuAvatarUrl('avatar/default/24'),
        'https://apic.douyucdn.cn/upload/avatar/default/24_middle.jpg',
      );
      expect(douyuAvatarUrl(''), '');
    });
  });

  group('送礼消息', () {
    late Map<String, DouyuGiftInfo> room;
    late List<Map<String, String>> raw;
    setUp(() {
      room = parseDouyuRoomGiftList(fixture('douyu_gift_list_74751.json'));
      raw = messages().map(stt).toList();
    });

    test('荧光棒一个一个连送：同一个连击，数量是 hits，免费', () {
      var combos = DouyuGiftCombos();
      var glow = parseDouyuPropSingle(fixture('douyu_prop_268.json'));
      var gifts = raw
          .take(4)
          .map((m) => parseDouyuGift(m, info: glow, combos: combos)!)
          .toList();
      expect(gifts.map((e) => e.count), [153, 155, 156, 158]);
      expect(gifts.map((e) => e.comboId).toSet(), hasLength(1));
      var g = gifts.last;
      expect(g.userName, '用户A');
      expect(g.giftName, '粉丝荧光棒');
      expect(g.paid, isFalse);
      expect(g.priceText, isNull);
      expect(g.icon!.url, glow!.icon);
      expect(g.text, '赠送 粉丝荧光棒 ×158');
      expect(
        g.face,
        'https://apic.douyucdn.cn/upload/avatar_v3/202001/'
        '00000000000000000000000000000001_middle.jpg',
      );
    });

    test('一次送 20 个：hits 是累计总数', () {
      var combos = DouyuGiftCombos();
      var gifts = raw
          .skip(4)
          .take(3)
          .map((m) => parseDouyuGift(m, combos: combos)!)
          .toList();
      expect(gifts.map((e) => e.count), [20, 40, 60]);
      expect(gifts.map((e) => e.comboId).toSet(), hasLength(1));
      // 没查到的背包道具按免费算，名称用消息里的 gfn
      expect(gifts.first.paid, isFalse);
      expect(gifts.first.giftName, '粉丝荧光棒');
      expect(gifts.first.icon, isNull);
    });

    test('hits 变小或隔太久是新的连击', () {
      var combos = DouyuGiftCombos();
      var t = DateTime(2026, 11, 13, 2);
      var m = raw[4];
      String id(int hits, DateTime time) => parseDouyuGift(
        {...m, 'hits': '$hits'},
        combos: combos,
        now: time,
      )!.comboId!;
      var a = id(20, t);
      expect(id(40, t.add(const Duration(seconds: 5))), a);
      var b = id(20, t.add(const Duration(seconds: 10)));
      expect(b, isNot(a));
      expect(id(40, t.add(const Duration(minutes: 5))), isNot(b));
      // 不同的人不共用连击
      expect(parseDouyuGift(raw[0], combos: combos, now: t)!.comboId, isNot(a));
    });

    test('直接买的礼物查房间列表：付费，价值按数量算', () {
      var g = parseDouyuGift(raw[7], info: room['24478'])!;
      expect(g.giftName, '全力守护');
      expect(g.paid, isTrue);
      expect(g.priceText, '¥0.1');
      expect(g.icon!.text, '全力守护');
      var five = parseDouyuGift({
        ...raw[7],
        'gfid': '20003',
        'gfn': '',
        'gfcnt': '5',
        'hits': '5',
      }, info: room['20003'])!;
      expect(five.giftName, '飞机');
      expect(five.priceText, '¥500');
    });

    test('鱼丸礼物免费，价值写鱼丸数', () {
      var g = parseDouyuGift({
        ...raw[7],
        'gfid': '20000',
        'gfn': '100鱼丸',
        'gfcnt': '1',
        'hits': '3',
      }, info: room['20000'])!;
      expect(g.paid, isFalse);
      expect(g.priceText, '300 鱼丸');
    });

    test('gfid 为 0 的背包道具按 pid', () {
      var stamp = parseDouyuPropSingle(fixture('douyu_prop_3410.json'));
      var g = parseDouyuGift(raw[8], info: stamp)!;
      expect(g.giftName, '陪伴印章');
      expect(g.count, 50);
      expect(g.paid, isFalse);
      expect(g.icon, isNotNull);
    });

    test('不认识的礼物：名称用“礼物”，没有图片，直接买的按付费', () {
      var g = parseDouyuGift({...raw[7], 'gfid': '99999', 'gfn': ''})!;
      expect(g.giftName, '礼物');
      expect(g.icon, isNull);
      expect(g.paid, isTrue);
      expect(g.priceText, isNull);
      expect(parseDouyuGift({'type': 'dgb', 'gfid': '0'}), isNull);
    });

    test('开通贵族：只认本房间的', () {
      var msg = {
        'type': 'anbc',
        'uid': '10001',
        'unk': '用户A',
        'drid': '63136',
        'nl': '3',
      };
      var g = parseDouyuNoble(msg, '63136')!;
      expect(g.text, '开通 贵族伯爵');
      expect(g.paid, isTrue);
      expect(
        parseDouyuNoble({...msg, 'type': 'rnewbc'}, '63136')!.action,
        '续费',
      );
      expect(parseDouyuNoble({...msg, 'drid': '1'}, '63136'), isNull);
      expect(parseDouyuNoble({...msg, 'nl': '99'}, '63136')!.giftName, '贵族');
    });
  });

  group('弹幕连接', () {
    setUp(() {
      DouyuRoomGifts.debugReset();
      DouyuPropGifts.debugReset();
      DouyuRoomEmotes.debugReset();
    });
    tearDown(() {
      DouyuRoomGifts.debugReset();
      DouyuPropGifts.debugReset();
      DouyuRoomEmotes.debugReset();
    });

    Future<List<LiveMessage>> decode(
      List<String> raws, {
      bool oneFrame = false,
    }) async {
      var danmaku = DouyuDanmaku()..roomId = "63136";
      var out = <LiveMessage>[];
      danmaku.onMessage = out.add;
      if (oneFrame) {
        danmaku.decodeMessage([
          for (var raw in raws) ...danmaku.serializeDouyu(raw),
        ]);
      } else {
        for (var raw in raws) {
          danmaku.decodeMessage(danmaku.serializeDouyu(raw));
        }
      }
      // 礼物按顺序异步发出
      await Future.delayed(const Duration(milliseconds: 50));
      return out;
    }

    test('礼物和弹幕一起：弹幕照旧，礼物按道具查到图片', () async {
      DouyuRoomGifts.debugSet(
        "63136",
        parseDouyuRoomGiftList(fixture('douyu_gift_list_74751.json')),
      );
      var fetched = <String>[];
      DouyuPropGifts.debugFetch = (pid) async {
        fetched.add(pid);
        return fixture('douyu_prop_$pid.json');
      };
      var raws = messages();
      var out = await decode(raws);
      var chats = out.where((e) => e.type == LiveMessageType.chat).toList();
      expect(chats.single.userName, '用户E');
      expect(chats.single.message, '雪迷宫也好看');
      var gifts = out
          .where((e) => e.type == LiveMessageType.gift)
          .map((e) => e.data as LiveGiftMessage)
          .toList();
      expect(gifts, hasLength(9));
      // 每个道具只读一次
      expect(fetched, ['268', '3410']);
      expect(gifts.first.icon, isNotNull);
      expect(gifts.first.paid, isFalse);
      expect(gifts[7].giftName, '全力守护');
      expect(gifts[7].paid, isTrue);
      expect(gifts[8].giftName, '陪伴印章');
      expect(
        out.firstWhere((e) => e.type == LiveMessageType.gift).message,
        '赠送 粉丝荧光棒 ×153',
      );
    });

    test('一帧里有好几个包时都能解析', () async {
      DouyuPropGifts.debugFetch = (pid) async =>
          fixture('douyu_prop_$pid.json');
      var raws = messages();
      var out = await decode([raws.last, raws[7], raws.last], oneFrame: true);
      expect(out.where((e) => e.type == LiveMessageType.chat), hasLength(2));
      expect(out.where((e) => e.type == LiveMessageType.gift), hasLength(1));
    });

    test('道具读不到时照样发出，名称用 gfn', () async {
      DouyuPropGifts.debugFetch = (pid) async => throw StateError('offline');
      CoreLog.enableLog = false;
      addTearDown(() => CoreLog.enableLog = true);
      var out = await decode([messages()[8]]);
      var g = out.single.data as LiveGiftMessage;
      expect(g.giftName, '陪伴印章');
      expect(g.icon, isNull);
    });
  });
}
