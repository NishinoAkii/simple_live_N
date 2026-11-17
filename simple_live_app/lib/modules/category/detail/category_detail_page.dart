import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/category/detail/category_detail_controller.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/widgets/keep_alive_wrapper.dart';
import 'package:simple_live_app/widgets/live_room_card.dart';
import 'package:simple_live_app/widgets/page_grid_view.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 分类里的直播。同一个页面可以一层层叠着打开（抖音的分类有好几层），
/// 每一层的控制器用 [tag] 区分，打开时由 [AppNavigator.toCategoryDetail] 生成
class CategoryDetailPage extends StatelessWidget {
  final String? tag;
  const CategoryDetailPage({this.tag, Key? key}) : super(key: key);

  /// 路由参数是 [site, category, tag]，以前的版本没有 tag
  static String? tagOf(Object? arguments) =>
      arguments is List && arguments.length > 2 ? arguments[2] as String? : null;

  @override
  Widget build(BuildContext context) {
    var controller = Get.find<CategoryDetailController>(
      tag: tag ?? tagOf(ModalRoute.of(context)?.settings.arguments),
    );
    var c = MediaQuery.of(context).size.width ~/ 200;
    if (c < 2) {
      c = 2;
    }
    var category = controller.subCategory;
    return Scaffold(
      appBar: AppBar(
        title: Text(category.name),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (category.hasChildren)
            SubCategoryBar(site: controller.site, category: category),
          Expanded(
            child: KeepAliveWrapper(
              child: PageGridView(
                pageController: controller,
                padding: AppStyle.edgeInsetsA12,
                firstRefresh: true,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                crossAxisCount: c,
                itemBuilder: (_, i) {
                  var item = controller.list[i];
                  return LiveRoomCard(controller.site, item);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 房间上方的一排下一层分类，第一个「全部」就是本页。窄屏上横着滑
class SubCategoryBar extends StatelessWidget {
  final Site site;
  final LiveSubCategory category;
  const SubCategoryBar({required this.site, required this.category, super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: AppStyle.edgeInsetsH12.copyWith(top: 8),
      child: Row(
        children: [
          ChoiceChip(
            label: Text("全部".t),
            selected: true,
            onSelected: (_) {},
          ),
          for (var child in category.children) ...[
            AppStyle.hGap8,
            ChoiceChip(
              label: Text(child.name),
              selected: false,
              onSelected: (_) =>
                  AppNavigator.toCategoryDetail(site: site, category: child),
            ),
          ],
        ],
      ),
    );
  }
}
