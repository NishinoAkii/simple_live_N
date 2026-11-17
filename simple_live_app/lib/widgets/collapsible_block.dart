import 'package:flutter/material.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 可以折叠的信息块：展开时显示 [expanded]，折叠时只显示一行 [collapsed]，
/// 右上角的小箭头切换（点击范围 40 像素），折叠时点那一行也能展开。
/// 用来给下面的列表腾地方，状态由调用方保存（如记在设置里）
class CollapsibleBlock extends StatelessWidget {
  final bool isCollapsed;
  final ValueChanged<bool> onChanged;
  final Widget expanded;
  final Widget collapsed;
  final EdgeInsets padding;
  const CollapsibleBlock({
    required this.isCollapsed,
    required this.onChanged,
    required this.expanded,
    required this.collapsed,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 4, 8),
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    var content = Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment:
            isCollapsed ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          Expanded(child: isCollapsed ? collapsed : expanded),
          IconButton(
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            iconSize: 20,
            tooltip: isCollapsed ? "展开".t : "收起".t,
            icon: Icon(isCollapsed ? Icons.expand_more : Icons.expand_less),
            onPressed: () => onChanged(!isCollapsed),
          ),
        ],
      ),
    );
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      alignment: Alignment.topCenter,
      child: isCollapsed
          ? InkWell(onTap: () => onChanged(false), child: content)
          : content,
    );
  }
}
