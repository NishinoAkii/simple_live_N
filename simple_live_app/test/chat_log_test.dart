import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/chat_log.dart';
import 'package:simple_live_app/widgets/tail_list_view.dart';
import 'package:simple_live_core/simple_live_core.dart';

LiveChatRecord record(int i) => LiveChatRecord(
      DateTime.fromMillisecondsSinceEpoch(1700000000000 + i * 1000),
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "user${i % 7}",
        message: "消息 $i",
        color: LiveMessageColor(i % 256, 128, 255 - i % 256),
      ),
    );

void expectRecord(LiveChatRecord actual, int i) {
  var expected = record(i);
  expect(actual.time, expected.time);
  expect(actual.message.userName, expected.message.userName);
  expect(actual.message.message, expected.message.message);
  expect(actual.message.color.toString(), expected.message.color.toString());
}

/// 只有部分消息有头像（如 YouTube 的聊天），每 3 条一条
String? faceOf(int i) =>
    i % 3 == 0 ? "https://yt3.ggpht.com/ytc/face$i=s64-c-k-nd" : null;

LiveChatRecord faceRecord(int i) {
  var base = record(i);
  return LiveChatRecord(
    base.time,
    LiveMessage(
      type: LiveMessageType.chat,
      userName: base.message.userName,
      message: base.message.message,
      color: base.message.color,
      face: faceOf(i),
    ),
  );
}

void expectFaceRecord(LiveChatRecord actual, int i) {
  expectRecord(actual, i);
  expect(actual.message.face, faceOf(i));
}

/// 记下写入的每一块，用来检查存储格式
class CapturingStore extends MemoryChunkStore {
  final List<Uint8List> written = [];

  @override
  Object? write(Uint8List bytes) {
    written.add(bytes);
    return super.write(bytes);
  }
}

