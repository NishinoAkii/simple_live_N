import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/follow_view_settings.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_controller.dart';
import 'package:simple_live_app/modules/follow_user/follow_view_widgets.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/live_notify_service.dart';
import 'package:simple_live_app/widgets/floating_header.dart';
import 'package:simple_live_app/widgets/follow_actions_sheet.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/page_grid_view.dart';
import 'package:simple_live_app/widgets/site_logo.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class FollowUserPage extends GetView<FollowUserController> {
  const FollowUserPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var count = MediaQuery.of(context).size.width ~/ 500;
    if (count < 1) count = 1;
    return Scaffold(
      appBar: AppBar(
        // 菜单里点了“搜索”时换成搜索框
        title: Obx(
          () => controller.searching.value
              ? FollowSearchField(
                  initial: controller.keyword.value,
                  onChanged: controller.setKeyword,
                  onClose: controller.stopSearch,
                )
              : Text("关注用户".t),
        ),
        // 列表从浮着的标签下面滚过时顶栏不变色（Material 3 默认会变成“滚到下面”的颜色）
        notificationPredicate: (_) => false,
        actions: [
          PopupMenuButton<int>(
            itemBuilder: (context) {
              return [
                PopupMenuItem(
                  value: 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Remix.save_2_line),
                      AppStyle.hGap12,
                      Text("导出文件".t)
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 1,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Remix.folder_open_line),
                      AppStyle.hGap12,
                      Text("导入文件".t)
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 2,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Remix.text),
                      AppStyle.hGap12,
                      Text("导出文本".t),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 3,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Remix.file_text_line),
                      AppStyle.hGap12,
                      Text("导入文本".t),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 4,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Remix.price_tag_line),
                      AppStyle.hGap12,
                      Text("标签管理".t),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 5,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Remix.user_received_line),
                      AppStyle.hGap12,
                      Text("从账号导入关注".t),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 6,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Remix.loop_left_line),
                      AppStyle.hGap12,
                      Text("账号关注同步".t),
                    ],
                  ),
                ),
                // 显示方式：放在原来几项的后面，原来的位置不变
                const PopupMenuDivider(),
                ..._viewMenuItems(context),
              ];
            },
            onSelected: (value) {
              if (value == 0) {
                FollowService.instance.exportFile();
              } else if (value == 1) {
                FollowService.instance.inputFile();
              } else if (value == 2) {
                FollowService.instance.exportText();
              } else if (value == 3) {
                FollowService.instance.inputText();
              } else if (value == 4) {
                showTagsManager();
              } else if (value == 5) {
                Get.toNamed(RoutePath.kAccountFollowImport);
              } else if (value == 6) {
                Get.toNamed(RoutePath.kAccountFollow);
              } else if (value == 7) {
                controller.startSearch();
              } else if (value == 8) {
                controller.setGrouped(!controller.view.grouped.value);
              } else if (value == 9) {
                pickGroupMode();
              } else if (value == 10) {
                pickSortMode();
              } else if (value == 11) {
                pickStyle();
              }
            },
          ),
        ],
        leading: Obx(
          () => FollowService.instance.updating.value
              ? const IconButton(
                  onPressed: null,
                  icon: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  ),
                )
              : IconButton(
                  onPressed: () {
                    controller.refreshData();
                  },
                  icon: const Icon(Icons.refresh),
                ),
        ),
      ),
      // 分组标签浮在列表上面（半透明），列表从下面滚过，
      // 一开始从标签下面排起。标签很多时左右滑
      body: FloatingHeader(
        header: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          // 只占标签那么宽：右边空出来的地方点得到下面的列表
          child: Align(
            alignment: Alignment.centerLeft,
            child: Obx(
              () => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var (i, option) in controller.tagList.indexed) ...[
                      if (i > 0) AppStyle.hGap8,
                      ChoiceChip(
                        label: Text(followTagLabel(option.tag)),
                        showCheckmark: false,
                        // 按 id 比：刚打开时“全部”是另一个对象，按对象比显示不出选中
                        selected: controller.filterMode.value.id == option.id,
                        onSelected: (_) => controller.setFilterMode(option),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        body: (context, top) => PageGridView(
              crossAxisSpacing: 12,
              crossAxisCount: count,
              pageController: controller,
              firstRefresh: true,
              showPCRefreshButton: false,
              padding: EdgeInsets.only(top: top),
              itemBuilder: (_, i) => buildItem(controller.list[i]),
              // 默认（不分组、列表）返回 null，还是原来的网格
              sliverBuilder: (context) => buildSections(context, count),
            ),
      ),
      // 分组时往下滚了一屏以上才出现
      floatingActionButton: Obx(
        () => controller.view.grouped.value && controller.showBackToTop.value
            ? FloatingActionButton.small(
                heroTag: null,
                tooltip: "回到顶部".t,
                onPressed: controller.scrollToTop,
                child: const Icon(Remix.arrow_up_line),
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  /// 列表的一行，和原来一样
  Widget buildItem(FollowUser item) {
    // 已删除的直播源为 null，FollowUserItem 灰色显示且不能打开
    var site = Sites.allSites[item.siteId];
    return FollowUserItem(
      item: item,
      onRemove: () {
        controller.removeItem(item);
      },
      onTap: site == null
          ? null
          : () {
              AppNavigator.toLiveRoomDetail(site: site, roomId: item.roomId);
            },
      // 长按：开关开播提醒、设置标签、取消关注
      onLongPress: () => showActions(item),
      onToggleNotify: site == null
          ? null
          : () => LiveNotifyService.instance.toggleSubscription(item),
    );
  }

  void showActions(FollowUser item) {
    showFollowActions(
      item,
      onUnfollow: () => controller.removeItem(item),
      onSetTag: () => setFollowTagDialog(item),
    );
  }

  /// 分组、紧凑、卡片样式，以及搜不到时的提示。默认的列表返回 null
  List<Widget>? buildSections(BuildContext context, int count) {
    var view = controller.view;
    var grouped = view.grouped.value;
    var style = view.style.value;
    var items = controller.list.toList();
    if (items.isEmpty &&
        controller.searching.value &&
        controller.keyword.value.trim().isNotEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: AppStyle.edgeInsetsA24,
            child: Center(
              child: Text(
                "没有符合条件的".t,
                style: const TextStyle(color: Colors.grey),
              ),
            ),
          ),
        ),
      ];
    }
    if (view.isPlainList) {
      return null;
    }
    var refreshing = controller.refreshingGroup.value;
    var updating = FollowService.instance.updating.value;
    var cardColumns = MediaQuery.of(context).size.width ~/ 200;
    return followSectionSlivers(
      groups: controller.groupsOf(items),
      headers: grouped,
      style: style,
      collapsed: view.collapsed.toSet(),
      columns: count,
      cardColumns: cardColumns < 2 ? 2 : cardColumns,
      row: buildItem,
      compact: (item) {
        var site = Sites.allSites[item.siteId];
        return FollowCompactRow(
          item: item,
          onTap: site == null
              ? null
              : () => AppNavigator.toLiveRoomDetail(
                  site: site, roomId: item.roomId),
          onLongPress: () => showActions(item),
          onToggleNotify: site == null
              ? null
              : () => LiveNotifyService.instance.toggleSubscription(item),
        );
      },
      card: (item) {
        var site = Sites.allSites[item.siteId];
        if (site == null) return buildItem(item);
        return FollowLiveCard(
          item: item,
          site: site,
          cover: controller.coverOf(item),
          title: controller.titleOf(item),
          onLongPress: () => showActions(item),
        );
      },
      header: (group, folded) => FollowGroupHeader(
        title: group.title,
        count: group.members.length,
        collapsed: folded,
        leading: group.siteId == null
            ? null
            : SiteLogo(Sites.allSites[group.siteId], width: 18),
        onToggle: () => controller.toggleGroup(group.key),
        refreshing: refreshing == group.key,
        onRefresh:
            updating ? null : () => controller.refreshFollowGroup(group.key),
      ),
      // 留出“回到顶部”的位置
      bottom: grouped ? 72 : 0,
    );
  }

  static Map<String, String> get groupModeLabels => {
        FollowViewSettings.groupSite: "按直播源".t,
        FollowViewSettings.groupTag: "按标签".t,
        FollowViewSettings.groupStatus: "按状态".t,
      };

  static Map<String, String> get sortLabels => {
        FollowViewSettings.sortLive: "直播中在前".t,
        FollowViewSettings.sortWatched: "最近看过".t,
        FollowViewSettings.sortStarted: "最近开播".t,
        FollowViewSettings.sortAdded: "最近关注".t,
        FollowViewSettings.sortName: "按名字".t,
      };

  static Map<String, String> get styleLabels => {
        FollowViewSettings.styleList: "列表".t,
        FollowViewSettings.styleCompact: "紧凑".t,
        FollowViewSettings.styleCard: "卡片".t,
      };

  /// 菜单里显示方式的几项，右边灰字是现在选的
  List<PopupMenuEntry<int>> _viewMenuItems(BuildContext context) {
    var view = controller.view;
    PopupMenuItem<int> item(int value, IconData icon, String text,
        {String? current, bool checked = false}) {
      return PopupMenuItem<int>(
        value: value,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon),
            AppStyle.hGap12,
            Text(text),
            if (current != null) ...[
              AppStyle.hGap12,
              Text(
                current,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
            if (checked) ...[
              AppStyle.hGap12,
              Icon(
                Icons.check,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ],
        ),
      );
    }

    return [
      item(7, Remix.search_line, "搜索".t),
      item(8, Remix.folders_line, "分组显示".t, checked: view.grouped.value),
      if (view.grouped.value)
        item(9, Remix.list_settings_line, "分组方式".t,
            current: groupModeLabels[view.groupMode.value]),
      item(10, Remix.sort_desc, "排序".t,
          current: sortLabels[view.sortMode.value]),
      item(11, Remix.layout_grid_line, "显示样式".t,
          current: styleLabels[view.style.value]),
    ];
  }

  Future<void> pickGroupMode() async {
    var value = await Utils.showMapOptionDialog(
      groupModeLabels,
      controller.view.groupMode.value,
      title: "分组方式".t,
    );
    if (value != null) controller.setGroupMode(value);
  }

  Future<void> pickSortMode() async {
    var value = await Utils.showMapOptionDialog(
      sortLabels,
      controller.view.sortMode.value,
      title: "排序".t,
    );
    if (value != null) controller.setSortMode(value);
  }

  Future<void> pickStyle() async {
    var value = await Utils.showMapOptionDialog(
      styleLabels,
      controller.view.style.value,
      title: "显示样式".t,
    );
    if (value != null) controller.setStyle(value);
  }

  void setFollowTagDialog(FollowUser item) {
    /// 控制单选ui
    List<FollowUserTag> copiedList = [
      controller.tagList.first,
      ...controller.tagList.skip(3),
    ];
    Rx<FollowUserTag> checkTag =
        controller.tagList.indexOf(controller.filterMode.value) < 3
            ? copiedList.first.obs
            : controller.filterMode.value.obs;
    final ScrollController scrollController = ScrollController();
    Get.dialog(
      AlertDialog(
        contentPadding: const EdgeInsets.all(16.0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12.0),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '设置标签'.t,
                  style: const TextStyle(
                    fontSize: 18,
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.check,
                  ),
                  onPressed: () {
                    controller.setItemTag(item, checkTag.value);
                    Get.back();
                  },
                ),
              ],
            ),
            const Divider(),
            Obx(
              () {
                int selectedIndex = copiedList.indexOf(checkTag.value);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (selectedIndex >= 0) {
                    scrollController.animateTo(
                      selectedIndex * 60.0, // 假设每项高度为 60
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  }
                });
                return SizedBox(
                  height: 300,
                  width: 300,
                  child: RadioGroup(
                    groupValue: checkTag.value,
                    onChanged: (value) {
                      checkTag.value = value!;
                    },
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: copiedList.length,
                      itemBuilder: (context, index) {
                        var tagItem = copiedList[index];
                        return Container(
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                  color: Colors.grey.shade300, width: 1.0),
                            ),
                          ),
                          child: RadioListTile<FollowUserTag>(
                            title: Text(followTagLabel(tagItem.tag)),
                            value: tagItem,
                          ),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void showTagsManager() {
    Utils.showBottomSheet(
      title: '标签管理'.t,
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppStyle.divider,
            ListTile(
              title: Text("添加标签".t),
              leading: const Icon(Icons.add),
              onTap: () {
                editTagDialog("添加标签".t);
              },
            ),
            AppStyle.divider,
            // 列表内容
            Expanded(
              child: Obx(
                () => ReorderableListView.builder(
                  itemCount: controller.userTagList.length,
                  itemBuilder: (context, index) {
                    // 偏移
                    FollowUserTag item = controller.userTagList[index];
                    return ListTile(
                      key: ValueKey(item.id),
                      title: GestureDetector(
                        child: Text(item.tag),
                        onLongPress: () {
                          {
                            editTagDialog("修改标签".t, followUserTag: item);
                          }
                        },
                      ),
                      leading: IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () {
                          controller.removeTag(item);
                        },
                      ),
                    );
                  },
                  onReorderItem: (int oldIndex, int newIndex) {
                    controller.updateTagOrder(oldIndex, newIndex);
                  },
                ),
              ),
            ),
          ]),
    );
  }

  void editTagDialog(String title, {FollowUserTag? followUserTag}) {
    final TextEditingController tagEditController =
        TextEditingController(text: followUserTag?.tag);
    bool upMode = title == "添加标签".t;
    Get.dialog(
      AlertDialog(
        contentPadding: const EdgeInsets.all(16.0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12.0),
        ),
        content: SingleChildScrollView(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(Get.context!).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                ),
              ),
              TextField(
                controller: tagEditController,
                minLines: 1,
                maxLines: 1,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  contentPadding: AppStyle.edgeInsetsA12,
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: Colors.grey.withAlpha(51),
                    ),
                  ),
                ),
                onSubmitted: (tag) {
                  upMode
                      ? controller.addTag(tagEditController.text)
                      : controller.updateTagName(
                          followUserTag!, tagEditController.text);
                  Get.back();
                },
              ),
              Container(
                margin: AppStyle.edgeInsetsB4,
                width: double.infinity,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        Get.back();
                      },
                      child: Text('取消'.t),
                    ),
                    TextButton(
                      onPressed: () {
                        upMode
                            ? controller.addTag(tagEditController.text)
                            : controller.updateTagName(
                                followUserTag!, tagEditController.text);
                        Get.back();
                      },
                      child: Text('确定'.t),
                    ),
                  ],
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}
