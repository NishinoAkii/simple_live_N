// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/controller/follow_view_settings.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/modules/follow_user/follow_view.dart';
import 'package:simple_live_app/services/account_follow_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 内置的三个分组（全部、直播中、未开播）按界面语言显示，自己建的标签原样显示。
/// 分组的名字同时是存进数据库的标识，所以存的、比较的一直是简体中文
String followTagLabel(String tag) =>
    const {"全部", "直播中", "未开播"}.contains(tag) ? tag.t : tag;

class FollowUserController extends BasePageController<FollowUser> {
  StreamSubscription<dynamic>? onUpdatedIndexedStream;
  StreamSubscription<dynamic>? onUpdatedListStream;

  /// 0:全部 1:直播中 2:未直播
  var filterMode = FollowUserTag(id: "0", tag: "全部", userId: []).obs;
  RxList<FollowUserTag> tagList = [
    FollowUserTag(id: "0", tag: "全部", userId: []),
    FollowUserTag(id: "1", tag: "直播中", userId: []),
    FollowUserTag(id: "2", tag: "未开播", userId: []),
  ].obs;

  // 用户自定义标签
  RxList<FollowUserTag> userTagList = <FollowUserTag>[].obs;

  /// 分组、排序、样式（只存在本机，默认和原来一样）
  final view = FollowViewSettings();

  /// 菜单里点了“搜索”：顶栏换成搜索框
  final searching = false.obs;
  final keyword = "".obs;
  final nameKeys = FollowNameKeys();

  /// 正在刷新的那一组（组的键）
  final refreshingGroup = RxnString();

  /// 分组时往下滚了一屏以上：显示“回到顶部”
  final showBackToTop = false.obs;

