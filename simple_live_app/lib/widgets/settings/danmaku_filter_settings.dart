import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/danmaku_filter_settings.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_menu.dart';
import 'package:simple_live_app/widgets/settings/settings_number.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';

/// “弹幕屏蔽”卡片里的重复弹幕过滤（开关打开后才显示下面几项）
class DanmakuDedupeSettings extends StatelessWidget {
  const DanmakuDedupeSettings({super.key});

  @override
  Widget build(BuildContext context) {
    var c = AppSettingsController.instance;
    return Obx(() {
      var on = c.danmuDedupe.value;
      var byUser = c.danmuDedupeMode.value != DanmakuFilterSettings.modeContent;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingsSwitch(
            title: "过滤重复弹幕".t,
            subtitle: "时间范围内同样的弹幕超过设定次数后不再显示".t,
            value: on,
            onChanged: c.setDanmuDedupe,
          ),
          if (on) ...[
            AppStyle.divider,
            SettingsNumber(
              title: "时间范围".t,
              value: c.danmuDedupeWindow.value,
              min: DanmakuFilterSettings.minWindow,
              max: DanmakuFilterSettings.maxWindow,
              format: (v) => "{seconds} 秒".tf({"seconds": v}),
              onChanged: c.setDanmuDedupeWindow,
            ),
            AppStyle.divider,
            SettingsMenu<int>(
              title: "比较方式".t,
              subtitle: byUser ? "同一个人发的相同内容才算重复".t : "内容相同就算重复，不区分发送的人".t,
              value: byUser
                  ? DanmakuFilterSettings.modeUser
                  : DanmakuFilterSettings.modeContent,
              valueMap: {
                DanmakuFilterSettings.modeUser: "同一个人".t,
                DanmakuFilterSettings.modeContent: "只看内容".t,
              },
              onChanged: c.setDanmuDedupeMode,
            ),
            AppStyle.divider,
            SettingsNumber(
              title: "允许出现几次".t,
              value: c.danmuDedupeMax.value,
              min: DanmakuFilterSettings.minMax,
              max: DanmakuFilterSettings.maxMax,
              format: (v) => "{count} 次".tf({"count": v}),
              onChanged: c.setDanmuDedupeMax,
            ),
            AppStyle.divider,
            SettingsSwitch(
              title: "聊天区也去掉重复".t,
              subtitle: "关闭时只过滤视频上的弹幕。录屏接口和弹幕记录与聊天区一致".t,
              value: c.danmuDedupeChat.value,
              onChanged: c.setDanmuDedupeChat,
            ),
          ],
        ],
      );
    });
  }
}

/// 弹幕延迟的写法：十分之一秒写成“1.5 秒”
String danmakuDelayText(int tenths) =>
    "{seconds} 秒".tf({"seconds": (tenths / 10).toStringAsFixed(1)});

/// 正在看的是直播间。直播间的设置上下文 id 以“live:”开头
bool _inLiveRoom(RoomContext? context) =>
    context != null && context.id.startsWith("live:");

/// 直播间的“弹幕设置”卡片里的一行：调的是当前平台的弹幕延迟。
/// 不在直播间时（设置页）不显示
class DanmakuDelayRoomRow extends StatelessWidget {
  const DanmakuDelayRoomRow({super.key});

  @override
  Widget build(BuildContext context) {
    var c = AppSettingsController.instance;
    return Obx(() {
      // 换直播间时跟着换（平台名字变了就重新读当前的直播间）
      c.specificSiteLabel.value;
      var room = c.currentRoomContext;
      if (!_inLiveRoom(room)) {
        return const SizedBox.shrink();
      }
      var siteId = room!.siteId;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppStyle.divider,
          SettingsNumber(
            title: "弹幕延迟（{name}）".tf({"name": room.siteName}),
            subtitle: "画面比弹幕慢时调大，每个平台分别保存。与弹幕缓冲增强的等待叠加".t,
            value: c.danmuDelayTenths(siteId),
            min: 0,
            max: DanmakuFilterSettings.maxDelayTenths,
            format: danmakuDelayText,
            onChanged: (e) => c.setDanmuDelay(siteId, e),
          ),
        ],
      );
    });
  }
}

/// 设置页里的“弹幕延迟”：列出全部平台。在直播间里不显示
class DanmakuDelaySection extends StatelessWidget {
  const DanmakuDelaySection({super.key});

  @override
  Widget build(BuildContext context) {
    var c = AppSettingsController.instance;
    return Obx(() {
      c.specificSiteLabel.value;
      if (c.currentRoomContext != null) {
        return const SizedBox.shrink();
      }
      Sites.version.value;
      var sites = Sites.supportSites;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24, bottom: 4),
            child: Text(
              "弹幕延迟".t,
              style: Get.textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsH12.copyWith(bottom: 8),
            child: Text(
              "只延迟视频上的弹幕。画面比弹幕慢时调大。开启弹幕缓冲增强时，两段等待会叠加".t,
              style: Get.textTheme.bodySmall!.copyWith(color: Colors.grey),
            ),
          ),
          SettingsCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < sites.length; i++) ...[
                  if (i > 0) AppStyle.divider,
                  SettingsNumber(
                    title: sites[i].name,
                    value: c.danmuDelayTenths(sites[i].id),
                    min: 0,
                    max: DanmakuFilterSettings.maxDelayTenths,
                    format: danmakuDelayText,
                    onChanged: (e) => c.setDanmuDelay(sites[i].id, e),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    });
  }
}
