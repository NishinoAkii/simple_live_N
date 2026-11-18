import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/capture/capture_controller.dart';
import 'package:simple_live_app/app/capture/capture_flow.dart';
import 'package:simple_live_app/app/capture/capture_meta.dart';
import 'package:simple_live_app/app/capture/capture_scope.dart';
import 'package:simple_live_app/app/capture/capture_settings.dart';
import 'package:simple_live_app/app/capture/capture_widgets.dart';
import 'package:simple_live_app/app/capture/stream_recorder.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/widgets/settings/capture_settings_view.dart';

import 'fakes/fake_player.dart';
import 'fakes/memory_storage.dart';

/// 不读本地存储的设置
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// 截图和录屏的控件：双击视频信息浮层隐藏它、全屏时一直显示截图键、录屏开关、截图时的闪光
void main() {
  late CaptureController capture;

  setUp(() {
    Get.testMode = true;
    MemoryStorage.install();
    Get.put<AppSettingsController>(_TestSettings());
    CaptureSettings.reset();
    capture = CaptureController(
      host: _Host(),
      flow: CaptureFlow(
        sink: _NoSink(),
        toast: (_) {},
        ask: (_, __) async => null,
      ),
      recordDir: () async => Directory.systemTemp,
    );
  });
  tearDown(() {
    CaptureSettings.reset();
    CaptureFeatures.debugStreamRecording = null;
    CaptureFeatures.debugScreenRecording = null;
    Get.reset();
  });

  testWidgets("双击视频信息浮层只隐藏浮层，双击别处照常", (tester) async {
    var settings = AppSettingsController.instance;
    settings.playerVideoStats.value = true;
    var fullscreenToggles = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CaptureLayerBox(
          scope: capture.scope,
          layer: CaptureLayer.player,
          child: Stack(
            children: [
              Positioned(
                left: 8,
                top: 8,
                child: CaptureLayerBox(
                  scope: capture.scope,
                  layer: CaptureLayer.videoStats,
                  child: Obx(
                    () => settings.playerVideoStats.value
                        ? const SizedBox(width: 120, height: 80)
                        : const SizedBox.shrink(),
                  ),
                ),
              ),
              // 和直播间的手势层一样：先看是不是落在浮层上
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTapDown: (d) {
                    if (!capture.hideVideoStatsAt(d.globalPosition)) {
                      fullscreenToggles++;
                    }
                  },
                  onDoubleTap: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );

    Future<void> doubleTap(Offset at) async {
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 400));
    }

    await doubleTap(const Offset(400, 300));
    expect(fullscreenToggles, 1);
    expect(settings.playerVideoStats.value, isTrue);

    await doubleTap(const Offset(40, 40));
    expect(settings.playerVideoStats.value, isFalse);
    expect(fullscreenToggles, 1);

    // 浮层藏起来以后，同一个地方双击就是普通的双击
    await doubleTap(const Offset(40, 40));
    expect(fullscreenToggles, 2);
  });

  testWidgets("全屏时一直显示截图键：默认跟着控制栏收起，打开后留在右边", (tester) async {
    Future<Rect> camera(bool shown) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: Stack(
              children: [
                FullscreenCaptureButtons(
                  controller: capture,
                  shown: shown,
                  right: 12,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getRect(find.byIcon(Icons.camera_alt_outlined));
    }

    var width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect((await camera(true)).right, lessThanOrEqualTo(width));
    expect((await camera(false)).left, greaterThanOrEqualTo(width));

    CaptureSettings.instance.setFullscreenButtons(true);
    var rect = await camera(false);
    expect(rect.right, lessThanOrEqualTo(width));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0.5,
    );
    // 录屏键在锁形键下面
    expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
  });

  testWidgets("录屏开关：流录制开着时顶栏、全屏都有录屏键，截图键位置不变；都关着时没有", (tester) async {
    Future<Rect> build() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(actions: [
              CaptureScreenshotButton(controller: capture),
              CaptureRecordButton(controller: capture),
            ]),
            body: Stack(
              children: [
                FullscreenCaptureButtons(
                  controller: capture,
                  shown: true,
                  right: 12,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.camera_alt_outlined), findsNWidgets(2));
      return tester.getRect(find.descendant(
        of: find.byType(FullscreenCaptureButtons),
        matching: find.byIcon(Icons.camera_alt_outlined),
      ));
    }

    // 1.26.0：只开了流录制
    expect(CaptureFeatures.screenRecording, isFalse);
    var on = await build();
    expect(find.byIcon(Icons.videocam_outlined), findsNWidgets(2));
    expect(find.byTooltip("录屏（最长 2 分钟）"), findsOneWidget);
    CaptureSettings.instance.setRecordFormat(CaptureRecordFormat.gif);
    await tester.pumpAndSettle();
    expect(find.byTooltip("录屏（最长 1 分钟）"), findsOneWidget);

    CaptureFeatures.debugStreamRecording = false;
    var off = await build();
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);
    expect(on, off);
  });

  testWidgets("设置：有录屏保存为和最长录制时间；画面录制的选项、说明和 .ass 都没有", (tester) async {
    var storage = Get.find<LocalStorageService>() as MemoryStorage;
    storage.values[CaptureSettings.kMaxMinutes] = 10;
    CaptureSettings.reset();
    await tester.pumpWidget(const GetMaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: CaptureSettingsView()),
      ),
    ));
    await tester.pump();

    for (var text in ["录屏保存为", "视频（原始流）", "最长录制时间", "2 分钟", "截图、录屏后"]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    // 以前存的 10 分钟按 2 分钟
    expect(CaptureSettings.instance.maxSeconds.value, 120);
    for (var text in ["录屏方式", "画面录制", "截图和录屏包含", "不限"]) {
      expect(find.text(text), findsNothing, reason: text);
    }
    expect(find.text("截图包含"), findsOneWidget);
    expect(find.textContaining("画面录制"), findsNothing);
    expect(find.textContaining(".ass"), findsNothing);

    // 选 GIF：说明最长 1 分钟
    CaptureSettings.instance.setRecordFormat(CaptureRecordFormat.gif);
    await tester.pump();
    expect(find.text("GIF"), findsOneWidget);
    expect(find.text("到时间自动停下并保存；存成 GIF 时最长 1 分钟"), findsOneWidget);

    // 最长录制时间只有 30 秒、1 分钟、2 分钟
    await tester.tap(find.text("最长录制时间"));
    await tester.pumpAndSettle();
    expect(find.byType(RadioListTile<int>), findsNWidgets(3));
    for (var text in ["30 秒", "1 分钟"]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
  });

  testWidgets("截图时播放器上闪一下，约 150 毫秒后没了；截完整窗口那一帧不显示", (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CaptureLayerBox(
          scope: capture.scope,
          layer: CaptureLayer.player,
          child: const SizedBox(width: 400, height: 225),
        ),
      ),
    );
    Finder flash() => find.descendant(
          of: find.byType(CaptureFlash),
          matching: find.byType(ColoredBox),
        );
    expect(flash(), findsNothing);
    capture.scope.flash();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(flash(), findsOneWidget);
    expect(tester.getSize(flash()), const Size(800, 600));
    // 截完整窗口时不显示
    capture.scope.stillCapture.value = true;
    await tester.pump();
    expect(flash(), findsNothing);
    capture.scope.stillCapture.value = false;
    await tester.pump(CaptureFlash.duration);
    expect(flash(), findsNothing);
  });
}

class _NoSink implements CaptureSink {
  @override
  Future<bool> canCopy(CaptureResult result) async => false;

  @override
  Future<bool> copy(CaptureResult result) async => false;

  @override
  Future<void> delete(CaptureResult result) async {}

  @override
  Future<String> save(CaptureResult result) async => "";
}

class _Host implements CaptureHost {
  @override
  final Player player = FakePlayer();

  @override
  CaptureMeta meta() => CaptureMeta(
        siteId: "test",
        siteName: "测试",
        roomId: "1",
        title: "",
        streamer: "",
        url: "",
        time: DateTime(2026),
      );

  @override
  BoxFit get videoFit => BoxFit.contain;

  @override
  double? get videoAspectRatio => null;

  @override
  bool get fullscreen => false;

  @override
  Stream<Object?>? get reopened => null;

  @override
  Future<CaptureSidecar?> startSidecar(String assPath) async => null;
}
