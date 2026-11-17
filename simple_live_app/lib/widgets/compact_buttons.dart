import 'package:flutter/material.dart';
import 'package:simple_live_app/app/app_style.dart';

/// 浮在列表上的圆形按钮（导出、排序、搜索、刷新）：半透明，列表从下面滚过。
/// 看起来 36 像素，点击范围 44 像素
class FloatingRoundButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;

  /// 为 null 时按钮变灰、点不了
  final VoidCallback? onPressed;
  const FloatingRoundButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 22,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Material(
              color: Theme.of(context).cardColor.withAlpha(205),
              shape: const CircleBorder(),
              elevation: 1,
              child: SizedBox(
                width: 36,
                height: 36,
                child: Icon(
                  icon,
                  size: 20,
                  color: onPressed == null ? Theme.of(context).disabledColor : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 浮在列表上的半透明开关（和 [FloatingRoundButton] 一套）：圆角条，
/// 选中时用主题色。看起来 32 像素高，点击范围 44 像素，列表从下面滚过
class FloatingPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? tooltip;
  const FloatingPill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.tooltip,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    Widget pill = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Material(
          color: selected
              ? scheme.secondaryContainer.withAlpha(235)
              : Theme.of(context).cardColor.withAlpha(205),
          elevation: 1,
          borderRadius: BorderRadius.circular(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 32, maxWidth: 220),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: selected ? scheme.onSecondaryContainer : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? pill : Tooltip(message: tooltip!, child: pill);
  }
}

/// 顶栏的小开关：圆角小框，选中时高亮（比 FilterChip 矮，不占地方）。
/// 看起来约 24 像素高，点击范围上下各多出 8 像素
class SmallToggle extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const SmallToggle({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: selected ? scheme.secondaryContainer : Colors.transparent,
              borderRadius: AppStyle.radius4,
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: selected ? scheme.onSecondaryContainer : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
