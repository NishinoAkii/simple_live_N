import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/capture/capture_compose.dart';
import 'package:simple_live_app/app/capture/capture_flow.dart';
import 'package:simple_live_app/app/capture/capture_meta.dart';
import 'package:simple_live_app/app/capture/capture_scope.dart';
import 'package:simple_live_app/app/capture/capture_settings.dart';
import 'package:simple_live_app/app/capture/gif_recorder.dart';
import 'package:simple_live_app/app/capture/native_capture.dart';
import 'package:simple_live_app/app/capture/stream_recorder.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 直播间给截图和录屏提供的东西
abstract class CaptureHost {
  Player get player;

  /// 现在的直播间信息（文件名、图片信息用）
  CaptureMeta meta();

  /// 视频在播放器里怎么摆（和 Video 组件一样）
  BoxFit get videoFit;
  double? get videoAspectRatio;

  /// 全屏或电脑小窗：窗口里只有播放器
  bool get fullscreen;

  /// 视频流重新打开（换线路、重连、换 P）时来一个事件；流录制据此换文件
  Stream<Object?>? get reopened;

  /// 开始记录和视频同名的 ASS 弹幕；不支持时返回 null。
  /// 1.26.0 的流录制不带弹幕，不用它
  Future<CaptureSidecar?> startSidecar(String assPath);
}

/// 一次录屏：流录制或画面录制
abstract class CaptureRecorder {
  /// 文件扩展名（不带点）
  String get extension;

  /// 原生端录的（它可能自己停下，见 NativeCapture.stopped）
  bool get native;

  /// 开始录到 [path]。没开始（如用户没允许）返回 false；出错时抛出，消息给用户看
  Future<bool> start(String path, CaptureRecordRequest request);

  /// 停下，返回录到的东西；什么都没录到时为 null
  Future<CaptureResult?> stop(String baseName);
}

class CaptureRecordRequest {
  /// 画面录制：录哪一块（物理像素，相对窗口客户区）
  final Rect? rect;
  final int fps;

  /// 设置里的最长录制时间（秒），0 = 不限
  final int maxSeconds;
  final Stream<Object?>? reopened;

  const CaptureRecordRequest({
    this.rect,
    this.fps = 30,
    this.maxSeconds = 0,
    this.reopened,
  });
}

/// 流录制：mpv stream-record，只有视频流（不带弹幕文件）
class StreamCaptureRecorder implements CaptureRecorder {
  final CaptureHost host;

  /// 测试里换掉 mpv 的 setProperty（null = 用播放器的）
  final Future<void> Function(String name, String value)? setProperty;
  StreamCaptureRecorder(this.host, {this.setProperty});

  StreamRecordSession? _session;

  @override
  String get extension => "mkv";

  @override
  bool get native => false;

  @override
  Future<bool> start(String path, CaptureRecordRequest request) async {
    var set = setProperty;
    if (set == null) {
      var native = host.player.platform;
      if (native is! NativePlayer) {
        return false;
      }
      set = native.setProperty;
    }
    // 不记弹幕：弹幕层的开关只管截图
    var session = StreamRecordSession(setProperty: set);
    await session.start(path, reopened: request.reopened);
    _session = session;
    return true;
  }

  @override
  Future<CaptureResult?> stop(String baseName) async {
    var session = _session;
    _session = null;
    if (session == null) {
      return null;
    }
    var files = await session.stop();
    if (files.isEmpty) {
      return null;
    }
    var bytes = 0;
    for (var path in files) {
      try {
        bytes += await File(path).length();
      } catch (_) {}
    }
    return CaptureResult.video(files, baseName: baseName, bytes: bytes);
  }
}

/// 画面录制：原生端把窗口里的一块录成 MP4（见 [NativeCapture]）
class ScreenCaptureRecorder implements CaptureRecorder {
  @override
  String get extension => "mp4";

  @override
  bool get native => true;

  @override
  Future<bool> start(String path, CaptureRecordRequest request) {
    return NativeCapture.recordStart(
      path: path,
      rect: request.rect ?? Rect.zero,
      fps: request.fps,
      maxSeconds: request.maxSeconds,
      // 安卓录屏时的通知
      extra: {
        'notificationTitle': "正在录屏".t,
        'stopLabel': "停止".t,
        'channelName': "录屏".t,
      },
    );
  }

