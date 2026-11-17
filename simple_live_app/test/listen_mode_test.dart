import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/play_prefs.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/listen_card.dart';
import 'package:simple_live_app/modules/live_room/listen_mode.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_playback.dart';
import 'package:simple_live_app/services/background_playback.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'fakes/fake_player.dart';

/// 不读本地存储的设置
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// 三档清晰度、两条线路；记下每个接口被调了几次
class _FakeSite extends LiveSite {
  final calls = <String>[];
  String userName = "主播";
  String title = "标题";
  String avatar = "https://a/face.png";

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    calls.add("detail");
    return LiveRoomDetail(
      roomId: roomId,
      title: title,
      cover: "",
      userName: userName,
      userAvatar: avatar,
      online: 0,
      status: true,
      url: "",
    );
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites(
      {required LiveRoomDetail detail}) async {
    calls.add("qualities");
    return [
      for (var name in ["原画", "高清", "流畅"])
        LivePlayQuality(quality: name, data: name)
    ];
  }

  @override
  Future<LivePlayUrl> getPlayUrls(
      {required LiveRoomDetail detail, required LivePlayQuality quality}) async {
    calls.add("urls:${quality.quality}");
    return LivePlayUrl(urls: [
      "https://a/${quality.quality}.flv?1",
      "https://b/${quality.quality}.flv?2",
    ]);
  }
}

/// 能发 playlist 事件（media_kit 每次打开新内容时发一次），记下视频轨和音量
class _ListenPlayer extends FakePlayer {
  final playlistController = StreamController<Playlist>.broadcast();

  @override
  PlayerStream get stream => PlayerStream(
        playlistController.stream,
        playingController.stream,
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
      );

  @override
  Future<void> setVideoTrack(VideoTrack track) async {
    calls.add("vid:${track.id}");
  }

  @override
  Future<void> setVolume(double volume) async {
    calls.add("volume:${volume.round()}");
  }

  int get videoOff => calls.where((e) => e == "vid:no").length;
}

class _Room extends LiveRoomController {
  _Room(this.fake)
      : super(
          pSite: Site(id: "test", liveSite: fake, logo: "", name: "测试"),
          pRoomId: "1",
        );
  final _FakeSite fake;
  final opened = <String>[];
  final onVideo = <String>[];
  final exits = <String>[];
  Completer<bool>? askResult;

  @override
  // ignore: overridden_fields
  final Player player = _ListenPlayer();

  _ListenPlayer get fakePlayer => player as _ListenPlayer;

  @override
  Future<void> openPlaylist({int startIndex = 0}) async {
    opened.add("${playUrls[startIndex]}#$startIndex");
    fakePlayer.playlistController.add(const Playlist([]));
    fakePlayer.setPlaying(true);
  }

  @override
  void addDanmaku(List<DanmakuContentItem> items) =>
      onVideo.addAll(items.map((e) => e.text));

  @override
  Future<bool> askDelayAutoExit() {
    exits.add("ask");
    return (askResult = Completer<bool>()).future;
  }

  @override
  Future<void> exitApp() async => exits.add("exit");

  @override
  void showAutoExitSheet() => exits.add("sheet");

