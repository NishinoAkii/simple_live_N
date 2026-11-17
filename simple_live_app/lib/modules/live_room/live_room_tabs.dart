import 'dart:async';

import 'package:flutter/material.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 直播间侧栏（手机上是播放器下面）的标签页。榜单在“礼物”页里（礼物 | 榜单）
enum LiveRoomTab { chat, superChat, gifts, follow, settings }

/// 这个直播间有哪些标签页，按显示的顺序
List<LiveRoomTab> liveRoomTabs({
  required bool superChat,
  required bool gifts,
}) =>
    [
      LiveRoomTab.chat,
      if (superChat) LiveRoomTab.superChat,
      if (gifts) LiveRoomTab.gifts,
      LiveRoomTab.follow,
      LiveRoomTab.settings,
    ];

/// 标签上的字；SC 页的标题带数量，由调用方给 [superChat]
Widget liveRoomTabLabel(LiveRoomTab tab, {Widget? superChat}) => switch (tab) {
      LiveRoomTab.chat => Tab(text: "聊天".t),
      LiveRoomTab.superChat => Tab(child: superChat ?? const Text("SC")),
      LiveRoomTab.gifts => Tab(text: "礼物".t),
      LiveRoomTab.follow => Tab(text: "关注##tab".t),
      LiveRoomTab.settings => Tab(text: "设置".t),
    };

/// 放在 DefaultTabController 下面：[jumps] 里来一个标签页就切过去
/// （点在线人数时切到“礼物”页）。这个直播间没有那一页时不动
class LiveRoomTabJumper extends StatefulWidget {
  final List<LiveRoomTab> tabs;
  final Stream<LiveRoomTab> jumps;
  final Widget child;
  const LiveRoomTabJumper({
    required this.tabs,
    required this.jumps,
    required this.child,
    super.key,
  });

  @override
  State<LiveRoomTabJumper> createState() => _LiveRoomTabJumperState();
}

class _LiveRoomTabJumperState extends State<LiveRoomTabJumper> {
  StreamSubscription<LiveRoomTab>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.jumps.listen(_jump);
  }

  @override
  void didUpdateWidget(LiveRoomTabJumper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jumps != widget.jumps) {
      _sub?.cancel();
      _sub = widget.jumps.listen(_jump);
    }
  }

  void _jump(LiveRoomTab tab) {
    var index = widget.tabs.indexOf(tab);
    var controller = mounted ? DefaultTabController.maybeOf(context) : null;
    if (index >= 0 && controller != null && controller.index != index) {
      controller.animateTo(index);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
