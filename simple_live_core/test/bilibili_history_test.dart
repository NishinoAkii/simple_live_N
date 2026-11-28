import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

// 哔哩哔哩进直播间时的最近聊天（gethistory）：解析、按时间排、去重、标成历史消息。
// 全部离线：样本照 bilibili-API-collect 文档里的返回改的（uid、名字、头像、牌子都是假的）

Map fixture() => json.decode(
  File('test/fixtures/history/bilibili_gethistory.json').readAsStringSync(),
);

void main() {
  group('解析', () {
    test('房管的和观众的合在一起按时间排，同一条只留一次，都是历史消息', () {
      var list = parseBiliChatHistory(fixture());
      expect(list.map((e) => e.message), [
        '好帅',
        '赚麻了 哈哈',
        '下播啦~ 感谢大家的陪伴~ 下次见哦~',
        '你好[花][妙]',
        '哈哈',
      ]);
      expect(list.every((e) => e.history), isTrue);
      expect(list.every((e) => e.type == LiveMessageType.chat), isTrue);
      expect(list.every((e) => e.color == LiveMessageColor.white), isTrue);
      expect(list.first.userName, 'viewer_2');
      expect(list.first.userId, '10002');
    });

    test('身份：粉丝牌、等级、房管，和实时弹幕一样认', () {
      var list = parseBiliChatHistory(fixture());
      var bye = list[2];
      // 房管那份先到（同一时间时 admin 在前），留下的是它
      expect(bye.badges?.map((e) => e.kind), contains(LiveBadgeKind.admin));
      var medal = bye.badges!.firstWhere((e) => e.kind == LiveBadgeKind.medal);
      expect(medal.text, '牌子2');
      expect(medal.level, 21);
      expect(medal.ownerName, '主播2');
      expect(medal.ownerUid, '30002');
      expect(
        bye.badges!.where((e) => e.kind == LiveBadgeKind.level).map((e) => e.text),
        containsAll(['UL', '荣耀']),
      );
      // 没戴牌子的没有牌子
      expect(
        list.first.badges?.where((e) => e.kind == LiveBadgeKind.medal) ?? [],
        isEmpty,
      );
    });

    test('小表情和大表情', () {
      var list = parseBiliChatHistory(fixture());
      var emotes = list[3].emotes!;
      expect(emotes.map((e) => e.text), unorderedEquals(['[花]', '[妙]']));
      expect(emotes.first.url, startsWith('https://'));
      expect(list[3].sticker, isNull);
      var sticker = list[4].sticker!;
      expect(sticker.text, '哈哈');
      expect(sticker.url, startsWith('https://'));
      expect(sticker.width, 162);
      expect(list[4].emotes, isNull);
      // 普通的一句没有表情
      expect(list.first.sticker, isNull);
      expect(list.first.emotes, isNull);
    });

    test('出错、空的、格式不对时是空的', () {
      expect(parseBiliChatHistory({'code': -400, 'data': fixture()['data']}),
          isEmpty);
      expect(parseBiliChatHistory({'code': 0, 'data': {}}), isEmpty);
      expect(
        parseBiliChatHistory({
          'code': 0,
          'data': {'admin': null, 'room': null},
        }),
        isEmpty,
      );
      expect(parseBiliChatHistory('<html>'), isEmpty);
      expect(parseBiliChatHistory(null), isEmpty);
      // 没登录：uid 是 0，名字打了码，照样显示，只是没有 uid
      var masked = parseBiliChatHistory({
        'code': 0,
        'data': {
          'room': [
            {'text': '你好', 'uid': 0, 'nickname': '用***', 'medal': []},
            {'text': '你好', 'uid': 0, 'nickname': '用***', 'medal': []},
          ],
        },
      });
      // 没有 id_str、时间也一样：当成同一条
      expect(masked, hasLength(1));
      expect(masked.single.userId, isNull);
      expect(masked.single.userName, '用***');
    });
  });

  group('进直播间时显示在聊天区', () {
    BiliBiliDanmakuArgs args({int roomId = 1}) => BiliBiliDanmakuArgs(
      roomId: roomId,
      token: '',
      // 连不上的本机地址：测试不访问网络
      serverHost: '127.0.0.1:9',
      buvid: '',
      uid: 0,
      cookie: '',
    );

    test('按顺序交给 onMessage，都是历史消息（读回来的不是也标上）', () async {
      var danmaku = BiliBiliDanmaku();
      var out = <LiveMessage>[];
      danmaku.onMessage = out.add;
      danmaku.historyLoader = (_) async => [
        LiveMessage(
          type: LiveMessageType.chat,
          userName: 'a',
          message: '一',
          color: LiveMessageColor.white,
        ),
        ...parseBiliChatHistory(fixture()).take(1),
      ];
      await danmaku.loadHistory(args());
      expect(out.map((e) => e.message), ['一', '好帅']);
      expect(out.every((e) => e.history), isTrue);
    });

    test('读太久、出错、没有房号时什么都不显示', () async {
      var danmaku = BiliBiliDanmaku()
        ..historyTimeout = const Duration(milliseconds: 20);
      var out = <LiveMessage>[];
      danmaku.onMessage = out.add;
      var never = Completer<List<LiveMessage>>();
      danmaku.historyLoader = (_) => never.future;
      await danmaku.loadHistory(args());
      danmaku.historyLoader = (_) async => throw StateError('x');
      await danmaku.loadHistory(args());
      var calls = 0;
      danmaku.historyLoader = (_) async {
        calls++;
        return parseBiliChatHistory(fixture());
      };
      await danmaku.loadHistory(args(roomId: 0));
      expect(calls, 0);
      expect(out, isEmpty);
      // 没有 site 也没有 historyLoader：不读
      await BiliBiliDanmaku().loadHistory(args());
    });

    test('同一个直播间再读（刷新）不再显示；换了直播间照常读', () async {
      var danmaku = BiliBiliDanmaku();
      var out = <LiveMessage>[];
      danmaku.onMessage = out.add;
      var calls = 0;
      danmaku.historyLoader = (_) async {
        calls++;
        return parseBiliChatHistory(fixture()).take(2).toList();
      };
      await danmaku.loadHistory(args());
      await danmaku.loadHistory(args());
      expect(calls, 1);
      expect(out, hasLength(2));
      await danmaku.loadHistory(args(roomId: 2));
      expect(calls, 2);
      expect(out, hasLength(4));
    });

    test('读完时已经刷新或离开（不是这一次的）：不显示，下一次照常读', () async {
      var danmaku = BiliBiliDanmaku();
      var out = <LiveMessage>[];
      danmaku.onMessage = out.add;
      danmaku.historyLoader = (_) async => parseBiliChatHistory(fixture());
      await danmaku.loadHistory(args(), session: -1);
      expect(out, isEmpty);
      await danmaku.loadHistory(args());
      expect(out, hasLength(5));
    });

    test('读的时候离开了直播间：不再连弹幕', () async {
      var danmaku = BiliBiliDanmaku();
      var gate = Completer<List<LiveMessage>>();
      danmaku.historyLoader = (_) => gate.future;
      var starting = danmaku.start(args());
      await danmaku.stop();
      gate.complete(parseBiliChatHistory(fixture()));
      await starting;
      expect(danmaku.webScoketUtils, isNull);
    });
  });
}
