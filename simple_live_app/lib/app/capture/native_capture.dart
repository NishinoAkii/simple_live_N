import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/log.dart';

/// 录屏结束时原生端给的结果
class NativeRecordResult {
  final String path;
  final Duration duration;
  final int bytes;

  /// iOS：已经直接存进了“照片”，不用再问保存
  final bool savedToAlbum;

  /// 录到了声音没有；原生端没说时为 null
  final bool? audio;

  const NativeRecordResult({
    required this.path,
    this.duration = Duration.zero,
    this.bytes = 0,
    this.savedToAlbum = false,
    this.audio,
  });

  static NativeRecordResult? fromMap(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    var path = raw["path"]?.toString() ?? "";
    var ms = raw["durationMs"];
    var bytes = raw["bytes"];
    var audio = raw["audio"];
    return NativeRecordResult(
      path: path,
      duration: Duration(milliseconds: ms is num ? ms.toInt() : 0),
      bytes: bytes is num ? bytes.toInt() : 0,
      savedToAlbum: raw["savedToAlbum"] == true,
      audio: audio is bool ? audio : null,
    );
  }
}

/// 截图、录屏的原生接口（MethodChannel 'simple_live/capture'）。
///
/// Windows、macOS、安卓、iOS 由原生端实现：复制图片和文件、把窗口里的一块录成视频。
/// 没有这个接口（旧版原生端、Linux、测试）时不报错：录屏只剩流录制，复制按不支持处理
class NativeCapture {
  NativeCapture._();

  static const MethodChannel channel = MethodChannel('simple_live/capture');

  static final StreamController<Map<Object?, Object?>> _stopped =
      StreamController.broadcast();
  static bool _handlerSet = false;

  /// 原生端自己停下了录屏（转屏、窗口大小变了、切到后台、到了上限、系统停止等）：
  /// {reason, path, durationMs, bytes, savedToAlbum, audio}，失败时 {reason, error}
  static Stream<Map<Object?, Object?>> get stopped {
    _setHandler();
    return _stopped.stream;
  }

