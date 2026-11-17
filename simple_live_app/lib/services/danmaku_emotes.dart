import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:extended_image/extended_image.dart'
    show getNetworkImageData, keyToMd5, ExtendedNetworkImageProvider;
import 'package:flutter/widgets.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 表情图片在 extended_image 磁盘缓存里的文件名（[LiveEmote.cacheKey] 的 md5，
/// 键里可能有“/”），没有缓存键时为 null（按地址缓存）。聊天栏和视频弹幕共用
String? emoteCacheKey(LiveEmote emote) {
  var key = emote.cacheKey;
  return key == null || key.isEmpty ? null : keyToMd5(key);
}

/// 视频弹幕里的表情图片。
///
/// 弹幕画在画布上，图片要先解码成 ui.Image，这里按“地址 + 解码高度”缓存：
/// - 按显示大小解码（行内表情约一个字高，大表情两行高，乘以屏幕像素比），
///   不按原图；动图只取第一帧；
/// - 解码后的图片总共不超过 [maxBytes]、[maxEntries] 张，最近最少用的先淘汰并释放。
///   屏幕上的弹幕各自 clone 了一份（canvas_danmaku 的补丁），淘汰不影响正在显示的；
/// - 原图走 extended_image 的磁盘缓存，和聊天栏的表情共用；
/// - 同时最多下载 [maxLoading] 张，其余排队（最多 [maxQueued] 张，排满时放弃最早的），
///   失败的地址 10 分钟内不再尝试。
///
/// 表情图片还没解码好时，弹幕先等一小会儿（[prepare]），
/// 还没好的表情显示为文字，之后再出现时就是图片。
/// 一批弹幕一起到达时（如 Steam 每 4 秒拉一次聊天）里面可能有很多张没见过的表情，
/// 排队的也在等待时间内下载，不会因为同时下载的已经够多就直接显示为文字。
class DanmakuEmotes {
  DanmakuEmotes._();
  static final DanmakuEmotes instance = DanmakuEmotes._();

  static const int maxBytes = 16 * 1024 * 1024;
  static const int maxEntries = 400;
  static const int maxLoading = 6;
  static const int maxQueued = 64;

  /// 一条弹幕里最多显示几张图片，其余显示为文字
  static const int maxImagesPerItem = 12;

  /// 行内表情的高度（相对字号），与 canvas_danmaku 的 Utils.emoteScale 相同
  static const double _emoteScale = 1.15;

  /// 大表情占两行
  static const double _stickerScale = 2.4;

  final LinkedHashMap<String, ui.Image> _images = LinkedHashMap();
  int _bytes = 0;
  final Map<String, Future<void>> _loading = {};

  /// 排队等下载的：键 → (表情, 解码高度, 下载完成时完成)
  final LinkedHashMap<String, (LiveEmote, int, Completer<void>)> _queued =
      LinkedHashMap();
  final LinkedHashMap<String, DateTime> _failed = LinkedHashMap();

  bool get enabled => AppSettingsController.instance.danmuEmoteImage.value;

  double get _dpr {
    try {
      return WidgetsBinding
              .instance.platformDispatcher.implicitView?.devicePixelRatio ??
          2;
    } catch (_) {
      return 2;
    }
  }

  /// 解码高度（像素），按 8 取整，字号微调时不用重新解码
  int _px(double scale) {
    var settings = AppSettingsController.instance;
    var raw =
        settings.danmuSizeMax * settings.effectiveEmoteScale * scale * _dpr;
    return ((raw / 8).ceil() * 8).clamp(16, 256);
  }

  String _key(String url, int px) => "$px|$url";

  ui.Image? _get(String url, int px) {
    var key = _key(url, px);
    var image = _images.remove(key);
    if (image != null) {
      // 移到最后：最近使用
      _images[key] = image;
    }
    return image;
  }

  bool _recentlyFailed(String url) {
    var time = _failed[url];
    if (time == null) {
      return false;
    }
    if (DateTime.now().difference(time) < const Duration(minutes: 10)) {
      return true;
    }
    _failed.remove(url);
    return false;
  }

  /// 需要的图片：(表情, 解码高度)，按 [frameUrl] 去重，最多 [maxImagesPerItem] 张
  List<(LiveEmote, int)> _wanted(
    String text,
    List<LiveEmote>? emotes,
    LiveEmote? sticker,
  ) {
    if (!enabled) {
      return const [];
    }
    if (sticker != null) {
      return [(sticker, _px(_stickerScale))];
    }
    if (emotes == null || emotes.isEmpty) {
      return const [];
    }
    var px = _px(_emoteScale);
    var wanted = <String, LiveEmote>{};
    for (var part in splitLiveEmotes(text, emotes)) {
      if (part.isEmote) {
        wanted.putIfAbsent(frameUrl(part.emote!), () => part.emote!);
        if (wanted.length >= maxImagesPerItem) {
          break;
        }
      }
    }
    return [for (var emote in wanted.values) (emote, px)];
  }

