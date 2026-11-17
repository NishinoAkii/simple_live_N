import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show DefaultTabController, TabController;

/// 放在 TabBarView 的某一页里：这一页（第 [index] 个标签）被切到时调用 [onShown]。
/// 每切到一次调用一次；一直停在这一页时不重复调用
class ShownInTab extends StatefulWidget {
  final int index;
  final VoidCallback onShown;
  final Widget child;
  const ShownInTab({
    required this.index,
    required this.onShown,
    required this.child,
    super.key,
  });

  @override
  State<ShownInTab> createState() => _ShownInTabState();
}

class _ShownInTabState extends State<ShownInTab> {
  TabController? _controller;
  bool _selected = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    var controller = DefaultTabController.maybeOf(context);
    if (controller == _controller) {
      return;
    }
    _controller?.removeListener(_check);
    _controller = controller;
    controller?.addListener(_check);
    _check();
  }

  @override
  void didUpdateWidget(ShownInTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _check();
    }
  }

  void _check() {
    var controller = _controller;
    if (controller == null || controller.indexIsChanging) {
      return;
    }
    var selected = controller.index == widget.index;
    if (selected && !_selected) {
      // 不在 build 里调用：回调里会改 Rx 变量
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onShown();
      });
    }
    _selected = selected;
  }

  @override
  void dispose() {
    _controller?.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
