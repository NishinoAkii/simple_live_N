import 'dart:io';

import 'package:floating/floating.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/multi_window/multi_window_widgets.dart';
import 'package:simple_live_app/app/player_lock.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/window_pin.dart';
import 'package:simple_live_app/app/name_color.dart';
import 'package:simple_live_app/modules/live_room/chat_face.dart';
import 'package:simple_live_app/modules/live_room/live_chat_search.dart';
import 'package:simple_live_app/modules/live_room/listen_card.dart';
import 'package:simple_live_app/modules/live_room/listen_mode.dart';
import 'package:simple_live_app/modules/live_room/live_gift_list.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_shortcuts.dart';
import 'package:simple_live_app/modules/live_room/live_room_tabs.dart';
import 'package:simple_live_app/modules/live_room/player/player_controls.dart';
import 'package:simple_live_app/modules/live_room/room_notice_card.dart';
import 'package:simple_live_app/modules/live_room/room_stats_line.dart';
import 'package:simple_live_app/modules/live_room/user_card/live_user_card.dart';
import 'package:simple_live_app/modules/live_room/user_card/user_block_list.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/live_notify_service.dart';
import 'package:simple_live_app/widgets/follow_actions_sheet.dart';
import 'package:simple_live_app/widgets/shown_in_tab.dart';
import 'package:simple_live_app/widgets/adaptive_tab_bar.dart';
import 'package:simple_live_app/widgets/compact_buttons.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/emote_text.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/ios_pip_placeholder.dart';
import 'package:simple_live_app/widgets/keep_alive_wrapper.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/resizable_side_panel.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/catch_up_settings.dart';
import 'package:simple_live_app/widgets/settings/room_specific_settings.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_number.dart';
import 'package:simple_live_app/widgets/settings/settings_menu.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_app/widgets/site_logo.dart';
import 'package:simple_live_app/widgets/superchat_card.dart';
import 'package:simple_live_app/widgets/tail_list_view.dart';
import 'package:simple_live_core/simple_live_core.dart';