void main() {
  group("ChatLog", () {
    test("keeps every message, older chunks round-trip through the store",
        () async {
      var log = ChatLog(chunkSize: 64, hotChunks: 2, cachedChunks: 2);
      for (var i = 0; i < 2000; i++) {
        log.add(record(i));
      }
      expect(log.length, 2000);
      for (var i = 0; i < 2000; i++) {
        expectRecord(log[i], i);
      }
      // 倒着读一遍，缓存反复换出换入
      for (var i = 1999; i >= 0; i -= 37) {
        expectRecord(log[i], i);
      }
      var found = await log.where((e) => e.message.userName == "user3");
      expect(found!.length,
          List.generate(2000, (i) => i % 7 == 3).where((e) => e).length);
      expect(found.first.message.message, "消息 3");
      expect(found.last.message.message, "消息 1998");
      log.clear();
      expect(log.length, 0);
      expect(await log.where((e) => true), isEmpty);
    });

    test("spills to a temp file and deletes it on dispose", () async {
      var dir = Directory.systemTemp.createTempSync("chat_log_test");
      addTearDown(() => dir.deleteSync(recursive: true));
      var log = ChatLog(
        store: FileChunkStore(() async => dir),
        chunkSize: 50,
        hotChunks: 1,
        cachedChunks: 1,
      );
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 1000; i++) {
        log.add(record(i));
      }
      var files = dir.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(files.single.lengthSync(), greaterThan(0));
      for (var i = 0; i < 1000; i++) {
        expectRecord(log[i], i);
      }
      log.clear();
      expect(dir.listSync(), isEmpty);
      // 清空后继续用，换一个新文件
      for (var i = 0; i < 200; i++) {
        log.add(record(i));
      }
      expectRecord(log[10], 10);
      expect(dir.listSync(), hasLength(1));
      log.dispose();
      expect(dir.listSync(), isEmpty);
    });

    test("keeps chunks in memory until the temp directory is ready", () async {
      var dir = Directory.systemTemp.createTempSync("chat_log_test");
      addTearDown(() => dir.deleteSync(recursive: true));
      var ready = Completer<Directory>();
      var log = ChatLog(
        store: FileChunkStore(() => ready.future),
        chunkSize: 10,
        hotChunks: 1,
      );
      for (var i = 0; i < 100; i++) {
        log.add(record(i));
      }
      expect(dir.listSync(), isEmpty);
      ready.complete(dir);
      await Future<void>.delayed(Duration.zero);
      for (var i = 100; i < 110; i++) {
        log.add(record(i));
      }
      expect(dir.listSync(), hasLength(1));
      for (var i = 0; i < 110; i++) {
        expectRecord(log[i], i);
      }
      log.dispose();
    });

    // 每条耗时 0.2ms，一块 2ms，扫几块就会让出一次
    bool slow(LiveChatRecord e) {
      var watch = Stopwatch()..start();
      while (watch.elapsedMicroseconds < 200) {}
      return true;
    }

    test("avatars round-trip through the store, rows without one stay short",
        () async {
      var store = CapturingStore();
      var log = ChatLog(
        store: store,
        chunkSize: 16,
        hotChunks: 1,
        cachedChunks: 1,
      );
      for (var i = 0; i < 200; i++) {
        log.add(faceRecord(i));
      }
      expect(store.written, isNotEmpty);
      for (var i = 0; i < 200; i++) {
        expectFaceRecord(log[i], i);
      }
      // 有头像的行多一项头像地址，没有头像的仍是原来的 4 项
      var rows = jsonDecode(utf8.decode(store.written.first)) as List;
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i] as List;
        expect(row.length, faceOf(i) == null ? 4 : 5);
        if (faceOf(i) != null) {
          expect(row[4], faceOf(i));
        }
      }
      var found = await log.where((e) => e.message.face != null);
      expect(found!.length, List.generate(200, faceOf).nonNulls.length);
    });

    test("avatars survive the temp file", () async {
      var dir = Directory.systemTemp.createTempSync("chat_log_test");
      addTearDown(() => dir.deleteSync(recursive: true));
      var log = ChatLog(
        store: FileChunkStore(() async => dir),
        chunkSize: 20,
        hotChunks: 1,
        cachedChunks: 1,
      );
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 300; i++) {
        log.add(faceRecord(i));
      }
      expect(dir.listSync().whereType<File>(), hasLength(1));
      // 倒着读，每块都从文件读回
      for (var i = 299; i >= 0; i--) {
        expectFaceRecord(log[i], i);
      }
      log.dispose();
      expect(dir.listSync(), isEmpty);
    });

    test("long searches yield, include new messages and can be cancelled",
        () async {
      var log = ChatLog(chunkSize: 10);
      for (var i = 0; i < 100; i++) {
        log.add(record(i));
      }
      // 让出时收到的新消息也要搜到
      Timer.run(() => log.add(record(100)));
      var result = await log.where(slow);
      expect(result, hasLength(101));
      expectRecord(result!.last, 100);

      expect(await log.where(slow, cancelled: () => true), isNull);
      var searching = log.where(slow);
      Timer.run(log.clear);
      expect(await searching, isNull);
    });
  });

  group("TailListView", () {
    // iOS、macOS 是回弹滚动，Windows、Android 是夹紧滚动，都要能用
    const platforms = TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.android,
    });

    late List<String> items;
    late TailListController list;

    Future<void> pumpList(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                height: 300,
                width: 200,
                child: TailListView(
                  controller: list,
                  itemBuilder: (_, i) =>
                      SizedBox(height: 20, child: Text(items[i])),
                ),
              ),
            ),
          ),
        ),
      );
    }

    void append(int n) {
      var start = items.length;
      items.addAll(List.generate(n, (i) => "item ${start + i}"));
      list.setLength(items.length);
    }

    setUp(() {
      items = [];
      list = TailListController();
    });

    testWidgets("short content stays at the top", (tester) async {
      await pumpList(tester);
      append(3);
      await tester.pump();
      expect(tester.getTopLeft(find.text("item 0")).dy, 0);
      expect(tester.getTopLeft(find.text("item 2")).dy, 40);
    }, variant: platforms);

    testWidgets("follows the newest at the bottom without building the rest",
        (tester) async {
      await pumpList(tester);
      append(5000);
      await tester.pump();
      expect(tester.getBottomLeft(find.text("item 4999")).dy, 300);
      expect(find.text("item 4000"), findsNothing);
      append(1);
      await tester.pump();
      expect(tester.getBottomLeft(find.text("item 5000")).dy, 300);
      expect(list.following.value, isTrue);
    }, variant: platforms);

    testWidgets("scrolling up stops following and new items do not move it",
        (tester) async {
      await pumpList(tester);
      append(500);
      await tester.pump();
      // 一次拖动中途切换成两段的布局，拖动不能断
      var gesture = await tester.startGesture(const Offset(100, 150));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(list.following.value, isFalse);
      var pixels = list.scrollController.position.pixels;
      expect(pixels, greaterThan(60));
      var y = tester.getTopLeft(find.text("item 490")).dy;
      append(30);
      await tester.pump();
      expect(tester.getTopLeft(find.text("item 490")).dy, y);
      expect(find.text("item 529"), findsNothing);

      list.jumpToLatest();
      await tester.pump();
      expect(list.following.value, isTrue);
      expect(tester.getBottomLeft(find.text("item 529")).dy, 300);
    }, variant: platforms);

    testWidgets("scrolling back to the bottom resumes following",
        (tester) async {
      await pumpList(tester);
      append(500);
      await tester.pump();
      await tester.drag(find.byType(TailListView), const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(list.following.value, isFalse);
      append(20);
      await tester.pump();
      await tester.drag(find.byType(TailListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(list.following.value, isTrue);
      append(1);
      await tester.pump();
      expect(tester.getBottomLeft(find.text("item 520")).dy, 300);
    }, variant: platforms);
  });
}
