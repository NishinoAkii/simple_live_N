import 'dart:async';

import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/controller/site_tabs.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/category/category_list_controller.dart';

class CategoryController extends GetxController
    with GetTickerProviderStateMixin {
  /// 有分类的平台（直播源没写分类时不显示）
  late final SiteTabs<CategoryListController> siteTabs = SiteTabs(
    vsync: this,
    load: () => Sites.categorySites,
    create: CategoryListController.new,
  );

  TabController get tabController => siteTabs.controller;
  RxList<Site> get sites => siteTabs.sites;

  StreamSubscription<dynamic>? streamSubscription;
  @override
  void onInit() {
    streamSubscription = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 2) {
          refreshOrScrollTop();
        }
      },
    );
    siteTabs.init();

    super.onInit();
  }

  void refreshOrScrollTop() {
    var site = siteTabs.current;
    if (site == null) {
      return;
    }
    BasePageController controller;
    controller = Get.find<CategoryListController>(tag: site.id);
    controller.scrollToTopOrRefresh();
  }

  @override
  void onClose() {
    streamSubscription?.cancel();
    siteTabs.dispose();
    super.onClose();
  }
}
