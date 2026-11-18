import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/log.dart';

/// 和视频同名的弹幕文件（.ass）：开始时建好，停下时写完
abstract class CaptureSidecar {
  Future<void> stop();
}

/// 流录制：用 mpv 的 stream-record 把收到的视频流原样存下来（不重新编码），
/// 同时记一份同名的 ASS 弹幕。
///
/// 重新打开视频流（换线路、断流重连）时 mpv 会从头重写这个文件，
/// 所以每次重新打开都换一个新文件（名字后面加 _2、_3），弹幕文件也跟着换
class StreamRecordSession {
  /// 设 mpv 的属性（NativePlayer.setProperty）
  final Future<void> Function(String name, String value) setProperty;

  /// 开始记某个文件的弹幕，[assPath] 是和视频同名的 .ass；不记弹幕时为 null
  final Future<CaptureSidecar?> Function(String assPath)? startSidecar;

  StreamRecordSession({required this.setProperty, this.startSidecar});

  static const String property = "stream-record";

  /// 和视频同名的弹幕文件
  static String sidecarPath(String videoPath) =>
      p.setExtension(videoPath, ".ass");

  final List<String> _videos = [];
  final List<String> _sidecarFiles = [];
  CaptureSidecar? _sidecar;
  String? _base;
  bool _active = false;
  StreamSubscription<Object?>? _reopenSub;

  bool get active => _active;

  /// 这次录下的文件（视频和弹幕）
  List<String> get files => [..._videos, ..._sidecarFiles];

  /// 开始录到 [path]（扩展名决定格式，用 .mkv）。[reopened] 每次重新打开视频流时来一个事件
  Future<void> start(String path, {Stream<Object?>? reopened}) async {
    if (_active) {
      return;
    }
    _active = true;
    _base = p.withoutExtension(path);
    await _open(path);
    _reopenSub = reopened?.listen((_) => rotate());
  }

  Future<void> _open(String path) async {
    _videos.add(path);
    await setProperty(property, path);
    var start = startSidecar;
    if (start != null) {
      var ass = sidecarPath(path);
      try {
        _sidecar = await start(ass);
        if (_sidecar != null) {
          _sidecarFiles.add(ass);
        }
      } catch (e) {
        Log.logPrint(e);
        _sidecar = null;
      }
    }
  }

  /// 视频流重新打开了：换到下一个文件
  Future<void> rotate() async {
    if (!_active || _base == null) {
      return;
    }
    await _closeSidecar();
    var ext = p.extension(_videos.first);
    var next = "${_base}_${_videos.length + 1}$ext";
    await _open(next);
  }

  Future<void> _closeSidecar() async {
    var sidecar = _sidecar;
    _sidecar = null;
    if (sidecar != null) {
      try {
        await sidecar.stop();
      } catch (e) {
        Log.logPrint(e);
      }
    }
  }

  /// 停下，返回录到东西的文件（空文件删掉）
  Future<List<String>> stop() async {
    if (!_active) {
      return files;
    }
    _active = false;
    // 先停 mpv（页面关闭时播放器随后就释放了），再取消监听
    try {
      await setProperty(property, "");
    } catch (e) {
      Log.logPrint(e);
    }
    await _reopenSub?.cancel();
    _reopenSub = null;
    await _closeSidecar();
    var kept = <String>[];
    for (var path in files) {
      var file = File(path);
      try {
        if (await file.exists()) {
          if (await file.length() > 0 || path.endsWith(".ass")) {
            kept.add(path);
          } else {
            await file.delete();
          }
        }
      } catch (_) {}
    }
    // 视频一个都没录到时，弹幕文件也不要
    if (!kept.any((e) => !e.endsWith(".ass"))) {
      for (var path in kept) {
        await File(path).delete().catchError((_) => File(path));
      }
      kept.clear();
    }
    return kept;
  }
}
