import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// “本直播间特别设置”“本平台特别设置”两个开关（和 Venera 的“本漫画特定设置”一样）。
///
/// 只在直播间里显示（设置页里调的始终是全局）。开启后，以下修改
/// （弹幕、聊天区、追帧、视频信息、画面尺寸、关键词屏蔽、定时关闭）只记到它名下
class RoomSpecificSettings extends StatelessWidget {
  final EdgeInsets margin;
  const RoomSpecificSettings({
    this.margin = const EdgeInsets.only(bottom: 12),
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    var c = AppSettingsController.instance;
    return Obx(() {
      if (c.specificRoomLabel.value.isEmpty) {
        return const SizedBox.shrink();
      }
      var roomOn = c.roomSpecific.value;
      var siteOn = c.siteSpecific.value;
      return Padding(
        padding: margin,
        child: SettingsCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SettingsSwitch(
                title: "本直播间特别设置".t,
                subtitle: "开启后，以下修改仅对本直播间生效".t,
                value: roomOn,
                onChanged: c.setRoomSpecific,
              ),
              if (roomOn && c.roomSpecificHasValues.value)
                Center(
                  child: TextButton(
                    onPressed: c.clearRoomSpecific,
                    child: Text("清除本直播间特别设置".t),
                  ),
                ),
              AppStyle.divider,
              SettingsSwitch(
                title: "本平台特别设置".t,
                subtitle: "开启后，以下修改对本平台所有直播间生效；直播间设置优先".t,
                value: siteOn,
                onChanged: c.setSiteSpecific,
              ),
              if (siteOn && c.siteSpecificHasValues.value)
                Center(
                  child: TextButton(
                    onPressed: c.clearSiteSpecific,
                    child: Text("清除本平台特别设置".t),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}
