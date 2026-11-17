import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/live_gift_list.dart';
import 'package:simple_live_app/modules/live_room/rank/live_rank_state.dart';
import 'package:simple_live_app/widgets/floating_header.dart';
import 'package:simple_live_app/widgets/live_badges.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 直播间的榜单（礼物页里的“榜单”，全屏时从播放器上的按钮打开同一个）。
///
/// 榜单种类、筛选和刷新是半透明的小按钮，浮在列表上面（和礼物页的按钮一样），
/// 列表从按钮下面排起、往上滚时从下面穿过；更新时间和说明跟着列表滚。
/// 前三名是领奖台，后面一行一个人。点一个人打开用户卡片。
class LiveRankPanel extends StatelessWidget {
  final LiveRankState state;

  /// 点一个人
  final void Function(LiveRankItem item) onTapItem;

  /// 给这个人写的备注，名字后面灰色显示；没有时为 null
  final String? Function(LiveRankItem item)? remarkOf;

  /// 浮动按钮那一行最左边的东西（礼物页的“榜单”按钮），没有时为 null
  final Widget? leading;

  const LiveRankPanel({
    required this.state,
    required this.onTapItem,
    this.remarkOf,
    this.leading,
    super.key,
  });

  /// 分数的写法：平台给了文字用文字，否则按数字简写（1.2万）
  static String scoreTextOf(LiveRankItem item) {
    if (item.scoreText case var text? when text.isNotEmpty) {
      return text;
    }
    var score = item.score;
    return score == null ? "" : Utils.compactNumber(score);
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // 表头里的筛选和榜单种类也跟着刷新
      state.version.value;
      state.topTen.value;
      state.medalOnly.value;
      state.selectedId.value;
      var ready = state.ready();
      var board = state.current;
      var data = state.currentData;
      if (ready &&
          data.updatedAt == null &&
          data.error == null &&
          !data.loading) {
        // 打开时读一次（不在 build 里改状态）
        WidgetsBinding.instance
            .addPostFrameCallback((_) => state.ensureLoaded());
      }
      // 按钮浮在上面；列表一开始从按钮下面排起，不会被盖住
      return FloatingHeader(
        header: LiveRankHeader(
          state: state,
          board: board,
          data: data,
          leading: leading,
        ),
        body: (context, top) => RefreshIndicator(
          edgeOffset: top + 12,
          onRefresh: state.refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // 比按钮多留一点空：静止时第一行离按钮远一些
              SliverToBoxAdapter(child: SizedBox(height: top + 12)),
              SliverToBoxAdapter(
                child: LiveRankInfo(board: board, data: data),
              ),
              ..._body(context, data),
            ],
          ),
        ),
      );
    });
  }

  List<Widget> _message(List<Widget> children) => [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ),
      ];

  List<Widget> _body(BuildContext context, LiveRankData data) {
    var grey = TextStyle(color: Theme.of(context).hintColor);
    if (data.items.isEmpty) {
      if (data.loading || data.updatedAt == null && data.error == null) {
        return _message([
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text("正在读取榜单…".t, style: grey),
        ]);
      }
      if (data.error != null) {
        return _message([
          Text(
            "读取失败：{error}".tf({"error": data.error}),
            textAlign: TextAlign.center,
            style: grey,
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: state.refresh,
            icon: const Icon(Remix.refresh_line),
            label: Text("重试".t),
          ),
        ]);
      }
      return _message([
        Text("榜单上还没有人".t, textAlign: TextAlign.center, style: grey),
      ]);
    }
    var list = state.visible;
    var rest = list.skip(3).toList();
    return [
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
      if (data.error != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text(
              "刷新失败，下面是上次读取的榜单：{error}".tf({"error": data.error}),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        ),
      if (list.isEmpty)
        ..._message([
          Text("没有符合条件的人".t, textAlign: TextAlign.center, style: grey),
        ])
      else ...[
        SliverToBoxAdapter(
          child: RankPodium(items: list.take(3).toList(), onTap: onTapItem),
        ),
        SliverList.builder(
          itemCount: rest.length,
          itemBuilder: (_, i) => RankRow(
            rest[i],
            remark: remarkOf?.call(rest[i]),
            onTap: () => onTapItem(rest[i]),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    ];
  }
}

/// 浮在榜单上面的一行小按钮（大小和播放器上的弹幕开关差不多）：[leading]（“榜单”）、
/// 榜单种类（短名字，一个榜单一个按钮）、只看前十（“10”）、只看有粉丝牌的（牌子图标）、
/// 刷新（图标）。放不下时换行。
/// 按钮之间是透明的，点得到下面的列表
class LiveRankHeader extends StatelessWidget {
  final LiveRankState state;
  final LiveRankBoard board;
  final LiveRankData data;
  final Widget? leading;
  const LiveRankHeader({
    required this.state,
    required this.board,
    required this.data,
    this.leading,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    var boards = state.boards;
    // 只有带粉丝牌的榜单才有“只看有粉丝牌的”（开着时一直显示，好关掉）
    var medals = state.medalOnly.value || data.items.any((e) => e.hasMedal);
    var topTen = state.topTen.value;
    var medalOnly = state.medalOnly.value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
      child: Wrap(
        spacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (leading != null) leading!,
          // 榜单种类不多，直接排成小按钮（短名字，完整的名字在提示里）
          for (var b in boards)
            RankSquareButton(
              tooltip: b.title.t,
              selected: b.id == board.id,
              onTap: () => state.select(b.id),
              child: Text(b.label.t, style: const TextStyle(fontSize: 13)),
            ),
          RankSquareButton(
            tooltip: "只看前十".t,
            square: true,
            selected: topTen,
            onTap: () => state.topTen.value = !topTen,
            child: const Text(
              "10",
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ),
          if (medals)
            RankSquareButton(
              tooltip: "只看有粉丝牌的".t,
              square: true,
              selected: medalOnly,
              onTap: () => state.medalOnly.value = !medalOnly,
              child: const Icon(Remix.medal_line, size: 18),
            ),
          RankSquareButton(
            tooltip: "刷新榜单".t,
            square: true,
            onTap: data.loading ? null : state.refresh,
            child: data.loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Remix.refresh_line, size: 18),
          ),
        ],
      ),
    );
  }
}

/// 榜单上面的小按钮：大小和播放器上的弹幕开关差不多（看起来 32 像素高，点击范围
/// 44 像素），圆角方形，里面是“10”、图标或很短的文字。[selected] 不为 null 时是开关，
/// 开着时用主题色；[onTap] 为 null 时只显示。[tooltip] 是完整的说明，读屏也读它
class RankSquareButton extends StatelessWidget {
  final String tooltip;
  final bool? selected;
  final VoidCallback? onTap;
  final Widget child;

  /// 正方形（“10”、图标）：内容放不下时缩小；为 false 时按文字加宽（榜单名字）
  final bool square;
  const RankSquareButton({
    required this.tooltip,
    required this.child,
    this.selected,
    this.onTap,
    this.square = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    var on = selected ?? false;
    var color = on ? scheme.onSecondaryContainer : null;
    var content = IconTheme.merge(
      data: IconThemeData(color: color),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: color),
        child: child,
      ),
    );
    return Semantics(
      button: onTap != null,
      toggled: selected,
      label: tooltip,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            child: Center(
              widthFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Material(
                  color: on
                      ? FloatingStyle.selected(context)
                      : FloatingStyle.background(context),
                  elevation: 1,
                  borderRadius: BorderRadius.circular(8),
                  child: square
                      ? SizedBox(
                          width: 32,
                          height: 32,
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: content,
                            ),
                          ),
                        )
                      : SizedBox(
                          height: 32,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minWidth: 32),
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              child: Center(widthFactor: 1, child: content),
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 榜单最上面的灰字：更新时间、人数、按什么排、说明。跟着列表滚
class LiveRankInfo extends StatelessWidget {
  final LiveRankBoard board;
  final LiveRankData data;
  const LiveRankInfo({required this.board, required this.data, super.key});

  @override
  Widget build(BuildContext context) {
    var grey = TextStyle(fontSize: 12, color: Theme.of(context).hintColor);
    var info = <String>[
      if (data.updatedAt != null)
        "更新于 {time}".tf({"time": GiftRow.timeText(data.updatedAt!)}),
      if (data.total != null && data.total! > 0)
        "共 {n} 人".tf({"n": data.total}),
      "按{label}排名".tf({"label": board.scoreLabel.t}),
      if (board.live) "前几名实时更新".t,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(info.join(" · "), style: grey),
          if (board.note case var note?)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(note.t, style: grey),
            ),
        ],
      ),
    );
  }
}

/// 前三名的领奖台：第一名在中间、最高，第二名在左，第三名在右。
/// 三列平分宽度，名字和分数一行放不下时省略，窄屏也不会超出
class RankPodium extends StatelessWidget {
  final List<LiveRankItem> items;
  final void Function(LiveRankItem item) onTap;
  const RankPodium({required this.items, required this.onTap, super.key});

  static const _colors = [
    Color(0xffe8a92e), // 金
    Color(0xff9aa8b8), // 银
    Color(0xffc8804e), // 铜
  ];
  static const _heights = [44.0, 32.0, 24.0];

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    var order = [
      if (items.length > 1) 1,
      0,
      if (items.length > 2) 2,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i in order) Expanded(child: _place(context, items[i], i)),
        ],
      ),
    );
  }

  Widget _place(BuildContext context, LiveRankItem item, int place) {
    var color = _colors[place];
    var size = place == 0 ? 56.0 : 44.0;
    var score = LiveRankPanel.scoreTextOf(item);
    return InkWell(
      key: ValueKey("rank_podium_$place"),
      borderRadius: BorderRadius.circular(8),
      onTap: () => onTap(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 2),
              ),
              child: ClipOval(
                child: NetImage(item.face, width: size, height: size),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              item.userName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (score.isNotEmpty)
              Text(
                score,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
              ),
            const SizedBox(height: 4),
            Container(
              height: _heights[place],
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withAlpha(60),
                border: Border(top: BorderSide(color: color, width: 2)),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(4),
                ),
              ),
              child: Text(
                "${item.rank}",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: color,
                  height: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 第四名以后的一行：“名次 头像 名字（备注）/ 牌子   分数 / 说明”
class RankRow extends StatelessWidget {
  final LiveRankItem item;
  final String? remark;
  final VoidCallback? onTap;
  const RankRow(this.item, {this.remark, this.onTap, super.key});

  @override
  Widget build(BuildContext context) {
    var grey = Theme.of(context).hintColor;
    var score = LiveRankPanel.scoreTextOf(item);
    var badges = item.badges.take(3).toList();
    return InkWell(
      key: ValueKey("rank_row_${item.rank}_${item.userId ?? item.userName}"),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Text(
                "${item.rank}",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: grey,
                  fontWeight: FontWeight.bold,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 6),
            ClipOval(child: NetImage(item.face, width: 36, height: 36)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: item.userName,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (remark != null)
                          TextSpan(
                            text: " ($remark)",
                            style: TextStyle(color: grey),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (badges.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      // 一行放下：太长时整行缩小，不换行也不超出
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < badges.length; i++)
                              Padding(
                                padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
                                child: LiveBadgeChips.chip(
                                  badges[i],
                                  fontSize: 11,
                                  dark: Theme.of(context).brightness ==
                                      Brightness.dark,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (score.isNotEmpty || item.detail != null) ...[
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (score.isNotEmpty)
                      Text(
                        score,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    if (item.detail case var detail?)
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: grey),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