  /// 弹幕需要的表情图片都已解码好（或不需要、加载失败过），可以直接 [build]
  bool isReady(String text, {List<LiveEmote>? emotes, LiveEmote? sticker}) {
    for (var (emote, px) in _wanted(text, emotes, sticker)) {
      var url = frameUrl(emote);
      if (!_images.containsKey(_key(url, px)) && !_recentlyFailed(url)) {
        return false;
      }
    }
    return true;
  }

  /// 开始加载弹幕需要的表情图片，最多等 [wait]，不会抛出异常。
  /// 没见过的表情要下载：新连接（TLS 握手 + 下载 + 写磁盘缓存 + 解码）实测约 0.15～0.3 秒，
  /// 进直播间时和播放器、头像一起下载会更久，所以最多等 0.6 秒
  Future<void> prepare(
    String text, {
    List<LiveEmote>? emotes,
    LiveEmote? sticker,
    Duration wait = const Duration(milliseconds: 600),
  }) async {
    var futures = [
      for (var (emote, px) in _wanted(text, emotes, sticker))
        if (!_images.containsKey(_key(frameUrl(emote), px))) _load(emote, px),
    ];
    if (futures.isEmpty) {
      return;
    }
    try {
      await Future.wait(futures).timeout(wait);
    } catch (_) {
      // 超时：没好的表情先显示为文字
    }
  }

  /// 生成弹幕：已解码好的表情显示为图片，其余为文字（同时开始加载，下次就有了）。
  DanmakuContentItem build(
    String text, {
    List<LiveEmote>? emotes,
    LiveEmote? sticker,
    Color color = const Color(0xffffffff),
    DanmakuItemType type = DanmakuItemType.scroll,
  }) {
    DanmakuContentItem plain() => DanmakuContentItem(
          text,
          color: color,
          type: type,
        );
    if (!enabled) {
      return plain();
    }
    if (sticker != null) {
      var px = _px(_stickerScale);
      var image = _get(frameUrl(sticker), px);
      if (image == null) {
        _load(sticker, px);
        return plain();
      }
      return DanmakuContentItem(
        text,
        color: color,
        type: type,
        sticker: true,
        segments: [DanmakuSegment.image(image)],
      );
    }
    if (emotes == null || emotes.isEmpty) {
      return plain();
    }
    var px = _px(_emoteScale);
    var segments = <DanmakuSegment>[];
    var buffer = StringBuffer();
    var count = 0;
    for (var part in splitLiveEmotes(text, emotes)) {
      ui.Image? image;
      if (part.isEmote && count < maxImagesPerItem) {
        image = _get(frameUrl(part.emote!), px);
        if (image == null) {
          _load(part.emote!, px);
        }
      }
      if (image == null) {
        buffer.write(part.text);
        continue;
      }
      if (buffer.isNotEmpty) {
        segments.add(DanmakuSegment.text(buffer.toString()));
        buffer.clear();
      }
      segments.add(DanmakuSegment.image(image));
      count++;
    }
    if (count == 0) {
      return plain();
    }
    if (buffer.isNotEmpty) {
      segments.add(DanmakuSegment.text(buffer.toString()));
    }
    return DanmakuContentItem(
      text,
      color: color,
      type: type,
      segments: segments,
    );
  }

  /// 下载并解码一张表情；同时下载的已经有 [maxLoading] 张时排队，有空位再下载
  Future<void> _load(LiveEmote emote, int px) {
    var url = frameUrl(emote);
    var key = _key(url, px);
    var running = _loading[key] ?? _queued[key]?.$3.future;
    if (running != null) {
      return running;
    }
    if (_recentlyFailed(url)) {
      return Future.value();
    }
    if (_loading.length < maxLoading) {
      return _start(emote, url, key, px);
    }
    var done = Completer<void>();
    _queued[key] = (emote, px, done);
    while (_queued.length > maxQueued) {
      // 排太多时放弃最早的：它们的弹幕早已显示为文字
      _queued.remove(_queued.keys.first)!.$3.complete();
    }
    return done.future;
  }

