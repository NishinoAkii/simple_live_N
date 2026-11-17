import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/widgets/settings/settings_number.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 小窗（画中画）里的弹幕大小和速度，和播放器里的分开设置
class PipDanmakuSettings extends StatelessWidget {
  const PipDanmakuSettings({super.key});

  @override
  Widget build(BuildContext context) {
    var settings = AppSettingsController.instance;
    return Obx(
      () => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingsNumber(
            title: "小窗弹幕大小".t,
            subtitle: "小窗很小时会自动缩小".t,
            value: settings.danmuPipSize.value.toInt(),
            min: 4,
            max: 48,
            onChanged: (e) => settings.setDanmuPipSize(e.toDouble()),
          ),
          AppStyle.divider,
          SettingsNumber(
            title: "小窗滚动速度".t,
            subtitle: "从右走到左要几秒，越小越快".t,
            value: settings.danmuPipSpeed.value.toInt(),
            min: 4,
            max: 20,
            onChanged: (e) => settings.setDanmuPipSpeed(e.toDouble()),
          ),
        ],
      ),
    );
  }
}
