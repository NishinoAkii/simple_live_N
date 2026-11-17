import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/player/danmaku_pacer.dart';

/// 测试里的时钟：跟着 tester.pump 前进
class FakeClock {
  int ms = 0;
  int call() => ms;
}

Future<void> advance(WidgetTester tester, FakeClock clock, int ms) async {
  for (var t = 0; t < ms; t += 16) {
    clock.ms += 16;
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 按录下来的到达时间喂给匀速器，记下每条什么时候放出
class Replay {
  final List<int> arrivals;

  /// 设置里的“弹幕缓冲增强”
  final bool smoothing;

  /// 设置里的“缓冲增强的起始弹幕量”（每秒几条）
  final double minRate;
  final List<int> outTimes = [];
  final List<int> delays = [];
  Replay(this.arrivals, {this.smoothing = true, this.minRate = 2});

  Future<void> run(WidgetTester tester, {int tail = 6000}) async {
    var clock = FakeClock();
    var pacer = DanmakuPacer<int>(
      (i) {
        outTimes.add(clock.ms);
        delays.add(clock.ms - arrivals[i]);
      },
      smoothing: () => smoothing,
      minRateOf: () => minRate,
      now: clock.call,
    );
    var next = 0;
    var end = arrivals.last + tail;
    while (clock.ms < end) {
      var tickAt = clock.ms + 16;
      // 两次计时之间到的消息，按它们各自的时间加进去
      while (next < arrivals.length && arrivals[next] <= tickAt) {
        clock.ms = arrivals[next];
        pacer.add(next++);
      }
      clock.ms = tickAt;
      await tester.pump(const Duration(milliseconds: 16));
    }
    pacer.clear();
  }

  /// [from, to) 这段时间里，相邻两条之间最长隔了多久
  static int longestGap(List<int> times, int from, int to) {
    var inside = times.where((t) => t >= from && t < to).toList();
    var longest = 0;
    for (var i = 1; i < inside.length; i++) {
      if (inside[i] - inside[i - 1] > longest) {
        longest = inside[i] - inside[i - 1];
      }
    }
    return longest;
  }

  /// 每 250 毫秒一格，[from, to) 里一条都没有的格子数
  static int emptyBins(List<int> times, int from, int to) {
    var bins = <int>{for (var t in times) t ~/ 250};
    var empty = 0;
    for (var b = from ~/ 250; b < to ~/ 250; b++) {
      if (!bins.contains(b)) empty++;
    }
    return empty;
  }

  /// 每 250 毫秒一格，[from, to) 里每格放出了几条
  static List<int> binCounts(List<int> times, int from, int to) {
    var counts = List.filled((to - from) ~/ 250, 0);
    for (var t in times) {
      var b = (t - from) ~/ 250;
      if (t >= from && b < counts.length) counts[b]++;
    }
    return counts;
  }

  int get maxDelay => delays.reduce((a, b) => a > b ? a : b);
  int get medianDelay => (delays.toList()..sort())[delays.length ~/ 2];

  /// [from] 之后到达的那些，最多晚了多久
  int maxDelayAfter(int from) {
    var worst = 0;
    for (var i = 0; i < outTimes.length; i++) {
      var arrived = outTimes[i] - delays[i];
      if (arrived >= from && delays[i] > worst) worst = delays[i];
    }
    return worst;
  }
}

List<int> fixture(String name) => File("test/fixtures/$name")
    .readAsLinesSync()
    .where((l) => l.isNotEmpty && !l.startsWith("#"))
    .map(int.parse)
    .toList();

/// 一阵一阵的到达：[on] 毫秒里每 [every] 毫秒一条，接着 [off] 毫秒没有
List<int> waves({
  required int every,
  required int on,
  required int off,
  required int seconds,
}) =>
    [
      for (var start = 0; start < seconds * 1000; start += on + off)
        for (var t = start; t < start + on; t += every) t,
    ];

void main() {
  testWidgets("零星的弹幕马上上屏，不加延迟", (tester) async {
    var clock = FakeClock();
    var out = <int>[];
    var pacer = DanmakuPacer<int>(out.add, now: clock.call);
    pacer.add(1);
    expect(out, [1]);
    await advance(tester, clock, 2000);
    pacer.add(2);
    expect(out, [1, 2]);
    await advance(tester, clock, 700);
    pacer.add(3);
    expect(out, [1, 2, 3], reason: "聊天不多时不匀");
    pacer.clear();
  });

  testWidgets("一批同时到的错开放出，不排成一竖列", (tester) async {
    var clock = FakeClock();
    var out = <int>[];
    var times = <int>[];
    var pacer = DanmakuPacer<int>((v) {
      out.add(v);
      times.add(clock.ms);
    }, now: clock.call);
    for (var i = 0; i < 30; i++) {
      pacer.add(i);
    }
    expect(out, [0]);
    await advance(tester, clock, 4500);
    expect(out, List.generate(30, (i) => i), reason: "顺序不变，全部放出");
    expect(times.toSet().length, greaterThan(20), reason: "分到了很多个时刻");
    // 刚进直播间按 3 秒的窗口匀
    expect(times.last, lessThanOrEqualTo(3400));
    pacer.clear();
  });

  testWidgets("一阵一阵地来（60 条/秒来 2 秒、停 1.5 秒）：从头一次空档起就匀速放出", (tester) async {
    var arrivals = waves(every: 17, on: 2000, off: 1500, seconds: 40);
    var replay = Replay(arrivals);
    await replay.run(tester);
    var end = arrivals.last;
    // 到达：一格 15 条左右，接着六格是空的
    var arriving = Replay.binCounts(arrivals, 8000, 36000);
    expect(arriving.reduce((a, b) => a > b ? a : b), greaterThanOrEqualTo(14));
    expect(Replay.longestGap(arrivals, 1000, end), greaterThan(1400));
    // 放出：全部放出；从第 1 秒算起（包括头一次空档）没有断过
    expect(replay.outTimes.length, arrivals.length);
    expect(Replay.longestGap(replay.outTimes, 1000, end), lessThan(200));
    expect(Replay.emptyBins(replay.outTimes, 1000, end), 0);
    // 认出周期以后是匀速的：每四分之一秒 8 条左右，不是忽多忽少
    var leaving = Replay.binCounts(replay.outTimes, 8000, 36000);
    expect(leaving.reduce((a, b) => a < b ? a : b), greaterThanOrEqualTo(6));
    expect(leaving.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(11));
    // 最多晚一个窗口（4 秒）
    expect(replay.maxDelay, lessThanOrEqualTo(4200));
    expect(replay.medianDelay, lessThan(1800));
  });

  testWidgets("关了缓冲增强：到了就放，空档照旧", (tester) async {
    var arrivals = waves(every: 17, on: 2000, off: 1500, seconds: 20);
    var replay = Replay(arrivals, smoothing: false);
    await replay.run(tester);
    expect(replay.outTimes.length, arrivals.length);
    // 只把挤在一起的稍微错开，不攒
    expect(replay.maxDelay, lessThanOrEqualTo(300));
    expect(
      Replay.longestGap(replay.outTimes, 1000, arrivals.last),
      greaterThan(1400),
    );
  });

  testWidgets("Twitch 大直播间的真实记录：2 秒有、1～2 秒没有，放出来不断流", (tester) async {
    // 13 条/秒，40 秒里有 12 次 0.8～2.1 秒的空档（服务器就是这样发的）
    var arrivals = fixture("chat_arrivals_waves.txt");
    var replay = Replay(arrivals);
    await replay.run(tester);
    var end = arrivals.last;
    // 原始数据：空档确实很长
    expect(Replay.longestGap(arrivals, 1000, end), greaterThan(1800));
    expect(Replay.emptyBins(arrivals, 1000, end), greaterThan(40));
    // 全部放出
    expect(replay.outTimes.length, arrivals.length);
    // 从第 1 秒算起：最长只隔几百毫秒，几乎没有空着的四分之一秒
    expect(Replay.longestGap(replay.outTimes, 1000, end), lessThan(600));
    expect(Replay.emptyBins(replay.outTimes, 1000, end), lessThanOrEqualTo(2));
    // 代价：晚一两秒，最多一个窗口
    expect(replay.maxDelay, lessThanOrEqualTo(4200));
    expect(replay.medianDelay, lessThan(1800));
  });

  testWidgets("另一个直播间的真实记录：头一次长空档在第 17 秒，也不断流", (tester) async {
    // 9 条/秒，长空档有 1.6 秒、1.3 秒和 2.2 秒的
    var arrivals = fixture("chat_arrivals_mixed.txt");
    var replay = Replay(arrivals);
    await replay.run(tester);
    expect(replay.outTimes.length, arrivals.length);
    expect(replay.maxDelay, lessThanOrEqualTo(4200));
    var end = arrivals.last;
    expect(Replay.longestGap(arrivals, 1000, end), greaterThan(2000));
    expect(Replay.emptyBins(arrivals, 1000, end), greaterThan(30));
    expect(Replay.longestGap(replay.outTimes, 1000, end), lessThan(900));
    expect(Replay.emptyBins(replay.outTimes, 1000, end), lessThanOrEqualTo(6));
  });

  testWidgets("消息本来就连续：刚进去晚一点，之后回到几乎不延迟", (tester) async {
    // 每 40 毫秒一条（25 条/秒），没有空档
    var arrivals = [for (var t = 0; t < 45000; t += 40) t];
    var replay = Replay(arrivals);
    await replay.run(tester, tail: 2000);
    expect(replay.outTimes.length, arrivals.length);
    // 前 20 多秒按 3 秒的窗口匀，晚一秒多
    expect(replay.maxDelay, lessThanOrEqualTo(2000));
    // 储备放完以后（第 30 秒起）到了就放
    expect(replay.maxDelayAfter(30000), lessThanOrEqualTo(150));
    expect(Replay.longestGap(replay.outTimes, 1000, 45000), lessThan(200));
  });

  testWidgets("弹幕少于起始量时不缓冲；起始量可以改", (tester) async {
    // 平均每秒 5 条左右：来 2 秒（每 100 毫秒一条）、停 1.5 秒
    var arrivals = waves(every: 100, on: 2000, off: 1500, seconds: 30);

    Future<Replay> run(double threshold) async {
      var replay = Replay(arrivals, minRate: threshold);
      await replay.run(tester);
      expect(replay.outTimes.length, arrivals.length);
      return replay;
    }

    // 起始量每秒 8 条：到了就放，空档照旧
    var off = await run(8);
    expect(off.maxDelay, lessThanOrEqualTo(150));
    expect(
      Replay.longestGap(off.outTimes, 1000, arrivals.last),
      greaterThan(1400),
    );
    // 起始量调到每秒 3 条：缓冲，空档被填上。离起始量不远的直播间要一秒多才认出来，
    // 头一次空档只能填上一部分，看认出来以后的
    var on = await run(3);
    expect(
      Replay.longestGap(on.outTimes, 8000, arrivals.last),
      lessThan(600),
    );
    expect(on.medianDelay, greaterThan(500));
  });

  testWidgets("在起始量上下晃：到了才开始，掉到七成以下才停", (tester) async {
    var clock = FakeClock();
    var pacer = DanmakuPacer<int>((_) {}, minRate: 10, now: clock.call);

    Future<void> feed(int perSecond, int seconds) async {
      var every = 1000 ~/ perSecond;
      for (var t = 0; t < seconds * 1000; t += every) {
        pacer.add(0);
        await advance(tester, clock, every);
      }
    }

    await feed(8, 10);
    expect(pacer.busy, isFalse, reason: "每秒 8 条，没到 10 条");
    await feed(12, 10);
    expect(pacer.busy, isTrue, reason: "每秒 12 条，开始缓冲");
    await feed(8, 10);
    expect(pacer.busy, isTrue, reason: "回到每秒 8 条，还在七成以上，不停");
    await feed(5, 10);
    expect(pacer.busy, isFalse, reason: "掉到每秒 5 条，停");
    pacer.clear();
  });

  testWidgets("flush：排着队的马上全放出来，顺序不变", (tester) async {
    var clock = FakeClock();
    var out = <int>[];
    var pacer = DanmakuPacer<int>(out.add, now: clock.call);
    for (var i = 0; i < 20; i++) {
      pacer.add(i);
    }
    expect(out.length, lessThan(5));
    pacer.flush();
    expect(out, List.generate(20, (i) => i));
    expect(pacer.pending, 0);
    // 放完以后照常工作
    await advance(tester, clock, 500);
    pacer.add(20);
    await advance(tester, clock, 4000);
    expect(out.last, 20);
    pacer.clear();
  });

  testWidgets("聊天停了很久再来：不当成节奏，马上放", (tester) async {
    var clock = FakeClock();
    var out = <int>[];
    var pacer = DanmakuPacer<int>(out.add, now: clock.call);
    for (var i = 0; i < 40; i++) {
      pacer.add(i);
      await advance(tester, clock, 48);
    }
    await advance(tester, clock, 10000);
    expect(out.length, 40);
    pacer.add(100);
    expect(out.last, 100);
    expect(pacer.window, 0);
    pacer.clear();
  });

  testWidgets("积压太多时丢掉最早的；清空后不再放出", (tester) async {
    var clock = FakeClock();
    var out = <int>[];
    var pacer = DanmakuPacer<int>(out.add, maxQueue: 10, now: clock.call);
    for (var i = 0; i < 50; i++) {
      pacer.add(i);
    }
    expect(pacer.pending, 10);
    pacer.clear();
    await advance(tester, clock, 1000);
    expect(out, [0]);
  });
}
