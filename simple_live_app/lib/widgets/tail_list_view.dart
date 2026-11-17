import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';

/// [TailListView] 的状态：条目数、是否跟随最新
class TailListController {
  TailListController() {
    scrollController.addListener(_onScroll);
  }

  final ScrollController scrollController = ScrollController();

  /// 是否停在最底部跟随最新的条目
  final RxBool following = true.obs;

  final RxInt _version = 0.obs;
  int _length = 0;
  int _anchor = 0;
  int _epoch = 0;
  bool _resumePending = false;

  /// 最新在上时列表顶部的留白（[TailListView] 每次构建时记下），最新在下时为 0
  double _leadingPad = 0;

  int get length => _length;

  /// 条目数变化（在末尾追加）后调用
  void setLength(int length) {
    _length = length;
    if (following.value || _anchor > length) {
      _anchor = length;
    }
    _version.value++;
  }

  /// 最前面丢掉了 [count] 条（超出保留条数）：总数和分界一起前移，
  /// 正在翻看的内容位置不变
  void dropFront(int count) {
    _length = _length > count ? _length - count : 0;
    _anchor = _anchor > count ? _anchor - count : 0;
    _version.value++;
  }

  /// 回到最底部并继续跟随；内容整个换掉（清空、重新搜索）后也调用这个
  void jumpToLatest([int? length]) {
    _length = length ?? _length;
    _anchor = _length;
    // 换一个新列表从底部重新布局，不用把中间的条目都布局一遍
    _epoch++;
    following.value = true;
    if (scrollController.hasClients) {
      scrollController.jumpTo(0);
    }
    _version.value++;
  }

  void _onScroll() {
    if (!scrollController.hasClients) {
      return;
    }
    var position = scrollController.position;
    var direction = position.userScrollDirection;
    if (following.value) {
      // 列表是倒着排的，往上翻看更早的内容时偏移变大
      if (direction == ScrollDirection.reverse) {
        following.value = false;
        // 最新在上：顶部的留白从这一段换到新收到的那一段上面（见 TailListView），
        // 偏移跟着减掉这么多，正在看的内容不动、拖动不断
        if (_leadingPad > 0) {
          position.correctBy(-_leadingPad);
        }
        _version.value++;
      }
    } else if (direction != ScrollDirection.reverse &&
        position.pixels <= position.minScrollExtent + 0.5 &&
        !_resumePending) {
      // 手动滑回了最底部，继续跟随
      _resumePending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _resumePending = false;
        if (!following.value && scrollController.hasClients) {
          var position = scrollController.position;
          if (position.pixels <= position.minScrollExtent + 0.5) {
            jumpToLatest();
          }
        }
      });
    }
  }

  void dispose() {
    scrollController.removeListener(_onScroll);
    scrollController.dispose();
  }
}

/// 只在末尾追加、可以一直增长的列表（直播间聊天、弹幕搜索结果），最新的在最下面。
///
/// 列表倒着排（偏移 0 在最底部），以 anchor 为界分成上下两段：
/// - 跟随最新时 anchor 始终在末尾，新条目直接出现在最下面，不需要滚动；
/// - 往上翻看时 anchor 不动，新条目接在下面一段，正在看的内容不会跳动；
/// - 回到最新时从底部重新布局，跳多远都只布局一屏。
/// 普通 ListView 从很远的位置跳到底部，要把中间的条目全部布局一遍。
///
/// [newestFirst] 为 true 时整个反过来：最新的在最上面（偏移 0 在顶部），其余规则一样
class TailListView extends StatelessWidget {
  const TailListView({
    required this.controller,
    required this.itemBuilder,
    this.padding = EdgeInsets.zero,
    this.newestFirst = false,
    super.key,
  });

  final TailListController controller;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final EdgeInsets padding;
  final bool newestFirst;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      controller._version.value;
      var length = controller._length;
      var anchor = controller._anchor;
      var split = !controller.following.value || anchor < length;

      Widget item(BuildContext context, int index) {
        return KeyedSubtree(
          key: ValueKey<int>(index),
          child: Padding(
            padding: EdgeInsets.only(
              bottom: !newestFirst && index == length - 1 ? padding.bottom : 0,
            ),
            child: itemBuilder(context, index),
          ),
        );
      }

      // 顶部的留白在整个列表的最上面：最新在上、分成两段时，最上面是新收到的那一段
      // （留白可能很大：直播间公告卡片浮在聊天列表顶上时，留的是卡片的高度）
      var topOnNewer = newestFirst && split;
      controller._leadingPad = newestFirst ? padding.top : 0;
      // 上面一段：anchor 之前的条目，从下往上排
      var olderKey = ValueKey(("tail_list_older", controller._epoch));
      var older = SliverPadding(
        key: olderKey,
        padding: EdgeInsets.fromLTRB(
            padding.left, topOnNewer ? 0 : padding.top, padding.right, 0),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => item(context, anchor - 1 - i),
            childCount: anchor,
            findChildIndexCallback: (key) {
              var i = anchor - 1 - (key as ValueKey<int>).value;
              return i >= 0 && i < anchor ? i : null;
            },
          ),
        ),
      );
      // 下面一段：翻看时新收到的条目，从上往下排
      var newer = SliverPadding(
        padding: EdgeInsets.fromLTRB(
            padding.left, topOnNewer ? padding.top : 0, padding.right, 0),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => item(context, anchor + i),
            childCount: length - anchor,
            findChildIndexCallback: (key) {
              var i = (key as ValueKey<int>).value - anchor;
              return i >= 0 && i < length - anchor ? i : null;
            },
          ),
        ),
      );
      // 两种状态的组件结构保持一致，切换时滚动位置和正在进行的拖动不会丢。
      // 列表自成一层：新消息只重画列表，不连带整个页面（按钮、标题、播放器控件）每帧重画；
      // 刷得很快的聊天也不进无障碍树，并且自成一个无障碍分界：新增的条目只标记到这里，
      // 不会让整个页面的无障碍信息每帧重算、同步给系统
      return RepaintBoundary(
          child: Semantics(
              container: true,
              child: ExcludeSemantics(
                  child: ScrollConfiguration(
                // 条目很多时拖动滚动条一下就跳过成千上万条，全部布局会卡住，所以不显示滚动条
                behavior:
                    ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: CustomScrollView(
                    controller: controller.scrollController,
                    reverse: !newestFirst,
                    // 跟随最新时只有上面一段，内容不满一屏时靠上显示
                    shrinkWrap: !split,
                    center: split ? olderKey : null,
                    slivers: split ? [newer, older] : [older],
                  ),
                ),
              ))));
    });
  }
}
