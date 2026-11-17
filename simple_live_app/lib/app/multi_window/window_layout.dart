import 'dart:math';
import 'dart:ui' show Rect, Size;

/// 一块屏幕：可用区域（去掉任务栏，物理像素）和缩放（1.0 = 96 DPI）
class ScreenArea {
  final Rect work;
  final double scale;
  const ScreenArea(this.work, this.scale);

  @override
  String toString() => "ScreenArea($work, x$scale)";
}

/// 多开窗口的摆放：排在主窗口所在的那块屏幕上，横屏 2×2、竖屏 1×4，
/// 彼此不重叠、不超出可用区域。屏幕太小、格子比副窗口最小尺寸还小时少分几格。
///
/// 全部用物理像素算，副窗口拿到以后再按自己所在屏幕的缩放换算
class WindowLayout {
  WindowLayout._();

  /// 副窗口的最小尺寸（逻辑像素）
  static const minSize = Size(200, 150);

  /// 窗口之间、窗口和屏幕边缘的空隙（逻辑像素）
  static const gap = 8.0;

  /// 主窗口所在的屏幕：主窗口中心所在的那块；都不在时选重叠最多的；再不行用第一块
  static ScreenArea? screenOf(List<ScreenArea> screens, Rect? main) {
    if (screens.isEmpty) {
      return null;
    }
    if (main == null) {
      return screens.first;
    }
    for (var s in screens) {
      if (s.work.contains(main.center)) {
        return s;
      }
    }
    ScreenArea best = screens.first;
    var bestArea = -1.0;
    for (var s in screens) {
      var area = _overlap(s.work, main);
      if (area > bestArea) {
        best = s;
        bestArea = area;
      }
    }
    return best;
  }

  /// 这块屏幕上的格子（最多 4 个，按从左到右、从上到下的顺序）
  static List<Rect> slots(ScreenArea screen, {int max = 4}) {
    var work = screen.work;
    var landscape = work.width >= work.height;
    var g = (gap * screen.scale).roundToDouble();
    var minW = minSize.width * screen.scale;
    var minH = minSize.height * screen.scale;
    var grids = landscape
        ? const [(2, 2), (2, 1), (1, 1)]
        : const [(1, 4), (1, 2), (1, 1)];
    for (var (cols, rows) in grids) {
      if (cols * rows > max && !(cols == 1 && rows == 1)) {
        continue;
      }
      var cellW = ((work.width - g * (cols + 1)) / cols).floorToDouble();
      var cellH = ((work.height - g * (rows + 1)) / rows).floorToDouble();
      var last = cols == 1 && rows == 1;
      if (!last && (cellW < minW || cellH < minH)) {
        continue;
      }
      if (cellW <= 0 || cellH <= 0) {
        return const [];
      }
      return [
        for (var r = 0; r < rows; r++)
          for (var c = 0; c < cols; c++)
            Rect.fromLTWH(
              work.left + g + c * (cellW + g),
              work.top + g + r * (cellH + g),
              cellW,
              cellH,
            ),
      ];
    }
    return const [];
  }

  /// 下一个空着的格子（下标）：尽量不挡主窗口，和主窗口重叠少的先用，
  /// 一样多时按顺序。都占满了返回 null
  static int? pickSlot(List<Rect> slots, Set<int> used, Rect? main) {
    var free = [
      for (var i = 0; i < slots.length; i++)
        if (!used.contains(i)) i,
    ];
    if (free.isEmpty) {
      return null;
    }
    if (main == null) {
      return free.first;
    }
    free.sort((a, b) {
      var d = _overlap(slots[a], main).compareTo(_overlap(slots[b], main));
      return d != 0 ? d : a.compareTo(b);
    });
    return free.first;
  }

  static double _overlap(Rect a, Rect b) {
    var w = min(a.right, b.right) - max(a.left, b.left);
    var h = min(a.bottom, b.bottom) - max(a.top, b.top);
    return w > 0 && h > 0 ? w * h : 0;
  }
}
