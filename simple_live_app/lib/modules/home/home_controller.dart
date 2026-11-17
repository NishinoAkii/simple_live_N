import 'dart:async';

import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/controller/site_tabs.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/home/home_list_controller.dart';
import 'package:simple_live_app/routes/route_path.dart';

class HomeController extends GetxController with GetTickerProviderStateMixin {
  /// 有推荐的平台（直播源没写推荐时不显示）
  late final SiteTabs<HomeListController> siteTabs = SiteTabs(
    vsync: this,
    load: () => Sites.recommendSites,
    create: HomeListController.new,
  );

  TabController get tabController => siteTabs.controller;
  RxList<Site> get sites => siteTabs.sites;

  StreamSubscription<dynamic>? streamSubscription;

  @override
  void onInit() {
    streamSubscription = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 0) {
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
    controller = Get.find<HomeListController>(tag: site.id);
    controller.scrollToTopOrRefresh();
  }

  void toSearch() {
    Get.toNamed(RoutePath.kSearch);
  }

  @override
  void onClose() {
    streamSubscription?.cancel();
    siteTabs.dispose();
    super.onClose();
  }
}