  @override
  Future<CaptureResult?> stop(String baseName) async =>
      nativeCaptureResult(await NativeCapture.recordStop(), baseName);
}

/// 原生端给的录屏结果换成 [CaptureResult]；没有文件、也没存进相册时为 null
CaptureResult? nativeCaptureResult(
    NativeRecordResult? result, String baseName) {
  if (result == null || (result.path.isEmpty && !result.savedToAlbum)) {
    return null;
  }
  return CaptureResult.video(
    [if (result.path.isNotEmpty) result.path],
    baseName: baseName,
    savedToAlbum: result.savedToAlbum,
    duration: result.duration,
    bytes: result.bytes,
    audio: result.audio,
  );
}

/// 原生端自己停下录屏的原因，给用户看的
String nativeStopReasonText(String reason) => switch (reason) {
      "rotation" => "屏幕旋转了".t,
      "resize" => "窗口大小变了".t,
      "background" => "切到后台了".t,
      "limit" => "已到最长时间".t,
      "notification" => "在通知里停止了".t,
      "closed" => "窗口关了".t,
      "error" => "出错了".t,
      _ => "系统停止了录屏".t,
    };

/// 录屏没开始时的原因（PlatformException 的 code），没有对应说明时用原生端的消息
String recordStartErrorText(PlatformException e) => switch (e.code) {
      "permission_denied" =>
        "需要在“系统设置 → 隐私与安全性 → 屏幕录制”里允许 Simple Live，然后重新打开 App".t,
      "unsupported" => "这台电脑的系统太旧，画面录制需要 macOS 12.3 或更新".t,
      "busy" => "已经有一个录屏在进行".t,
      "no_window" => "找不到要录的窗口".t,
      "consent_failed" => "没有拿到录屏授权".t,
      _ => e.message?.isNotEmpty == true
          ? e.message!
          : "录屏没有开始：{e}".tf({"e": e.code}),
    };

/// 为什么停下
enum CaptureStopReason { user, limit, leave }

/// 一个页面（直播间）的截图和录屏
class CaptureController {
  final CaptureHost host;
  final CaptureFlow flow;
  final CaptureScope scope = CaptureScope();

  /// 测试里换掉：录屏方式 → 录屏器、录到哪个文件夹、定时器、现在的时间
  final CaptureRecorder Function(CaptureRecordMode mode) recorderFor;
  final Future<Directory> Function() recordDir;
  final Timer Function(Duration duration, void Function() callback) timer;
  final DateTime Function() now;

  CaptureController({
    required this.host,
    required this.flow,
    required this.recordDir,
    CaptureRecorder Function(CaptureRecordMode mode)? recorderFor,
    Timer Function(Duration duration, void Function() callback)? timer,
    DateTime Function()? now,
  })  : recorderFor = recorderFor ??
            ((mode) => mode == CaptureRecordMode.screen
                ? ScreenCaptureRecorder()
                : CaptureSettings.instance.gif
                    ? GifCaptureRecorder(host)
                    : StreamCaptureRecorder(host)),
        timer = timer ?? Timer.new,
        now = now ?? DateTime.now;

  CaptureSettings get settings => CaptureSettings.instance;

  /// 正在录
  final RxBool recording = false.obs;

  /// 正在开始或停下（按钮先不响应）
  final RxBool busy = false.obs;

  /// 已经录了几秒
  final RxInt elapsedSeconds = 0.obs;

  /// 这次的录屏方式
  CaptureRecordMode? mode;

  CaptureRecorder? _recorder;
  String _baseName = "";
  DateTime? _startedAt;
  Timer? _ticker;
  Timer? _limitTimer;
  StreamSubscription<Map<Object?, Object?>>? _nativeStopSub;
  bool _shooting = false;
  bool _disposed = false;

  /// 画面录制能不能用（Linux 没有；原生接口不在时也没有）
  static Future<bool> screenRecordSupported() async =>
      !Platform.isLinux && await NativeCapture.probe();

