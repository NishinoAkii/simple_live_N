import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/capture/capture_scope.dart';
import 'package:simple_live_app/app/capture/capture_settings.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/modules/live_room/live_gifts.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/player/link_mic_tag.dart';
import 'package:simple_live_app/modules/live_room/player/notice_queue.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/widgets/emote_text.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/superchat_card.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 视频左下角的 SC 和礼物：共用一个位置和队列，不进弹幕层。
///
/// SC 每条弹出一次（最多 15 秒，不超过它剩下的时间）；
/// 付费礼物弹出 5 秒，连击时更新数量，每来一次多显示 1 秒（最长 15 秒）
class PlayerNoticeOverlay extends StatefulWidget {
  final LiveRoomController controller;
  const PlayerNoticeOverlay({required this.controller, super.key});

  @override
  State<PlayerNoticeOverlay> createState() => _PlayerNoticeOverlayState();
}

class _PlayerNoticeOverlayState extends State<PlayerNoticeOverlay> {
  final NoticeQueue _queue = NoticeQueue();
  late Worker _scWorker;
  late Worker _scSetting;
  late Worker _giftSetting;
  StreamSubscription<GiftRecord>? _giftSub;
  Timer? _timer;

  LiveRoomController get c => widget.controller;
  AppSettingsController get settings => AppSettingsController.instance;

  void _syncSuperChats(List<LiveSuperChatMessage> list) {
    if (!settings.playershowSuperChat.value) {
      return;
    }
    for (var sc in list) {
      if (c.superChatRemaining(sc) > 0) {
        _queue.pushSuperChat(sc, c.superChatKey(sc));
      }
    }
    _tick();
  }

  void _onGift(GiftRecord record) {
    if (!settings.danmuGiftFly.value) {
      return;
    }
    _queue.pushGift(record, DateTime.now());
    _tick(force: true);
  }

  void _tick({bool force = false}) {
    var changed = _queue.tick(DateTime.now(), c.superChatRemaining);
    if ((changed || force) && mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _syncSuperChats(c.superChats);
    _scWorker = ever<List<LiveSuperChatMessage>>(c.superChats, _syncSuperChats);
    _giftSub = c.giftPopups.listen(_onGift);
    // 关掉某一类时马上收起
    _scSetting = ever<bool>(settings.playershowSuperChat, (on) {
      if (!on) {
        _queue.removeWhere((e) => !e.isGift);
        _tick(force: true);
      }
    });
    _giftSetting = ever<bool>(settings.danmuGiftFly, (on) {
      if (!on) {
        _queue.removeWhere((e) => e.isGift);
        _tick(force: true);
      }
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _scWorker.dispose();
    _scSetting.dispose();
    _giftSetting.dispose();
    _giftSub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 卡片滑入、倒计时只重画这一层
    return RepaintBoundary(
        child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 连麦标签：有人连麦时一直在最上面，可以点。
        // 截图和录屏里连麦标签、SC、礼物各自单独选（见 CaptureSettings）
        CaptureLayerBox(
          scope: c.capture.scope,
          layer: CaptureLayer.linkMic,
          child: LinkMicTag(
            state: c.linkMic,
            hidden: c.linkMicHidden,
            onHide: c.hideLinkMic,
          ),
        ),
        // SC 和礼物卡片只是看的，点击照样落到视频上
        for (var entry in _queue.shown)
          Padding(
            key: ValueKey(entry.key),
            padding: const EdgeInsets.only(top: 8),
            child: CaptureLayerBox(
              scope: c.capture.scope,
              layer: entry.isGift ? CaptureLayer.gifts : CaptureLayer.superChat,
              child: IgnorePointer(
                child: _SlideIn(
                  child: SizedBox(
                    // 礼物卡片比 SC 窄一些，少挡画面
                    width: entry.isGift ? 200 : 240,
                    child: entry.isGift
                        ? GiftNoticeCard(entry.gift!.gift)
                        : Opacity(
                            opacity: 0.65,
                            child: SuperChatCard(
                              entry.superChat!,
                              remaining: c.superChatRemaining(entry.superChat!),
                              showStatus: false,
                              remark: ChatUsersService.remarkFor(
                                c.site.id,
                                userId: entry.superChat!.userId,
                                name: entry.superChat!.userName,
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ));
  }
}

/// 从左边滑进来
class _SlideIn extends StatelessWidget {
  final Widget child;
  const _SlideIn({required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: -1, end: 0),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      builder: (_, value, child) => FractionalTranslation(
        translation: Offset(value, 0),
        child: Opacity(opacity: 1 + value, child: child),
      ),
      child: child,
    );
  }
}

/// 视频上的礼物卡片：和 SC 卡片一样的圆角方框，小而半透明，少挡画面。
/// 头像、名字、“投喂 小心心”、礼物图标、×数量
class GiftNoticeCard extends StatelessWidget {
  final LiveGiftMessage gift;
  const GiftNoticeCard(this.gift, {super.key});

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xffffc857);
    var icon = gift.icon;
    return Opacity(
      opacity: 0.8,
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(140),
          borderRadius: AppStyle.radius8,
        ),
        child: Row(
          children: [
            ClipOval(
              child: SizedBox(
                width: 24,
                height: 24,
                child: gift.face.isEmpty
                    ? const ColoredBox(
                        color: Colors.white24,
                        child:
                            Icon(Icons.person, size: 16, color: Colors.white),
                      )
                    : NetImage(gift.face, width: 24, height: 24),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    gift.userName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      height: 1.2,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    "${gift.action.t} ${"${gift.giftName}##gift".t}",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            if (icon != null) ...[
              const SizedBox(width: 4),
              EmoteImage(icon, height: 24, maxWidth: 36),
            ],
            const SizedBox(width: 4),
            Text(
              "×${gift.count}",
              style: const TextStyle(
                color: gold,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
