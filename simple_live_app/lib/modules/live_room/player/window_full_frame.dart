import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/window_pin.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:window_manager/window_manager.dart';

/// 全屏、电脑小窗、窗口全屏时的播放器外框。窗口全屏时在画面最上面加一条透明的标题栏，
/// 并把它的高度算进顶部边距，全屏控制栏、视频信息和弹幕都从它下面开始
class WindowFullFrame extends StatelessWidget {
  final LiveRoomController controller;
  final Widget child;
  const WindowFullFrame({
    required this.controller,
    required this.child,
    super.key,
  });

  /// 标题栏的高度（和 Windows 的标题栏按钮一样高）
  static const double height = 32;

  @override
  Widget build(BuildContext context) {
    var media = MediaQuery.of(context);
    return Obx(() {
      var on = controller.windowFullState.value &&
          !controller.smallWindowState.value;
      // 播放器一直是第一个子组件，进出窗口全屏时不会重建
      return Stack(
        children: [
          Positioned.fill(
            child: MediaQuery(
              data: on
                  ? media.copyWith(
                      padding: media.padding
                          .copyWith(top: media.padding.top + height),
                    )
                  : media,
              child: child,
            ),
          ),
          if (on)
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              height: height,
              child: WindowFullCaption(controller: controller),
            ),
        ],
      );
    });
  }
}

/// 窗口全屏时的标题栏：没有底色，拖动移动窗口，双击最大化或还原。
/// 右边的置顶、最小化、最大化、关闭跟着控制栏出现和隐藏，鼠标移到这一条上时也会出现。
/// macOS 用系统自己的红绿灯，这里只有置顶
class WindowFullCaption extends StatefulWidget {
  final LiveRoomController controller;
  const WindowFullCaption({required this.controller, super.key});

  @override
  State<WindowFullCaption> createState() => _WindowFullCaptionState();
}

class _WindowFullCaptionState extends State<WindowFullCaption>
    with WindowListener {
  bool maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _readMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _readMaximized() async {
    try {
      var value = await windowManager.isMaximized();
      if (mounted) setState(() => maximized = value);
    } catch (_) {
      // 测试里没有窗口插件
    }
  }

  @override
  void onWindowMaximize() => _readMaximized();

  @override
  void onWindowUnmaximize() => _readMaximized();

  @override
  Widget build(BuildContext context) {
    var c = widget.controller;
    var buttons = <Widget>[
      _PinCaptionButton(),
      if (!Platform.isMacOS) ...[
        WindowCaptionButton.minimize(
          brightness: Brightness.dark,
          onPressed: windowManager.minimize,
        ),
        maximized
            ? WindowCaptionButton.unmaximize(
                brightness: Brightness.dark,
                onPressed: windowManager.unmaximize,
              )
            : WindowCaptionButton.maximize(
                brightness: Brightness.dark,
                onPressed: windowManager.maximize,
              ),
        WindowCaptionButton.close(
          brightness: Brightness.dark,
          onPressed: windowManager.close,
        ),
      ],
    ];
    return MouseRegion(
      // 鼠标在这一条上动时把控制栏和这些按键叫出来（并重新计时）
      onHover: (_) => c.showControls(),
      child: Row(
        children: [
          const Expanded(
            child: DragToMoveArea(child: SizedBox.expand()),
          ),
          Obx(() {
            var shown = c.showControlsState.value;
            return IgnorePointer(
              ignoring: !shown,
              child: AnimatedOpacity(
                opacity: shown ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: DecoratedBox(
                  // 淡淡的一层底，亮的画面上也看得清白色按键
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black38, Colors.transparent],
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: buttons,
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

/// 标题栏上的图钉，和直播间顶栏的图钉是同一个状态
class _PinCaptionButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Obx(() {
      var pinned = WindowPin.instance.pinned.value;
      return Tooltip(
        message: pinned ? "取消置顶".t : "窗口置顶".t,
        child: InkWell(
          onTap: WindowPin.instance.toggle,
          child: SizedBox(
            width: 46,
            height: WindowFullFrame.height,
            child: Icon(
              pinned ? Icons.push_pin : Icons.push_pin_outlined,
              size: 16,
              color: Colors.white,
            ),
          ),
        ),
      );
    });
  }
}

/// 底栏的窗口全屏键（电脑），在小窗键右边、全屏键左边。
/// 点一下画面占满当前窗口，再点一下回来；系统全屏时点它换成窗口全屏
class WindowFullButton extends StatelessWidget {
  final LiveRoomController controller;
  const WindowFullButton({required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    if (!WindowPin.supported) {
      return const SizedBox.shrink();
    }
    return Obx(() {
      var on = controller.windowFullState.value;
      return IconButton(
        tooltip: on ? "退出窗口全屏".t : "窗口全屏".t,
        onPressed: controller.toggleWindowFull,
        icon: Icon(
          on ? Remix.aspect_ratio_fill : Remix.aspect_ratio_line,
          color: Colors.white,
          size: 24,
        ),
      );
    });
  }
}
