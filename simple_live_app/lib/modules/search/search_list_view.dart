import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/search/search_list_controller.dart';
import 'package:simple_live_app/modules/search/search_merge.dart';
import 'package:simple_live_app/modules/search/widgets/search_cards.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/widgets/keep_alive_wrapper.dart';
import 'package:simple_live_app/widgets/live_room_card.dart';
import 'package:simple_live_app/widgets/page_grid_view.dart';
import 'package:simple_live_core/simple_live_core.dart';

class SearchListView extends StatelessWidget {
  final String tag;
  const SearchListView(this.tag, {Key? key}) : super(key: key);
  SearchListController get controller =>
      Get.find<SearchListController>(tag: tag);
  @override
  Widget build(BuildContext context) {
    var roomRowCount = MediaQuery.of(context).size.width ~/ 200;
    if (roomRowCount < 2) roomRowCount = 2;

    var userRowCount = MediaQuery.of(context).size.width ~/ 500;
    if (userRowCount < 1) userRowCount = 1;
    return KeepAliveWrapper(
      child: Column(
        children: [
          _buildHeader(context),
          Expanded(
            child: Obx(
              () => controller.searchMode.value == SearchMode.anchors
                  ? PageGridView(
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      crossAxisCount: userRowCount,
                      padding: AppStyle.edgeInsetsA12,
                      pageController: controller,
                      firstRefresh: false,
                      showPageLoadding: true,
                      itemBuilder: (_, i) {
                        var item = controller.list[i];
                        if (item is! LiveAnchorItem) return const SizedBox();
                        return SearchAnchorCard(controller.site, item);
                      },
                    )
                  : PageGridView(
                      pageController: controller,
                      padding: AppStyle.edgeInsetsA12,
                      firstRefresh: false,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      crossAxisCount: roomRowCount,
                      showPageLoadding: true,
                      itemBuilder: (_, i) {
                        var item = controller.list[i];
                        if (item is SearchEntry) {
                          return SearchEntryCard(controller.site, item);
                        }
                        if (item is! LiveRoomItem) return const SizedBox();
                        return LiveRoomCard(controller.site, item);
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 结果上面的“你是不是要找”、直达卡片、要登录的提示
  Widget _buildHeader(BuildContext context) {
    return Obx(() {
      var direct = controller.direct.value;
      var correction = controller.correction.value;
      var children = <Widget>[
        if (correction != null)
          Padding(
            padding: AppStyle.edgeInsetsB8,
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text("你是不是要找：".t, style: const TextStyle(fontSize: 13)),
                InkWell(
                  onTap: () => controller.onSearchWord?.call(correction),
                  child: Text(
                    correction,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (controller.rescuing.value)
          Padding(
            padding: AppStyle.edgeInsetsB8,
            child: Text(
              "结果不多，正在按拼音再找找…".t,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        if (direct != null) SearchDirectCard(controller.site, direct),
        if (controller.needLogin.value)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: () => Get.toNamed(RoutePath.kSettingsAccount),
                icon: const Icon(Icons.manage_accounts_outlined),
                label: Text("去设置账号".t),
              ),
            ],
          ),
      ];
      if (children.isEmpty) {
        return const SizedBox();
      }
      return Padding(
        padding: AppStyle.edgeInsetsA12.copyWith(bottom: 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    });
  }
}