  /// 测试用：代替下载和解码
  @visibleForTesting
  static Future<ui.Image?> Function(String url, int px)? debugDecode;

  Future<void> _start(LiveEmote emote, String url, String key, int px) {
    var decode = debugDecode?.call(url, px) ?? _decode(emote, url, px);
    var future = decode.then((image) {
      if (image == null) {
        _markFailed(url);
      } else {
        _put(key, image);
      }
    }).catchError((Object _) {
      _markFailed(url);
    }).whenComplete(() {
      _loading.remove(key);
      _startQueued();
    });
    _loading[key] = future;
    return future;
  }

  /// 有空位时按排队的顺序开始下载
  void _startQueued() {
    while (_loading.length < maxLoading && _queued.isNotEmpty) {
      var key = _queued.keys.first;
      var (emote, px, done) = _queued.remove(key)!;
      var url = frameUrl(emote);
      if (_images.containsKey(key) || _recentlyFailed(url)) {
        done.complete();
        continue;
      }
      _start(emote, url, key, px).whenComplete(done.complete);
    }
  }

  void _markFailed(String url) {
    _failed.remove(url);
    _failed[url] = DateTime.now();
    while (_failed.length > 200) {
      _failed.remove(_failed.keys.first);
    }
  }

  /// 视频弹幕要解码的地址。只画第一帧，动图的第一帧可能是空白，
  /// 有静态版本时用它：平台给出的 [LiveEmote.staticUrl]，
  /// 或者 Twitch 原生表情的 /static/ 地址；都没有时就是 [LiveEmote.url]
  static String frameUrl(LiveEmote emote) {
    var staticUrl = emote.staticUrl;
    if (staticUrl != null && staticUrl.isNotEmpty) {
      return staticUrl;
    }
    var url = emote.url;
    if (url.startsWith("https://static-cdn.jtvnw.net/emoticons/")) {
      return url.replaceFirst("/default/", "/static/");
    }
    return url;
  }

  /// 磁盘缓存的文件名：表情带了 [LiveEmote.cacheKey]（地址会变、图片不变）
  /// 而且要的就是 [LiveEmote.url] 时按它，和聊天栏的 [emoteCacheKey] 一样
  static String? _diskKey(LiveEmote emote, String url) =>
      url == emote.url ? emoteCacheKey(emote) : null;

  /// 下载（或读磁盘缓存）并按 [px] 高度解码第一帧
  Future<ui.Image?> _decode(LiveEmote emote, String url, int px) async {
    var diskKey = _diskKey(emote, url);
    var bytes = diskKey == null
        ? await getNetworkImageData(url)
        : await ExtendedNetworkImageProvider(
            url,
            cache: true,
            cacheKey: diskKey,
          ).getNetworkImageData();
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    var buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    var codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) {
        if (width <= 0 || height <= 0) {
          return const ui.TargetImageSize();
        }
        // 不放大；特别宽的图按 8 倍高度限制宽度
        var h = min(height, px);
        var w = max(1, (width * h / height).round());
        if (w > h * 8) {
          w = h * 8;
          h = max(1, (height * w / width).round());
        }
        return ui.TargetImageSize(width: w, height: h);
      },
    );
    try {
      var frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  _MemoryPressureObserver? _observer;

  void _put(String key, ui.Image image) {
    if (_observer == null) {
      _observer = _MemoryPressureObserver();
      WidgetsBinding.instance.addObserver(_observer!);
    }
    var old = _images.remove(key);
    if (old != null) {
      _bytes -= _sizeOf(old);
      old.dispose();
    }
    _images[key] = image;
    _bytes += _sizeOf(image);
    while (_images.length > 1 &&
        (_bytes > maxBytes || _images.length > maxEntries)) {
      var first = _images.keys.first;
      var evicted = _images.remove(first)!;
      _bytes -= _sizeOf(evicted);
      evicted.dispose();
    }
  }

  static int _sizeOf(ui.Image image) => image.width * image.height * 4;

  /// 测试用：把解码好的图片放进缓存（交给缓存持有）
  @visibleForTesting
  void debugPut(String url, ui.Image image, {bool sticker = false}) =>
      _put(_key(url, _px(sticker ? _stickerScale : _emoteScale)), image);

  @visibleForTesting
  int get debugLength => _images.length;

  /// 释放全部（系统提示内存紧张时）；屏幕上的弹幕有自己的 clone，不受影响
  void clear() {
    for (var image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _bytes = 0;
  }
}

class _MemoryPressureObserver with WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() {
    DanmakuEmotes.instance.clear();
  }
}
