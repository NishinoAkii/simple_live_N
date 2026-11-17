import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/desktop_shortcuts.dart';
import 'package:simple_live_app/app/window_memory.dart';
import 'package:simple_live_app/modules/settings/desktop_settings_page.dart';

import 'fakes/memory_storage.dart';

/// 电脑端设置页的快捷键部分：显示按键、改键、冲突和不能用的键的提示、关掉、恢复默认
void main() {
  late MemoryStorage storage;
  late DesktopShortcuts shortcuts;

  setUp(() {
    Get.testMode = true;
    storage = MemoryStorage.install();
    shortcuts = DesktopShortcuts.instance = DesktopShortcuts();
    WindowMemory.instance = WindowMemory();
  });
  tearDown(Get.reset);

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const GetMaterialApp(home: DesktopSettingsPage()));
    await tester.pump();
  }

  /// 某个动作那一行右边显示的键
  Finder keyOf(String action) => find.descendant(
        of: find.widgetWithText(ListTile, action),
        matching: find.byType(ShortcutKeyCap),
      );

  String capLabel(WidgetTester tester, Finder cap) => tester
      .widget<Text>(find.descendant(of: cap, matching: find.byType(Text)))
      .data!;

  testWidgets("列出每个动作和它的键", (tester) async {
    await open(tester);
    expect(find.text("启用快捷键"), findsOneWidget);
    for (var action in ShortcutAction.values) {
      expect(find.widgetWithText(ListTile, action.label), findsOneWidget);
    }
    expect(capLabel(tester, keyOf("全屏")), "F");
    expect(capLabel(tester, keyOf("暂停和继续")), "空格");
    expect(capLabel(tester, keyOf("音量加")), "↑");
    expect(find.text("记住窗口位置和大小"), findsOneWidget);
  });

  testWidgets("改键：按下别的动作在用的键，提示冲突，确定后那个动作变成未设置", (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(ListTile, "刷新"));
    await tester.pumpAndSettle();
    expect(find.text("设置「刷新」的按键"), findsOneWidget);
    expect(find.text("请按下要使用的键"), findsOneWidget);
    expect(find.text("当前：R"), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(find.text("这个键已用于「全屏」，确定后「全屏」将不再有快捷键。"), findsOneWidget);
    await tester.tap(find.text("确定"));
    await tester.pumpAndSettle();

    expect(shortcuts.bindings.value[ShortcutAction.refresh],
        LogicalKeyboardKey.keyF);
    expect(shortcuts.bindings.value[ShortcutAction.fullscreen], isNull);
    expect(capLabel(tester, keyOf("刷新")), "F");
    expect(
        find.descendant(
            of: find.widgetWithText(ListTile, "全屏"),
            matching: find.text("未设置")),
        findsOneWidget);
  });

  testWidgets("不能用的键：给出原因，确定按不了；Esc 关掉对话框，什么都不改", (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(ListTile, "全屏"));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(find.text("Shift、Ctrl、Alt 这类键不能单独使用"), findsOneWidget);
    var ok = tester.widget<TextButton>(find.widgetWithText(TextButton, "确定"));
    expect(ok.onPressed, isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text("设置「全屏」的按键"), findsNothing);
    expect(shortcuts.bindings.value, ShortcutKeys.defaultMap);
  });

  testWidgets("关闭一个快捷键、恢复默认、关掉整个快捷键", (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(ListTile, "静音"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("关闭此快捷键"));
    await tester.pumpAndSettle();
    expect(shortcuts.bindings.value[ShortcutAction.mute], isNull);
    expect(
        find.descendant(
            of: find.widgetWithText(ListTile, "静音"),
            matching: find.text("未设置")),
        findsOneWidget);

    await tester.tap(find.text("恢复默认按键"));
    await tester.pump();
    expect(shortcuts.bindings.value, ShortcutKeys.defaultMap);
    expect(capLabel(tester, keyOf("静音")), "M");

    await tester.tap(find.text("启用快捷键"));
    await tester.pump();
    expect(shortcuts.enabled.value, isFalse);
    expect(storage.values[DesktopShortcuts.kEnabled], isFalse);
  });

  testWidgets("改键对话框开着时，Windows 上也要断开输入法", (tester) async {
    await open(tester);
    expect(shortcuts.captureState()["imeOff"], isFalse);
    await tester.tap(find.widgetWithText(ListTile, "暂停和继续"));
    await tester.pumpAndSettle();
    expect(shortcuts.captureState()["imeOff"], isTrue);
    await tester.tap(find.text("取消"));
    await tester.pumpAndSettle();
    expect(shortcuts.captureState()["imeOff"], isFalse);
  });
}
