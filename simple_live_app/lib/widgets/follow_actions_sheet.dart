import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/multi_window/multi_window_widgets.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/live_notify_service.dart';

/// 长按关注列表里的直播间弹出的卡片，和点一条弹幕弹出的卡片一个样子：
/// 上面是主播名、平台和开播状态，下面一行一个操作：开启或关闭开播提醒、
/// 设置标签（首页的关注列表才有）、取消关注
Future<void> showFollowActions(
  FollowUser item, {
  required VoidCallback onUnfollow,
  VoidCallback? onSetTag,
}) {
  return showModalBottomSheet(
    context: Get.context!,
    constraints: const BoxConstraints(maxWidth: 600),
    builder: (sheetContext) {
      Widget action(IconData icon, String title, VoidCallback onTap) {
        return ListTile(
          leading: Icon(icon),
          title: Text(title),
          onTap: () {
            Navigator.of(sheetContext).pop();
            onTap();
          },
        );
      }

      var site = Sites.allSites[item.siteId];
      var status = switch (item.liveStatus.value) {
        2 => "直播中".t,
        1 => "未开播".t,
        _ => "",
      };
      var line = [
        site?.name ?? Sites.missingSiteText(item.siteId),
        if (status.isNotEmpty) status,
      ].join(" · ");
      var notifyOn = item.notify;
      return SafeArea(
        // 横屏时卡片比屏幕能给的高度高，可以滚
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.userName,
                      style: const TextStyle(
                        color: Colors.grey,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    AppStyle.vGap8,
                    Text(line),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (site != null)
                action(
                  notifyOn
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_active_outlined,
                  notifyOn ? "关闭开播提醒".t : "开启开播提醒".t,
                  () => LiveNotifyService.instance.toggleSubscription(item),
                ),
              if (site != null)
                ...multiWindowTiles(
                  site,
                  item.roomId,
                  close: () => Navigator.of(sheetContext).pop(),
                ),
              if (onSetTag != null)
                action(Icons.label_outline, "设置标签".t, onSetTag),
              action(Remix.dislike_line, "取消关注".t, onUnfollow),
            ],
          ),
        ),
      );
    },
  );
}
