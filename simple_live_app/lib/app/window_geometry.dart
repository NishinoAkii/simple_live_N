import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

/// 一块屏幕能放窗口的区域（去掉任务栏），和窗口用同一种坐标（Windows 上是物理像素）
class DisplayArea {
  final Rect work;

  /// 这块屏幕的缩放（150% 为 1.5）
  final double scale;
  const DisplayArea(this.work, this.scale);

  @override
  String toString() => "DisplayArea($work, x$scale)";
}

/// 记下来的窗口位置和大小。[rect] 用和 [DisplayArea] 一样的坐标，
/// [scale] 是记下时窗口所在屏幕的缩放（换到缩放不同的屏幕时按它换算大小）
class WindowPlacement {
  final Rect rect;
  final double scale;
  final bool maximized;
  const WindowPlacement(this.rect, this.scale, {this.maximized = false});

  WindowPlacement copyWith({bool? maximized}) =>
      WindowPlacement(rect, scale, maximized: maximized ?? this.maximized);

  String encode() => jsonEncode({
        "x": rect.left,
        "y": rect.top,
        "w": rect.width,
        "h": rect.height,
        "scale": scale,
        if (maximized) "max": true,
      });

  /// 读不出来（没存过、坏了、大小不对）时为 null
  static WindowPlacement? decode(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      var json = jsonDecode(text);
      if (json is! Map) return null;
      double? n(String key) => (json[key] as num?)?.toDouble();
      var x = n("x"), y = n("y"), w = n("w"), h = n("h");
      var scale = n("scale") ?? 1;
      if (x == null || y == null || w == null || h == null) return null;
      if (!(w > 0 && h > 0 && scale > 0) ||
          ![x, y, w, h, scale].every((e) => e.isFinite)) {
        return null;
      }
      return WindowPlacement(Rect.fromLTWH(x, y, w, h), scale,
          maximized: json["max"] == true);
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => "WindowPlacement($rect, x$scale, max: $maximized)";
}

/// 窗口位置的规则，都是纯计算，方便测试
class WindowGeometry {
  /// 标题栏大约多高（逻辑像素）：这一条至少要露出一段在某块屏幕上，才拖得动
  static const double titleBarHeight = 32;

  /// 标题栏至少要露出多宽（逻辑像素）
  static const double minVisibleWidth = 120;

  /// 和 [rect] 重叠最多的屏幕；一点都不重叠时为 null
  static DisplayArea? displayOf(Rect rect, List<DisplayArea> displays) {
    DisplayArea? best;
    var bestArea = 0.0;
    for (var d in displays) {
      var overlap = rect.intersect(d.work);
      if (overlap.width <= 0 || overlap.height <= 0) continue;
      var area = overlap.width * overlap.height;
      if (area > bestArea) {
        best = d;
        bestArea = area;
      }
    }
    return best;
  }

  /// 窗口还能找到、拖得动：标题栏有一段露在某块屏幕上
  static bool isReachable(Rect rect, List<DisplayArea> displays) {
    for (var d in displays) {
      var bar = Rect.fromLTWH(rect.left, rect.top, rect.width,
          math.min(rect.height, titleBarHeight * d.scale));
      var overlap = bar.intersect(d.work);
      var need = math.min(minVisibleWidth * d.scale, rect.width / 2);
      if (overlap.width >= need && overlap.height >= 8 * d.scale) {
        return true;
      }
    }
    return false;
  }

  /// 把 [scale] 下的大小换成 [target] 屏幕上的大小：逻辑大小不变
  static Size convertSize(Size size, double scale, double targetScale) =>
      size / scale * targetScale;

  /// 大小不超过屏幕的可用区域
  static Size fit(Size size, DisplayArea display) => Size(
        math.min(size.width, display.work.width),
        math.min(size.height, display.work.height),
      );

  /// 放在 [display] 的正中间
  static Rect centered(Size size, DisplayArea display) {
    var fitted = fit(size, display);
    return Rect.fromCenter(
      center: display.work.center,
      width: fitted.width,
      height: fitted.height,
    );
  }

  /// 恢复记下的窗口：还在某块屏幕上就放回原处（屏幕的缩放改了时按逻辑大小换算），
  /// 找不到了（比如拔了副屏）就放到 [fallback] 屏幕的正中间。返回位置和那块屏幕
  static (Rect, DisplayArea) restore(
      WindowPlacement saved, List<DisplayArea> displays, DisplayArea fallback) {
    if (isReachable(saved.rect, displays)) {
      var display = displayOf(saved.rect, displays) ?? fallback;
      var size = fit(
          convertSize(saved.rect.size, saved.scale, display.scale), display);
      return (saved.rect.topLeft & size, display);
    }
    var size = convertSize(saved.rect.size, saved.scale, fallback.scale);
    return (centered(size, fallback), fallback);
  }

  /// 小窗换到宽高比不同的视频时保持面积（逻辑像素）不变，宽高按新的比例
  static Size keepArea(Size size, double aspectRatio) {
    var area = size.width * size.height;
    if (!(area > 0) || !(aspectRatio > 0)) return size;
    var width = math.sqrt(area * aspectRatio);
    return Size(width, width / aspectRatio);
  }
}
