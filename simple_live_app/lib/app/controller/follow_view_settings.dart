import 'package:get/get.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 关注页的显示方式：分组、排序、样式和折叠了哪些组。
///
/// 都只存在本机，不进备份（见 SyncCompat.localOnlySettingKeys）。
/// 默认值就是原来的样子：不分组、直播中的在前、列表
class FollowViewSettings {
  /// 分组显示（默认关）
  static const String kGrouped = "FollowGrouped";

  /// 分组方式：[groupSite]、[groupTag]、[groupStatus]
  static const String kGroupMode = "FollowGroupMode";

  /// 排序：[sortLive]、[sortWatched]、[sortStarted]、[sortAdded]、[sortName]
  static const String kSortMode = "FollowSortMode";

  /// 样式：[styleList]、[styleCompact]、[styleCard]
  static const String kStyle = "FollowViewStyle";

  /// 折叠了的组（组的键，见 FollowGroup.key）
  static const String kCollapsed = "FollowGroupCollapsed";

  static const List<String> storageKeys = [
    kGrouped,
    kGroupMode,
    kSortMode,
    kStyle,
    kCollapsed,
  ];

  static const String groupSite = "site";
  static const String groupTag = "tag";
  static const String groupStatus = "status";
  static const List<String> groupModes = [groupSite, groupTag, groupStatus];

  static const String sortLive = "live";
  static const String sortWatched = "watched";
  static const String sortStarted = "started";
  static const String sortAdded = "added";
  static const String sortName = "name";
  static const List<String> sortModes = [
    sortLive,
    sortWatched,
    sortStarted,
    sortAdded,
    sortName,
  ];

  static const String styleList = "list";
  static const String styleCompact = "compact";
  static const String styleCard = "card";
  static const List<String> styles = [styleList, styleCompact, styleCard];

  final grouped = false.obs;
  final groupMode = groupSite.obs;
  final sortMode = sortLive.obs;
  final style = styleList.obs;
  final collapsed = <String>{}.obs;

  static LocalStorageService? get _storage =>
      Get.isRegistered<LocalStorageService>()
          ? LocalStorageService.instance
          : null;

  static String _pick(String? value, List<String> allowed) =>
      allowed.contains(value) ? value! : allowed.first;

  /// 从本机读；没有存过、或者存的值不认识时用默认值
  void load() {
    var s = _storage;
    if (s == null) return;
    grouped.value = s.getValue<bool>(kGrouped, false);
    groupMode.value =
        _pick(s.getValue<String>(kGroupMode, groupSite), groupModes);
    sortMode.value = _pick(s.getValue<String>(kSortMode, sortLive), sortModes);
    style.value = _pick(s.getValue<String>(kStyle, styleList), styles);
    var list = s.getValue<List>(kCollapsed, const []);
    collapsed.assignAll(list.map((e) => e.toString()));
  }

  void setGrouped(bool value) {
    grouped.value = value;
    _storage?.setValue(kGrouped, value);
  }

  void setGroupMode(String value) {
    groupMode.value = _pick(value, groupModes);
    _storage?.setValue(kGroupMode, groupMode.value);
  }

  void setSortMode(String value) {
    sortMode.value = _pick(value, sortModes);
    _storage?.setValue(kSortMode, sortMode.value);
  }

  void setStyle(String value) {
    style.value = _pick(value, styles);
    _storage?.setValue(kStyle, style.value);
  }

  void toggleCollapsed(String key) {
    if (!collapsed.remove(key)) {
      collapsed.add(key);
    }
    _storage?.setValue(kCollapsed, collapsed.toList());
  }

  /// 和原来一样：不分组的列表
  bool get isPlainList => !grouped.value && style.value == styleList;
}
