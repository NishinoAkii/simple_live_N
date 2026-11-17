import 'package:flutter/widgets.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/rank/live_rank_panel.dart';
import 'package:simple_live_app/modules/live_room/user_card/live_user_card.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';

/// 直播间的榜单（礼物页里的“榜单”和全屏时的弹窗共用）：点一个人打开用户卡片，
/// 名字后面带备注。[leading] 是浮动按钮那一行最左边的东西（礼物页的“榜单”按钮）
Widget buildRankPanel(LiveRoomController controller, {Widget? leading}) =>
    LiveRankPanel(
      state: controller.rank,
      leading: leading,
      onTapItem: (item) =>
          showRankUserCard(controller, item, controller.rank.current),
      remarkOf: (item) => ChatUsersService.remarkFor(
        controller.site.id,
        userId: item.userId,
        name: item.userName,
      ),
    );
