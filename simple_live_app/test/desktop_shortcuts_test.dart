import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/desktop_shortcuts.dart';
import 'package:simple_live_app/services/sync_compat.dart';

import 'fakes/memory_storage.dart';

/// 快捷键：按键表的规则、按键匹配、交给原生端的状态
void main() {
  group("按键表", () {
    test("默认：F 全屏、D 弹幕、M 静音、R 刷新、C 收起聊天、空格暂停、↑↓ 音量、S 截图", () {
      var map = ShortcutKeys.defaultMap;
      expect(map[ShortcutAction.fullscreen], LogicalKeyboardKey.keyF);
      expect(map[ShortcutAction.danmaku], LogicalKeyboardKey.keyD);
      expect(map[ShortcutAction.mute], LogicalKeyboardKey.keyM);
      expect(map[ShortcutAction.refresh], LogicalKeyboardKey.keyR);
      expect(map[ShortcutAction.collapseChat], LogicalKeyboardKey.keyC);
      expect(map[ShortcutAction.pause], LogicalKeyboardKey.space);
      expect(map[ShortcutAction.volumeUp], LogicalKeyboardKey.arrowUp);
      expect(map[ShortcutAction.volumeDown], LogicalKeyboardKey.arrowDown);
      expect(map[ShortcutAction.screenshot], LogicalKeyboardKey.keyS);
      expect(map.values.toSet().length, ShortcutAction.values.length);
      expect(ShortcutKeys.reservedReason(LogicalKeyboardKey.keyS), isNull);
    });

    test("以前把 S 设给了别的动作：S 还归那个动作，截图没有快捷键", () {
      var map =
          ShortcutKeys.decode('{"refresh": ${LogicalKeyboardKey.keyS.keyId}}');
      expect(map[ShortcutAction.refresh], LogicalKeyboardKey.keyS);
      expect(map[ShortcutAction.screenshot], isNull);
    });

    test("存了再读回来一样；关掉的存成 0，读回来还是关着", () {
      var map = ShortcutKeys.assign(ShortcutKeys.defaultMap,
          ShortcutAction.fullscreen, LogicalKeyboardKey.keyG);
      map = ShortcutKeys.assign(map, ShortcutAction.mute, null);
      var back = ShortcutKeys.decode(ShortcutKeys.encode(map));
      expect(back, map);
      expect(back[ShortcutAction.mute], isNull);
      expect(back[ShortcutAction.fullscreen], LogicalKeyboardKey.keyG);
    });

    test("没存过、坏了、少了几项：缺的用默认", () {
      expect(ShortcutKeys.decode(null), ShortcutKeys.defaultMap);
      expect(ShortcutKeys.decode("not json"), ShortcutKeys.defaultMap);
      expect(ShortcutKeys.decode("[1,2]"), ShortcutKeys.defaultMap);
      var map = ShortcutKeys.decode(
          '{"pause": ${LogicalKeyboardKey.keyP.keyId}, "nonsense": 5}');
      expect(map[ShortcutAction.pause], LogicalKeyboardKey.keyP);
      expect(map[ShortcutAction.fullscreen], LogicalKeyboardKey.keyF);
    });

    test("存着不能用的键（Tab、Esc、Shift）退回默认；两个动作同一个键时后面的关掉", () {
      var map = ShortcutKeys.decode('{"fullscreen": '
          '${LogicalKeyboardKey.tab.keyId}, "danmaku": '
          '${LogicalKeyboardKey.escape.keyId}, "mute": '
          '${LogicalKeyboardKey.shiftLeft.keyId}}');
      expect(map[ShortcutAction.fullscreen], LogicalKeyboardKey.keyF);
      expect(map[ShortcutAction.danmaku], LogicalKeyboardKey.keyD);
      expect(map[ShortcutAction.mute], LogicalKeyboardKey.keyM);
      var dup =
          ShortcutKeys.decode('{"refresh": ${LogicalKeyboardKey.keyF.keyId}}');
      expect(dup[ShortcutAction.fullscreen], LogicalKeyboardKey.keyF);
      expect(dup[ShortcutAction.refresh], isNull);
    });

    test("冲突：设成别的动作在用的键，提示是哪个，确定后那个动作关掉", () {
      var map = ShortcutKeys.defaultMap;
      expect(
          ShortcutKeys.conflict(
              map, ShortcutAction.refresh, LogicalKeyboardKey.keyF),
          ShortcutAction.fullscreen);
      // 自己原来的键不算冲突
      expect(
          ShortcutKeys.conflict(
              map, ShortcutAction.fullscreen, LogicalKeyboardKey.keyF),
          isNull);
      expect(
          ShortcutKeys.conflict(
              map, ShortcutAction.refresh, LogicalKeyboardKey.keyQ),
          isNull);
      var next = ShortcutKeys.assign(
          map, ShortcutAction.refresh, LogicalKeyboardKey.keyF);
      expect(next[ShortcutAction.refresh], LogicalKeyboardKey.keyF);
      expect(next[ShortcutAction.fullscreen], isNull);
      // 原来的表不变
      expect(map[ShortcutAction.fullscreen], LogicalKeyboardKey.keyF);
    });

    test("不能用的键：Shift/Ctrl/Alt/Win、Esc、Tab；别的都能用", () {
      for (var key in [
        LogicalKeyboardKey.shiftLeft,
        LogicalKeyboardKey.controlRight,
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.tab,
      ]) {
        expect(ShortcutKeys.reservedReason(key), isNotNull, reason: "$key");
      }
      for (var key in [
        LogicalKeyboardKey.keyQ,
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.f5,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpad5,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowLeft,
      ]) {
        expect(ShortcutKeys.reservedReason(key), isNull, reason: "$key");
      }
    });

    test("显示的名字", () {
      expect(ShortcutKeys.label(LogicalKeyboardKey.keyF), "F");
      expect(ShortcutKeys.label(LogicalKeyboardKey.space), "空格");
      expect(ShortcutKeys.label(LogicalKeyboardKey.arrowUp), "↑");
      expect(ShortcutKeys.label(LogicalKeyboardKey.arrowDown), "↓");
      expect(ShortcutKeys.label(LogicalKeyboardKey.digit3), "3");
      expect(ShortcutKeys.label(LogicalKeyboardKey.f5), "F5");
    });

    test("Windows 虚拟键码：来回换得上；默认的键都有", () {
      expect(ShortcutKeys.windowsVirtualKey(LogicalKeyboardKey.keyF), 0x46);
      expect(ShortcutKeys.windowsVirtualKey(LogicalKeyboardKey.space), 0x20);
      expect(ShortcutKeys.windowsVirtualKey(LogicalKeyboardKey.arrowUp), 0x26);
      expect(
          ShortcutKeys.windowsVirtualKey(LogicalKeyboardKey.arrowDown), 0x28);
      for (var key in ShortcutKeys.defaults.values) {
        var vk = ShortcutKeys.windowsVirtualKey(key);
        expect(vk, isNotNull, reason: "$key");
        expect(ShortcutKeys.fromWindowsVirtualKey(vk!), key);
      }
      expect(ShortcutKeys.fromWindowsVirtualKey(0xFFFF), isNull);
    });

    test("只有音量按住不放时连续触发", () {
      expect(ShortcutAction.values.where((e) => e.repeats).toSet(),
          {ShortcutAction.volumeUp, ShortcutAction.volumeDown});
    });
  });

  group("设置和匹配", () {
    late DesktopShortcuts shortcuts;

    setUp(() {
      MemoryStorage.install();
      shortcuts = DesktopShortcuts();
    });
    tearDown(Get.reset);

    test("改键、关掉、恢复默认都存下来；开关也存；同步时跟着设置走，不是只在本机", () {
      shortcuts.setKey(ShortcutAction.refresh, LogicalKeyboardKey.keyF);
      shortcuts.setEnabled(false);
      var again = DesktopShortcuts()..load();
      expect(again.enabled.value, isFalse);
      expect(again.bindings.value[ShortcutAction.refresh],
          LogicalKeyboardKey.keyF);
      expect(again.bindings.value[ShortcutAction.fullscreen], isNull);
      shortcuts.resetKeys();
      expect(
          (DesktopShortcuts()..load()).bindings.value, ShortcutKeys.defaultMap);
      for (var key in DesktopShortcuts.storageKeys) {
        expect(SyncCompat.isLocalOnlySetting(key), isFalse, reason: key);
        expect(SyncCompat.isExtSetting(key), isTrue, reason: key);
      }
    });

    testWidgets("按键交给页面：打字、按着 Ctrl、关了快捷键时不算；按住只有音量连续", (tester) async {
      var done = <(ShortcutAction, bool)>[];
      var target = ShortcutTarget(
        isActive: () => true,
        perform: (action, repeat) {
          done.add((action, repeat));
          return true;
        },
      );
      var field = FocusNode();
      var area = FocusNode();
      addTearDown(field.dispose);
      addTearDown(area.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Focus(
            focusNode: area,
            autofocus: true,
            onKeyEvent: (_, e) => shortcuts.handle(e, target),
            child: TextField(focusNode: field),
          ),
        ),
      ));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      expect(done, [(ShortcutAction.fullscreen, false)]);

      done.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
      expect(done, [
        (ShortcutAction.volumeUp, false),
        (ShortcutAction.volumeUp, true),
        (ShortcutAction.danmaku, false),
      ]);

      done.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(done, isEmpty);

      // 在输入框里打字
      field.requestFocus();
      await tester.pump();
      expect(DesktopShortcuts.typingText(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      expect(done, isEmpty);
      area.requestFocus();
      await tester.pump();
      expect(DesktopShortcuts.typingText(), isFalse);

      shortcuts.setEnabled(false);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      expect(done, isEmpty);
      shortcuts.setEnabled(true);

      // 关掉的键不再触发，改成的新键触发
      shortcuts.setKey(ShortcutAction.fullscreen, LogicalKeyboardKey.keyG);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      expect(done, [(ShortcutAction.fullscreen, false)]);
    });

    test("交给 Windows 原生端的状态：有页面在最上面才截键，等用户按键时只断开输入法", () {
      expect(shortcuts.captureState(), {"imeOff": false, "keys": <int>[]});
      var active = true;
      var target =
          ShortcutTarget(isActive: () => active, perform: (_, __) => true);
      shortcuts.attach(target);
      var state = shortcuts.captureState();
      expect(state["imeOff"], isTrue);
      expect(state["keys"],
          [0x20, 0x26, 0x28, 0x43, 0x44, 0x46, 0x4D, 0x52, 0x53]);
      // 关掉一个键，那个键就不截了
      shortcuts.setKey(ShortcutAction.mute, null);
      expect(shortcuts.captureState()["keys"], isNot(contains(0x4D)));
      // 页面被盖住（打开了别的页面）
      active = false;
      expect(shortcuts.captureState(), {"imeOff": false, "keys": <int>[]});
      shortcuts.beginRecording();
      expect(shortcuts.captureState(), {"imeOff": true, "keys": <int>[]});
      shortcuts.endRecording();
      active = true;
      shortcuts.setEnabled(false);
      expect(shortcuts.captureState()["imeOff"], isFalse);
      shortcuts.detach(target);
      expect(shortcuts.activeTarget, isNull);
    });

    test("几个页面叠着时，最上面那个显示着的响应", () {
      var a = ShortcutTarget(isActive: () => true, perform: (_, __) => true);
      var bActive = true;
      var b = ShortcutTarget(isActive: () => bActive, perform: (_, __) => true);
      shortcuts.attach(a);
      shortcuts.attach(b);
      expect(shortcuts.activeTarget, b);
      bActive = false;
      expect(shortcuts.activeTarget, a);
    });
  });
}