  /// 实际用的录屏方式：画面录制没开（[CaptureFeatures.screenRecording]）、
  /// 选了但用不了时用流录制
  Future<CaptureRecordMode> effectiveMode() async {
    if (CaptureFeatures.screenRecording &&
        settings.recordMode.value == CaptureRecordMode.screen &&
        await screenRecordSupported()) {
      return CaptureRecordMode.screen;
    }
    return CaptureRecordMode.stream;
  }

  /// 按钮上显示的时间：03:25
  String get elapsedText {
    var s = elapsedSeconds.value;
    String two(int v) => v.toString().padLeft(2, "0");
    return s >= 3600
        ? "${s ~/ 3600}:${two(s % 3600 ~/ 60)}:${two(s % 60)}"
        : "${two(s ~/ 60)}:${two(s % 60)}";
  }

  // ---------------- 视频信息浮层 ----------------

  /// 顶栏的按钮：显示、隐藏视频信息
  void toggleVideoStats() {
    var settings = AppSettingsController.instance;
    settings.setPlayerVideoStats(!settings.playerVideoStats.value);
  }

  /// 双击落在视频信息浮层上时隐藏它（截图前顺手藏掉），返回 true；
  /// 不在浮层上时返回 false，播放器照常处理双击
  bool hideVideoStatsAt(Offset global) {
    var settings = AppSettingsController.instance;
    if (!scope.hitsVideoStats(global, shown: settings.playerVideoStats.value)) {
      return false;
    }
    settings.setPlayerVideoStats(false);
    return true;
  }

  // ---------------- 截图 ----------------

  /// 截一张：视频帧、弹幕、选了的层（和侧栏），按设置保存、复制或问一下
  Future<void> screenshot() async {
    if (_shooting) {
      return;
    }
    _shooting = true;
    try {
      var png = await _composeScreenshot();
      if (png == null) {
        return;
      }
      var meta = host.meta();
      if (settings.metadata.value) {
        png = PngMeta.embedMeta(png, meta);
      }
      await flow.finish(
        CaptureResult.image(png, baseName: meta.baseName),
        settings.afterAction.value,
      );
    } catch (e, s) {
      Log.e("截图失败：$e", s);
      flow.toast("截图失败：{e}".tf({"e": e}));
    } finally {
      _shooting = false;
    }
  }

  Future<Uint8List?> _composeScreenshot() async {
    var playerRect = scope.rectOf(CaptureLayer.player);
    var context = scope.contextOf(CaptureLayer.player);
    if (playerRect == null || context == null) {
      flow.toast("截图失败，没截到画面".t);
      return null;
    }
    var frame = await grabVideoFrame(host.player);
    if (frame == null) {
      flow.toast("截图失败，没截到画面".t);
      return null;
    }
    if (!context.mounted) {
      frame.dispose();
      return null;
    }
    // 取到画面了：播放器上闪一下（不进截图）
    scope.flash();
    var dpr = View.of(context).devicePixelRatio;
    var panelColor = Theme.of(context).scaffoldBackgroundColor;
    var chosen = settings.chosenLayers;
    var handles = <CaptureLayer, List<CaptureLayerHandle>>{
      for (var layer in captureOverlayOrder)
        if (chosen.contains(layer)) layer: scope.handlesOf(layer),
    };
    var overlays = <CaptureLayer, List<Rect>>{
      for (var e in handles.entries) e.key: [for (var h in e.value) h.rect],
    };
    var page = settings.range.value == CaptureRange.window && !host.fullscreen
        ? scope.rectOf(CaptureLayer.page)
        : null;
    var plan = planCapture(
      player: playerRect,
      chosen: chosen,
      overlays: overlays,
      panel: scope.rectOf(CaptureLayer.sidePanel),
      page: page,
      frame: Size(frame.width.toDouble(), frame.height.toDouble()),
      fit: host.videoFit,
      aspectRatio: host.videoAspectRatio,
      devicePixelRatio: dpr,
      imageSize: settings.imageSize.value,
    );
    var images = <CapturePiece, ui.Image>{};
    try {
      for (var piece in plan.pieces) {
        ui.Image? image;
        switch (piece.layer) {
          case CaptureLayer.player:
          case CaptureLayer.page:
            continue;
          case CaptureLayer.sidePanel:
            image = await scope.imageOf(CaptureLayer.sidePanel, plan.scale);
          default:
            var list = handles[piece.layer] ?? const [];
            if (piece.index < list.length) {
              image = await list[piece.index].capture(plan.scale);
            }
        }
        if (image != null) {
          images[piece] = image;
        }
      }
      if (page != null) {
        var image = await _capturePage(frame, plan.scale,
            hidePanel: !chosen.contains(CaptureLayer.sidePanel));
        if (image != null) {
          images[plan.pieces.first] = image;
        }
      }
      var composed = await paintCapture(
        plan,
        video: frame,
        images: images,
        panelBackground: panelColor,
      );
      try {
        var data = await composed.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        composed.dispose();
      }
    } finally {
      frame.dispose();
      for (var image in images.values) {
        image.dispose();
      }
    }
  }

