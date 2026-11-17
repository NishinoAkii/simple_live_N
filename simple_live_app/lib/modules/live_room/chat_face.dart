import 'package:flutter/material.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/widgets/live_badges.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 聊天消息名字前的圆形头像，大小约为字号的 1.4 倍。
///
/// 只有部分平台提供头像（如 YouTube）；没有头像或关闭了“聊天栏显示头像”时返回 null。
/// 在 Obx 中调用，开关变化时会刷新。
WidgetSpan? chatFaceSpan(LiveMessage message, double fontSize) {
  var face = message.face ?? "";
  if (face.isEmpty || !AppSettingsController.instance.chatShowFace.value) {
    return null;
  }
  var size = fontSize * 1.4;
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Padding(
      padding: EdgeInsets.only(right: fontSize * 0.3),
      child: ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: NetImage(face, width: size, height: size),
        ),
      ),
    ),
  );
}

/// 聊天消息名字前的牌子（粉丝牌、舰长等，见 [LiveBadgeChips.inlineOf]）。
///
/// 没有牌子或没开“聊天栏显示牌子”时返回 null。在 Obx 中调用，开关变化时会刷新。
WidgetSpan? chatBadgeSpan(LiveMessage message, double fontSize) {
  if (!AppSettingsController.instance.chatShowBadges.value) {
    return null;
  }
  var badges = LiveBadgeChips.inlineOf(message.badges);
  if (badges == null) {
    return null;
  }
  var size = fontSize * 0.8;
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Padding(
      padding: EdgeInsets.only(right: fontSize * 0.3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < badges.length; i++)
            Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 3),
              child: LiveBadgeChips.chip(
                badges[i],
                fontSize: size,
                dark: Get.isDarkMode,
                iconOnly: true,
              ),
            ),
        ],
      ),
    ),
  );
}
