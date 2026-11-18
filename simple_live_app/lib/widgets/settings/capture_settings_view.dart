import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/capture/capture_controller.dart';
import 'package:simple_live_app/app/capture/capture_settings.dart';
import 'package:simple_live_app/app/capture/capture_storage.dart';
import 'package:simple_live_app/app/capture/capture_widgets.dart';
import 'package:simple_live_app/app/capture/native_capture.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_menu.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_app/widgets/video_stats_overlay.dart';

/// 设置里的“截图和录屏”：包含哪些层、范围、尺寸、录屏方式、录屏保存为、最长时间、
/// 截图后做什么、图片信息、全屏按键、保存位置（电脑）。没开录屏（[CaptureFeatures.recording]）时
/// 只有截图的设置，录屏的不显示（存着的不动）；画面录制没开时没有录屏方式和它的说明
class CaptureSettingsView extends StatefulWidget {
  const CaptureSettingsView({super.key});

  @override
  State<CaptureSettingsView> createState() => _CaptureSettingsViewState();
}

class _CaptureSettingsViewState extends State<CaptureSettingsView> {
  bool _screen = false;
  bool _copy = false;
  String _defaultDir = "";

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    var screen = CaptureFeatures.screenRecording &&
        await CaptureController.screenRecordSupported();
    var copy = await CaptureClipboard.supported();
    var dir = CaptureFolders.desktop
        ? (await CaptureFolders.defaultDesktopDir()).path
        : "";
    if (mounted) {
      setState(() {
        _screen = screen;
        _copy = copy;
        _defaultDir = dir;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    var settings = CaptureSettings.instance;
    var recording = CaptureFeatures.recording;
    var screenRecording = CaptureFeatures.screenRecording;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 包含哪些层：默认只有弹幕
        const CaptureLayersSetting(),
        AppStyle.divider,
        Obx(
          () => SettingsMenu<CaptureRange>(
            title: "截图范围".t,
            subtitle: screenRecording ? "截图和画面录制都按这个".t : null,
            value: settings.range.value,
            valueMap: {
              CaptureRange.player: "直播画面".t,
              CaptureRange.window: "完整窗口".t,
            },
            onChanged: settings.setRange,
          ),
        ),
        AppStyle.divider,
        Obx(() {
          var size = settings.imageSize.value;
          return SettingsMenu<CaptureImageSize>(
            title: "截图尺寸".t,
            subtitle: size == CaptureImageSize.source
                ? "按视频的原始分辨率".t
                : "按屏幕上显示的大小，文件更小".t,
            value: size,
            valueMap: {
              CaptureImageSize.source: "原画".t,
              CaptureImageSize.screen: "和屏幕一样".t,
            },
            onChanged: settings.setImageSize,
          );
        }),
        if (screenRecording) ...[
          AppStyle.divider,
          Obx(() {
            var mode = settings.recordMode.value;
            var screen = mode == CaptureRecordMode.screen && _screen;
            return SettingsMenu<CaptureRecordMode>(
              title: "录屏方式".t,
              subtitle: !_screen
                  ? "这台设备用不了画面录制，只能流录制".t
                  : screen
                      ? "录下看到的画面，存成 MP4；没选的图层录制时会暂时藏起来".t
                      : "原样存下视频流，不带弹幕".t,
              value: _screen ? mode : CaptureRecordMode.stream,
              valueMap: {
                CaptureRecordMode.stream: "流录制".t,
                if (_screen) CaptureRecordMode.screen: "画面录制".t,
              },
              onChanged: settings.setRecordMode,
            );
          }),
        ],
        if (recording) ...[
          AppStyle.divider,
          Obx(
            () => SettingsMenu<CaptureRecordFormat>(
              title: "录屏保存为".t,
              subtitle: settings.gif
                  ? "只有画面，没有声音和弹幕，最长 1 分钟".t
                  : "原样保存直播流（MKV），不带弹幕".t,
              value: settings.recordFormat.value,
              valueMap: {
                CaptureRecordFormat.video: "视频（原始流）".t,
                CaptureRecordFormat.gif: "GIF",
              },
              onChanged: settings.setRecordFormat,
            ),
          ),
          AppStyle.divider,
          Obx(
            () => SettingsMenu<int>(
              title: "最长录制时间".t,
              subtitle: settings.gif
                  ? "到时间自动停下并保存；存成 GIF 时最长 1 分钟".t
                  : "到时间自动停下并保存".t,
              value: settings.maxSeconds.value,
              valueMap: {
                for (var s in CaptureSettings.maxSecondsOptions)
                  s: recordLimitText(s),
              },
              onChanged: settings.setMaxSeconds,
            ),
          ),
        ],
        AppStyle.divider,
        Obx(() {
          var action = settings.afterAction.value;
          if (!_copy && action == CaptureAfterAction.copy) {
            action = CaptureAfterAction.save;
          }
          return SettingsMenu<CaptureAfterAction>(
            title: recording ? "截图、录屏后".t : "截图后".t,
            value: action,
            valueMap: {
              CaptureAfterAction.ask: "询问".t,
              CaptureAfterAction.save: "直接保存".t,
              if (_copy) CaptureAfterAction.copy: "复制".t,
            },
            onChanged: settings.setAfterAction,
          );
        }),
        AppStyle.divider,
        Obx(
          () => SettingsSwitch(
            title: "在图片信息里记录直播间信息".t,
            subtitle: "平台、房间号、标题、主播、时间、链接和应用版本".t,
            value: settings.metadata.value,
            onChanged: settings.setMetadata,
          ),
        ),
        AppStyle.divider,
        Obx(
          () => SettingsSwitch(
            title: "全屏时一直显示截图键".t,
            subtitle: "控制栏收起后也留在右边，小一点、半透明".t,
            value: settings.fullscreenButtons.value,
            onChanged: settings.setFullscreenButtons,
          ),
        ),
        if (CaptureFolders.desktop) ...[
          AppStyle.divider,
          Obx(() {
            var dir = settings.saveDir.value;
            return SettingsAction(
              title: "保存位置".t,
              subtitle: "只在这台电脑上".t,
              value: _shortPath(dir.isEmpty ? _defaultDir : dir),
              onTap: _pickDir,
            );
          }),
        ],
      ],
    );
  }

