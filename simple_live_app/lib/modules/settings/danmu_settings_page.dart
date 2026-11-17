import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/widgets/settings/danmaku_filter_settings.dart';
import 'package:simple_live_app/widgets/settings/ios_pip_settings.dart';
import 'package:simple_live_app/widgets/settings/pip_danmaku_settings.dart';
import 'package:simple_live_app/widgets/settings/room_specific_settings.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_number.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 设置里的“弹幕设置”页：调的始终是全局的（直播间开着时也是），
/// 打开时切到全局，关掉后回到直播间的单独设置
class DanmuSettingsPage extends StatefulWidget {
  const DanmuSettingsPage({Key? key}) : super(key: key);

  @override
  State<DanmuSettingsPage> createState() => _DanmuSettingsPageState();
}

class _DanmuSettingsPageState extends State<DanmuSettingsPage> {
  static const String _contextId = "settings:danmu";

  @override
  void initState() {
    super.initState();
    AppSettingsController.instance
        .enterRoomContext(const RoomContext.global(_contextId));
  }

  @override
  void dispose() {
    AppSettingsController.instance.leaveRoomContext(_contextId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("弹幕设置".t),
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: const [
          DanmuSettingsView(),
        ],
      ),
    );
  }
}

class DanmuSettingsView extends GetView<AppSettingsController> {
  final Function()? onTapDanmuShield;
  final DanmakuController? danmakuController;
  const DanmuSettingsView({
    this.onTapDanmuShield,
    this.danmakuController,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 直播间、平台单独设置放在最上面（只在直播间里出现）
        const RoomSpecificSettings(),
        Padding(
          padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
          child: Text(
            "弹幕屏蔽".t,
            style: Get.textTheme.titleSmall,
          ),
        ),
        SettingsCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SettingsAction(
                title: "关键词屏蔽".t,
                onTap: onTapDanmuShield ??
                    () => Get.toNamed(RoutePath.kSettingsDanmuShield),
              ),
              AppStyle.divider,
              const DanmakuDedupeSettings(),
            ],
          ),
        ),
        Padding(
          padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
          child: Text(
            "弹幕设置".t,
            style: Get.textTheme.titleSmall,
          ),
        ),
        SettingsCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Obx(
                () => SettingsSwitch(
                  title: "默认显示弹幕".t,
                  value: controller.danmuEnable.value,
                  onChanged: (e) {
                    controller.setDanmuEnable(e);
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "弹幕显示表情图片".t,
                  subtitle: "弹幕和聊天栏的表情显示成图片，关掉就显示文字".t,
                  value: controller.danmuEmoteImage.value,
                  onChanged: (e) {
                    controller.setDanmuEmoteImage(e);
                  },
                ),
              ),
              // 表情默认随文字大小一起变化；打开开关后才出现单独的表情大小
              Obx(
                () => Visibility(
                  visible: controller.danmuEmoteImage.value,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppStyle.divider,
                      SettingsSwitch(
                        title: "单独调整表情大小".t,
                        subtitle: "关掉时表情随文字一起变大变小".t,
                        value: controller.emoteSizeSeparate.value,
                        onChanged: controller.setEmoteSizeSeparate,
                      ),
                      if (controller.emoteSizeSeparate.value) ...[
                        AppStyle.divider,
                        SettingsNumber(
                          title: "表情大小".t,
                          subtitle: "文字大小的百分比，弹幕和聊天栏都生效".t,
                          value: (controller.emoteScale.value * 100).round(),
                          min: 50,
                          max: 300,
                          step: 10,
                          unit: "%",
                          onChanged: (e) => controller.setEmoteScale(e / 100),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "彩色弹幕".t,
                  subtitle: "关闭时全部为白色。Twitch、Kick 的颜色是发言人的名字颜色".t,
                  value: controller.danmuColorful.value,
                  onChanged: controller.setDanmuColorful,
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "弹幕缓冲增强".t,
                  subtitle: "平台一阵一阵发弹幕时先攒一会儿再匀速放出，视频上的弹幕和聊天栏都不断流；会晚一两秒".t,
                  value: controller.danmuBufferBoost.value,
                  onChanged: controller.setDanmuBufferBoost,
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsNumber(
                  title: "缓冲增强的起始弹幕量".t,
                  subtitle: "平均每秒弹幕少于这个数时不缓冲，收到就放".t,
                  value: controller.danmuBufferMinRate.value,
                  min: 1,
                  max: 50,
                  unit: " 条/秒".t,
                  onChanged: controller.setDanmuBufferMinRate,
                ),
              ),
              // 直播间里：当前平台的弹幕延迟
              const DanmakuDelayRoomRow(),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "视频左下角显示付费礼物".t,
                  subtitle: "与 SC 共用位置，每条显示 5 秒，连击每次延长 1 秒；关闭后仍记录在礼物页".t,
                  value: controller.danmuGiftFly.value,
                  onChanged: controller.setDanmuGiftFly,
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsNumber(
                  title: "显示区域".t,
                  value: (controller.danmuArea.value * 100).toInt(),
                  min: 10,
                  max: 100,
                  step: 10,
                  unit: "%",
                  onChanged: (e) {
                    controller.setDanmuArea(e / 100.0);
                    updateDanmuOption(
                      danmakuController?.option.copyWith(area: e / 100.0),
                    );
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsNumber(
                  title: "不透明度".t,
                  value: (controller.danmuOpacity.value * 100).toInt(),
                  min: 10,
                  max: 100,
                  step: 10,
                  unit: "%",
                  onChanged: (e) {
                    controller.setDanmuOpacity(e / 100.0);
                    updateDanmuOption(
                      danmakuController?.option.copyWith(opacity: e / 100.0),
                    );
                  },
                ),
              ),
              AppStyle.divider,
              // 大小和速度由直播间按全屏/非全屏/小窗自己套用
              Obx(
                () => SettingsNumber(
                  title: AppSettingsController.danmakuPerMode
                      ? "字体大小（非全屏）".t
                      : "字体大小".t,
                  value: controller.danmuSize.toInt(),
                  min: 8,
                  max: 48,
                  onChanged: (e) => controller.setDanmuSize(e.toDouble()),
                ),
              ),
              if (AppSettingsController.danmakuPerMode) ...[
                AppStyle.divider,
                Obx(
                  () => SettingsNumber(
                    title: "字体大小（全屏）".t,
                    subtitle: Platform.isIOS ? "投屏到电视时也用这个大小".t : null,
                    value: controller.danmuSizeFullscreen.value.toInt(),
                    min: 8,
                    max: 48,
                    onChanged: (e) =>
                        controller.setDanmuSizeFullscreen(e.toDouble()),
                  ),
                ),
              ],
              AppStyle.divider,
              Obx(
                () => SettingsNumber(
                  title: "字体粗细".t,
                  value: controller.danmuFontWeight.value,
                  min: 1,
                  max: 9,
                  step: 1,
                  displayValue: [
                    "极细".t,
                    "很细".t,
                    "细".t,
                    "正常".t,
                    "小粗".t,
                    "偏粗".t,
                    "粗".t,
                    "很粗".t,
                    "极粗".t
                  ][controller.danmuFontWeight.value - 1]
                      .toString(),
                  onChanged: (e) {
                    controller.setDanmuFontWeight(e);
                    updateDanmuOption(
                      danmakuController?.option.copyWith(
                        fontWeight: e,
                      ),
                    );
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsNumber(
                  title: "滚动速度".t,
                  subtitle: AppSettingsController.danmakuPerMode
                      ? "从右走到左要几秒，越小越快；全屏和非全屏共用，小窗另外设置".t
                      : "从右走到左要几秒，越小越快".t,
                  value: controller.danmuSpeed.toInt(),
                  min: 4,
                  max: 20,
                  onChanged: (e) => controller.setDanmuSpeed(e.toDouble()),
                ),
              ),
              // AppStyle.divider,
              // Obx(
              //   () => SettingsNumber(
              //     title: "字体描边",
              //     value: controller.danmuStrokeWidth.toInt(),
              //     min: 0,
              //     max: 10,
              //     onChanged: (e) {
              //       controller.setDanmuStrokeWidth(e.toDouble());
              //       updateDanmuOption(
              //         danmakuController?.option
              //             .copyWith(strokeWidth: e.toDouble()),
              //       );
              //     },
              //   ),
              // ),
              AppStyle.divider,
              Obx(
                () => SettingsNumber(
                  title: "顶部边距".t,
                  subtitle: "曲面屏上边显示不全时调大".t,
                  value: controller.danmuTopMargin.toInt(),
                  min: 0,
                  max: 48,
                  step: 4,
                  onChanged: (e) {
                    controller.setDanmuTopMargin(e.toDouble());
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsNumber(
                  title: "底部边距".t,
                  subtitle: "曲面屏下边显示不全时调大".t,
                  value: controller.danmuBottomMargin.toInt(),
                  min: 0,
                  max: 48,
                  step: 4,
                  onChanged: (e) {
                    controller.setDanmuBottomMargin(e.toDouble());
                  },
                ),
              ),
            ],
          ),
        ),
        // 设置页里：全部平台的弹幕延迟
        const DanmakuDelaySection(),
        // 小窗（画中画）里的弹幕：手机才有系统小窗
        if (Platform.isAndroid || Platform.isIOS) ...[
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "小窗（画中画）弹幕".t,
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Platform.isIOS
                ? const IosPipSettings(danmakuOnly: true)
                : Obx(
                    () => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SettingsSwitch(
                          title: "小窗显示弹幕".t,
                          subtitle: "和直播间的“进入小窗隐藏弹幕”是同一个开关".t,
                          value: !controller.pipHideDanmu.value,
                          onChanged: (e) => controller.setPIPHideDanmu(!e),
                        ),
                        if (!controller.pipHideDanmu.value) ...[
                          AppStyle.divider,
                          const PipDanmakuSettings(),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ],
    );
  }

  void updateDanmuOption(DanmakuOption? option) {
    if (danmakuController == null || option == null) return;
    danmakuController!.updateOption(option);
  }
}
