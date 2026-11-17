import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/search/search_controller.dart';
import 'package:simple_live_app/modules/search/search_list_controller.dart';
import 'package:simple_live_app/modules/search/search_list_view.dart';
import 'package:simple_live_app/modules/search/widgets/search_suggest_panel.dart';
import 'package:simple_live_app/widgets/site_logo.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class SearchPage extends GetView<AppSearchController> {
  const SearchPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: TextField(
          controller: controller.searchController,
          focusNode: controller.focusNode,
          autofocus: true,
          onTap: () => controller.panelOpen.value = true,
          decoration: InputDecoration(
            hintText: "主播、房间号或链接".t,
            border: OutlineInputBorder(
              borderRadius: AppStyle.radius24,
            ),
            contentPadding: AppStyle.edgeInsetsH12,
            prefixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: Get.back,
                  icon: const Icon(Icons.arrow_back),
                ),
                Obx(
                  () => DropdownButton<int>(
                    underline: const SizedBox(),
                    items: [
                      DropdownMenuItem(
                        value: SearchMode.all,
                        child: Text("综合".t),
                      ),
                      DropdownMenuItem(
                        value: SearchMode.rooms,
                        child: Text("房间".t),
                      ),
                      DropdownMenuItem(
                        value: SearchMode.anchors,
                        child: Text("主播".t),
                      ),
                    ],
                    value: controller.searchMode.value,
                    onChanged: (e) {
                      controller.searchMode.value = e ?? SearchMode.all;
                      controller.doSearch();
                    },
                  ),
                ),
                AppStyle.hGap8,
              ],
            ),
            suffixIcon: IconButton(
              onPressed: controller.doSearch,
              icon: const Icon(Icons.search),
            ),
          ),
          onSubmitted: (e) {
            controller.doSearch();
          },
        ),
        bottom: TabBar(
          controller: controller.tabController,
          padding: EdgeInsets.zero,
          tabAlignment: TabAlignment.center,
          tabs: controller.sites
              .map(
                (e) => Tab(
                  //text: e.name,
                  child: Row(
                    children: [
                      SiteLogo(
                        e,
                        width: 24,
                      ),
                      AppStyle.hGap8,
                      Text(e.name),
                    ],
                  ),
                ),
              )
              .toList(),
          labelPadding: AppStyle.edgeInsetsH20,
          isScrollable: true,
          indicatorSize: TabBarIndicatorSize.label,
        ),
      ),
      body: Stack(
        children: [
          TabBarView(
            physics: const NeverScrollableScrollPhysics(),
            controller: controller.tabController,
            children: controller.sites
                .map((e) => SearchListView(
                          e.id,
                        )
                    // (e) => e.id == Constant.kDouyin
                    //     ? const DouyinSearchView()
                    //     : SearchListView(
                    //         e.id,
                    //       ),
                    )
                .toList(),
          ),
          // 输入时的联想、最近搜索
          Obx(
            () => controller.panelOpen.value
                ? Positioned.fill(child: SearchSuggestPanel(controller))
                : const SizedBox(),
          ),
        ],
      ),
    );
  }
}
