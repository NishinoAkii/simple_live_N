import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/rank/live_rank_panel.dart';
import 'package:simple_live_app/modules/live_room/user_card/chat_user_card.dart';
import 'package:simple_live_app/services/chat_users/chat_user.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/widgets/emote_text.dart';
import 'package:simple_live_app/widgets/live_badges.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 直播间里打开用户卡片：点一条弹幕、SC 卡片、礼物记录。
/// 卡片上面是发言人、身份和内容，下面一行一个操作：粉丝牌是哪个主播的（知道时）、
/// 只看这个人的弹幕、屏蔽这个人 ›、备注、复制弹幕、搜索这条弹幕

/// 点一条弹幕
void showLiveChatCard(LiveRoomController controller, LiveMessage message) {
  var hasName = message.userName.trim().isNotEmpty;
  _show(
    controller,
    ChatUser.ofMessage(controller.site.id, message),
    message,
    after: [
      ChatUserCardAction(
        Icons.copy,
        "复制弹幕".t,
        () => Utils.copyToClipboard(
          controller.readableChatText(message.message),
        ),
      ),
      ChatUserCardAction(
        Icons.search,
        "搜索这条弹幕".t,
        () => controller.prefillChatSearch(message),
      ),
    ],
    hasName: hasName,
  );
}

/// 点 SC 卡片（SC 页的列表）
void showSuperChatUserCard(
  LiveRoomController controller,
  LiveSuperChatMessage sc,
) {
  var message = LiveMessage(
    type: LiveMessageType.superChat,
    userName: sc.userName,
    message: sc.message,
    color: LiveMessageColor.white,
    data: sc,
    emotes: sc.emotes,
    sticker: sc.sticker,
    userId: sc.userId,
  );
  _show(
    controller,
    ChatUser.ofSuperChat(controller.site.id, sc),
    message,
    after: [
      ChatUserCardAction(
        Icons.copy,
        "复制弹幕".t,
        () => Utils.copyToClipboard(sc.message),
      ),
    ],
    hasName: sc.userName.trim().isNotEmpty,
  );
}

/// 点礼物页的一行
void showGiftUserCard(LiveRoomController controller, LiveGiftMessage gift) {
  _show(
    controller,
    ChatUser.ofGift(controller.site.id, gift),
    gift.toMessage(),
    hasName: gift.userName.trim().isNotEmpty,
  );
}

/// 点榜单上的一个人（屏蔽、备注按用户 ID 认人，榜单给了 ID 时才能用）
void showRankUserCard(
  LiveRoomController controller,
  LiveRankItem item,
  LiveRankBoard board,
) {
  _show(
    controller,
    ChatUser(controller.site.id, userId: item.userId, name: item.userName),
    LiveMessage(
      type: LiveMessageType.chat,
      userName: item.userName,
      message: "",
      color: LiveMessageColor.white,
      face: item.face.isEmpty ? null : item.face,
      badges: item.badges,
      userId: item.userId,
    ),
    body: (_) => RankCardBody(item, board),
    hasName: item.userName.trim().isNotEmpty,
  );
}

/// 用户卡片上面：身份和榜单上的名次、分数
class RankCardBody extends StatelessWidget {
  final LiveRankItem item;
  final LiveRankBoard board;
  const RankCardBody(this.item, this.board, {super.key});

  @override
  Widget build(BuildContext context) {
    var score = LiveRankPanel.scoreTextOf(item);
    var line = [
      "{board}第 {rank} 名".tf({"board": board.title.t, "rank": item.rank}),
      if (score.isNotEmpty) "${board.scoreLabel.t} $score",
      if (item.detail != null) item.detail!,
    ].join(" · ");
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (item.badges.isNotEmpty) ...[
          LiveBadgeChips(item.badges),
          AppStyle.vGap8,
        ],
        Text(line, style: TextStyle(color: Theme.of(context).hintColor)),
      ],
    );
  }
}

void _show(
  LiveRoomController controller,
  ChatUser user,
  LiveMessage message, {
  List<ChatUserCardAction> after = const [],
  WidgetBuilder? body,
  required bool hasName,
}) {
  showChatUserCard(
    user: user,
    blocks: controller.userBlocks,
    body: body ?? (_) => LiveMessageCardBody(message),
    medal: chatUserMedal(controller, message.badges),
    before: [
      ChatUserCardAction(
        Icons.person_search,
        "只看这个人的弹幕".t,
        hasName
            ? () => controller.showUserChat(
                  message.userName,
                  userId: user.userId,
                )
            : null,
      ),
    ],
    after: after,
  );
}