class LiveRoomPage extends GetView<LiveRoomController> {
  const LiveRoomPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final page = Obx(
      () {
        if (controller.loadError.value) {
          return Scaffold(
            appBar: AppBar(
              title: Text("直播间加载失败".t),
            ),
            body: Padding(
              padding: AppStyle.edgeInsetsA12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Icon(
                      Remix.error_warning_line,
                      size: 72,
                      color: Colors.grey,
                    ),
                  ),
                  Text(
                    "直播间加载失败".t,
                    textAlign: TextAlign.center,
                  ),
                  AppStyle.vGap4,
                  Text(
                    controller.error?.toString() ?? "未知错误".t,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  AppStyle.vGap4,
                  Text(
                    "${controller.rxSite.value.id} - ${controller.rxRoomId.value}",
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: controller.copyErrorDetail,
                        icon: const Icon(Remix.file_copy_line),
                        label: Text("复制信息".t),
                      ),
                      TextButton.icon(
                        onPressed: controller.refreshRoom,
                        icon: const Icon(Remix.refresh_line),
                        label: Text("刷新".t),
                      ),
                    ],
                  )
                ],
              ),
            ),
          );
        }
        if (controller.fullScreenState.value) {
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (e, r) {
              // 锁定时返回键、返回手势不退出全屏
              if (controller.lockControlsState.value) {
                PlayerLock.showTip();
                return;
              }
              controller.exitFull();
            },
            child: Scaffold(
              body: buildMediaPlayer(),
            ),
          );
        } else {
          return buildPageUI();
        }
      },
    );
    // 快捷键
    var keyed = LiveRoomShortcuts(controller: controller, child: page);
    if (!Platform.isAndroid) {
      return keyed;
    }
    return PiPSwitcher(
      floating: controller.pip,
      childWhenDisabled: keyed,
      childWhenEnabled: buildMediaPlayer(),
    );
  }

  Widget buildPageUI() {
    return OrientationBuilder(
      builder: (context, orientation) {
        // 弹出键盘时收起主播信息、标签栏和底栏：聊天区多留些空间，
        // 点空白处收起键盘时也不会误点到“取消关注”
        var typing = MediaQuery.viewInsetsOf(context).bottom > 0;
        return Scaffold(
          appBar: AppBar(
            title: Obx(
              () => Text(controller.detail.value?.title ?? "直播间".t),
            ),
            actions: [
              // 电脑：这个窗口置顶或回到正常层（主窗口、多开窗口各管各的）
              if (WindowPin.supported) const WindowPinButton(),
              // 宽屏：收起、展开右侧的聊天栏
              if (orientation == Orientation.landscape)
                LiveChatToggleButton(controller: controller),
              ...buildAppbarActions(context),
            ],
          ),
          body: orientation == Orientation.portrait
              ? buildPhoneUI(context, typing)
              : buildTabletUI(context, typing),
        );
      },
    );
  }

  Widget buildPhoneUI(BuildContext context, bool typing) {
    // 用 Visibility 占着位置：隐藏时后面的聊天区不会重建，输入框不会失去焦点
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: buildMediaPlayer(),
        ),
        Visibility(
          visible: !typing,
          child: buildUserProfile(context),
        ),
        buildMessageArea(showTabs: !typing),
        Visibility(
          visible: !typing,
          child: buildBottomActions(context),
        ),
      ],
    );
  }

  Widget buildTabletUI(BuildContext context, bool typing) {
    // 侧栏可拖动左边缘调整宽度
    var sidePanel = ResizableSidePanel(
      storageKey: "LiveSidePanelWidth",
      defaultWidth: 300,
      child: Column(
        children: [
          Visibility(
            visible: !typing,
            child: buildUserProfile(context),
          ),
          buildMessageArea(showTabs: !typing),
        ],
      ),
    );
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: buildMediaPlayer(),
              ),
              // 可以收起（快捷键 C 或标题栏的按钮）
              Obx(
                () => Visibility(
                  visible:
                      !LiveRoomKeyState.of(controller).chatCollapsed.value,
                  maintainState: true,
                  child: sidePanel,
                ),
              ),
            ],
          ),
        ),
        Visibility(
          visible: !typing,
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              border: Border(
                top: BorderSide(
                  color: Colors.grey.withAlpha(25),
                ),
              ),
            ),
            padding: AppStyle.edgeInsetsV4.copyWith(
              bottom: AppStyle.bottomBarHeight + 4,
            ),
            child: Row(
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 14),
                  ),
                  onPressed: controller.refreshRoom,
                  icon: const Icon(Remix.refresh_line),
                  label: Text("刷新".t),
                ),
                AppStyle.hGap4,
                Obx(
                  () => controller.followed.value
                      ? TextButton.icon(
                          style: TextButton.styleFrom(
                            textStyle: const TextStyle(fontSize: 14),
                          ),
                          onPressed: controller.removeFollowUser,
                          icon: const Icon(Remix.heart_fill),
                          label: Text("取消关注".t),
                        )
                      : TextButton.icon(
                          style: TextButton.styleFrom(
                            textStyle: const TextStyle(fontSize: 14),
                          ),
                          onPressed: controller.followUser,
                          icon: const Icon(Remix.heart_line),
                          label: Text("关注".t),
                        ),
                ),
                const Expanded(child: Center()),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 14),
                  ),
                  onPressed: controller.share,
                  icon: const Icon(Remix.share_line),
                  label: Text("分享".t),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 14),
                  ),
                  onPressed: controller.copyUrl,
                  icon: const Icon(Remix.file_copy_line),
                  label: Text("复制链接".t),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 14),
                  ),
                  onPressed: controller.copyPlayUrl,
                  icon: const Icon(Remix.file_copy_line),
                  label: Text("复制播放直链".t),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 播放器；听直播时换成主播卡片（视频轨已关，见 listen_mode.dart）
  Widget buildMediaPlayer() {
    var video = buildVideoPlayer();
    return Obx(
      () => controller.listen.active.value
          ? ListenCard(controller: controller)
          : video,
    );
  }

  Widget buildVideoPlayer() {
    var boxFit = BoxFit.contain;
    double? aspectRatio;
    if (AppSettingsController.instance.scaleMode.value == 0) {
      boxFit = BoxFit.contain;
    } else if (AppSettingsController.instance.scaleMode.value == 1) {
      boxFit = BoxFit.fill;
    } else if (AppSettingsController.instance.scaleMode.value == 2) {
      boxFit = BoxFit.cover;
    } else if (AppSettingsController.instance.scaleMode.value == 3) {
      boxFit = BoxFit.contain;
      aspectRatio = 16 / 9;
    } else if (AppSettingsController.instance.scaleMode.value == 4) {
      boxFit = BoxFit.contain;
      aspectRatio = 4 / 3;
    }
    return Stack(
      children: [
        Video(
          key: controller.globalPlayerKey,
          controller: controller.videoController,
          // 进入后台自动暂停、回来时重新拉流由直播间自己做（onLifecycleForPause）
          pauseUponEnteringBackgroundMode: false,
          resumeUponEnteringForegroundMode: false,
          controls: (state) {
            return playerControls(state, controller);
          },
          aspectRatio: aspectRatio,
          fit: boxFit,
          // 自己实现
          wakelock: false,
        ),
        Obx(
          () => Visibility(
            visible: !controller.liveStatus.value,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "未开播".t,
                    style: const TextStyle(fontSize: 16, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),
        // iOS 画中画开着时应用内显示黑屏和提示
        IosPipPlaceholder(session: controller.iosPip),
      ],
    );
  }

  Widget buildUserProfile(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          top: BorderSide(
            color: Colors.grey.withAlpha(25),
          ),
          bottom: BorderSide(
            color: Colors.grey.withAlpha(25),
          ),
        ),
      ),
      padding: AppStyle.edgeInsetsA8.copyWith(
        left: 12,
        right: 12,
      ),
      child: Obx(
        () => Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.withAlpha(50)),
                borderRadius: AppStyle.radius24,
              ),
              child: NetImage(
                controller.detail.value?.userAvatar ?? "",
                width: 48,
                height: 48,
                borderRadius: 24,
              ),
            ),
            AppStyle.hGap12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 第一行：主播名 + 热度
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          controller.detail.value?.userName ?? "",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      AppStyle.hGap12,
                      // 点热度（在线人数）打开礼物页里的榜单
                      OnlineCountTap(
                        onTap: controller.showRank ? controller.openRank : null,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Remix.fire_fill,
                              size: 20,
                              color: Colors.orange,
                            ),
                            AppStyle.hGap4,
                            // 进直播间时是房间信息里的数，之后跟着弹幕连接的推送变；
                            // 单独刷新，不带着整行重画
                            Obx(
                              () => Text(
                                Utils.onlineToString(controller.online.value),
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  AppStyle.vGap4,
                  // 第二行：平台 + 在线人数、贵宾数、看过、点赞（平台有才显示）
                  RoomStatsRow(
                    logo: SiteLogo(
                      controller.site,
                      width: 20,
                    ),
                    name: controller.site.name,
                    // 这几个数跟着弹幕连接变，单独刷新，不带着整行重画；
                    // 点在线人数这一行也打开榜单
                    stats: OnlineCountTap(
                      onTap: controller.showRank ? controller.openRank : null,
                      child: Obx(
                        () => RoomStatsLine(controller.roomStats.value),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildBottomActions(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          top: BorderSide(
            color: Colors.grey.withAlpha(25),
          ),
        ),
      ),
      padding: EdgeInsets.only(bottom: AppStyle.bottomBarHeight),
      child: Row(
        children: [
          Expanded(
            child: Obx(
              () => controller.followed.value
                  ? TextButton.icon(
                      style: TextButton.styleFrom(
                        textStyle: const TextStyle(fontSize: 14),
                      ),
                      onPressed: controller.removeFollowUser,
                      icon: const Icon(Remix.heart_fill),
                      label: Text("取消关注".t),
                    )
                  : TextButton.icon(
                      style: TextButton.styleFrom(
                        textStyle: const TextStyle(fontSize: 14),
                      ),
                      onPressed: controller.followUser,
                      icon: const Icon(Remix.heart_line),
                      label: Text("关注".t),
                    ),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              style: TextButton.styleFrom(
                textStyle: const TextStyle(fontSize: 14),
              ),
              onPressed: controller.refreshRoom,
              icon: const Icon(Remix.refresh_line),
              label: Text("刷新".t),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              style: TextButton.styleFrom(
                textStyle: const TextStyle(fontSize: 14),
              ),
              onPressed: controller.share,
              icon: const Icon(Remix.share_line),
              label: Text("分享".t),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildMessageArea({bool showTabs = true}) {
    // 切换直播间时整组标签页重建，避免沿用上一个直播间的内容
    return Expanded(
      child: Obx(
        () {
          var tabs = liveRoomTabs(
            superChat: controller.supportsSuperChat,
            gifts: controller.supportsGifts,
          );
          return DefaultTabController(
            key: ValueKey("tabs_${controller.site.id}_${controller.roomId}"),
            length: tabs.length,
            child: Column(
              children: [
                // 点在线人数时切到礼物页（看榜单）；不占地方
                LiveRoomTabJumper(
                  tabs: tabs,
                  jumps: controller.tabJumps,
                  child: const SizedBox.shrink(),
                ),
                // 平均分布占满整栏，侧栏很宽时靠左，太窄时横向滚动
                Visibility(
                  visible: showTabs,
                  child: AdaptiveTabBar(
                    tabs: [
                      for (var tab in tabs)
                        liveRoomTabLabel(
                          tab,
                          superChat: Obx(
                            () {
                              // 标题显示直播间里仍在显示的 SC 数量，随时间刷新
                              controller.scNow.value;
                              var active = controller.superChats
                                  .where(controller.isSuperChatActive)
                                  .length;
                              return Text(active > 0 ? "SC($active)" : "SC");
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      for (var tab in tabs)
                        switch (tab) {
                          LiveRoomTab.chat => LiveChatSearchView(
                              controller: controller,
                              chatList: buildChatList(),
                            ),
                          LiveRoomTab.superChat => buildSuperChats(),
                          LiveRoomTab.gifts =>
                            LiveGiftList(controller: controller),
                          LiveRoomTab.follow => buildFollowList(
                              tabIndex: tabs.indexOf(LiveRoomTab.follow),
                            ),
                          LiveRoomTab.settings => buildSettings(),
                        },
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget buildChatList() {
    return Obx(() {
      // 最新的在下面（默认）或上面，聊天页右上角的箭头切换
      var atBottom = AppSettingsController.instance.chatNewestAtBottom.value;
      // 公告卡片浮在列表顶上，消息从它下面滚过；列表顶部留出它的高度，
      // 消息少的时候（或最新在上时）不会被它挡住
      var cardBottom = controller.roomNotice.inset.value;
      return Stack(
        children: [
          // 聊天列表滚起来了（新消息多到一屏放不下，或者用户自己滑），公告卡片收成小条
          NotificationListener<Notification>(
            onNotification: (n) {
              if (n is UserScrollNotification &&
                  n.depth == 0 &&
                  n.direction != ScrollDirection.idle) {
                controller.roomNotice.chatScrolled(byUser: true);
              } else if (n is ScrollMetricsNotification &&
                  n.depth == 0 &&
                  n.metrics.maxScrollExtent > 0.5) {
                controller.roomNotice.chatScrolled(byUser: false);
              }
              return false;
            },
            child: TailListView(
              controller: controller.chatList,
              newestFirst: !atBottom,
              padding: cardBottom > 0
                  ? AppStyle.edgeInsetsA12.copyWith(top: cardBottom + 8)
                  : AppStyle.edgeInsetsA12,
              itemBuilder: (_, i) {
                var item = buildMessageItem(controller.chatLog[i].message);
                // 行间距加在每条的上方，最上面那条不加（最新在上时是最新的一条）
                if (atBottom ? i == 0 : i == controller.chatLog.length - 1) {
                  return item;
                }
                return Obx(
                  () => Padding(
                    // *2与原来的EdgeInsets.symmetric(vertical: )做兼容
                    padding: EdgeInsets.only(
                      top: AppSettingsController.instance.chatTextGap.value * 2,
                    ),
                    child: item,
                  ),
                );
              },
            ),
          ),
          Obx(
            () => Visibility(
              visible: !controller.chatList.following.value,
              child: Positioned(
                right: 12,
                // 最新的在上面时按钮放在上面（右上角的按钮下方、公告卡片下方）
                top: atBottom ? null : (cardBottom + 8 > 52 ? cardBottom + 8 : 52),
                bottom: atBottom ? 12 : null,
                child: ElevatedButton.icon(
                  onPressed: () => controller.chatList.jumpToLatest(),
                  icon: Icon(atBottom ? Icons.expand_more : Icons.expand_less),
                  label: Text("最新".t),
                ),
              ),
            ),
          ),
          RoomNoticeOverlay(controller: controller),
        ],
      );
    });
  }

  Widget buildMessageItem(LiveMessage message) {
    if (message.userName == "LiveSysMessage") {
      return Obx(
        () => Text(
          message.message,
          style: TextStyle(
            color: Colors.grey,
            fontSize: AppSettingsController.instance.chatTextSize.value,
          ),
        ),
      );
    }

    // 点击（或长按）弹出“只看这个人的弹幕 / 复制弹幕”
    return InkWell(
      onTap: () => showLiveChatActions(controller, message),
      onLongPress: () => showLiveChatActions(controller, message),
      borderRadius: AppStyle.radius4,
      child: buildMessageContent(message),
    );
  }

  Widget buildMessageContent(LiveMessage message) {
    return Obx(
      () => AppSettingsController.instance.chatBubbleStyle.value
          ? Row(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blueGrey.withAlpha(25),
                      //borderRadius: AppStyle.radius8,
                      borderRadius: const BorderRadius.only(
                        topRight: Radius.circular(12),
                        bottomLeft: Radius.circular(12),
                        bottomRight: Radius.circular(12),
                      ),
                    ),
                    padding:
                        AppStyle.edgeInsetsA4.copyWith(left: 12, right: 12),
                    child: Text.rich(buildMessageSpan(message)),
                  ),
                ),
              ],
            )
          : Text.rich(buildMessageSpan(message)),
    );
  }

  /// 名字和正文；表情显示为图片（平台给出图片、且开着“弹幕显示表情图片”时）
  InlineSpan buildMessageSpan(LiveMessage message) {
    var size = AppSettingsController.instance.chatTextSize.value;
    var bodyStyle = TextStyle(
      color: Get.isDarkMode ? Colors.white : AppColors.black333,
    );
    // 用户名用发言人自己的颜色（Twitch、Kick），可以在聊天区设置里关掉
    var nameColor = AppSettingsController.instance.chatNameColor.value
        ? chatNameColor(message.nameColor, dark: Get.isDarkMode)
        : null;
    // 有备注时名字后面跟着灰色的“(备注)”（视频弹幕上不显示）
    var remark = chatRemarkSpan(controller.site.id, message, size);
    return withChatFace(
      message,
      TextSpan(
        text: remark == null
            ? "${message.userName}${"：".t}"
            : message.userName,
        style: TextStyle(color: nameColor ?? Colors.grey, fontSize: size),
        children: [
          if (remark != null) ...[remark, TextSpan(text: "：".t)],
          emoteStickerSpan(message.sticker, fontSize: size, style: bodyStyle) ??
              emoteTextSpan(
                message.message,
                message.emotes,
                fontSize: size,
                style: bodyStyle,
              ),
        ],
      ),
    );
  }

  /// 有头像时（如 YouTube）在名字前加上头像，开了“聊天栏显示牌子”时再加上牌子；
  /// 气泡和普通样式都一样
  InlineSpan withChatFace(LiveMessage message, InlineSpan span) {
    var size = AppSettingsController.instance.chatTextSize.value;
    var face = chatFaceSpan(message, size);
    var badges = chatBadgeSpan(message, size);
    if (face == null && badges == null) {
      return span;
    }
    return TextSpan(
      children: [
        if (face != null) face,
        if (badges != null) badges,
        span,
      ],
    );
  }

  Widget buildSuperChats() {
    // 列表占满整页，切换按钮半透明地浮在右上角，SC 从下面滚过
    return KeepAliveWrapper(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Obx(
            () {
              // 依赖每秒更新的时间，倒计时和状态随之刷新
              controller.scNow.value;
              // 顺序和以前一样（还在显示的在前，已结束的在后）；
              // 默认从下往上排（和弹幕一样贴着底部），可以换成从上往下
              var atBottom =
                  AppSettingsController.instance.noticeNewestAtBottom.value;
              var list = controller.sortedSuperChats;
              return ListView.separated(
                reverse: atBottom,
                padding: AppStyle.edgeInsetsA12,
                itemCount: list.length,
                separatorBuilder: (_, i) => AppStyle.vGap12,
                itemBuilder: (_, i) {
                  var item = list[i];
                  // 点 SC 打开用户卡片（屏蔽、备注）
                  return GestureDetector(
                    key: ValueKey(controller.superChatKey(item)),
                    onTap: () => showSuperChatUserCard(controller, item),
                    child: SuperChatCard(
                      item,
                      remaining: controller.superChatRemaining(item),
                      remark: ChatUsersService.remarkFor(
                        controller.site.id,
                        userId: item.userId,
                        name: item.userName,
                      ),
                    ),
                  );
                },
              );
            },
          ),
          Positioned(
            top: 4,
            right: 4,
            child: Obx(() {
              var settings = AppSettingsController.instance;
              var mode = settings.superChatDisplayMode.value;
              void setMode(int value) {
                settings.setSuperChatDisplayMode(value);
                controller.trimSuperChats();
              }

              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingPill(
                    label: "到时消失".t,
                    selected: mode == 0,
                    onTap: () => setMode(0),
                  ),
                  FloatingPill(
                    label: "一直显示".t,
                    selected: mode == 1,
                    onTap: () => setMode(1),
                  ),
                  NoticeOrderButton(
                    atBottom: settings.noticeNewestAtBottom.value,
                  ),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget buildSettings() {
    return ListView(
      padding: AppStyle.edgeInsetsA12,
      children: [
        // 这个直播间、这个平台单独设置（打开后下面的设置都只对它生效）
        const RoomSpecificSettings(),
        Obx(
          () => Visibility(
            visible: controller.autoExitEnable.value,
            child: ListTile(
              leading: const Icon(Icons.timer_outlined),
              visualDensity: VisualDensity.compact,
              title: Text("{parseDuration}后自动关闭".tf({"parseDuration": parseDuration(controller.countdown.value)})),
            ),
          ),
        ),
        Padding(
          padding: AppStyle.edgeInsetsA12,
          child: Text(
            "播放".t,
            style: Get.textTheme.titleSmall,
          ),
        ),
        SettingsCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CatchUpSettings(),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "显示视频信息（帧率、码率等）".t,
                  value: AppSettingsController.instance.playerVideoStats.value,
                  onChanged: AppSettingsController.instance.setPlayerVideoStats,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: AppStyle.edgeInsetsA12,
          child: Text(
            "聊天区".t,
            style: Get.textTheme.titleSmall,
          ),
        ),
        SettingsCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Obx(
                () => SettingsNumber(
                  title: "文字大小".t,
                  value:
                      AppSettingsController.instance.chatTextSize.value.toInt(),
                  min: 8,
                  max: 36,
                  onChanged: (e) {
                    AppSettingsController.instance
                        .setChatTextSize(e.toDouble());
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsNumber(
                  title: "上下间隔".t,
                  value:
                      AppSettingsController.instance.chatTextGap.value.toInt(),
                  min: 0,
                  max: 12,
                  onChanged: (e) {
                    AppSettingsController.instance.setChatTextGap(e.toDouble());
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "气泡样式".t,
                  value: AppSettingsController.instance.chatBubbleStyle.value,
                  onChanged: (e) {
                    AppSettingsController.instance.setChatBubbleStyle(e);
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "彩色用户名".t,
                  subtitle: "用发言人自己的名字颜色（Twitch、Kick）".t,
                  value: AppSettingsController.instance.chatNameColor.value,
                  onChanged: AppSettingsController.instance.setChatNameColor,
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "名字前显示牌子".t,
                  subtitle: "粉丝牌、舰长等，不用点开就能看到".t,
                  value: AppSettingsController.instance.chatShowBadges.value,
                  onChanged: AppSettingsController.instance.setChatShowBadges,
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "聊天区顶部显示直播间公告".t,
                  subtitle: "标题和主播公告，没有公告时显示简介".t,
                  value: AppSettingsController.instance.chatNoticeCard.value,
                  onChanged: AppSettingsController.instance.setChatNoticeCard,
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsMenu<int>(
                  title: "保留的弹幕条数".t,
                  subtitle: "超出后丢掉最早的".t,
                  value: AppSettingsController.instance.chatKeepLimit.value,
                  valueMap: {
                    for (var v in AppSettingsController.chatKeepLimitOptions)
                      v: v == 0 ? "不限".t : "{p} 万条".tf({"p": v ~/ 10000}),
                  },
                  onChanged: AppSettingsController.instance.setChatKeepLimit,
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "播放器中显示SC".t,
                  value:
                      AppSettingsController.instance.playershowSuperChat.value,
                  onChanged: (e) {
                    AppSettingsController.instance.setPlayerShowSuperChat(e);
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: AppStyle.edgeInsetsA12,
          child: Text(
            "更多设置".t,
            style: Get.textTheme.titleSmall,
          ),
        ),
        SettingsCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SettingsAction(
                title: "关键词屏蔽".t,
                onTap: controller.showDanmuShield,
              ),
              AppStyle.divider,
              Obx(() {
                ChatUsersService.maybeInstance?.version.value;
                controller.userBlocks.visitVersion.value;
                return SettingsAction(
                  title: "本直播间屏蔽的人（{n}）".tf({
                    "n": controller.userBlocks.effective().length,
                  }),
                  onTap: () => showRoomBlockList(controller.userBlocks),
                );
              }),
              AppStyle.divider,
              SettingsAction(
                title: "弹幕设置".t,
                onTap: controller.showDanmuSettingsSheet,
              ),
              AppStyle.divider,
              SettingsAction(
                title: "定时关闭".t,
                onTap: controller.showAutoExitSheet,
              ),
              AppStyle.divider,
              SettingsAction(
                title: "画面尺寸".t,
                onTap: controller.showPlayerSettingsSheet,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildFollowList({required int tabIndex}) {
    // 切到“关注”时刷新一次开播状态（看直播时定时刷新会推迟）
    return ShownInTab(
      index: tabIndex,
      onShown: controller.onFollowListShown,
      child: Obx(
      () => Stack(
        children: [
          RefreshIndicator(
            onRefresh: FollowService.instance.loadData,
            child: ListView.builder(
              itemCount: FollowService.instance.liveList.length,
              itemBuilder: (_, i) {
                var item = FollowService.instance.liveList[i];
                return Obx(
                  () => FollowUserItem(
                    item: item,
                    playing: controller.rxSite.value.id == item.siteId &&
                        controller.rxRoomId.value == item.roomId,
                    onTap: () {
                      controller.resetRoomOf(item.siteId, item.roomId);
                    },
                    onToggleNotify: () =>
                        LiveNotifyService.instance.toggleSubscription(item),
                    onLongPress: () => showFollowActions(
                      item,
                      onUnfollow: () => controller.unfollowFromList(item),
                    ),
                  ),
                );
              },
            ),
          ),
          if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
            Positioned(
              right: 12,
              bottom: 12,
              child: Obx(
                () => DesktopRefreshButton(
                  refreshing: FollowService.instance.updating.value,
                  onPressed: FollowService.instance.loadData,
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }

  List<Widget> buildAppbarActions(BuildContext context) {
    return [
      // 正在记录弹幕（ASS）：点一下停止
      Obx(
        () => controller.assRecording.value
            ? TextButton.icon(
                style: TextButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 12),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: controller.toggleAssRecording,
                icon: const Icon(
                  Icons.fiber_manual_record,
                  color: Colors.red,
                  size: 14,
                ),
                label: Text("记录弹幕 {assRecordTime}".tf({"assRecordTime": controller.assRecordTime.value})),
              )
            : const SizedBox.shrink(),
      ),
      IconButton(
        onPressed: () {
          showMore();
        },
        icon: const Icon(Icons.more_horiz),
      ),
    ];
  }

  void showMore() {
    showModalBottomSheet(
      context: Get.context!,
      constraints: const BoxConstraints(
        maxWidth: 600,
      ),
      isScrollControlled: true,
      // 项多了，矮的屏幕上可以滑
      builder: (_) => SingleChildScrollView(
        padding: EdgeInsets.only(
          bottom: AppStyle.bottomBarHeight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text("刷新".t),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                controller.refreshRoom();
              },
            ),
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              trailing: const Icon(Icons.chevron_right),
              title: Text("切换清晰度".t),
              onTap: () {
                Get.back();
                controller.showQualitySheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.switch_video_outlined),
              title: Text("切换线路".t),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.showPlayUrlsSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.aspect_ratio_outlined),
              title: Text("画面尺寸".t),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.showPlayerSettingsSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: Text("截图".t),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                controller.saveScreenshot();
              },
            ),
            // 听直播时不开小窗。先读 listen.active：电脑上 && 短路读不到它，
            // Obx 里没有可监听的值会出错，正式版里整块变成灰色，把下面的项都挤没了
            Obx(() {
              var listening = controller.listen.active.value;
              return Visibility(
                visible: Platform.isAndroid && !listening,
                child: ListTile(
                  leading: const Icon(Icons.picture_in_picture),
                  title: Text("小窗播放".t),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Get.back();
                    controller.enablePIP();
                  },
                ),
              );
            }),
            // 电脑上的主窗口：在新窗口打开后这里退出直播间，不重复播放
            ...multiWindowTiles(
              controller.site,
              controller.roomId,
              close: () => Get.back(),
              afterOpen: () => Get.back(),
              userName: controller.detail.value?.userName ?? "",
              title: controller.detail.value?.title ?? "",
            ),
            Obx(
              () => ListTile(
                leading: Icon(
                  controller.listen.active.value
                      ? Remix.tv_2_line
                      : Remix.headphone_line,
                ),
                title: Text(
                  controller.listen.active.value ? "恢复画面".t : "听直播".t,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Get.back();
                  controller.toggleListenMode();
                },
              ),
            ),
            Obx(
              () => ListTile(
                leading: controller.assRecording.value
                    ? const Icon(Icons.stop_circle_outlined, color: Colors.red)
                    : const Icon(Icons.subtitles_outlined),
                title: Text(
                  controller.assRecording.value
                      ? "停止记录弹幕（{assRecordTime}）".tf({"assRecordTime": controller.assRecordTime.value})
                      : "记录弹幕（ASS）".t,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Get.back();
                  controller.toggleAssRecording();
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text("定时关闭".t),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.showAutoExitSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_sharp),
              title: Text("分享直播间".t),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.share();
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text("复制链接".t),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.copyUrl();
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: Text("在 App 中打开".t),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.openNaviteAPP();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: Text("播放信息".t),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.showDebugInfo();
              },
            ),
          ],
        ),
      ),
    );
  }

  String parseDuration(int sec) {
    // 转为时分秒
    var h = sec ~/ 3600;
    var m = (sec % 3600) ~/ 60;
    var s = sec % 60;
    if (h > 0) {
      return "{h}小时{m}分钟{s}秒".tf({"h": h.toString().padLeft(2, '0'), "m": m.toString().padLeft(2, '0'), "s": s.toString().padLeft(2, '0')});
    }
    if (m > 0) {
      return "{m}分钟{s}秒".tf({"m": m.toString().padLeft(2, '0'), "s": s.toString().padLeft(2, '0')});
    }
    return "{s}秒".tf({"s": s.toString().padLeft(2, '0')});
  }
}
