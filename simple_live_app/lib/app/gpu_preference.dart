import 'dart:io';

import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 显卡偏好（只有 Windows）：自动 / 省电 / 高性能，重启后生效。
///
/// 选项存在本机设置里（不进备份），同时写一份到数据文件夹里的 [fileName]：
/// 原生端（windows/runner/main.cpp）在引擎启动前读这个文件，按它选显卡。
/// mpv 画画面用的 D3D11 设备建在 Flutter 用的那块显卡上，所以视频也跟着走
class GpuPreferenceSetting {
  static GpuPreferenceSetting instance = GpuPreferenceSetting();

  static const String kGpuPreference = "GpuPreference";
  static const List<String> storageKeys = [kGpuPreference];

  static const String auto = "auto";
  static const String lowPower = "low_power";
  static const String highPerformance = "high_performance";
  static const List<String> values = [auto, lowPower, highPerformance];

  static const String fileName = "gpu_preference.txt";

  static bool get supported => Platform.isWindows;

  final value = auto.obs;

  /// 这次启动时用的（文件里原来写的）；和 [value] 不同时提示重启
  String applied = auto;

  static String normalize(String? value) =>
      values.contains(value) ? value! : auto;

  static LocalStorageService? get _storage =>
      Get.isRegistered<LocalStorageService>()
          ? LocalStorageService.instance
          : null;

  /// 启动时调用：读设置，记下这次启动用的，文件和设置不一致时按设置重写
  Future<void> init({Directory? dir}) async {
    if (!supported && dir == null) return;
    value.value = normalize(_storage?.getValue<String>(kGpuPreference, auto));
    try {
      dir ??= await getApplicationSupportDirectory();
      applied = await readFile(dir);
      if (applied != value.value) {
        await writeFile(dir, value.value);
      }
    } catch (e) {
      Log.logPrint(e);
    }
  }

  Future<void> set(String choice, {Directory? dir}) async {
    choice = normalize(choice);
    value.value = choice;
    await _storage?.setValue<String>(kGpuPreference, choice);
    try {
      dir ??= await getApplicationSupportDirectory();
      await writeFile(dir, choice);
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 文件里写的；没有文件、读不了或者不认识时为 [auto]
  static Future<String> readFile(Directory dir) async {
    try {
      var file = File("${dir.path}${Platform.pathSeparator}$fileName");
      if (!await file.exists()) return auto;
      return normalize((await file.readAsString()).trim());
    } catch (e) {
      Log.logPrint(e);
      return auto;
    }
  }

  /// 自动就删掉文件（原生端没读到文件时不指定显卡）
  static Future<void> writeFile(Directory dir, String choice) async {
    var file = File("${dir.path}${Platform.pathSeparator}$fileName");
    if (normalize(choice) == auto) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.writeAsString(normalize(choice), flush: true);
  }
}
