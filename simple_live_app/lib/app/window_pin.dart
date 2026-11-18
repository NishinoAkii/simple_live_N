import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/windows_version.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:window_manager/window_manager.dart';

/// 电脑上的窗口置顶：主窗口和每个多开窗口各管各的，只在这次打开时有效，
/// 重新打开窗口后是正常层。直播间小窗本来就在最前面，退出小窗后回到这里记的状态
class WindowPin {
  WindowPin._();
  static final WindowPin instance = WindowPin._();

  /// Windows 7 安装包维持 1.24.0 的功能，不显示图钉
  static bool get supported =>
      (Platform.isWindows && !WindowsVersion.isWindows7) ||
      Platform.isMacOS ||
      Platform.isLinux;

  /// 这个窗口现在是否置顶
  final RxBool pinned = false.obs;

  Future<void> toggle() => set(!pinned.value);

  Future<void> set(bool value) async {
    if (!supported) {
      return;
    }
    pinned.value = value;
    try {
      await windowManager.setAlwaysOnTop(value);
    } catch (e) {
      Log.logPrint(e);
    }
  }
}

/// 直播间右上角的图钉：点一下让这个窗口一直在最前面，再点一下回到正常层
class WindowPinButton extends StatelessWidget {
  const WindowPinButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      var pinned = WindowPin.instance.pinned.value;
      return IconButton(
        tooltip: pinned ? "取消置顶".t : "窗口置顶".t,
        isSelected: pinned,
        onPressed: WindowPin.instance.toggle,
        icon: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
      );
    });
  }
}
