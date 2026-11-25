import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';
import 'package:simple_live_app/app/multi_window/window_switcher.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_compat.dart';

import 'fakes/memory_storage.dart';

// 贴靠分组时 Alt+Tab 里隐藏单个的窗口：哪些窗口算一组，什么时候隐藏、恢复

SwitcherWindow window(
  int id, {
  double left = 0,
  double width = 100,
  bool main = false,
  bool snapped = true,
  bool away = false,
  bool topmost = false,
  int monitor = 1,
}) =>
    SwitcherWindow(
      id: id,
      main: main,
      snapped: snapped,
      away: away,
      topmost: topmost,
      monitor: monitor,
      frame: Rect.fromLTWH(left, 0, width, 100),
    );

class _FakeSystem implements SwitcherSystem {
  @override
  bool grouping = true;

  @override
  bool switcherOpen = false;

  List<SwitcherWindow> windows = [];
  final calls = <String>[];

  /// 这个窗口隐藏不了
  int? refuse;

  /// 最后一次读的是哪些进程
  (int, Set<int>)? asked;

  @override
  List<SwitcherWindow> read(int main, Set<int> pids) {
    asked = (main, pids);
    return windows;
  }

  @override
  bool hide(int id) {
    calls.add("hide $id");
    return id != refuse;
  }

  @override
  void settle(int id) => calls.add("settle $id");

  @override
  void show(int id) => calls.add("show $id");

  List<String> take() {
    var now = calls.toList();
    calls.clear();
    return now;
  }
}

