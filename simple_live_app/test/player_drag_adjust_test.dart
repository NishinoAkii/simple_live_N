import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/player_drag_adjust.dart';

void main() {
  test('电脑上只有手指和触控笔能触发，鼠标不行', () {
    expect(PlayerDragAdjust.accepts(PointerDeviceKind.touch), isTrue);
    expect(PlayerDragAdjust.accepts(PointerDeviceKind.stylus), isTrue);
    var mobile = Platform.isAndroid || Platform.isIOS;
    expect(PlayerDragAdjust.accepts(PointerDeviceKind.mouse), mobile);
    expect(PlayerDragAdjust.accepts(PointerDeviceKind.trackpad), mobile);
    expect(PlayerDragAdjust.accepts(null), mobile);
  });

  test('往上滑变大，往下滑变小，到头就停', () {
    double value(double y) => PlayerDragAdjust.dragValue(
          start: 0.5,
          startY: 100,
          y: y,
          range: 100,
        );
    expect(value(100), 0.5);
    expect(value(50), 1.0);
    expect(value(75), 0.75);
    expect(value(150), 0.0);
    expect(value(-500), 1.0);
    expect(value(900), 0.0);
  });

  test('音量每档 5%', () {
    expect(PlayerDragAdjust.volumePercent(0), 0);
    expect(PlayerDragAdjust.volumePercent(0.52), 50);
    expect(PlayerDragAdjust.volumePercent(0.53), 55);
    expect(PlayerDragAdjust.volumePercent(1), 100);
  });
}
