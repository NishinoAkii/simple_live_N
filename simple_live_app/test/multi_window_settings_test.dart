import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/multi_window/window_frame.dart';
import 'package:simple_live_app/app/multi_window/window_layout.dart';
import 'package:simple_live_app/app/multi_window/window_link.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';
import 'package:simple_live_app/app/play_prefs.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'fakes/fake_player.dart';
import 'fakes/memory_storage.dart';

// 多开窗口（1.24.3）：贴靠的位置放回去还贴着边、新开的默认静音（记过的静音优先）、
// 每个窗口的设置跟着那一组、观看记录里一组的主窗口直播间、声音输出设备不在了、
// 换直播间以后清晰度读到新的才报、哪些设置能同步；换直播间时原来那个还没读完的不用

WindowRoom room(String id) => WindowRoom(siteId: "douyu", roomId: id);

WindowEntry entry(int slot, String id, {Rect? bounds}) =>
    WindowEntry(slot: slot, room: room(id), bounds: bounds);

/// 不读本地存储的设置；按直播间记的弹幕设置不换（要 Hive）
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  void enterRoomContext(RoomContext context) {}
}

/// 开着播的平台：几档清晰度，[gate] 不为空时读清晰度要等它
class _FakeSite extends LiveSite {
  _FakeSite(this.qualities);
  final List<String> qualities;
  Completer<void>? gate;

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async =>
      LiveRoomDetail(
        roomId: roomId,
        title: "标题",
        cover: "",
        userName: "主播",
        userAvatar: "",
        online: 0,
        status: true,
        url: "",
      );

  @override
  Future<List<LivePlayQuality>> getPlayQualites(
      {required LiveRoomDetail detail}) async {
    await gate?.future;
    return [for (var n in qualities) LivePlayQuality(quality: n, data: n)];
  }

  @override
  Future<LivePlayUrl> getPlayUrls(
          {required LiveRoomDetail detail,
          required LivePlayQuality quality}) async =>
      LivePlayUrl(urls: ["https://a/${quality.quality}.flv"]);
}

/// 读直播间信息要等测试放行的平台（像抖音那样，读到的房间号可能和进的不一样）
class _GatedSite extends LiveSite {
  final _gates = <String, Completer<LiveRoomDetail>>{};

  /// 不为空时读 SC 要等它，为空时马上给 [superChats]
  Completer<List<LiveSuperChatMessage>>? scGate;
  List<LiveSuperChatMessage> superChats = [];

  /// 读房间号 [roomId] 的直播间信息：测试放行时给
  Completer<LiveRoomDetail> gate(String roomId) =>
      _gates.putIfAbsent(roomId, Completer.new);

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) =>
      gate(roomId).future;

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage(
          {required String roomId}) =>
      scGate?.future ?? Future.value(superChats);

  /// 不为空时取播放地址要等它
  Completer<LivePlayUrl>? urlGate;

  @override
  Future<LivePlayUrl> getPlayUrls(
          {required LiveRoomDetail detail,
          required LivePlayQuality quality}) =>
      urlGate?.future ?? Future.value(LivePlayUrl(urls: []));
}

LiveRoomDetail _detail(String roomId) => LiveRoomDetail(
      roomId: roomId,
      title: "标题$roomId",
      cover: "",
      userName: "主播$roomId",
      userAvatar: "",
      online: 0,
      status: false,
      url: "",
    );

FollowUser _douyinFollow(String roomId, {bool notify = false}) => FollowUser(
      id: "${Constant.kDouyin}_$roomId",
      roomId: roomId,
      siteId: Constant.kDouyin,
      userName: "主播$roomId",
      face: "",
      addTime: DateTime(2026, 11, 23),
      notify: notify,
    );

LiveSuperChatMessage _sc(String message) => LiveSuperChatMessage(
      backgroundBottomColor: "#000000",
      backgroundColor: "#000000",
      startTime: DateTime(2026, 11, 23, 20),
      endTime: DateTime(2026, 11, 23, 21),
      face: "",
      message: message,
      price: 30,
      userName: "观众",
    );

