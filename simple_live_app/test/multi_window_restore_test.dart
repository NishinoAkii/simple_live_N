import 'dart:convert';
import 'dart:io' show Directory, pid;
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
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
      expect(WindowSetRecorder.storageKeys, hasLength(6));
      expect(WindowSetRecorder.storageKeys,
          contains(WindowSetRecorder.kRoomLayouts));
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

    test("每个窗口的窗口全屏、置顶记在这一组里，主窗口的也记下", () async {
      MainLayout layout = (
        windowFull: false,
        pinned: false,
        chatCollapsed: false,
        placement: null,
        settings: null
      );
      recorder = WindowSetRecorder(
        mainRoom: () => mainRoom,
        mainLayout: () => layout,
        saveDelay: Duration.zero,
        clock: () => time,
      );
      recorder.opened(entry(1, "1", cells[0]));
      // 主窗口置顶时开的
      recorder.opened(WindowEntry(
          slot: 2, room: room("2"), bounds: cells[1], pinned: true));
      var open = stored(WindowSetRecorder.kOpen)!;
      expect(open.windows.map((e) => e.windowFull), [false, false]);
      expect(open.windows.map((e) => e.pinned), [false, true]);
      // 第一个进了窗口全屏、点了置顶；第二个自己取消置顶
      recorder.reported(1, const WindowReport(windowFull: true));
      recorder.reported(1, const WindowReport(pinned: true));
      recorder.reported(2, const WindowReport(pinned: false));
      open = stored(WindowSetRecorder.kOpen)!;
      expect(open.windows.map((e) => e.windowFull), [true, false]);
      expect(open.windows.map((e) => e.pinned), [true, false]);
      expect(open.windows.first.room, room("1"));
      expect(open.windows.first.bounds, cells[0]);
      // 之后挪了位置、读到主播名：窗口全屏、置顶还在
      const moved = Rect.fromLTWH(100, 120, 800, 450);
      recorder.reported(1, const WindowReport(bounds: moved, scale: 1.0));
      recorder.reported(1, WindowReport(room: room("1", name: "甲")));
      var first = stored(WindowSetRecorder.kOpen)!.windows.first;
      expect(first.bounds, moved);
      expect(first.windowFull, isTrue);
      expect(first.pinned, isTrue);
      // 主窗口在直播间里，窗口全屏、置顶
      mainRoom = room("9");
      layout = (
        windowFull: true,
        pinned: true,
        chatCollapsed: false,
        placement: null,
        settings: null
      );
      recorder.mainRoomChanged();
      open = stored(WindowSetRecorder.kOpen)!;
      expect(open.mainFull, isTrue);
      expect(open.mainPinned, isTrue);

      await recorder.closingAll();
      // 下次启动：上次的一组、记在主窗口直播间名下的那组都有
      var next = create();
      for (var set in [next.last.value!, next.groupFor("douyu", "9")!]) {
        expect(set.windows.map((e) => e.windowFull), [true, false]);
        expect(set.windows.map((e) => e.pinned), [true, false]);
        expect(set.mainRoom, room("9"));
        expect(set.mainFull, isTrue);
        expect(set.mainPinned, isTrue);
      }

      // 主窗口不在直播间里：没有窗口全屏，置顶照记
      mainRoom = null;
      recorder.opened(entry(3, "3", cells[2]));
      open = stored(WindowSetRecorder.kOpen)!;
      expect(open.mainFull, isFalse);
      expect(open.mainPinned, isTrue);
    });

    test("窗口全屏、置顶的存档：读回来一样；以前存的没有这两项当作没有", () {
      var set = WindowSet(
        [
          WindowEntry(
              slot: 1, room: room("1"), bounds: cells[0], windowFull: true),
          WindowEntry(slot: 2, room: room("2"), pinned: true),
          WindowEntry(
              slot: 3,
              room: room("3"),
              bounds: const Rect.fromLTWH(-2548, 12, 837, 746),
              scale: 1.5,
              windowFull: true,
              pinned: true),
          entry(4, "4", cells[3]),
        ],
        mainRoom: room("9"),
        mainFull: true,
        mainPinned: true,
        time: time,
      );
      var back = WindowSet.decode(set.encode())!;
      expect(back.windows.map((e) => e.slot), [1, 2, 3, 4]);
      expect(back.windows.map((e) => e.windowFull), [true, false, true, false]);
      expect(back.windows.map((e) => e.pinned), [false, true, true, false]);
      expect(back.windows[2].bounds, const Rect.fromLTWH(-2548, 12, 837, 746));
      expect(back.windows[2].scale, 1.5);
      expect(back.mainRoom, room("9"));
      expect(back.mainFull, isTrue);
      expect(back.mainPinned, isTrue);
      // 都没有时不写（和以前的格式一样）
      expect(entry(4, "4", cells[3]).toJson().keys,
          isNot(anyOf(contains("full"), contains("pinned"))));
      var plain =
          WindowSet([entry(1, "1", cells[0])], mainRoom: room("9"), time: time)
              .encode();
      expect(plain, isNot(contains("mainFull")));
      expect(plain, isNot(contains("mainPinned")));

      // 1.26.0 存的
      var old = WindowSet.decode(
        '{"v":1,"time":0,"main":{"site":"douyu","room":"9"},"windows":['
        '{"slot":1,"site":"douyu","room":"1",'
        '"x":8,"y":8,"w":629,"h":504,"scale":1.0,"device":"耳机"}'
        ']}',
      )!;
      expect(old.windows.single.bounds, cells[0]);
      expect(old.windows.single.audioDevice, "耳机");
      expect(old.windows.single.windowFull, isFalse);
      expect(old.windows.single.pinned, isFalse);
      expect(old.mainRoom, room("9"));
      expect(old.mainFull, isFalse);
      expect(old.mainPinned, isFalse);

      // 不是 true、false 的：那一个窗口丢掉；主窗口的当作没有。
      // 主窗口不在直播间里时没有窗口全屏
      var bad = WindowSet.decode(
        '{"v":1,"main":{"site":"douyu","room":"9"},'
        '"mainFull":"yes","mainPinned":1,"windows":['
        '{"slot":1,"site":"douyu","room":"1","full":"1"},'
        '{"slot":2,"site":"douyu","room":"2","pinned":1},'
        '{"slot":3,"site":"douyu","room":"3","full":false,"pinned":true}'
        ']}',
      )!;
      expect(bad.windows.map((e) => e.slot), [3]);
      expect(bad.windows.single.windowFull, isFalse);
      expect(bad.windows.single.pinned, isTrue);
      expect(bad.mainFull, isFalse);
      expect(bad.mainPinned, isFalse);
      var noMain = WindowSet.decode('{"v":1,"mainFull":true,"mainPinned":true,'
          '"windows":[{"slot":1,"site":"douyu","room":"1"}]}')!;
      expect(noMain.mainRoom, isNull);
      expect(noMain.mainFull, isFalse);
      expect(noMain.mainPinned, isTrue);
    });

    test("副窗口的报告：进出窗口全屏、置顶变了", () {
      var r = WindowReport.decode({"full": true});
      expect(r.windowFull, isTrue);
      expect(r.pinned, isNull);
      expect(r.room, isNull);
      expect(r.bounds, isNull);
      expect(r.settings, isNull);
      r = WindowReport.decode({"pinned": false});
      expect(r.pinned, isFalse);
      expect(r.windowFull, isNull);
      var back = WindowReport.decode(
          const WindowReport(windowFull: false, pinned: true).toJson());
      expect(back.windowFull, isFalse);
      expect(back.pinned, isTrue);
      // 别的报告不带这两项
      var json = WindowReport(bounds: cells[0]).toJson();
      expect(json.containsKey("full"), isFalse);
      expect(json.containsKey("pinned"), isFalse);
      for (var bad in <Object?>[
        {"full": "true"},
        {"full": 1},
        {"pinned": "false"},
        {"full": null, "pinned": null},
        {
          "full": true,
          "room": {"site": "douyu", "room": ""}
        },
      ]) {
        expect(() => WindowReport.decode(bad), throwsFormatException,
            reason: "$bad");
      }
    });

    test("这一组记下每个窗口的全部样子，连同主窗口的位置、声音这些", () async {
      const mainAt = WindowPlacement(Rect.fromLTWH(-1920, 0, 1600, 900), 1.25);
      const mainSettings = WindowSettings(
          volume: 20,
          muted: false,
          danmaku: true,
          quality: "蓝光",
          audioDevice: "wasapi/{main}");
      MainLayout layout = (
        windowFull: true,
        pinned: true,
        chatCollapsed: false,
        placement: mainAt,
        settings: mainSettings,
      );
      recorder = WindowSetRecorder(
        mainRoom: () => mainRoom,
        mainLayout: () => layout,
        saveDelay: Duration.zero,
        clock: () => time,
      );
      mainRoom = room("9");
      // 开的时候带的设置（主窗口算好的）
      recorder.opened(WindowEntry(
          slot: 1,
          room: room("1"),
          bounds: cells[0],
          settings: const WindowSettings(volume: 50, muted: true)));
      recorder.reported(
          1,
          const WindowReport(
              settings: WindowSettings(
                  volume: 35,
                  muted: false,
                  danmaku: false,
                  quality: "原画",
                  audioDevice: "wasapi/{abc}")));
      recorder.reported(1, const WindowReport(windowFull: true, pinned: true));
      const expected = WindowSettings(
          volume: 35, muted: false, danmaku: false, quality: "原画");
      var open = stored(WindowSetRecorder.kOpen)!;
      expect(open.windows.single.settings, expected);
      expect(open.windows.single.audioDevice, "wasapi/{abc}");
      expect(open.mainPlacement!.rect, mainAt.rect);
      expect(open.mainSettings, mainSettings);

      await recorder.closingAll();
      for (var set in [
        create().last.value!,
        create().groupFor("douyu", "9")!
      ]) {
        var w = set.windows.single;
        expect(w.bounds, cells[0]);
        expect(w.settings, expected);
        expect(w.audioDevice, "wasapi/{abc}");
        expect(w.windowFull, isTrue);
        expect(w.pinned, isTrue);
        expect(set.mainRoom, room("9"));
        expect(set.mainFull, isTrue);
        expect(set.mainPinned, isTrue);
        expect(set.mainPlacement!.rect, mainAt.rect);
        expect(set.mainPlacement!.scale, 1.25);
        expect(set.mainPlacement!.maximized, isFalse);
        expect(set.mainSettings, mainSettings);
      }

      // 主窗口不在直播间里：位置照记，直播间的设置不记
      mainRoom = null;
      layout = (
        windowFull: false,
        pinned: false,
        chatCollapsed: false,
        placement: mainAt.copyWith(maximized: true),
        settings: mainSettings,
      );
      recorder.opened(entry(2, "2", cells[1]));
      open = stored(WindowSetRecorder.kOpen)!;
      expect(open.mainPlacement!.maximized, isTrue);
      expect(open.mainSettings, isNull);
    });

    test("副窗口关掉时（提前手动关的也算）记下直播间的设置、大小、窗口全屏，不记位置", () async {
      recorder.opened(entry(1, "1", cells[0]));
      recorder.opened(entry(2, "2", cells[1]));
      const moved = Rect.fromLTWH(2000, 100, 1200, 700);
      recorder.reported(2, const WindowReport(bounds: moved, scale: 1.5));
      recorder.reported(2, const WindowReport(windowFull: true));
      recorder.reported(
          2,
          const WindowReport(
              settings: WindowSettings(
                  volume: 70, muted: false, audioDevice: "wasapi/{b}")));
      // 还开着：一开始报上来的（不是用户改的）只记在这一组里，大小这些关掉时才记
      expect(recorder.roomSettings(room("2")), isNull);
      expect(recorder.roomLayout(room("2")), isNull);

      // 别的还开着时手动关掉：不在这一组里了，直播间照样记下
      recorder.exited(2);
      expect(slots(stored(WindowSetRecorder.kOpen)), [1]);
      expect(recorder.roomSettings(room("2")),
          const WindowSettings(volume: 70, muted: false));
      expect(
          recorder.roomLayout(room("2")),
          const RoomLayout(
              size: Size(1200, 700),
              scale: 1.5,
              windowFull: true,
              audioDevice: "wasapi/{b}"));
      expect(recorder.slotDevice(2), "wasapi/{b}");
      await recorder.flush();
      var layouts =
          jsonDecode(storage.values[WindowSetRecorder.kRoomLayouts] as String)
              as Map;
      // 只有大小，没有位置
      expect(layouts["douyu_2"], {
        "w": 1200,
        "h": 700,
        "scale": 1.5,
        "full": true,
        "device": "wasapi/{b}",
      });
      expect((layouts["douyu_2"] as Map).keys, isNot(contains("x")));
      expect((layouts["douyu_2"] as Map).keys, isNot(contains("y")));

      // 关全部时关掉的也记；没报过设置的只记大小和窗口全屏
      await recorder.closingAll();
      recorder.exited(1);
      expect(recorder.roomSettings(room("1")), isNull);
      expect(recorder.roomLayout(room("1")),
          RoomLayout(size: cells[0].size, scale: 1.0));
      await recorder.flush();
      // 下次启动还在
      var next = create();
      expect(next.roomLayout(room("2"))!.size, const Size(1200, 700));
      expect(next.roomLayout(room("1"))!.windowFull, isFalse);
      // 再关一次同一个直播间：换成新的（“每个窗口单独选声音输出设备”关着，设备留着以前的）
      next.opened(entry(3, "2", cells[2]));
      next.exited(3);
      expect(next.roomLayout(room("2")),
          RoomLayout(size: cells[2].size, audioDevice: "wasapi/{b}"));
    });

    test("打开这一组时用的设置报回来不改直播间平常记的；用户改了的马上记，关掉时全部记", () async {
      // 平常记的：音量 80、静音、清晰度流畅，大小 900x600
      storage.values[WindowSetRecorder.kRoomSettings] =
          '{"douyu_1":{"volume":80.0,"muted":true,"quality":"流畅"},'
          '"douyu_2":{"volume":60.0,"quality":"流畅"}}';
      storage.values[WindowSetRecorder.kRoomLayouts] =
          '{"douyu_1":{"w":900,"h":600,"scale":1.0}}';
      recorder = create();
      // 按这一组开的：音量 30、不静音，窗口全屏；副窗口读到清晰度后报上来（弹幕开关是一开始的）
      recorder.opened(WindowEntry(
          slot: 1,
          room: room("1"),
          bounds: cells[0],
          windowFull: true,
          settings: const WindowSettings(volume: 30, muted: false)));
      recorder.reported(
          1,
          const WindowReport(
              settings: WindowSettings(
                  volume: 30, muted: false, danmaku: true, quality: "原画")));
      expect(recorder.roomSettings(room("1")),
          const WindowSettings(volume: 80, muted: true, quality: "流畅"));
      expect(recorder.roomLayout(room("1"))!.size, const Size(900, 600));
      expect(recorder.roomLayout(room("1"))!.windowFull, isFalse);
      // 这一组记的清晰度这个直播间现在没有，读到以后换了别的：也不算用户改的
      recorder.opened(WindowEntry(
          slot: 2,
          room: room("2"),
          bounds: cells[1],
          settings:
              const WindowSettings(volume: 50, muted: false, quality: "蓝光")));
      recorder.reported(
          2,
          const WindowReport(
              settings: WindowSettings(
                  volume: 50, muted: false, danmaku: true, quality: "原画")));
      expect(recorder.roomSettings(room("2")),
          const WindowSettings(volume: 60, quality: "流畅"));
      // 用户调了音量：马上记成这个直播间的，别的项还是平常记的
      recorder.reported(
          1,
          const WindowReport(
              settings: WindowSettings(
                  volume: 45, muted: false, danmaku: true, quality: "原画")));
      expect(recorder.roomSettings(room("1")),
          const WindowSettings(volume: 45, muted: true, quality: "流畅"));
      // 用户换了清晰度：也马上记
      recorder.reported(
          2,
          const WindowReport(
              settings: WindowSettings(
                  volume: 50, muted: false, danmaku: true, quality: "超清")));
      expect(recorder.roomSettings(room("2")),
          const WindowSettings(volume: 60, quality: "超清"));
      // 之后关掉：照常记成关掉时的
      recorder.exited(1);
      expect(
          recorder.roomSettings(room("1")),
          const WindowSettings(
              volume: 45, muted: false, danmaku: true, quality: "原画"));
      expect(recorder.roomLayout(room("1"))!.size, cells[0].size);
      expect(recorder.roomLayout(room("1"))!.windowFull, isTrue);
    });

    test("副窗口里换了直播间：原来的直播间照关掉一样记下，新的直播间从头记", () async {
      recorder.opened(WindowEntry(
          slot: 1,
          room: room("1"),
          bounds: cells[0],
          settings: const WindowSettings(volume: 50, muted: true)));
      const moved = Rect.fromLTWH(100, 100, 1000, 600);
      recorder.reported(1, const WindowReport(bounds: moved, scale: 1.0));
      recorder.reported(1, const WindowReport(windowFull: true));
      // 读到清晰度以后第一次报：和开的时候给的一样
      recorder.reported(
          1,
          const WindowReport(
              settings: WindowSettings(
                  volume: 50,
                  muted: true,
                  danmaku: true,
                  quality: "原画",
                  audioDevice: "wasapi/{a}")));
      expect(recorder.roomSettings(room("1")), isNull);
      // 在直播间 1 里调了音量：马上记
      recorder.reported(
          1,
          const WindowReport(
              settings: WindowSettings(
                  volume: 70, muted: true, danmaku: true, quality: "原画")));
      expect(
          recorder.roomSettings(room("1")), const WindowSettings(volume: 70));

      // 关注列表里点了直播间 2：1 照关掉一样记下这时的设置、大小、窗口全屏、声音输出设备
      recorder.reported(1, WindowReport(room: room("2")));
      const settings1 = WindowSettings(
          volume: 70, muted: true, danmaku: true, quality: "原画");
      expect(recorder.roomSettings(room("1")), settings1);
      expect(
          recorder.roomLayout(room("1")),
          const RoomLayout(
              size: Size(1000, 600),
              windowFull: true,
              audioDevice: "wasapi/{a}"));
      expect(recorder.slotDevice(1), "wasapi/{a}");
      // 2 还什么都没记，1 的音量这些不带过来；窗口本身的位置、窗口全屏、设备还在
      expect(recorder.roomSettings(room("2")), isNull);
      expect(recorder.roomLayout(room("2")), isNull);
      var open = stored(WindowSetRecorder.kOpen)!.windows.single;
      expect(open.room, room("2"));
      expect(open.settings, isNull);
      expect(open.bounds, moved);
      expect(open.windowFull, isTrue);
      expect(open.audioDevice, "wasapi/{a}");

      // 换过来以后马上报的（现在的音量这些，不带清晰度）、读到 2 的清晰度以后报的：
      // 只是 2 一开始的样子，不记成 2 的
      recorder.reported(
          1,
          const WindowReport(
              settings:
                  WindowSettings(volume: 70, muted: true, danmaku: true)));
      recorder.reported(
          1,
          const WindowReport(
              settings: WindowSettings(
                  volume: 70, muted: true, danmaku: true, quality: "蓝光")));
      expect(recorder.roomSettings(room("2")), isNull);
      // 读到主播名（同一个直播间）：不算换
      recorder.reported(1, WindowReport(room: room("2", name: "乙")));
      expect(recorder.roomLayout(room("2")), isNull);
      // 在 2 里取消静音：记成 2 的，1 的不动
      recorder.reported(
          1,
          const WindowReport(
              settings: WindowSettings(
                  volume: 70, muted: false, danmaku: true, quality: "蓝光")));
      expect(recorder.roomSettings(room("2")),
          const WindowSettings(muted: false));
      expect(recorder.roomSettings(room("1")), settings1);

      // 关掉：记成 2 的
      recorder.exited(1);
      expect(
          recorder.roomSettings(room("2")),
          const WindowSettings(
              volume: 70, muted: false, danmaku: true, quality: "蓝光"));
      expect(recorder.roomLayout(room("2"))!.size, const Size(1000, 600));
      expect(recorder.roomLayout(room("2"))!.windowFull, isTrue);
      expect(recorder.roomSettings(room("1")), settings1);
      expect(recorder.last.value!.windows.single.room.roomId, "2");
      await recorder.flush();
      // 下次启动还在
      var next = create();
      expect(next.roomSettings(room("1")), settings1);
      expect(next.roomLayout(room("1"))!.windowFull, isTrue);
      expect(next.roomLayout(room("2"))!.windowFull, isTrue);
    });

    test("换了直播间：窗口本身的位置、缩放、置顶、聊天栏收起、窗口全屏、设备都留着", () async {
      const at = Rect.fromLTWH(2000, 100, 1200, 700);
      recorder.opened(WindowEntry(
          slot: 1,
          room: room("1"),
          bounds: at,
          scale: 1.5,
          pinned: true,
          chatCollapsed: true,
          windowFull: true,
          audioDevice: "wasapi/{a}",
          settings: const WindowSettings(volume: 50, muted: true)));
      recorder.reported(1, WindowReport(room: room("2")));
      void check(WindowEntry e) {
        expect(e.room, room("2"));
        expect(e.bounds, at);
        expect(e.scale, 1.5);
        expect(e.pinned, isTrue);
        expect(e.chatCollapsed, isTrue);
        expect(e.windowFull, isTrue);
        expect(e.audioDevice, "wasapi/{a}");
        // 1 的音量这些不带过来
        expect(e.settings, isNull);
      }

      check(recorder.active.single);
      check(stored(WindowSetRecorder.kOpen)!.windows.single);
      // 关全部：这一组里也是这样
      await recorder.closingAll();
      check(create().last.value!.windows.single);
    });

    test("抖音换成平台认的房间号：只改房间号，设置照旧，原来的房间号什么都不记", () async {
      WindowRoom douyin(String id) => WindowRoom(siteId: "douyin", roomId: id);
      recorder.opened(WindowEntry(
          slot: 1,
          room: douyin("71"),
          bounds: cells[0],
          settings: const WindowSettings(volume: 40, muted: true)));
      // 读到清晰度以后第一次报：只是这个窗口一开始的样子
      const first =
          WindowSettings(volume: 40, muted: true, danmaku: true, quality: "原画");
      recorder.reported(1, const WindowReport(settings: first));
      // 读到直播间信息：房间号换成 WebRid
      recorder.reported(
          1, WindowReport(room: douyin("7001"), renamedFrom: "71"));
      expect(recorder.active.single.room, douyin("7001"));
      expect(recorder.active.single.settings, first);
      expect(
          stored(WindowSetRecorder.kOpen)!.windows.single.room.roomId, "7001");
      // 没当作关掉原来的：两个房间号都什么都没记
      expect(recorder.roomSettings(douyin("71")), isNull);
      expect(recorder.roomLayout(douyin("71")), isNull);
      expect(recorder.roomSettings(douyin("7001")), isNull);
      expect(
          storage.values.containsKey(WindowSetRecorder.kRoomSettings), isFalse);
      expect(
          storage.values.containsKey(WindowSetRecorder.kRoomLayouts), isFalse);
      // 换房间号以前读过清晰度，换了以后照旧算读过：接着换的清晰度是用户换的，马上记成新房间号的
      const blue =
          WindowSettings(volume: 40, muted: true, danmaku: true, quality: "蓝光");
      recorder.reported(1, const WindowReport(settings: blue));
      expect(recorder.roomSettings(douyin("7001")),
          const WindowSettings(quality: "蓝光"));
      // 一样的再报回来不算改动
      recorder.reported(1, const WindowReport(settings: blue));
      expect(recorder.roomSettings(douyin("7001")),
          const WindowSettings(quality: "蓝光"));
      // 原来的房间号对不上（不是这个窗口原来的）、换了平台：照换了直播间算
      recorder.reported(1, WindowReport(room: douyin("8"), renamedFrom: "71"));
      expect(
          recorder.roomSettings(douyin("7001")),
          const WindowSettings(
              volume: 40, muted: true, danmaku: true, quality: "蓝光"));
      expect(recorder.roomLayout(douyin("7001")), isNotNull);
      expect(recorder.active.single.settings, isNull);
      recorder.reported(1, WindowReport(room: room("8"), renamedFrom: "8"));
      expect(recorder.roomLayout(douyin("8")), isNotNull);
      expect(recorder.active.single.room, room("8"));

      // 副窗口的报告：原来的房间号跟着直播间一起报，单独报、不对的不收
      var report = WindowReport.decode(
          WindowReport(room: douyin("7001"), renamedFrom: "71").toJson());
      expect(report.room, douyin("7001"));
      expect(report.renamedFrom, "71");
      expect(WindowReport.decode({"room": douyin("1").toJson()}).renamedFrom,
          isNull);
      expect(
          const WindowReport(windowFull: true, renamedFrom: "71").toJson().keys,
          isNot(contains("renamedFrom")));
      for (var bad in <Object?>[
        {"renamedFrom": "71"},
        {"renamedFrom": "71", "full": true},
        {"room": douyin("1").toJson(), "renamedFrom": ""},
        {"room": douyin("1").toJson(), "renamedFrom": 71},
        {"room": douyin("1").toJson(), "renamedFrom": "a\nb"},
      ]) {
        expect(() => WindowReport.decode(bad), throwsFormatException,
            reason: "$bad");
      }
    });

    test("静音不改音量，静音着记的就是静音之前的；记过的静音比“默认静音”优先", () async {
      recorder.opened(WindowEntry(
          slot: 1,
          room: room("1"),
          bounds: cells[0],
          settings: const WindowSettings(volume: 60, muted: false)));
      // 点了静音：报的音量还是 60（静音不改音量）
      recorder.reported(
          1,
          const WindowReport(
              settings:
                  WindowSettings(volume: 60, muted: true, danmaku: true)));
      expect(
          recorder.roomSettings(room("1")), const WindowSettings(muted: true));
      expect(recorder.active.single.settings!.volume, 60);
      // 静音着关掉：记的是 60 和静音
      recorder.exited(1);
      const closed = WindowSettings(volume: 60, muted: true, danmaku: true);
      expect(recorder.roomSettings(room("1")), closed);
      // 之后新开：静音照记的（“默认静音”关着也静音），音量 60，取消静音时回到它
      expect(
          WindowRestore.openingSettings(
              muteNew: false, room: recorder.roomSettings(room("1"))),
          closed);
      // 关的时候没静音：“默认静音”开着也不静音
      expect(
          WindowRestore.openingSettings(
                  muteNew: true, room: closed.withMuted(false))
              .muted,
          isFalse);

      // 没静音时调成 0：是真的调成了 0
      recorder.opened(WindowEntry(
          slot: 2,
          room: room("2"),
          settings: const WindowSettings(volume: 30, muted: false)));
      recorder.reported(
          2,
          const WindowReport(
              settings: WindowSettings(volume: 0, muted: false)));
      expect(recorder.roomSettings(room("2")), const WindowSettings(volume: 0));
      // 调成 0 又马上点了静音（连着改，报上来的是一次）：也是真的调成了 0，不换成之前的音量
      recorder.opened(WindowEntry(
          slot: 3,
          room: room("3"),
          settings: const WindowSettings(volume: 30, muted: false)));
      recorder.reported(3,
          const WindowReport(settings: WindowSettings(volume: 0, muted: true)));
      expect(recorder.roomSettings(room("3")),
          const WindowSettings(volume: 0, muted: true));
      recorder.exited(3);
      expect(recorder.roomSettings(room("3")),
          const WindowSettings(volume: 0, muted: true));

      // 打开这一组：这一组记的静音、音量优先；这一组没记的项用直播间记的，静音都没记过才按“默认静音”
      var plan = WindowRestore.plan(
        WindowSet([
          WindowEntry(
              slot: 1,
              room: room("1"),
              bounds: cells[0],
              settings: const WindowSettings(volume: 60, muted: true)),
          WindowEntry(
              slot: 2,
              room: room("2"),
              bounds: cells[1],
              settings: const WindowSettings(volume: 25)),
          WindowEntry(
              slot: 3,
              room: room("3"),
              bounds: cells[2],
              settings: const WindowSettings(volume: 35)),
        ], time: time),
        screens: [left],
        main: left.work,
      );
      expect(plan.windows[0].launchSettings(muteNew: false),
          const WindowSettings(volume: 60, muted: true));
      expect(
          plan.windows[1].launchSettings(
              muteNew: true,
              room: const WindowSettings(
                  volume: 80, muted: false, quality: "流畅")),
          const WindowSettings(volume: 25, muted: false, quality: "流畅"));
      expect(plan.windows[2].launchSettings(muteNew: true),
          const WindowSettings(volume: 35, muted: true));
    });

    test("主窗口：换了直播间时记着的清晰度不带过去；只是换了房间号时照旧；报的音量照记", () {
      var page = Object();
      addTearDown(() => MultiWindow.leaveRoom(page));
      MultiWindow.noteRoom(page, room("9"));
      const settings = WindowSettings(
          volume: 50, muted: false, danmaku: true, quality: "原画");
      MultiWindow.noteSettings(page, settings);
      expect(MultiWindow.mainLayoutNow().settings, settings);
      // 抖音这样换成平台认的房间号：还是这个直播间
      MultiWindow.noteRoom(page, room("9001"), renamedFrom: "9");
      expect(MultiWindow.mainRoom, room("9001"));
      expect(MultiWindow.mainLayoutNow().settings, settings);
      // 原来的房间号对不上、别的页面说的：照换了直播间算
      MultiWindow.noteRoom(page, room("10"), renamedFrom: "9");
      expect(MultiWindow.mainLayoutNow().settings, settings.withQuality(null));
      MultiWindow.noteSettings(page, settings);
      MultiWindow.noteRoom(Object(), room("11"), renamedFrom: "10");
      expect(MultiWindow.mainLayoutNow().settings, settings.withQuality(null));
      MultiWindow.noteRoom(page, room("12"));
      MultiWindow.noteSettings(page, settings);
      // 换了直播间：清晰度不带过去，音量这些还是这个页面的；读到新的清晰度再记
      MultiWindow.noteRoom(page, room("13"));
      expect(MultiWindow.mainLayoutNow().settings,
          const WindowSettings(volume: 50, muted: false, danmaku: true));
      MultiWindow.noteSettings(page, settings.withQuality("蓝光"));
      expect(MultiWindow.mainLayoutNow().settings!.quality, "蓝光");
      // 点了静音：音量还是 50（静音不改音量）
      MultiWindow.noteSettings(
          page, settings.withQuality("蓝光").withMuted(true));
      expect(MultiWindow.mainLayoutNow().settings,
          settings.withQuality("蓝光").withMuted(true));
      // 调成 0 又点了静音：记的是 0（真的调成了 0）
      const zero =
          WindowSettings(volume: 0, muted: true, danmaku: true, quality: "蓝光");
      MultiWindow.noteSettings(page, zero);
      expect(MultiWindow.mainLayoutNow().settings, zero);
    });

    test("新开的窗口：用户改了的音量这些马上记成直播间的，开的时候给的报回来不算", () {
      // 这个直播间记的音量 40；“默认静音”开着，先静音
      recorder.opened(WindowEntry(
          slot: 1,
          room: room("1"),
          bounds: cells[0],
          settings: const WindowSettings(volume: 40, muted: true)));
      // 读到清晰度以后第一次报：音量、静音和开的时候一样，弹幕开关、清晰度是这个窗口一开始的
      const echo = WindowReport(
          settings: WindowSettings(
              volume: 40, muted: true, danmaku: true, quality: "原画"));
      recorder.reported(1, echo);
      recorder.reported(1, echo);
      expect(recorder.roomSettings(room("1")), isNull);
      expect(
          storage.values.containsKey(WindowSetRecorder.kRoomSettings), isFalse);
      // 取消静音：马上记
      recorder.reported(
          1,
          const WindowReport(
              settings: WindowSettings(
                  volume: 40, muted: false, danmaku: true, quality: "原画")));
      expect(recorder.roomSettings(room("1")),
          const WindowSettings(muted: false));
      // 关弹幕、换清晰度：也马上记
      recorder.reported(
          1,
          const WindowReport(
              settings: WindowSettings(
                  volume: 40, muted: false, danmaku: false, quality: "蓝光")));
      const changed =
          WindowSettings(muted: false, danmaku: false, quality: "蓝光");
      expect(recorder.roomSettings(room("1")), changed);
      // 这一组里记的是这个窗口现在的样子
      expect(
          stored(WindowSetRecorder.kOpen)!.windows.single.settings,
          const WindowSettings(
              volume: 40, muted: false, danmaku: false, quality: "蓝光"));
      // 主窗口没有正常退出（崩了、直接关机）：下次启动时还在
      expect(create().roomSettings(room("1")), changed);
    });

    test("关全部时到最后还没退出的（强制结束的）：照最后报上来的记下直播间，主窗口退出前写好", () async {
      recorder.opened(entry(1, "1", cells[0]));
      recorder.opened(entry(2, "2", cells[1]));
      recorder.reported(
          1,
          const WindowReport(
              settings: WindowSettings(
                  volume: 50,
                  muted: false,
                  danmaku: true,
                  quality: "原画",
                  audioDevice: "wasapi/{a}")));
      recorder.reported(1, const WindowReport(windowFull: true));
      await recorder.closingAll();
      // 关之前报的最后的位置
      const last = Rect.fromLTWH(300, 200, 1200, 700);
      recorder.reported(1, const WindowReport(bounds: last, scale: 1.0));
      // 第二个自己退出了；第一个没退，强制结束（退出的消息来之前主窗口就要退出了）
      recorder.exited(2);
      expect(recorder.roomLayout(room("1")), isNull);
      // 关全部以后又开的一个：开着，不记
      recorder.opened(entry(3, "3", cells[2]));
      recorder.rememberClosing();
      await recorder.flush();
      expect(
          recorder.roomLayout(room("1")),
          const RoomLayout(
              size: Size(1200, 700),
              windowFull: true,
              audioDevice: "wasapi/{a}"));
      expect(
          recorder.roomSettings(room("1")),
          const WindowSettings(
              volume: 50, muted: false, danmaku: true, quality: "原画"));
      expect(recorder.slotDevice(1), "wasapi/{a}");
      expect(recorder.roomLayout(room("2")), RoomLayout(size: cells[1].size));
      expect(recorder.roomLayout(room("3")), isNull);
      // 下次启动都在
      var next = create();
      expect(next.roomLayout(room("1"))!.size, const Size(1200, 700));
      expect(next.roomSettings(room("1"))!.volume, 50);
      // 之后退出的消息来了：照样再记一次，上次的一组不变
      recorder.exited(1);
      expect(slots(recorder.last.value), [1, 2]);
      expect(recorder.roomLayout(room("1"))!.windowFull, isTrue);
    });

    test("打开这一组把主窗口放回去以后：开着的这一组记放回去的位置，等挪完再量一次", () async {
      var saved = MultiWindow.recorder;
      addTearDown(() => MultiWindow.recorder = saved);
      recorder = WindowSetRecorder(
        mainRoom: () => mainRoom,
        mainLayout: MultiWindow.mainLayoutNow,
        saveDelay: Duration.zero,
        clock: () => time,
      );
      MultiWindow.recorder = recorder;
      recorder.opened(entry(1, "1", cells[0]));
      // 这一组记的：右边的屏幕上最大化（连同最大化之前的位置和大小）
      const target = WindowPlacement(Rect.fromLTWH(2000, 100, 1800, 1100), 1.5,
          maximized: true);
      MultiWindow.mainPlaced(target, settle: const Duration(milliseconds: 30));
      var open = stored(WindowSetRecorder.kOpen)!;
      expect(open.mainPlacement!.rect, target.rect);
      expect(open.mainPlacement!.scale, 1.5);
      expect(open.mainPlacement!.maximized, isTrue);
      expect(MultiWindow.remeasurePending, isTrue);
      // 之后最大化着量：留着放回去时的位置（不是放回去之前的），记下最大化
      var measured = MultiWindow.measuredPlacement(MultiWindow.mainPlacement,
          const Rect.fromLTWH(1909, -11, 2582, 1550), 1.5,
          maximized: true);
      expect(measured.rect, target.rect);
      expect(measured.maximized, isTrue);
      // 没最大化时照量到的
      const now = Rect.fromLTWH(10, 20, 800, 600);
      var normal =
          MultiWindow.measuredPlacement(target, now, 1.0, maximized: false);
      expect(normal.rect, now);
      expect(normal.maximized, isFalse);
      // 等挪完再量一次（测试里没有窗口插件，量不到时留着放回去的）
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(MultiWindow.remeasurePending, isFalse);
      expect(MultiWindow.mainPlacement!.rect, target.rect);
      // 关全部：上次的一组记的是放回去的
      await recorder.closingAll();
      expect(recorder.last.value!.mainPlacement!.rect, target.rect);
      expect(recorder.last.value!.mainPlacement!.maximized, isTrue);
    });

    test("聊天栏收起记在这一组里（主窗口的也记），只在打开这一组时用", () async {
      var dataDir = p.join(
          Directory.systemTemp.path, "sl_support", "multi_window", "w1-1");
      MainLayout layout = (
        windowFull: false,
        pinned: false,
        chatCollapsed: true,
        placement: null,
        settings: null
      );
      recorder = WindowSetRecorder(
        mainRoom: () => mainRoom,
        mainLayout: () => layout,
        saveDelay: Duration.zero,
        clock: () => time,
      );
      mainRoom = room("9");
      recorder.opened(entry(1, "1", cells[0]));
      recorder.opened(entry(2, "2", cells[1]));
      recorder.reported(1, const WindowReport(chatCollapsed: true));
      var open = stored(WindowSetRecorder.kOpen)!;
      expect(open.windows.map((e) => e.chatCollapsed), [true, false]);
      expect(open.mainChatCollapsed, isTrue);
      // 之后挪了位置、报了设置：还收着
      recorder.reported(1,
          const WindowReport(bounds: Rect.fromLTWH(100, 120, 800, 450)));
      recorder.reported(
          1, const WindowReport(settings: WindowSettings(volume: 20)));
      expect(
          stored(WindowSetRecorder.kOpen)!.windows.first.chatCollapsed, isTrue);
      await recorder.closingAll();
      var next = create();
      for (var set in [next.last.value!, next.groupFor("douyu", "9")!]) {
        expect(set.windows.map((e) => e.chatCollapsed), [true, false]);
        expect(set.mainChatCollapsed, isTrue);
      }
      var saved = next.last.value!;

      // 打开这一组：带进启动参数，主窗口的这个直播间也收起
      var plan = WindowRestore.plan(saved, screens: [left], main: left.work);
      SecondaryLaunch launch(WindowEntry e) => SecondaryLaunch.parse(e
          .toLaunch(
              port: 50123, token: WindowToken.generate(), dataDir: dataDir)
          .toArgs())!;
      expect(plan.windows.map((t) => launch(t.reopen()).chatCollapsed),
          [true, false]);
      expect(plan.windows.first.reopen(followPin: true).chatCollapsed, isTrue);
      var forMain = WindowRestore.mainFor(saved, plan)!;
      expect(forMain.room, room("9"));
      expect(forMain.chatCollapsed, isTrue);
      // 主窗口上次的直播间已经在副窗口里开着：主窗口只放回位置、置顶，聊天栏不动
      expect(
          WindowRestore.mainFor(
                  saved,
                  WindowRestore.plan(saved,
                      screens: [left], main: left.work, openRooms: {"douyu|9"}))!
              .chatCollapsed,
          isFalse);
      // 平常新开这个直播间（不是打开这一组）：不收起
      var opened = WindowRestore.opening(1, room("1"), (cells[0], 1.0),
          memory: const RoomLayout(windowFull: true), screens: [left]);
      expect(opened.chatCollapsed, isFalse);
      expect(launch(opened).chatCollapsed, isFalse);
      // 平常打开主窗口的直播间：不用；打开这一组时用一次
      MultiWindow.mainRestoreRequest.value = null;
      expect(MultiWindow.takeMainRestore(room("9")), isNull);
      MultiWindow.requestMainRestore(forMain);
      expect(MultiWindow.takeMainRestore(room("9"))!.chatCollapsed, isTrue);

      // 主窗口：在直播间里的那个页面收起、展开才记，离开直播间时不再收着
      var page = Object();
      MultiWindow.noteRoom(page, room("9"));
      MultiWindow.noteChatCollapsed(Object(), true);
      expect(MultiWindow.mainLayoutNow().chatCollapsed, isFalse);
      MultiWindow.noteChatCollapsed(page, true);
      expect(MultiWindow.mainLayoutNow().chatCollapsed, isTrue);
      MultiWindow.leaveRoom(page);
      expect(MultiWindow.mainLayoutNow().chatCollapsed, isFalse);

      // 存档：不收起时不写（和以前的格式一样）；以前存的没有这项当作没收起
      expect(entry(1, "1", cells[0]).toJson().keys,
          isNot(contains("chatCollapsed")));
      expect(
          WindowSet([entry(1, "1", cells[0])], mainRoom: room("9"), time: time)
              .encode(),
          isNot(contains("mainChatCollapsed")));
      // 主窗口不在直播间里：没有收起；不是 true、false 的：那一个窗口丢掉
      var odd = WindowSet.decode('{"v":1,"mainChatCollapsed":true,"windows":['
          '{"slot":1,"site":"douyu","room":"1","chatCollapsed":true},'
          '{"slot":2,"site":"douyu","room":"2","chatCollapsed":"yes"}'
          ']}')!;
      expect(odd.mainChatCollapsed, isFalse);
      expect(odd.windows.single.chatCollapsed, isTrue);
      // 副窗口的报告
      var r = WindowReport.decode({"chatCollapsed": true});
      expect(r.chatCollapsed, isTrue);
      expect(r.windowFull, isNull);
      expect(
          WindowReport.decode(
                  const WindowReport(chatCollapsed: false).toJson())
              .chatCollapsed,
          isFalse);
      expect(WindowReport(bounds: cells[0]).toJson().keys,
          isNot(contains("chatCollapsed")));
      expect(() => WindowReport.decode({"chatCollapsed": 1}),
          throwsFormatException);
    });

    test("新加的存档项：读回来一样；以前存的没有时照旧，坏了的不用", () {
      var set = WindowSet(
        [
          WindowEntry(
              slot: 1,
              room: room("1"),
              bounds: cells[0],
              settings: const WindowSettings(
                  volume: 35, muted: false, danmaku: true, quality: "原画")),
        ],
        mainRoom: room("9"),
        mainPlacement: const WindowPlacement(
            Rect.fromLTWH(100, 50, 1400, 900), 1.5,
            maximized: true),
        mainSettings: const WindowSettings(volume: 10, muted: true),
        time: time,
      );
      var back = WindowSet.decode(set.encode())!;
      expect(
          back.windows.single.settings,
          const WindowSettings(
              volume: 35, muted: false, danmaku: true, quality: "原画"));
      expect(back.mainPlacement!.rect, const Rect.fromLTWH(100, 50, 1400, 900));
      expect(back.mainPlacement!.scale, 1.5);
      expect(back.mainPlacement!.maximized, isTrue);
      expect(back.mainSettings, const WindowSettings(volume: 10, muted: true));
      // 声音输出设备不放进窗口的设置（在 device 里）
      var withDevice = WindowEntry(
          slot: 1,
          room: room("1"),
          audioDevice: "wasapi/{a}",
          settings: const WindowSettings(volume: 5, audioDevice: "wasapi/{x}"));
      expect(withDevice.toJson()["settings"], {"volume": 5.0});
      expect(withDevice.toJson()["device"], "wasapi/{a}");

      // 1.27.0 存的：没有这些，照旧读
      var old = WindowSet.decode(
        '{"v":1,"time":0,"main":{"site":"douyu","room":"9"},"mainFull":true,'
        '"windows":[{"slot":1,"site":"douyu","room":"1","full":true}]}',
      )!;
      expect(old.windows.single.settings, isNull);
      expect(old.windows.single.windowFull, isTrue);
      expect(old.windows.single.chatCollapsed, isFalse);
      expect(old.mainFull, isTrue);
      expect(old.mainChatCollapsed, isFalse);
      expect(old.mainPlacement, isNull);
      expect(old.mainSettings, isNull);
      // 1.27.1 第一版存的（有音量这些和主窗口的位置，没有聊天栏）：照旧读
      var first = WindowSet.decode(
        '{"v":1,"time":0,"main":{"site":"douyu","room":"9"},'
        '"mainAt":{"x":100,"y":50,"w":1400,"h":900,"scale":1.5},'
        '"mainSettings":{"volume":10.0,"muted":true},"windows":['
        '{"slot":1,"site":"douyu","room":"1","settings":{"volume":35.0}}'
        ']}',
      )!;
      expect(first.windows.single.settings, const WindowSettings(volume: 35));
      expect(first.windows.single.chatCollapsed, isFalse);
      expect(first.mainChatCollapsed, isFalse);
      expect(first.mainPlacement!.rect, const Rect.fromLTWH(100, 50, 1400, 900));
      expect(first.mainSettings, const WindowSettings(volume: 10, muted: true));

      // 主窗口的位置、设置坏了：只是不用；窗口的设置坏了：丢掉那一个
      var bad = WindowSet.decode(
        '{"v":1,"main":{"site":"douyu","room":"9"},'
        '"mainAt":{"x":1,"y":2,"w":0,"h":4,"scale":1},'
        '"mainSettings":{"volume":300},"windows":['
        '{"slot":1,"site":"douyu","room":"1","settings":{"muted":"yes"}},'
        '{"slot":2,"site":"douyu","room":"2","settings":{"volume":40}}'
        ']}',
      )!;
      expect(bad.mainRoom, room("9"));
      expect(bad.mainPlacement, isNull);
      expect(bad.mainSettings, isNull);
      expect(bad.windows.map((e) => e.slot), [2]);
      expect(bad.windows.single.settings, const WindowSettings(volume: 40));
      expect(
          WindowSet.decode('{"v":1,"mainAt":{"x":1,"y":2,"w":3,"h":4,'
                  '"scale":20},"windows":[]}')!
              .mainPlacement,
          isNull);

      // 直播间关掉时记的：读回来一样，不对的抛 FormatException
      const layout = RoomLayout(
          size: Size(1200, 700),
          scale: 1.5,
          windowFull: true,
          audioDevice: "wasapi/{b}");
      expect(RoomLayout.fromJson(layout.toJson()), layout);
      expect(RoomLayout.fromJson(const RoomLayout(windowFull: true).toJson()),
          const RoomLayout(windowFull: true));
      for (var badLayout in <Object?>[
        null,
        "x",
        {"w": 0, "h": 10, "scale": 1},
        {"w": 10, "scale": 1},
        {"w": 10, "h": 10},
        {"w": 10, "h": 10, "scale": 20},
        {"full": "yes"},
        {"device": 1},
      ]) {
        expect(() => RoomLayout.fromJson(badLayout), throwsFormatException,
            reason: "$badLayout");
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

    test("窗口全屏、置顶照上次的，带进启动参数；主窗口不按这一组来、现在置顶着时都置顶", () {
      var dataDir = p.join(
          Directory.systemTemp.path, "sl_support", "multi_window", "w1-1");
      var plan = WindowRestore.plan(
        saved([
          WindowEntry(
              slot: 1, room: room("1"), bounds: cells[0], windowFull: true),
          WindowEntry(slot: 2, room: room("2"), bounds: cells[1], pinned: true),
          entry(3, "3", cells[2]),
          WindowEntry(
              slot: 4,
              room: room("4"),
              bounds: const Rect.fromLTWH(2000, 100, 1200, 700),
              scale: 1.5,
              windowFull: true,
              pinned: true),
        ]),
        screens: [left, right],
        main: left.work,
      );
      // 副窗口的启动参数：主窗口开窗口时照这样写（WindowEntry.toLaunch）
      List<SecondaryLaunch> launches({bool followPin = false}) => [
            for (var t in plan.windows)
              SecondaryLaunch.parse(t
                  .reopen(followPin: followPin)
                  .toLaunch(
                      port: 50123,
                      token: WindowToken.generate(),
                      dataDir: dataDir,
                      mainPid: 4321)
                  .toArgs())!,
          ];
      var args = launches();
      expect(args.map((e) => e.slot), [1, 2, 3, 4]);
      expect(args.map((e) => e.roomId), ["1", "2", "3", "4"]);
      expect(args.map((e) => e.windowFull), [true, false, false, true]);
      expect(args.map((e) => e.pinned), [false, true, false, true]);
      expect(args.map((e) => e.bounds), [
        cells[0],
        cells[1],
        cells[2],
        const Rect.fromLTWH(2000, 100, 1200, 700)
      ]);
      expect(args.last.scale, 1.5);
      // 主窗口在看别的直播间、置顶着：都一出来就置顶，窗口全屏照上次的
      args = launches(followPin: true);
      expect(args.map((e) => e.pinned), [true, true, true, true]);
      expect(args.map((e) => e.windowFull), [true, false, false, true]);
      // 开着的这一组记下的也是这样
      var reopened = plan.windows.first.reopen();
      expect(reopened.slot, 1);
      expect(reopened.room, room("1"));
      expect(reopened.bounds, cells[0]);
      expect(reopened.windowFull, isTrue);
      expect(reopened.pinned, isFalse);
      // 以前存的一组（没有这两项）：都不是窗口全屏、不置顶
      var old = WindowSet.decode('{"v":1,"windows":['
          '{"slot":1,"site":"douyu","room":"1","x":8,"y":8,"w":629,"h":504,"scale":1}'
          ']}')!;
      var oldArgs = WindowRestore.plan(old, screens: [left], main: left.work)
          .windows
          .single
          .reopen()
          .toLaunch(
              port: 50123, token: WindowToken.generate(), dataDir: dataDir)
          .toArgs();
      expect(oldArgs.any((e) => e.startsWith("--sl-full")), isFalse);
      expect(oldArgs.any((e) => e.startsWith("--sl-pinned")), isFalse);
      expect(SecondaryLaunch.parse(oldArgs)!.bounds, cells[0]);
    });

    test("新开窗口（不是打开这一组）：用这个直播间关掉时的大小、窗口全屏和声音，位置照这个编号的", () {
      var dataDir = p.join(
          Directory.systemTemp.path, "sl_support", "multi_window", "w2-1");
      // 这个编号记的位置（或者错开放的）
      var where = WindowRestore.place(2,
          screens: [left, right],
          remembered: {
            2: const WindowPlacement(Rect.fromLTWH(300, 200, 800, 500), 1.0),
          },
          main: left.work)!;
      expect(where.$1, const Rect.fromLTWH(300, 200, 800, 500));
      // 在 150% 的屏幕上关的 1500x900：换到 100% 的屏幕是 1000x600，左上角照这个编号的
      const memory = RoomLayout(
          size: Size(1500, 900),
          scale: 1.5,
          windowFull: true,
          audioDevice: "wasapi/{b}");
      var opened = WindowRestore.opening(2, room("5"), where,
          memory: memory, screens: [left, right], pinned: true);
      expect(opened.bounds, const Rect.fromLTWH(300, 200, 1000, 600));
      expect(opened.scale, 1.0);
      expect(opened.windowFull, isTrue);
      expect(opened.pinned, isTrue);
      var args = SecondaryLaunch.parse(opened
          .toLaunch(
              port: 50123, token: WindowToken.generate(), dataDir: dataDir)
          .toArgs())!;
      expect(args.bounds, const Rect.fromLTWH(300, 200, 1000, 600));
      expect(args.windowFull, isTrue);
      // 放不下时整个挪进屏幕（位置本来就不记）
      var big = WindowRestore.opening(2, room("5"), where,
          memory: const RoomLayout(size: Size(1800, 1000)),
          screens: [left, right]);
      expect(big.bounds, const Rect.fromLTWH(120, 32, 1800, 1000));
      // 没关过：照这个编号的，不窗口全屏
      var plain =
          WindowRestore.opening(2, room("5"), where, screens: [left, right]);
      expect(plain.bounds, where.$1);
      expect(plain.windowFull, isFalse);
      expect(plain.pinned, isFalse);
      // 一块屏幕都读不到：居中，大小也不管
      var none = WindowRestore.opening(2, room("5"), null,
          memory: memory, fallbackScale: 1.25);
      expect(none.bounds, isNull);
      expect(none.scale, 1.25);
      expect(none.windowFull, isTrue);

      // 声音：记过静音的照记的（不静音就不静音，“默认静音”开着也一样），
      // 没记过静音时“默认静音”开着先静音
      const roomSettings = WindowSettings(volume: 40, muted: false);
      expect(WindowRestore.openingSettings(muteNew: true, room: roomSettings),
          roomSettings);
      expect(
          WindowRestore.openingSettings(
                  muteNew: false, room: roomSettings.withMuted(true))
              .muted,
          isTrue);
      expect(
          WindowRestore.openingSettings(
              muteNew: true, room: const WindowSettings(volume: 40)),
          const WindowSettings(volume: 40, muted: true));
      expect(WindowRestore.openingSettings(muteNew: false).muted, isFalse);
      expect(
          WindowRestore.openingSettings(
              muteNew: true,
              room: roomSettings,
              audioDevice: memory.audioDevice),
          const WindowSettings(
              volume: 40, muted: false, audioDevice: "wasapi/{b}"));
    });

    test("打开这一组：这一组记的优先，不用直播间关掉时记的", () {
      var plan = WindowRestore.plan(
        saved([
          WindowEntry(
              slot: 1,
              room: room("1"),
              bounds: cells[0],
              settings: const WindowSettings(
                  volume: 30, muted: false, danmaku: false, quality: "原画")),
          // 以前存的：没有音量这些
          WindowEntry(slot: 2, room: room("2"), bounds: cells[1]),
        ]),
        screens: [left],
        main: left.work,
      );
      // 这两个直播间平常记的（关掉时记的）不一样
      const roomSettings =
          WindowSettings(volume: 80, muted: true, danmaku: true, quality: "流畅");
      var first = plan.windows[0];
      expect(first.reopen().bounds, cells[0]);
      expect(first.reopen().windowFull, isFalse);
      expect(
          first.launchSettings(muteNew: true, room: roomSettings),
          const WindowSettings(
              volume: 30, muted: false, danmaku: false, quality: "原画"));
      // 没有这一组记的：用直播间记的
      expect(plan.windows[1].launchSettings(muteNew: true, room: roomSettings),
          roomSettings);
    });

    test("主窗口：只有打开这一组时才用这一组记的位置、窗口全屏、声音这些", () {
      const mainAt = WindowPlacement(Rect.fromLTWH(-1920, 0, 1600, 900), 1.25,
          maximized: true);
      const mainSettings = WindowSettings(
          volume: 20, muted: false, danmaku: false, quality: "蓝光");
      var set = WindowSet(
        [entry(1, "1", cells[0])],
        mainRoom: room("9"),
        mainFull: true,
        mainPinned: true,
        mainPlacement: mainAt,
        mainSettings: mainSettings,
        time: time,
      );
      var stored = WindowSet.decode(set.encode())!;
      // 主窗口不在直播间里：在主窗口打开那个直播间，全部照记的
      var plan = WindowRestore.plan(stored, screens: [left], main: left.work);
      var forMain = WindowRestore.mainFor(stored, plan)!;
      expect(forMain.room, room("9"));
      expect(forMain.windowFull, isTrue);
      expect(forMain.pinned, isTrue);
      expect(forMain.placement!.rect, mainAt.rect);
      expect(forMain.placement!.maximized, isTrue);
      expect(forMain.settings, mainSettings);
      // 主窗口已经在这个直播间里（观看记录里打开一组）：一样
      plan = WindowRestore.plan(stored,
          screens: [left], main: left.work, mainRoomNow: room("9"));
      forMain = WindowRestore.mainFor(stored, plan, mainRoomNow: room("9"))!;
      expect(forMain.room, room("9"));
      expect(forMain.settings, mainSettings);
      // 主窗口在看别的直播间：主窗口不动
      plan = WindowRestore.plan(stored,
          screens: [left], main: left.work, mainRoomNow: room("7"));
      expect(
          WindowRestore.mainFor(stored, plan, mainRoomNow: room("7")), isNull);
      // 什么都没打开（都已经开着）：不动
      plan = WindowRestore.plan(stored,
          screens: [left], main: left.work, openRooms: {"douyu|1", "douyu|9"});
      expect(WindowRestore.mainFor(stored, plan), isNull);
      // 主窗口上次的直播间已经在副窗口里开着：只放回位置、置顶
      plan = WindowRestore.plan(stored,
          screens: [left], main: left.work, openRooms: {"douyu|9"});
      forMain = WindowRestore.mainFor(stored, plan)!;
      expect(forMain.room, isNull);
      expect(forMain.windowFull, isFalse);
      expect(forMain.settings, isNull);
      expect(forMain.placement!.rect, mainAt.rect);
      expect(forMain.pinned, isTrue);

      // 平常打开主窗口的直播间（没有打开这一组）：什么都不用，就算上次的一组里记着
      MultiWindow.mainRestoreRequest.value = null;
      expect(MultiWindow.takeMainRestore(room("9")), isNull);
      // 打开这一组：主窗口的这个直播间用一次
      MultiWindow.requestMainRestore(WindowRestore.mainFor(
          stored, WindowRestore.plan(stored, screens: [left]))!);
      expect(MultiWindow.takeMainRestore(room("8")), isNull);
      var taken = MultiWindow.takeMainRestore(room("9"))!;
      expect(taken.windowFull, isTrue);
      expect(taken.settings, mainSettings);
      expect(MultiWindow.takeMainRestore(room("9")), isNull);
      // 没有直播间的（只放位置、置顶）不交给直播间页面
      MultiWindow.requestMainRestore(const MainRestore(pinned: true));
      expect(MultiWindow.mainRestoreRequest.value, isNull);
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
