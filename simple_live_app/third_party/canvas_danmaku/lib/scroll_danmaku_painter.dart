import 'package:flutter/material.dart';
import 'models/danmaku_item.dart';
import '/utils/utils.dart';

class ScrollDanmakuPainter extends CustomPainter {
  final double progress;
  final List<DanmakuItem> scrollDanmakuItems;
  final int danmakuDurationInSeconds;
  final double fontSize;
  final int fontWeight;
  final bool showStroke;
  final double danmakuHeight;
  final bool running;

  /// SimpleLive: 这一帧的时间（毫秒，带小数），取帧的时间戳而不是绘制时的钟点：
  /// 绘制前主线程忙一下（比如排版新来的弹幕），按钟点算的位置就会往前跳，
  /// 而这一帧上屏的时刻并没有变，弹幕看起来一顿一顿的。
  /// 画笔跟着动画自己重画（repaint），不用每帧重建组件
  final double Function() frameTimeOf;
  final int batchThreshold;

  final double totalDuration;
  final Paint selfSendPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..color = Colors.green;

  ScrollDanmakuPainter(
    this.progress,
    this.scrollDanmakuItems,
    this.danmakuDurationInSeconds,
    this.fontSize,
    this.fontWeight,
    this.showStroke,
    this.danmakuHeight,
    this.running,
    this.frameTimeOf, {
    this.batchThreshold = 10, // 默认值为10，可以自行调整
    super.repaint,
  }) : totalDuration = danmakuDurationInSeconds * 1000;

  @override
  void paint(Canvas canvas, Size size) {
    final tick = frameTimeOf();
    final startPosition = size.width;

    // SimpleLive: 直接画在这一层的 canvas 上。原来超过 [batchThreshold] 条时每帧
    // 另录一个 Picture 再画上去，这一层本来就会被录下来，多录一遍只多分配内存
    for (var item in scrollDanmakuItems) {
      // SimpleLive: 第一次画时从右边缘出发，之后按两帧的时间差移动
      final last = item.lastDrawTick;
      if (last != null && tick > last) {
        final distance = startPosition + item.width;
        item.xPosition -= (tick - last) / totalDuration * distance;
      }
      item.lastDrawTick = tick;

      if (item.xPosition < -item.width || item.xPosition > size.width) {
        continue;
      }

      item.paragraph ??= Utils.generateParagraph(
          item.content, size.width, fontSize, fontWeight,
          stickerHeight: item.stickerHeight,
          emoteHeight: fontSize * item.emoteFactor);
      final offset = Offset(item.xPosition, item.yPosition);

      if (showStroke) {
        item.strokeParagraph ??= Utils.generateStrokeParagraph(
            item.content, size.width, fontSize, fontWeight,
            stickerHeight: item.stickerHeight,
            emoteHeight: fontSize * item.emoteFactor);
        canvas.drawParagraph(item.strokeParagraph!, offset);
      }

      if (item.content.selfSend) {
        canvas.drawRect(
            offset.translate(-2, 2) &
                (Size(item.width, item.height) + const Offset(4, 0)),
            selfSendPaint);
      }

      canvas.drawParagraph(item.paragraph!, offset);
      Utils.drawImages(canvas, item, offset);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }

  // SimpleLive: 弹幕没有无障碍内容。默认跟着 shouldRepaint 每帧重建无障碍树，
  // Windows 上还要同步给系统，白白占用主线程
  @override
  bool shouldRebuildSemantics(covariant CustomPainter oldDelegate) => false;
}
