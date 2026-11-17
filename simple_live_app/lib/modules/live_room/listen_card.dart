import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/modules/live_room/listen_mode.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_playback.dart';
import 'package:simple_live_app/widgets/net_image.dart';

/// 剩下的秒数写成 1:05:09 或 05:09
String listenClock(int seconds) {
  if (seconds < 0) seconds = 0;
  String two(int v) => v.toString().padLeft(2, "0");
  var h = seconds ~/ 3600;
  var m = (seconds % 3600) ~/ 60;
  var s = seconds % 60;
  return h > 0 ? "$h:${two(m)}:${two(s)}" : "${two(m)}:${two(s)}";
}

/// 卡片上定时关闭按钮的文字：开着时显示还剩多久
String listenTimerLabel({required bool enabled, required int seconds}) =>
    enabled
        ? "{parseDuration}后自动关闭".tf({"parseDuration": listenClock(seconds)})
        : "定时关闭".t;

/// 听直播时画面位置上的主播卡片：头像、名字、标题，暂停/继续、恢复画面、定时关闭。
/// 地方小（手机竖屏、电脑小窗）时横着排，宽时竖着排；放不下时可以上下滑，不会溢出
class ListenCard extends StatelessWidget {
  final LiveRoomController controller;
  const ListenCard({required this.controller, super.key});

  static const _textColor = Colors.white;
  static const _subColor = Colors.white70;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, box) {
          var roomy = box.maxWidth >= 480 && box.maxHeight >= 300;
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Obx(() => roomy ? _column() : _row()),
            ),
          );
        },
      ),
    );
  }

  Widget _row() {
    return Row(
      children: [
        _avatar(56),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ..._texts(TextAlign.start),
              const SizedBox(height: 8),
              _buttons(WrapAlignment.start),
            ],
          ),
        ),
      ],
    );
  }

  Widget _column() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _avatar(80),
          const SizedBox(height: 12),
          ..._texts(TextAlign.center),
          const SizedBox(height: 16),
          _buttons(WrapAlignment.center),
        ],
      ),
    );
  }

  Widget _avatar(double size) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white24),
      ),
      child: NetImage(
        controller.detail.value?.userAvatar ?? "",
        width: size,
        height: size,
        borderRadius: size / 2,
      ),
    );
  }

  List<Widget> _texts(TextAlign align) {
    var room = controller.detail.value;
    var name = room?.userName ?? "";
    String status;
    if (!controller.liveStatus.value) {
      status = "未开播".t;
    } else if (controller.listen.reconnecting.value) {
      status = "正在重新连接".t;
    } else {
      status = room?.title ?? "";
    }
    return [
      Text(
        name.isEmpty ? controller.site.name : name,
        textAlign: align,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: _textColor,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      if (status.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(
          status,
          textAlign: align,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: _subColor, fontSize: 13),
        ),
      ],
    ];
  }

  Widget _buttons(WrapAlignment alignment) {
    var timerOn = controller.autoExitEnable.value;
    return Wrap(
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        // 没开播时不显示
        LivePauseButton(controller: controller),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: _textColor,
            side: const BorderSide(color: Colors.white54),
            visualDensity: VisualDensity.compact,
          ),
          onPressed: controller.exitListenMode,
          icon: const Icon(Remix.tv_2_line, size: 18),
          label: Text("恢复画面".t),
        ),
        TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: timerOn ? _textColor : _subColor,
            visualDensity: VisualDensity.compact,
          ),
          onPressed: controller.showAutoExitSheet,
          icon: const Icon(Icons.timer_outlined, size: 18),
          label: Text(
            listenTimerLabel(
              enabled: timerOn,
              seconds: controller.countdown.value,
            ),
          ),
        ),
      ],
    );
  }
}