  static void _setHandler() {
    if (_handlerSet || !platformMayHave) {
      return;
    }
    _handlerSet = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onRecordStopped') {
        var args = call.arguments;
        _stopped.add(args is Map ? args : const {});
      }
      return null;
    });
  }

  /// 接口在不在：第一次用时问一下（null = 还没问过）
  static bool? _available;

  /// 有没有 copyGif（null = 还没问过）
  static bool? _gif;

  @visibleForTesting
  static void resetForTest() => _available = _gif = null;

  /// 原生端可能实现了接口的平台
  static bool get platformMayHave =>
      Platform.isWindows ||
      Platform.isMacOS ||
      Platform.isAndroid ||
      Platform.isIOS;

  /// 接口在不在（问过以后直接给结果）
  static bool get knownAvailable => _available ?? false;

  /// 问一下原生端有没有这个接口
  static Future<bool> probe() async {
    if (_available != null) {
      return _available!;
    }
    if (!platformMayHave) {
      return _available = false;
    }
    try {
      await channel.invokeMethod('recordActive');
      _available = true;
    } on MissingPluginException {
      _available = false;
    } catch (e) {
      // 接口在，只是这次出错了
      Log.logPrint(e);
      _available = true;
    }
    return _available!;
  }

  static Future<T?> _call<T>(String method, [Object? args]) async {
    if (!await probe()) {
      return null;
    }
    try {
      return await channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      _available = false;
      return null;
    }
  }

  /// 把 PNG 放进剪贴板，失败或不支持时返回 false
  static Future<bool> copyImage(Uint8List png) async {
    try {
      return await _call<bool>('copyImage', {'png': png}) ?? false;
    } catch (e) {
      Log.logPrint(e);
      return false;
    }
  }

  /// 把文件放进剪贴板（资源管理器里可以粘贴）
  static Future<bool> copyFiles(List<String> paths) async {
    try {
      return await _call<bool>('copyFiles', {'paths': paths}) ?? false;
    } catch (e) {
      Log.logPrint(e);
      return false;
    }
  }

  /// 原生端有没有 copyGif：用空路径问一下（原生端不碰剪贴板，返回 false）
  static Future<bool> probeGif() async {
    if (_gif != null) {
      return _gif!;
    }
    if (!await probe()) {
      return _gif = false;
    }
    try {
      await channel.invokeMethod('copyGif', {'path': ''});
      _gif = true;
    } on MissingPluginException {
      _gif = false;
    } catch (e) {
      Log.logPrint(e);
      _gif = true;
    }
    return _gif!;
  }

  /// 把 GIF 文件放进剪贴板，支持的应用里粘贴出来是动图
  static Future<bool> copyGif(String path) async {
    try {
      return await _call<bool>('copyGif', {'path': path}) ?? false;
    } catch (e) {
      Log.logPrint(e);
      return false;
    }
  }

  /// 开始录 [rect]（物理像素，相对窗口客户区）。用户拒绝授权等返回 false；
  /// 出错时抛出 [PlatformException]，message 直接给用户看。
  /// [maxSeconds] 是设置里的最长录制时间（0 = 不限），原生端按它设一个稍大的保险上限
  static Future<bool> recordStart({
    required String path,
    required Rect rect,
    int fps = 30,
    bool audio = true,
    int maxSeconds = 0,
    Map<String, Object?> extra = const {},
  }) async {
    _setHandler();
    var ok = await _call<bool>('recordStart', {
      ...extra,
      'path': path,
      'x': rect.left.round(),
      'y': rect.top.round(),
      'width': rect.width.round(),
      'height': rect.height.round(),
      'fps': fps,
      'audio': audio,
      'maxSeconds': maxSeconds,
    });
    return ok ?? false;
  }

  static Future<NativeRecordResult?> recordStop() async {
    var raw = await _call<Object?>('recordStop');
    return NativeRecordResult.fromMap(raw);
  }

  static Future<bool> recordActive() async {
    try {
      return await _call<bool>('recordActive') ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// 剪贴板：Windows、macOS、安卓、iOS 走原生接口（手机上只能复制图片和 GIF）；
/// Linux 有 wl-copy 或 xclip 时用它们
class CaptureClipboard {
  CaptureClipboard._();

  static String? _linuxTool;
  static bool _linuxChecked = false;

  /// Linux 上能用的剪贴板工具（Wayland 优先 wl-copy，X11 用 xclip），没有时为 null
  static Future<String?> _linux() async {
    if (_linuxChecked) {
      return _linuxTool;
    }
    _linuxChecked = true;
    var wayland = (Platform.environment["WAYLAND_DISPLAY"] ?? "").isNotEmpty;
    for (var tool in [if (wayland) "wl-copy", "xclip"]) {
      try {
        var r = await Process.run("which", [tool]);
        if (r.exitCode == 0) {
          return _linuxTool = tool;
        }
      } catch (_) {}
    }
    return null;
  }

  /// 能不能复制截图（不能时不显示“复制”）
  static Future<bool> supported() async {
    if (Platform.isLinux) {
      return await _linux() != null;
    }
    return NativeCapture.probe();
  }

  /// 能不能复制视频文件：手机上不能
  static Future<bool> supportsFiles() async {
    if (Platform.isAndroid || Platform.isIOS) {
      return false;
    }
    return supported();
  }

  /// 能不能把 GIF 当图片复制（粘贴出动图）
  static Future<bool> supportsGif() async {
    if (Platform.isLinux) {
      return await _linux() != null;
    }
    return NativeCapture.probeGif();
  }

  static Future<bool> copyImage(Uint8List png) async {
    if (Platform.isLinux) {
      return _linuxCopy(png, "image/png");
    }
    return NativeCapture.copyImage(png);
  }

  static Future<bool> copyGif(String path) async {
    if (Platform.isLinux) {
      return _linuxCopy(await File(path).readAsBytes(), "image/gif");
    }
    return NativeCapture.copyGif(path);
  }

  static Future<bool> copyFiles(List<String> paths) async {
    if (Platform.isLinux) {
      var uris =
          paths.map((e) => Uri.file(p.absolute(e)).toString()).join("\n");
      return _linuxCopy(Uint8List.fromList(uris.codeUnits), "text/uri-list");
    }
    if (Platform.isWindows || Platform.isMacOS) {
      return NativeCapture.copyFiles(paths);
    }
    return false;
  }

  static Future<bool> _linuxCopy(Uint8List data, String type) async {
    var tool = await _linux();
    if (tool == null) {
      return false;
    }
    try {
      var args = tool == "wl-copy"
          ? ["--type", type]
          : ["-selection", "clipboard", "-t", type, "-i"];
      var process = await Process.start(tool, args);
      process.stdin.add(data);
      await process.stdin.close();
      // wl-copy、xclip 会留在后台守着剪贴板，不等它退出
      var code = await process.exitCode
          .timeout(const Duration(seconds: 2), onTimeout: () => 0);
      return code == 0;
    } catch (e) {
      Log.logPrint(e);
      return false;
    }
  }
}
