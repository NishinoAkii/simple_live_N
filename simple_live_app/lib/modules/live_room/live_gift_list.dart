import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/modules/live_room/live_gifts.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/rank/live_rank_entry.dart';
import 'package:simple_live_app/modules/live_room/user_card/live_user_card.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/widgets/compact_buttons.dart';
import 'package:simple_live_app/widgets/emote_text.dart';
import 'package:simple_live_app/widgets/floating_header.dart';
import 'package:simple_live_app/widgets/keep_alive_wrapper.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 直播间“礼物”页。浮动按钮那一行左边是“榜单”，点了看榜单、再点回到礼物（默认是礼物）；
/// 设置里关掉“显示榜单”时没有这个按钮，只有礼物
class LiveGiftList extends StatelessWidget {
  final LiveRoomController controller;
  const LiveGiftList({required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    return KeepAliveWrapper(
      child: GiftPageView(
        showRank: () => controller.showRank,
        rankSelected: controller.giftShowRank,
        gifts: (rankButton) => GiftListView(
          book: controller.giftBook,
          version: controller.giftVersion,
          paidOnly: controller.giftPaidOnly,
          leading: rankButton,
          remarkOf: (gift) => ChatUsersService.remarkFor(
            controller.site.id,
            userId: gift.userId,
            name: gift.userName,
          ),
          // 点一行打开用户卡片（屏蔽、备注）
          onTap: (gift) => showGiftUserCard(controller, gift),
        ),
        rank: (rankButton) => buildRankPanel(controller, leading: rankButton),
      ),
    );
  }
}

/// 礼物页的两个视图：[gifts]（礼物列表）和 [rank]（榜单），由 [rankSelected] 切换。
/// 两个视图都把“榜单”按钮（[RankViewButton]）放在浮动按钮那一行的最左边：
/// 点一下看榜单（按钮高亮），再点一下回到礼物
class GiftPageView extends StatelessWidget {
  /// 设置里开着“显示榜单”（在 Obx 里调用）
  final bool Function() showRank;
  final RxBool rankSelected;
  final Widget Function(Widget? rankButton) gifts;
  final Widget Function(Widget rankButton) rank;
  const GiftPageView({
    required this.showRank,
    required this.rankSelected,
    required this.gifts,
    required this.rank,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!showRank()) {
        return gifts(null);
      }
      var button = RankViewButton(rankSelected: rankSelected);
      return rankSelected.value ? rank(button) : gifts(button);
    });
  }
}

/// 礼物页的“榜单”按钮：和“只看付费”一样的小按钮，看榜单时高亮
class RankViewButton extends StatelessWidget {
  final RxBool rankSelected;
  const RankViewButton({required this.rankSelected, super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => FloatingPill(
        label: "榜单".t,
        selected: rankSelected.value,
        onTap: () => rankSelected.value = !rankSelected.value,
      ),
    );
  }
}

/// 礼物列表：本场收到的全部礼物（含免费礼物），每行右边是送礼时间。
/// 默认和弹幕一样最新的在下面，可以换到上面（和 SC 页共用）。
/// 礼物不进聊天，也不进视频弹幕。按钮浮在列表上面，列表从按钮下面排起
class GiftListView extends StatelessWidget {
  final GiftBook book;

  /// 礼物有变化时加一
  final RxInt version;
  final RxBool paidOnly;

