import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/parse/parse_controller.dart';
import 'package:simple_live_app/modules/search/local_search.dart';
import 'package:simple_live_app/modules/search/search_history.dart';
import 'package:simple_live_app/modules/search/search_list_controller.dart';
import 'package:simple_live_app/modules/search/search_suggest_controller.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class AppSearchController extends GetxController
    with GetSingleTickerProviderStateMixin {
  late TabController tabController;
  int index = 0;

  /// 搜索模式，见 [SearchMode]，默认综合
  var searchMode = SearchMode.all.obs;

  /// 有搜索的平台（直播源没写搜索时不显示）；打开搜索页时确定，页面里不再变化
  final List<Site> sites;

  /// 输入时的联想（本地匹配、平台联想、最近搜索）
  late final SearchSuggestController suggest = SearchSuggestController(
    currentSite: () => sites[index],
    buildIndex: _buildLocalIndex,
    historyStore: SearchHistoryStore(),
  );

  /// 联想面板是否打开（输入框获得焦点或输入时打开，搜索后关闭）
  var panelOpen = false.obs;

  final FocusNode focusNode = FocusNode();

  /// [searchSites] 默认为 [Sites.searchSites]（测试时可以指定）
  AppSearchController({List<Site>? searchSites})
      : sites = searchSites ?? Sites.searchSites {
    tabController = TabController(length: sites.length, vsync: this);
    tabController.animation?.addListener(() {
      var currentIndex = (tabController.animation?.value ?? 0).round();
      if (index == currentIndex) {
        return;
      }

      index = currentIndex;
      // if (Sites.supportSites[index].id == Constant.kDouyin) {
      //   return;
      // }
      if (panelOpen.value) {
        suggest.onSiteChanged();
      }

      var controller = Get.find<SearchListController>(tag: sites[index].id);

      if (controller.list.isEmpty &&
          !controller.pageEmpty.value &&
          controller.keyword.isNotEmpty) {
        controller.refreshData();
      }
    });
  }

  StreamSubscription<dynamic>? streamSubscription;
  Worker? _followWorker;

  TextEditingController searchController = TextEditingController();

  /// 上次搜索的文字：输入框的文字和它不同时才打开联想
  String _searched = "";

  @override
  void onInit() {
    for (var site in sites) {
      // if (site.id == Constant.kDouyin) {
      //   Get.put(DouyinSearchController(site));
      // } else {
      var controller = SearchListController(site)
        ..cachedSuggestions = suggest.cached
        ..localNames = suggest.localNames
        ..onSearchWord = searchWord;
      Get.put(
        controller,
        tag: site.id,
      );
      //}
    }
    suggest.loadHistory();
    searchController.addListener(_onTextChanged);
    focusNode.addListener(() {
      if (focusNode.hasFocus) {
        panelOpen.value = true;
      }
    });
    if (Get.isRegistered<FollowService>()) {
      _followWorker = ever(
        FollowService.instance.followList,
        (_) => suggest.invalidateIndex(),
      );
    }
    panelOpen.value = true;

    super.onInit();
  }

  void _onTextChanged() {
    var text = searchController.text;
    if (text == suggest.query.value) {
      return;
    }
    suggest.onChanged(text);
    if (text != _searched) {
      panelOpen.value = true;
    }
  }

  /// 本地匹配的数据：关注（带在播状态）和观看历史
  LocalSearchIndex _buildLocalIndex() {
    var follows = Get.isRegistered<FollowService>()
        ? FollowService.instance.followList.toList()
        : (Get.isRegistered<DBService>()
            ? DBService.instance.getFollowList()
            : const []);
    var histories = Get.isRegistered<DBService>()
        ? DBService.instance.getHistores()
        : const [];
    return LocalSearchIndex.build(
      follows: follows.cast(),
      histories: histories.cast(),
    );
  }

  void closePanel() {
    panelOpen.value = false;
    suggest.cancel();
  }

  /// 点了最近搜索或“你是不是要找”：填进输入框并搜索
  void searchWord(String text) {
    searchController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    doSearch();
  }

  /// 点了本地匹配（关注、历史）：直接进直播间
  void openLocal(LocalSearchMatch match) {
    var site = Sites.allSites[match.item.siteId];
    if (site == null) {
      SmartDialog.showToast(Sites.missingSiteText(match.item.siteId));
      return;
    }
    closePanel();
    AppNavigator.toLiveRoomDetail(site: site, roomId: match.item.roomId);
  }

  /// 点了平台的频道卡片：直接进直播间
  void openChannel(LiveSuggestion item) {
    var roomId = item.roomId;
    if (roomId == null || roomId.isEmpty) {
      searchWord(item.text);
      return;
    }
    closePanel();
    AppNavigator.toLiveRoomDetail(site: sites[index], roomId: roomId);
  }

  /// 输入的是直播间链接时直接打开直播间（YouTube 还支持 @名称和频道 ID）
  Future<bool> tryOpenLink(String text) async {
    var input = text.trim();
    if (!ParseController.isYouTubeInput(input) &&
        !RegExp(r"https?://|(twitch\.tv|kick\.com|youtube\.com|youtu\.be|douyu\.com|huya\.com|bilibili\.com|b23\.tv|douyin\.com)/",
                caseSensitive: false)
            .hasMatch(text) &&
        Sites.matchScriptLink(input) == null) {
      return false;
    }
    try {
      var result = await ParseController().parse(input);
      if (result.isEmpty || result.first == "") {
        return false;
      }
      AppNavigator.toLiveRoomDetail(site: result[1], roomId: result.first);
      return true;
    } on ParseLinkError catch (e) {
      // 只输入 @名称 也可能是想搜关键词，找不到频道时继续搜索；
      // 明确是 YouTube 链接时拿链接搜关键词没有意义，提示后停下
      if (ParseController.isYouTubeHandle(input)) {
        SmartDialog.showToast("{message}，改为搜索关键词".tf({"message": e.message}));
        return false;
      }
      SmartDialog.showToast(e.message);
      return true;
    } catch (e) {
      Log.logPrint(e);
      return false;
    }
  }

  void doSearch() async {
    if (searchController.text.trim().isEmpty) {
      return;
    }
    _searched = searchController.text;
    closePanel();
    if (await tryOpenLink(searchController.text)) {
      return;
    }
    suggest.recordSearch(searchController.text);
    for (var site in sites) {
      // if (site.id == Constant.kDouyin) {
      //   var controller = Get.find<DouyinSearchController>();
      //   controller.keyword = searchController.text;
      //   controller.searchMode.value = searchMode.value;
      //   controller.reloadWebView();
      // } else {
      var controller = Get.find<SearchListController>(tag: site.id);
      controller.clear();
      controller.keyword = searchController.text;
      controller.searchMode.value = searchMode.value;
      //}
    }
    // if (Sites.supportSites[index].id != Constant.kDouyin) {
    var controller = Get.find<SearchListController>(tag: sites[index].id);
    controller.refreshData();
    //}
  }

  @override
  void onClose() {
    streamSubscription?.cancel();
    _followWorker?.dispose();
    suggest.dispose();
    searchController.removeListener(_onTextChanged);
    focusNode.dispose();
    super.onClose();
  }
}
