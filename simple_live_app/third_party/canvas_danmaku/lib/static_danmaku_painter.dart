import 'package:flutter/material.dart';
import 'models/danmaku_item.dart';
import '/utils/utils.dart';

class StaticDanmakuPainter extends CustomPainter {
  final double progress;
  final List<DanmakuItem> topDanmakuItems;
  final List<DanmakuItem> buttomDanmakuItems;
  final int danmakuDurationInSeconds;
  final double fontSize;
  final int fontWeight;
  final bool showStroke;
  final double danmakuHeight;
  final bool running;
  final int tick;
  final Paint selfSendPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..color = Colors.green;

  StaticDanmakuPainter(
      this.progress,
      this.topDanmakuItems,
      this.buttomDanmakuItems,
      this.danmakuDurationInSeconds,
      this.fontSize,
      this.fontWeight,
      this.showStroke,
      this.danmakuHeight,
      this.running,
      this.tick);

  @override
  void paint(Canvas canvas, Size size) {
    // 绘制顶部弹幕
    for (var item in topDanmakuItems) {
      item.xPosition = (size.width - item.width) / 2;
      // 如果 Paragraph 没有缓存，则创建并缓存它
      item.paragraph ??= Utils.generateParagraph(
          item.content, size.width, fontSize, fontWeight,
          stickerHeight: item.stickerHeight,
          emoteHeight: fontSize * item.emoteFactor);

      // 黑色部分
      if (showStroke) {
        item.strokeParagraph ??= Utils.generateStrokeParagraph(
            item.content, size.width, fontSize, fontWeight,
            stickerHeight: item.stickerHeight,
            emoteHeight: fontSize * item.emoteFactor);

        canvas.drawParagraph(
            item.strokeParagraph!, Offset(item.xPosition, item.yPosition));
      }

      if (item.content.selfSend) {
        canvas.drawRect(
            Offset(item.xPosition, item.yPosition).translate(-2, 2) &
                (Size(item.width, item.height) + const Offset(4, 0)),
            selfSendPaint);
      }
      // 白色部分
      canvas.drawParagraph(
          item.paragraph!, Offset(item.xPosition, item.yPosition));
      Utils.drawImages(canvas, item, Offset(item.xPosition, item.yPosition));
    }
    // 绘制底部弹幕 (翻转绘制)
    for (var item in buttomDanmakuItems) {
      item.xPosition = (size.width - item.width) / 2;
      // 如果 Paragraph 没有缓存，则创建并缓存它
      item.paragraph ??= Utils.generateParagraph(
          item.content, size.width, fontSize, fontWeight,
          stickerHeight: item.stickerHeight,
          emoteHeight: fontSize * item.emoteFactor);

      // 黑色部分
      if (showStroke) {
        item.strokeParagraph ??= Utils.generateStrokeParagraph(
            item.content, size.width, fontSize, fontWeight,
            stickerHeight: item.stickerHeight,
            emoteHeight: fontSize * item.emoteFactor);

        canvas.drawParagraph(
            item.strokeParagraph!,
            Offset(item.xPosition,
                (size.height - item.yPosition - danmakuHeight)));
      }

      if (item.content.selfSend) {
        canvas.drawRect(
            Offset(item.xPosition,
                        (size.height - item.yPosition - danmakuHeight))
                    .translate(-2, 2) &
                (Size(item.width, item.height) + const Offset(4, 0)),
            selfSendPaint);
      }

      // 白色部分
      canvas.drawParagraph(item.paragraph!,
          Offset(item.xPosition, size.height - item.yPosition - danmakuHeight));
      Utils.drawImages(canvas, item,
          Offset(item.xPosition, size.height - item.yPosition - danmakuHeight));
    }
  }

  @override
  bool shouldRepaint(covariant StaticDanmakuPainter oldDelegate) {
    return true;
  }

  // SimpleLive: 弹幕没有无障碍内容。默认跟着 shouldRepaint 每帧重建无障碍树，
  // Windows 上还要同步给系统，白白占用主线程
  @override
  bool shouldRebuildSemantics(covariant CustomPainter oldDelegate) => false;
}
