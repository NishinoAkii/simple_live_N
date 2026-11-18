import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/multi_window/window_layout.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';
import 'package:simple_live_app/app/window_geometry.dart';

// 多开：副窗口的摆放（物理像素）。没有固定的格子：每个编号记住用户拖到的位置，
// 没记过时从前一个窗口（或主窗口）往右下错开

/// 可用区域都去掉了底部任务栏（按缩放 48 逻辑像素）
ScreenArea screen(double left, double top, double w, double h, double scale) =>
    ScreenArea(Rect.fromLTWH(left, top, w, h - 48 * scale), scale);

void main() {
  // 左边 1080p 100%，右边 2560×1600 150%
  var left = screen(0, 0, 1920, 1080, 1.0);
  var right = screen(1920, 0, 2560, 1600, 1.5);
  var both = [left, right];

  test("最多同时开 6 个", () {
    expect(SecondaryLaunch.maxWindows, 6);
  });

  test("没记过位置：往右下错开 32，默认 800×500，整个在屏幕里（两块屏幕，一块 150%）", () {
    // 主窗口在左边
    expect(WindowLayout.cascade(both, const Rect.fromLTWH(100, 100, 1200, 700)),
        (const Rect.fromLTWH(132, 132, 800, 500), 1.0));
    // 主窗口在右边 150% 的屏幕上：错开和大小都按 1.5 倍
    expect(
        WindowLayout.cascade(both, const Rect.fromLTWH(2000, 100, 1500, 900)),
        (const Rect.fromLTWH(2048, 148, 1200, 750), 1.5));
    // 靠近右下角：整个挪进屏幕
    expect(WindowLayout.cascade(both, const Rect.fromLTWH(1800, 900, 100, 100)),
        (const Rect.fromLTWH(1120, 532, 800, 500), 1.0));
    // 屏幕很小：缩小到放得下
    var tiny = [screen(0, 0, 640, 480, 1.0)];
    expect(WindowLayout.cascade(tiny, const Rect.fromLTWH(0, 0, 640, 432)),
        (const Rect.fromLTWH(0, 0, 640, 432), 1.0));
    // 一块屏幕都读不到：交给副窗口居中
    expect(WindowLayout.cascade(const [], null), isNull);
  });

  test("第 k 个从前一个开着的窗口错开，第 1 个从主窗口错开", () {
    const main = Rect.fromLTWH(100, 100, 1200, 700);
    const first = Rect.fromLTWH(400, 200, 800, 500);
    const second = Rect.fromLTWH(2100, 300, 1200, 750);
    expect(WindowRestore.place(1, screens: both, main: main),
        (const Rect.fromLTWH(132, 132, 800, 500), 1.0));
    expect(WindowRestore.place(2, screens: both, open: {1: first}, main: main),
        (const Rect.fromLTWH(432, 232, 800, 500), 1.0));
    // 第 3 个：前一个（第 2 个）在右边的屏幕上
    expect(
        WindowRestore.place(3,
            screens: both, open: {1: first, 2: second}, main: main),
        (const Rect.fromLTWH(2148, 348, 1200, 750), 1.5));
    // 第 2 个空着时，第 3 个从第 1 个错开；后面开着的不算
    expect(WindowRestore.place(3, screens: both, open: {1: first, 5: second}),
        (const Rect.fromLTWH(432, 232, 800, 500), 1.0));
  });

  test("记过位置的编号放回原处；那块屏幕没了时错开放", () {
    const main = Rect.fromLTWH(100, 100, 1200, 700);
    var remembered = {
      2: const WindowPlacement(Rect.fromLTWH(2100, 200, 1200, 750), 1.5),
      // 记下时右边的屏幕是 100%，现在是 150%：逻辑大小不变
      3: const WindowPlacement(Rect.fromLTWH(2000, 100, 1200, 700), 1.0),
    };
    expect(
        WindowRestore.place(2,
            screens: both, remembered: remembered, main: main),
        (const Rect.fromLTWH(2100, 200, 1200, 750), 1.5));
    expect(
        WindowRestore.place(3,
            screens: both, remembered: remembered, main: main),
        (const Rect.fromLTWH(2000, 100, 1800, 1050), 1.5));
    // 拔了右边的屏幕：从主窗口错开
    expect(
        WindowRestore.place(2,
            screens: [left], remembered: remembered, main: main),
        (const Rect.fromLTWH(132, 132, 800, 500), 1.0));
  });

  test("主窗口在哪块屏幕上，就从哪块开始", () {
    expect(
        WindowLayout.screenOf(both, const Rect.fromLTWH(2000, 100, 1280, 720)),
        right);
    expect(WindowLayout.screenOf(both, const Rect.fromLTWH(100, 100, 800, 600)),
        left);
    // 中心不在任何屏幕上（跨在边上、或者在屏幕外）：重叠最多的
    expect(
        WindowLayout.screenOf(both, const Rect.fromLTWH(1500, 1050, 1000, 400)),
        right);
    expect(WindowLayout.screenOf(both, null), left);
    expect(WindowLayout.screenOf(const [], null), isNull);
  });
}
