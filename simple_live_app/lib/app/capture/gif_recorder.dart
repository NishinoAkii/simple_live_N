import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:simple_live_app/app/capture/capture_controller.dart';
import 'package:simple_live_app/app/capture/capture_flow.dart';
import 'package:simple_live_app/app/log.dart';

/// 流录制存成 GIF：只有画面，没有声音和弹幕。
///
/// 录的时候每 100 毫秒（10 fps）用截图的取帧（[grabRawVideoFrame]）取一帧原始画面，
/// 交给后台 isolate：缩到 480 宽、每帧单独配调色板、编码，边录边写进文件，不攒帧。
/// 上一帧还没取到、或后台还压着 [maxPending] 帧没编完时，这一下就跳过（丢帧，不排队、
/// 不等）。每帧显示多久按实际取帧的时间记，丢了帧播放速度也不变
class GifCaptureRecorder implements CaptureRecorder {
  GifCaptureRecorder(
    CaptureHost host, {
    Future<RawVideoFrame?> Function()? grab,
    this.interval = const Duration(milliseconds: 100),
    this.width = defaultWidth,
  }) : grab = grab ?? (() => grabRawVideoFrame(host.player));

  static const int defaultWidth = 480;

  /// 后台最多压着几帧没编完，再多就丢帧
  static const int maxPending = 2;

  /// 取一帧（测试里换掉）
  final Future<RawVideoFrame?> Function() grab;
  final Duration interval;
  final int width;

  GifEncodeWorker? _worker;
  String _path = "";
  Timer? _timer;
  final Stopwatch _clock = Stopwatch();
  Future<void>? _grabbing;

  /// 取帧次数、耗时、丢帧（停下时写进日志）
  int _grabs = 0;
  int _dropped = 0;
  int _grabMicros = 0;
  int _maxGrabMicros = 0;
  int _sendMicros = 0;

  @override
  String get extension => "gif";

  @override
  bool get native => false;

  @override
  Future<bool> start(String path, CaptureRecordRequest request) async {
    _path = path;
    _worker = await GifEncodeWorker.spawn(
      path,
      width: width,
      frameMs: interval.inMilliseconds,
    );
    _clock
      ..reset()
      ..start();
    _tick();
    _timer = Timer.periodic(interval, (_) => _tick());
    return true;
  }

  void _tick() {
    var worker = _worker;
    if (worker == null) {
      return;
    }
    if (_grabbing != null || worker.pending >= maxPending) {
      _dropped++;
      return;
    }
    _grabbing = _grab(worker, _clock.elapsedMilliseconds)
        .whenComplete(() => _grabbing = null);
  }

  Future<void> _grab(GifEncodeWorker worker, int atMs) async {
    var watch = Stopwatch()..start();
    RawVideoFrame? frame;
    try {
      frame = await grab();
    } catch (e) {
      Log.logPrint(e);
    }
    var cost = watch.elapsedMicroseconds;
    _grabs++;
    _grabMicros += cost;
    _maxGrabMicros = math.max(_maxGrabMicros, cost);
    if (frame == null || !identical(_worker, worker)) {
      return;
    }
    watch.reset();
    worker.add(frame, atMs);
    _sendMicros += watch.elapsedMicroseconds;
  }

  @override
  Future<CaptureResult?> stop(String baseName) async {
    var worker = _worker;
    _worker = null;
    _timer?.cancel();
    _timer = null;
    if (worker == null) {
      return null;
    }
    await _grabbing;
    _clock.stop();
    var file = File(_path);
    GifEncodeResult done;
    try {
      done = await worker.finish();
    } catch (e) {
      await file.delete().catchError((_) => file);
      rethrow;
    }
    String ms(int micros, int n) =>
        n == 0 ? "-" : (micros / n / 1000).toStringAsFixed(1);
    Log.d("GIF 录制：${done.frames} 帧，取帧 $_grabs 次，"
        "平均 ${ms(_grabMicros, _grabs)} ms，最长 ${ms(_maxGrabMicros, 1)} ms，"
        "交给后台平均 ${ms(_sendMicros, done.frames)} ms，跳过 $_dropped 次，"
        "编码平均 ${ms(done.encodeMicros, done.frames)} ms/帧");
    if (done.frames == 0) {
      await file.delete().catchError((_) => file);
      return null;
    }
    return CaptureResult.video(
      [_path],
      baseName: baseName,
      duration: Duration(milliseconds: done.durationMs),
      bytes: await file.length(),
    );
  }
}