  /// 截整个页面：视频（纹理不能截）先换成截到的帧，截图、录屏键藏起来，
  /// 没选的侧栏也藏起来，画完一帧后截，再恢复
  Future<ui.Image?> _capturePage(
    ui.Image frame,
    double scale, {
    required bool hidePanel,
  }) async {
    var addedPanel = hidePanel && scope.hidden.add(CaptureLayer.sidePanel);
    scope.freezeFrame = frame;
    scope.stillCapture.value = true;
    try {
      await _nextFrame();
      return await scope.imageOf(CaptureLayer.page, scale);
    } finally {
      scope.stillCapture.value = false;
      scope.freezeFrame = null;
      if (addedPanel) {
        scope.hidden.remove(CaptureLayer.sidePanel);
      }
    }
  }

  static Future<void> _nextFrame() async {
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame;
  }

  // ---------------- 录屏 ----------------

  Future<void> toggleRecording() =>
      recording.value ? stopRecording() : startRecording();

  Future<void> startRecording() async {
    // 两种录屏都关着时什么都不做（见 CaptureFeatures）
    if (!CaptureFeatures.recording ||
        recording.value ||
        busy.value ||
        _disposed) {
      return;
    }
    busy.value = true;
    var restoreHidden = false;
    try {
      var mode = await effectiveMode();
      var recorder = recorderFor(mode);
      var meta = host.meta();
      var dir = await recordDir();
      var file = uniqueCaptureFile(dir, meta.baseName, recorder.extension);
      Rect? rect;
      if (mode == CaptureRecordMode.screen) {
        rect = _recordRect();
        if (rect == null) {
          flow.toast("录屏没有开始：找不到播放器".t);
          return;
        }
        _hideForRecording();
        restoreHidden = true;
        await _nextFrame();
      }
      // 最长时间：流录制存成 GIF 时最多 1 分钟
      var limit = settings.recordLimit(
          gif: mode == CaptureRecordMode.stream && settings.gif);
      bool started;
      try {
        started = await recorder.start(
          file.path,
          CaptureRecordRequest(
            rect: rect,
            fps: Platform.isAndroid || Platform.isIOS ? 30 : 60,
            maxSeconds: limit.inSeconds,
            reopened: host.reopened,
          ),
        );
      } on PlatformException catch (e) {
        flow.toast(recordStartErrorText(e));
        return;
      }
      if (!started) {
        // 手机上用户没同意录屏
        flow.toast("已取消录屏".t);
        return;
      }
      if (_disposed) {
        await recorder.stop(meta.baseName);
        return;
      }
      restoreHidden = false;
      _recorder = recorder;
      this.mode = mode;
      _baseName = p.basenameWithoutExtension(file.path);
      _startedAt = now();
      elapsedSeconds.value = 0;
      recording.value = true;
      _ticker = timer(const Duration(seconds: 1), _tick);
      _limitTimer =
          timer(limit, () => stopRecording(reason: CaptureStopReason.limit));
      if (recorder.native) {
        _nativeStopSub = NativeCapture.stopped.listen(handleNativeStop);
      }
    } catch (e, s) {
      Log.e("录屏没有开始：$e", s);
      flow.toast("录屏没有开始：{e}".tf({"e": e}));
    } finally {
      if (restoreHidden) {
        _restoreHidden();
      }
      busy.value = false;
    }
  }

