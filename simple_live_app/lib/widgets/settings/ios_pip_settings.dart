import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_menu.dart';
import 'package:simple_live_app/widgets/settings/pip_danmaku_settings.dart';
import 'package:simple_live_app/widgets/settings/settings_number.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// iOS 画中画弹幕和投屏（屏幕镜像）设置
class IosPipSettings extends StatelessWidget {
  /// 只显示画中画弹幕的几项（弹幕设置页里用）
  final bool danmakuOnly;
  const IosPipSettings({this.danmakuOnly = false, super.key});

  @override
  Widget build(BuildContext context) {
    var settings = AppSettingsController.instance;
    return Obx(
      () {
        // 系统播放器方式（默认）；mpv 是旧方式
        var avEngine = settings.iosPipEngine.value == 0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!danmakuOnly) ...[
              SettingsMenu<int>(
                title: "小窗播放方式".t,
                subtitle: avEngine
                    ? ("用 iOS 系统播放器，后台更稳更省电；"
                        "没有能用的地址时自动改用 mpv").t
                    : "把 mpv 画面放进系统小窗，后台放久了可能被系统关掉".t,
                value: settings.iosPipEngine.value,
                valueMap: {
                  0: "系统播放器（推荐）".t,
                  1: "mpv（旧方式）".t,
                },
                onChanged: settings.setIosPipEngine,
              ),
              if (avEngine) ...[
                AppStyle.divider,
                SettingsSwitch(
                  title: "退到后台自动开小窗".t,
                  subtitle: "在直播间时静音多开一路系统播放器（多用约 2.5 Mbps 流量）".t,
                  value: settings.iosPipAutoStart.value,
                  onChanged: settings.setIosPipAutoStart,
                ),
              ],
              AppStyle.divider,
            ],
            SettingsSwitch(
              title: "画中画显示弹幕".t,
              subtitle: "颜色和透明度同弹幕设置，大小和速度在下面调".t,
              value: settings.iosPipDanmaku.value,
              onChanged: settings.setIosPipDanmaku,
            ),
            if (settings.iosPipDanmaku.value) ...[
              if (avEngine) ...[
                AppStyle.divider,
                SettingsMenu<int>(
                  title: "小窗弹幕方式".t,
                  subtitle: settings.iosPipDanmakuMode.value == 1
                      ? ("标准系统小窗（有暂停、快进按钮），弹幕叠在上面；"
                          "以后的 iOS 可能不支持，到时就没有弹幕了").t
                      : "显示画面和弹幕，没有暂停和进度按钮".t,
                  value: settings.iosPipDanmakuMode.value,
                  valueMap: {
                    0: "通话式（推荐）".t,
                    1: "叠加到系统小窗（实验）".t,
                  },
                  onChanged: settings.setIosPipDanmakuMode,
                ),
              ],
              AppStyle.divider,
              const PipDanmakuSettings(),
              AppStyle.divider,
              SettingsNumber(
                title: "画中画弹幕行数".t,
                value: settings.iosPipDanmakuLines.value,
                min: 1,
                max: 10,
                unit: "行".t,
                onChanged: settings.setIosPipDanmakuLines,
              ),
              if (avEngine) ...[
                AppStyle.divider,
                SettingsSwitch(
                  title: "小窗显示醒目留言".t,
                  subtitle: "用自己的颜色在小窗顶部显示 10 秒".t,
                  value: settings.iosPipSuperChat.value,
                  onChanged: settings.setIosPipSuperChat,
                ),
              ],
            ],
            if (!danmakuOnly) ...[
              AppStyle.divider,
              SettingsAction(
                title: "画中画帧率（仅 mpv 方式）".t,
                subtitle: "60 帧更流畅，30 帧更省电；小窗很快被系统关掉就改回 30 帧".t,
                value: "{iosPipFrameRate} 帧".tf({"iosPipFrameRate": settings.iosPipFrameRate.value}),
                onTap: () async {
                  var value = await Utils.showOptionDialog<int>(
                    const [60, 30],
                    settings.iosPipFrameRate.value,
                    title: "画中画帧率".t,
                  );
                  if (value != null) {
                    settings.setIosPipFrameRate(value);
                  }
                },
              ),
              AppStyle.divider,
              SettingsAction(
                title: "画中画画质（仅 mpv 方式）".t,
                subtitle: "小窗最大尺寸，越高越清晰也越耗电".t,
                value: "${settings.iosPipQuality.value}p",
                onTap: () async {
                  var value = await Utils.showOptionDialog<int>(
                    const [540, 720, 1080],
                    settings.iosPipQuality.value,
                    title: "画中画画质".t,
                  );
                  if (value != null) {
                    settings.setIosPipQuality(value);
                  }
                },
              ),
              AppStyle.divider,
              SettingsSwitch(
                title: "投屏时电视只显示画面和弹幕".t,
                subtitle: "用“屏幕镜像”投到 Apple TV 或 AirPlay 电视后，打开直播间生效，手机照常能用；关掉则镜像整个屏幕".t,
                value: settings.iosExternalDisplay.value,
                onChanged: settings.setIosExternalDisplay,
              ),
              if (settings.iosExternalDisplay.value) ...[
                AppStyle.divider,
                SettingsSwitch(
                  title: "电视显示右侧聊天栏".t,
                  value: settings.iosExternalSidebar.value,
                  onChanged: settings.setIosExternalSidebar,
                ),
              ],
            ],
          ],
        );
      },
    );
  }
}
