import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/play_prefs.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

/// 直播的暂停状态。
///
/// 暂停期间断流不重连，也不算播放失败；继续时重新拉流，回到最新画面
class LivePauseState {
  /// 用户点了暂停（或者进入后台时自动暂停了）
  final paused = false.obs;

  /// 播放器在不在播。别的地方（iOS 小窗、换清晰度）让它播起来时，暂停状态跟着取消
  final playing = false.obs;

  /// 是进入后台时自动暂停的：回到前台时自动继续
  bool byBackground = false;

  /// 正在继续（重新拉流中）
  bool resuming = false;

  StreamSubscription<bool>? _playingSubscription;

  void dispose() {
    _playingSubscription?.cancel();
  }
}

/// 暂停、继续，以及手动切换清晰度（记住上次）
extension LiveRoomPlayback on LiveRoomController {
  /// 直播间打开时调用
  void initLivePause() {
    var state = livePause;
    state.playing.value = player.state.playing;
    state._playingSubscription = player.stream.playing.listen((playing) {
      state.playing.value = playing;
      // 换清晰度、换线路、刷新以后播放器又播起来了：不再算暂停。
      // 事件是异步到的，以播放器现在的状态为准（刚点了暂停时可能还有一个“在播”的旧事件）
      if (playing &&
          player.state.playing &&
          state.paused.value &&
          !state.resuming) {
        state.paused.value = false;
        state.byBackground = false;
      }
    });
  }

  /// 按钮显示成“继续”：点过暂停，或者播放器停着（比如 iOS 小窗在后台关掉以后）
  bool get showResume =>
      livePause.paused.value || (!livePause.playing.value && liveStatus.value);

  void toggleLivePause() {
    // 正在重新拉流，等它好
    if (livePause.resuming) {
      return;
    }
    if (showResume) {
      resumeLive();
    } else {
      pauseLive();
    }
  }

  Future<void> pauseLive({bool background = false}) async {
    var state = livePause;
    state.paused.value = true;
    state.byBackground = background;
    // 正在进行的断流重连作废，暂停期间也不再重连
    resetPlaybackRecovery();
    try {
      await player.pause();
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 继续：重新读直播间和播放地址（暂停久了可能已经下播，有的平台的地址只能用一次），
  /// 按当前清晰度和线路打开，回到最新画面
  Future<void> resumeLive() async {
    var state = livePause;
    state.paused.value = false;
    state.byBackground = false;
    if (isClosed) {
      return;
    }
    if (detail.value == null ||
        !liveStatus.value ||
        qualites.isEmpty ||
        currentQuality < 0 ||
        currentQuality >= qualites.length) {
      await player.play();
      return;
    }
    resetPlaybackRecovery();
    errorMsg.value = "";
    state.resuming = true;
    // 又点了暂停、关了直播间、或者用户自己刷新了：这次继续作废
    bool stale() => isClosed || state.paused.value;
    try {
      var fresh = await site.liveSite.getRoomDetail(roomId: roomId);
      if (stale()) {
        return;
      }
      if (!fresh.status && !fresh.isRecord) {
        liveStatus.value = false;
        addSysMsg("主播已下播".t);
        await player.stop();
        return;
      }
      detail.value = fresh;
      var name = qualites[currentQuality].quality;
      var list = await site.liveSite.getPlayQualites(detail: fresh);
      if (stale()) {
        return;
      }
      if (list.isEmpty) {
        throw StateError("no qualities");
      }
      var index = list.indexWhere((e) => e.quality == name);
      if (index < 0) {
        index = min(currentQuality, list.length - 1);
      }
      var playUrl =
          await site.liveSite.getPlayUrls(detail: fresh, quality: list[index]);
      if (stale()) {
        return;
      }
      if (playUrl.urls.isEmpty) {
        throw StateError("no urls");
      }
      qualites.value = list;
      currentQuality = index;
      currentQualityInfo.value = list[index].quality;
      playUrls.value = playUrl.urls;
      playHeaders = playUrl.headers;
      if (currentLineIndex < 0 || currentLineIndex >= playUrls.length) {
        currentLineIndex = 0;
      }
      await openPlaylist(startIndex: currentLineIndex);
    } catch (e) {
      Log.logPrint(e);
      if (!stale()) {
        // 一次没拉到：交给断流重连（会重试几次、换线路）
        state.resuming = false;
        recoverPlayback("播放出错".t);
      }
    } finally {
      state.resuming = false;
    }
  }

  /// 进入后台、回到前台。设置了“进入后台自动暂停”时：进入后台暂停，回来时重新拉流。
  /// 开着 iOS 画中画、听直播时不暂停
  void onLifecycleForPause(AppLifecycleState lifecycle) {
    var state = livePause;
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached) {
      // 听直播就是要在后台接着播
      if (!AppSettingsController.instance.playerAutoPause.value ||
          listen.active.value ||
          (iosPip?.active.value ?? false) ||
          (iosPip?.keepPlaybackInBackground ?? false) ||
          state.paused.value ||
          !player.state.playing) {
        return;
      }
      pauseLive(background: true);
    } else if (lifecycle == AppLifecycleState.resumed) {
      if (state.paused.value && state.byBackground) {
        resumeLive();
      }
    }
  }

  /// 手动选清晰度（底部弹窗、右侧弹窗）：记下来再换
  void switchQualityManually(int index) {
    currentQuality = index;
    PlayPrefs.instance.rememberManualQuality(
      site.id,
      qualites,
      index,
      cellular: qualityOnCellular,
    );
    getPlayUrl();
  }
}

/// 控制栏最左边的暂停、继续按钮。没开播时不显示
class LivePauseButton extends StatelessWidget {
  final LiveRoomController controller;
  const LivePauseButton({required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!controller.liveStatus.value) {
        return const SizedBox.shrink();
      }
      var resume = controller.showResume;
      return IconButton(
        tooltip: resume ? "继续".t : "暂停".t,
        onPressed: controller.toggleLivePause,
        icon: Icon(
          resume ? Remix.play_fill : Remix.pause_fill,
          color: Colors.white,
        ),
      );
    });
  }
}
