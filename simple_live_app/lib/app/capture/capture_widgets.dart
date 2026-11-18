import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/capture/capture_controller.dart';
import 'package:simple_live_app/app/capture/capture_flow.dart';
import 'package:simple_live_app/app/capture/capture_scope.dart';
import 'package:simple_live_app/app/capture/capture_settings.dart';
import 'package:simple_live_app/app/capture/capture_storage.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 直播间用的截图和录屏：存、复制走各平台的做法，提示用 toast，问的时候弹窗
CaptureController createCaptureController(CaptureHost host) {
  return CaptureController(
    host: host,
    recordDir: CaptureFolders.recordDir,
    flow: CaptureFlow(
      sink: DefaultCaptureSink(),
      toast: (text) => SmartDialog.showToast(text),
      ask: showCaptureActions,
    ),
  );
}

/// 截图、录屏后问怎么处理：保存 / 复制到剪贴板 / 删除。关掉窗口时为 null
Future<CaptureChoice?> showCaptureActions(
  CaptureResult result,
  bool canCopy,
) {
  var png = result.png;
  var name = result.isVideo
      ? p.basename(result.videos.firstOrNull ?? result.baseName)
      : "${result.baseName}.png";
  var details = [
    if (result.duration > Duration.zero)
      "{s} 秒".tf({"s": result.duration.inSeconds}),
    if (result.bytes > 0) Utils.parseFileSize(result.bytes),
    if (result.files.length > 1) "共 {n} 个文件".tf({"n": result.files.length}),
  ].join(" · ");
  return Get.dialog<CaptureChoice>(
    AlertDialog(
      title: Text(result.isVideo ? "录屏完成".t : "截图".t),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (png != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ClipRRect(
                  borderRadius: AppStyle.radius4,
                  // 预览只解一张小图：原图最大四千万像素，整张解码要一百多 MB
                  child: Image.memory(png, fit: BoxFit.contain, cacheHeight: 520),
                ),
              )
            else
              const Icon(Icons.movie_outlined, size: 48),
            AppStyle.vGap8,
            Text(name, style: const TextStyle(fontSize: 13)),
            if (details.isNotEmpty)
              Text(
                details,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back(result: CaptureChoice.delete),
          child: Text("删除".t),
        ),
        if (canCopy)
          TextButton(
            onPressed: () => Get.back(result: CaptureChoice.copy),
            child: Text("复制到剪贴板".t),
          ),
        FilledButton(
          onPressed: () => Get.back(result: CaptureChoice.save),
          child: Text("保存".t),
        ),
      ],
    ),
  );
}

/// 页面顶栏左边：返回键（位置不变）+ 视频信息开关。
/// AppBar 的 leadingWidth 用 [widthOf]；页面不能返回（如多开窗口里）时只有开关
class CaptureLeading extends StatelessWidget {
  final CaptureController controller;
  const CaptureLeading({required this.controller, super.key});

  static bool _canPop(BuildContext context) =>
      ModalRoute.of(context)?.impliesAppBarDismissal ?? false;

  static double widthOf(BuildContext context) => _canPop(context) ? 104 : 56;

  @override
  Widget build(BuildContext context) {
    var toggle = VideoStatsToggleButton(controller: controller);
    if (!_canPop(context)) {
      return Center(child: toggle);
    }
    return Row(
      children: [
        const SizedBox(width: 56, child: Center(child: BackButton())),
        toggle,
      ],
    );
  }
}

/// 显示、隐藏左上角的视频信息
class VideoStatsToggleButton extends StatelessWidget {
  final CaptureController controller;
  final Color? color;
  const VideoStatsToggleButton({
    required this.controller,
    this.color,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      var shown = AppSettingsController.instance.playerVideoStats.value;
      return IconButton(
        tooltip: shown ? "隐藏视频信息".t : "显示视频信息".t,
        onPressed: controller.toggleVideoStats,
        icon: Icon(
          shown ? Icons.info : Icons.info_outline,
          color: color,
        ),
      );
    });
  }
}

