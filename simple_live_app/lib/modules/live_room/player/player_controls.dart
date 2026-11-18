import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/capture/capture_scope.dart';
import 'package:simple_live_app/app/capture/capture_settings.dart';
import 'package:simple_live_app/app/capture/capture_widgets.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/rank/live_rank_entry.dart';
import 'package:simple_live_app/modules/live_room/live_room_playback.dart';
import 'package:simple_live_app/modules/live_room/player/player_notice_overlay.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/live_notify_service.dart';
import 'package:simple_live_app/widgets/follow_actions_sheet.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/external_display_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/video_stats_overlay.dart';
import 'package:window_manager/window_manager.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/modules/live_room/player/voice_room_view.dart';

Widget playerControls(
  VideoState videoState,
  LiveRoomController controller,
) {
  // 截图和录屏量播放器的位置用（控制层铺满整个播放器）
  return CaptureLayerBox(
    scope: controller.capture.scope,
    layer: CaptureLayer.player,
    child: Obx(() {
      if (controller.fullScreenState.value) {
        return buildFullControls(
          videoState,
          controller,
        );
      }
      return buildControls(
        videoState.context.orientation == Orientation.portrait,
        videoState,
        controller,
      );
    }),
  );
}

/// 双击：落在视频信息浮层上时只隐藏浮层，别处照常（全屏/退出全屏）
void _onDoubleTapDown(LiveRoomController controller, TapDownDetails details) {
  if (controller.capture.hideVideoStatsAt(details.globalPosition)) {
    return;
  }
  controller.onDoubleTap(details);
}

