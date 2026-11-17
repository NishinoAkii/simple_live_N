import 'dart:async';

import 'package:simple_live_core/src/common/online_poller.dart';
import 'package:test/test.dart';

void main() {
  test("读到的在线人数发出去；读不到、0 和出错都不发", () async {
    var results = <Object?>[1234, null, 0, StateError("断网"), 1300];
    var out = <int>[];
    var poller = OnlinePoller(
      read: () async {
        var next = results.removeAt(0);
        if (next is Error) throw next;
        return next as int?;
      },
      onOnline: out.add,
    );
    for (var i = 0; i < 5; i++) {
      await poller.poll();
    }
    expect(out, [1234, 1300]);
  });

  test("停了以后才回来的结果不要", () async {
    var pending = Completer<int?>();
    var out = <int>[];
    var poller = OnlinePoller(read: () => pending.future, onOnline: out.add);
    var poll = poller.poll();
    poller.stop();
    pending.complete(99);
    await poll;
    expect(out, isEmpty);
  });

  test("按间隔定时读，停了就不再读", () async {
    var reads = 0;
    var poller = OnlinePoller(
      read: () async => ++reads,
      onOnline: (_) {},
      interval: const Duration(milliseconds: 20),
    )..start();
    await Future.delayed(const Duration(milliseconds: 110));
    poller.stop();
    var seen = reads;
    expect(seen, greaterThanOrEqualTo(2));
    await Future.delayed(const Duration(milliseconds: 60));
    expect(reads, seen);
  });
}
