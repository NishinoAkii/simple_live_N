import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 宽屏布局右侧的侧栏，左边缘可拖动调整宽度，宽度按 [storageKey] 记住。
/// 双击拖动条恢复默认宽度。
class ResizableSidePanel extends StatefulWidget {
  final Widget child;
  final String storageKey;
  final double defaultWidth;
  final double minWidth;
  final double maxWidth;

  const ResizableSidePanel({
    required this.child,
    required this.storageKey,
    this.defaultWidth = 300,
    this.minWidth = 240,
    this.maxWidth = 720,
    super.key,
  });

  @override
  State<ResizableSidePanel> createState() => _ResizableSidePanelState();
}

class _ResizableSidePanelState extends State<ResizableSidePanel> {
  late double _width;
  bool _hover = false;
  bool _dragging = false;

  /// 拖动过程中延迟保存，拖动结束、取消或页面关闭时立即保存
  Timer? _saveTimer;

  @override
  void initState() {
    var saved = LocalStorageService.instance
        .getValue<double>(widget.storageKey, widget.defaultWidth);
    _width = saved.isFinite ? saved : widget.defaultWidth;
    super.initState();
  }

  /// 侧栏最多占窗口宽度的 60%，给画面留出空间
  double _clamp(double value, double screenWidth) {
    var upper = math.max(
      widget.minWidth,
      math.min(widget.maxWidth, screenWidth * 0.6),
    );
    return value.clamp(widget.minWidth, upper).toDouble();
  }

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = null;
    LocalStorageService.instance.setValue<double>(widget.storageKey, _width);
  }

  void _saveLater() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _save);
  }

  @override
  void dispose() {
    if (_saveTimer != null) {
      _save();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var screenWidth = MediaQuery.of(context).size.width;
    var width = _clamp(_width, screenWidth);
    var highlight = _hover || _dragging;
    var color = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => setState(() => _dragging = true),
            onHorizontalDragUpdate: (details) {
              setState(() {
                // 向左拖动变宽
                _width = _clamp(width - details.delta.dx, screenWidth);
              });
              _saveLater();
            },
            onHorizontalDragEnd: (_) {
              setState(() => _dragging = false);
              _save();
            },
            onHorizontalDragCancel: () {
              setState(() => _dragging = false);
              _save();
            },
            onDoubleTap: () {
              setState(() => _width = widget.defaultWidth);
              _save();
            },
            child: SizedBox(
              width: 8,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: highlight ? 3 : 1,
                  color: highlight ? color : Colors.grey.withAlpha(50),
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: width, child: widget.child),
      ],
    );
  }
}
