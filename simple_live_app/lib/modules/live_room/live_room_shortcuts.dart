import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/desktop_shortcuts.dart';
import 'package:simple_live_app/app/player_lock.dart';
import 'package:simple_live_app/app/player_mute.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_playback.dart';

/// 直播间里快捷键用到的状态：聊天栏收起了没有、提示的计时器
class LiveRoomKeyState {
  /// 宽屏时右侧聊天栏收起（只在这次打开的直播间里有效）
  final chatCollapsed = false.obs;
  Timer? tipTimer;

  static final Expando<LiveRoomKeyState> _states = Expando("LiveRoomKeyState");

  static LiveRoomKeyState of(LiveRoomController controller) =>
      _states[controller] ??= LiveRoomKeyState();
}

/// 直播间的快捷键。整个直播间页面包在这里面
class LiveRoomShortcuts extends StatelessWidget {
  final LiveRoomController controller;
  final Widget child;
  const LiveRoomShortcuts({
    required this.controller,
    required this.child,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ShortcutArea(
      onAction: (action, repeat) => perform(controller, action, repeat),
      child: child,
    );
  }

  static bool perform(
      LiveRoomController c, ShortcutAction action, bool repeat) {
    if (c.isClosed) {
      return false;
    }
    if (c.lockControlsState.value && c.fullScreenState.value) {
      if (!repeat) PlayerLock.showTip();
      return true;
    }
    switch (action) {
      case ShortcutAction.fullscreen:
        if (c.smallWindowState.value) {
          c.exitSmallWindow();
        } else if (c.fullScreenState.value) {
          c.exitFull();
        } else {
          c.enterFullScreen();
        }
      case ShortcutAction.danmaku:
        var show = !c.showDanmakuState.value;
        c.showDanmakuState.value = show;
        _tip(c, show ? "弹幕已开启".t : "弹幕已关闭".t);
      case ShortcutAction.mute:
        var muted = PlayerMute.toggle(c.player);
        _tip(c, muted ? "已静音".t : "已取消静音".t);
      case ShortcutAction.refresh:
        c.refreshRoom();
      case ShortcutAction.collapseChat:
        var state = LiveRoomKeyState.of(c);
        state.chatCollapsed.value = !state.chatCollapsed.value;
      case ShortcutAction.pause:
        if (!c.liveStatus.value) {
          return false;
        }
        c.toggleLivePause();
      case ShortcutAction.volumeUp:
      case ShortcutAction.volumeDown:
        var settings = AppSettingsController.instance;
        var volume = PlayerMute.step(settings.playerVolume.value,
            action == ShortcutAction.volumeUp ? 5 : -5);
        PlayerMute.clear(c.player);
        settings.setPlayerVolume(volume);
        c.player.setVolume(volume);
        _tip(c, "音量 {volume}%".tf({"volume": volume.round()}));
    }
    return true;
  }

  /// 画面中间的提示，一会儿就消失（和拖动调音量时同一个位置）
  static void _tip(LiveRoomController c, String text) {
    var state = LiveRoomKeyState.of(c);
    state.tipTimer?.cancel();
    c.gestureTipText.value = text;
    c.showGestureTip.value = true;
    state.tipTimer = Timer(const Duration(milliseconds: 900), () {
      if (!c.isClosed && !c.verticalDragging) {
        c.showGestureTip.value = false;
      }
    });
  }
}

/// 宽屏时标题栏上收起、展开聊天栏的按钮
class LiveChatToggleButton extends StatelessWidget {
  final LiveRoomController controller;
  const LiveChatToggleButton({required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    var collapsed = LiveRoomKeyState.of(controller).chatCollapsed;
    return Obx(
      () => IconButton(
        tooltip: collapsed.value ? "展开聊天".t : "收起聊天".t,
        icon: Icon(
          collapsed.value
              ? Icons.keyboard_double_arrow_left
              : Icons.keyboard_double_arrow_right,
        ),
        onPressed: () => collapsed.value = !collapsed.value,
      ),
    );
  }
}
