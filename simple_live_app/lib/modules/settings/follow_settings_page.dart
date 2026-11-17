import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/live_notify_service.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'dart:io';
import 'package:simple_live_app/i18n/i18n.dart';

class FollowSettingsPage extends GetView<AppSettingsController> {
  const FollowSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("关注设置".t),
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          SettingsCard(
            child: Column(
              children: [
                Obx(
                  () => SettingsSwitch(
                    value: controller.autoUpdateFollowEnable.value,
                    title: "自动更新关注直播状态".t,
                    onChanged: (e) {
                      controller.setAutoUpdateFollowEnable(e);
                      FollowService.instance.initTimer();
                    },
                  ),
                ),
                Obx(
                  () => Visibility(
                    visible: controller.autoUpdateFollowEnable.value,
                    child: AppStyle.divider,
                  ),
                ),
                Obx(
                  () => Visibility(
                    visible: controller.autoUpdateFollowEnable.value,
                    child: SettingsAction(
                      title: "自动更新间隔".t,
                      value:
                          "{p}小时{p2}分钟".tf({"p": controller.autoUpdateFollowDuration.value ~/ 60, "p2": controller.autoUpdateFollowDuration.value % 60}),
                      onTap: () {
                        setTimer(context);
                      },
                    ),
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () {
                    var threadCount = controller.updateFollowThreadCount.value;
                    var displayValue = threadCount == 0
                        ? "自动（按 CPU 核心数）".t
                        : "$threadCount";

                    return SettingsAction(
                      title: "同时更新的数量".t,
                      subtitle: "0 按 CPU 核心数自动定（推荐），也可手动设 1-20".t,
                      value: displayValue,
                      onTap: () {
                        showConcurrencyDialog();
                      },
                    );
                  },
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsAction(
                    title: "直播间关注页的检查范围".t,
                    subtitle: "关注较多时可以只检查一个分组，或不检查".t,
                    value: liveRoomCheckLabel(
                        controller.liveRoomFollowCheck.value),
                    onTap: showLiveRoomCheckDialog,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "开播提醒".t,
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              children: [
                Obx(
                  () => SettingsSwitch(
                    value: controller.liveNotifyEnable.value,
                    title: "开播时发通知".t,
                    subtitle: "长按关注的直播间，选“开启开播提醒”".t,
                    onChanged: controller.setLiveNotifyEnable,
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    value: controller.liveNotifyShowBell.value,
                    title: "所有关注都显示铃铛".t,
                    subtitle: "关闭时只在开启了提醒的直播间显示铃铛".t,
                    onChanged: controller.setLiveNotifyShowBell,
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsAction(
                    title: "检查间隔".t,
                    subtitle: "只检查开启了提醒的直播间，观看直播时也会检查。App 需要保持运行；手机在后台过久会被系统暂停，回到前台后补查".t,
                    value: "{n} 分钟".tf({"n": controller.liveNotifyInterval.value}),
                    onTap: showNotifyIntervalDialog,
                  ),
                ),
                AppStyle.divider,
                SettingsAction(
                  title: "发送测试通知".t,
                  subtitle: "首次使用时会请求通知权限".t,
                  onTap: LiveNotifyService.instance.sendTest,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 直播间里切到“关注”时查的范围显示成什么
  static String liveRoomCheckLabel(String mode) {
    if (mode == "none") {
      return "不检查".t;
    }
    if (mode == "current") {
      return "当前主播的分组".t;
    }
    if (mode.startsWith("tag:")) {
      var id = mode.substring(4);
      var tag = FollowService.instance.followTagList
          .firstWhereOrNull((e) => e.id == id);
      if (tag != null) {
        return tag.tag;
      }
    }
    return "全部关注".t;
  }

  void showLiveRoomCheckDialog() {
    FollowService.instance.getAllTagList();
    var current = controller.liveRoomFollowCheck.value;
    var options = <(String, String, String?)>[
      ("all", "全部关注".t, null),
      ("current", "当前主播的分组".t, "检查正在观看的主播所在的分组，没有分组时不检查".t),
      for (var tag in FollowService.instance.followTagList)
        ("tag:${tag.id}", tag.tag, null),
      ("none", "不检查".t, "显示上次的检查结果，点击刷新后才检查".t),
    ];
    Get.dialog(
      AlertDialog(
        title: Text("直播间关注页的检查范围".t),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var (value, label, hint) in options)
                  ListTile(
                    title: Text(label),
                    subtitle: hint == null ? null : Text(hint),
                    trailing: value == current ? const Icon(Icons.check) : null,
                    selected: value == current,
                    onTap: () {
                      controller.setLiveRoomFollowCheck(value);
                      Get.back();
                    },
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: Text("取消".t),
          ),
        ],
      ),
    );
  }

  void showNotifyIntervalDialog() {
    var current = controller.liveNotifyInterval.value;
    Get.dialog(
      AlertDialog(
        title: Text("检查间隔".t),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var minutes in const [1, 2, 3, 5, 10, 15, 30])
              ChoiceChip(
                label: Text("{n} 分钟".tf({"n": minutes})),
                selected: current == minutes,
                onSelected: (_) {
                  controller.setLiveNotifyInterval(minutes);
                  Get.back();
                },
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: Text("取消".t),
          ),
        ],
      ),
    );
  }

  void setTimer(BuildContext context) async {
    var value = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: controller.autoUpdateFollowDuration.value ~/ 60,
        minute: controller.autoUpdateFollowDuration.value % 60,
      ),
      initialEntryMode: TimePickerEntryMode.inputOnly,
      builder: (_, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            alwaysUse24HourFormat: true,
          ),
          child: child!,
        );
      },
    );
    if (value == null || (value.hour == 0 && value.minute == 0)) {
      return;
    }
    var duration = Duration(hours: value.hour, minutes: value.minute);
    controller.setAutoUpdateFollowDuration(duration.inMinutes);
    FollowService.instance.initTimer();
  }

  void showConcurrencyDialog() {
    var currentValue = controller.updateFollowThreadCount.value;
    var cpuCount = Platform.numberOfProcessors;
    var autoValue = (cpuCount * 2.5).round().clamp(4, 20);

    Get.dialog(
      AlertDialog(
        title: Text("同时更新的数量".t),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "CPU 核心数：{cpuCount}".tf({"cpuCount": cpuCount}),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            Text(
              "自动推荐：{autoValue}".tf({"autoValue": autoValue}),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Text(
              "选一个数量".t,
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 8),
            // 快捷选项
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildQuickOption(0, "自动（{autoValue}）".tf({"autoValue": autoValue}), currentValue),
                _buildQuickOption(4, "4", currentValue),
                _buildQuickOption(8, "8", currentValue),
                _buildQuickOption(12, "12", currentValue),
                _buildQuickOption(16, "16", currentValue),
                _buildQuickOption(20, "20", currentValue),
              ],
            ),
            const SizedBox(height: 16),
            // 自定义输入
            TextField(
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: "自定义（1-20）".t,
                border: const OutlineInputBorder(),
                hintText: "输入 1-20 之间的数字".t,
              ),
              onSubmitted: (value) {
                var num = int.tryParse(value);
                if (num != null && num >= 0 && num <= 20) {
                  controller.setUpdateFollowThreadCount(num);
                  Get.back();
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: Text("取消".t),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickOption(int value, String label, int currentValue) {
    var isSelected = currentValue == value;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          controller.setUpdateFollowThreadCount(value);
          Get.back();
        }
      },
    );
  }
}