/// [badges] 里的粉丝牌是哪个主播的（卡片第一行），点了在这个窗口打开那个主播的直播间；
/// 没戴牌子、平台没给是谁的时为 null。
/// 斗鱼只给房间号：先写房间号，打开卡片后读一次主播名（[DouyuSite.getRoomOwnerName]）。
/// 别的平台没有主播名时不去读
ChatUserMedal? chatUserMedal(
  LiveRoomController controller,
  List<LiveBadge>? badges,
) {
  for (var medal in badges ?? const <LiveBadge>[]) {
    if (medal.kind != LiveBadgeKind.medal || !medal.hasOwner) {
      continue;
    }
    var site = controller.site;
    var liveSite = site.liveSite;
    var room = medal.ownerRoomId;
    var own = _isRoomMedal(controller, medal);
    return ChatUserMedal(
      title: "粉丝牌：{medal}".tf({
        "medal": [medal.text, if (medal.level != null) medal.level].join(" "),
      }),
      owner: own ? "本直播间".t : _medalOwner(medal, medal.ownerName),
      onTap:
          own || room == null ? null : () => controller.resetRoom(site, room),
      loadOwner: !own &&
              room != null &&
              medal.ownerName == null &&
              liveSite is DouyuSite
          ? () async {
              var name = await liveSite.getRoomOwnerName(roomId: room);
              return name == null ? null : _medalOwner(medal, name);
            }
          : null,
    );
  }
  return null;
}

/// 牌子是谁的：知道主播名 [name] 时写主播名，否则写房间号，都没有时写主播的 uid
String _medalOwner(LiveBadge medal, String? name) {
  if (name != null) {
    return "来自 {name} 的直播间".tf({"name": name});
  }
  var room = medal.ownerRoomId;
  return room != null
      ? "来自直播间 {room}".tf({"room": room})
      : "来自 UID {uid} 的直播间".tf({"uid": medal.ownerUid});
}

/// [medal] 就是这个直播间的牌子：主播的 uid 一样，或者房间号一样
/// （哔哩哔哩可能是用短号进来的，读到的长号也比）
bool _isRoomMedal(LiveRoomController controller, LiveBadge medal) {
  var detail = controller.detail.value;
  var uid = switch (detail?.danmakuData) {
    BiliBiliDanmakuArgs args => args.anchorUid,
    HuyaDanmakuArgs args => args.presenterUid,
    _ => 0,
  };
  var room = medal.ownerRoomId;
  return (uid > 0 && medal.ownerUid == "$uid") ||
      (room != null && (room == controller.roomId || room == detail?.roomId));
}

/// 卡片上面的身份（粉丝牌、头衔等）和这条内容
class LiveMessageCardBody extends StatelessWidget {
  final LiveMessage message;
  const LiveMessageCardBody(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    var size = AppSettingsController.instance.chatTextSize.value;
    var textStyle = TextStyle(
      fontSize: size,
      color: Get.isDarkMode ? Colors.white : AppColors.black333,
    );
    var badges = message.badges;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (badges != null && badges.isNotEmpty) ...[
          LiveBadgeChips(badges),
          AppStyle.vGap8,
        ],
        Text.rich(
          emoteStickerSpan(
                message.sticker,
                fontSize: size,
                style: textStyle,
              ) ??
              emoteTextSpan(
                message.message,
                message.emotes,
                fontSize: size,
                style: textStyle,
              ),
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// 聊天区名字后面灰色的“(备注)”；没有备注时为 null。在 Obx 里调用，备注改了会刷新
InlineSpan? chatRemarkSpan(String siteId, LiveMessage message, double size) {
  var user = ChatUser.ofMessage(siteId, message);
  var remark = ChatUsersService.remarkFor(
    siteId,
    userId: user.userId,
    name: user.name,
  );
  if (remark == null) {
    return null;
  }
  return TextSpan(
    text: " ($remark)",
    style: TextStyle(color: Colors.grey, fontSize: size),
  );
}
