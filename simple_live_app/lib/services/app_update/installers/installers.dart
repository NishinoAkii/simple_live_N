import 'dart:async';
import 'dart:io';

import 'package:simple_live_app/app/windows_version.dart';
import 'package:simple_live_app/services/app_update/installers/android_installer.dart';
import 'package:simple_live_app/services/app_update/installers/ios_installer.dart';
import 'package:simple_live_app/services/app_update/installers/macos_installer.dart';
import 'package:simple_live_app/services/app_update/installers/windows_installer.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';

/// 当前平台的安装方式；还不支持的平台返回 null（这时只能打开 Release 网页）。
/// 各平台的实现放在同一个文件夹里（windows_installer.dart 等）
UpdateInstaller? currentInstaller() {
  if (Platform.isWindows) {
    // Windows 7 安装包维持 1.24.0 的功能，不在 App 里安装，只能打开 Release 网页
    return WindowsVersion.isWindows7 ? null : WindowsInstaller();
  }
  if (Platform.isMacOS) {
    return MacosInstaller();
  }
  if (Platform.isAndroid) {
    // 先读设备的 ABI，挑 APK 时用（读到之前按当前进程的 ABI）
    unawaited(AndroidInstaller.loadAbis());
    return AndroidInstaller();
  }
  if (Platform.isIOS) {
    return IosInstaller();
  }
  return null;
}
