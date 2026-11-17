import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/gpu_preference.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_compat.dart';

/// 显卡偏好：设置里存一份，数据文件夹里写一份给 main.cpp 在启动时读
void main() {
  late Directory dir;
  late Directory data;
  late Box box;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync("gpu_preference_");
    data = Directory("${dir.path}${Platform.pathSeparator}data")..createSync();
    Hive.init(dir.path);
    box = await Hive.openBox("settings");
    Get.put(LocalStorageService()..settingsBox = box);
  });
  tearDown(() async {
    await box.close();
    Get.reset();
    dir.deleteSync(recursive: true);
  });

  File file() => File(
      "${data.path}${Platform.pathSeparator}${GpuPreferenceSetting.fileName}");

  test("文件：写什么读出什么；自动 = 没有文件；没有、读不懂时按自动", () async {
    expect(
        await GpuPreferenceSetting.readFile(data), GpuPreferenceSetting.auto);
    await GpuPreferenceSetting.writeFile(
        data, GpuPreferenceSetting.highPerformance);
    // main.cpp 读的就是这个词
    expect(file().readAsStringSync(), "high_performance");
    expect(await GpuPreferenceSetting.readFile(data),
        GpuPreferenceSetting.highPerformance);
    await GpuPreferenceSetting.writeFile(data, GpuPreferenceSetting.lowPower);
    expect(file().readAsStringSync(), "low_power");
    await GpuPreferenceSetting.writeFile(data, GpuPreferenceSetting.auto);
    expect(file().existsSync(), isFalse);
    file().writeAsStringSync("  something-else \r\n");
    expect(
        await GpuPreferenceSetting.readFile(data), GpuPreferenceSetting.auto);
    file().writeAsStringSync("low_power\r\n");
    expect(await GpuPreferenceSetting.readFile(data),
        GpuPreferenceSetting.lowPower);
  });

  test("选了以后：设置和文件都改，这次启动用的还是原来的（提示重启）", () async {
    var gpu = GpuPreferenceSetting();
    await gpu.init(dir: data);
    expect(gpu.value.value, GpuPreferenceSetting.auto);
    expect(gpu.applied, GpuPreferenceSetting.auto);
    await gpu.set(GpuPreferenceSetting.highPerformance, dir: data);
    expect(gpu.value.value, GpuPreferenceSetting.highPerformance);
    expect(gpu.applied, GpuPreferenceSetting.auto);
    expect(box.get(GpuPreferenceSetting.kGpuPreference), "high_performance");
    expect(file().readAsStringSync(), "high_performance");

    // 下次启动：用的就是新的
    var next = GpuPreferenceSetting();
    await next.init(dir: data);
    expect(next.value.value, GpuPreferenceSetting.highPerformance);
    expect(next.applied, GpuPreferenceSetting.highPerformance);
  });

  test("文件和设置对不上（文件被删了、设置被重置了）：启动时按设置重写文件", () async {
    await box.put(GpuPreferenceSetting.kGpuPreference, "low_power");
    var gpu = GpuPreferenceSetting();
    await gpu.init(dir: data);
    expect(gpu.applied, GpuPreferenceSetting.auto);
    expect(file().readAsStringSync(), "low_power");

    await box.delete(GpuPreferenceSetting.kGpuPreference);
    await GpuPreferenceSetting().init(dir: data);
    expect(file().existsSync(), isFalse);
  });

  test("不认识的选项按自动；只在本机，不进备份", () async {
    expect(GpuPreferenceSetting.normalize("turbo"), GpuPreferenceSetting.auto);
    expect(GpuPreferenceSetting.normalize(null), GpuPreferenceSetting.auto);
    var gpu = GpuPreferenceSetting();
    await gpu.set("turbo", dir: data);
    expect(gpu.value.value, GpuPreferenceSetting.auto);
    expect(file().existsSync(), isFalse);
    for (var key in GpuPreferenceSetting.storageKeys) {
      expect(SyncCompat.isLocalOnlySetting(key), isTrue, reason: key);
    }
  });
}
