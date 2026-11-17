import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';

/// 首页、分类页的平台标签页：安装、删除直播源后标签跟着变化。
///
/// 标签和页面都按 [sites] 生成，[controller] 和 [sites] 一起替换，
/// 页面里的 TabBar / TabBarView 用 Obx 读取 [sites]，长度始终一致。
/// 每个平台一个列表控制器 [C]（tag 为平台 id）；删掉的平台等页面重建后再删除控制器。
class SiteTabs<C extends GetxController> {
  final TickerProvider vsync;
  final List<Site> Function() load;
  final C Function(Site site) create;

  final RxList<Site> sites = <Site>[].obs;
  late TabController controller;
  Worker? _worker;

  SiteTabs({
    required this.vsync,
    required this.load,
    required this.create,
  }) {
    sites.assignAll(load());
    controller = TabController(length: sites.length, vsync: vsync);
  }

  /// 创建各平台的列表控制器，开始跟随平台列表的变化
  void init() {
    for (var site in sites) {
      _put(site);
    }
    _worker = ever<int>(Sites.version, (_) => _sync());
  }

  void _put(Site site) {
    if (!Get.isRegistered<C>(tag: site.id)) {
      // 常驻：在直播源订阅页里安装时，控制器是在那个页面打开期间创建的，
      // GetX 会在返回时把它跟着那个页面一起删掉，回到首页就找不到了。删除平台时由这里强制删除
      Get.put<C>(create(site), tag: site.id, permanent: true);
    }
  }

  /// 当前选中的平台
  Site? get current {
    if (sites.isEmpty) {
      return null;
    }
    return sites[controller.index.clamp(0, sites.length - 1)];
  }

  void _sync() {
    var next = load();
    if (listEquals(next, sites)) {
      return;
    }
    var selected = current;
    var removed = sites.where((e) => !next.contains(e)).toList();
    for (var site in next) {
      _put(site);
    }
    var old = controller;
    var index = selected == null ? 0 : next.indexOf(selected);
    controller = TabController(
      length: next.length,
      vsync: vsync,
      initialIndex: index < 0 ? 0 : index,
    );
    sites.assignAll(next);
    // 旧的 TabController 和删掉的平台的控制器等页面换成新的之后再释放
    WidgetsBinding.instance.addPostFrameCallback((_) {
      old.dispose();
      for (var site in removed) {
        if (!sites.any((e) => e.id == site.id) &&
            Get.isRegistered<C>(tag: site.id)) {
          Get.delete<C>(tag: site.id, force: true);
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void dispose() {
    _worker?.dispose();
  }
}
