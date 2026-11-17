import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 视频信息浮层读取的 mpv 属性及显示格式。
/// mpv 以字符串返回属性值，读不到时为空字符串，统一显示为 [empty]
class VideoStats {
  static const String empty = "-";

  static const List<String> properties = [
    "video-params/w",
    "video-params/h",
    "estimated-vf-fps",
    "container-fps",
    "video-bitrate",
    "audio-bitrate",
    "video-format",
    "video-codec",
    "hwdec-current",
    "frame-drop-count",
    "decoder-frame-drop-count",
    "demuxer-cache-duration",
    "cache-speed",
  ];

  static double? _number(String? raw) {
    var value = double.tryParse(raw?.trim() ?? "");
    if (value == null || value.isNaN || value.isInfinite) {
      return null;
    }
    return value;
  }

  /// 去掉小数末尾的 0：60.00 → 60，59.90 → 59.9
  static String _trimZeros(String text) {
    if (!text.contains(".")) {
      return text;
    }
    return text.replaceFirst(RegExp(r'\.?0+$'), "");
  }

  /// 1920×1080
  static String resolution(String? width, String? height) {
    var w = _number(width);
    var h = _number(height);
    if (w == null || h == null || w <= 0 || h <= 0) {
      return empty;
    }
    return "${w.round()}×${h.round()}";
  }

  /// 实际输出帧率（estimated-vf-fps），刚开始播放还没有时用容器标称帧率
  static String fps(String? estimated, String? container) {
    var value = _number(estimated);
    if (value == null || value <= 0) {
      value = _number(container);
    }
    if (value == null || value <= 0) {
      return empty;
    }
    return "${_trimZeros(value.toStringAsFixed(2))} fps";
  }

  /// 码率：mpv 给出的是 bit/s
  static String bitrate(String? raw) {
    var value = _number(raw);
    if (value == null || value < 0) {
      return empty;
    }
    if (value < 1000) {
      return "${value.round()} bps";
    }
    var kbps = value / 1000;
    if (kbps.round() < 1000) {
      return "${kbps.round()} kbps";
    }
    return "${(kbps / 1000).toStringAsFixed(2)} Mbps";
  }

  /// 下载速度：mpv 的 cache-speed 单位是 字节/秒
  static String speed(String? raw) {
    var value = _number(raw);
    if (value == null || value < 0) {
      return empty;
    }
    if (value < 1024) {
      return "${value.round()} B/s";
    }
    var kb = value / 1024;
    if (kb < 1024) {
      return "${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB/s";
    }
    return "${(kb / 1024).toStringAsFixed(2)} MB/s";
  }

  /// 缓冲时长（秒）：10 秒以内保留一位小数
  static String seconds(String? raw) {
    var value = _number(raw);
    if (value == null || value < 0) {
      return empty;
    }
    return value < 10 ? "${value.toStringAsFixed(1)}s" : "${value.round()}s";
  }

  /// 编码与解码器：h264 · d3d11va；hwdec-current 为 no 表示软件解码。
  /// video-format 是简短的编码名，没有时取 video-codec 括号前的部分
  static String codec(String? format, String? codec, String? hwdec) {
    var name = format?.trim() ?? "";
    if (name.isEmpty) {
      name = (codec ?? "").split("(").first.trim();
    }
    var hw = hwdec?.trim() ?? "";
    var decoder = hw.isEmpty
        ? ""
        : hw == "no"
            ? "软解".t
            : hw;
    var parts = [name, decoder].where((e) => e.isNotEmpty);
    return parts.isEmpty ? empty : parts.join(" · ");
  }

  /// 丢帧：输出丢帧 + 解码丢帧
  static String drops(String? output, String? decoder) {
    var a = int.tryParse(output?.trim() ?? "");
    var b = int.tryParse(decoder?.trim() ?? "");
    if (a == null && b == null) {
      return empty;
    }
    return "${(a ?? 0) + (b ?? 0)}";
  }

  /// 浮层上的各行（名称, 值）
  static List<(String, String)> lines(Map<String, String> v) {
    return [
      ("分辨率".t, resolution(v["video-params/w"], v["video-params/h"])),
      ("帧率".t, fps(v["estimated-vf-fps"], v["container-fps"])),
      ("视频码率".t, bitrate(v["video-bitrate"])),
      ("音频码率".t, bitrate(v["audio-bitrate"])),
      ("编解码".t, codec(v["video-format"], v["video-codec"], v["hwdec-current"])),
      ("丢帧".t, drops(v["frame-drop-count"], v["decoder-frame-drop-count"])),
      ("缓冲".t, seconds(v["demuxer-cache-duration"])),
      ("下载速度".t, speed(v["cache-speed"])),
    ];
  }
}

/// 播放器左上角的视频信息（帧率、码率等），在设置中开关。
/// 只在显示时每秒读取一次；页面被盖住时暂停读取。
/// 不拦截手势，位置由外层 Positioned 决定
class VideoStatsOverlay extends StatefulWidget {
  final Player player;
  const VideoStatsOverlay({required this.player, super.key});

  @override
  State<VideoStatsOverlay> createState() => _VideoStatsOverlayState();
}

class _VideoStatsOverlayState extends State<VideoStatsOverlay> {
  static final TextStyle _style = TextStyle(
    fontSize: 11,
    height: 1.25,
    color: Colors.white.withAlpha(230),
    fontFamily: Platform.isWindows
        ? "Consolas"
        : Platform.isIOS || Platform.isMacOS
            ? "Menlo"
            : "monospace",
    fontFamilyFallback: Platform.isWindows ? const ["Microsoft YaHei"] : null,
    fontFeatures: const [FontFeature.tabularFigures()],
    shadows: const [Shadow(blurRadius: 2)],
  );

  Timer? _timer;
  Worker? _worker;
  bool _tickerEnabled = true;
  bool _reading = false;
  List<(String, String)> _lines = VideoStats.lines(const {});

  bool get _enabled => AppSettingsController.instance.playerVideoStats.value;

  @override
  void initState() {
    super.initState();
    _worker = ever<bool>(
      AppSettingsController.instance.playerVideoStats,
      (_) => _sync(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  /// 显示时开始定时读取，隐藏时停止
  void _sync() {
    var active = mounted && _enabled && _tickerEnabled;
    if (active && _timer == null) {
      _read();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _read());
    } else if (!active && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  Future<String> _property(NativePlayer native, String name) async {
    try {
      return await native.getProperty(name);
    } catch (_) {
      // 播放器已释放或属性不可用
      return "";
    }
  }

  Future<void> _read() async {
    var native = widget.player.platform;
    if (_reading || native is! NativePlayer) {
      return;
    }
    _reading = true;
    try {
      var values = await Future.wait(
        VideoStats.properties.map((e) => _property(native, e)),
      );
      if (!mounted || _timer == null) {
        return;
      }
      setState(() {
        _lines = VideoStats.lines(
          Map.fromIterables(VideoStats.properties, values),
        );
      });
    } finally {
      _reading = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _worker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!_enabled) {
        return const SizedBox.shrink();
      }
      return IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(110),
            borderRadius: BorderRadius.circular(4),
          ),
          child: DefaultTextStyle(
            style: _style,
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              children: [
                for (var (label, value) in _lines)
                  TableRow(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(label),
                      ),
                      Text(value),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }
}
