import 'dart:ui' as ui;
import '/models/danmaku_content_item.dart';

class DanmakuItem {
  /// 弹幕内容
  final DanmakuContentItem content;

  /// 弹幕创建时间
  final int creationTime;

  /// 弹幕宽度
  final double width;

  /// 弹幕高度
  final double height;

  /// 弹幕水平方向位置
  double xPosition;

  /// 弹幕竖直方向位置
  double yPosition;

  /// 上次绘制时那一帧的时间（毫秒，SimpleLive: 帧时间戳，带小数）
  double? lastDrawTick;

  /// 弹幕布局缓存
  ui.Paragraph? paragraph;
  ui.Paragraph? strokeParagraph;

  /// SimpleLive: 这条弹幕自己持有的图片（[DanmakuContentItem.segments] 里图片的
  /// clone，顺序相同），移除时释放
  List<ui.Image>? images;

  /// SimpleLive: 图片在 [paragraph] 里的位置，随 paragraph 重建
  List<ui.Rect>? imageRects;

  /// SimpleLive: 占几条轨道（滚动的大表情占两条，表情调大后可能更多）
  final int trackSpan;

  /// SimpleLive: 行内表情图片的高度相对字号的倍数（字号变化重建 paragraph 时用）
  final double emoteFactor;

  DanmakuItem({
    required this.content,
    required this.creationTime,
    required this.height,
    required this.width,
    this.xPosition = 0,
    this.yPosition = 0,
    this.paragraph,
    this.strokeParagraph,
    this.lastDrawTick,
    this.images,
    this.trackSpan = 1,
    this.emoteFactor = 1.15,
  });

  /// SimpleLive: 大表情的图片高度（比所占的轨道矮一点，留出间隙），不是大表情时为 0
  double get stickerHeight => content.sticker ? height - 2 : 0;

  /// SimpleLive: 移除时立即释放 Paragraph 等原生对象。
  /// 弹幕在屏幕上停留好几秒，Dart 对象会进入老年代，只靠 GC 回收时
  /// 原生内存要等很久才释放，长时间观看时内存会一直涨。
  void dispose() {
    paragraph?.dispose();
    paragraph = null;
    strokeParagraph?.dispose();
    strokeParagraph = null;
    imageRects = null;
    final images = this.images;
    if (images != null) {
      for (final image in images) {
        image.dispose();
      }
      this.images = null;
    }
    final content = this.content;
    if (content is SpecialDanmakuContentItem) {
      content.painterCache?.dispose();
      content.painterCache = null;
    }
  }

  /// 释放并清空一组弹幕
  static void disposeAll(List<DanmakuItem> items) {
    for (final item in items) {
      item.dispose();
    }
    items.clear();
  }

  /// 移除符合条件的弹幕并释放
  static void removeWhere(
      List<DanmakuItem> items, bool Function(DanmakuItem item) test) {
    items.removeWhere((item) {
      if (!test(item)) {
        return false;
      }
      item.dispose();
      return true;
    });
  }
}
