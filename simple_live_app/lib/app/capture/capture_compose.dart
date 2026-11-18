import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:simple_live_app/app/capture/capture_settings.dart';

/// 盖在视频上的层，按屏幕上的上下顺序画：视频、语聊房画面、弹幕、视频信息、
/// 连麦标签、SC、礼物
const List<CaptureLayer> captureOverlayOrder = [
  CaptureLayer.voiceRoom,
  CaptureLayer.danmaku,
  CaptureLayer.videoStats,
  CaptureLayer.linkMic,
  CaptureLayer.superChat,
  CaptureLayer.gifts,
];

/// 截图的像素上限：长边、总像素（40 MP）
const double captureMaxSide = 8192;
const double captureMaxPixels = 40000000;

/// 拼图里的一块：[dst] 是在成图里的位置（逻辑像素），[index] 是同一层里的第几个
/// （SC、礼物卡片可能同时有好几张）。[CaptureLayer.player] 这一块是“涂黑再画视频帧”
class CapturePiece {
  final CaptureLayer layer;
  final Rect dst;
  final int index;
  const CapturePiece(this.layer, this.dst, [this.index = 0]);

  @override
  String toString() => "CapturePiece($layer#$index, $dst)";
}

/// 一张截图怎么拼：成图大小、放大倍数、视频画在哪、各块的位置（按画的顺序）
class CapturePlan {
  /// 成图大小（逻辑像素），乘 [scale] 是实际像素
  final Size size;
  final double scale;

  /// 播放器区域在成图里的位置
  final Rect player;

  /// 视频帧取哪一块（帧的像素）、画到哪（逻辑像素，相对播放器区域）；没有帧时为 null
  final Rect? videoSrc;
  final Rect? videoDst;

  /// 按画的顺序：整个页面（完整窗口时）、播放器（视频帧）、弹幕、视频信息、礼物和 SC、侧栏
  final List<CapturePiece> pieces;

  const CapturePlan({
    required this.size,
    required this.scale,
    required this.player,
    required this.pieces,
    this.videoSrc,
    this.videoDst,
  });

  List<CaptureLayer> get order => [for (var e in pieces) e.layer];

  int get pixelWidth => math.max(1, (size.width * scale).round());
  int get pixelHeight => math.max(1, (size.height * scale).round());
}

/// 视频在播放器里的位置，和 media_kit 的 Video 一样：给了 [aspectRatio] 时
/// 按这个比例拉伸后再按 [fit] 居中放进去。返回（帧里取的部分, 画到的位置）
(Rect, Rect) videoRectIn(
  Size area,
  Size frame, {
  BoxFit fit = BoxFit.contain,
  double? aspectRatio,
}) {
  var virtual = aspectRatio != null && aspectRatio > 0
      ? Size(frame.height * aspectRatio, frame.height)
      : frame;
  var fitted = applyBoxFit(fit, virtual, area);
  var dst = Alignment.center.inscribe(fitted.destination, Offset.zero & area);
  var srcVirtual =
      Alignment.center.inscribe(fitted.source, Offset.zero & virtual);
  var sx = frame.width / virtual.width;
  var src = Rect.fromLTRB(
    srcVirtual.left * sx,
    srcVirtual.top,
    srcVirtual.right * sx,
    srcVirtual.bottom,
  );
  return (src, dst);
}