  /// 浮动按钮那一行最左边的东西（“榜单”按钮），没有时为 null
  final Widget? leading;
  final String? Function(LiveGiftMessage gift)? remarkOf;
  final void Function(LiveGiftMessage gift)? onTap;
  const GiftListView({
    required this.book,
    required this.version,
    required this.paidOnly,
    this.leading,
    this.remarkOf,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    var settings = AppSettingsController.instance;
    return Obx(() {
      version.value;
      var paid = paidOnly.value;
      var atBottom = settings.noticeNewestAtBottom.value;
      var all = book.records;
      var list = paid ? all.where((e) => e.gift.paid).toList() : all;
      var pills = <Widget>[
        FloatingPill(
          label: paid ? "只看付费 {listCount}".tf({"listCount": list.length}) : "只看付费".t,
          selected: paid,
          onTap: () => paidOnly.value = !paid,
        ),
        NoticeOrderButton(atBottom: atBottom),
      ];
      // 列表占满整页，按钮半透明地浮在上面，礼物从下面滚过
      return FloatingHeader(
        header: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左边空着的地方放“榜单”，右边的按钮还在原来的位置
              if (leading != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: leading,
                ),
              // 窄的时候右边的按钮换行，不和左边的挤在一起
              Expanded(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: pills,
                ),
              ),
            ],
          ),
        ),
        body: (context, top) => list.isEmpty
            ? Padding(
                padding: EdgeInsets.only(top: top),
                child: Center(
                  child: Text(
                    "还没有收到礼物".t,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
              )
            : ListView.builder(
                // 最新的在下面：倒着排，停在最下面时新礼物从下面出来
                reverse: atBottom,
                padding: EdgeInsets.only(top: top + 4, bottom: 4),
                itemCount: list.length,
                itemBuilder: (_, i) {
                  var record = list[list.length - 1 - i];
                  return GiftRow(
                    record,
                    remark: remarkOf?.call(record.gift),
                    onTap: onTap == null ? null : () => onTap!(record.gift),
                  );
                },
              ),
      );
    });
  }
}

/// 开通、续费（舰长、钻粉、贵族、订阅、会员）标成小标签：开通绿色，续费蓝色
Color? giftActionColor(String action) => switch (action) {
      "开通" || "加入" => const Color(0xff2e9d55),
      "续费" || "续订" || "自动续费" => const Color(0xff3478d4),
      _ => null,
    };

/// SC 页和礼物页顶栏的“最新的在下面 / 上面”切换（两页共用）
class NoticeOrderButton extends StatelessWidget {
  final bool atBottom;
  const NoticeOrderButton({required this.atBottom, super.key});

  @override
  Widget build(BuildContext context) => FloatingRoundButton(
        tooltip: atBottom ? "最新在下，点击切换为最新在上".t : "最新在上，点击切换为最新在下".t,
        icon: atBottom ? Icons.arrow_downward : Icons.arrow_upward,
        onPressed: () =>
            AppSettingsController.instance.setNoticeNewestAtBottom(!atBottom),
      );
}

/// 礼物页的一行：“头像 用户 投喂 [图] 小心心 ×3   ¥0.3  20:15:32”
class GiftRow extends StatelessWidget {
  final GiftRecord record;

  /// 给送礼人写的备注，名字后面灰色显示
  final String? remark;
  final VoidCallback? onTap;
  const GiftRow(this.record, {this.remark, this.onTap, super.key});

  static String timeText(DateTime time) {
    var t = time.toLocal();
    String two(int v) => v.toString().padLeft(2, "0");
    return "${two(t.hour)}:${two(t.minute)}:${two(t.second)}";
  }

  @override
  Widget build(BuildContext context) {
    var gift = record.gift;
    var grey = Theme.of(context).hintColor;
    var icon = gift.icon;
    const price = ""; // 不显示礼物的价格
    var row = Opacity(
      opacity: gift.paid ? 1 : 0.6,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (gift.face.isNotEmpty) ...[
              ClipOval(
                child: NetImage(gift.face, width: 24, height: 24),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: gift.userName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    if (remark != null)
                      TextSpan(
                        text: " ($remark)",
                        style: TextStyle(color: grey),
                      ),
                    if (giftActionColor(gift.action) case var color?)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: color.withAlpha(40),
                            border: Border.all(color: color),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            gift.action,
                            style: TextStyle(fontSize: 11, color: color),
                          ),
                        ),
                      )
                    else
                      TextSpan(text: " ${gift.action.t} "),
                    if (icon != null)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 2),
                          child: EmoteImage(icon, height: 22, maxWidth: 40),
                        ),
                      ),
                    TextSpan(text: "${gift.giftName}##gift".t),
                    if (gift.count > 1)
                      TextSpan(
                        text: " ×${gift.count}",
                        style: const TextStyle(
                          color: Color(0xffe0a020),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
                style: const TextStyle(fontSize: 14),
              ),
            ),
            if (price.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(price, style: TextStyle(fontSize: 12, color: grey)),
            ],
            const SizedBox(width: 8),
            Text(
              timeText(record.time),
              style: TextStyle(
                fontSize: 12,
                color: grey,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}
