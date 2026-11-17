import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 画一块 400×[height] 的弹幕屏，返回控制器
Future<DanmakuController> _pumpScreen(
  WidgetTester tester,
  GlobalKey key, {
  double height = 200,
  double area = 1.0,
}) async {
  DanmakuController? controller;
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 400,
            height: height,
            child: DanmakuScreen(
              createdController: (c) => controller = c,
              option: DanmakuOption(fontSize: 20, area: area),
            ),
          ),
        ),
      ),
    ),
  );
  return controller!;
}

/// 顶部弹幕居中显示、不移动，数一数画出来的红色像素
Future<int> _redPixels(WidgetTester tester, GlobalKey key) async {
  var boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  var pixels = await tester.runAsync(() async {
    var image = await boundary.toImage();
    var data = await image.toByteData();
    image.dispose();
    return data!;
  });
  var count = 0;
  for (var i = 0; i < pixels!.lengthInBytes; i += 4) {
    if (pixels.getUint8(i) > 200 &&
        pixels.getUint8(i + 1) < 60 &&
        pixels.getUint8(i + 2) < 60) {
      count++;
    }
  }
  return count;
}

DanmakuContentItem _red() => DanmakuContentItem(
      "MMMM",
      color: const Color(0xFFFF0000),
      type: DanmakuItemType.top,
    );

Future<void> _dispose(WidgetTester tester, DanmakuController controller) async {
  controller.clear();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('切到后台再回来，新弹幕照常显示', (tester) async {
    var key = GlobalKey();
    var controller = await _pumpScreen(tester, key);
    for (var state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    controller.addDanmaku(_red());
    await tester.pump(const Duration(milliseconds: 16));
    expect(await _redPixels(tester, key), greaterThan(300));
    await _dispose(tester, controller);
  });

  testWidgets('手动暂停的不会因为回到前台自动恢复', (tester) async {
    var key = GlobalKey();
    var controller = await _pumpScreen(tester, key);
    controller.pause();
    for (var state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    controller.addDanmaku(_red());
    await tester.pump(const Duration(milliseconds: 16));
    expect(await _redPixels(tester, key), 0);
    await _dispose(tester, controller);
  });

  testWidgets('播放器很矮、显示区域很小时至少留一行', (tester) async {
    // 竖屏小窗口约 190 高，显示区域 10% 算出来不到一行
    var key = GlobalKey();
    var controller = await _pumpScreen(tester, key, height: 190, area: 0.1);
    controller.addDanmaku(_red());
    await tester.pump(const Duration(milliseconds: 16));
    expect(await _redPixels(tester, key), greaterThan(300));
    await _dispose(tester, controller);
  });

  group('表情大小', () {
    Future<int> emotePixels(WidgetTester tester, double emoteScale) async {
      var red = await tester.runAsync(() {
        var completer = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          Uint8List.fromList([
            for (var i = 0; i < 32 * 32; i++) ...[255, 0, 0, 255],
          ]),
          32,
          32,
          ui.PixelFormat.rgba8888,
          completer.complete,
        );
        return completer.future;
      });
      DanmakuController? controller;
      var key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 400,
                height: 200,
                child: DanmakuScreen(
                  createdController: (c) => controller = c,
                  option: DanmakuOption(
                    fontSize: 20,
                    duration: 2,
                    emoteScale: emoteScale,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      // 滚动弹幕：只有一张表情，走到画面中间时数红色像素
      controller!.addDanmaku(
        DanmakuContentItem("x", segments: [DanmakuSegment.image(red!)]),
      );
      await tester.pump(const Duration(milliseconds: 16));
      // 滚动位置按帧时间算：第一帧在右边缘出发，再过 1 秒（共 2 秒）走到中间
      await tester.pump(const Duration(milliseconds: 1000));
      var count = await _redPixels(tester, key);
      controller!.clear();
      red.dispose();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 200));
      return count;
    }

    testWidgets('默认约一行高，调到 200% 时边长约两倍', (tester) async {
      // 字号 20：默认约 23×23，200% 约 46×46
      var normal = await emotePixels(tester, 1.0);
      var big = await emotePixels(tester, 2.0);
      expect(normal, inInclusiveRange(350, 700));
      expect(big, greaterThan(normal * 3));
    });
  });
}
