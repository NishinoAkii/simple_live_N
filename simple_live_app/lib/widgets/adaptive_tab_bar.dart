import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 侧栏顶部的标签栏：按宽度平均分布占满整栏；每个标签最宽 [maxTabWidth]，
/// 侧栏更宽时标签保持这个宽度靠左排列；太窄放不下时可横向滚动。
class AdaptiveTabBar extends StatelessWidget implements PreferredSizeWidget {
  final List<Widget> tabs;
  final double maxTabWidth;
  final double minTabWidth;

  const AdaptiveTabBar({
    required this.tabs,
    this.maxTabWidth = 150,
    this.minTabWidth = 56,
    super.key,
  });

  @override
  Size get preferredSize => const Size.fromHeight(46);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var width = constraints.maxWidth;
        var each = width / math.max(1, tabs.length);
        if (!width.isFinite || each < minTabWidth) {
          // 放不下：按文字宽度排列并横向滚动
          return TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            indicatorSize: TabBarIndicatorSize.tab,
            labelPadding: const EdgeInsets.symmetric(horizontal: 12),
            indicatorWeight: 1.0,
            tabs: tabs,
          );
        }
        var tabWidth = math.min(each, maxTabWidth);
        return TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          indicatorSize: TabBarIndicatorSize.tab,
          labelPadding: EdgeInsets.zero,
          indicatorWeight: 1.0,
          tabs: [
            for (var tab in tabs)
              SizedBox(width: tabWidth, child: Center(child: tab)),
          ],
        );
      },
    );
  }
}
