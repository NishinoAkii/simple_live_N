import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/chat_log.dart';
import 'package:simple_live_app/widgets/live_badges.dart';
import 'package:simple_live_app/widgets/tail_list_view.dart';
import 'package:simple_live_core/simple_live_core.dart';

LiveChatRecord chat(int i, {List<LiveBadge>? badges}) => LiveChatRecord(
      DateTime.fromMillisecondsSinceEpoch(1000000 + i),
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "user$i",
        message: "消息 $i",
        color: LiveMessageColor.white,
        badges: badges,
      ),
    );

void main() {
  group("聊天记录存到临时文件后", () {
    test("发言人身份、表情、大表情都还在", () {
      var log = ChatLog(chunkSize: 4, hotChunks: 0, cachedChunks: 0);
      const badges = [
        LiveBadge(LiveBadgeKind.guard, "舰长", level: 3, icon: "https://i/g3"),
        LiveBadge(
          LiveBadgeKind.medal,
          "甜心",
          level: 21,
          color: 0x5896de,
          ownerName: "主播乙",
          ownerRoomId: "30000002",
          ownerUid: "20000002",
        ),
        LiveBadge(LiveBadgeKind.admin, "房管"),
      ];
      log.add(LiveChatRecord(
        DateTime.fromMillisecondsSinceEpoch(5),
        LiveMessage(
          type: LiveMessageType.chat,
          userName: "a",
          message: "你好[比心]",
          color: LiveMessageColor.white,
          badges: badges,
          emotes: const [
            LiveEmote(text: "[比心]", url: "https://e/1", width: 20, height: 20),
          ],
        ),
      ));
      log.add(LiveChatRecord(
        DateTime.fromMillisecondsSinceEpoch(6),
        LiveMessage(
          type: LiveMessageType.chat,
          userName: "b",
          message: "大表情",
          color: LiveMessageColor.white,
          sticker: const LiveEmote(text: "大表情", url: "https://e/2"),
        ),
      ));
      log.add(chat(3));
      log.add(chat(4));
      log.add(chat(5)); // 封存第一块，转存出去
      var first = log[0].message;
      expect(first.badges, badges);
      // 粉丝牌是哪个主播的也在（重新建的对象，不是原来那个）
      expect(identical(first.badges![1], badges[1]), isFalse);
      expect(first.badges![1].ownerName, "主播乙");
      expect(first.badges![1].ownerRoomId, "30000002");
      expect(first.badges![1].ownerUid, "20000002");
      expect(first.badges![2].hasOwner, isFalse);
      expect(first.emotes!.single.text, "[比心]");
      expect(first.emotes!.single.width, 20);
      expect(log[1].message.sticker!.url, "https://e/2");
      expect(log[2].message.badges, isNull);
    });
  });

  group("保留的弹幕条数", () {
    test("超出时整块丢掉最早的，通知列表平移，顺序不乱", () {
      var dropped = <int>[];
      var log = ChatLog(
        chunkSize: 10,
        hotChunks: 1,
        cachedChunks: 1,
        maxCount: 25,
        onTrimmed: dropped.add,
      );
      for (var i = 0; i < 100; i++) {
        log.add(chat(i));
      }
      // 留下的不少于 25 条，最多再多出不到一块
      expect(log.length, greaterThanOrEqualTo(25));
      expect(log.length, lessThan(35));
      expect(dropped.every((n) => n % 10 == 0), isTrue);
      expect(dropped.fold<int>(0, (a, b) => a + b) + log.length, 100);
      var oldest = 100 - log.length;
      for (var i = 0; i < log.length; i++) {
        expect(log[i].message.message, "消息 ${oldest + i}");
      }
    });

    test("0 为不限，一条都不丢", () {
      var log = ChatLog(chunkSize: 10, hotChunks: 1, maxCount: 0);
      for (var i = 0; i < 500; i++) {
        log.add(chat(i));
      }
      expect(log.length, 500);
      expect(log[0].message.message, "消息 0");
    });

    test("改小上限后，下一块封存时生效", () {
      var log = ChatLog(chunkSize: 10, hotChunks: 1, maxCount: 0);
      for (var i = 0; i < 200; i++) {
        log.add(chat(i));
      }
      log.maxCount = 50;
      for (var i = 200; i < 210; i++) {
        log.add(chat(i));
      }
      expect(log.length, lessThan(60));
      expect(log[log.length - 1].message.message, "消息 209");
    });

    test("搜索进行中丢掉了前面的块：不出错，后面的照样找到", () async {
      var log = ChatLog(chunkSize: 10, hotChunks: 1, maxCount: 0);
      for (var i = 0; i < 2000; i++) {
        log.add(chat(i));
      }
      var search = log.where((e) => e.message.message.endsWith("7"));
      log.maxCount = 100;
      for (var i = 2000; i < 2020; i++) {
        log.add(chat(i));
      }
      var found = await search;
      expect(found, isNotNull);
      expect(found!.last.message.message, "消息 2017");
      var texts = found.map((e) => e.message.message).toList();
      expect(texts.toSet().length, texts.length, reason: "没有重复");
    });

    test("临时文件分段：整段都丢掉后删掉文件", () async {
      var dir = Directory.systemTemp.createTempSync("chat_keep_test");
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      var log = ChatLog(
        store: FileChunkStore(() async => dir, 2),
        chunkSize: 10,
        hotChunks: 1,
        cachedChunks: 1,
        maxCount: 30,
      );
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 400; i++) {
        log.add(chat(i));
      }
      var files = dir.listSync().whereType<File>().length;
      // 40 块里只留 3~4 块，每个文件 2 块：留下的文件很少
      expect(files, lessThanOrEqualTo(3));
      var oldest = 400 - log.length;
      for (var i = 0; i < log.length; i++) {
        expect(log[i].message.message, "消息 ${oldest + i}");
      }
      log.dispose();
      expect(dir.listSync(), isEmpty);
    });
  });

  test("列表平移：总数和分界一起前移", () {
    var c = TailListController();
    c.setLength(100);
    c.dropFront(30);
    expect(c.length, 70);
    c.dropFront(500);
    expect(c.length, 0);
    c.dispose();
  });

  testWidgets("身份标签的文字", (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: LiveBadgeChips([
          LiveBadge(LiveBadgeKind.medal, "甜心", level: 21),
          LiveBadge(LiveBadgeKind.subscriber, "订阅", level: 14),
          LiveBadge(LiveBadgeKind.admin, "房管"),
          LiveBadge(LiveBadgeKind.level, "UL", level: 30),
        ]),
      ),
    ));
    expect(find.text("甜心"), findsOneWidget);
    expect(find.text("21"), findsOneWidget);
    expect(find.text("订阅 14 个月"), findsOneWidget);
    expect(find.text("房管"), findsOneWidget);
    expect(find.text("UL 30"), findsOneWidget);
  });
}
