import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/danmaku_delay.dart';

/// 测试里的时钟：和 tester.pump 一起往前走
class Clock {
  int ms = 0;
  int call() => ms;
}

/// 一个延迟队列和它放出的东西：（内容，放出的时间）
class Harness {
  final Clock clock = Clock();
  int delay;
  final List<(String, int)> out = [];
  late final DanmakuDelayQueue<String> queue = DanmakuDelayQueue<String>(
    (item) => out.add((item, clock.ms)),
    delayMs: () => delay,
    now: clock.call,
    maxQueue: maxQueue,
  );
  final int maxQueue;
  Harness(this.delay, {this.maxQueue = 5000});

  /// 时钟和计时器一起往前走 [ms] 毫秒，每次 1 毫秒，放出的时间就是准的
  Future<void> advance(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms; i++) {
      clock.ms++;
      await tester.pump(const Duration(milliseconds: 1));
    }
  }

  List<String> get items => [for (var e in out) e.$1];
}

void main() {
  testWidgets("延迟是 0：马上放出，不开计时器", (tester) async {
    var h = Harness(0);
    h.queue.add("a");
    h.queue.add("b");
    expect(h.items, ["a", "b"]);
    expect(h.queue.timerActive, isFalse);
    expect(h.queue.timersStarted, 0);
  });

  testWidgets("按到达的先后、到时间才放出", (tester) async {
    var h = Harness(1500);
    h.queue.add("a");
    await h.advance(tester, 100);
    h.queue.add("b");
    await h.advance(tester, 100);
    h.queue.add("c");
    await h.advance(tester, 1200);
    expect(h.out, isEmpty);
    await h.advance(tester, 100);
    expect(h.out, [("a", 1500)]);
    await h.advance(tester, 300);
    expect(h.out, [("a", 1500), ("b", 1600), ("c", 1700)]);
    expect(h.queue.pending, 0);
    expect(h.queue.timerActive, isFalse);
  });

  testWidgets("自己发的不延迟，直接放出，不等前面排着的", (tester) async {
    var h = Harness(2000);
    h.queue.add("别人");
    await h.advance(tester, 10);
    h.queue.add("自己", immediate: true);
    expect(h.out, [("自己", 10)]);
    await h.advance(tester, 2000);
    expect(h.items, ["自己", "别人"]);
  });

  testWidgets("同时只有一个计时器：大直播间每秒 300 条也不是每条一个", (tester) async {
    var h = Harness(2000);
    var sent = 0;
    // 5 秒，每 3～4 毫秒一条
    for (var t = 0; t < 5000; t++) {
      if (t % 10 == 0 || t % 10 == 3 || t % 10 == 6) {
        h.queue.add("m${sent++}");
      }
      await h.advance(tester, 1);
    }
    await h.advance(tester, 2100);
    expect(sent, 1500);
    expect(h.out.length, 1500);
    // 顺序不变，每条都晚了 2 秒左右（最多再晚一个最小间隔）
    for (var i = 0; i < h.out.length; i++) {
      expect(h.out[i].$1, "m$i");
    }
    // 7 秒里最多每 16 毫秒定一次
    expect(h.queue.timersStarted, lessThan(7100 ~/ 16 + 5));
    expect(h.queue.timersStarted, lessThan(sent ~/ 3));
  });

  testWidgets("放出的时间：到时间以后最多晚一个最小间隔", (tester) async {
    var h = Harness(1000);
    var arrivals = <int>[];
    for (var t = 0; t < 3000; t++) {
      if (t % 7 == 0) {
        arrivals.add(h.clock.ms);
        h.queue.add("m${arrivals.length - 1}");
      }
      await h.advance(tester, 1);
    }
    await h.advance(tester, 1100);
    expect(h.out.length, arrivals.length);
    for (var i = 0; i < h.out.length; i++) {
      var late = h.out[i].$2 - arrivals[i];
      expect(late, greaterThanOrEqualTo(1000), reason: "第 $i 条");
      expect(late, lessThanOrEqualTo(1000 + 16), reason: "第 $i 条");
    }
  });

  testWidgets("调小延迟：下一条进来时排着的已经到时间的一起放出，顺序不变", (tester) async {
    var h = Harness(3000);
    h.queue.add("a");
    await h.advance(tester, 500);
    h.queue.add("b");
    await h.advance(tester, 500);
    h.delay = 200;
    h.queue.add("c");
    // a、b 已经超过 200 毫秒，马上放出；c 还要等
    expect(h.items, ["a", "b"]);
    await h.advance(tester, 250);
    expect(h.items, ["a", "b", "c"]);
  });

  testWidgets("调成 0：排着的和新来的按顺序马上放出", (tester) async {
    var h = Harness(3000);
    h.queue.add("a");
    h.queue.add("b");
    await h.advance(tester, 10);
    h.delay = 0;
    h.queue.add("c");
    expect(h.items, ["a", "b", "c"]);
    expect(h.queue.pending, 0);
  });

  testWidgets("调大延迟：计时器到点时还没到时间，再往后定，不会提前放出", (tester) async {
    var h = Harness(500);
    h.queue.add("a");
    await h.advance(tester, 100);
    h.delay = 2000;
    await h.advance(tester, 1000);
    expect(h.out, isEmpty);
    await h.advance(tester, 920);
    expect(h.items, ["a"]);
    expect(h.out.single.$2, inInclusiveRange(2000, 2016));
  });

  testWidgets("换直播间时清空：排着的不再放出，计时器停掉", (tester) async {
    var h = Harness(1000);
    for (var i = 0; i < 20; i++) {
      h.queue.add("旧$i");
    }
    expect(h.queue.timerActive, isTrue);
    await h.advance(tester, 500);
    h.queue.clear();
    expect(h.queue.pending, 0);
    expect(h.queue.timerActive, isFalse);
    await h.advance(tester, 2000);
    expect(h.out, isEmpty);
    // 清空以后照常工作
    h.queue.add("新");
    await h.advance(tester, 1000);
    expect(h.items, ["新"]);
  });

  testWidgets("积压超过上限时丢掉最早的", (tester) async {
    var h = Harness(5000, maxQueue: 50);
    for (var i = 0; i < 80; i++) {
      h.queue.add("m$i");
    }
    expect(h.queue.pending, 50);
    await h.advance(tester, 5020);
    expect(h.out.length, 50);
    expect(h.out.first.$1, "m30");
    expect(h.out.last.$1, "m79");
  });

  testWidgets("放出时清空（比如放出的回调里关了直播间）不出错", (tester) async {
    var h = Harness(100);
    late DanmakuDelayQueue<int> queue;
    var out = <int>[];
    queue = DanmakuDelayQueue<int>(
      (i) {
        out.add(i);
        if (i == 1) queue.clear();
      },
      delayMs: () => 100,
      now: h.clock.call,
    );
    for (var i = 0; i < 5; i++) {
      queue.add(i);
    }
    await h.advance(tester, 200);
    expect(out, [0, 1]);
    expect(queue.timerActive, isFalse);
  });
}
