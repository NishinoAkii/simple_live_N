import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multi_window/window_layout.dart';

// 多开：副窗口的摆放（物理像素）。
// 1 到 4 个窗口，在不同大小、不同缩放的屏幕上：不重叠、都在可用区域里、不小于最小尺寸

/// 可用区域都去掉了底部任务栏（按缩放 48 逻辑像素）
ScreenArea screen(double left, double top, double w, double h, double scale) =>
    ScreenArea(Rect.fromLTWH(left, top, w, h - 48 * scale), scale);

final screens = <String, ScreenArea>{
  "1080p 100%": screen(0, 0, 1920, 1080, 1.0),
  "1080p 125%": screen(0, 0, 1920, 1080, 1.25),
  "1440p 150%（右边的副屏）": screen(1920, -200, 2560, 1440, 1.5),
  "4K 200%": screen(0, 0, 3840, 2160, 2.0),
  "4K 150%（左边的副屏，坐标为负）": screen(-3840, 0, 3840, 2160, 1.5),
  "1366×768 100%": screen(0, 0, 1366, 768, 1.0),
  "720p 150%（很小）": screen(0, 0, 1280, 720, 1.5),
  "竖屏 1080×1920 125%": screen(0, 0, 1080, 1920, 1.25),
};

void main() {
  void checkPlacement(ScreenArea s, List<Rect> rects, String name) {
    for (var r in rects) {
      expect(s.work.left <= r.left && s.work.top <= r.top, isTrue,
          reason: "$name：$r 超出了 ${s.work}");
      expect(r.right <= s.work.right && r.bottom <= s.work.bottom, isTrue,
          reason: "$name：$r 超出了 ${s.work}");
      expect(r.width >= WindowLayout.minSize.width * s.scale, isTrue,
          reason: "$name：$r 太窄");
      expect(r.height >= WindowLayout.minSize.height * s.scale, isTrue,
          reason: "$name：$r 太矮");
    }
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        var a = rects[i], b = rects[j];
        var overlap = a.left < b.right &&
            b.left < a.right &&
            a.top < b.bottom &&
            b.top < a.bottom;
        expect(overlap, isFalse, reason: "$name：$a 和 $b 重叠");
      }
    }
  }

  test("1 到 4 个窗口：不重叠、都在屏幕里", () {
    for (var entry in screens.entries) {
      var s = entry.value;
      var slots = WindowLayout.slots(s);
      expect(slots, hasLength(4), reason: entry.key);
      // 主窗口在屏幕中间，开 1 到 4 个
      var main = Rect.fromCenter(
          center: s.work.center,
          width: s.work.width / 2,
          height: s.work.height / 2);
      var used = <int>{};
      for (var n = 1; n <= 4; n++) {
        var index = WindowLayout.pickSlot(slots, used, main);
        expect(index, isNotNull, reason: "${entry.key} 第 $n 个");
        used.add(index!);
        checkPlacement(s, [for (var i in used) slots[i]], "${entry.key} $n 个");
      }
      // 第 5 个没有位置
      expect(WindowLayout.pickSlot(slots, used, main), isNull);
    }
  });

  test("横屏排 2×2，竖屏排 1×4，空隙按缩放算", () {
    var wide = WindowLayout.slots(screens["1080p 100%"]!);
    expect(wide.map((e) => e.top).toSet(), hasLength(2));
    expect(wide.map((e) => e.left).toSet(), hasLength(2));
    expect(wide.first, const Rect.fromLTWH(8, 8, 948, 504));
    var tall = WindowLayout.slots(screens["竖屏 1080×1920 125%"]!);
    expect(tall.map((e) => e.left).toSet(), hasLength(1));
    expect(tall.map((e) => e.top).toSet(), hasLength(4));
    var hi = WindowLayout.slots(screens["4K 200%"]!);
    expect(hi.first.left, 16);
    expect(hi[1].left - hi[0].right, 16);
  });

  test("先用不挡主窗口的格子", () {
    var s = screens["1080p 100%"]!;
    var slots = WindowLayout.slots(s);
    // 主窗口在左上角：先用右上、左下、右下
    var main = const Rect.fromLTWH(0, 0, 900, 500);
    var used = <int>{};
    var order = <int>[];
    for (var n = 0; n < 4; n++) {
      var i = WindowLayout.pickSlot(slots, used, main)!;
      used.add(i);
      order.add(i);
    }
    expect(order.first, isNot(0));
    expect(order.last, 0);
    // 主窗口占满屏幕（最大化）：按顺序
    used.clear();
    var full = s.work;
    expect(WindowLayout.pickSlot(slots, used, full), 0);
    expect(WindowLayout.pickSlot(slots, {0}, full), 1);
  });

  test("主窗口在哪块屏幕上，就排在哪块", () {
    var left = screens["1080p 100%"]!;
    var right = screens["1440p 150%（右边的副屏）"]!;
    var list = [left, right];
    expect(
        WindowLayout.screenOf(list, const Rect.fromLTWH(2000, 100, 1280, 720)),
        right);
    expect(WindowLayout.screenOf(list, const Rect.fromLTWH(100, 100, 800, 600)),
        left);
    // 中心不在任何屏幕上（跨在边上、或者在屏幕外）：重叠最多的
    expect(
        WindowLayout.screenOf(list, const Rect.fromLTWH(1500, 1050, 1000, 400)),
        right);
    expect(WindowLayout.screenOf(list, null), left);
    expect(WindowLayout.screenOf(const [], null), isNull);
  });

  test("屏幕太小放不下 4 个时少分几格，仍然不重叠", () {
    // 800×600 的屏幕、200% 缩放：逻辑上只有 400×276
    const tiny = ScreenArea(Rect.fromLTWH(0, 0, 800, 552), 2.0);
    var slots = WindowLayout.slots(tiny);
    expect(slots.length, lessThan(4));
    expect(slots, isNotEmpty);
    checkPlacement(tiny, slots, "tiny");
  });
}