  /// 每秒一次：更新时间（定时器换成假的时由测试自己调）
  void _tick() {
    var started = _startedAt;
    if (!recording.value || started == null) {
      return;
    }
    elapsedSeconds.value = now().difference(started).inSeconds;
    _ticker = timer(const Duration(seconds: 1), _tick);
  }

  /// 录屏的状态收起来（不再计时、按钮回到没在录），返回在录的录屏器
  CaptureRecorder? _endRecordingState() {
    var recorder = _recorder;
    if (recorder == null || !recording.value) {
      return null;
    }
    _recorder = null;
    _ticker?.cancel();
    _limitTimer?.cancel();
    _ticker = null;
    _limitTimer = null;
    _nativeStopSub?.cancel();
    _nativeStopSub = null;
    recording.value = false;
    return recorder;
  }

  /// 停下。用户按的：按设置保存、复制或问一下；到了最长时间或离开页面：直接保存
  Future<void> stopRecording({
    CaptureStopReason reason = CaptureStopReason.user,
  }) async {
    var recorder = _endRecordingState();
    if (recorder == null) {
      return;
    }
    busy.value = true;
    try {
      CaptureResult? result;
      try {
        result = await recorder.stop(_baseName);
      } finally {
        _restoreHidden();
      }
      await _finish(result, reason);
    } catch (e, s) {
      Log.e("停止录屏失败：$e", s);
      flow.toast("停止录屏失败：{e}".tf({"e": e}));
    } finally {
      busy.value = false;
      mode = null;
    }
  }

  /// 原生端自己停下了录屏（[args] 见 NativeCapture.stopped）：
  /// 到了上限时直接保存，别的原因先说一下为什么停了，再按设置保存、复制或问一下
  Future<void> handleNativeStop(Map<Object?, Object?> args) async {
    var recorder = _recorder;
    if (recorder == null || !recorder.native) {
      return;
    }
    if (_endRecordingState() == null) {
      return;
    }
    _restoreHidden();
    busy.value = true;
    try {
      var reason = args["reason"]?.toString() ?? "";
      var error = args["error"]?.toString() ?? "";
      var result =
          nativeCaptureResult(NativeRecordResult.fromMap(args), _baseName);
      if (reason == "limit" && result != null) {
        await _finish(result, CaptureStopReason.limit);
        return;
      }
      var stopped = "录屏已停止（{reason}）".tf({
        "reason": nativeStopReasonText(reason),
      });
      if (result == null) {
        flow.toast(error.isEmpty ? stopped : "$stopped$error");
        return;
      }
      flow.toast(result.audio == false ? "$stopped${"，没有录到声音".t}" : stopped);
      await flow.finish(result, settings.afterAction.value);
    } catch (e, s) {
      Log.e("录屏停止后处理失败：$e", s);
    } finally {
      busy.value = false;
      mode = null;
    }
  }

  Future<void> _finish(CaptureResult? result, CaptureStopReason reason) async {
    if (result == null) {
      flow.toast("录屏失败，没录到内容".t);
      return;
    }
    // 要了声音但没录到时说一下
    var noAudio = result.audio == false ? "，没有录到声音".t : "";
    switch (reason) {
      case CaptureStopReason.limit:
        await flow.autoSave(result,
            done: "${"已到最长录制时间，录屏已保存：{where}".t}$noAudio");
      case CaptureStopReason.leave:
        await flow.autoSave(result, done: "${"录屏已保存：{where}".t}$noAudio");
      case CaptureStopReason.user:
        if (noAudio.isNotEmpty) {
          flow.toast("没有录到声音".t);
        }
        await flow.finish(result, settings.afterAction.value);
    }
  }

