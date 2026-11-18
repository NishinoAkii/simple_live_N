import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/capture/capture_settings.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/widgets/settings/capture_settings_view.dart';
import 'package:simple_live_app/widgets/settings/catch_up_settings.dart';
import 'package:simple_live_app/widgets/settings/ios_pip_settings.dart';
import 'package:simple_live_app/widgets/settings/obs_bridge_settings.dart';
import 'package:simple_live_app/widgets/settings/play_prefs_settings.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_menu.dart';
import 'package:simple_live_app/widgets/settings/settings_number.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class PlaySettingsPage extends GetView<AppSettingsController> {
  const PlaySettingsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("直播间设置".t),
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
            child: Text(
              "播放器".t,
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(
                  () => SettingsSwitch(
                    title: "硬件解码".t,
                    value: controller.hardwareDecode.value,
                    subtitle: "播放不出来时可以试试关掉".t,
                    onChanged: (e) {
                      controller.setHardwareDecode(e);
                    },
                  ),
                ),
                if (Platform.isAndroid) AppStyle.divider,
                Obx(
                  () => Visibility(
                    visible: Platform.isAndroid,
                    child: SettingsSwitch(
                      title: "兼容模式".t,
                      subtitle: "播放卡顿时可以试试打开".t,
                      value: controller.playerCompatMode.value,
                      onChanged: (e) {
                        controller.setPlayerCompatMode(e);
                      },
                    ),
                  ),
                ),
                // AppStyle.divider,
                // Obx(
                //   () => SettingsNumber(
                //     title: "缓冲区大小",
                //     subtitle: "若播放卡顿可尝试调高此选项",
                //     value: controller.playerBufferSize.value,
                //     min: 32,
                //     max: 1024,
                //     step: 4,
                //     unit: "MB",
                //     onChanged: (e) {
                //       controller.setPlayerBufferSize(e);
                //     },
                //   ),
                // ),
                AppStyle.divider,
                const CatchUpSettings(),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "进入后台自动暂停".t,
                    value: controller.playerAutoPause.value,
                    onChanged: (e) {
                      controller.setPlayerAutoPause(e);
                    },
                  ),
                ),
                // 音频焦点（安卓）和音频会话（iOS），电脑上没有
                if (Platform.isAndroid || Platform.isIOS) ...[
                  AppStyle.divider,
                  Obx(
                    () => SettingsSwitch(
                      title: "与其他应用同时播放".t,
                      subtitle: "开启后与其他应用同时出声，互不暂停".t,
                      value: controller.playWithOthers.value,
                      onChanged: controller.setPlayWithOthers,
                    ),
                  ),
                ],
                AppStyle.divider,
                Obx(
                  () => SettingsMenu<int>(
                    title: "画面尺寸".t,
                    value: controller.scaleMode.value,
                    valueMap: {
                      0: "适应".t,
                      1: "拉伸".t,
                      2: "铺满".t,
                      3: "16:9",
                      4: "4:3",
                    },
                    onChanged: (e) {
                      controller.setScaleMode(e);
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "使用HTTPS链接".t,
                    subtitle: "把 http 链接换成 https".t,
                    value: controller.playerForceHttps.value,
                    onChanged: (e) {
                      controller.setPlayerForceHttps(e);
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "显示视频信息（帧率、码率等）".t,
                    subtitle: "在画面左上角显示分辨率、帧率、码率、丢帧、缓冲和网速".t,
                    value: controller.playerVideoStats.value,
                    onChanged: (e) {
                      controller.setPlayerVideoStats(e);
                    },
                  ),
                ),
                AppStyle.divider,
                // 浮层显示哪几行（直播间顶栏的按钮开关浮层）
                const VideoStatsFieldsSetting(),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "直播间".t,
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(
                  () => SettingsSwitch(
                    title: "进入直播间自动全屏".t,
                    value: controller.autoFullScreen.value,
                    onChanged: (e) {
                      controller.setAutoFullScreen(e);
                    },
                  ),
                ),
                if (Platform.isAndroid) ...[
                  AppStyle.divider,
                  const FullscreenOrientationSetting(),
                ],
                AppStyle.divider,
                Obx(
                  () => Visibility(
                    visible: Platform.isAndroid,
                    child: SettingsSwitch(
                      title: "进入小窗隐藏弹幕".t,
                      value: controller.pipHideDanmu.value,
                      onChanged: (e) {
                        controller.setPIPHideDanmu(e);
                      },
                    ),
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "播放器中显示SC".t,
                    value: controller.playershowSuperChat.value,
                    onChanged: (e) {
                      controller.setPlayerShowSuperChat(e);
                    },
                  ),
                ),
              ],
            ),
          ),
          if (Platform.isIOS) ...[
            Padding(
              padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
              child: Text(
                "画中画与投屏".t,
                style: Get.textTheme.titleSmall,
              ),
            ),
            const SettingsCard(child: IosPipSettings()),
          ],
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "清晰度".t,
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              children: [
                QualityLevelSetting(
                  title: "默认清晰度".t,
                  cellular: false,
                  level: controller.qualityLevel,
                  setLevel: controller.setQualityLevel,
                ),
                AppStyle.divider,
                QualityLevelSetting(
                  title: "数据网络清晰度".t,
                  cellular: true,
                  level: controller.qualityLevelCellular,
                  setLevel: controller.setQualityLevelCellular,
                ),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "聊天区".t,
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(
                  () => SettingsNumber(
                    title: "文字大小".t,
                    value: controller.chatTextSize.value.toInt(),
                    min: 8,
                    max: 36,
                    onChanged: (e) {
                      controller.setChatTextSize(e.toDouble());
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsNumber(
                    title: "上下间隔".t,
                    value: controller.chatTextGap.value.toInt(),
                    min: 0,
                    max: 12,
                    onChanged: (e) {
                      controller.setChatTextGap(e.toDouble());
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "气泡样式".t,
                    value: controller.chatBubbleStyle.value,
                    onChanged: (e) {
                      controller.setChatBubbleStyle(e);
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "彩色用户名".t,
                    subtitle: "用发言人自己的名字颜色（Twitch、Kick）".t,
                    value: controller.chatNameColor.value,
                    onChanged: controller.setChatNameColor,
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "名字前显示牌子".t,
                    subtitle: "粉丝牌、舰长等，不用点开就能看到".t,
                    value: controller.chatShowBadges.value,
                    onChanged: controller.setChatShowBadges,
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "聊天栏显示头像".t,
                    subtitle: "平台提供头像时（如 YouTube）显示在名字前".t,
                    value: controller.chatShowFace.value,
                    onChanged: (e) {
                      controller.setChatShowFace(e);
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "聊天栏表情播放动图".t,
                    subtitle: "关闭时只显示第一帧，更省 CPU 和内存".t,
                    value: controller.chatAnimatedEmotes.value,
                    onChanged: controller.setChatAnimatedEmotes,
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "显示榜单".t,
                    subtitle: "礼物页中的榜单、点击在线人数打开榜单，以及全屏时的榜单按钮".t,
                    value: controller.liveRankTab.value,
                    onChanged: controller.setLiveRankTab,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              CaptureFeatures.recording ? "截图和录屏".t : "截图".t,
              style: Get.textTheme.titleSmall,
            ),
          ),
          const SettingsCard(child: CaptureSettingsView()),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "录屏接口（OBS 等）".t,
              style: Get.textTheme.titleSmall,
            ),
          ),
          const SettingsCard(child: ObsBridgeSettings()),
        ],
      ),
    );
  }
}
