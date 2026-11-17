import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/catch_up_policy.dart';

void main() {
  ({double rate, bool catchingUp}) decide(double ahead,
          {double target = 2, double max = 2, bool catching = false}) =>
      CatchUpPolicy.decide(
        ahead: ahead,
        target: target,
        maxRate: max,
        catchingUp: catching,
      );

  test('stays at 1x near the target and does not start within the margin', () {
    expect(decide(1.0).rate, 1.0);
    expect(decide(2.9).rate, 1.0);
    expect(decide(2.9).catchingUp, isFalse);
  });

  test('speeds up proportionally, rounded to 0.01', () {
    var d = decide(3.5);
    expect(d.catchingUp, isTrue);
    expect(d.rate, 1.3);
    expect(decide(3.06).rate, 1.21);
  });

  test('never exceeds the configured maximum', () {
    expect(decide(30).rate, 2.0);
    expect(decide(30, max: 1.37).rate, 1.37);
  });

  test('keeps catching up until back at the target, then returns to 1x', () {
    expect(decide(2.5, catching: true).rate, 1.1);
    expect(decide(2.05, catching: true).rate, 1.01);
    var d = decide(2.0, catching: true);
    expect(d.catchingUp, isFalse);
    expect(d.rate, 1.0);
  });

  group('BufferFloor', () {
    var t0 = DateTime(2026, 10, 23, 20);

    test('HLS sawtooth (4.2 s segments) stays below the start threshold', () {
      var floor = BufferFloor();
      // a segment lands every 4.2 s: buffer jumps to ~5.2 s, then drains to ~1 s
      for (var i = 0; i <= 40; i++) {
        var t = i * 0.5;
        var ahead = 5.2 - (t % 4.2);
        floor.add(ahead,
            now: t0.add(Duration(milliseconds: (t * 1000).round())));
      }
      var now = t0.add(const Duration(seconds: 20));
      var value = floor.floor(now: now)!;
      expect(value, lessThan(1.2));
      // the old per-sample decision would have sped up at the peaks
      expect(decide(5.2).catchingUp, isTrue);
      expect(decide(value).catchingUp, isFalse);
    });

    test('a steadily high buffer (FLV) still triggers catch-up', () {
      var floor = BufferFloor();
      for (var i = 0; i <= 20; i++) {
        floor.add(6.0 + (i.isEven ? 0.2 : 0),
            now: t0.add(Duration(milliseconds: i * 500)));
      }
      var value = floor.floor(now: t0.add(const Duration(seconds: 10)))!;
      expect(value, closeTo(6.0, 1e-9));
      expect(decide(value).catchingUp, isTrue);
    });

    test('needs half a window of samples, forgets old ones', () {
      var floor = BufferFloor();
      floor.add(9, now: t0);
      expect(floor.floor(now: t0.add(const Duration(seconds: 2))), isNull);
      floor.add(3, now: t0.add(const Duration(seconds: 6)));
      expect(floor.floor(now: t0.add(const Duration(seconds: 6))), 3);
      floor.add(4, now: t0.add(const Duration(seconds: 20)));
      // samples older than 10 s are dropped
      expect(floor.floor(now: t0.add(const Duration(seconds: 20))), isNull);
      floor.clear();
      expect(floor.floor(now: t0), isNull);
    });
  });

  test("HLS keeps at least one segment of buffer as the target", () {
    expect(CatchUpPolicy.targetFor(2.0, hls: true), CatchUpPolicy.hlsMinTarget);
    expect(CatchUpPolicy.targetFor(6.0, hls: true), 6.0);
    expect(CatchUpPolicy.targetFor(2.0, hls: false), 2.0);
  });
}
