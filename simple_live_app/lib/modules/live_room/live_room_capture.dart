import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/capture/capture_controller.dart';
import 'package:simple_live_app/app/capture/capture_meta.dart';
import 'package:simple_live_app/app/capture/stream_recorder.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/obs_bridge/ass_writer.dart';
import 'package:simple_live_app/services/obs_bridge/danmaku_recorder.dart';
import 'package:simple_live_app/services/obs_bridge/obs_bridge_service.dart';

/// 直播间给截图和录屏的东西：直播间信息、画面尺寸、流录制时的同名弹幕
class LiveCaptureHost implements CaptureHost {
  final LiveRoomController room;
  LiveCaptureHost(this.room);

  @override
  Player get player => room.player;

  @override
  CaptureMeta meta() {
    var detail = room.detail.value;
    return CaptureMeta(
      siteId: room.site.id,
      siteName: room.site.name,
      roomId: room.roomId,
      title: detail?.title ?? "",
      streamer: detail?.userName ?? "",
      url: detail?.url ?? "",
      time: DateTime.now(),
      software: captureSoftware(),
    );
  }

  @override
  BoxFit get videoFit =>
      scaleModeFit(AppSettingsController.instance.scaleMode.value).$1;

  @override
  double? get videoAspectRatio =>
      scaleModeFit(AppSettingsController.instance.scaleMode.value).$2;

  @override
  bool get fullscreen =>
      room.fullScreenState.value || room.smallWindowState.value;

  @override
  Stream<Object?>? get reopened => room.player.stream.playlist;

  @override
  Future<CaptureSidecar?> startSidecar(String assPath) async {
    var info = room.obsRoomInfo();
    var file = File(assPath);
    var recorder = await DanmakuAssRecorder.start(
      dir: file.parent,
      file: file,
      options: AssOptions.fromConfig(ObsBridgeService.danmakuConfig()),
      site: room.site.id,
      roomId: room.roomId,
      roomKey: info.key,
      roomLabel: info.label,
    );
    room.captureSidecars.add(recorder);
    return _LiveSidecar(room, recorder);
  }
}

/// 录屏时同名的弹幕文件：之后收到的弹幕和 SC 写进去（见 LiveRoomController.captureSidecars）
class _LiveSidecar implements CaptureSidecar {
  final LiveRoomController room;
  final DanmakuAssRecorder recorder;
  _LiveSidecar(this.room, this.recorder);

  @override
  Future<void> stop() async {
    room.captureSidecars.remove(recorder);
    await recorder.stop();
  }
}
