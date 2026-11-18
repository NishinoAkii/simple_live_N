import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/window_pin.dart';

void main() {
  tearDown(() => WindowPin.instance.pinned.value = false);

  test('置顶开关：没有窗口插件时也不出错，状态照常切换', () async {
    if (!WindowPin.supported) {
      return;
    }
    expect(WindowPin.instance.pinned.value, isFalse);
    await WindowPin.instance.toggle();
    expect(WindowPin.instance.pinned.value, isTrue);
    await WindowPin.instance.toggle();
    expect(WindowPin.instance.pinned.value, isFalse);
  });

  testWidgets('图钉按钮：点一下置顶，图标变实心，再点回到正常层', (tester) async {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return;
    }
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: WindowPinButton())),
      ),
    );
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(WindowPin.instance.pinned.value, isTrue);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(WindowPin.instance.pinned.value, isFalse);
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
  });
}