Widget buildFullControls(
  VideoState videoState,
  LiveRoomController controller,
) {
  var padding = MediaQuery.of(videoState.context).padding;
  GlobalKey volumeButtonkey = GlobalKey();
  return DragToMoveArea(
    child: Stack(
      children: [
        Container(),
        // 语聊房：自己画的房主和麦位盖住低清的合成画面，弹幕在它上面
        VoiceRoomLayer(controller: controller),
        buildDanmuView(videoState, controller),
        buildVideoStats(controller, padding, fullScreen: true),

        Center(
          child: // 中间
              StreamBuilder(
            stream: videoState.widget.controller.player.stream.buffering,
            initialData: videoState.widget.controller.player.state.buffering,
            builder: (_, s) => Visibility(
              visible: s.data ?? false,
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: GestureDetector(
            onTap: controller.onTap,
            onDoubleTapDown: (d) => _onDoubleTapDown(controller, d),
            onLongPress: () {
              if (controller.lockControlsState.value) {
                return;
              }
              showFollowUser(controller);
            },
            onVerticalDragStart: (details) => controller.onVerticalDragStart(
              details,
              area: videoState.context.size,
            ),
            onVerticalDragUpdate: controller.onVerticalDragUpdate,
            onVerticalDragEnd: controller.onVerticalDragEnd,
            child: MouseRegion(
              onHover: (PointerHoverEvent event) {
                controller.onHover(event, videoState.context);
              },
              child: Container(
                width: double.infinity,
                height: double.infinity,
                color: Colors.transparent,
                // child: Visibility(
                //   //拖拽区域
                //   visible: controller.smallWindowState.value,
                //   child: DragToMoveArea(
                //       child: Container(
                //     width: double.infinity,
                //     height: double.infinity,
                //     color: Colors.transparent,
                //   )),
                // ),
              ),
            ),
          ),
        ),

        // 左下角连麦标签、SC 和礼物（共用位置和队列）。放在手势层上面，连麦标签才点得到；
        // 底部栏出来时跟着让到它上面，不挡按钮
        Obx(
          () => Visibility(
            visible: showPlayerNotices(controller),
            child: AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              left: 24,
              bottom: (controller.showControlsState.value &&
                      !controller.lockControlsState.value)
                  ? 80 + padding.bottom + 8
                  : 24,
              child: PlayerNoticeOverlay(controller: controller),
            ),
          ),
        ),

        // 顶部
        Obx(
          () => AnimatedPositioned(
            left: 0,
            right: 0,
            top: (controller.showControlsState.value &&
                    !controller.lockControlsState.value)
                ? 0
                : -(48 + padding.top),
            duration: const Duration(milliseconds: 200),
            child: Container(
              height: 48 + padding.top,
              padding: EdgeInsets.only(
                left: padding.left + 12,
                right: padding.right + 12,
                top: padding.top,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black87,
                  ],
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () {
                      if (controller.smallWindowState.value) {
                        controller.exitSmallWindow();
                      } else {
                        controller.exitFull();
                      }
                    },
                    icon: const Icon(
                      Icons.arrow_back,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  // 返回键右边：显示、隐藏视频信息
                  VideoStatsToggleButton(
                    controller: controller.capture,
                    color: Colors.white,
                  ),
                  AppStyle.hGap4,
                  Expanded(
                    child: Text(
                      "${controller.detail.value?.title} - ${controller.detail.value?.userName}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                  AppStyle.hGap12,
                  // 截图键不进画面录制
                  CaptureButtonVisibility(
                    scope: controller.capture.scope,
                    child: IconButton(
                      onPressed: () {
                        controller.saveScreenshot();
                      },
                      icon: const Icon(
                        Icons.camera_alt_outlined,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                  // 榜单（设置里关掉“显示榜单”时没有）
                  if (controller.showRank)
                    IconButton(
                      tooltip: "榜单".t,
                      onPressed: () => showLiveRank(controller),
                      icon: const Icon(
                        Remix.trophy_line,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  IconButton(
                    onPressed: () {
                      showFollowUser(controller);
                    },
                    icon: const Icon(
                      Remix.play_list_2_line,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  Visibility(
                    visible: Platform.isAndroid || Platform.isIOS,
                    child: IconButton(
                      onPressed: () {
                        controller.enablePIP();
                      },
                      icon: const Icon(
                        Icons.picture_in_picture,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      showPlayerSettings(controller);
                    },
                    icon: const Icon(
                      Icons.more_horiz,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // 底部
        Obx(
          () => AnimatedPositioned(
            left: 0,
            right: 0,
            bottom: (controller.showControlsState.value &&
                    !controller.lockControlsState.value)
                ? 0
                : -(80 + padding.bottom),
            duration: const Duration(milliseconds: 200),
            child: buildFullBottomBar(controller, padding, volumeButtonkey),
          ),
        ),

        // 右侧锁定
        Obx(
          () => AnimatedPositioned(
            top: 0,
            bottom: 0,
            right: controller.showControlsState.value
                ? padding.right + 12
                : -(64 + padding.right),
            duration: const Duration(milliseconds: 200),
            child: buildLockButton(controller),
          ),
        ),
        // 右边锁形键上下：截图、录屏（设置里可以让它们一直显示）
        Obx(
          () => FullscreenCaptureButtons(
            controller: controller.capture,
            shown: controller.showControlsState.value &&
                !controller.lockControlsState.value,
            right: padding.right + 12,
          ),
        ),
        // 左侧锁定
        Obx(
          () => AnimatedPositioned(
            top: 0,
            bottom: 0,
            left: controller.showControlsState.value
                ? padding.left + 12
                : -(64 + padding.right),
            duration: const Duration(milliseconds: 200),
            child: buildLockButton(controller),
          ),
        ),
        Obx(
          () => Offstage(
            offstage: !controller.showGestureTip.value,
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade900,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  controller.gestureTipText.value,
                  style: const TextStyle(fontSize: 18, color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// 正在记录弹幕（ASS）时，控制栏里开播时长后面的红点和时长
Widget buildAssRecordIndicator(LiveRoomController controller) {
  return Obx(
    () => controller.assRecording.value
        ? Padding(
            padding: const EdgeInsets.only(left: 8.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.fiber_manual_record,
                  color: Colors.red,
                  size: 12,
                ),
                const SizedBox(width: 2),
                Text(
                  "记录弹幕 {assRecordTime}".tf({"assRecordTime": controller.assRecordTime.value}),
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ],
            ),
          )
        : const SizedBox.shrink(),
  );
}

Widget buildLockButton(LiveRoomController controller) {
  return Center(
    child: InkWell(
      onTap: () {
        controller.setLockState();
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black45,
          borderRadius: AppStyle.radius8,
        ),
        width: 40,
        height: 40,
        child: Center(
          child: Icon(
            controller.lockControlsState.value
                ? Icons.lock_outline_rounded
                : Icons.lock_open_outlined,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    ),
  );
}

Widget buildControls(
  bool isPortrait,
  VideoState videoState,
  LiveRoomController controller,
) {
  GlobalKey volumeButtonkey = GlobalKey();
  var padding = MediaQuery.of(videoState.context).padding;
  return Stack(
    children: [
      Container(),
      VoiceRoomLayer(controller: controller),
      buildDanmuView(videoState, controller),
      buildVideoStats(controller, padding, fullScreen: false),

      // 中间
      Center(
        child: StreamBuilder(
          stream: videoState.widget.controller.player.stream.buffering,
          initialData: videoState.widget.controller.player.state.buffering,
          builder: (_, s) => Visibility(
            visible: s.data ?? false,
            child: const Center(
              child: CircularProgressIndicator(),
            ),
          ),
        ),
      ),
      Positioned.fill(
        child: GestureDetector(
          onTap: controller.onTap,
          onDoubleTapDown: (d) => _onDoubleTapDown(controller, d),
          onVerticalDragStart: (details) => controller.onVerticalDragStart(
            details,
            area: videoState.context.size,
          ),
          onVerticalDragUpdate: controller.onVerticalDragUpdate,
          onVerticalDragEnd: controller.onVerticalDragEnd,
          //onLongPress: controller.showDebugInfo,
          child: MouseRegion(
            onEnter: controller.onEnter,
            child: Container(
              width: double.infinity,
              height: double.infinity,
              color: Colors.transparent,
            ),
          ),
        ),
      ),
      // 左下角连麦标签、SC 和礼物（共用位置和队列）。放在手势层上面，连麦标签才点得到；
      // 底部栏出来时跟着让到它上面，不挡按钮
      Obx(
        () => Visibility(
          visible: showPlayerNotices(controller),
          child: AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            left: 24,
            bottom: controller.showControlsState.value ? 48 + 8 : 24,
            child: PlayerNoticeOverlay(controller: controller),
          ),
        ),
      ),
      Obx(
        () => AnimatedPositioned(
          left: 0,
          right: 0,
          bottom: controller.showControlsState.value ? 0 : -48,
          duration: const Duration(milliseconds: 200),
          child: buildBottomBar(controller, isPortrait, volumeButtonkey),
        ),
      ),
      Obx(
        () => Offstage(
          offstage: !controller.showGestureTip.value,
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade900,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                controller.gestureTipText.value,
                style: const TextStyle(fontSize: 18, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

/// 控制栏一行：左边一组占剩下的宽度，放不下时横着滑；右边一组按自己的宽度，太宽时也横着滑，
/// 左边至少留出暂停和刷新两个按钮；最后一个按钮（全屏、退出全屏）一直露着。
/// 电脑小窗、窄屏、字放大时都不溢出
Widget buildBarRow({
  required List<Widget> start,
  required List<Widget> end,
  required Widget last,
}) {
  return LayoutBuilder(
    builder: (context, constraints) {
      var endMax = max(0.0, constraints.maxWidth - 48 - 96);
      return Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(mainAxisSize: MainAxisSize.min, children: start),
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: endMax),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(mainAxisSize: MainAxisSize.min, children: end),
            ),
          ),
          last,
        ],
      );
    },
  );
}

/// 全屏和电脑小窗的底栏
Widget buildFullBottomBar(
  LiveRoomController controller,
  EdgeInsets padding,
  GlobalKey volumeButtonkey,
) {
  return Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.black87,
        ],
      ),
    ),
    padding: EdgeInsets.only(
      left: padding.left + 12,
      right: padding.right + 12,
      bottom: padding.bottom,
    ),
    child: buildBarRow(
      start: [
        LivePauseButton(controller: controller),
        IconButton(
          onPressed: () {
            controller.refreshRoom();
          },
          icon: const Icon(
            Remix.refresh_line,
            color: Colors.white,
          ),
        ),
        VoiceViewButton(controller: controller),
        Offstage(
          offstage: controller.showDanmakuState.value,
          child: IconButton(
            onPressed: () => controller.showDanmakuState.value =
                !controller.showDanmakuState.value,
            icon: const ImageIcon(
              AssetImage('assets/icons/icon_danmaku_open.png'),
              size: 24,
              color: Colors.white,
            ),
          ),
        ),
        Offstage(
          offstage: !controller.showDanmakuState.value,
          child: IconButton(
            onPressed: () => controller.showDanmakuState.value =
                !controller.showDanmakuState.value,
            icon: const ImageIcon(
              AssetImage('assets/icons/icon_danmaku_close.png'),
              size: 24,
              color: Colors.white,
            ),
          ),
        ),
        IconButton(
          onPressed: () {
            showDanmakuSettings(controller);
          },
          icon: const ImageIcon(
            AssetImage('assets/icons/icon_danmaku_setting.png'),
            size: 24,
            color: Colors.white,
          ),
        ),
        Obx(
          () => Padding(
            padding: const EdgeInsets.only(left: 8.0),
            child: Text(
              controller.playbackRate.value > 1.0
                  ? "${controller.liveDuration.value}  ${controller.playbackRate.value.toStringAsFixed(2)}x"
                  : controller.liveDuration.value,
              style: const TextStyle(fontSize: 14, color: Colors.white),
            ),
          ),
        ),
        buildAssRecordIndicator(controller),
      ],
      end: [
        Visibility(
          visible: !Platform.isAndroid && !Platform.isIOS,
          child: IconButton(
            key: volumeButtonkey,
            onPressed: () {
              controller.showVolumeSlider(volumeButtonkey.currentContext!);
            },
            // 静音时（多开窗口默认静音）图标换成静音的
            icon: Obx(
              () => Icon(
                controller.muted.value ? Icons.volume_off : Icons.volume_down,
                size: 24,
                color: Colors.white,
              ),
            ),
          ),
        ),
        TextButton(
          onPressed: () {
            showQualitesInfo(controller);
          },
          child: Obx(
            () => Text(
              controller.currentQualityInfo.value.t,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ),
        TextButton(
          onPressed: () {
            showLinesInfo(controller);
          },
          child: Text(
            controller.currentLineInfo.value,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ],
      last: IconButton(
        onPressed: () {
          if (controller.smallWindowState.value) {
            controller.exitSmallWindow();
          } else {
            controller.exitFull();
          }
        },
        icon: const Icon(
          Remix.fullscreen_exit_fill,
          color: Colors.white,
        ),
      ),
    ),
  );
}

/// 不全屏时的底栏。竖屏时不显示清晰度和线路
Widget buildBottomBar(
  LiveRoomController controller,
  bool isPortrait,
  GlobalKey volumeButtonkey,
) {
  return Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.black87,
        ],
      ),
    ),
    child: buildBarRow(
      start: [
        LivePauseButton(controller: controller),
        IconButton(
          onPressed: () {
            controller.refreshRoom();
          },
          icon: const Icon(
            Remix.refresh_line,
            color: Colors.white,
          ),
        ),
        VoiceViewButton(controller: controller),
        Offstage(
          offstage: controller.showDanmakuState.value,
          child: IconButton(
            onPressed: () => controller.showDanmakuState.value =
                !controller.showDanmakuState.value,
            icon: const ImageIcon(
              AssetImage('assets/icons/icon_danmaku_open.png'),
              size: 24,
              color: Colors.white,
            ),
          ),
        ),
        Offstage(
          offstage: !controller.showDanmakuState.value,
          child: IconButton(
            onPressed: () => controller.showDanmakuState.value =
                !controller.showDanmakuState.value,
            icon: const ImageIcon(
              AssetImage('assets/icons/icon_danmaku_close.png'),
              size: 24,
              color: Colors.white,
            ),
          ),
        ),
        IconButton(
          onPressed: () {
            controller.showDanmuSettingsSheet();
          },
          icon: const ImageIcon(
            AssetImage('assets/icons/icon_danmaku_setting.png'),
            size: 24,
            color: Colors.white,
          ),
        ),
        Obx(
          () => Padding(
            padding: const EdgeInsets.only(left: 8.0),
            child: Text(
              controller.playbackRate.value > 1.0
                  ? "${controller.liveDuration.value}  ${controller.playbackRate.value.toStringAsFixed(2)}x"
                  : controller.liveDuration.value,
              style: const TextStyle(fontSize: 14, color: Colors.white),
            ),
          ),
        ),
        buildAssRecordIndicator(controller),
      ],
      end: [
        Visibility(
          visible: !Platform.isAndroid && !Platform.isIOS,
          child: IconButton(
            key: volumeButtonkey,
            onPressed: () {
              controller.showVolumeSlider(
                volumeButtonkey.currentContext!,
              );
            },
            // 静音时（多开窗口默认静音）图标换成静音的
            icon: Obx(
              () => Icon(
                controller.muted.value ? Icons.volume_off : Icons.volume_down,
                size: 24,
                color: Colors.white,
              ),
            ),
          ),
        ),
        Offstage(
          offstage: isPortrait,
          child: TextButton(
            onPressed: () {
              controller.showQualitySheet();
            },
            child: Obx(
              () => Text(
                controller.currentQualityInfo.value.t,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
          ),
        ),
        Offstage(
          offstage: isPortrait,
          child: TextButton(
            onPressed: () {
              controller.showPlayUrlsSheet();
            },
            child: Text(
              controller.currentLineInfo.value,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ),
        Visibility(
          visible: !Platform.isAndroid && !Platform.isIOS,
          child: IconButton(
            onPressed: () {
              controller.enterSmallWindow();
            },
            icon: const Icon(
              Icons.picture_in_picture,
              color: Colors.white,
              size: 24,
            ),
          ),
        ),
        // iOS 投屏时切换电视聊天栏
        const ExternalDisplayButton(),
        // iOS 画中画
        Visibility(
          visible: Platform.isIOS,
          child: IconButton(
            onPressed: () {
              controller.enablePIP();
            },
            icon: const Icon(
              Icons.picture_in_picture_alt,
              color: Colors.white,
              size: 24,
            ),
          ),
        ),
      ],
      last: IconButton(
        onPressed: () {
          controller.enterFullScreen();
        },
        icon: const Icon(
          Remix.fullscreen_line,
          color: Colors.white,
        ),
      ),
    ),
  );
}

/// 左上角的视频信息（设置里打开），不拦截手势。全屏时顶部栏显示期间移到栏下面，
/// 不被标题栏遮住；非全屏没有顶部栏
Widget buildVideoStats(
  LiveRoomController controller,
  EdgeInsets padding, {
  required bool fullScreen,
}) {
  return Obx(() {
    var barShown = controller.showControlsState.value &&
        !controller.lockControlsState.value;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      left: padding.left + 8,
      top: fullScreen && barShown ? padding.top + 48 + 4 : padding.top + 8,
      child: CaptureLayerBox(
        scope: controller.capture.scope,
        layer: CaptureLayer.videoStats,
        child: VideoStatsOverlay(player: controller.player),
      ),
    );
  });
}

Widget buildDanmuView(VideoState videoState, LiveRoomController controller) {
  // 全屏时避开刘海和底部横条；不全屏时播放器不贴屏幕边（竖屏在标题栏下面），
  // 再让出底部横条的高度只会让本来就矮的弹幕区更矮
  var padding = controller.fullScreenState.value
      ? MediaQuery.of(videoState.context).padding
      : EdgeInsets.zero;
  controller.danmakuView ??= DanmakuScreen(
    key: controller.globalDanmuKey,
    createdController: controller.initDanmakuController,
    option: DanmakuOption(
      fontSize: AppSettingsController.instance
          .danmuSizeFor(controller.danmakuViewMode),
      area: AppSettingsController.instance.danmuArea.value,
      duration: AppSettingsController.instance
          .danmuSpeedFor(controller.danmakuViewMode),
      emoteScale: AppSettingsController.instance.effectiveEmoteScale,
      opacity: AppSettingsController.instance.danmuOpacity.value,
      //strokeWidth: AppSettingsController.instance.danmuStrokeWidth.value,
      fontWeight: AppSettingsController.instance.danmuFontWeight.value,
    ),
  );
  return Positioned.fill(
    top: padding.top,
    bottom: padding.bottom,
    child: CaptureLayerBox(
      scope: controller.capture.scope,
      layer: CaptureLayer.danmaku,
      child: Obx(
        () => Offstage(
          offstage: !controller.showDanmakuState.value,
          child: Padding(
            padding: controller.fullScreenState.value
                ? EdgeInsets.only(
                    top: AppSettingsController.instance.danmuTopMargin.value,
                    bottom:
                        AppSettingsController.instance.danmuBottomMargin.value,
                  )
                : EdgeInsets.zero,
            child: controller.danmakuView!,
          ),
        ),
      ),
    ),
  );
}

void showLinesInfo(LiveRoomController controller) {
  if (controller.isVertical.value) {
    controller.showPlayUrlsSheet();
    return;
  }
  Utils.showRightDialog(
    title: "线路".t,
    useSystem: true,
    child: ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: controller.playUrls.length,
      itemBuilder: (_, i) {
        return ListTile(
          selected: controller.currentLineIndex == i,
          title: Text.rich(
            TextSpan(
              text: "线路{p}".tf({"p": i + 1}),
              children: [
                WidgetSpan(
                    child: Container(
                  decoration: BoxDecoration(
                    borderRadius: AppStyle.radius4,
                    border: Border.all(
                      color: Colors.grey,
                    ),
                  ),
                  padding: AppStyle.edgeInsetsH4,
                  margin: AppStyle.edgeInsetsL8,
                  child: Text(
                    controller.playUrls[i].contains(".flv") ? "FLV" : "HLS",
                    style: const TextStyle(
                      fontSize: 12,
                    ),
                  ),
                )),
              ],
            ),
            style: const TextStyle(fontSize: 14),
          ),
          minLeadingWidth: 16,
          onTap: () {
            Utils.hideRightDialog();
            //controller.currentLineIndex = i;
            //controller.setPlayer();
            controller.changePlayLine(i);
          },
        );
      },
    ),
  );
}

void showQualitesInfo(LiveRoomController controller) {
  if (controller.isVertical.value) {
    controller.showQualitySheet();
    return;
  }
  Utils.showRightDialog(
    title: "清晰度".t,
    useSystem: true,
    child: ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: controller.qualites.length,
      itemBuilder: (_, i) {
        var item = controller.qualites[i];
        return ListTile(
          selected: controller.currentQuality == i,
          title: Text(
            item.quality.t,
            style: const TextStyle(fontSize: 14),
          ),
          minLeadingWidth: 16,
          onTap: () {
            Utils.hideRightDialog();
            controller.switchQualityManually(i);
          },
        );
      },
    ),
  );
}

void showDanmakuSettings(LiveRoomController controller) {
  if (controller.isVertical.value) {
    controller.showDanmuSettingsSheet();
    return;
  }
  Utils.showRightDialog(
    title: "弹幕设置".t,
    width: 400,
    useSystem: true,
    child: ListView(
      padding: AppStyle.edgeInsetsA12,
      children: [
        DanmuSettingsView(
          danmakuController: controller.danmakuController,
        ),
      ],
    ),
  );
}

/// 全屏时右上角“更多”：视频信息开关、画面尺寸；竖屏直播间用底部弹窗
void showPlayerSettings(LiveRoomController controller) {
  if (controller.isVertical.value) {
    Utils.showBottomSheet(
      title: "设置".t,
      child: _buildPlayerSettings(controller),
    );
    return;
  }
  Utils.showRightDialog(
    title: "设置".t,
    width: 320,
    useSystem: true,
    child: _buildPlayerSettings(controller),
  );
}

Widget _buildPlayerSettings(LiveRoomController controller) {
  var settings = AppSettingsController.instance;
  return Obx(
    () => RadioGroup(
      groupValue: settings.scaleMode.value,
      onChanged: (e) {
        settings.setScaleMode(e ?? 0);
        controller.updateScaleMode();
      },
      child: ListView(
        padding: AppStyle.edgeInsetsV12,
        children: [
          SwitchListTile(
            contentPadding: AppStyle.edgeInsetsH16,
            title: Text("显示视频信息（帧率、码率等）".t),
            value: settings.playerVideoStats.value,
            onChanged: settings.setPlayerVideoStats,
          ),
          AppStyle.vGap8,
          Padding(
            padding: AppStyle.edgeInsetsH16,
            child: Text(
              "画面尺寸".t,
              style: Get.textTheme.titleMedium,
            ),
          ),
          RadioListTile(
            value: 0,
            contentPadding: AppStyle.edgeInsetsH4,
            title: Text("适应".t),
            visualDensity: VisualDensity.compact,
          ),
          RadioListTile(
            value: 1,
            contentPadding: AppStyle.edgeInsetsH4,
            title: Text("拉伸".t),
            visualDensity: VisualDensity.compact,
          ),
          RadioListTile(
            value: 2,
            contentPadding: AppStyle.edgeInsetsH4,
            title: Text("铺满".t),
            visualDensity: VisualDensity.compact,
          ),
          const RadioListTile(
            value: 3,
            contentPadding: AppStyle.edgeInsetsH4,
            title: Text("16:9"),
            visualDensity: VisualDensity.compact,
          ),
          const RadioListTile(
            value: 4,
            contentPadding: AppStyle.edgeInsetsH4,
            title: Text("4:3"),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    ),
  );
}

/// 全屏时打开榜单：竖屏从下面弹出，横屏从右边滑出（和关注列表一样）
void showLiveRank(LiveRoomController controller) {
  var panel = buildRankPanel(controller);
  if (controller.isVertical.value) {
    Utils.showBottomSheet(title: "榜单".t, child: panel);
    return;
  }
  Utils.showRightDialog(
    title: "榜单".t,
    width: 400,
    useSystem: true,
    child: panel,
  );
}

void showFollowUser(LiveRoomController controller) {
  if (controller.isVertical.value) {
    controller.showFollowUserSheet();
    return;
  }

  // 打开关注列表时查一遍开播状态（看直播时定时刷新会推迟）
  controller.onFollowListShown();
  Utils.showRightDialog(
    title: "关注列表".t,
    width: 400,
    useSystem: true,
    child: Obx(
      () => Stack(
        children: [
          RefreshIndicator(
            onRefresh: FollowService.instance.loadData,
            child: ListView.builder(
              itemCount: FollowService.instance.liveList.length,
              itemBuilder: (_, i) {
                var item = FollowService.instance.liveList[i];
                return Obx(
                  () => FollowUserItem(
                    item: item,
                    playing: controller.rxSite.value.id == item.siteId &&
                        controller.rxRoomId.value == item.roomId,
                    onTap: () {
                      Utils.hideRightDialog();
                      controller.resetRoomOf(item.siteId, item.roomId);
                    },
                    onToggleNotify: () =>
                        LiveNotifyService.instance.toggleSubscription(item),
                    onLongPress: () => showFollowActions(
                      item,
                      onUnfollow: () => controller.unfollowFromList(item),
                    ),
                  ),
                );
              },
            ),
          ),
          if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
            Positioned(
              right: 12,
              bottom: 12,
              child: Obx(
                () => DesktopRefreshButton(
                  refreshing: FollowService.instance.updating.value,
                  onPressed: FollowService.instance.loadData,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// 视频左下角显示 SC 和礼物：电脑上一直显示，手机、平板只在全屏时显示
bool showPlayerNotices(LiveRoomController controller) {
  var settings = AppSettingsController.instance;
  return (settings.playershowSuperChat.value ||
          settings.danmuGiftFly.value ||
          controller.linkMicShown) &&
      ((!Platform.isAndroid && !Platform.isIOS) ||
          controller.fullScreenState.value);
}
