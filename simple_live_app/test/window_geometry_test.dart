import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/window_geometry.dart';
import 'package:simple_live_app/app/window_memory.dart';
import 'package:simple_live_app/services/sync_compat.dart';

/// 记住窗口的位置规则。坐标都是物理像素：
/// 主屏 1920×1080、100%，任务栏 40；副屏在右边 3840×2160、150%，任务栏 60
const primary = DisplayArea(Rect.fromLTWH(0, 0, 1920, 1040), 1.0);
const secondary = DisplayArea(Rect.fromLTWH(1920, 0, 3840, 2100), 1.5);
const both = [primary, secondary];

void main() {
  group("在不在屏幕上", () {
    test("整个在主屏、整个在副屏、跨在两块中间：都算在", () {
      expect(
          WindowGeometry.isReachable(
              const Rect.fromLTWH(100, 100, 1280, 720), both),
          isTrue);
      expect(
          WindowGeometry.isReachable(
              const Rect.fromLTWH(2400, 300, 1920, 1080), both),
          isTrue);
      expect(
          WindowGeometry.isReachable(
              const Rect.fromLTWH(1500, 200, 1280, 720), both),
          isTrue);
    });

    test("拔了副屏：原来在副屏上的不在了", () {
      expect(
          WindowGeometry.isReachable(
              const Rect.fromLTWH(2400, 300, 1920, 1080), [primary]),
          isFalse);
    });

    test("标题栏露出来的太少（只剩一小角、只有窗口下半截在屏幕上）不算", () {
      // 右边只露出 50 像素
      expect(
          WindowGeometry.isReachable(
              const Rect.fromLTWH(1870, 100, 1280, 720), [primary]),
          isFalse);
      // 标题栏在屏幕上面看不到的地方
      expect(
          WindowGeometry.isReachable(
              const Rect.fromLTWH(100, -400, 1280, 720), [primary]),
          isFalse);
      // 窗口在任务栏下面
      expect(
          WindowGeometry.isReachable(
              const Rect.fromLTWH(100, 1045, 1280, 720), [primary]),
          isFalse);
      // 露出 200 像素宽的标题栏：拖得回来
      expect(
          WindowGeometry.isReachable(
              const Rect.fromLTWH(1720, 100, 1280, 720), [primary]),
          isTrue);
    });

    test("重叠最多的那块屏幕", () {
      expect(
          WindowGeometry.displayOf(
              const Rect.fromLTWH(1500, 200, 1280, 720), both),
          secondary);
      expect(
          WindowGeometry.displayOf(
              const Rect.fromLTWH(1000, 200, 1280, 720), both),
          primary);
      expect(
          WindowGeometry.displayOf(
              const Rect.fromLTWH(-3000, 0, 100, 100), both),
          isNull);
    });
  });

  group("恢复", () {
    test("还在屏幕上：放回原处，大小不变", () {
      var saved =
          const WindowPlacement(Rect.fromLTWH(2400, 300, 1920, 1080), 1.5);
      var (rect, display) = WindowGeometry.restore(saved, both, primary);
      expect(rect, saved.rect);
      expect(display, secondary);
    });

    test("副屏拔了：放到主屏正中间，逻辑大小不变（150% 下 1920×1080 → 100% 下 1280×720）", () {
      var saved =
          const WindowPlacement(Rect.fromLTWH(2400, 300, 1920, 1080), 1.5);
      var (rect, display) = WindowGeometry.restore(saved, [primary], primary);
      expect(display, primary);
      expect(rect.size, const Size(1280, 720));
      expect(rect.center, primary.work.center);
    });

    test("从主屏挪到副屏的反方向：100% 下 1280×720 到 150% 屏上是 1920×1080", () {
      var size = WindowGeometry.convertSize(const Size(1280, 720), 1.0, 1.5);
      expect(size, const Size(1920, 1080));
      expect(WindowGeometry.convertSize(size, 1.5, 1.0), const Size(1280, 720));
    });

    test("屏幕的缩放后来改了（记下时 100%，现在 150%）：左上角不动，按逻辑大小换算", () {
      var saved = const WindowPlacement(Rect.fromLTWH(100, 100, 800, 600), 1.0);
      var scaled = DisplayArea(primary.work, 1.5);
      var (rect, display) = WindowGeometry.restore(saved, [scaled], scaled);
      expect(display, scaled);
      expect(rect, const Rect.fromLTWH(100, 100, 1200, 900));
    });

    test("居中时比屏幕还大：缩到屏幕的可用区域", () {
      var rect = WindowGeometry.centered(const Size(4000, 3000), primary);
      expect(rect, primary.work);
      var saved =
          const WindowPlacement(Rect.fromLTWH(-5000, 0, 3840, 2100), 1.0);
      var (restored, _) = WindowGeometry.restore(saved, both, primary);
      expect(restored, primary.work);
    });

    test("小窗换到宽高比不同的视频：面积不变", () {
      var size = WindowGeometry.keepArea(const Size(498, 280), 9 / 16);
      expect(size.width * size.height, closeTo(498 * 280, 1));
      expect(size.width / size.height, closeTo(9 / 16, 0.001));
      expect(WindowGeometry.keepArea(const Size(400, 300), 0),
          const Size(400, 300));
    });
  });

  group("存取", () {
    test("存了再读回来一样，最大化也记着", () {
      var p = const WindowPlacement(Rect.fromLTWH(-1200.5, 30, 1280, 720), 1.25,
          maximized: true);
      var back = WindowPlacement.decode(p.encode())!;
      expect(back.rect, p.rect);
      expect(back.scale, 1.25);
      expect(back.maximized, isTrue);
      expect(
          WindowPlacement.decode(p.copyWith(maximized: false).encode())!
              .maximized,
          isFalse);
    });

    test("没存过、坏了、大小不对：当作没记过", () {
      expect(WindowPlacement.decode(null), isNull);
      expect(WindowPlacement.decode(""), isNull);
      expect(WindowPlacement.decode("{"), isNull);
      expect(WindowPlacement.decode('{"x":1,"y":2,"w":0,"h":5}'), isNull);
      expect(WindowPlacement.decode('{"x":1,"y":2,"w":10}'), isNull);
      expect(WindowPlacement.decode('{"x":1,"y":2,"w":10,"h":5,"scale":-1}'),
          isNull);
    });

    test("记住窗口的设置只在本机，不进备份", () {
      for (var key in WindowMemory.storageKeys) {
        expect(SyncCompat.isLocalOnlySetting(key), isTrue, reason: key);
      }
    });
  });
}
