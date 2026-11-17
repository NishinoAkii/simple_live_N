import 'dart:io';

import 'package:flutter/material.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/widgets/status/app_empty_widget.dart';
import 'package:simple_live_app/widgets/status/app_error_widget.dart';
import 'package:simple_live_app/widgets/status/app_loadding_widget.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_easyrefresh/easy_refresh.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class PageGridView extends StatelessWidget {
  final BasePageController pageController;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsets? padding;
  final bool firstRefresh;
  final Function()? onLoginSuccess;
  final bool showPageLoadding;
  final double crossAxisSpacing, mainAxisSpacing;
  final int crossAxisCount;
  final bool showPCRefreshButton;

  /// 换成自己排的几段（关注页的分组、紧凑和卡片样式）。返回 null 时还是原来的网格；
  /// 在 Obx 里调用，里面读到的 Rx 变了会重排
  final List<Widget>? Function(BuildContext context)? sliverBuilder;
  const PageGridView({
    required this.itemBuilder,
    required this.pageController,
    this.padding,
    this.firstRefresh = false,
    this.showPageLoadding = false,
    this.onLoginSuccess,
    this.crossAxisSpacing = 0.0,
    this.mainAxisSpacing = 0.0,
    this.showPCRefreshButton = true,
    required this.crossAxisCount,
    this.sliverBuilder,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      var slivers = sliverBuilder?.call(context);
      return Stack(
        children: [
          EasyRefresh(
            header: MaterialHeader(
              completeDuration: const Duration(milliseconds: 400),
            ),
            footer: MaterialFooter(
              completeDuration: const Duration(milliseconds: 400),
            ),
            scrollController: pageController.scrollController,
            controller: pageController.easyRefreshController,
            firstRefresh: firstRefresh,
            onLoad: pageController.loadData,
            onRefresh: pageController.refreshData,
            // 按行排：每行和这一行最高的卡片一样高，顺序和列表一致。
            // 原来是瀑布流，标题里有特殊字符（换成别的字体）的卡片高几个像素，
            // 后面的卡片就往矮的那一列放，顺序乱了，最后一行还会空出位置
            child: slivers != null
                ? CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: padding ?? EdgeInsets.zero,
                        sliver: SliverMainAxisGroup(slivers: slivers),
                      ),
                    ],
                  )
                : AlignedGridView.count(
                    padding: padding,
                    itemCount: pageController.list.length,
                    itemBuilder: itemBuilder,
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: crossAxisSpacing,
                    mainAxisSpacing: mainAxisSpacing,
                  ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: // 加载更多按钮
                Visibility(
              visible: (Platform.isWindows ||
                      Platform.isLinux ||
                      Platform.isMacOS) &&
                  pageController.canLoadMore.value &&
                  !pageController.pageLoadding.value &&
                  !pageController.pageEmpty.value,
              child: Center(
                child: TextButton(
                  onPressed: pageController.loadData,
                  child: Text("加载更多".t),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 12,
            right: 12,
            child: // 加载更多按钮
                Visibility(
              visible: (Platform.isWindows ||
                      Platform.isLinux ||
                      Platform.isMacOS) &&
                  pageController.canLoadMore.value &&
                  !pageController.pageLoadding.value &&
                  !pageController.pageEmpty.value &&
                  showPCRefreshButton,
              child: Center(
                child: IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: Get.theme.cardColor.withAlpha(200),
                    elevation: 4,
                  ),
                  onPressed: () {
                    pageController.refreshData();
                  },
                  icon: const Icon(Icons.refresh),
                ),
              ),
            ),
          ),
          // 只在要显示时才建出来：这三个都带一直循环的动画，用 Offstage 藏起来时
          // 动画照样每帧都在跑，还会让整页跟着重画，空闲时也占满一个 CPU 核心
          if (pageController.pageEmpty.value)
            AppEmptyWidget(
              onRefresh: () => pageController.refreshData(),
            ),
          if (showPageLoadding && pageController.pageLoadding.value)
            const AppLoaddingWidget(),
          if (pageController.pageError.value)
            AppErrorWidget(
              errorMsg: pageController.errorMsg.value,
              onRefresh: () => pageController.refreshData(),
            ),
        ],
      );
    });
  }
}