  @override
  void onInit() {
    view.load();
    scrollController.addListener(_onScroll);
    onUpdatedIndexedStream = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
          (index) {
        if (index == 1) {
          scrollToTopOrRefresh();
        }
      },
    );
    onUpdatedListStream =
        FollowService.instance.updatedListStream.listen((event) {
      filterData();
    });
    super.onInit();
  }

  @override
  Future refreshData() async {
    await FollowService.instance.loadData();
    updateTagList();
    super.refreshData();
  }

  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    if (page > 1) {
      return Future.value([]);
    }
    if (filterMode.value.tag == "全部") {
      return present(FollowService.instance.followList.value);
    } else if (filterMode.value.tag == "直播中") {
      return present(FollowService.instance.liveList.value);
    } else if (filterMode.value.tag == "未开播") {
      return present(FollowService.instance.notLiveList.value);
    } else {
      FollowService.instance.filterDataByTag(filterMode.value);
      return present(FollowService.instance.curTagFollowList.value);
    }
  }

  /// 搜索和排序。默认（没在搜、直播中的在前）原样返回同一个列表，和原来一样
  List<FollowUser> present(List<FollowUser> source) {
    var result = source;
    var word = keyword.value.trim();
    if (searching.value && word.isNotEmpty) {
      nameKeys.trim();
      result = searchFollows(result, word, nameKeys);
    }
    return sortFollows(
      result,
      view.sortMode.value,
      watchedAt: _watchedAt,
      keys: nameKeys,
    );
  }

  static DateTime? _watchedAt(FollowUser item) {
    try {
      return DBService.instance.getHistory(item.id)?.updateTime;
    } catch (_) {
      return null;
    }
  }

  void _onScroll() {
    var show = view.grouped.value &&
        scrollController.hasClients &&
        scrollController.position.pixels >
            scrollController.position.viewportDimension;
    if (show != showBackToTop.value) {
      showBackToTop.value = show;
    }
  }

  void scrollToTop() {
    if (scrollController.hasClients) {
      scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  // ---- 菜单里的显示方式 ----

  void startSearch() {
    searching.value = true;
  }

  void setKeyword(String value) {
    keyword.value = value;
    filterData();
  }

  void stopSearch() {
    searching.value = false;
    keyword.value = "";
    filterData();
  }

  void setGrouped(bool value) {
    view.setGrouped(value);
    if (!value) showBackToTop.value = false;
  }

  void setGroupMode(String mode) => view.setGroupMode(mode);

  void setSortMode(String mode) {
    view.setSortMode(mode);
    filterData();
  }

  void setStyle(String style) => view.setStyle(style);

  void toggleGroup(String key) => view.toggleCollapsed(key);

  /// 把列表分组；不分组时整个列表是一组（键是空的）
  List<FollowGroup> groupsOf(List<FollowUser> items) {
    if (!view.grouped.value) {
      return [FollowGroup("", "", items)];
    }
    return groupFollows(
      items,
      view.groupMode.value,
      siteOrder: [for (var s in Sites.supportSites) s.id],
      tags: FollowService.instance.followTagList,
      siteName: (id) => Sites.allSites[id]?.name ?? Sites.missingSiteText(id),
    );
  }

  /// 刷新一组：查这一组全部的人（不管上面选的是“直播中”还是在搜索），
  /// 别的组的状态不动。正在刷新时不再开始
  Future<void> refreshFollowGroup(String key) async {
    var service = FollowService.instance;
    if (service.updating.value || key.isEmpty) return;
    var group = groupFollows(
      service.followList.toList(),
      view.groupMode.value,
      siteOrder: const [],
      tags: service.followTagList,
    ).firstWhereOrNull((e) => e.key == key);
    if (group == null || group.members.isEmpty) return;
    refreshingGroup.value = key;
    try {
      await service.startUpdateStatus(only: group.members);
    } finally {
      refreshingGroup.value = null;
    }
  }

  /// 卡片的封面：这次查到的，没有时用进直播间时记下的
  String coverOf(FollowUser item) {
    var cover = item.liveCover;
    if (cover != null && cover.isNotEmpty) return cover;
    try {
      return DBService.instance.getHistory(item.id)?.cover ?? "";
    } catch (_) {
      return "";
    }
  }

  String titleOf(FollowUser item) {
    var title = item.liveTitle;
    if (title != null && title.isNotEmpty) return title;
    try {
      return DBService.instance.getHistory(item.id)?.title ?? "";
    } catch (_) {
      return "";
    }
  }

  void updateTagList() {
    userTagList.assignAll(FollowService.instance.followTagList);
    tagList.value = tagList.take(3).toList();
    for (var i in userTagList) {
      if (!tagList.contains(i)) {
        tagList.add(i);
      }
    }
  }

  void filterData() {
    if (filterMode.value.tag == "全部") {
      list.assignAll(present(FollowService.instance.followList.value));
    } else if (filterMode.value.tag == "直播中") {
      list.assignAll(present(FollowService.instance.liveList.value));
    } else if (filterMode.value.tag == "未开播") {
      list.assignAll(present(FollowService.instance.notLiveList.value));
    } else {
      FollowService.instance.filterDataByTag(filterMode.value);
      list.assignAll(present(FollowService.instance.curTagFollowList));
    }
  }

  void setFilterMode(FollowUserTag tag) {
    filterMode.value = tag;
    filterData();
  }

  void removeItem(FollowUser item) async {
    // 打开了“同步到账号”时会多一个“仅在 App 里取消”的选项
    var localOnly =
        await AccountFollowService.confirmUnfollow(item.siteId, item.userName);
    if (localOnly == null) {
      return;
    }
    await removeConfirmed(item, localOnly: localOnly);
  }

  /// 确认以后取消关注：只在本地拿掉这一个，其他主播的开播状态不重查
  Future<void> removeConfirmed(FollowUser item, {bool localOnly = false}) async {
    // 取消关注同时删除标签内的 userId
    if(item.tag != "全部"){
      var tag = tagList.firstWhere((tag) => tag.tag == item.tag);
      tag.userId.remove(item.id);
      updateTag(tag);
    }
    await FollowService.instance.unfollow(item, localOnly: localOnly);
    FollowService.instance.removeLocal(item.id);
    filterData();
  }

  void updateItem(FollowUser item){
    FollowService.instance.addFollow(item);
  }
  // 修改item的标签
  void setItemTag(FollowUser item, FollowUserTag targetTag) {
    FollowUserTag tarTag = targetTag;
    FollowUserTag curTag =
    tagList.firstWhere((tag) => tag.tag == item.tag);
    // 从当前标签（非全部）删除item 向目标标签(全部包含所有item == 非全部)添加item
    curTag.userId.remove(item.id);
    tarTag.userId.addIf(!tarTag.userId.contains(item.id), item.id);
    // 数据库更新
    item.tag = tarTag.tag;
    updateTag(curTag);
    updateTag(tarTag);
    updateItem(item);
    filterData();
  }

  Future<void> removeTag(FollowUserTag tag) async {
    // 将tag下的所有follow设置为全部
    for(var i in tag.userId){
      var follow = DBService.instance.followBox.get(i);
      if(follow != null){
        follow.tag = "全部";
        updateItem(follow);
      }
    }
    await FollowService.instance.delFollowUserTag(tag);
    updateTagList();
    Log.i('删除tag${tag.tag}');
  }

  void addTag(String tag) async {
    FollowService.instance
        .addFollowUserTag(tag)
        .then((value) => updateTagList());
  }

  void updateTag(FollowUserTag followUserTag) {
    if(followUserTag.tag == '全部'){
      return;
    }
    FollowService.instance.updateFollowUserTag(followUserTag);
  }

  void updateTagName(FollowUserTag followUserTag, String newTagName) {
    // 未操作
    if (followUserTag.tag == newTagName) {
      return;
    }
    // 避免重名
    if (tagList.any((item) => item.tag == newTagName)) {
      SmartDialog.showToast("已有同名标签，换个名字吧".t);
      return;
    }
    final FollowUserTag newTag = followUserTag.copyWith(tag: newTagName);
    updateTag(newTag);
    // update item's tag when update tagName
    for(var i in newTag.userId){
      var follow = DBService.instance.followBox.get(i);
      if(follow != null){
        follow.tag = newTagName;
        updateItem(follow);
      }
    }
    SmartDialog.showToast("标签已改名".t);
    updateTagList();
  }

  // 调整标签顺序
  void updateTagOrder(int oldIndex, int newIndex) {
    final item = userTagList.removeAt(oldIndex);
    userTagList.insert(newIndex, item);
    tagList.value = tagList.take(3).toList();
    tagList.addAll(userTagList);
    DBService.instance.updateFollowTagOrder(userTagList);
  }

  @override
  void onClose() {
    onUpdatedIndexedStream?.cancel();
    scrollController.removeListener(_onScroll);
    super.onClose();
  }
}
