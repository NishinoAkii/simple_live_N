import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/listen_card.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_playback.dart';
import 'package:simple_live_core/simple_live_core.dart';

import '../fakes/fake_player.dart';
import 'layout_matrix.dart';

// 布局检查：听直播时画面位置上的主播卡片，带定时关闭的入口。
// 名字 20 个字、标题很长、定时关闭开着（英文最长），三种放法：
// 手机竖屏（16:9 的播放器）、横屏和平板电脑（旁边有聊天栏）、整个窗口（全屏、电脑小窗）

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

/// 新加的文字还没进 en.json（合并时再加），英文布局用 i18n_new.json 里拟的译文
Map<String, String> _newEnglish() {
  var file = File("../i18n_new.json");
  if (!file.existsSync()) {
    return const {};
  }
  return Map<String, String>.from(jsonDecode(file.readAsStringSync()) as Map);
}

final _english = _newEnglish();

Widget withNewText(Widget Function() build) {
  var base = CoreText.lookup;
  if (base != null && base("复制弹幕") == "Copy danmaku") {
    CoreText.lookup = (key) => base(key) ?? _english[key];
  }
  return build();
}

void main() {
  late _Room room;
  setUp(() {
    Get.testMode = true;
    Get.put<AppSettingsController>(_TestSettings());
    room = _Room();
    room.initLivePause();
    room.liveStatus.value = true;
    room.detail.value = LiveRoomDetail(
      roomId: "1",
      title: "标题也写得特别特别长的一场直播，看看两行放不放得下，放不下时省略号结尾",
      cover: "",
      userName: "名字特别特别特别特别长的一位主播啊啊啊啊",
      userAvatar: "",
      online: 0,
      status: true,
      url: "",
    );
    room.listen.active.value = true;
    // 定时关闭开着，还剩 23:59:59（按钮文字最长）
    room.autoExitEnable.value = true;
    room.countdown.value = 86399;
    (room.player as FakePlayer).setPlaying(true);
  });
  tearDown(() {
    room.livePause.dispose();
    Get.reset();
  });

  Widget card() => ListenCard(controller: room);

  testWidgets("手机竖屏：16:9 的播放器位置", (tester) async {
    var problems = await layoutMatrix(
      tester,
      () => withNewText(() => Column(
            children: [
              AspectRatio(aspectRatio: 16 / 9, child: card()),
              const Expanded(child: SizedBox()),
            ],
          )),
      sizes: layoutSizes.where((s) => s.height > s.width),
    );
    expect(problems, isEmpty);
    // 按钮都在卡片里，没有被挤出去
    expect(find.text("恢复画面").evaluate().isNotEmpty ||
        find.text("Show video").evaluate().isNotEmpty, isTrue);
  });

  testWidgets("横屏、平板、电脑：旁边有聊天栏", (tester) async {
    var problems = await layoutMatrix(
      tester,
      () => withNewText(() => LayoutBuilder(
            builder: (context, box) => Row(
              children: [
                Expanded(child: card()),
                SizedBox(width: min(300.0, box.maxWidth * 0.4)),
              ],
            ),
          )),
    );
    expect(problems, isEmpty);
  });

  testWidgets("整个窗口：全屏、电脑小窗；还有断流和没开播时", (tester) async {
    var problems = await layoutMatrix(tester, () => withNewText(card));
    expect(problems, isEmpty);
    room.listen.reconnecting.value = true;
    problems = await layoutMatrix(tester, () => withNewText(card),
        sizes: const [Size(400, 225), Size(360, 640)]);
    expect(problems, isEmpty);
    room.liveStatus.value = false;
    problems = await layoutMatrix(tester, () => withNewText(card),
        sizes: const [Size(400, 225), Size(360, 640)]);
    expect(problems, isEmpty);
  });

  testWidgets("暂停按钮在卡片里能点到", (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            AspectRatio(aspectRatio: 16 / 9, child: card()),
            const Expanded(child: SizedBox()),
          ],
        ),
      ),
    ));
    var pause = tester.getRect(find.byType(LivePauseButton));
    var player = tester.getRect(find.byType(ListenCard));
    expect(player.contains(pause.topLeft) && player.contains(pause.bottomRight - const Offset(0.1, 0.1)), isTrue);
    expect(pause.height, greaterThanOrEqualTo(40));
  });
}
