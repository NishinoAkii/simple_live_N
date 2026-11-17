import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/home/home_controller.dart';
import 'package:simple_live_app/modules/home/home_list_view.dart';
import 'package:simple_live_app/widgets/site_logo.dart';

class HomePage extends GetView<HomeController> {
  const HomePage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: Obx(
          () => TabBar(
            controller: controller.tabController,
            labelPadding: AppStyle.edgeInsetsH20,
            isScrollable: true,
            indicatorSize: TabBarIndicatorSize.label,
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
          ),
        ),
        actions: [
          IconButton(
            onPressed: controller.toSearch,
            icon: const Icon(Icons.search),
          )
        ],
      ),
      body: Obx(
        () => TabBarView(
          controller: controller.tabController,
          children: controller.sites
              .map(
                (e) => HomeListView(
                  e.id,
                  key: ValueKey(e.id),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}
