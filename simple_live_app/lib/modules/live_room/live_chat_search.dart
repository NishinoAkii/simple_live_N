import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/name_color.dart';
import 'package:simple_live_app/modules/live_room/chat_face.dart';
import 'package:simple_live_app/modules/live_room/chat_log.dart';
import 'package:simple_live_app/modules/live_room/danmaku_export_dialog.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/user_card/live_user_card.dart';
import 'package:simple_live_app/widgets/compact_buttons.dart';
import 'package:simple_live_app/widgets/emote_text.dart';
import 'package:simple_live_app/widgets/tail_list_view.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 直播间“聊天”页：实时聊天，以及按内容/用户搜索收到过的弹幕
class LiveChatSearchView extends StatelessWidget {
  final LiveRoomController controller;

  /// 实时聊天列表，搜索时留在后台继续接收和滚动
  final Widget chatList;
  const LiveChatSearchView({
    required this.controller,
    required this.chatList,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    // 竖屏时键盘会把聊天区挤得很小，改在底部弹窗里输入
    var portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    return Obx(() {
      var showBar = controller.chatSearchOpen.value && !portrait;
      var searching = controller.chatSearchTitle.value.isNotEmpty;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showBar)
            Padding(
              key: const ValueKey("chat_search_bar"),
              padding: const EdgeInsets.fromLTRB(8, 6, 4, 2),
              child: LiveChatSearchField(controller: controller),
            ),
          if (searching) buildResultHeader(),
          if (showBar || searching) const Divider(height: 1),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                IndexedStack(
                  index: searching ? 1 : 0,
                  sizing: StackFit.expand,
                  children: [
                    chatList,
                    searching
                        ? _ChatSearchResults(controller: controller)
                        : const SizedBox.shrink(),
                  ],
                ),
                if (!showBar)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FloatingRoundButton(
                          tooltip: "导出弹幕（ASS）".t,
                          icon: Icons.file_download_outlined,
                          onPressed: () => showLiveExportDialog(controller),
                        ),
                        FloatingRoundButton(
                          tooltip: AppSettingsController
                                  .instance.chatNewestAtBottom.value
                              ? "最新在下，点击切换为最新在上".t
                              : "最新在上，点击切换为最新在下".t,
                          icon: AppSettingsController
                                  .instance.chatNewestAtBottom.value
                              ? Icons.arrow_downward
                              : Icons.arrow_upward,
                          onPressed: () {
                            var settings = AppSettingsController.instance;
                            settings.setChatNewestAtBottom(
                                !settings.chatNewestAtBottom.value);
                            // 换了方向从最新的一端看起
                            controller.chatList.jumpToLatest();
                            controller.chatSearchList.jumpToLatest();
                          },
                        ),
                        FloatingRoundButton(
                          tooltip: "搜索弹幕".t,
                          icon: Icons.search,
                          onPressed: () {
                            if (portrait) {
                              showLiveChatSearchSheet(controller);
                            } else {
                              controller.openChatSearch();
                            }
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    });
  }

  Widget buildResultHeader() {
    return Padding(
      key: const ValueKey("chat_search_header"),
      padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              controller.chatSearchTitle.value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ),
          Obx(
            () => Text(
              " · {chatSearchResultsCount} 条".tf({"chatSearchResultsCount": controller.chatSearchResults.length}),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ),
          TextButton(
            onPressed: controller.closeChatSearch,
            child: Text("返回实时弹幕".t),
          ),
        ],
      ),
    );
  }
}

/// 搜索结果列表，按接收时间排列，最新的在最下面
class _ChatSearchResults extends StatefulWidget {
  final LiveRoomController controller;
  const _ChatSearchResults({required this.controller});

  @override
  State<_ChatSearchResults> createState() => _ChatSearchResultsState();
}

class _ChatSearchResultsState extends State<_ChatSearchResults> {
  LiveRoomController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // 切换页签或旋转屏幕后重新显示时，回到最新的结果
    controller.chatSearchList.jumpToLatest();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      var results = controller.chatSearchResults;
      if (results.isEmpty) {
        return Center(
          child: Padding(
            padding: AppStyle.edgeInsetsA12,
            child: Text(
              controller.chatSearchBusy.value
                  ? "正在搜索…".t
                  : "没找到相关弹幕\n只能搜进直播间后收到的弹幕".t,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ),
        );
      }
      return TailListView(
        controller: controller.chatSearchList,
        newestFirst: !AppSettingsController.instance.chatNewestAtBottom.value,
        padding: AppStyle.edgeInsetsA8,
        itemBuilder: (_, i) {
          var item = results[i];
          return LiveChatRecordRow(
            item: item,
            siteId: controller.site.id,
            onTap: () => showLiveChatActions(controller, item.message),
          );
        },
      );
    });
  }
}

