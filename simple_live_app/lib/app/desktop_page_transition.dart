import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// 桌面端页面转场：淡入 + 轻微放大，效果接近系统的缩放转场。
///
/// GetX 未指定转场时使用 `const PageTransitionsTheme()`，在 Windows 上是
/// ZoomPageTransitionsBuilder，它会把页面画面做成快照（toImageSync）。
/// 快照会把视频纹理按 Skia 路径绘制，而引擎用的是 Impeller、没有 GrDirectContext，
/// 于是在 EmbedderExternalTextureGL::ResolveTextureSkia 里访问空指针，
/// 进入/退出播放页时整个程序闪退。这里的转场不做快照。
class DesktopPageTransition extends CustomTransition {
  @override
  Widget buildTransition(
    BuildContext context,
    Curve? curve,
    Alignment? alignment,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    var enter = CurvedAnimation(
      parent: animation,
      curve: Curves.fastOutSlowIn,
      reverseCurve: Curves.easeIn,
    );
    var exit = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.fastOutSlowIn,
    );
    return FadeTransition(
      opacity: enter,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.92, end: 1.0).animate(enter),
        child: ScaleTransition(
          // 被新页面覆盖时稍微放大，和系统缩放转场一致
          scale: Tween<double>(begin: 1.0, end: 1.05).animate(exit),
          child: child,
        ),
      ),
    );
  }
}