/// 编完的结果（后台 isolate 发回来）
class GifEncodeResult {
  final int frames;
  final int durationMs;
  final int encodeMicros;
  final String? error;
  const GifEncodeResult({
    required this.frames,
    required this.durationMs,
    required this.encodeMicros,
    this.error,
  });
}

/// 后台编码 GIF 的 isolate：收原始帧，编码写文件，[finish] 时收尾
class GifEncodeWorker {
  GifEncodeWorker._(this._port);

  final SendPort _port;
  final Completer<GifEncodeResult> _done = Completer();

  /// 发过去还没编完的帧数
  int pending = 0;

  static const int _frameDone = 1;
  static const String _finish = "finish";

  static Future<GifEncodeWorker> spawn(
    String path, {
    int width = GifCaptureRecorder.defaultWidth,
    int frameMs = 100,
  }) async {
    GifEncodeWorker? worker;
    var ready = Completer<SendPort>();
    var events = RawReceivePort();
    void fail(Object error) {
      events.close();
      if (!ready.isCompleted) {
        ready.completeError(error);
      } else if (worker != null && !worker._done.isCompleted) {
        worker._done.completeError(error);
      }
    }

    events.handler = (Object? message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message == _frameDone) {
        worker?.pending--;
      } else if (message is GifEncodeResult) {
        events.close();
        var error = message.error;
        if (error != null) {
          worker?._done.completeError(Exception(error));
        } else {
          worker?._done.complete(message);
        }
      } else {
        // onError 发来 [错误, 堆栈]；onExit 发来 null（没收尾就退出了）
        fail(Exception(message is List && message.isNotEmpty
            ? "${message.first}"
            : "GIF 编码中断"));
      }
    };
    try {
      await Isolate.spawn(
        _gifWorkerMain,
        (events.sendPort, path, width, frameMs),
        onError: events.sendPort,
        onExit: events.sendPort,
        debugName: "gif-encoder",
      );
    } catch (_) {
      events.close();
      rethrow;
    }
    return worker = GifEncodeWorker._(await ready.future);
  }

  /// 交一帧（[atMs] 是从开始录算起的取帧时间）
  void add(RawVideoFrame frame, int atMs) {
    pending++;
    _port.send((frame, atMs));
  }

  /// 收尾：编完剩下的帧、写完文件
  Future<GifEncodeResult> finish() {
    _port.send(_finish);
    return _done.future;
  }
}

void _gifWorkerMain((SendPort, String, int, int) args) {
  var (reply, path, width, frameMs) = args;
  var writer = GifFileWriter(path, width: width, frameMs: frameMs);
  Object? error;
  var port = RawReceivePort();
  port.handler = (Object? message) {
    if (message is (RawVideoFrame, int)) {
      if (error == null) {
        try {
          writer.add(message.$1, message.$2);
        } catch (e) {
          error = e;
        }
      }
      reply.send(GifEncodeWorker._frameDone);
      return;
    }
    port.close();
    GifEncodeResult result;
    try {
      result = writer.finish();
    } catch (e) {
      error ??= e;
      result = const GifEncodeResult(frames: 0, durationMs: 0, encodeMicros: 0);
    }
    if (error != null) {
      result = GifEncodeResult(
        frames: result.frames,
        durationMs: result.durationMs,
        encodeMicros: result.encodeMicros,
        error: "$error",
      );
    }
    Isolate.exit(reply, result);
  };
  reply.send(port.sendPort);
}

/// 把一帧帧画面编成 GIF（package:image 的 GifEncoder，每帧单独配调色板），
/// 边编边写进文件。宽 [width]（比视频窄时用视频的宽），高按第一帧的比例；
/// 一直循环
class GifFileWriter {
  GifFileWriter(String path, {this.width = 480, this.frameMs = 100})
      : _file = File(path).openSync(mode: FileMode.write);