  /// 已经在播：有房间信息、清晰度、线路
  Future<void> startPlaying() async {
    detail.value = await fake.getRoomDetail(roomId: "1");
    liveStatus.value = true;
    qualites.value = await fake.getPlayQualites(detail: detail.value!);
    currentQuality = 1;
    var url = await fake.getPlayUrls(
        detail: detail.value!, quality: qualites[currentQuality]);
    playUrls.value = url.urls;
    currentLineIndex = 0;
    fakePlayer.setPlaying(true);
    // 等“在播”的事件传到暂停状态和音频焦点
    await settle();
    fake.calls.clear();
  }
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

LiveMessage chat(String text) => LiveMessage(
      type: LiveMessageType.chat,
      userName: "观众",
      message: text,
      color: LiveMessageColor.white,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel("test/background_playback");
  late _TestSettings settings;
  late _FakeSite fake;
  late _Room room;
  late List<MethodCall> native;
  late List<bool> screenOn;

  /// 原生端发给 Dart 的消息（通知按钮、音频焦点）
  Future<void> fromNative(String method, Map<String, Object> args) async {
    var messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
    await settle();
  }

  List<MethodCall> sent(String method) =>
      native.where((e) => e.method == method).toList();

  Map args(MethodCall call) => call.arguments as Map;

  setUp(() {
    Get.testMode = true;
    settings = Get.put<AppSettingsController>(_TestSettings()) as _TestSettings;
    settings.danmuBufferBoost.value = false;
    PlayPrefs.instance = PlayPrefs.forTest();
    native = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      native.add(call);
      return call.method == "startService" ? true : null;
    });
    BackgroundPlayback.instance =
        BackgroundPlayback(channel: channel, supported: true);
    fake = _FakeSite();
    room = _Room(fake);
    room.initLivePause();
    room.initListenMode();
    room.listen.loadArtwork = (_) async => null;
    screenOn = [];
    room.listen.keepScreenOn = (on) async => screenOn.add(on);
  });
  tearDown(() {
    room.disposeListenMode();
    room.livePause.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    BackgroundPlayback.instance = null;
    PlayPrefs.instance = null;
    Get.reset();
  });

  group("听直播", () {
    test("开了以后关掉视频轨；每次重新打开播放后都再关一次", () async {
      await room.startPlaying();
      await room.enterListenMode();
      expect(room.listen.active.value, isTrue);
      expect(room.fakePlayer.videoOff, 1);

      // 暂停后继续：重新拉流、打开
      await room.pauseLive();
      await room.resumeLive();
      await settle();
      expect(room.opened, hasLength(1));
      expect(room.fakePlayer.videoOff, 2);

      // 手动换清晰度
      room.switchQualityManually(0);
      await settle();
      expect(room.opened, hasLength(2));
      expect(room.fakePlayer.videoOff, 3);

      // mpv 自己换到下一条线路（出错时）
      room.fakePlayer.playlistController.add(const Playlist([]));
      await settle();
      expect(room.fakePlayer.videoOff, 4);
    });

    test("视频弹幕停掉，聊天照常；恢复画面后弹幕回来", () async {
      // 聊天栏是匀开进的：插一条系统提示，排着的先全放出来
      List<String> chats() {
        room.addSysMsg("-");
        return [
          for (var i = 0; i < room.chatLog.length; i++)
            if (room.chatLog[i].message.userName != "LiveSysMessage")
              room.chatLog[i].message.message,
        ];
      }

      await room.startPlaying();
      room.onWSMessage(chat("之前"));
      expect(room.onVideo, ["之前"]);

      await room.enterListenMode();
      room.onWSMessage(chat("听直播时"));
      await settle();
      expect(room.onVideo, ["之前"]);
      expect(chats(), ["之前", "听直播时"]);

      await room.exitListenMode();
      expect(room.listen.active.value, isFalse);
      expect(room.fakePlayer.calls.last, "vid:auto");
      room.onWSMessage(chat("恢复以后"));
      expect(room.onVideo, ["之前", "恢复以后"]);
      expect(chats(), ["之前", "听直播时", "恢复以后"]);
    });

    test("恢复画面以后再打开播放，不再关视频轨", () async {
      await room.startPlaying();
      await room.enterListenMode();
      await room.exitListenMode();
      var off = room.fakePlayer.videoOff;
      room.fakePlayer.playlistController.add(const Playlist([]));
      await settle();
      expect(room.fakePlayer.videoOff, off);
    });

    test("开着“进入后台自动暂停”时，听直播切到后台也不暂停", () async {
      settings.playerAutoPause.value = true;
      await room.startPlaying();
      await room.enterListenMode();
      room.onLifecycleForPause(AppLifecycleState.paused);
      await settle();
      expect(room.livePause.paused.value, isFalse);
      expect(room.fakePlayer.calls, isNot(contains("pause")));
    });

    test("听直播时屏幕不常亮（重新播起来也一样），恢复画面后常亮", () async {
      await room.startPlaying();
      await room.enterListenMode();
      expect(screenOn, [false]);
      await room.pauseLive();
      await room.resumeLive();
      await settle();
      expect(screenOn, [false, false]);
      await room.exitListenMode();
      expect(screenOn, [false, false, true]);
    });

    test("听直播时不开电脑小窗", () async {
      await room.enterListenMode();
      room.enterSmallWindow();
      expect(room.smallWindowState.value, isFalse);
    });
  });

  group("通知和锁屏卡片（平台通道）", () {
    test("开听直播时显示，内容是主播名和标题，文字已经翻译好", () async {
      await room.startPlaying();
      await room.enterListenMode();
      var start = sent("startService").single;
      expect(args(start)["title"], "主播");
      expect(args(start)["subtitle"], "标题");
      expect(args(start)["state"], "playing");
      expect(args(start)["channelName"], "后台播放");
      expect(args(start)["playLabel"], "继续");
      expect(args(start)["pauseLabel"], "暂停");
      expect(args(start)["stopLabel"], "停止");
    });

    test("暂停、换直播间只更新通知，不重开服务", () async {
      await room.startPlaying();
      await room.enterListenMode();
      await room.pauseLive();
      await settle();
      expect(args(sent("updateService").last)["state"], "paused");

      fake.userName = "另一位主播";
      fake.title = "另一个标题";
      room.detail.value = await fake.getRoomDetail(roomId: "2");
      await settle();
      var last = args(sent("updateService").last);
      expect(last["title"], "另一位主播");
      expect(last["subtitle"], "另一个标题");
      expect(sent("startService"), hasLength(1));
      expect(sent("stopService"), isEmpty);
    });

    test("断流重连时显示“正在重新连接”", () async {
      await room.startPlaying();
      await room.enterListenMode();
      // 重连先等 1 秒；等的时候让它作废，不真的重连
      unawaited(room.recoverPlayback("直播断流了"));
      await settle();
      room.syncListenInfo();
      await settle();
      var last = args(sent("updateService").last);
      expect(last["subtitle"], "正在重新连接");
      expect(last["state"], "buffering");
      expect(room.listen.reconnecting.value, isTrue);
      room.resetPlaybackRecovery();
    });

    test("通知上的按钮：暂停、继续（重新拉流）", () async {
      await room.startPlaying();
      await room.enterListenMode();
      await fromNative("onAction", {"action": "pause"});
      expect(room.livePause.paused.value, isTrue);
      await fromNative("onAction", {"action": "play"});
      expect(room.livePause.paused.value, isFalse);
      expect(fake.calls, ["detail", "qualities", "urls:高清"]);
      await fromNative("onAction", {"action": "toggle"});
      expect(room.livePause.paused.value, isTrue);
    });

    test("停止：暂停并收起通知；在卡片上点继续时再显示", () async {
      await room.startPlaying();
      await room.enterListenMode();
      await fromNative("onAction", {"action": "stop"});
      expect(room.livePause.paused.value, isTrue);
      expect(room.listen.stopped, isTrue);
      expect(sent("stopService"), hasLength(1));
      // 停止以后的状态变化不再更新通知
      var updates = sent("updateService").length;
      room.syncListenInfo();
      await settle();
      expect(sent("updateService"), hasLength(updates));

      room.toggleLivePause();
      await settle();
      expect(room.livePause.paused.value, isFalse);
      expect(room.listen.stopped, isFalse);
      expect(sent("startService"), hasLength(2));
    });

    test("恢复画面、关闭直播间时收起通知、放掉音频焦点", () async {
      await room.startPlaying();
      await room.enterListenMode();
      await room.exitListenMode();
      expect(sent("stopService"), hasLength(1));
      await room.enterListenMode();
      room.disposeListenMode();
      await settle();
      expect(sent("stopService"), hasLength(2));
      expect(args(sent("audioActive").last), {"active": false, "mix": false});
    });

    test("电脑上什么都不发", () async {
      BackgroundPlayback.instance =
          BackgroundPlayback(channel: channel, supported: false);
      var desktop = _Room(fake)
        ..initLivePause()
        ..initListenMode();
      desktop.listen.loadArtwork = (_) async => null;
      desktop.listen.keepScreenOn = (_) async {};
      await desktop.startPlaying();
      await desktop.enterListenMode();
      await desktop.pauseLive();
      await settle();
      expect(native, isEmpty);
      expect(desktop.fakePlayer.videoOff, 1);
      desktop.disposeListenMode();
      desktop.livePause.dispose();
    });
  });

  group("音频焦点", () {
    test("在播时占着焦点，暂停时放掉；“同时播放”跟着设置", () async {
      await room.startPlaying();
      await settle();
      expect(args(sent("audioActive").last), {"active": true, "mix": false});
      settings.playWithOthers.value = true;
      await settle();
      expect(args(sent("audioActive").last), {"active": true, "mix": true});
      await room.pauseLive();
      await settle();
      expect(args(sent("audioActive").last), {"active": false, "mix": true});
    });

    test("来电（短时间占用）：暂停，等着时不放焦点；结束后重新拉流", () async {
      await room.startPlaying();
      await fromNative("onFocus", {"event": "lossTransient"});
      expect(room.livePause.paused.value, isTrue);
      expect(args(sent("audioActive").last)["active"], isTrue);
      await fromNative("onFocus", {"event": "gain"});
      expect(room.livePause.paused.value, isFalse);
      expect(fake.calls, ["detail", "qualities", "urls:高清"]);
    });

    test("中断结束但系统说不要恢复（iOS）：保持暂停", () async {
      await room.startPlaying();
      await fromNative("onFocus", {"event": "lossTransient"});
      await fromNative("onFocus", {"event": "ended"});
      expect(room.livePause.paused.value, isTrue);
      expect(room.opened, isEmpty);
    });

    test("可以小声：压低音量，焦点回来时恢复", () async {
      settings.playerVolume.value = 100;
      await room.startPlaying();
      await fromNative("onFocus", {"event": "duck"});
      expect(room.fakePlayer.calls.last, "volume:20");
      expect(room.livePause.paused.value, isFalse);
      await fromNative("onFocus", {"event": "gain"});
      expect(room.fakePlayer.calls.last, "volume:100");
    });

    test("别的应用长时间占用：暂停，焦点回来也不自动继续", () async {
      await room.startPlaying();
      await fromNative("onFocus", {"event": "loss"});
      expect(room.livePause.paused.value, isTrue);
      await fromNative("onFocus", {"event": "gain"});
      expect(room.livePause.paused.value, isTrue);
      expect(room.opened, isEmpty);
    });

    test("拔耳机：暂停", () async {
      await room.startPlaying();
      await fromNative("onFocus", {"event": "noisy"});
      expect(room.livePause.paused.value, isTrue);
    });

    test("开着“与其他应用同时播放”：别的应用出声不暂停、不压低", () async {
      settings.playWithOthers.value = true;
      await room.startPlaying();
      await fromNative("onFocus", {"event": "loss"});
      await fromNative("onFocus", {"event": "duck"});
      expect(room.livePause.paused.value, isFalse);
      expect(room.fakePlayer.calls, isNot(contains("volume:20")));
    });

    test("自己点了继续以后，焦点回来不再拉一次流", () async {
      await room.startPlaying();
      await fromNative("onFocus", {"event": "lossTransient"});
      await room.resumeLive();
      await settle();
      fake.calls.clear();
      await fromNative("onFocus", {"event": "gain"});
      expect(fake.calls, isEmpty);
    });
  });

  group("焦点的决定", () {
    List<AudioFocusAction> run(AudioFocusPolicy p, AudioFocusEvent e,
            {bool playing = true, bool mix = false}) =>
        p.decide(e, playing: playing, mixWithOthers: mix);

    test("暂停、压低、恢复", () {
      var p = AudioFocusPolicy();
      expect(run(p, AudioFocusEvent.duck), [AudioFocusAction.duck]);
      // 已经压低了：不再压
      expect(run(p, AudioFocusEvent.duck), isEmpty);
      expect(run(p, AudioFocusEvent.lossTransient), [AudioFocusAction.pause]);
      expect(run(p, AudioFocusEvent.gain, playing: false),
          [AudioFocusAction.restoreVolume, AudioFocusAction.resume]);
      expect(run(p, AudioFocusEvent.gain), isEmpty);
    });

    test("没在播时什么都不做；拔耳机先恢复音量再暂停", () {
      var p = AudioFocusPolicy();
      expect(run(p, AudioFocusEvent.loss, playing: false), isEmpty);
      expect(run(p, AudioFocusEvent.lossTransient, playing: false), isEmpty);
      expect(run(p, AudioFocusEvent.duck, playing: false), isEmpty);
      run(p, AudioFocusEvent.duck);
      expect(run(p, AudioFocusEvent.noisy),
          [AudioFocusAction.restoreVolume, AudioFocusAction.pause]);
    });

    test("同时播放：只管来电和拔耳机", () {
      var p = AudioFocusPolicy();
      expect(run(p, AudioFocusEvent.loss, mix: true), isEmpty);
      expect(run(p, AudioFocusEvent.duck, mix: true), isEmpty);
      expect(run(p, AudioFocusEvent.lossTransient, mix: true),
          [AudioFocusAction.pause]);
      expect(run(p, AudioFocusEvent.gain, mix: true, playing: false),
          [AudioFocusAction.resume]);
      expect(run(p, AudioFocusEvent.noisy, mix: true), [AudioFocusAction.pause]);
    });

    test("原生端的事件名", () {
      expect(AudioFocusEvent.parse("lossTransient"),
          AudioFocusEvent.lossTransient);
      expect(AudioFocusEvent.parse("bogus"), isNull);
      expect(AudioFocusEvent.parse(null), isNull);
    });

    test("“与其他应用同时播放”默认关，只存本机", () {
      expect(settings.playWithOthers.value, isFalse);
      expect(
        SyncCompat.isLocalOnlySetting(LocalStorageService.kPlayWithOthers),
        isTrue,
      );
    });
  });

  group("定时关闭（卡片上的入口）", () {
    test("按钮文字：开着时显示还剩多久", () {
      expect(listenTimerLabel(enabled: false, seconds: 99), "定时关闭");
      expect(listenTimerLabel(enabled: true, seconds: 65), "01:05后自动关闭");
      expect(listenTimerLabel(enabled: true, seconds: 3725), "1:02:05后自动关闭");
      expect(listenClock(-3), "00:00");
    });

    // testWidgets 里的计时器是假的，pump 多久就走多久
    void startTimer(int minutes) {
      room.autoExitEnable.value = true;
      room.autoExitMinutes.value = minutes;
      room.setAutoExit();
    }

    testWidgets("时间到了先问；选“关闭”就关", (tester) async {
      startTimer(1);
      await tester.pump(const Duration(seconds: 59));
      expect(room.countdown.value, 1);
      expect(room.exits, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(room.exits, ["ask"]);
      room.askResult!.complete(false);
      await tester.pump();
      expect(room.exits, ["ask", "exit"]);
      // 10 秒的兜底不会再关一次
      await tester.pump(const Duration(seconds: 20));
      expect(room.exits, ["ask", "exit"]);
    });

    testWidgets("没人回答（在后台听着）：10 秒后自动关", (tester) async {
      startTimer(1);
      await tester.pump(const Duration(seconds: 60));
      expect(room.exits, ["ask"]);
      await tester.pump(const Duration(seconds: 9));
      expect(room.exits, ["ask"]);
      await tester.pump(const Duration(seconds: 1));
      expect(room.exits, ["ask", "exit"]);
    });

    testWidgets("选“延迟”：打开设置，重新倒计时，不关", (tester) async {
      startTimer(2);
      await tester.pump(const Duration(minutes: 2));
      room.askResult!.complete(true);
      await tester.pump();
      expect(room.exits, ["ask", "sheet"]);
      expect(room.delayAutoExit.value, isTrue);
      expect(room.countdown.value, 120);
      await tester.pump(const Duration(seconds: 30));
      expect(room.countdown.value, 90);
      expect(room.exits, ["ask", "sheet"]);
      room.autoExitTimer?.cancel();
    });
  });

  group("主播卡片", () {
    testWidgets("恢复画面、定时关闭、暂停", (tester) async {
      // 不加载网络头像（显示内置的图）
      fake.avatar = "";
      await tester.runAsync(() async {
        await room.startPlaying();
        await room.enterListenMode();
      });
      await tester.pumpWidget(GetMaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 219,
            child: ListenCard(controller: room),
          ),
        ),
      ));
      expect(find.text("主播"), findsOneWidget);
      expect(find.text("标题"), findsOneWidget);
      expect(find.byType(LivePauseButton), findsOneWidget);

      await tester.tap(find.text("定时关闭"));
      expect(room.exits, ["sheet"]);

      room.autoExitEnable.value = true;
      room.countdown.value = 1800;
      await tester.pump();
      expect(find.text("30:00后自动关闭"), findsOneWidget);

      room.liveStatus.value = false;
      await tester.pump();
      expect(find.text("未开播"), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
      room.liveStatus.value = true;
      await tester.pump();

      await tester.tap(find.text("恢复画面"));
      await tester.pump();
      expect(room.listen.active.value, isFalse);
      room.autoExitEnable.value = false;
    });
  });
}
