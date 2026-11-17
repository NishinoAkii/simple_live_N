import 'dart:math';

import 'package:flutter/material.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 在线人数、贵宾数、多少人看过、点赞数排成的一小行。平台没给的那项不显示，
/// 都没有时不占地方。长按（鼠标悬停）看完整的数字
class RoomStatsLine extends StatelessWidget {
  final LiveRoomStats stats;
  const RoomStatsLine(this.stats, {super.key});

  @override
  Widget build(BuildContext context) {
    var items = [
      if (stats.viewers case var n?) _item(Remix.user_line, n, "{n} 人在线".tf({"n": n})),
      if (stats.nobles case var n?) _item(Remix.vip_crown_line, n, "{n} 位贵宾".tf({"n": n})),
      if (stats.watched case var n?) _item(Remix.eye_line, n, "{n} 人看过".tf({"n": n})),
      if (stats.likes case var n?) _item(Remix.thumb_up_line, n, "{n} 次点赞".tf({"n": n})),
    ];
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          items[i],
        ],
      ],
    );
  }

  Widget _item(IconData icon, int count, String tip) {
    return Tooltip(
      message: tip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.grey),
          const SizedBox(width: 3),
          Text(
            Utils.onlineToString(count),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

/// 主播名下面的那一行：左边平台图标和名字，右边 [stats]（一般是 [RoomStatsLine]）。
/// 右边按内容占宽度，放不下（数字很长或系统字体放大）时整体缩小；
/// 名字用剩下的宽度，不够时省略
class RoomStatsRow extends StatelessWidget {
  final Widget logo;
  final String name;
  final Widget stats;
  const RoomStatsRow({
    required this.logo,
    required this.name,
    required this.stats,
    super.key,
  });

  /// 图标（20）和两处间隔占掉的宽度
  static const _fixed = 20.0 + 4 + 8;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          SizedBox(width: 20, child: logo),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: max(0, box.maxWidth - _fixed)),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: stats,
            ),
          ),
        ],
      ),
    );
  }
}

/// 主播信息里的热度和在线人数：能打开榜单时点它打开（设置里关掉“显示榜单”时
/// [onTap] 为 null，原样显示、点不了）
class OnlineCountTap extends StatelessWidget {
  final VoidCallback? onTap;
  final Widget child;
  const OnlineCountTap({required this.onTap, required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    if (onTap == null) {
      return child;
    }
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: child,
    );
  }
}
