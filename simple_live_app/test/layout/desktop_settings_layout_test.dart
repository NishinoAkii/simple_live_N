import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/desktop_shortcuts.dart';
import 'package:simple_live_app/app/gpu_preference.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';
import 'package:simple_live_app/app/multi_window/window_switcher.dart';
import 'package:simple_live_app/app/window_memory.dart';
import 'package:simple_live_app/modules/settings/desktop_settings_page.dart';
import 'package:simple_live_core/simple_live_core.dart';

import '../fakes/memory_storage.dart';
import 'layout_matrix.dart';

// 电脑端设置的布局检查：设置页的三部分（显卡那部分强制显示），
// 改键对话框的冲突提示和不能用的键的提示

/// 新加的文字还没进 en.json（合并时再加），英文布局用 i18n_new.json 里拟的译文
final Map<String, String> _english = () {
  var file = File("../i18n_new.json");
  if (!file.existsSync()) return const <String, String>{};
  return Map<String, String>.from(jsonDecode(file.readAsStringSync()) as Map);
}();

Widget withNewText(Widget Function() build) {
  var base = CoreText.lookup;
  if (base != null && base("复制弹幕") == "Copy danmaku") {
    CoreText.lookup = (key) => base(key) ?? _english[key];
  }
  return build();
}

void main() {
  setUp(() {
    Get.testMode = true;
    MemoryStorage.install();
    DesktopShortcuts.instance = DesktopShortcuts();
    WindowMemory.instance = WindowMemory();
    GpuPreferenceSetting.instance = GpuPreferenceSetting()
      ..value.value = GpuPreferenceSetting.highPerformance;
    // 一个键关掉，显示“未设置”
    DesktopShortcuts.instance.setKey(ShortcutAction.collapseChat, null);
  });
  tearDown(Get.reset);

  Future<void> check(
      WidgetTester tester, String name, Widget Function() builder) async {
    var problems = await layoutMatrix(tester, () => withNewText(builder));
    if (problems.isNotEmpty) {
      // ignore: avoid_print
      print("[layout] $name\n  ${problems.join("\n  ")}");
    }
    expect(problems, isEmpty, reason: name);
  }

  testWidgets("设置页", (tester) async {
    await check(
      tester,
      "设置页",
      () => ListView(
        padding: const EdgeInsets.all(12),
        children: const [
          ShortcutSettingsSection(),
          WindowSettingsSection(),
          MultiWindowSettingsSection(visible: true, groupSwitcher: true),
          GpuSettingsSection(visible: true),
        ],
      ),
    );
  });

  testWidgets("贴靠分组时的 Alt+Tab：Windows 11 有，选了就存", (tester) async {
    MultiWindow.debugSupported = true;
    MultiWindowPrefs.reset();
    addTearDown(() {
      MultiWindow.debugSupported = null;
      MultiWindowPrefs.reset();
    });
    Widget page(bool has) => GetMaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MultiWindowSettingsSection(groupSwitcher: has),
            ),
          ),
        );
    await tester.pumpWidget(page(false));
    expect(find.text("贴靠分组时的 Alt+Tab"), findsNothing);
    await tester.pumpWidget(page(true));
    expect(find.text("显示全部"), findsOneWidget);
    await tester.tap(find.text("贴靠分组时的 Alt+Tab"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("只显示分组").last);
    await tester.pumpAndSettle();
    expect(MultiWindowPrefs.switcher.value, SwitcherMode.group);
    expect(find.text("只显示分组"), findsOneWidget);
  });

  testWidgets("多开窗口：记着上次的一组时能打开，开着窗口时能关，没有时灰掉", (tester) async {
    MultiWindow.debugSupported = true;
    MultiWindow.recorder = WindowSetRecorder(saveDelay: Duration.zero);
    StartupRestoreSetting.reset();
    addTearDown(() {
      MultiWindow.debugSupported = null;
      MultiWindow.recorder = WindowSetRecorder();
      MultiWindow.openCount.value = 0;
      StartupRestoreSetting.reset();
    });
    await tester.pumpWidget(const GetMaterialApp(
      home: Scaffold(
          body: SingleChildScrollView(child: MultiWindowSettingsSection())),
    ));
    ListTile tile(String text) => tester.widget<ListTile>(
        find.ancestor(of: find.text(text), matching: find.byType(ListTile)));
    expect(find.text("询问"), findsOneWidget);
    expect(tile("打开上次的多开窗口").enabled, isFalse);
    expect(tile("关闭全部多开窗口").enabled, isFalse);

    // 开着两个窗口，点了关闭全部：上次的一组有 2 个
    var recorder = MultiWindow.recorder;
    for (var slot in [1, 2]) {
      recorder.opened(WindowEntry(
        slot: slot,
        room: WindowRoom(siteId: "douyu", roomId: "$slot"),
        bounds: Rect.fromLTWH(8.0 + 637 * (slot - 1), 8, 629, 504),
      ));
    }
    await recorder.closingAll();
    MultiWindow.openCount.value = 3;
    await tester.pump();
    expect(tile("打开上次的多开窗口（2 个）").enabled, isTrue);
    expect(tile("关闭全部多开窗口（3）").enabled, isTrue);

    // 改成“不打开”
    await StartupRestoreSetting.set(StartupRestore.off);
    await tester.pump();
    expect(find.text("不打开"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets("改键对话框：冲突", (tester) async {
    await check(
      tester,
      "改键对话框：冲突",
      () => ShortcutKeyDialog(
        action: ShortcutAction.volumeDown,
        bindings: ShortcutKeys.defaultMap,
        pressed: LogicalKeyboardKey.space,
      ),
    );
  });

  testWidgets("改键对话框：不能用的键、还没按键", (tester) async {
    await check(
      tester,
      "改键对话框：不能用的键",
      () => ShortcutKeyDialog(
        action: ShortcutAction.collapseChat,
        bindings: ShortcutKeys.defaultMap,
        pressed: LogicalKeyboardKey.shiftLeft,
      ),
    );
    await check(
      tester,
      "改键对话框：还没按键",
      () => ShortcutKeyDialog(
        action: ShortcutAction.pause,
        bindings: ShortcutKeys.defaultMap,
      ),
    );
  });
}
