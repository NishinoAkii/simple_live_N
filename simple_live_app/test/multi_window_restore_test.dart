import 'dart:io' show pid;
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/window_layout.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';
import 'package:simple_live_app/app/window_geometry.dart';
import 'package:simple_live_app/services/sync_compat.dart';

import 'fakes/memory_storage.dart';

// 多开：记下上次的一组窗口，历史页一下全部打开

WindowRoom room(String id, {String name = "", String title = ""}) =>
    WindowRoom(siteId: "douyu", roomId: id, userName: name, title: title);

WindowEntry entry(int slot, String id, Rect? bounds,
        {double scale = 1.0, String name = ""}) =>
    WindowEntry(
        slot: slot, room: room(id, name: name), bounds: bounds, scale: scale);

/// 可用区域去掉了底部任务栏（按缩放 48 逻辑像素）
ScreenArea display(double l, double t, double w, double h, double scale) =>
    ScreenArea(Rect.fromLTWH(l, t, w, h - 48 * scale), scale);

void main() {
  // 左边 1080p 100%（主窗口在这块），右边 2560×1600 150%
  var left = display(0, 0, 1920, 1080, 1.0);
  var right = display(1920, 0, 2560, 1600, 1.5);
  // 用户拖到的几个位置（左边的屏幕上，不重叠）
  var cells = const [
    Rect.fromLTWH(8, 8, 629, 504),
    Rect.fromLTWH(645, 8, 629, 504),
    Rect.fromLTWH(1282, 8, 629, 504),
    Rect.fromLTWH(8, 520, 629, 504),
    Rect.fromLTWH(645, 520, 629, 504),
    Rect.fromLTWH(1282, 520, 629, 504),
  ];
  var time = DateTime(2026, 11, 19, 20);

  group("记下这一组", () {
    late MemoryStorage storage;
    late WindowSetRecorder recorder;
    WindowRoom? mainRoom;

    WindowSetRecorder create() => WindowSetRecorder(
          mainRoom: () => mainRoom,
          saveDelay: Duration.zero,
          clock: () => time,
        );

    WindowSet? stored(String key) =>
        WindowSet.decode(storage.values[key] as String?);

    List<int> slots(WindowSet? set) => [...?set?.windows.map((e) => e.slot)];

    setUp(() {
      storage = MemoryStorage.install();
      mainRoom = null;
      recorder = create();
    });

    tearDown(Get.reset);

    test("开窗口、挪动、换直播间：开着的这一组随时存，上次的一组不变", () {
      // 上一次留下的一组
      storage.values[WindowSetRecorder.kLast] =
          WindowSet([entry(1, "100", cells[0])], time: time).encode();
      expect(slots(recorder.last.value), [1]);

      recorder.opened(entry(1, "1", cells[0]));
      recorder.opened(entry(2, "2", cells[1]));
      expect(slots(stored(WindowSetRecorder.kOpen)), [1, 2]);
      expect(slots(recorder.last.value), [1]);
      expect(recorder.last.value!.windows.single.room.roomId, "100");

      // 挪了第一个
      const moved = Rect.fromLTWH(100, 120, 800, 450);
      recorder.reported(1, const WindowReport(bounds: moved, scale: 1.0));
      expect(stored(WindowSetRecorder.kOpen)!.windows.first.bounds, moved);
      // 第二个读到了主播名，位置不变
      recorder.reported(
          2, WindowReport(room: room("2", name: "主播乙", title: "标题")));
      var second = stored(WindowSetRecorder.kOpen)!.windows[1];
      expect(second.room.userName, "主播乙");
      expect(second.room.title, "标题");
      expect(second.bounds, cells[1]);
      // 第二个换了直播间（在副窗口里点了别的）
      recorder.reported(2, WindowReport(room: room("3")));
      expect(stored(WindowSetRecorder.kOpen)!.windows[1].room.roomId, "3");
      // 不认识的窗口不管
      recorder.reported(5, const WindowReport(bounds: moved, scale: 1.0));
      expect(slots(stored(WindowSetRecorder.kOpen)), [1, 2]);
      // 主窗口在看的直播间也跟着记
      mainRoom = room("9", name: "主窗口");
      recorder.mainRoomChanged();
      expect(stored(WindowSetRecorder.kOpen)!.mainRoom, mainRoom);
      expect(slots(recorder.last.value), [1]);
    });

    test("挪窗口时连着报很多次，停下以后才存", () async {
      recorder = WindowSetRecorder(
          saveDelay: const Duration(milliseconds: 50), clock: () => time);
      recorder.opened(entry(1, "1", cells[0]));
      for (var i = 0; i < 5; i++) {
        recorder.reported(
            1, WindowReport(bounds: Rect.fromLTWH(10.0 * i, 0, 800, 450)));
      }
      expect(stored(WindowSetRecorder.kOpen)!.windows.single.bounds, cells[0]);
      await recorder.flush();
      expect(stored(WindowSetRecorder.kOpen)!.windows.single.bounds,
          const Rect.fromLTWH(40, 0, 800, 450));
    });

    test("手动关掉一个（别的还开着）：从这一组去掉；手动关掉最后一个：这一组定下来", () {
      recorder.opened(entry(1, "1", cells[0]));
      recorder.opened(entry(2, "2", cells[1]));
      recorder.opened(entry(3, "3", cells[2]));
      recorder.exited(2);
      expect(slots(stored(WindowSetRecorder.kOpen)), [1, 3]);
      expect(recorder.last.value, isNull);
      recorder.exited(1);
      expect(slots(stored(WindowSetRecorder.kOpen)), [3]);
      expect(recorder.last.value, isNull);
      // 最后一个：连同它一起定下来
      mainRoom = room("9");
      recorder.exited(3);
      expect(slots(recorder.last.value), [3]);
      expect(recorder.last.value!.mainRoom, mainRoom);
      expect(slots(stored(WindowSetRecorder.kLast)), [3]);
      expect(storage.values.containsKey(WindowSetRecorder.kOpen), isFalse);
      // 退出过的再退出一次不管
      recorder.exited(3);
      expect(slots(recorder.last.value), [3]);
    });

    test("关全部多开窗口：开着的都留在这一组里，之后它们退出时不再改", () async {
      recorder.opened(entry(1, "1", cells[0]));
      recorder.opened(entry(2, "2", cells[1]));
      recorder.opened(entry(3, "3", cells[2]));
      recorder.exited(2);
      mainRoom = room("9", name: "主窗口");
      expect(await recorder.closingAll(), isTrue);
      expect(slots(recorder.last.value), [1, 3]);
      expect(recorder.last.value!.mainRoom, mainRoom);
      expect(recorder.closing, {1, 3});
      expect(slots(stored(WindowSetRecorder.kLast)), [1, 3]);
      expect(storage.values.containsKey(WindowSetRecorder.kOpen), isFalse);
      recorder.exited(1);
      recorder.exited(3);
      expect(slots(recorder.last.value), [1, 3]);
      expect(slots(stored(WindowSetRecorder.kLast)), [1, 3]);
      expect(recorder.entries, isEmpty);
      // 没有开着的窗口时什么都不做
      expect(await recorder.closingAll(), isFalse);
      expect(slots(recorder.last.value), [1, 3]);
    });

    test("主窗口退出：开着的都记下；下次启动读得到，开新窗口不会冲掉它", () async {
      recorder.opened(entry(1, "1", cells[0], name: "甲"));
      recorder.opened(entry(4, "4", const Rect.fromLTWH(2000, 100, 1200, 700),
          scale: 1.5, name: "乙"));
      mainRoom = room("9");
      // 主窗口退出时走的也是关全部（ExitGuard 里的任务）
      await recorder.closingAll();
      recorder.exited(1);
      recorder.exited(4);

      // 下次启动
      mainRoom = null;
      var next = create();
      var last = next.last.value!;
      expect(last.windows.map((e) => e.slot), [1, 4]);
      expect(last.windows[1].bounds, const Rect.fromLTWH(2000, 100, 1200, 700));
      expect(last.windows[1].scale, 1.5);
      expect(last.labels, "甲、乙");
      expect(last.mainRoom, room("9"));
      // 这次先开了一个新窗口：上次的一组还在，新的单独记
      next.opened(entry(1, "7", cells[0]));
      expect(slots(next.last.value), [1, 4]);
      expect(slots(stored(WindowSetRecorder.kOpen)), [1]);
      expect(slots(stored(WindowSetRecorder.kLast)), [1, 4]);
    });

    test("关全部以后马上开新窗口：新开的单独算", () async {
      recorder.opened(entry(1, "1", cells[0]));
      recorder.opened(entry(2, "2", cells[1]));
      await recorder.closingAll();
      // 旧的还没退出，又开了一个
      recorder.opened(entry(3, "3", cells[2]));
      expect(recorder.active.map((e) => e.slot), [3]);
      expect(recorder.entries.map((e) => e.slot), [1, 2, 3]);
      expect(slots(stored(WindowSetRecorder.kOpen)), [3]);
      recorder.exited(1);
      recorder.exited(2);
      expect(slots(recorder.last.value), [1, 2]);
      // 新开的这个手动关掉，它是这一组的最后一个
      recorder.exited(3);
      expect(slots(recorder.last.value), [3]);
    });

    test("主窗口没有正常退出（崩了、直接关机）：下次启动时开着的那一组当作上次的", () {
      storage.values[WindowSetRecorder.kLast] =
          WindowSet([entry(1, "100", cells[0])], time: time).encode();
      recorder.opened(entry(1, "1", cells[0]));
      recorder.opened(entry(2, "2", cells[1]));
      // 没有关全部，进程直接没了
      var next = create();
      expect(slots(next.last.value), [1, 2]);
      expect(next.last.value!.windows.first.room.roomId, "1");
      expect(slots(stored(WindowSetRecorder.kLast)), [1, 2]);
      expect(storage.values.containsKey(WindowSetRecorder.kOpen), isFalse);
    });

    test("按打开的顺序记；重新开到空出来的编号排到最后", () async {
      recorder.opened(entry(1, "1", cells[0]));
      recorder.opened(entry(2, "2", cells[1]));
      recorder.opened(entry(3, "3", cells[2]));
      recorder.exited(1);
      recorder.opened(entry(1, "4", cells[3]));
      expect(recorder.active.map((e) => e.slot), [2, 3, 1]);
      expect(slots(stored(WindowSetRecorder.kOpen)), [2, 3, 1]);
      await recorder.closingAll();
      expect(slots(recorder.last.value), [2, 3, 1]);
      expect(slots(create().last.value), [2, 3, 1]);
    });

    test("每个编号记住用户拖到的位置：刚开时报的不算，挪过的记下，下次启动还在", () {
      recorder.opened(entry(1, "1", cells[0]));
      recorder.opened(entry(2, "2", null));
      // 显示以后报的第一次就是开的位置（差一两个像素也算）
      recorder.reported(1, WindowReport(bounds: cells[0].translate(1, 0)));
      expect(recorder.slotPlacements, isEmpty);
      // 拖走了
      const moved = Rect.fromLTWH(2100, 200, 1200, 750);
      recorder.reported(1, const WindowReport(bounds: moved, scale: 1.5));
      recorder.reported(2, WindowReport(bounds: cells[4]));
      expect(recorder.slotPlacements.keys, unorderedEquals([1, 2]));
      expect(recorder.slotPlacements[1]!.rect, moved);
      expect(recorder.slotPlacements[1]!.scale, 1.5);
      // 关掉以后也还记着
      recorder.exited(1);
      recorder.exited(2);
      var next = create();
      expect(next.slotPlacements[1]!.rect, moved);
      expect(next.slotPlacements[2]!.rect, cells[4]);
    });

    test("存档只在本机，不进备份和同步", () {
      expect(WindowSetRecorder.storageKeys, hasLength(5));
      for (var key in [
        ...WindowSetRecorder.storageKeys,
        StartupRestoreSetting.kKey,
      ]) {
        expect(SyncCompat.isLocalOnlySetting(key), isTrue, reason: key);
        expect(SyncCompat.isExtSetting(key), isFalse, reason: key);
        expect(SyncCompat.isAutoSyncedSetting(key, syncSettings: true), isFalse,
            reason: key);
        var settings = {key: "{}", "DanmuSize": 16.0};
        expect(SyncCompat.upstreamSettings(settings).keys, ["DanmuSize"]);
        expect(SyncCompat.extSettings(settings).containsKey(key), isFalse);
        // 恢复备份时留着本机的
        var merged = SyncCompat.mergeRestoredSettings(
            {key: "local"}, {key: "remote"}, {key: "remote"});
        expect(merged[key], "local");
      }
    });

    test("存档的格式：读回来一样；版本不对、坏了的当作没有，坏了的单个窗口丢掉", () {
      var set = WindowSet(
        [
          entry(1, "1", cells[0], name: "甲"),
          entry(6, "6", const Rect.fromLTWH(-2548, 12, 837, 746), scale: 1.5),
          WindowEntry(slot: 3, room: room("3")),
        ],
        mainRoom: room("9", title: "标题"),
        time: time,
      );
      var back = WindowSet.decode(set.encode())!;
      expect(back.time, time);
      expect(back.mainRoom, room("9", title: "标题"));
      // 顺序是打开的顺序，不按编号排
      expect(back.windows.map((e) => e.slot), [1, 6, 3]);
      expect(back.windows[0].room, room("1", name: "甲"));
      expect(back.windows[0].bounds, cells[0]);
      expect(back.windows[2].bounds, isNull);
      expect(back.windows[1].bounds, const Rect.fromLTWH(-2548, 12, 837, 746));
      expect(back.windows[1].scale, 1.5);

      expect(WindowSet.decode(null), isNull);
      expect(WindowSet.decode(""), isNull);
      expect(WindowSet.decode("not json"), isNull);
      expect(WindowSet.decode('{"v":2,"windows":[]}'), isNull);
      expect(WindowSet.decode('{"v":1}'), isNull);
      var mixed = WindowSet.decode(
        '{"v":1,"windows":['
        '{"slot":7,"site":"douyu","room":"7"},'
        '{"slot":2,"site":"douyu"},'
        '{"slot":3,"site":"douyu","room":"a\\nb"},'
        '{"slot":4,"site":"douyu","room":"4","x":1,"y":2,"w":0,"h":4,"scale":1},'
        '{"slot":5,"site":"douyu","room":"5","x":1,"y":2,"w":3,"h":4,"scale":20},'
        '{"slot":1,"site":"douyu","room":"1"},'
        '{"slot":1,"site":"douyu","room":"dup"}'
        '],"main":{"site":""}}',
      )!;
      expect(mixed.windows.map((e) => e.slot), [1]);
      expect(mixed.windows.single.room.roomId, "1");
      expect(mixed.mainRoom, isNull);
    });

    test("副窗口的报告：内容逐项检查", () {
      var r = WindowReport.decode({
        "room": {"site": "douyu", "room": "1", "name": "主播"},
      });
      expect(r.room, room("1", name: "主播"));
      expect(r.bounds, isNull);
      r = WindowReport.decode(
          {"x": -1912, "y": 8, "w": 629, "h": 504, "scale": 1.5});
      expect(r.bounds, const Rect.fromLTWH(-1912, 8, 629, 504));
      expect(r.scale, 1.5);
      var back = WindowReport.decode(
          WindowReport(room: room("2"), bounds: cells[1], scale: 1.25)
              .toJson());
      expect(back.room, room("2"));
      expect(back.bounds, cells[1]);
      expect(back.scale, 1.25);
      for (var bad in <Object?>[
        null,
        [1],
        <String, dynamic>{},
        {"room": "douyu_1"},
        {
          "room": {"site": "douyu", "room": ""}
        },
        {
          "room": {"site": "douyu", "room": "1\n2"}
        },
        {
          "room": {"site": "douyu", "room": "x" * 300}
        },
        {"x": 1, "y": 2, "w": 3, "h": 4},
        {"x": 1, "y": 2, "w": 3, "h": 4, "scale": 0.1},
        {"x": 1, "y": 2, "w": 0, "h": 4, "scale": 1},
        {"x": 1, "y": 2, "w": 3, "scale": 1},
        {"x": "1", "y": 2, "w": 3, "h": 4, "scale": 1},
        {"x": 200000, "y": 2, "w": 3, "h": 4, "scale": 1},
      ]) {
        expect(() => WindowReport.decode(bad), throwsFormatException,
            reason: "$bad");
      }
    });
  });

  group("主窗口关了，副窗口跟着关", () {
    test("主窗口进程没了：隔一会儿再确认，然后自己关掉", () async {
      var gone = 0;
      var watch = MainGoneWatch(
        alive: () => false,
        onGone: () => gone++,
        grace: const Duration(milliseconds: 40),
        poll: const Duration(milliseconds: 20),
      );
      var done = watch.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(gone, 0);
      await done;
      expect(gone, 1);
    });

    test("主窗口还在（只是一时连不上）、查着查着又在了：不关；之后真的没了再关", () async {
      var gone = 0;
      var answers = <bool?>[false, true, null, true];
      var calls = 0;
      var watch = MainGoneWatch(
        // 先说不在了，确认时又在了；查不了的不算不在；最后一直不在
        alive: () => calls < answers.length ? answers[calls++] : false,
        onGone: () => gone++,
        grace: const Duration(milliseconds: 20),
        poll: const Duration(milliseconds: 10),
      );
      var done = watch.start();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(gone, 0);
      await done;
      expect(gone, 1);
      expect(calls, answers.length);

      // 一直在：不关，停下以后结束
      var alive = MainGoneWatch(
        alive: () => true,
        onGone: () => gone++,
        poll: const Duration(milliseconds: 10),
      );
      var running = alive.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      alive.stop();
      await running;
      expect(gone, 1);
    });

    test("这个进程自己当然还在；编号不对时查不了", () {
      // 测试在 Windows 上跑时能查到；别的系统上查不了（null），不会因此关窗口
      var self = MainProcess(pid).alive;
      expect(self, anyOf(isTrue, isNull));
      expect(MainProcess(0).alive, isNull);
    });
  });

  group("启动时恢复上次的多开窗口", () {
    var set = WindowSet([entry(1, "1", cells[0])], time: time);

    test("询问（默认）、直接打开、不打开", () {
      expect(StartupRestoreSetting.parse(null), StartupRestore.ask);
      expect(StartupRestoreSetting.parse("x"), StartupRestore.ask);
      expect(StartupRestoreSetting.parse("off"), StartupRestore.off);
      StartupAction decide(StartupRestore s,
              {bool canOpen = true, WindowSet? last, bool forRoom = false}) =>
          StartupRestoreSetting.decide(s,
              canOpen: canOpen, last: last ?? set, forRoom: forRoom);
      expect(decide(StartupRestore.ask), StartupAction.ask);
      expect(decide(StartupRestore.open), StartupAction.open);
      expect(decide(StartupRestore.off), StartupAction.none);
      // 没有上次的一组
      expect(
          StartupRestoreSetting.decide(StartupRestore.ask,
              canOpen: true, last: null, forRoom: false),
          StartupAction.none);
      expect(decide(StartupRestore.open, last: WindowSet(const [], time: time)),
          StartupAction.none);
      // 副窗口、不是电脑：不问
      expect(decide(StartupRestore.ask, canOpen: false), StartupAction.none);
      expect(decide(StartupRestore.open, canOpen: false), StartupAction.none);
      // 带着链接或参数启动、已经进了直播间：不问
      expect(decide(StartupRestore.ask, forRoom: true), StartupAction.none);
      expect(decide(StartupRestore.open, forRoom: true), StartupAction.none);
    });

    test("设置存在本机，改了马上生效", () async {
      var storage = MemoryStorage.install();
      addTearDown(Get.reset);
      StartupRestoreSetting.reset();
      expect(StartupRestoreSetting.value.value, StartupRestore.ask);
      await StartupRestoreSetting.set(StartupRestore.off);
      expect(storage.values[StartupRestoreSetting.kKey], "off");
      StartupRestoreSetting.reset();
      expect(StartupRestoreSetting.value.value, StartupRestore.off);
      StartupRestoreSetting.reset();
    });
  });

  group("打开上次的一组", () {
    WindowSet saved(List<WindowEntry> windows, {WindowRoom? mainRoom}) =>
        WindowSet(windows, mainRoom: mainRoom, time: time);

    test("放回上次的位置：两块屏幕、缩放不同；按上次打开的顺序", () {
      var plan = WindowRestore.plan(
        saved([
          entry(4, "4", const Rect.fromLTWH(700, 520, 900, 500)),
          entry(1, "1", cells[0]),
          entry(2, "2", const Rect.fromLTWH(2000, 100, 1200, 700), scale: 1.5),
        ]),
        screens: [left, right],
        main: left.work,
      );
      // 顺序和上次一样（后开的在上面），编号用上次的
      expect(plan.windows.map((e) => e.slot), [4, 1, 2]);
      expect(plan.windows.map((e) => e.bounds), [
        const Rect.fromLTWH(700, 520, 900, 500),
        cells[0],
        const Rect.fromLTWH(2000, 100, 1200, 700),
      ]);
      expect(plan.windows.map((e) => e.scale), [1.0, 1.0, 1.5]);
      expect(plan.windows.every((e) => e.atSavedSpot), isTrue);
      expect(plan.skipped, 0);
      expect(plan.limited, 0);
    });

    test("屏幕的缩放改了：按逻辑大小换算；超出屏幕的整个挪进来", () {
      var plan = WindowRestore.plan(
        saved([
          entry(1, "1", const Rect.fromLTWH(2000, 100, 1200, 700)),
          entry(2, "2", const Rect.fromLTWH(4000, 1200, 800, 600), scale: 1.5),
        ]),
        screens: [left, right],
        main: left.work,
      );
      expect(
          plan.windows[0].bounds, const Rect.fromLTWH(2000, 100, 1800, 1050));
      expect(plan.windows[0].scale, 1.5);
      expect(plan.windows[1].bounds, const Rect.fromLTWH(3680, 928, 800, 600));
    });

    test("那块屏幕找不到了（拔了副屏）：按这个编号记的位置，没记过时从前一个错开", () {
      var plan = WindowRestore.plan(
        saved([
          entry(1, "1", cells[0]),
          entry(2, "2", const Rect.fromLTWH(2000, 100, 1200, 700), scale: 1.5),
          entry(3, "3", const Rect.fromLTWH(-3000, -3000, 800, 450)),
        ]),
        screens: [left],
        remembered: {
          2: const WindowPlacement(Rect.fromLTWH(300, 300, 700, 400), 1.0),
        },
        main: left.work,
      );
      expect(plan.windows.map((e) => e.bounds), [
        cells[0],
        const Rect.fromLTWH(300, 300, 700, 400),
        const Rect.fromLTWH(332, 332, 800, 500),
      ]);
      expect(plan.windows.map((e) => e.atSavedSpot), [true, false, false]);
      // 一块屏幕都读不到：居中
      var none = WindowRestore.plan(
        saved([entry(1, "1", cells[0])]),
        screens: const [],
        fallbackScale: 1.25,
      );
      expect(none.windows.single.bounds, isNull);
      expect(none.windows.single.scale, 1.25);
    });

    test("已经开着的直播间不再开（副窗口里、主窗口里）", () {
      var set = saved(
        [
          entry(1, "1", cells[0]),
          entry(2, "2", cells[1]),
          entry(3, "3", cells[2])
        ],
        mainRoom: room("8"),
      );
      var plan = WindowRestore.plan(
        set,
        screens: [left],
        main: left.work,
        usedSlots: {4},
        open: {4: cells[3]},
        openRooms: {"douyu|2"},
        mainRoomNow: room("3"),
      );
      expect(plan.windows.map((e) => e.saved.room.roomId), ["1"]);
      expect(plan.skipped, 2);
      // 主窗口在直播间里：不换
      expect(plan.mainRoom, isNull);
      // 主窗口不在直播间里：在主窗口打开上次在看的
      plan = WindowRestore.plan(set, screens: [left], main: left.work);
      expect(plan.windows, hasLength(3));
      expect(plan.mainRoom, room("8"));
      // 主窗口上次看的已经在副窗口里开着：不再开
      plan = WindowRestore.plan(set,
          screens: [left], main: left.work, openRooms: {"douyu|8"});
      expect(plan.mainRoom, isNull);
      // 同一个直播间记了两次：只开一个
      plan = WindowRestore.plan(
          saved([entry(1, "1", cells[0]), entry(2, "1", cells[1])]),
          screens: [left],
          main: left.work);
      expect(plan.windows, hasLength(1));
      expect(plan.skipped, 1);
    });

    test("不超过同时开的上限；编号尽量用上次的", () {
      var plan = WindowRestore.plan(
        saved([
          entry(1, "11", cells[4]),
          entry(2, "12", cells[5]),
          entry(5, "13", const Rect.fromLTWH(2000, 100, 1200, 700)),
        ]),
        screens: [left, right],
        main: left.work,
        usedSlots: {1, 2, 3, 4},
        open: {for (var i = 0; i < 4; i++) i + 1: cells[i]},
        openRooms: {"douyu|1", "douyu|2", "douyu|3", "douyu|4"},
      );
      // 1、2 号被占了换成 5、6；第三个没有编号了
      expect(plan.windows.map((e) => e.slot), [5, 6]);
      expect(plan.windows.map((e) => e.bounds), [cells[4], cells[5]]);
      expect(plan.limited, 1);
    });

    test("打开以后的提示", () {
      expect(
          const RestoreResult(opened: 3, skipped: 0, limited: 0, failed: 0)
              .message,
          "已打开 3 个窗口");
      expect(
          const RestoreResult(opened: 0, skipped: 2, limited: 0, failed: 0)
              .message,
          "上次的窗口都已经开着");
      expect(
          const RestoreResult(opened: 2, skipped: 1, limited: 1, failed: 0)
              .message,
          "已打开 2 个窗口，多开窗口最多 6 个");
      expect(
          const RestoreResult(opened: 2, skipped: 0, limited: 0, failed: 1)
              .message,
          "已打开 2 个窗口，1 个没有打开");
    });
  });
}