/// 算出拼图的方案。
///
/// 所有位置都是屏幕上的（逻辑像素）。[page] 不为空时是“完整窗口”：成图是整个页面，
/// 页面截图（侧栏没选时已经藏掉）垫在最下面；否则成图是播放器区域，选了侧栏时
/// 侧栏紧挨着放在右边（手机竖屏时在下面），中间隔着的东西不要。
/// 只有 [chosen] 里、屏幕上又看得见（[overlays] 里有位置）的层才画。
/// 放大倍数：[imageSize] 是原画时取屏幕的倍数和视频原始清晰度里大的那个，
/// 和屏幕一样时只用屏幕的倍数；成图长边不超过 [captureMaxSide]、
/// 总像素不超过 [captureMaxPixels]
CapturePlan planCapture({
  required Rect player,
  required Set<CaptureLayer> chosen,
  Map<CaptureLayer, List<Rect>> overlays = const {},
  Rect? panel,
  Rect? page,
  Size? frame,
  BoxFit fit = BoxFit.contain,
  double? aspectRatio,
  double devicePixelRatio = 1,
  CaptureImageSize imageSize = CaptureImageSize.source,
}) {
  var area = player.size;
  Rect? videoSrc;
  Rect? videoDst;
  var scale = devicePixelRatio;
  if (frame != null && !frame.isEmpty && !area.isEmpty) {
    (videoSrc, videoDst) =
        videoRectIn(area, frame, fit: fit, aspectRatio: aspectRatio);
    if (imageSize == CaptureImageSize.source && videoDst.width > 0) {
      scale = math.max(scale, videoSrc.width / videoDst.width);
    }
  }
  var origin = page?.topLeft ?? player.topLeft;
  var playerRect = player.shift(-origin);
  var pieces = <CapturePiece>[
    if (page != null) CapturePiece(CaptureLayer.page, Offset.zero & page.size),
    CapturePiece(CaptureLayer.player, playerRect),
  ];
  for (var layer in captureOverlayOrder) {
    if (!chosen.contains(layer)) {
      continue;
    }
    var rects = overlays[layer] ?? const [];
    for (var i = 0; i < rects.length; i++) {
      if (!rects[i].isEmpty) {
        pieces.add(CapturePiece(layer, rects[i].shift(-origin), i));
      }
    }
  }
  var size = page?.size ?? area;
  if (page == null &&
      panel != null &&
      !panel.isEmpty &&
      chosen.contains(CaptureLayer.sidePanel)) {
    // 在播放器下面（手机竖屏）时放下面，别的情况放右边
    var below = panel.top >= player.bottom - 1 && panel.left < player.right - 1;
    var dst = below
        ? Rect.fromLTWH(0, area.height, panel.width, panel.height)
        : Rect.fromLTWH(area.width, 0, panel.width, panel.height);
    pieces.add(CapturePiece(CaptureLayer.sidePanel, dst));
    size = Size(
      math.max(area.width, dst.right),
      math.max(area.height, dst.bottom),
    );
  }
  var longest = math.max(size.width, size.height);
  if (longest > 0 && longest * scale > captureMaxSide) {
    scale = captureMaxSide / longest;
  }
  var logicalPixels = size.width * size.height;
  if (logicalPixels > 0 && logicalPixels * scale * scale > captureMaxPixels) {
    scale = math.sqrt(captureMaxPixels / logicalPixels);
  }
  return CapturePlan(
    size: size,
    scale: scale,
    player: playerRect,
    pieces: pieces,
    videoSrc: videoSrc,
    videoDst: videoDst,
  );
}

/// 按 [plan] 画出成图：页面截图垫底（完整窗口时），播放器区域涂黑后画视频帧，
/// 叠上各层（只在播放器区域里）；侧栏先涂 [panelBackground] 再画（它自己多半是透明底）。
/// [images] 是各块（plan.pieces 里的）截到的图
Future<ui.Image> paintCapture(
  CapturePlan plan, {
  ui.Image? video,
  Map<CapturePiece, ui.Image> images = const {},
  Color panelBackground = const Color(0xFFFFFFFF),
}) async {
  var recorder = ui.PictureRecorder();
  var canvas = Canvas(recorder);
  canvas.scale(plan.scale);
  var paint = Paint()..filterQuality = FilterQuality.medium;
  for (var piece in plan.pieces) {
    if (piece.layer == CaptureLayer.player) {
      canvas.drawRect(piece.dst, Paint()..color = const Color(0xFF000000));
      if (video != null && plan.videoSrc != null && plan.videoDst != null) {
        canvas.save();
        canvas.clipRect(piece.dst);
        canvas.drawImageRect(
          video,
          plan.videoSrc!,
          plan.videoDst!.shift(piece.dst.topLeft),
          paint,
        );
        canvas.restore();
      }
      continue;
    }
    var image = images[piece];
    if (image == null) {
      continue;
    }
    var src =
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    canvas.save();
    if (piece.layer == CaptureLayer.sidePanel) {
      canvas.drawRect(piece.dst, Paint()..color = panelBackground);
    } else if (piece.layer != CaptureLayer.page) {
      canvas.clipRect(plan.player);
    }
    canvas.drawImageRect(image, src, piece.dst, paint);
    canvas.restore();
  }
  var picture = recorder.endRecording();
  try {
    return await picture.toImage(plan.pixelWidth, plan.pixelHeight);
  } finally {
    picture.dispose();
  }
}

/// 把 mpv 给的 BGR0 原始画面（每行 [rowBytes] 字节）转成图片。
/// 第四个字节是 0，改成 255（不透明）
Future<ui.Image> imageFromBgr0(
  Uint8List bytes,
  int width,
  int height,
  int rowBytes,
) {
  var data = Uint8List.fromList(bytes);
  for (var i = 3; i < data.length; i += 4) {
    data[i] = 255;
  }
  var completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    data,
    width,
    height,
    ui.PixelFormat.bgra8888,
    completer.complete,
    rowBytes: rowBytes,
  );
  return completer.future;
}

/// 编码好的图片（PNG、JPEG）转成图片
Future<ui.Image> imageFromEncoded(Uint8List bytes) async {
  var codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}
