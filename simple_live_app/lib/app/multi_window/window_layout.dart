import 'dart:math';
import 'dart:ui' show Offset, Rect, Size;

/// 一块屏幕：可用区域（去掉任务栏，物理像素）和缩放（1.0 = 96 DPI）
class ScreenArea {
  final Rect work;
  final double scale;
  const ScreenArea(this.work, this.scale);

  @override
  String toString() => "ScreenArea($work, x$scale)";
}

/// 多开窗口的摆放。没有固定的格子：每个编号（第几个窗口）记住用户拖到的位置和大小
/// （见 WindowSetRecorder），下次开到这个编号时放回去；第一次用、还没记过时，
/// 从前一个窗口（没有时从主窗口）往右下错开一点，用默认大小，整个放在屏幕里。
///
/// 全部用物理像素算，副窗口拿到以后再按自己所在屏幕的缩放换算
class WindowLayout {
  WindowLayout._();

  /// 副窗口的最小尺寸（逻辑像素）
  static const minSize = Size(200, 150);

  /// 还没记过位置时的大小（逻辑像素）
  static const defaultSize = Size(800, 500);

  /// 往右下错开多少（逻辑像素）
  static const cascadeStep = 32.0;

  /// [rect] 所在的屏幕：中心所在的那块；都不在时选重叠最多的；再不行用第一块
  static ScreenArea? screenOf(List<ScreenArea> screens, Rect? rect) {
    if (screens.isEmpty) {
      return null;
    }
    if (rect == null) {
      return screens.first;
    }
    for (var s in screens) {
      if (s.work.contains(rect.center)) {
        return s;
      }
    }
    ScreenArea best = screens.first;
    var bestArea = -1.0;
    for (var s in screens) {
      var area = overlap(s.work, rect);
      if (area > bestArea) {
        best = s;
        bestArea = area;
      }
    }
    return best;
  }

  /// 没记过位置的窗口放哪里：从 [from]（前一个窗口，没有时是主窗口）的左上角往右下错开
  /// [cascadeStep]，默认大小，整个放进 [from] 所在屏幕的可用区域。返回位置和那块屏幕的缩放；
  /// 一块屏幕都没有时为 null（副窗口自己居中）
  static (Rect, double)? cascade(List<ScreenArea> screens, Rect? from) {
    var screen = screenOf(screens, from);
    if (screen == null) {
      return null;
    }
    var s = screen.scale;
    var step = Offset(cascadeStep * s, cascadeStep * s);
    var origin = (from?.topLeft ?? screen.work.topLeft) + step;
    var rect = clampInto(
        origin & Size(defaultSize.width * s, defaultSize.height * s),
        screen.work);
    return rect == null ? null : (rect, s);
  }

  /// 整个放进 [work] 里（取整像素，大了先缩小），放不下时为 null。
  /// 超出不到 [slack] 的（屏幕信息换算时差了一两个像素）原样不动：
  /// 贴靠在屏幕边上的窗口放回去还贴着边
  static Rect? clampInto(Rect rect, Rect work, {double slack = 0}) {
    if (slack > 0 &&
        rect.width > 0 &&
        rect.height > 0 &&
        rect.left >= work.left - slack &&
        rect.top >= work.top - slack &&
        rect.right <= work.right + slack &&
        rect.bottom <= work.bottom + slack) {
      return Rect.fromLTWH(rect.left.roundToDouble(), rect.top.roundToDouble(),
          rect.width.roundToDouble(), rect.height.roundToDouble());
    }
    var left = work.left.ceil(), top = work.top.ceil();
    var right = work.right.floor(), bottom = work.bottom.floor();
    if (right <= left || bottom <= top) {
      return null;
    }
    var w = min(rect.width.round(), right - left);
    var h = min(rect.height.round(), bottom - top);
    if (w <= 0 || h <= 0) {
      return null;
    }
    var x = rect.left.round().clamp(left, right - w);
    var y = rect.top.round().clamp(top, bottom - h);
    return Rect.fromLTWH(
        x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());
  }

  /// 两个矩形重叠的面积
  static double overlap(Rect a, Rect b) {
    var w = min(a.right, b.right) - max(a.left, b.left);
    var h = min(a.bottom, b.bottom) - max(a.top, b.top);
    return w > 0 && h > 0 ? w * h : 0;
  }
}
