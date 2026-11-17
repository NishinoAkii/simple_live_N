import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '/models/danmaku_content_item.dart';
import '/models/danmaku_item.dart';

class Utils {
  /// SimpleLive: 行内表情图片的高度（相对字号）
  static const double emoteScale = 1.15;

  static generateParagraph(DanmakuContentItem content, double danmakuWidth,
      double fontSize, int fontWeight,
      {double stickerHeight = 0, double? emoteHeight}) {
    final ui.ParagraphBuilder builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      textAlign: TextAlign.left,
      fontSize: fontSize,
      fontWeight: FontWeight.values[fontWeight],
      textDirection: TextDirection.ltr,
    ))
      ..pushStyle(ui.TextStyle(
        color: content.color,
      ));
    _addContent(builder, content, fontSize, stickerHeight, emoteHeight);
    return builder.build()
      ..layout(ui.ParagraphConstraints(width: danmakuWidth));
  }

  static generateStrokeParagraph(DanmakuContentItem content,
      double danmakuWidth, double fontSize, int fontWeight,
      {double stickerHeight = 0, double? emoteHeight}) {
    final Paint strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.black;

    final ui.ParagraphBuilder strokeBuilder =
        ui.ParagraphBuilder(ui.ParagraphStyle(
      textAlign: TextAlign.left,
      fontSize: fontSize,
      fontWeight: FontWeight.values[fontWeight],
      textDirection: TextDirection.ltr,
    ))
          ..pushStyle(ui.TextStyle(
            foreground: strokePaint,
          ));
    _addContent(strokeBuilder, content, fontSize, stickerHeight, emoteHeight);

    return strokeBuilder.build()
      ..layout(ui.ParagraphConstraints(width: danmakuWidth));
  }

  /// SimpleLive: 文字，或图文混排（图片位置先用占位符留出来，画的时候再画图片）
  static void _addContent(
      ui.ParagraphBuilder builder,
      DanmakuContentItem content,
      double fontSize,
      double stickerHeight,
      double? emoteHeight) {
    final segments = content.segments;
    if (segments == null || segments.isEmpty) {
      builder.addText(content.text);
      return;
    }
    final sticker = content.sticker && stickerHeight > 0;
    final height =
        sticker ? stickerHeight : emoteHeight ?? fontSize * emoteScale;
    for (final segment in segments) {
      if (segment.isImage) {
        builder.addPlaceholder(
          height * segment.aspectRatio,
          height,
          sticker
              ? ui.PlaceholderAlignment.top
              : ui.PlaceholderAlignment.middle,
        );
      } else if (segment.text!.isNotEmpty) {
        builder.addText(segment.text!);
      }
    }
  }

  static final Paint _imagePaint = Paint()
    ..filterQuality = FilterQuality.medium
    ..isAntiAlias = true;

  /// SimpleLive: 在 [paragraph] 的占位符上画出弹幕的图片
  static void drawImages(Canvas canvas, DanmakuItem item, Offset offset) {
    final images = item.images;
    final paragraph = item.paragraph;
    if (images == null || images.isEmpty || paragraph == null) {
      return;
    }
    final rects = item.imageRects ??= [
      for (final box in paragraph.getBoxesForPlaceholders()) box.toRect(),
    ];
    for (var i = 0; i < images.length && i < rects.length; i++) {
      final image = images[i];
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        rects[i].shift(offset),
        _imagePaint,
      );
    }
  }
}
