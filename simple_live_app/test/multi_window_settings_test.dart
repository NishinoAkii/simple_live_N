import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/multi_window/window_frame.dart';
import 'package:simple_live_app/app/multi_window/window_layout.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';
import 'package:simple_live_app/services/sync_compat.dart';

import 'fakes/memory_storage.dart';

// 多开窗口（1.24.3）：贴靠的位置放回去还贴着边、新开的默认静音、每个窗口的设置跟着那一组、
// 观看记录里一组的主窗口直播间、声音输出设备不在了、哪些设置能同步

WindowRoom room(String id) => WindowRoom(siteId: "douyu", roomId: id);

WindowEntry entry(int slot, String id, {Rect? bounds}) =>
    WindowEntry(slot: slot, room: room(id), bounds: bounds);

void main() {
  // 左边 1080p 100%（可用区域去掉 48 的任务栏），右边 2560×1600 150%
  const left = ScreenArea(Rect.fromLTWH(0, 0, 1920, 1032), 1.0);
  const right = ScreenArea(Rect.fromLTWH(1920, 0, 2560, 1528), 1.5);

  group("贴靠到屏幕边上、角上的窗口：放回去还贴着", () {
    test("100%：看不见的边框 7 像素，记看得见的部分，放回去换回外框", () {
      // 贴到左上角的四分之一：看得见的部分正好是可用区域的左上四分之一，
      // GetWindowRect 的外框左、右、下各伸出去 7
      const visible = Rect.fromLTWH(0, 0, 960, 516);
      const outer = Rect.fromLTRB(-7, 0, 967, 523);
      var insets = FrameInsets.between(outer, visible);
      expect(insets, const FrameInsets(7, 0, 7, 7));
      expect(insets, FrameInsets.estimate(1.0));
      expect(insets.visibleOf(outer), visible);
      // 以前记外框、按外框往屏幕里挪：左边被拉进来 7 像素，不贴边了
      expect(WindowLayout.clampInto(outer, left.work)!.left, 0);
      expect(
          insets.visibleOf(WindowLayout.clampInto(outer, left.work)!).left, 7);
      // 现在：四个角原样放回，外框和贴靠时一样
      for (var quadrant in const [
        Rect.fromLTWH(0, 0, 960, 516),
        Rect.fromLTWH(960, 0, 960, 516),
        Rect.fromLTWH(0, 516, 960, 516),
        Rect.fromLTWH(960, 516, 960, 516),
      ]) {
        var spot = WindowRestore.savedSpot(quadrant, 1.0, [left, right])!;
        expect(spot, (quadrant, 1.0), reason: "$quadrant");
        expect(insets.outerOf(spot.$1).left, quadrant.left - 7);
        expect(insets.outerOf(spot.$1).bottom, quadrant.bottom + 7);
      }
    });

    test("150%：边框按缩放算（11 像素），右边副屏的四个角原样放回", () {
      var insets = FrameInsets.estimate(1.5);
      expect(insets, const FrameInsets(11, 0, 11, 11));
      for (var quadrant in const [
        Rect.fromLTWH(1920, 0, 1280, 764),
        Rect.fromLTWH(3200, 0, 1280, 764),
        Rect.fromLTWH(1920, 764, 1280, 764),
        Rect.fromLTWH(3200, 764, 1280, 764),
      ]) {
        var outer = insets.outerOf(quadrant);
        expect(FrameInsets.between(outer, quadrant), insets);
        expect(WindowRestore.savedSpot(quadrant, 1.5, [left, right]),
            (quadrant, 1.5),
            reason: "$quadrant");
      }
      // 屏幕信息换算差了一个像素：不往里挪
      const off = ScreenArea(Rect.fromLTWH(1920, 0, 2560, 1527), 1.5);
      expect(
          WindowRestore.savedSpot(
                  const Rect.fromLTWH(3200, 764, 1280, 764), 1.5, [left, off])!
              .$1,
          const Rect.fromLTWH(3200, 764, 1280, 764));
      // 真的超出去一截：照样整个挪进来
      expect(
          WindowRestore.savedSpot(const Rect.fromLTWH(3400, 900, 1280, 764),
                  1.5, [left, right])!
              .$1,
          const Rect.fromLTWH(3200, 764, 1280, 764));
    });

    test("量出来不像边框时按估的", () {
      expect(const FrameInsets(7, 0, 7, 7).isSane, isTrue);
      expect(const FrameInsets(-3, 0, 7, 7).isSane, isFalse);
      expect(const FrameInsets(7, 0, 7, 200).isSane, isFalse);
    });
  });

  group("设置", () {
    late MemoryStorage storage;
    WindowRoom? mainRoom;
    var grouped = <WindowSet>[];

    WindowSetRecorder create() => WindowSetRecorder(
          mainRoom: () => mainRoom,
          saveDelay: Duration.zero,
          onGroupClosed: (set) async => grouped.add(set),
        );

    setUp(() {
      storage = MemoryStorage.install();
      mainRoom = null;
      grouped = [];
      MultiWindowPrefs.reset();
    });

    tearDown(() {
      MultiWindowPrefs.reset();
      Get.reset();
    });

    test("新开的多开窗口默认静音（默认开）；打开上次的按关的时候", () async {
      expect(MultiWindowPrefs.muteNew.value, isTrue);
      expect(MultiWindowPrefs.devicePerWindow.value, isFalse);
      const saved = WindowSettings(
          volume: 40, muted: false, danmaku: false, quality: "超清");
      // 新开的：一定先静音，别的照这个直播间记的
      expect(
          WindowSettings.initial(restored: false, muteNew: true, room: saved),
          const WindowSettings(
              volume: 40, muted: true, danmaku: false, quality: "超清"));
      expect(WindowSettings.initial(restored: false, muteNew: true),
          const WindowSettings(muted: true));
      // 关了“默认静音”：照记的，没记过时不静音
      expect(
          WindowSettings.initial(restored: false, muteNew: false, room: saved)
              .muted,
          isFalse);
      expect(WindowSettings.initial(restored: false, muteNew: false).muted,
          isFalse);
      // 打开上次的：关的时候没静音就不静音；没记过时按“默认静音”
      expect(
          WindowSettings.initial(restored: true, muteNew: true, room: saved)
              .muted,
          isFalse);
      expect(
          WindowSettings.initial(restored: true, muteNew: true).muted, isTrue);
      // 开关只在本机，改了存下
      await MultiWindowPrefs.setMuteNew(false);
      expect(storage.values[MultiWindowPrefs.kMuteNew], isFalse);
      MultiWindowPrefs.reset();
      expect(MultiWindowPrefs.muteNew.value, isFalse);
    });

    test("音量、静音、弹幕、清晰度按直播间记，声音输出设备记在这一组和这个编号上", () async {
      var recorder = create();
      recorder.opened(entry(1, "1"));
      recorder.reported(
          1,
          const WindowReport(
              settings: WindowSettings(
                  volume: 35,
                  muted: false,
                  danmaku: false,
                  quality: "原画",
                  audioDevice: "wasapi/{abc}")));
      // 之后只改了音量：别的留着
      recorder.reported(
          1, const WindowReport(settings: WindowSettings(volume: 60)));
      const expected = WindowSettings(
          volume: 60, muted: false, danmaku: false, quality: "原画");
      expect(recorder.roomSettings(room("1")), expected);
      expect(recorder.slotDevice(1), "wasapi/{abc}");
      expect(recorder.active.single.audioDevice, "wasapi/{abc}");
      // 设备不进按直播间记的（那部分要同步）
      var stored =
          jsonDecode(storage.values[WindowSetRecorder.kRoomSettings] as String)
              as Map;
      expect(stored["douyu_1"], {
        "volume": 60.0,
        "muted": false,
        "danmaku": false,
        "quality": "原画",
      });
      await recorder.closingAll();
      expect(recorder.last.value!.windows.single.audioDevice, "wasapi/{abc}");

      // 下次启动，打开上次的：和关的时候一样
      var next = create();
      var restored = WindowSettings.initial(
        restored: true,
        muteNew: true,
        room: next.roomSettings(room("1")),
        audioDevice: next.last.value!.windows.single.audioDevice,
      );
      expect(restored, expected.withDevice("wasapi/{abc}"));
      // 放进启动参数再读回来一样
      var launch = SecondaryLaunch(
        port: 1,
        token: WindowToken.generate(),
        dataDir: "/tmp/multi_window/w1-1",
        slot: 1,
        siteId: "douyu",
        roomId: "1",
        settings: restored.toJson(),
      );
      var parsed = SecondaryLaunch.parse(launch.toArgs())!;
      expect(WindowSettings.fromJson(parsed.settings), restored);
      // 坏了的参数不认
      expect(
          SecondaryLaunch.parse([
            ...launch.toArgs().where((e) => !e.startsWith("--sl-settings=")),
            "--sl-settings=not-base64!",
          ]),
          isNull);
      expect(() => WindowSettings.fromJson({"volume": 300}),
          throwsFormatException);
      expect(() => WindowSettings.fromJson({"muted": "yes"}),
          throwsFormatException);
    });

    test("一组记在主窗口的直播间名下：和主窗口一起关的才算，手动先关的不在里面", () async {
      var recorder = create();
      mainRoom = room("main");
      recorder.opened(entry(1, "a"));
      recorder.opened(entry(2, "b"));
      recorder.opened(entry(3, "c"));
      // 先手动关掉一个
      recorder.exited(2);
      await recorder.closingAll();
      var group = recorder.groupFor("douyu", "main")!;
      expect(group.windows.map((e) => e.room.roomId), ["a", "c"]);
      expect(group.mainRoom, room("main"));
      // 只有主窗口的直播间才问
      expect(recorder.groupFor("douyu", "a"), isNull);
      expect(recorder.groupFor("douyu", "b"), isNull);
      // 关的时候把观看记录的时间写在一起
      expect(grouped.single.windows.map((e) => e.room.roomId), ["a", "c"]);

      // 同一个直播间只留最近的一组
      recorder.opened(entry(1, "d"));
      await recorder.closingAll();
      expect(
          recorder.groupFor("douyu", "main")!.windows.single.room.roomId, "d");
      // 下次启动还在
      expect(
          create().groupFor("douyu", "main")!.windows.single.room.roomId, "d");

      // 主窗口不在直播间里、手动关掉最后一个：不算哪个直播间的一组
      mainRoom = null;
      recorder.opened(entry(1, "e"));
      await recorder.closingAll();
      mainRoom = room("other");
      recorder.opened(entry(1, "f"));
      recorder.exited(1);
      await Future<void>.delayed(Duration.zero);
      expect(recorder.groupFor("douyu", "other"), isNull);
      expect(grouped, hasLength(2));
    });

    test("声音输出设备不在了：用默认设备，要提示", () {
      var available = ["auto", "wasapi/{a}", "wasapi/{b}"];
      expect(pickAudioDevice("wasapi/{a}", available),
          (device: "wasapi/{a}", missing: false));
      expect(pickAudioDevice("wasapi/{gone}", available),
          (device: "auto", missing: true));
      expect(
          pickAudioDevice(null, available), (device: "auto", missing: false));
      expect(
          pickAudioDevice("auto", available), (device: "auto", missing: false));
    });

    test("只有按直播间记的设置跟着同步（放在扩展部分），位置和设备只在本机", () {
      const key = WindowSetRecorder.kRoomSettings;
      expect(SyncCompat.isExtSetting(key), isTrue);
      expect(SyncCompat.isLocalOnlySetting(key), isFalse);
      var settings = {key: "{}", "DanmuSize": 16.0};
      expect(SyncCompat.upstreamSettings(settings).containsKey(key), isFalse);
      expect(SyncCompat.extSettings(settings).containsKey(key), isTrue);
      expect(
          SyncCompat.mergeRestoredSettings(
              {key: "local"}, {}, {key: "remote"})[key],
          "remote");
      for (var local in [
        ...WindowSetRecorder.storageKeys,
        ...MultiWindowPrefs.storageKeys,
      ]) {
        expect(SyncCompat.isLocalOnlySetting(local), isTrue, reason: local);
        expect(SyncCompat.extSettings({local: "x"}).containsKey(local), isFalse,
            reason: local);
      }
    });
  });
}