  /// 画面录制录哪一块：直播画面（选了侧栏时加上侧栏）或整个窗口，物理像素
  Rect? _recordRect() {
    var context = scope.contextOf(CaptureLayer.player);
    var player = scope.rectOf(CaptureLayer.player);
    if (context == null || player == null) {
      return null;
    }
    var view = View.of(context);
    return captureRecordRect(
      range: settings.range.value,
      fullscreen: host.fullscreen,
      player: player,
      panel: settings.sidePanel.value
          ? scope.rectOf(CaptureLayer.sidePanel)
          : null,
      viewSize: view.physicalSize,
      devicePixelRatio: view.devicePixelRatio,
    );
  }

  /// 画面录制期间藏起没选的层；录到的范围里有截图、录屏键时键变透明
  void _hideForRecording() {
    var window = settings.range.value == CaptureRange.window;
    scope.hidden.assignAll({
      for (var layer in captureOverlayOrder)
        if (!settings.includes(layer)) layer,
      if (window && !settings.sidePanel.value) CaptureLayer.sidePanel,
    });
    scope.buttonsHidden.value = window || host.fullscreen;
  }

  void _restoreHidden() {
    scope.hidden.clear();
    scope.buttonsHidden.value = false;
  }

  /// 离开页面（关掉、换直播间）：在录的直接保存
  Future<void> stopForLeave() => stopRecording(reason: CaptureStopReason.leave);

  void dispose() {
    if (recording.value) {
      stopForLeave();
    }
    _disposed = true;
  }
}

/// mpv 的一帧原始画面：BGR0，每行 [stride] 字节
class RawVideoFrame {
  final Uint8List bytes;
  final int width;
  final int height;
  final int stride;
  const RawVideoFrame(this.bytes, this.width, this.height, this.stride);
}

/// 取 mpv 现在的原始画面（截图、GIF 录制都用）；大小对不上时为 null
Future<RawVideoFrame?> grabRawVideoFrame(Player player) async {
  var width = player.state.width;
  var height = player.state.height;
  var raw = await player.screenshot(format: null);
  if (raw != null &&
      width != null &&
      height != null &&
      width > 0 &&
      height > 0 &&
      raw.length >= width * height * 4 &&
      raw.length % height == 0) {
    return RawVideoFrame(raw, width, height, raw.length ~/ height);
  }
  return null;
}

/// 取 mpv 现在的画面：先要原始像素（快），大小对不上时要 PNG
Future<ui.Image?> grabVideoFrame(Player player) async {
  try {
    var raw = await grabRawVideoFrame(player);
    if (raw != null) {
      return await imageFromBgr0(raw.bytes, raw.width, raw.height, raw.stride);
    }
    var png = await player.screenshot(format: "image/png");
    if (png != null) {
      return await imageFromEncoded(png);
    }
  } catch (e) {
    Log.logPrint(e);
  }
  return null;
}

/// 画面录制录哪一块（物理像素，相对窗口客户区）：完整窗口或全屏时是整个窗口，
/// 否则是播放器（[panel] 不为空时加上侧栏）
Rect captureRecordRect({
  required CaptureRange range,
  required bool fullscreen,
  required Rect player,
  Rect? panel,
  required Size viewSize,
  required double devicePixelRatio,
}) {
  if (range == CaptureRange.window || fullscreen) {
    return Offset.zero & viewSize;
  }
  var rect = panel == null ? player : player.expandToInclude(panel);
  var dpr = devicePixelRatio;
  return Rect.fromLTRB(
    (rect.left * dpr).floorToDouble(),
    (rect.top * dpr).floorToDouble(),
    (rect.right * dpr).ceilToDouble(),
    (rect.bottom * dpr).ceilToDouble(),
  ).intersect(Offset.zero & viewSize);
}

/// 设置里的画面尺寸（0 适应、1 拉伸、2 铺满、3 16:9、4 4:3）对应的摆法
(BoxFit, double?) scaleModeFit(int mode) => switch (mode) {
      1 => (BoxFit.fill, null),
      2 => (BoxFit.cover, null),
      3 => (BoxFit.contain, 16 / 9),
      4 => (BoxFit.contain, 4 / 3),
      _ => (BoxFit.contain, null),
    };

/// 图片信息里的软件名：Simple Live 1.25.0
String captureSoftware() {
  try {
    return "Simple Live N ${Utils.packageInfo.version}";
  } catch (_) {
    return "Simple Live N";
  }
}
