import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/play_prefs.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_playback.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_app/widgets/settings/play_prefs_settings.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'fakes/fake_player.dart';
import 'layout/layout_matrix.dart';

/// 不读本地存储的设置；按直播间记的弹幕设置不换（要 Hive）
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  void enterRoomContext(RoomContext context) {}
}

/// 两档清晰度、两条线路；记下每个接口被调了几次
class _FakeSite extends LiveSite {
  bool live = true;
  final calls = <String>[];
  List<String> qualityNames = ["原画", "高清", "流畅"];

  /// 不为空时读直播间信息要等它
  Completer<void>? detailGate;

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    calls.add("detail");
    await detailGate?.future;
    return LiveRoomDetail(
      roomId: roomId,
      title: "标题",
      cover: "",
      userName: "主播",
      userAvatar: "",
      online: 0,
      status: live,
      url: "",
    );
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites(
      {required LiveRoomDetail detail}) async {
    calls.add("qualities");
    return [for (var name in qualityNames) LivePlayQuality(quality: name, data: name)];
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

/// 直播间：不连播放器，打开地址时只记下来
class _Room extends LiveRoomController {
  _Room(this.fake)
      : super(
          pSite: Site(id: "test", liveSite: fake, logo: "", name: "测试"),
          pRoomId: "1",
        );
  final _FakeSite fake;
  final opened = <String>[];

  @override
  // ignore: overridden_fields
  final Player player = FakePlayer();

  FakePlayer get fakePlayer => player as FakePlayer;

  @override
  Future<void> openPlaylist({int startIndex = 0}) async {
    opened.add("${playUrls[startIndex]}#$startIndex");
    fakePlayer.setPlaying(true);
  }

  /// 已经在播：有房间信息、清晰度、线路
  Future<void> startPlaying({int quality = 1, int line = 1}) async {
    detail.value = await fake.getRoomDetail(roomId: "1");
    liveStatus.value = true;
    qualites.value = await fake.getPlayQualites(detail: detail.value!);
    currentQuality = quality;
    var url = await fake.getPlayUrls(
        detail: detail.value!, quality: qualites[quality]);
    playUrls.value = url.urls;
    currentLineIndex = line;
    fakePlayer.setPlaying(true);
    fake.calls.clear();
  }

  /// 在关注列表里点了别的直播间。测试里没有 SmartDialog，之后的 loadData 一开始就停下（错误不管）
  void switchTo(Site site, String roomId) {
    runZonedGuarded(() => resetRoom(site, roomId), (_, __) {});
  }
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _TestSettings settings;
  late _FakeSite fake;
  late _Room room;

  setUp(() {
    Get.testMode = true;
    settings = Get.put<AppSettingsController>(_TestSettings()) as _TestSettings;
    PlayPrefs.instance = PlayPrefs.forTest();
    fake = _FakeSite();
    room = _Room(fake);
    room.initLivePause();
  });
  tearDown(() {
    room.livePause.dispose();
    PlayPrefs.instance = null;
    Get.reset();
  });

  group("暂停和继续", () {
    test("暂停：播放器暂停；这期间断流不重连，也不算失败", () async {
      await room.startPlaying();
      await room.pauseLive();
      await settle();
      expect(room.livePause.paused.value, isTrue);
      expect(room.fakePlayer.calls, ["pause"]);
      expect(room.showResume, isTrue);

      // 暂停着的流被服务器断开（断流、出错、卡住最后都走这里）
      await room.recoverPlayback("直播断流了");
      await room.recoverPlayback("播放出错");
      await settle();
      expect(fake.calls, isEmpty);
      expect(room.recoverAttempts, 0);
      expect(room.errorMsg.value, "");
      expect(room.opened, isEmpty);
    });

    test("继续：重新读直播间和地址，按原来的清晰度、线路打开（最新画面）", () async {
      await room.startPlaying(quality: 1, line: 1);
      await room.pauseLive();
      await room.resumeLive();
      await settle();
      expect(fake.calls, ["detail", "qualities", "urls:高清"]);
      expect(room.opened, ["https://b/高清.flv?2#1"]);
      expect(room.livePause.paused.value, isFalse);
      expect(room.showResume, isFalse);
    });

    test("继续时清晰度列表变了：按名字找，找不到时用相近的一档", () async {
      await room.startPlaying(quality: 2, line: 0);
      await room.pauseLive();
      fake.qualityNames = ["蓝光", "原画"];
      await room.resumeLive();
      await settle();
      expect(room.currentQuality, 1);
      expect(room.currentQualityInfo.value, "原画");
      expect(room.opened.single, startsWith("https://a/原画.flv"));
    });

    test("继续时换了直播间：读到的是原来那个的，不用（房间信息不改，不换清晰度，不打开）", () async {
      await room.startPlaying(quality: 1, line: 1);
      await room.pauseLive();
      var before = room.detail.value;
      fake.detailGate = Completer<void>();
      var resuming = room.resumeLive();
      await settle();
      // 还在读直播间信息时，在关注列表里点了别的直播间
      room.switchTo(
          Site(id: "other", liveSite: _FakeSite(), logo: "", name: "别的"), "2");
      await settle();
      fake.detailGate!.complete();
      await resuming;
      await settle();
      expect(fake.calls, ["detail"]);
      expect(room.opened, isEmpty);
      expect(room.detail.value, same(before));
      expect(room.currentQualityInfo.value, "");
      expect(room.livePause.resuming, isFalse);
    });

    test("暂停期间下播了：继续时显示下播，不再打开", () async {
      await room.startPlaying();
      await room.pauseLive();
      fake.live = false;
      await room.resumeLive();
      await settle();
      expect(room.liveStatus.value, isFalse);
      expect(room.opened, isEmpty);
      expect(room.fakePlayer.calls.last, "stop");
    });

    test("暂停时换了清晰度（播起来了）：不再算暂停", () async {
      await room.startPlaying();
      await room.pauseLive();
      room.switchQualityManually(0);
      await settle();
      expect(room.opened.single, contains("原画"));
      expect(room.livePause.paused.value, isFalse);
    });

    test("进入后台自动暂停：回到前台时重新拉流", () async {
      settings.playerAutoPause.value = true;
      await room.startPlaying();
      room.onLifecycleForPause(AppLifecycleState.inactive);
      expect(room.livePause.paused.value, isFalse);
      room.onLifecycleForPause(AppLifecycleState.paused);
      await settle();
      expect(room.livePause.paused.value, isTrue);
      expect(room.livePause.byBackground, isTrue);
      await room.recoverPlayback("直播断流了");
      await settle();
      expect(fake.calls, isEmpty);

      room.onLifecycleForPause(AppLifecycleState.resumed);
      await settle();
      expect(fake.calls, ["detail", "qualities", "urls:高清"]);
      expect(room.opened, hasLength(1));
      expect(room.livePause.paused.value, isFalse);
    });

    test("没开“进入后台自动暂停”：进入后台不暂停", () async {
      settings.playerAutoPause.value = false;
      await room.startPlaying();
      room.onLifecycleForPause(AppLifecycleState.paused);
      await settle();
      expect(room.livePause.paused.value, isFalse);
      expect(room.fakePlayer.calls, isEmpty);
    });

    test("自己点的暂停：从后台回来也不自动继续", () async {
      settings.playerAutoPause.value = true;
      await room.startPlaying();
      await room.pauseLive();
      room.onLifecycleForPause(AppLifecycleState.paused);
      room.onLifecycleForPause(AppLifecycleState.resumed);
      await settle();
      expect(room.livePause.paused.value, isTrue);
      expect(room.opened, isEmpty);
    });
  });

  group("记住上次的清晰度", () {
    List<LivePlayQuality> list(List<String> names) =>
        [for (var n in names) LivePlayQuality(quality: n, data: n)];

    test("找记下的那一档：先按名字，再按位置，位置超出用最低一档", () {
      var qualities = list(["蓝光", "超清", "高清", "流畅"]);
      expect(RememberedQuality.resolve(qualities, const RememberedQuality("高清", 0)), 2);
      expect(RememberedQuality.resolve(qualities, const RememberedQuality("4K", 1)), 1);
      expect(RememberedQuality.resolve(qualities, const RememberedQuality("4K", 9)), 3);
      expect(RememberedQuality.resolve(qualities, null), -1);
      expect(RememberedQuality.resolve([], const RememberedQuality("高清", 0)), -1);
    });

    test("存成 JSON 再读回来；坏的项跳过", () {
      var text = RememberedQuality.encodeAll({
        "huya": const RememberedQuality("蓝光4M", 0),
        "douyu": const RememberedQuality("高清", 2),
      });
      var back = RememberedQuality.decodeAll(text);
      expect(back["huya"]!.name, "蓝光4M");
      expect(back["douyu"]!.index, 2);
      expect(RememberedQuality.decodeAll('{"a":{"name":"","index":1},"b":3,'
          '"c":{"name":"x","index":"1"},"d":{"name":"y","index":1}}').keys, ["d"]);
      expect(RememberedQuality.decodeAll("不是 JSON"), isEmpty);
      expect(RememberedQuality.decodeAll(""), isEmpty);
    });

    test("没选记住上次时照原来的；选了时用这个平台记下的，数据网络另算", () {
      var prefs = PlayPrefs.instance;
      var qualities = list(["原画", "高清", "流畅"]);
      prefs.rememberManualQuality("huya", qualities, 2, cellular: false);
      expect(prefs.pickQuality("huya", qualities, 1, cellular: false), 1);
      prefs.setRememberQuality(true, cellular: false);
      expect(prefs.pickQuality("huya", qualities, 1, cellular: false), 2);
      // 别的平台没记过
      expect(prefs.pickQuality("douyu", qualities, 1, cellular: false), 1);
      // 数据网络：没选记住上次
      expect(prefs.pickQuality("huya", qualities, 1, cellular: true), 1);
      prefs.setRememberQuality(true, cellular: true);
      expect(prefs.pickQuality("huya", qualities, 1, cellular: true), 1);
      prefs.rememberManualQuality("huya", qualities, 0, cellular: true);
      expect(prefs.pickQuality("huya", qualities, 1, cellular: true), 0);
      expect(prefs.pickQuality("huya", qualities, 1, cellular: false), 2);
    });

    test("直播间：手动切换时记下，进直播间时用记下的", () async {
      PlayPrefs.instance.setRememberQuality(true, cellular: false);
      await room.startPlaying(quality: 1);
      room.switchQualityManually(2);
      await settle();
      var saved = PlayPrefs.instance.remembered("test", cellular: false)!;
      expect(saved.name, "流畅");
      expect(saved.index, 2);
      expect(room.opened.single, contains("流畅"));

      // 断流重连、自动选的不记
      room.currentQuality = 0;
      expect(PlayPrefs.instance.remembered("test", cellular: false)!.name, "流畅");

      // 再进一个同平台的直播间
      var next = _Room(fake);
      next.detail.value = await fake.getRoomDetail(roomId: "2");
      next.getPlayQualites();
      await settle();
      expect(next.currentQuality, 2);
      expect(next.opened.single, contains("流畅"));
    });

    test("只存在本机：设置项都在不同步的名单里", () async {
      var dir = Directory.systemTemp.createTempSync("play_prefs_");
      addTearDown(() async {
        await Hive.close();
        dir.deleteSync(recursive: true);
      });
      Hive.init(dir.path);
      var storage = LocalStorageService();
      await storage.init();
      Get.put(storage);
      var prefs = PlayPrefs.forTest()..load();
      prefs.setRememberQuality(true, cellular: true);
      prefs.setFullscreenOrientation(2);
      prefs.rememberManualQuality(
          "huya", list(["原画", "高清"]), 1, cellular: false);
      await settle();

      var again = PlayPrefs.forTest()..load();
      expect(again.rememberQualityCellular.value, isTrue);
      expect(again.rememberQuality.value, isFalse);
      expect(again.fullscreenOrientation.value, 2);
      expect(again.remembered("huya", cellular: false)!.name, "高清");

      var keys = {
        LocalStorageService.kQualityRemember,
        LocalStorageService.kQualityRememberCellular,
        LocalStorageService.kQualityMemory,
        LocalStorageService.kQualityMemoryCellular,
        LocalStorageService.kFullscreenOrientation,
      };
      var all = Map<String, dynamic>.from(storage.settingsBox.toMap());
      expect(all.keys.toSet().intersection(keys), isNotEmpty);
      for (var key in keys) {
        expect(SyncCompat.isLocalOnlySetting(key), isTrue, reason: key);
      }
      expect(SyncCompat.upstreamSettings(all).keys.toSet().intersection(keys),
          isEmpty);
      expect(SyncCompat.extSettings(all).keys.toSet().intersection(keys), isEmpty);
    });
  });

  group("设置项", () {
    Widget page() => ListView(
          children: [
            SettingsCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  QualityLevelSetting(
                    title: "默认清晰度",
                    cellular: false,
                    level: settings.qualityLevel,
                    setLevel: (e) => settings.qualityLevel.value = e,
                  ),
                  QualityLevelSetting(
                    title: "数据网络清晰度",
                    cellular: true,
                    level: settings.qualityLevelCellular,
                    setLevel: (e) => settings.qualityLevelCellular.value = e,
                  ),
                  const FullscreenOrientationSetting(),
                ],
              ),
            ),
          ],
        );

    testWidgets("各种尺寸、语言下不溢出", (tester) async {
      PlayPrefs.instance.rememberQuality.value = true;
      PlayPrefs.instance.fullscreenOrientation.value = 1;
      var problems = await layoutMatrix(tester, page);
      expect(problems, isEmpty);
    });

    testWidgets("新文字的英文（i18n_new.json 里提的）放进去也不溢出", (tester) async {
      // 合并进 en.json 以后这个文件就没了，上面的测试会用 en.json 检查
      var file = File("../i18n_new.json");
      if (!file.existsSync()) {
        return;
      }
      var table = <String, String>{
        ...(jsonDecode(File("assets/lang/en.json").readAsStringSync()) as Map)
            .map((k, v) => MapEntry(k.toString(), v.toString())),
        ...(jsonDecode(file.readAsStringSync()) as Map)
            .map((k, v) => MapEntry(k.toString(), v.toString())),
      };
      addTearDown(() {
        CoreText.lookup = null;
        tester.view.reset();
      });
      var errors = <String>[];
      var previous = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.exceptionAsString());
      CoreText.lookup = (key) => table[key];
      for (var mode in [0, 1, 2]) {
        PlayPrefs.instance.fullscreenOrientation.value = mode;
        PlayPrefs.instance.rememberQuality.value = mode == 1;
        for (var size in layoutSizes) {
          for (var scale in layoutTextScales) {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            await tester.pumpWidget(GetMaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(body: page()),
            ));
            var e = tester.takeException();
            if (e != null) errors.add("$size x$scale: $e");
          }
        }
      }
      FlutterError.onError = previous;
      expect(find.text("Orientation is left to the system rotation setting"),
          findsOneWidget);
      expect(errors, isEmpty);
    });

    testWidgets("选“记住上次”：原来的档位不变；再选“最高”时关掉记住上次", (tester) async {
      settings.qualityLevel.value = 1;
      await tester.pumpWidget(GetMaterialApp(home: Scaffold(body: page())));
      expect(find.text("中等"), findsNWidgets(2));
      await tester.tap(find.text("默认清晰度"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("记住上次").last);
      await tester.pumpAndSettle();
      expect(PlayPrefs.instance.rememberQuality.value, isTrue);
      expect(settings.qualityLevel.value, 1);
      expect(find.text("记住上次"), findsOneWidget);

      await tester.tap(find.text("默认清晰度"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("最高").last);
      await tester.pumpAndSettle();
      expect(PlayPrefs.instance.rememberQuality.value, isFalse);
      expect(settings.qualityLevel.value, 2);

      // 全屏方向
      expect(find.text("智能"), findsOneWidget);
      await tester.tap(find.text("全屏方向"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("跟随系统").last);
      await tester.pumpAndSettle();
      expect(PlayPrefs.instance.fullscreenOrientation.value, 2);
      expect(find.text("不调整屏幕方向，按系统设置旋转"), findsOneWidget);
    });
  });
}
