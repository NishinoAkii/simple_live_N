import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/settings/indexed_settings/indexed_settings_controller.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/site_logo.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class IndexedSettingsPage extends GetView<IndexedSettingsController> {
  const IndexedSettingsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("主页设置".t),
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
            child: Text(
              "主页排序（长按拖动，重启后生效）".t,
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Obx(
              () => ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                onReorderItem: controller.updateHomeSort,
                children: controller.homeSort.map(
                  (key) {
                    var e = Constant.allHomePages[key]!;
                    return ListTile(
                      key: ValueKey(e.title),
                      title: Text("${e.title}##tab".t),
                      visualDensity: VisualDensity.compact,
                      leading: Icon(e.iconData),
                      trailing: const Icon(Icons.drag_handle),
                    );
                  },
                ).toList(),
              ),
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "平台排序和显示（长按拖动，重启后生效；关掉后首页、分类和搜索不再显示，关注和历史里仍能打开）".t,
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Obx(
              () => ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                onReorderItem: controller.updateSiteSort,
                children: controller.visibleSiteSort.map(
                  (key) {
                    var e = Sites.allSites[key]!;
                    return ListTile(
                      key: ValueKey(e.id),
                      visualDensity: VisualDensity.compact,
                      title: Text(e.name),
                      leading: SiteLogo(
                        e,
                        width: 24,
                        height: 24,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Obx(
                            () => Switch(
                              value: !AppSettingsController.instance.hiddenSites
                                  .contains(e.id),
                              onChanged: (show) => AppSettingsController
                                  .instance
                                  .setSiteHidden(e.id, !show),
                            ),
                          ),
                          const Icon(Icons.drag_handle),
                        ],
                      ),
                    );
                  },
                ).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