  final int width;

  /// 最后一帧显示多久（毫秒）
  final int frameMs;
  final RandomAccessFile _file;

  /// 不抖动：快一半、文件小约三成，帧与帧之间也不会有闪动的噪点
  final img.GifEncoder _encoder = img.GifEncoder(
    repeat: 0,
    dispose: 1,
    dither: img.DitherKernel.none,
  );

  /// 先压一帧：等下一帧来了才知道这一帧显示多久
  img.Image? _held;
  int _heldAt = 0;
  int _firstAt = 0;
  int _w = 0;
  int _h = 0;
  int frames = 0;
  int encodeMicros = 0;

  void add(RawVideoFrame frame, int atMs) {
    var watch = Stopwatch()..start();
    if (_w == 0) {
      _w = math.min(width, frame.width);
      _h = math.max(1, (frame.height * _w / frame.width).round());
      _firstAt = atMs;
    }
    var rgb = downscaleBgr0(
        frame.bytes, frame.width, frame.height, frame.stride, _w, _h);
    var image = img.Image.fromBytes(
      width: _w,
      height: _h,
      bytes: rgb.buffer,
      numChannels: 3,
    );
    var held = _held;
    if (held != null) {
      _encoder.addFrame(held, duration: _delay(_heldAt, atMs));
      _flush();
    }
    _held = image;
    _heldAt = atMs;
    frames++;
    encodeMicros += watch.elapsedMicroseconds;
  }

  /// 一帧显示多久（1/100 秒）：从第一帧算起取整，误差不累积；最少 2（再短浏览器按 10 算）
  int _delay(int from, int to) => math.max(2, _cs(to) - _cs(from));

  int _cs(int ms) => (ms - _firstAt + 5) ~/ 10;

  GifEncodeResult finish() {
    var watch = Stopwatch()..start();
    try {
      var held = _held;
      if (held != null) {
        _encoder.addFrame(held, duration: math.max(2, (frameMs + 5) ~/ 10));
        var tail = _encoder.finish();
        if (tail != null) {
          _file.writeFromSync(tail);
        }
      }
    } finally {
      _file.closeSync();
    }
    encodeMicros += watch.elapsedMicroseconds;
    return GifEncodeResult(
      frames: frames,
      durationMs: frames == 0 ? 0 : _heldAt - _firstAt + frameMs,
      encodeMicros: encodeMicros,
    );
  }

  /// 编好的部分写进文件，缓冲区从头用
  void _flush() {
    var out = _encoder.output;
    if (out != null && out.length > 0) {
      _file.writeFromSync(out.getBytes());
      out.rewind();
    }
  }
}

/// BGR0 缩成 RGB：每个目标像素取原图对应那一块的平均
Uint8List downscaleBgr0(
  Uint8List src,
  int srcWidth,
  int srcHeight,
  int stride,
  int width,
  int height,
) {
  var out = Uint8List(width * height * 3);
  var xs = Int32List(width + 1);
  for (var x = 0; x <= width; x++) {
    xs[x] = x * srcWidth ~/ width;
  }
  var o = 0;
  for (var y = 0; y < height; y++) {
    var y0 = y * srcHeight ~/ height;
    var y1 = math.max(y0 + 1, (y + 1) * srcHeight ~/ height);
    for (var x = 0; x < width; x++) {
      var x0 = xs[x];
      var x1 = math.max(x0 + 1, xs[x + 1]);
      var b = 0, g = 0, r = 0;
      for (var yy = y0; yy < y1; yy++) {
        var row = yy * stride;
        for (var i = row + x0 * 4, end = row + x1 * 4; i < end; i += 4) {
          b += src[i];
          g += src[i + 1];
          r += src[i + 2];
        }
      }
      var n = (y1 - y0) * (x1 - x0);
      out[o++] = r ~/ n;
      out[o++] = g ~/ n;
      out[o++] = b ~/ n;
    }
  }
  return out;
}
