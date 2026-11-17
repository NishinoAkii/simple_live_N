import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/widgets/settings/settings_number.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 直播追帧加速设置：开关、最高倍速（1.01~2.00，步长 0.01）、目标缓冲
class CatchUpSettings extends StatelessWidget {
  const CatchUpSettings({super.key});

  @override
  Widget build(BuildContext context) {
    var settings = AppSettingsController.instance;
    return Obx(
      () => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingsSwitch(
            title: "追帧加速".t,
            subtitle: "画面落后时加快播放，卡住加载时恢复正常速度".t,
            value: settings.liveCatchUp.value,
            onChanged: settings.setLiveCatchUp,
          ),
          if (settings.liveCatchUp.value) ...[
            AppStyle.divider,
            SettingsNumber(
              title: "最高倍速".t,
              value: (settings.liveCatchUpMaxRate.value * 100).round(),
              min: 101,
              max: 200,
              step: 1,
              displayValue:
                  "${settings.liveCatchUpMaxRate.value.toStringAsFixed(2)}x",
              onChanged: (e) => settings.setLiveCatchUpMaxRate(e / 100),
            ),
            Padding(
              padding: AppStyle.edgeInsetsH12,
              child: Slider(
                min: 1.01,
                max: 2.0,
                divisions: 99,
                value: settings.liveCatchUpMaxRate.value.clamp(1.01, 2.0),
                label:
                    "${settings.liveCatchUpMaxRate.value.toStringAsFixed(2)}x",
                onChanged: settings.setLiveCatchUpMaxRate,
              ),
            ),
            AppStyle.divider,
            SettingsNumber(
              title: "目标缓冲".t,
              subtitle:
                  "缓冲超过这个值 1 秒以上就加速。越小越接近实时，也越容易卡；Twitch、Kick 等分段直播最少按 4 秒算".t,
              value: (settings.liveCatchUpTarget.value * 10).round(),
              min: 5,
              max: 100,
              step: 5,
              displayValue:
                  "{liveCatchUpTarget}秒".tf({"liveCatchUpTarget": settings.liveCatchUpTarget.value.toStringAsFixed(1)}),
              onChanged: (e) => settings.setLiveCatchUpTarget(e / 10),
            ),
          ],
        ],
      ),
    );
  }
}