  Future<void> _pickDir() async {
    var settings = CaptureSettings.instance;
    if (settings.saveDir.value.isNotEmpty) {
      var choice = await Utils.showMapOptionDialog<int>(
        {
          0: "选择其它文件夹".t,
          1: "改回图片文件夹里的 SimpleLive".t,
        },
        -1,
        title: "保存位置".t,
      );
      if (choice == null) {
        return;
      }
      if (choice == 1) {
        settings.setSaveDir("");
        return;
      }
    }
    try {
      var dir = await FilePicker.platform.getDirectoryPath();
      if (dir != null && dir.isNotEmpty) {
        settings.setSaveDir(dir);
      }
    } catch (e) {
      SmartDialog.showToast("无法选择文件夹：{e}".tf({"e": e}));
    }
  }

  static String _shortPath(String path) {
    if (path.length <= 24) {
      return path;
    }
    return "…${path.substring(path.length - 22)}";
  }
}

/// 视频信息浮层显示哪几行（直播间设置里）
class VideoStatsFieldsSetting extends StatelessWidget {
  const VideoStatsFieldsSetting({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      var chosen = CaptureSettings.instance.videoStatsFields;
      var count = chosen.isEmpty ? VideoStats.fieldIds.length : chosen.length;
      return SettingsAction(
        title: "视频信息显示的内容".t,
        value: count == VideoStats.fieldIds.length
            ? "全部".t
            : "{n} 项".tf({"n": count}),
        onTap: () => _open(context),
      );
    });
  }

  void _open(BuildContext context) {
    var settings = CaptureSettings.instance;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Obx(() {
            var chosen = settings.videoStatsFields.isEmpty
                ? VideoStats.fieldIds.toSet()
                : settings.videoStatsFields.toSet();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var id in VideoStats.fieldIds)
                  CheckboxListTile(
                    title: Text(VideoStats.fieldLabel(id)),
                    value: chosen.contains(id),
                    onChanged: (on) {
                      var next = {...chosen};
                      if (on == true) {
                        next.add(id);
                      } else if (next.length > 1) {
                        // 至少留一行
                        next.remove(id);
                      }
                      settings.setVideoStatsFields(
                        next.length == VideoStats.fieldIds.length
                            ? const []
                            : VideoStats.fieldIds.where(next.contains),
                      );
                    },
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

/// 截图（和录屏）里包含什么：点开选（默认只有弹幕）。平台特有的放在“按平台”下面
class CaptureLayersSetting extends StatelessWidget {
  const CaptureLayersSetting({super.key});

  static String label(CaptureLayer layer) => switch (layer) {
        CaptureLayer.danmaku => "弹幕".t,
        CaptureLayer.sidePanel => "侧栏（聊天、公告）".t,
        CaptureLayer.videoStats => "视频信息".t,
        CaptureLayer.gifts => "礼物弹窗".t,
        CaptureLayer.superChat => "SC 卡片".t,
        CaptureLayer.linkMic => "连麦标签".t,
        CaptureLayer.voiceRoom => "语聊房画面".t,
        _ => "",
      };

  /// 只在部分平台出现的层：说明是哪些平台
  static String? platforms(CaptureLayer layer) => switch (layer) {
        CaptureLayer.superChat => "哔哩哔哩、YouTube 等".t,
        CaptureLayer.linkMic => "哔哩哔哩、斗鱼、虎牙、抖音、Twitch".t,
        CaptureLayer.voiceRoom => "哔哩哔哩".t,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    var settings = CaptureSettings.instance;
    return Obx(() {
      var chosen = settings.chosenLayers;
      // 只有画面录制会录进这些层（流录制、GIF 只有视频）
      var recording = CaptureFeatures.screenRecording;
      return SettingsAction(
        title: recording ? "截图和录屏包含".t : "截图包含".t,
        subtitle: recording ? "视频之外的内容，画面录制时没选的会暂时藏起来".t : "视频之外的内容".t,
        value: chosen.isEmpty
            ? "只有视频".t
            : [
                for (var layer in CaptureSettings.optionalLayers)
                  if (chosen.contains(layer)) label(layer),
              ].join("、".t),
        onTap: () => _open(context),
      );
    });
  }

  void _open(BuildContext context) {
    var settings = CaptureSettings.instance;
    Widget tile(CaptureLayer layer) => Obx(
          () => CheckboxListTile(
            dense: true,
            title: Text(label(layer)),
            subtitle: platforms(layer) == null ? null : Text(platforms(layer)!),
            value: settings.includes(layer),
            onChanged: (on) => settings.setLayer(layer, on == true),
          ),
        );
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var layer in const [
                CaptureLayer.danmaku,
                CaptureLayer.sidePanel,
                CaptureLayer.videoStats,
                CaptureLayer.gifts,
              ])
                tile(layer),
              Padding(
                padding: AppStyle.edgeInsetsH16.copyWith(top: 8, bottom: 4),
                child: Text(
                  "按平台".t,
                  style: Get.textTheme.titleSmall,
                ),
              ),
              for (var layer in const [
                CaptureLayer.superChat,
                CaptureLayer.linkMic,
                CaptureLayer.voiceRoom,
              ])
                tile(layer),
            ],
          ),
        ),
      ),
    );
  }
}
