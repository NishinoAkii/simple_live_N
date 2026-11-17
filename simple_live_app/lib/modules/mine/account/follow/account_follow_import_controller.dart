import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/account_follow/account_follow_diff.dart';
import 'package:simple_live_app/services/account_follow/account_follow_models.dart';
import 'package:simple_live_app/services/account_follow_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 读取账号关注的几个阶段
enum AccountFollowStage { pick, loading, loaded, error }

/// 从账号导入关注：读取 → 预览勾选 → 添加到 App（不会改动账号）
class AccountFollowImportController extends GetxController {
  /// 平台；从关注页进来时为空，先选平台
  final siteId = RxnString();

  /// 进来时就指定了平台（取消读取时直接返回）
  bool _fixedSite = false;

  final stage = AccountFollowStage.pick.obs;
  final progress = "".obs;
  final error = "".obs;
  final saving = false.obs;

  AccountFollowLoad? result;
  final entries = <ImportPreviewEntry>[].obs;
  final onlyLive = false.obs;
  final keyword = "".obs;

  /// 放入标签：空为不放，[kNewTag] 为新建，其它为已有标签的名字
  final tag = "".obs;
  static const String kNewTag = "\u0000new";

  int _loadId = 0;
  bool _cancelled = false;

  AccountFollowService get service => AccountFollowService.instance;

  @override
  void onInit() {
    var arg = Get.arguments;
    if (arg is String && arg.isNotEmpty) {
      _fixedSite = true;
      siteId.value = arg;
      load();
    }
    super.onInit();
  }

  String get platformName => AccountFollowService.siteName(siteId.value ?? "");

  /// 新建标签的名字
  String get newTagName => "{platformName}导入".tf({"platformName": platformName});

  List<String> get existingTags =>
      DBService.instance.getFollowTagList().map((e) => e.tag).toList();

  void pick(String id) {
    siteId.value = id;
    load();
  }

  Future<void> load() async {
    var id = siteId.value;
    if (id == null) {
      return;
    }
    var loadId = ++_loadId;
    _cancelled = false;
    stage.value = AccountFollowStage.loading;
    progress.value = "正在读取…".t;
    try {
      var loaded = await service.load(
        id,
        onProgress: (text) {
          if (loadId == _loadId) {
            progress.value = text;
          }
        },
        isCancelled: () => _cancelled || loadId != _loadId,
      );
      if (loadId != _loadId) {
        return;
      }
      result = loaded;
      entries.assignAll(
        buildImportPreview(
          siteId: id,
          items: loaded.fetch.items,
          locals: loaded.locals,
          tombstones: service.repo.tombstonesForSite(id),
        ),
      );
      stage.value = AccountFollowStage.loaded;
    } on AccountFollowCancelled {
      // 已经在 cancel() 里处理
    } catch (e) {
      if (loadId != _loadId) {
        return;
      }
      Log.logPrint(e);
      error.value =
          e is CoreError && e.message.isNotEmpty ? e.message : "读取失败：{e}".tf({"e": e});
      stage.value = AccountFollowStage.error;
    }
  }

  void cancel() {
    _cancelled = true;
    _loadId++;
    if (_fixedSite) {
      Get.back();
    } else {
      stage.value = AccountFollowStage.pick;
    }
  }

  /// 按“只看直播中”和搜索筛选后的
  List<ImportPreviewEntry> get visible {
    var text = keyword.value.trim().toLowerCase();
    return entries.where((e) {
      if (onlyLive.value && e.item.isLive != true) {
        return false;
      }
      if (text.isEmpty) {
        return true;
      }
      return e.item.userName.toLowerCase().contains(text) ||
          e.item.roomId.toLowerCase().contains(text);
    }).toList();
  }

  int get selectedCount =>
      entries.where((e) => e.selected && !e.alreadyFollowed).length;

  int get followedCount => entries.where((e) => e.alreadyFollowed).length;

  /// 全选 / 全不选（只作用于当前筛选出来的）
  void selectAll(bool value) {
    for (var entry in visible) {
      if (!entry.alreadyFollowed) {
        entry.selected = value;
      }
    }
    entries.refresh();
  }

  void toggle(ImportPreviewEntry entry, bool value) {
    if (entry.alreadyFollowed) {
      return;
    }
    entry.selected = value;
    entries.refresh();
  }

  Future<void> apply() async {
    var loaded = result;
    var id = siteId.value;
    if (loaded == null || id == null || saving.value) {
      return;
    }
    if (selectedCount == 0) {
      SmartDialog.showToast("还没有选中要添加的".t);
      return;
    }
    saving.value = true;
    try {
      var tagName = tag.value.isEmpty
          ? "全部"
          : tag.value == kNewTag
              ? newTagName
              : tag.value;
      var added = <String>[];
      var count = await service.sync.applyImport(
        siteId: id,
        owner: loaded.owner,
        fetch: loaded.fetch,
        entries: entries,
        tag: tagName,
        // 以“导入”的来源添加：不会同步到账号
        addLocal: (user) async {
          await FollowService.instance.follow(
            user,
            origin: FollowChangeOrigin.import,
          );
          added.add(user.id);
        },
      );
      if (tagName != "全部" && added.isNotEmpty) {
        var followTag = DBService.instance.getFollowTag(tagName) ??
            await DBService.instance.addFollowTag(tagName);
        for (var followId in added) {
          if (!followTag.userId.contains(followId)) {
            followTag.userId.add(followId);
          }
        }
        await DBService.instance.updateFollowTag(followTag);
      }
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      FollowService.instance.loadData();
      SmartDialog.showToast("已添加 {count} 个关注".tf({"count": count}));
      Get.back();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("添加失败：{e}".tf({"e": e}));
    } finally {
      saving.value = false;
    }
  }

  @override
  void onClose() {
    _cancelled = true;
    _loadId++;
    super.onClose();
  }
}