void main() {
  late MemoryStorage storage;

  setUp(() {
    Get.testMode = true;
    storage = MemoryStorage();
    Get.put<LocalStorageService>(storage);
    MultiWindowPrefs.reset();
  });
  tearDown(() {
    MultiWindowPrefs.reset();
    Get.reset();
  });

  group("哪些窗口在一个贴靠分组里", () {
    Set<int> of(List<SwitcherWindow> windows, [Set<int> previous = const {}]) =>
        SnapGroups.of(windows, previous);

    test("同一块屏幕上贴靠着、不重叠的两个以上", () {
      expect(of([window(1), window(2, left: 100)]), {1, 2});
      expect(
        of([window(1), window(2, left: 100), window(3, left: 200)]),
        {1, 2, 3},
      );
      expect(of([window(1)]), isEmpty);
      // 边上差几个像素照样算
      expect(of([window(1, width: 103), window(2, left: 100)]), {1, 2});
      expect(of([window(1, width: 110), window(2, left: 100)]), isEmpty);
    });

    test("没贴靠、置顶、别的屏幕的不算", () {
      expect(of([window(1), window(2, left: 100, snapped: false)]), isEmpty);
      expect(of([window(1), window(2, left: 100, topmost: true)]), isEmpty);
      expect(of([window(1), window(2, left: 100, monitor: 2)]), isEmpty);
      expect(
        of([
          window(1),
          window(2, left: 100),
          window(3, monitor: 2),
          window(4, left: 100, monitor: 2),
        ]),
        {1, 2, 3, 4},
      );
    });

    test("叠着的只算上面的", () {
      expect(
        of([window(1), window(2, left: 100), window(3, left: 100)]),
        {1, 2},
      );
    });

    test("在组里时最小化、去了别的桌面的还算，原来不在组里的不算", () {
      var minimized = [
        window(1, away: true, snapped: false),
        window(2, away: true, snapped: false),
      ];
      expect(of(minimized, {1, 2}), {1, 2});
      expect(of(minimized), isEmpty);
      expect(
        of([window(1), window(2, away: true, snapped: false)], {1, 2}),
        {1, 2},
      );
      // 还原以后不贴靠了：散了
      expect(
        of([window(1), window(2, left: 300, snapped: false)], {1, 2}),
        isEmpty,
      );
    });
  });

  group("隐藏和恢复", () {
    late _FakeSystem system;
    late List<int> pids;
    late SnapGroupHider hider;

    setUp(() {
      system = _FakeSystem()
        ..windows = [window(1, main: true), window(2, left: 100)];
      pids = [22];
      hider = SnapGroupHider(pids: () => pids, system: system, main: 11);
    });
    tearDown(() => hider.stop());

    Future<void> mode(SwitcherMode value) =>
        MultiWindowPrefs.setSwitcher(value);

    test("默认和系统一样：什么都不做，不定时看", () {
      hider
        ..start()
        ..update();
      expect(hider.running, isFalse);
      expect(system.take(), isEmpty);
      expect(system.asked, isNull);
    });

    test("隐藏多开窗口：只隐藏副窗口；只显示分组：主窗口也隐藏；改回来全部恢复", () async {
      hider.start();
      await mode(SwitcherMode.main);
      expect(hider.running, isTrue);
      expect(system.asked?.$1, 11);
      expect(system.asked?.$2, {22});
      expect(system.take(), ["hide 2"]);
      hider.update();
      expect(system.take(), isEmpty);
      await mode(SwitcherMode.group);
      expect(system.take(), ["hide 1"]);
      expect(hider.hidden, {1, 2});
      await mode(SwitcherMode.main);
      expect(system.take(), ["show 1"]);
      await mode(SwitcherMode.all);
      expect(system.take(), ["show 2"]);
      expect(hider.running, isFalse);
      expect(hider.hidden, isEmpty);
    });

    test("存着的设置启动时就生效，停下时恢复", () async {
      await mode(SwitcherMode.group);
      hider.start();
      expect(system.take(), ["hide 1", "hide 2"]);
      hider.stop();
      expect(system.take(), ["show 1", "show 2"]);
      expect(hider.running, isFalse);
      // 停下以后改设置不再管
      await mode(SwitcherMode.main);
      expect(system.take(), isEmpty);
    });

    test("分组散了恢复，又组成了再隐藏", () async {
      await mode(SwitcherMode.group);
      hider.start();
      system.take();
      system.windows = [
        window(1, main: true),
        window(2, left: 100, snapped: false),
      ];
      hider.update();
      expect(system.take(), ["show 1", "show 2"]);
      system.windows = [window(1, main: true), window(2, left: 100)];
      hider.update();
      expect(system.take(), ["hide 1", "hide 2"]);
      // 一起最小化：还是隐藏着
      system.windows = [
        window(1, main: true, away: true, snapped: false),
        window(2, away: true, snapped: false),
      ];
      hider.update();
      expect(system.take(), isEmpty);
      // 关掉了一个
      system.windows = [window(1, main: true)];
      hider.update();
      expect(system.take(), ["show 1", "show 2"]);
    });

    test("Alt+Tab 打开着：之前隐藏的已经生效，不再改", () async {
      await mode(SwitcherMode.main);
      hider.start();
      expect(system.take(), ["hide 2"]);
      system
        ..switcherOpen = true
        ..windows = [window(1, main: true)];
      hider.update();
      expect(system.take(), ["settle 2"]);
      hider.update();
      expect(system.take(), isEmpty);
      system.switcherOpen = false;
      hider.update();
      expect(system.take(), ["show 2"]);
      // 打开着时组成的：关了以后再隐藏，下一次打开时生效
      system
        ..switcherOpen = true
        ..windows = [window(1, main: true), window(2, left: 100)];
      hider.update();
      expect(system.take(), isEmpty);
      system.switcherOpen = false;
      hider.update();
      expect(system.take(), ["hide 2"]);
    });

    test("系统关了贴靠分组、没有多开窗口：恢复", () async {
      await mode(SwitcherMode.main);
      hider.start();
      system.take();
      system.grouping = false;
      hider.update();
      expect(system.take(), ["show 2"]);
      system.grouping = true;
      hider.update();
      expect(system.take(), ["hide 2"]);
      pids = [];
      hider.update();
      expect(system.take(), ["show 2"]);
    });

    test("隐藏不了的不算，下次再试", () async {
      system.refuse = 2;
      await mode(SwitcherMode.group);
      hider.start();
      expect(system.take(), ["hide 1", "hide 2"]);
      expect(hider.hidden, {1});
      hider.update();
      expect(system.take(), ["hide 2"]);
    });

    test("定时看", () async {
      hider = SnapGroupHider(
        pids: () => pids,
        system: system,
        main: 11,
        every: const Duration(milliseconds: 20),
      );
      system.windows = [window(1, main: true)];
      await mode(SwitcherMode.main);
      hider.start();
      expect(system.take(), isEmpty);
      system.windows = [window(1, main: true), window(2, left: 100)];
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(system.take(), ["hide 2"]);
    });
  });

  test("设置：默认显示全部，只在本机", () async {
    expect(MultiWindowPrefs.switcher.value, SwitcherMode.all);
    await MultiWindowPrefs.setSwitcher(SwitcherMode.group);
    expect(storage.values[MultiWindowPrefs.kSwitcher], "group");
    MultiWindowPrefs.reset();
    expect(MultiWindowPrefs.switcher.value, SwitcherMode.group);
    expect(SyncCompat.isLocalOnlySetting(MultiWindowPrefs.kSwitcher), isTrue);
    expect(SwitcherMode.parse("x"), SwitcherMode.all);
    expect(SwitcherMode.parse(null), SwitcherMode.all);
  });

  group("系统", () {
    test("Windows 11 才有贴靠分组", () {
      expect(
        WindowsSwitcher.buildOf('"Windows 11 Pro" 10.0 (Build 26300)'),
        26300,
      );
      expect(
        WindowsSwitcher.buildOf('"Windows 10 Pro" 10.0 (Build 19045)'),
        19045,
      );
      expect(WindowsSwitcher.buildOf("Linux 6.1"), 0);
    });

    test("真的系统调用（Windows，不显示的消息窗口）", () {
      if (!WindowsSwitcher.supported) {
        return;
      }
      var system = WindowsSwitcher.create()!;
      var user32 = DynamicLibrary.open("user32.dll");
      var text = DynamicLibrary.open("kernel32.dll").lookupFunction<
          Pointer<Uint16> Function(Uint32, IntPtr),
          Pointer<Uint16> Function(int, int)>("LocalAlloc")(0x40, 64);
      const name = "STATIC";
      for (var i = 0; i < name.length; i++) {
        text[i] = name.codeUnitAt(i);
      }
      var hwnd = user32.lookupFunction<
              IntPtr Function(Uint32, Pointer<Uint16>, Pointer<Uint16>, Uint32,
                  Int32, Int32, Int32, Int32, IntPtr, IntPtr, IntPtr, IntPtr),
              int Function(int, Pointer<Uint16>, Pointer<Uint16>, int, int, int,
                  int, int, int, int, int, int)>("CreateWindowExW")(
          0, text, text, 0, 0, 0, 0, 0, -3, 0, 0, 0);
      expect(hwnd, isNot(0));
      addTearDown(() =>
          user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
              "DestroyWindow")(hwnd));
      var get = user32.lookupFunction<IntPtr Function(IntPtr, IntPtr),
          int Function(int, int)>("GetPropW");
      int hide() => get(hwnd, WindowsSwitcher.hideProp);
      int again() => get(hwnd, WindowsSwitcher.againProp);
      expect(system.hide(hwnd), isTrue);
      expect([hide(), again()], [1, hwnd]);
      system.settle(hwnd);
      expect([hide(), again()], [1, 0]);
      system.show(hwnd);
      expect([hide(), again()], [0, 0]);
      // 不是窗口：隐藏不了
      expect(system.hide(1), isFalse);
      var now = system.windowOf(hwnd, main: true);
      expect(
        [now.main, now.snapped, now.away, now.topmost],
        [true, false, false, false],
      );
      // 只读，不出错；测试的进程没有 Flutter 的窗口
      expect(system.grouping, isA<bool>());
      expect(system.switcherOpen, isA<bool>());
      expect(system.read(pid, {pid}), isEmpty);
    });
  });
}
