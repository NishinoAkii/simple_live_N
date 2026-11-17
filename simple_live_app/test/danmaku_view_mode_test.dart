import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 不读本地存储的设置
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  late _TestSettings settings;
  setUp(() {
    Get.testMode = true;
    settings = Get.put<AppSettingsController>(_TestSettings()) as _TestSettings;
    settings.danmuSize.value = 16;
    settings.danmuSpeed.value = 10;
    settings.danmuSizeFullscreen.value = 24;
    settings.danmuPipSize.value = 12;
    settings.danmuPipSpeed.value = 6;
  });
  tearDown(() {
    AppSettingsController.debugDanmakuPerMode = null;
    Get.reset();
  });

  test('手机、平板：非全屏、全屏、小窗各用各的大小，小窗有自己的速度', () {
    AppSettingsController.debugDanmakuPerMode = true;
    expect(settings.danmuSizeFor(DanmakuViewMode.normal), 16);
    expect(settings.danmuSizeFor(DanmakuViewMode.fullscreen), 24);
    expect(settings.danmuSizeFor(DanmakuViewMode.pip), 12);
    expect(settings.danmuSpeedFor(DanmakuViewMode.normal), 10);
    expect(settings.danmuSpeedFor(DanmakuViewMode.fullscreen), 10);
    expect(settings.danmuSpeedFor(DanmakuViewMode.pip), 6);
    expect(settings.danmuSizeMax, 24);
  });

  test('桌面只有一套', () {
    AppSettingsController.debugDanmakuPerMode = false;
    for (var mode in DanmakuViewMode.values) {
      expect(settings.danmuSizeFor(mode), 16);
      expect(settings.danmuSpeedFor(mode), 10);
    }
    expect(settings.danmuSizeMax, 16);
  });

  group('第一次用时沿用原来的大小和速度', () {
    late Directory dir;
    late Box box;
    setUp(() async {
      dir = Directory.systemTemp.createTempSync("danmaku_modes_");
      Hive.init(dir.path);
      box = await Hive.openBox("settings");
      Get.put(LocalStorageService()..settingsBox = box);
    });
    tearDown(() async {
      await Hive.close();
      dir.deleteSync(recursive: true);
    });

    test('手机、平板：没设置过的从原来的值复制并存下来', () {
      AppSettingsController.debugDanmakuPerMode = true;
      settings.danmuSize.value = 20;
      settings.danmuSpeed.value = 8;
      settings.initDanmakuModes();
      expect(settings.danmuSizeFullscreen.value, 20);
      expect(settings.danmuPipSize.value, 20);
      expect(settings.danmuPipSpeed.value, 8);
      expect(box.get(LocalStorageService.kDanmuSizeFullscreen), 20);
      expect(box.get(LocalStorageService.kDanmuPipSpeed), 8);
    });

    test('设置过的保持不变', () async {
      AppSettingsController.debugDanmakuPerMode = true;
      await box.put(LocalStorageService.kDanmuSizeFullscreen, 30.0);
      await box.put(LocalStorageService.kDanmuPipSize, 10.0);
      await box.put(LocalStorageService.kDanmuPipSpeed, 5.0);
      settings.initDanmakuModes();
      expect(settings.danmuSizeFullscreen.value, 30);
      expect(settings.danmuPipSize.value, 10);
      expect(settings.danmuPipSpeed.value, 5);
    });

    test('桌面不存（同步到手机时不会盖掉手机上的设置）', () {
      AppSettingsController.debugDanmakuPerMode = false;
      settings.initDanmakuModes();
      expect(
          box.containsKey(LocalStorageService.kDanmuSizeFullscreen), isFalse);
      expect(box.containsKey(LocalStorageService.kDanmuPipSize), isFalse);
    });
  });
}
