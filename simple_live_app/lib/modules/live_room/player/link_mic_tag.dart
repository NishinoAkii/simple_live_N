import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 视频左下角的连麦标签，和 SC、礼物卡片一个样式。
///
/// 有人连麦时一直显示，可以点 × 关掉（连麦的人变了会再出来）。
/// 有人排队时，点一下标签展开排队名单；鼠标移开或点别处就收起来。
class LinkMicTag extends StatefulWidget {
  /// 连麦状态和是否被关掉（直播间控制器里的 linkMic、linkMicHidden）
  final Rx<LiveLinkMicState> state;
  final RxBool hidden;

  /// 点了 ×
  final VoidCallback onHide;

  const LinkMicTag({
    required this.state,
    required this.hidden,
    required this.onHide,
    super.key,
  });

  @override
  State<LinkMicTag> createState() => _LinkMicTagState();
}

class _LinkMicTagState extends State<LinkMicTag> {
  static const gold = Color(0xffffc857);

  bool _open = false;
  Timer? _closeTimer;

  void _setOpen(bool open) {
    _closeTimer?.cancel();
    if (_open != open && mounted) {
      setState(() => _open = open);
    }
  }

  /// 鼠标移开后稍等一下再收起，从标签移到名单上时不会闪一下
  void _closeSoon() {
    _closeTimer?.cancel();
    _closeTimer =
        Timer(const Duration(milliseconds: 300), () => _setOpen(false));
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      var state = widget.state.value;
      if (!state.active || widget.hidden.value) {
        return const SizedBox.shrink();
      }
      var waiting = state.waiting;
      return TapRegion(
        onTapOutside: (_) => _setOpen(false),
        child: MouseRegion(
          onEnter: (_) => _closeTimer?.cancel(),
          onExit: (_) => _closeSoon(),
          child: SizedBox(
            width: 200,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _card(state, waiting),
                if (_open && waiting > 0) _queue(state),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _box({required Widget child, EdgeInsets? padding}) => Opacity(
        opacity: 0.8,
        child: Container(
          padding: padding ?? const EdgeInsets.fromLTRB(4, 4, 2, 4),
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(140),
            borderRadius: AppStyle.radius8,
          ),
          child: child,
        ),
      );

  Widget _card(LiveLinkMicState state, int waiting) {
    var names = state.linked.map((e) => e.name).join("、".t);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: waiting > 0 ? () => _setOpen(!_open) : null,
      child: _box(
        child: Row(
          children: [
            _faces(state.linked),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state.kind.t,
                    style: const TextStyle(
                      color: gold,
                      fontSize: 11,
                      height: 1.2,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    names,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
            if (waiting > 0)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "排队 {waiting}".tf({"waiting": waiting}),
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      size: 14,
                      color: Colors.white70,
                    ),
                  ],
                ),
              ),
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () {
                _setOpen(false);
                widget.onHide();
              },
              child: const Padding(
                padding: EdgeInsets.all(3),
                child: Icon(Icons.close, size: 14, color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 连麦的人的头像，最多叠三个
  Widget _faces(List<LiveLinkMicUser> users) {
    var shown = users.take(3).toList();
    const size = 22.0;
    const step = 12.0;
    return SizedBox(
      width: size + step * (shown.length - 1),
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: step * i,
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black,
                ),
                padding: const EdgeInsets.all(1),
                child: _avatar(shown[i], size - 2),
              ),
            ),
        ],
      ),
    );
  }

  Widget _avatar(LiveLinkMicUser user, double size) => ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: user.face.isEmpty
              ? const ColoredBox(
                  color: Colors.white24,
                  child: Icon(Icons.person, size: 14, color: Colors.white),
                )
              : NetImage(user.face, width: size, height: size),
        ),
      );

  /// 排队名单；平台只给人数时说明一下
  Widget _queue(LiveLinkMicState state) {
    var unnamed = state.waiting - state.queue.length;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: _box(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 160),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "排队连麦".t,
                  style: const TextStyle(color: gold, fontSize: 11, height: 1.4),
                ),
                for (var user in state.queue)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        _avatar(user, 18),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            user.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (unnamed > 0)
                  Text(
                    state.queue.isEmpty
                        ? "{unnamed} 人在排队，平台没给名单".tf({"unnamed": unnamed})
                        : "还有 {unnamed} 人，平台没给名单".tf({"unnamed": unnamed}),
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
