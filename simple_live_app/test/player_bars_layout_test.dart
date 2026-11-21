import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/play_prefs.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_playback.dart';
import 'package:simple_live_app/modules/live_room/player/player_controls.dart';
import 'package:simple_live_app/modules/live_room/player/window_full_frame.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'fakes/fake_player.dart';
import 'layout/layout_matrix.dart';

/// 不读本地存储的设置
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _Room extends LiveRoomController {
  _Room()
      : super(
          pSite: Site(id: "test", liveSite: LiveSite(), logo: "", name: "测试"),
          pRoomId: "1",
        );

  @override
  // ignore: overridden_fields
  final Player player = FakePlayer();
}

/// 底栏（普通、全屏、电脑小窗）加了暂停按钮以后不挤。
/// 测试在电脑上跑，按电脑的样子排（多了音量、小窗按钮，比手机上挤）
void main() {
  late _Room room;
  setUp(() {
    Get.testMode = true;
    Get.put<AppSettingsController>(_TestSettings());
    PlayPrefs.instance = PlayPrefs.forTest();
    room = _Room();
    room.initLivePause();
    // 最挤的情况：开着播、倍速追帧、记录弹幕
    room.liveStatus.value = true;
    room.liveDuration.value = "123:45:67";
    room.playbackRate.value = 1.25;
    room.assRecording.value = true;
    room.assRecordTime.value = "12:34:56";
    room.currentQualityInfo.value = "蓝光8M";
    room.currentLineInfo.value = "线路10";
    (room.player as FakePlayer).setPlaying(true);
  });
  tearDown(() {
    room.livePause.dispose();
    PlayPrefs.instance = null;
    Get.reset();
  });

  /// 底栏放在播放器底部，播放器和窗口一样宽
  Widget host(Widget bar) => Stack(
        children: [
          Positioned(left: 0, right: 0, bottom: 0, child: bar),
        ],
      );

  Future<void> checkBar(WidgetTester tester, String name, Widget Function() bar) async {
    var problems = await layoutMatrix(tester, () => host(bar()));
    expect(problems, isEmpty, reason: name);
    // 最后一种（小窗 400x225、英文、字放大）下：暂停按钮在最左边，全屏按钮完整露出来
    var pause = tester.getRect(find.byType(LivePauseButton));
    expect(pause.left, lessThan(60), reason: name);
    var screen = Offset.zero & tester.view.physicalSize;
    for (var icon in [Remix.fullscreen_line, Remix.fullscreen_exit_fill]) {
      var f = find.byIcon(icon);
      if (f.evaluate().isNotEmpty) {
        var rect = tester.getRect(f);
        expect(screen.contains(rect.topLeft) && screen.contains(rect.bottomRight - const Offset(0.1, 0.1)),
            isTrue, reason: "$name $rect");
      }
    }
  }

  testWidgets("普通底栏（横屏、竖屏）", (tester) async {
    await checkBar(tester, "普通横屏",
        () => buildBottomBar(room, false, GlobalKey()));
    await checkBar(tester, "普通竖屏",
        () => buildBottomBar(room, true, GlobalKey()));
  });

  testWidgets("全屏和电脑小窗的底栏", (tester) async {
    await checkBar(tester, "全屏",
        () => buildFullBottomBar(room, EdgeInsets.zero, GlobalKey()));
    // 手机全屏时有刘海、横条的边距：横着拿时在左右两边，竖着拿时在底下
    await checkBar(tester, "全屏带边距", () {
      var size = tester.view.physicalSize;
      var padding = size.width > size.height
          ? const EdgeInsets.fromLTRB(44, 0, 44, 20)
          : const EdgeInsets.only(bottom: 34);
      return buildFullBottomBar(room, padding, GlobalKey());
    });
  });

  testWidgets("暂停按钮：点一下暂停，再点继续；没开播时不显示", (tester) async {
    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(body: host(buildBottomBar(room, false, GlobalKey()))),
    ));
    expect(find.byIcon(Remix.pause_fill), findsOneWidget);
    await tester.tap(find.byType(LivePauseButton));
    await tester.pump();
    expect(room.livePause.paused.value, isTrue);
    expect((room.player as FakePlayer).calls, ["pause"]);
    expect(find.byIcon(Remix.play_fill), findsOneWidget);

    // 继续：这里没有房间信息，只让播放器接着播
    await tester.tap(find.byType(LivePauseButton));
    await tester.pump();
    expect(room.livePause.paused.value, isFalse);
    expect((room.player as FakePlayer).calls.last, "play");
    await tester.pump();
    expect(find.byIcon(Remix.pause_fill), findsOneWidget);

    room.liveStatus.value = false;
    await tester.pump();
    expect(find.byIcon(Remix.pause_fill), findsNothing);
    expect(find.byIcon(Remix.play_fill), findsNothing);
  });

  testWidgets("窗口全屏的底栏：小窗、窗口全屏、全屏键都放得下", (tester) async {
    room.windowFullState.value = true;
    room.fullScreenState.value = true;
    await checkBar(tester, "窗口全屏",
        () => buildFullBottomBar(room, EdgeInsets.zero, GlobalKey()));
  });

  testWidgets("窗口全屏键：点一下进入，窗口全屏的底栏里再点一下退出", (tester) async {
    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(body: host(buildBottomBar(room, false, GlobalKey()))),
    ));
    await tester.tap(find.byIcon(Remix.aspect_ratio_line));
    await tester.pump();
    expect(room.windowFullState.value, isTrue);
    expect(room.fullScreenState.value, isTrue);

    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(
        body: host(buildFullBottomBar(room, EdgeInsets.zero, GlobalKey())),
      ),
    ));
    // 最右边是全屏键，前面是小窗键和退出窗口全屏
    expect(find.byIcon(Remix.fullscreen_line), findsOneWidget);
    expect(find.byIcon(Remix.fullscreen_exit_fill), findsNothing);
    expect(find.byIcon(Icons.picture_in_picture), findsOneWidget);
    await tester.tap(find.byIcon(Remix.aspect_ratio_fill));
    await tester.pump();
    expect(room.windowFullState.value, isFalse);
    expect(room.fullScreenState.value, isFalse);
  });

  testWidgets("窗口全屏：上面多一条标题栏，播放器的顶部边距让出它的高度", (tester) async {
    double? top;
    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(
        body: WindowFullFrame(
          controller: room,
          child: Builder(builder: (context) {
            top = MediaQuery.paddingOf(context).top;
            return const SizedBox.expand();
          }),
        ),
      ),
    ));
    expect(find.byType(WindowFullCaption), findsNothing);
    expect(top, 0);

    room.enterWindowFull();
    await tester.pump();
    expect(find.byType(WindowFullCaption), findsOneWidget);
    expect(top, WindowFullFrame.height);

    // 按键跟着控制栏出现
    room.showControlsState.value = true;
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);

    room.exitFull();
    await tester.pump();
    expect(find.byType(WindowFullCaption), findsNothing);
    expect(top, 0);
    room.hideControls();
  });
}
