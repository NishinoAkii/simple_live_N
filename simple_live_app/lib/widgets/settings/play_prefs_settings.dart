import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/play_prefs.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/widgets/settings/settings_menu.dart';

/// 直播间设置里的“全屏方向”（只在安卓上显示，只存本机）
class FullscreenOrientationSetting extends StatelessWidget {
  const FullscreenOrientationSetting({super.key});

  @override
  Widget build(BuildContext context) {
    var prefs = PlayPrefs.instance;
    return Obx(() {
      var value = prefs.fullscreenOrientation.value;
      return SettingsMenu<int>(
        title: "全屏方向".t,
        subtitle: switch (value) {
          1 => "横屏直播在手机和平板上都转成横屏".t,
          2 => "不调整屏幕方向，按系统设置旋转".t,
          _ => "横屏直播在手机上转成横屏，平板上不强制转屏".t,
        },
        value: value,
        valueMap: {
          0: "智能".t,
          1: "强制横屏".t,
          2: "跟随系统".t,
        },
        onChanged: prefs.setFullscreenOrientation,
      );
    });
  }
}

/// 默认清晰度、数据网络清晰度的菜单：在原来的最低、中等、最高后面加“记住上次”
class QualityLevelSetting extends StatelessWidget {
  final String title;
  final bool cellular;

  /// 原来的档位（0 最低、1 中等、2 最高）和改它的方法
  final RxInt level;
  final void Function(int) setLevel;
  const QualityLevelSetting({
    required this.title,
    required this.cellular,
    required this.level,
    required this.setLevel,
    super.key,
  });

  static const remember = 3;

  @override
  Widget build(BuildContext context) {
    var prefs = PlayPrefs.instance;
    var on = cellular ? prefs.rememberQualityCellular : prefs.rememberQuality;
    return Obx(
      () => SettingsMenu<int>(
        title: title,
        // 选了记住上次时，没记过的平台还按原来选的档位
        value: on.value ? remember : level.value,
        valueMap: {
          0: "最低".t,
          1: "中等".t,
          2: "最高".t,
          remember: "记住上次".t,
        },
        onChanged: (e) {
          prefs.setRememberQuality(e == remember, cellular: cellular);
          if (e != remember) {
            setLevel(e);
          }
        },
      ),
    );
  }
}