/// 截图键
class CaptureScreenshotButton extends StatelessWidget {
  final CaptureController controller;
  final Color? color;
  const CaptureScreenshotButton({
    required this.controller,
    this.color,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return CaptureButtonVisibility(
      scope: controller.scope,
      child: IconButton(
        tooltip: "截图".t,
        onPressed: controller.screenshot,
        icon: Icon(Icons.camera_alt_outlined, color: color),
      ),
    );
  }
}

/// 录屏键：点一下开始，再点一下停止；录着时是红点和已录的时间。
/// 没开录屏（[CaptureFeatures.recording]）时什么都不显示
class CaptureRecordButton extends StatelessWidget {
  final CaptureController controller;
  final Color? color;
  const CaptureRecordButton({
    required this.controller,
    this.color,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (!CaptureFeatures.recording) {
      return const SizedBox.shrink();
    }
    return CaptureButtonVisibility(
      scope: controller.scope,
      child: Obx(() {
        var busy = controller.busy.value;
        if (!controller.recording.value) {
          var limit = CaptureSettings.instance.maxDuration.inSeconds;
          return IconButton(
            tooltip: "录屏（最长 {t}）".tf({"t": recordLimitText(limit)}),
            onPressed: busy ? null : controller.toggleRecording,
            icon: Icon(Icons.videocam_outlined, color: color),
          );
        }
        return TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: color,
            visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(
              fontSize: 13,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          onPressed: busy ? null : controller.toggleRecording,
          icon: const Icon(Icons.fiber_manual_record,
              color: Colors.red, size: 14),
          label: Tooltip(
            message: "停止录屏".t,
            child: Text(controller.elapsedText),
          ),
        );
      }),
    );
  }
}

/// 全屏时右边的截图、录屏键：截图在锁形键上面，录屏在下面，中间空出锁形键的位置。
/// 没开录屏时下面留空（截图键还在锁形键上面）。
/// [shown] 是控制栏显示着；设置里开了“全屏时一直显示截图键”时控制栏收起后也在，
/// 小一点、半透明
class FullscreenCaptureButtons extends StatelessWidget {
  final CaptureController controller;
  final bool shown;
  final double right;

  /// 锁形键的高度（中间空出来的）
  final double lockSize;

  const FullscreenCaptureButtons({
    required this.controller,
    required this.shown,
    required this.right,
    this.lockSize = 40,
    super.key,
  });

  /// 控制栏收起时这两个键还在不在
  static bool visible({required bool shown}) =>
      shown || CaptureSettings.instance.fullscreenButtons.value;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      var always = CaptureSettings.instance.fullscreenButtons.value;
      var show = shown || always;
      var small = !shown;
      var size = small ? 32.0 : 40.0;
      return AnimatedPositioned(
        duration: const Duration(milliseconds: 200),
        top: 0,
        bottom: 0,
        right: show ? right + (40 - size) / 2 : -(64 + right),
        child: Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: small ? 0.5 : 1,
            child: CaptureButtonVisibility(
              scope: controller.scope,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _square(
                    size: size,
                    tooltip: "截图".t,
                    onTap: controller.screenshot,
                    child: Icon(Icons.camera_alt_outlined,
                        color: Colors.white, size: size / 2),
                  ),
                  SizedBox(height: lockSize + 24),
                  if (!CaptureFeatures.recording)
                    SizedBox.square(dimension: size)
                  else
                    Obx(() {
                      var recording = controller.recording.value;
                      return _square(
                        size: size,
                        tooltip: recording ? "停止录屏".t : "录屏".t,
                        onTap: controller.busy.value
                            ? null
                            : controller.toggleRecording,
                        child: recording
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.fiber_manual_record,
                                      color: Colors.red, size: 12),
                                  FittedBox(
                                    child: Text(
                                      controller.elapsedText,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : Icon(Icons.videocam_outlined,
                                color: Colors.white, size: size / 2),
                      );
                    }),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _square({
    required double size,
    required String tooltip,
    required VoidCallback? onTap,
    required Widget child,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppStyle.radius8,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.black45,
            borderRadius: AppStyle.radius8,
          ),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}

/// 最长录制时间的写法：30 秒、1 分钟、2 分钟
String recordLimitText(int seconds) => seconds % 60 == 0
    ? "{m} 分钟".tf({"m": seconds ~/ 60})
    : "{s} 秒".tf({"s": seconds});

/// 画面录制每分钟大约多少 MB：按录的大小（物理像素）和帧率粗算，H.264 每像素约 0.07 bit
int estimateScreenRecordMbPerMinute(Size physical, int fps) {
  var bitsPerSecond = physical.width * physical.height * fps * 0.07;
  return math.max(1, (bitsPerSecond * 60 / 8 / 1000000).round());
}

/// 最长录制时间选了 5 分钟以上（或不限）时先说明一下，确定了才改
Future<bool> confirmLongRecording(int minutes) async {
  var view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
  var size = view?.physicalSize ?? const Size(1920, 1080);
  var mobile = Platform.isAndroid || Platform.isIOS;
  var mb = estimateScreenRecordMbPerMinute(size, mobile ? 30 : 60);
  var lines = [
    "录得越久，文件越大：画面录制按现在的窗口大小每分钟约 {mb} MB；流录制跟着直播的码率走，每分钟约 1–8 MB。"
        .tf({"mb": mb}),
    "录的时候一直占用磁盘、CPU 和电量，设备可能会发热。".t,
    if (mobile) "手机上切到后台后，系统可能会停掉时间长的录屏。".t,
    if (minutes == 0) "不限时只有按停止时才停，最多录 4 小时。".t,
  ];
  return Utils.showAlertDialog(
    lines.join("\n\n"),
    title: minutes == 0 ? "最长录制时间：不限".t : "最长录制时间：{m} 分钟".tf({"m": minutes}),
  );
}
