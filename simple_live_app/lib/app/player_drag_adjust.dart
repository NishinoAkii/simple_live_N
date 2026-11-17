import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:screen_brightness/screen_brightness.dart';
import 'package:simple_live_app/app/custom_throttle.dart';
import 'package:simple_live_app/app/log.dart';

/// 播放画面上竖向滑动调亮度和音量的公共部分
class PlayerDragAdjust {
  static bool get _mobile => Platform.isAndroid || Platform.isIOS;

  /// 手机平板都算；电脑上只有手指和触控笔算，鼠标拖动不调
  static bool accepts(PointerDeviceKind? kind) =>
      _mobile ||
      kind == PointerDeviceKind.touch ||
      kind == PointerDeviceKind.stylus;

  /// 手机调系统音量；电脑调播放器音量，和滚轮、音量条一致
  static bool get usesSystemVolume => _mobile;

  /// 往上滑变大，滑过 [range] 变化整个 0-1
  static double dragValue({
    required double start,
    required double startY,
    required double y,
    required double range,
  }) =>
      (start + (startY - y) / range).clamp(0.0, 1.0).toDouble();

  /// 音量每档 5%
  static int volumePercent(double value) => (value * 20).round() * 5;

  static bool _changed = false;
  static bool _useWmi = false;
  static double? _wmiOriginal;

  /// 现在的亮度（0-1），这台设备调不了时返回 null。
  /// Windows 上的插件只能调外接显示器，笔记本内屏要走 WMI
  static Future<double?> readBrightness() async {
    try {
      var value = await ScreenBrightness.instance.application;
      _useWmi = false;
      return value;
    } catch (e) {
      Log.logPrint(e);
    }
    if (!Platform.isWindows) {
      return null;
    }
    var value = await _wmiRead();
    _useWmi = value != null;
    if (value != null && !_changed) {
      _wmiOriginal = value;
    }
    return value;
  }

  static Future<void> setBrightness(double value) async {
    _changed = true;
    if (_useWmi) {
      await _wmiWrite(value);
      return;
    }
    try {
      await ScreenBrightness.instance.setApplicationScreenBrightness(value);
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 手机马上生效；电脑上调亮度比较慢，节流
  static void applyBrightness(double value, DelayedThrottle? throttle) {
    if (_mobile) {
      setBrightness(value);
    } else {
      throttle?.invoke(() => setBrightness(value));
    }
  }

  /// 离开播放页时恢复；没有调过就什么都不做
  static Future<void> resetBrightness() async {
    if (!_changed) {
      return;
    }
    _changed = false;
    try {
      if (_useWmi) {
        var original = _wmiOriginal;
        if (original != null) {
          await _wmiWrite(original);
        }
      } else {
        await ScreenBrightness.instance.resetApplicationScreenBrightness();
      }
    } catch (e) {
      Log.logPrint(e);
    }
  }

  static Future<String?> _powershell(String script) async {
    try {
      var result = await Process.run(
        "powershell.exe",
        ["-NoProfile", "-NonInteractive", "-Command", script],
      );
      if (result.exitCode != 0) {
        return null;
      }
      return result.stdout.toString().trim();
    } catch (e) {
      Log.logPrint(e);
      return null;
    }
  }

  static Future<double?> _wmiRead() async {
    var output = await _powershell(
      "(Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness"
      " -ErrorAction Stop | Select-Object -First 1).CurrentBrightness",
    );
    var value = int.tryParse(output ?? "");
    return value == null ? null : value / 100;
  }

  static Future<void> _wmiWrite(double value) async {
    var percent = (value * 100).round();
    await _powershell(
      "Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods"
      " -ErrorAction Stop | Invoke-CimMethod -MethodName WmiSetBrightness"
      " -Arguments @{Timeout=[uint32]1;Brightness=[byte]$percent} | Out-Null",
    );
  }
}