/// 搜索输入框和“内容/用户”切换
class LiveChatSearchField extends StatelessWidget {
  final LiveRoomController controller;

  /// 在底部弹窗中显示：提交后关闭弹窗，右侧按钮只清空输入
  final bool inSheet;
  const LiveChatSearchField({
    required this.controller,
    this.inSheet = false,
    super.key,
  });

  void submit(BuildContext context) {
    // 弹窗正在关闭时不要再 pop，否则会退出直播间
    if (inSheet && (ModalRoute.of(context)?.isCurrent ?? false)) {
      Navigator.of(context).pop();
    }
    controller.searchChat();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      var byUser = controller.chatSearchByUser.value;
      // 一行：输入框、内容/用户、搜索（按钮看起来小，点击范围 40 像素）
      return Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller.chatSearchInputController,
              // 侧栏里的输入框可能随页签切换重建，只在展开时聚焦
              focusNode: inSheet ? null : controller.chatSearchFocusNode,
              autofocus: inSheet,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: byUser ? "搜索用户名".t : "搜索弹幕内容".t,
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                suffixIconConstraints:
                    const BoxConstraints.tightFor(width: 36, height: 36),
                suffixIcon: inSheet
                    ? IconButton(
                        tooltip: "清空".t,
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: controller.chatSearchInputController.clear,
                      )
                    : IconButton(
                        tooltip: "关闭搜索".t,
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: controller.closeChatSearch,
                      ),
              ),
              onSubmitted: (_) => submit(context),
            ),
          ),
          const SizedBox(width: 6),
          SmallToggle(
            label: byUser ? "用户".t : "内容".t,
            selected: true,
            onTap: () => controller.chatSearchByUser.value = !byUser,
          ),
          IconButton(
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            iconSize: 20,
            tooltip: "搜索".t,
            icon: const Icon(Icons.search),
            onPressed: () => submit(context),
          ),
        ],
      );
    });
  }
}

/// 竖屏时在底部弹窗里输入搜索内容
void showLiveChatSearchSheet(LiveRoomController controller) {
  showModalBottomSheet(
    context: Get.context!,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 600),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: SafeArea(
        child: Padding(
          padding: AppStyle.edgeInsetsA12,
          child: LiveChatSearchField(controller: controller, inSheet: true),
        ),
      ),
    ),
  );
}

/// 点一条弹幕弹出的卡片：上面是发言人、身份（粉丝牌、头衔等）和内容，
/// 下面一行一个操作：只看这个人的弹幕、
/// 屏蔽这个人 ›、备注、复制弹幕、搜索这条弹幕。
/// 卡片在 user_card/chat_user_card.dart
void showLiveChatActions(LiveRoomController controller, LiveMessage message) =>
    showLiveChatCard(controller, message);

/// 搜索结果中的一行：接收时间、用户名、内容
class LiveChatRecordRow extends StatelessWidget {
  final LiveChatRecord item;
  final VoidCallback onTap;

  /// 平台（名字后面的备注按平台查）
  final String siteId;
  const LiveChatRecordRow({
    required this.item,
    required this.onTap,
    this.siteId = "",
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onTap,
      borderRadius: AppStyle.radius4,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Obx(() {
          var size = AppSettingsController.instance.chatTextSize.value;
          var face = chatFaceSpan(item.message, size);
          var badgeSpan = chatBadgeSpan(item.message, size);
          var bodyStyle = TextStyle(
            color: Get.isDarkMode ? Colors.white : AppColors.black333,
          );
          var nameStyle = TextStyle(
            color: (AppSettingsController.instance.chatNameColor.value
                    ? chatNameColor(
                        item.message.nameColor,
                        dark: Get.isDarkMode,
                      )
                    : null) ??
                Colors.grey,
          );
          var remark = chatRemarkSpan(siteId, item.message, size);
          return Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: "${Utils.timeFormat.format(item.time)}  ",
                  style: TextStyle(
                    fontSize: size * 0.85,
                    color: Colors.grey,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (face != null) face,
                if (badgeSpan != null) badgeSpan,
                // 有备注时名字后面跟着灰色的“(备注)”
                if (remark == null)
                  TextSpan(
                    text: "${item.message.userName}${"：".t}",
                    style: nameStyle,
                  )
                else ...[
                  TextSpan(text: item.message.userName, style: nameStyle),
                  remark,
                  TextSpan(text: "：".t, style: nameStyle),
                ],
                emoteStickerSpan(
                      item.message.sticker,
                      fontSize: size,
                      style: bodyStyle,
                    ) ??
                    emoteTextSpan(
                      item.message.message,
                      item.message.emotes,
                      fontSize: size,
                      style: bodyStyle,
                    ),
              ],
            ),
            style: TextStyle(fontSize: size),
          );
        }),
      ),
    );
  }
}
