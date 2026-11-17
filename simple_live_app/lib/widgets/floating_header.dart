import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 侧栏顶上的按钮浮在列表上面：列表占满整页，一开始从按钮下面排起，
/// 往上滚时从按钮下面穿过。按钮之间的空隙是透明的，看得到下面的内容。
///
/// [header] 是原来顶栏里的那几行按钮（顺序、排法不变）；[body] 拿到按钮占的高度，
/// 用它给列表加上面的留白
class FloatingHeader extends StatefulWidget {
  final Widget header;
  final Widget Function(BuildContext context, double top) body;
  const FloatingHeader({required this.header, required this.body, super.key});

  @override
  State<FloatingHeader> createState() => _FloatingHeaderState();
}

class _FloatingHeaderState extends State<FloatingHeader> {
  double _top = 0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.body(context, _top),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FloatingStyle(
            child: MeasureSize(
              onChange: (size) {
                if (mounted && size.height != _top) {
                  setState(() => _top = size.height);
                }
              },
              child: widget.header,
            ),
          ),
        ),
      ],
    );
  }
}

/// 浮在内容上的按钮用的颜色：半透明的卡片色，选中的用主题色
class FloatingStyle extends StatelessWidget {
  final Widget child;
  const FloatingStyle({required this.child, super.key});

  static Color background(BuildContext context) =>
      Theme.of(context).cardColor.withAlpha(205);

  static Color selected(BuildContext context) =>
      Theme.of(context).colorScheme.secondaryContainer.withAlpha(235);

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    var chips = ChipTheme.of(context);
    return ChipTheme(
      data: chips.copyWith(
        color: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? selected(context)
              : background(context),
        ),
        elevation: 1,
        pressElevation: 2,
        shadowColor: Colors.black38,
        side: BorderSide(color: scheme.outlineVariant.withAlpha(150)),
        labelStyle: (chips.labelStyle ?? const TextStyle()).copyWith(
          fontSize: 13,
        ),
      ),
      child: child,
    );
  }
}

/// 浮在内容上的一段文字（标题、数量）：和按钮一样的半透明底
class FloatingLabel extends StatelessWidget {
  final Widget child;
  const FloatingLabel({required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: FloatingStyle.background(context),
      elevation: 1,
      borderRadius: BorderRadius.circular(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: child,
        ),
      ),
    );
  }
}

/// 布局后报告自己的大小（大小变了才报），给 [FloatingHeader] 量按钮占多高
class MeasureSize extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onChange;
  const MeasureSize({required this.onChange, required super.child, super.key});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureSize(onChange);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderMeasureSize).onChange = onChange;
  }
}

class _RenderMeasureSize extends RenderProxyBox {
  ValueChanged<Size> onChange;
  Size? _last;
  _RenderMeasureSize(this.onChange);

  @override
  void performLayout() {
    super.performLayout();
    var now = size;
    if (now == _last) return;
    _last = now;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(now));
  }
}
