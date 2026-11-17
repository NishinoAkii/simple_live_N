import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_import_controller.dart';
import 'package:simple_live_app/services/account_follow/account_follow_diff.dart';
import 'package:simple_live_app/services/account_follow/account_follow_models.dart';
import 'package:simple_live_app/services/account_follow/account_follow_platforms.dart';
import 'package:simple_live_app/services/account_follow_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 与账号同步：读取账号关注，和上次同步的记录、App 的关注三方比对，确认后执行
class AccountFollowSyncController extends GetxController {
  final siteId = RxnString();
  bool _fixedSite = false;

  final stage = AccountFollowStage.pick.obs;
  final progress = "".obs;
  final error = "".obs;
  final saving = false.obs;

  AccountFollowLoad? result;
  final diff = Rxn<AccountFollowDiff>();

  /// 勾选变化时加一
  final version = 0.obs;

  /// 读取时“同步到账号”是否打开
  bool writeBack = false;

  int _loadId = 0;
  bool _cancelled = false;

  AccountFollowService get service => AccountFollowService.instance;

  AccountFollowPlatform? get platform =>
      AccountFollowPlatforms.of(siteId.value ?? "");

  String get platformName => AccountFollowService.siteName(siteId.value ?? "");

  String get followWord => platform?.followWord ?? "关注##verb".t;

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
      writeBack = service.isWriteBackOn(id);
      var value = computeAccountFollowDiff(
        siteId: id,
        owner: loaded.owner,
        fetch: loaded.fetch,
        locals: loaded.locals,
        snapshot: service.repo.snapshot(id),
        tombstones: service.repo.tombstonesForSite(id),
        listIsAuthoritative:
            loaded.site.accountFollowPolicy.listIsAuthoritative,
        writeBack: writeBack,
      );
      if (value.isEmpty) {
        // 两边一致：记下这次的状态，作为下次比对的基准
        await service.sync.saveSnapshot(
          siteId: id,
          owner: loaded.owner,
          fetch: loaded.fetch,
        );
      }
      diff.value = value;
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

  void toggle(SyncChange change, bool value) {
    change.selected = value;
    version.value++;
  }

  void selectGroup(SyncChangeKind kind, bool value) {
    for (var change in diff.value?.of(kind) ?? const <SyncChange>[]) {
      change.selected = value;
    }
    version.value++;
  }

  int selectedOf(SyncChangeKind kind) =>
      diff.value?.of(kind).where((e) => e.selected).length ?? 0;

  int get selectedCount =>
      diff.value?.changes.where((e) => e.selected).length ?? 0;

  /// 执行前的汇总
  String summary() {
    var add = selectedOf(SyncChangeKind.addToApp) +
        selectedOf(SyncChangeKind.restoreToApp);
    var remove = selectedOf(SyncChangeKind.removeFromApp);
    var follow = selectedOf(SyncChangeKind.followOnAccount);
    var unfollow = selectedOf(SyncChangeKind.unfollowOnAccount);
    var parts = <String>[];
    if (add > 0 || remove > 0) {
      parts.add([
        if (add > 0) "在 App 添加 {add} 个".tf({"add": add}),
        if (remove > 0) "从 App 移除 {remove} 个".tf({"remove": remove}),
      ].join("、".t));
    }
    var writes = follow + unfollow;
    if (writes > 0) {
      var site = result!.site;
      var seconds =
          AccountFollowService.estimateWriteTime(site, writes).inSeconds;
      var time =
          seconds < 90 ? "约 {seconds} 秒".tf({"seconds": seconds}) : "约 {ceil} 分钟".tf({"ceil": (seconds / 60).ceil()});
      var policy = site.accountFollowPolicy;
      var extra = [
        time,
        if (writes > policy.batchLimit) "超过 {batchLimit} 条会分批，中间休息几分钟".tf({"batchLimit": policy.batchLimit}),
        if (policy.writeQuotaCost > 0)
          "约用 {p} 点配额".tf({"p": policy.writeQuotaCost * writes}),
      ].join("，".t);
      var actions = [
        if (follow > 0) "{followWord} {follow} 个".tf({"followWord": followWord, "follow": follow}),
        if (unfollow > 0) "取消{followWord} {unfollow} 个".tf({"followWord": followWord, "unfollow": unfollow}),
      ].join("、".t);
      parts.add("在{platformName}账号{actions}（{extra}）".tf({"platformName": platformName, "actions": actions, "extra": extra}));
    }
    return "将{parts}。".tf({"parts": parts.join("；".t)});
  }

  Future<void> apply() async {
    var loaded = result;
    var value = diff.value;
    var id = siteId.value;
    if (loaded == null || value == null || id == null || saving.value) {
      return;
    }
    if (selectedCount == 0) {
      SmartDialog.showToast("还没有勾选要执行的".t);
      return;
    }
    var ok = await Get.dialog<bool>(
      AlertDialog(
        title: Text("确认同步".t),
        content: Text(summary()),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: Text("取消".t),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: Text("执行".t),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    saving.value = true;
    try {
      // App 这边以“同步”的来源改动：不会再同步回账号
      var counts = await service.sync.applySync(
        siteId: id,
        owner: loaded.owner,
        fetch: loaded.fetch,
        diff: value,
        addLocal: (user) => FollowService.instance
            .follow(user, origin: FollowChangeOrigin.sync),
        removeLocal: (followId) async {
          var user = DBService.instance.followBox.get(followId);
          if (user != null) {
            await FollowService.instance.unfollow(
              user,
              origin: FollowChangeOrigin.sync,
            );
          }
        },
      );
      var writes = (counts[SyncChangeKind.followOnAccount] ?? 0) +
          (counts[SyncChangeKind.unfollowOnAccount] ?? 0);
      if (writes > 0) {
        service.kick();
      }
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      FollowService.instance.loadData();
      SmartDialog.showToast(
        writes > 0 ? "App 里已改好，账号那边逐条同步".t : "已同步".t,
      );
      Get.back();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("同步失败：{e}".tf({"e": e}));
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