/// 副窗口连着主窗口：报的直接交给 [onReport]（不走本机的网络）
class _DirectLink extends Fake implements MainWindowLink {
  _DirectLink(this.onReport);
  final void Function(WindowReport report) onReport;

  @override
  Future<bool> report(WindowReport report) {
    onReport(report);
    return Future.value(true);
  }

  @override
  void dispose() {}
}

/// 不连 mpv 的播放器，静音、调音量时什么都不做
class _Player extends FakePlayer {
  @override
  Future<void> setVolume(double volume) async {}
}

/// 直播间页面：不连播放器
class _Room extends LiveRoomController {
  _Room(Site site, {String roomId = "1"}) : super(pSite: site, pRoomId: roomId);

  @override
  // ignore: overridden_fields
  final Player player = _Player();

  @override
  Future<void> openPlaylist({int startIndex = 0}) async {}

  /// 不为空时选清晰度档位（看是不是数据网络）要等它
  Completer<void>? levelGate;

  @override
  Future<int> getQualityLevel() async {
    await levelGate?.future;
    return super.getQualityLevel();
  }

  /// loadData 里读到直播间信息以后那一段：读清晰度、选一个、取地址
  Future<void> loadQualities() async {
    detail.value = await site.liveSite.getRoomDetail(roomId: roomId);
    liveStatus.value = true;
    getPlayQualites();
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 在关注列表里点了别的直播间。多开的那部分在 resetRoom 一开始就做完；
  /// 测试里没有 SmartDialog，之后的 loadData 一开始就停下（错误不管），清晰度由测试自己读
  void switchTo(Site site, String roomId) {
    runZonedGuarded(() => resetRoom(site, roomId), (_, __) {});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

    test("记过的静音优先；没记过静音时按“新开的多开窗口默认静音”（默认开）", () async {
      expect(MultiWindowPrefs.muteNew.value, isTrue);
      expect(MultiWindowPrefs.devicePerWindow.value, isFalse);
      const saved = WindowSettings(
          volume: 40, muted: false, danmaku: false, quality: "超清");
      // 记过不静音：“默认静音”开着也不静音，别的照记的
      expect(WindowSettings.initial(muteNew: true, room: saved), saved);
      // 记过静音：“默认静音”关着也静音，音量还是记的（取消静音时回到它）
      expect(
          WindowSettings.initial(muteNew: false, room: saved.withMuted(true)),
          saved.withMuted(true));
      // 没记过静音（只记了音量这些）、什么都没记过：按“默认静音”
      const noMute = WindowSettings(volume: 40, danmaku: false);
      expect(WindowSettings.initial(muteNew: true, room: noMute),
          const WindowSettings(volume: 40, muted: true, danmaku: false));
      expect(WindowSettings.initial(muteNew: true),
          const WindowSettings(muted: true));
      expect(
          WindowSettings.initial(muteNew: false, room: noMute).muted, isFalse);
      expect(WindowSettings.initial(muteNew: false).muted, isFalse);
      // 开关只在本机，改了存下
      await MultiWindowPrefs.setMuteNew(false);
      expect(storage.values[MultiWindowPrefs.kMuteNew], isFalse);
      MultiWindowPrefs.reset();
      expect(MultiWindowPrefs.muteNew.value, isFalse);
    });

    test("音量、静音、弹幕、清晰度按直播间记（改了马上记，关掉时全部记），声音输出设备记在这一组和这个编号上",
        () async {
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
      // 开着时记在这一组里；改了的音量马上记成这个直播间的（一开始报上来的那些关掉时才记），
      // 设备关掉时才记在这个编号上
      expect(recorder.active.single.settings, expected);
      expect(recorder.active.single.audioDevice, "wasapi/{abc}");
      expect(recorder.roomSettings(room("1")), const WindowSettings(volume: 60));
      expect(recorder.slotDevice(1), isNull);
      await recorder.closingAll();
      expect(recorder.last.value!.windows.single.audioDevice, "wasapi/{abc}");
      expect(recorder.last.value!.windows.single.settings, expected);
      recorder.exited(1);
      await recorder.flush();
      expect(recorder.roomSettings(room("1")), expected);
      expect(recorder.slotDevice(1), "wasapi/{abc}");
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

      // 下次启动，打开上次的：和关的时候一样（这一组里记的）
      var next = create();
      var restored = WindowSettings.initial(
        muteNew: true,
        room: next.last.value!.windows.single.settings,
        audioDevice: next.last.value!.windows.single.audioDevice,
      );
      expect(restored, expected.withDevice("wasapi/{abc}"));
      expect(next.roomSettings(room("1")), expected);
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

    test("直播间页面换直播间：报的设置等读到新直播间的清晰度才带清晰度", () async {
      Get.put<AppSettingsController>(_TestSettings());
      PlayPrefs.instance = PlayPrefs.forTest();
      MultiWindow.debugSupported = true;
      var fakeA = _FakeSite(["原画", "高清"]);
      var a = Site(id: "ta", liveSite: fakeA, logo: "", name: "甲");
      var b = Site(
          id: "tb", liveSite: _FakeSite(["蓝光", "高清"]), logo: "", name: "乙");
      var page = _Room(a);
      addTearDown(() {
        MultiWindow.leaveRoom(page);
        MultiWindow.debugSupported = null;
        PlayPrefs.instance = null;
      });
      // 主窗口的直播间页面（副窗口报的是同一份）
      WindowSettings? reported() => MultiWindow.mainLayoutNow().settings;
      page.initMultiWindowForTest();
      expect(MultiWindow.mainRoom!.key, "ta|1");
      expect(reported()!.quality, isNull);
      await page.loadQualities();
      expect(page.currentQualityInfo.value, "高清");
      expect(reported()!.quality, "高清");

      // 换到乙：马上报的从现在的音量这些算起，不带甲的清晰度（currentQualityInfo 这时还是甲的）
      page.switchTo(b, "2");
      expect(MultiWindow.mainRoom!.key, "tb|2");
      expect(page.currentQualityInfo.value, "高清");
      expect(reported(),
          const WindowSettings(volume: 100, muted: false, danmaku: false));
      // 乙的清晰度读到之前点了静音：报的也不带
      page.muted.value = true;
      expect(reported(),
          const WindowSettings(volume: 100, muted: true, danmaku: false));
      // 乙没读到就换回甲：甲上次读到的也不带，等这次读到
      page.switchTo(a, "1");
      expect(MultiWindow.mainRoom!.key, "ta|1");
      expect(reported()!.quality, isNull);
      // 读到甲的：选的和原来同名（currentQualityInfo 没变），照样报
      await page.loadQualities();
      expect(reported()!.quality, "高清");

      // 甲的清晰度还在读时换到乙：读到的甲的不用，不算乙的
      fakeA.gate = Completer<void>();
      page.getPlayQualites();
      page.switchTo(b, "2");
      fakeA.gate!.complete();
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(page.qualites, isEmpty);
      expect(page.currentQuality, -1);
      expect(reported()!.quality, isNull);
      // 读到乙的
      await page.loadQualities();
      expect(page.qualites.map((e) => e.quality), ["蓝光", "高清"]);
      expect(reported()!.quality, "高清");
      expect(MultiWindow.mainRoom!.key, "tb|2");
    });

    test("读到清晰度以后、选档位时换了直播间：选的是原来那个的，不用，不算新直播间的", () async {
      Get.put<AppSettingsController>(_TestSettings());
      PlayPrefs.instance = PlayPrefs.forTest();
      MultiWindow.debugSupported = true;
      var a = Site(
          id: "ta", liveSite: _FakeSite(["原画", "高清"]), logo: "", name: "甲");
      var b = Site(
          id: "tb", liveSite: _FakeSite(["蓝光", "高清"]), logo: "", name: "乙");
      var page = _Room(a);
      addTearDown(() {
        MultiWindow.leaveRoom(page);
        MultiWindow.debugSupported = null;
        PlayPrefs.instance = null;
      });
      WindowSettings? reported() => MultiWindow.mainLayoutNow().settings;
      page.initMultiWindowForTest();
      // 甲的清晰度读到了，还在看是不是数据网络时换到乙
      page.levelGate = Completer<void>();
      await page.loadQualities();
      page.switchTo(b, "2");
      page.levelGate!.complete();
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(page.qualites, isEmpty);
      expect(page.currentQuality, -1);
      expect(page.currentQualityInfo.value, "");
      expect(reported()!.quality, isNull);
      // 读到乙的
      page.levelGate = null;
      await page.loadQualities();
      expect(page.qualites.map((e) => e.quality), ["蓝光", "高清"]);
      expect(reported()!.quality, "高清");
    });

    test("副窗口里换了直播间：马上从现在的设置报起，之后第一次改就记成新直播间的；静音不改音量", () async {
      Get.put<AppSettingsController>(_TestSettings());
      PlayPrefs.instance = PlayPrefs.forTest();
      MultiWindow.debugSupported = true;
      var recorder = create();
      const ta = WindowRoom(siteId: "ta", roomId: "1");
      const tb = WindowRoom(siteId: "tb", roomId: "2");
      // 主窗口开这个窗口时给的：甲记的音量 40、没静音
      const launched = WindowSettings(volume: 40, muted: false);
      MultiWindow.launch = SecondaryLaunch(
        port: 1,
        token: WindowToken.generate(),
        dataDir: "/tmp/multi_window/w1-1",
        slot: 1,
        siteId: "ta",
        roomId: "1",
        settings: launched.toJson(),
      );
      recorder.opened(const WindowEntry(slot: 1, room: ta, settings: launched));
      // 副窗口报的照收发的格式过一遍，交给主窗口记着的这一组
      MultiWindow.link = _DirectLink(
          (r) => recorder.reported(1, WindowReport.decode(r.toJson())));
      var a = Site(
          id: "ta", liveSite: _FakeSite(["原画", "高清"]), logo: "", name: "甲");
      var b = Site(
          id: "tb", liveSite: _FakeSite(["蓝光", "高清"]), logo: "", name: "乙");
      var page = _Room(a);
      addTearDown(() {
        MultiWindow.link?.dispose();
        MultiWindow.link = null;
        MultiWindow.launch = null;
        MultiWindow.debugSupported = null;
        PlayPrefs.instance = null;
      });
      page.initMultiWindowForTest();
      await page.loadQualities();
      // 还没到报的时候的马上报（关窗口之前也是这样）
      await MultiWindow.reportPlacementNow();
      const inA = WindowSettings(
          volume: 40, muted: false, danmaku: false, quality: "高清");
      expect(recorder.active.single.settings, inA);
      // 报的音量、静音和开的时候给的一样：不算改动
      expect(recorder.roomSettings(ta), isNull);

      // 换到乙：甲照关掉一样记下
      page.switchTo(b, "2");
      expect(recorder.active.single.room.key, tb.key);
      expect(recorder.roomSettings(ta), inA);
      // 乙里第一次改（点了静音）：马上记成乙的
      page.setMuted(true);
      await MultiWindow.reportPlacementNow();
      expect(recorder.roomSettings(tb), const WindowSettings(muted: true));
      // 静音不改音量：报的、关掉时记的都是静音之前的 40，取消静音时回到它
      expect(AppSettingsController.instance.playerVolume.value, 40);
      expect(recorder.active.single.settings!.volume, 40);
      // 取消静音，再调成 0 马上又点了静音（连着改，报上来的是一次）：记的是 0
      page.setMuted(false);
      await MultiWindow.reportPlacementNow();
      AppSettingsController.instance.playerVolume.value = 0;
      page.setMuted(true);
      await MultiWindow.reportPlacementNow();
      expect(recorder.roomSettings(tb),
          const WindowSettings(volume: 0, muted: true));
      recorder.exited(1);
      expect(recorder.roomSettings(tb),
          const WindowSettings(volume: 0, muted: true, danmaku: false));
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

  group("原来那个直播间还没读完就换了直播间", () {
    late Directory dir;
    late DBService db;

    setUp(() async {
      Get.testMode = true;
      dir = Directory.systemTemp.createTempSync("sl_room_switch_");
      Hive.init(dir.path);
      if (!Hive.isAdapterRegistered(1)) {
        Hive.registerAdapter(FollowUserAdapter());
      }
      if (!Hive.isAdapterRegistered(2)) {
        Hive.registerAdapter(HistoryAdapter());
      }
      // 放在内存里：控件测试的假时钟里写文件写不完
      db = DBService()
        ..followBox =
            await Hive.openBox<FollowUser>("FollowUser", bytes: Uint8List(0))
        ..historyBox =
            await Hive.openBox<History>("History", bytes: Uint8List(0));
      Get.put(db);
      MemoryStorage.install();
      var settings = Get.put<AppSettingsController>(_TestSettings());
      // SC 都显示（不按时间筛）
      settings.superChatDisplayMode.value = 1;
      PlayPrefs.instance = PlayPrefs.forTest();
    });

    tearDown(() async {
      PlayPrefs.instance = null;
      Get.reset();
      await Hive.close().timeout(const Duration(seconds: 20));
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// 有加载提示（SmartDialog）的界面
    Future<void> pumpApp(WidgetTester tester) =>
        tester.pumpWidget(GetMaterialApp(
          navigatorObservers: [FlutterSmartDialog.observer],
          builder: FlutterSmartDialog.init(),
          home: const SizedBox(),
        ));

    testWidgets("读到的直播间信息、SC、读出的错是原来那个的：不用，抖音关注的直播间也不会被换掉", (tester) async {
      await pumpApp(tester);
      var fake = _GatedSite();
      var douyin =
          Site(id: Constant.kDouyin, liveSite: fake, logo: "", name: "抖音");
      await db.addFollow(_douyinFollow("88"));
      // 在关注着的 1 里，直播间信息还没读到就在关注列表里点了 88
      var page = _Room(douyin, roomId: "1")..followed.value = true;
      page.loadData();
      await tester.pump();
      page.resetRoom(douyin, "88");
      await tester.pump();
      expect(page.roomId, "88");
      // 1 的读到了（抖音给的房间号和 88 对不上）：不用，不当作 88 换了房间号
      fake.gate("1").complete(_detail("1"));
      await tester.pump();
      expect(page.roomId, "88");
      expect(page.detail.value, isNull);
      expect(page.loadError.value, isFalse);
      expect(db.followBox.keys, ["douyin_88"]);
      // 88 的读到了：照常用上；88 的 SC 还在读
      fake.scGate = Completer();
      fake.gate("88").complete(_detail("88"));
      await tester.pump();
      expect(page.detail.value!.roomId, "88");
      expect(page.followed.value, isTrue);
      expect(page.loadError.value, isFalse);
      // SC 还没读到就换到 99：读到的 88 的 SC 不要
      page.resetRoom(douyin, "99");
      await tester.pump();
      fake.scGate!.complete([_sc("88 的")]);
      await tester.pump();
      expect(page.superChats, isEmpty);
      // 99 的照常读到
      fake.scGate = null;
      fake.superChats = [_sc("99 的")];
      fake.gate("99").complete(_detail("99"));
      await tester.pumpAndSettle();
      expect(page.detail.value!.roomId, "99");
      expect(page.superChats.map((e) => e.message), ["99 的"]);
      expect(db.followBox.keys, ["douyin_88"]);
      // 100 还没读到就换到 101，100 的读出错了：不算 101 没加载出来
      page.resetRoom(douyin, "100");
      await tester.pump();
      page.resetRoom(douyin, "101");
      await tester.pump();
      fake.gate("100").completeError(StateError("读不到"));
      await tester.pump();
      expect(page.loadError.value, isFalse);
      fake.gate("101").complete(_detail("101"));
      await tester.pumpAndSettle();
      expect(page.detail.value!.roomId, "101");
      expect(page.loadError.value, isFalse);
      // 等 3 秒，让后台的计时器走完
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets("没换直播间时抖音换成平台认的房间号：照旧改，关注跟着换过去", (tester) async {
      await pumpApp(tester);
      var fake = _GatedSite();
      var douyin =
          Site(id: Constant.kDouyin, liveSite: fake, logo: "", name: "抖音");
      await db.addFollow(_douyinFollow("71", notify: true));
      var page = _Room(douyin, roomId: "71")..followed.value = true;
      page.loadData();
      await tester.pump();
      fake.gate("71").complete(_detail("7001"));
      await tester.pumpAndSettle();
      expect(page.roomId, "7001");
      expect(page.detail.value!.roomId, "7001");
      expect(db.followBox.keys, ["douyin_7001"]);
      expect(db.followBox.get("douyin_7001")!.notify, isTrue);
      expect(page.followed.value, isTrue);
      expect(page.loadError.value, isFalse);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets("从没关注的直播间换到关注着的抖音旧房间号：关注照样换到平台认的房间号", (tester) async {
      await pumpApp(tester);
      var fake = _GatedSite();
      var douyin =
          Site(id: Constant.kDouyin, liveSite: fake, logo: "", name: "抖音");
      await db.addFollow(_douyinFollow("71", notify: true));
      // 上一个直播间没关注（followed 还是它的）
      var page = _Room(douyin, roomId: "5")..followed.value = false;
      page.resetRoom(douyin, "71");
      await tester.pump();
      fake.gate("71").complete(_detail("7001"));
      await tester.pumpAndSettle();
      expect(page.roomId, "7001");
      expect(db.followBox.keys, ["douyin_7001"]);
      expect(db.followBox.get("douyin_7001")!.notify, isTrue);
      expect(page.followed.value, isTrue);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets("原来那个直播间的播放地址换了直播间以后才取到：不播", (tester) async {
      await pumpApp(tester);
      var fake = _GatedSite();
      var site = Site(id: "test", liveSite: fake, logo: "", name: "测试");
      var page = _Room(site, roomId: "1");
      page.detail.value = _detail("1");
      page.qualites.value = [LivePlayQuality(quality: "原画", data: "x")];
      page.currentQuality = 0;
      fake.urlGate = Completer();
      page.getPlayUrl();
      await tester.pump();
      page.resetRoom(site, "2");
      await tester.pump();
      fake.urlGate!.complete(LivePlayUrl(urls: ["https://old/1.flv"]));
      await tester.pump();
      expect(page.playUrls, isEmpty);
      // 2 的直播间信息照常读到
      fake.gate("2").complete(_detail("2"));
      await tester.pumpAndSettle();
      expect(page.detail.value!.roomId, "2");
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets("断流重连时换了直播间：原来那个直播间“已下播”不写进新的直播间", (tester) async {
      await pumpApp(tester);
      var fake = _GatedSite();
      var site = Site(id: "test", liveSite: fake, logo: "", name: "测试");
      var page = _Room(site, roomId: "1");
      page.detail.value = _detail("1");
      page.liveStatus.value = true;
      page.qualites.value = [LivePlayQuality(quality: "原画", data: "x")];
      page.currentQuality = 0;
      page.recoverPlayback("断流");
      // 第一次重连先等 1 秒，然后读 1 的直播间信息
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      page.resetRoom(site, "2");
      await tester.pump();
      // 1 已经下播了：不能让 2 变成“未开播”
      fake.gate("1").complete(_detail("1"));
      await tester.pump();
      expect(page.liveStatus.value, isTrue);
      fake.gate("2").complete(_detail("2"));
      await tester.pumpAndSettle();
      expect(page.detail.value!.roomId, "2");
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
