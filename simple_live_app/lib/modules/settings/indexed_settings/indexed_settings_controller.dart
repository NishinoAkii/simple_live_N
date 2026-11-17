import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';

class IndexedSettingsController extends GetxController {
  RxList<String> siteSort = RxList<String>();
  RxList<String> homeSort = RxList<String>();
  @override
  void onInit() {
    siteSort = AppSettingsController.instance.siteSort;
    homeSort = AppSettingsController.instance.homeSort;
    super.onInit();
  }

  /// 排序里能显示的平台：已删除的直播源不显示，但保留在排序里（装回来时位置不变）
  List<String> get visibleSiteSort =>
      siteSort.where((e) => Sites.allSites.containsKey(e)).toList();

  void updateSiteSort(int oldIndex, int newIndex) {
    var visible = visibleSiteSort;
    final String item = visible.removeAt(oldIndex);
    visible.insert(newIndex, item);
    var hidden = siteSort.where((e) => !Sites.allSites.containsKey(e));
    AppSettingsController.instance.setSiteSort([...visible, ...hidden]);
  }

  void updateHomeSort(int oldIndex, int newIndex) {
    final String item = homeSort.removeAt(oldIndex);
    homeSort.insert(newIndex, item);
    // ignore: invalid_use_of_protected_member
    AppSettingsController.instance.setHomeSort(homeSort.value);
  }
}
