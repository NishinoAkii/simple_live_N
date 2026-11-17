import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/services/ios_pip/ios_pip_session.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// iOS 投屏（外接显示器已连接）时出现在控制栏：切换电视右侧聊天栏
class ExternalDisplayButton extends StatelessWidget {
  final double size;
  const ExternalDisplayButton({this.size = 24, super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) {
      return const SizedBox.shrink();
    }
    return Obx(() {
      var settings = AppSettingsController.instance;
      if (!IosPipSession.externalConnected.value ||
          !settings.iosExternalDisplay.value) {
        return const SizedBox.shrink();
      }
      var sidebar = settings.iosExternalSidebar.value;
      return IconButton(
        tooltip: sidebar ? "电视隐藏聊天栏".t : "电视显示聊天栏".t,
        onPressed: () {
          settings.setIosExternalSidebar(!sidebar);
          SmartDialog.showToast(sidebar ? "电视已隐藏右侧聊天栏".t : "电视已显示右侧聊天栏".t);
        },
        icon: Icon(
          sidebar ? Icons.view_sidebar : Icons.tv,
          color: Colors.white,
          size: size,
        ),
      );
    });
  }
}
