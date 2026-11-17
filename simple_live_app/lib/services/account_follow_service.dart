import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/account_follow/account_follow_diff.dart';
import 'package:simple_live_app/services/account_follow/account_follow_models.dart';
import 'package:simple_live_app/services/account_follow/account_follow_platforms.dart';
import 'package:simple_live_app/services/account_follow/account_follow_queue.dart';
import 'package:simple_live_app/services/account_follow/account_follow_store.dart';
import 'package:simple_live_app/services/account_follow/account_follow_sync.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 读取账号关注的结果（导入和同步共用）
class AccountFollowLoad {
  final String siteId;
  final LiveAccountFollowSite site;
  final String owner;
  final AccountFollowFetchResult fetch;

  /// 本地这个平台的关注（已带上对应关系，短号/靓号已尽量换好）
  final List<LocalFollowRef> locals;

  const AccountFollowLoad({
    required this.siteId,
    required this.site,
    required this.owner,
    required this.fetch,
    required this.locals,
  });
}

/// 账号关注：从账号导入、手动同步、在 App 里关注/取关时同步到账号
///
/// 回写队列、对应关系、快照都存在本机的 Hive box 里（[HiveAccountFollowStore]），
/// 开关存在设置里但只在本机（SyncCompat.localOnlySettingKeys），都不进 WebDAV/局域网同步。
class AccountFollowService extends GetxService {
  static AccountFollowService get instance => Get.find<AccountFollowService>();

  /// 没有初始化（如测试）时为 null
  static AccountFollowService? get maybe =>
      Get.isRegistered<AccountFollowService>()
          ? Get.find<AccountFollowService>()
          : null;

  late final AccountFollowRepository repo;
  late final AccountFollowQueue queue;
  late final AccountFollowSync sync;

  /// 待同步和失败的（界面用）
  final jobs = <FollowWriteJob>[].obs;

  /// 各平台队列状态（界面用）
  final siteStates = <String, AccountFollowSiteState>{}.obs;

  /// 开关变化时加一，界面据此刷新
  final version = 0.obs;

  bool _ready = false;
  Timer? _timer;

  Future<void> init() async {
    repo = AccountFollowRepository(await HiveAccountFollowStore.open());
    queue = AccountFollowQueue(
      repo: repo,
      siteOf: siteOf,
      isEnabled: isWriteBackOn,
      onChanged: _refresh,
      onJobFinished: _onJobFinished,
    );
    sync = AccountFollowSync(
      repo: repo,
      queue: queue,
      writeBackOn: isWriteBackOn,
    );
    _ready = true;
    _refresh();
    // 启动时别和其它请求挤在一起，稍等再继续上次没做完的
    _schedule(const Duration(seconds: 15));
  }

  static LiveAccountFollowSite? siteOf(String siteId) {
    var site = Sites.allSites[siteId]?.liveSite;
    return site is LiveAccountFollowSite ? site as LiveAccountFollowSite : null;
  }

  static String siteName(String siteId) =>
      AccountFollowPlatforms.of(siteId)?.name ??
      Sites.allSites[siteId]?.name ??
      siteId;

  bool isWriteBackOn(String siteId) => AccountFollowPlatforms.writeBackEnabled(
        siteId,
        LocalStorageService.instance.getValue,
      );

  Future<void> setWriteBack(String siteId, bool value) async {
    var key = AccountFollowPlatforms.of(siteId)?.writeBackKey;
    if (key == null) {
      return;
    }
    await LocalStorageService.instance.setValue(key, value);
    version.value++;
    if (value) {
      kick();
    }
  }

  void _refresh() {
    if (!_ready) {
      return;
    }
    jobs.assignAll(repo.jobs());
    var states = <String, AccountFollowSiteState>{};
    for (var platform in AccountFollowPlatforms.all) {
      states[platform.siteId] = repo.siteState(platform.siteId);
    }
    siteStates.assignAll(states);
  }

  /// 正在执行的那一条
  bool isInFlight(String jobId) => _ready && queue.isInFlight(jobId);

  /// 开始执行各平台的队列（已经在执行的不会重复）
  void kick() {
    // 多开的副窗口不跑队列：关注、取关交给主窗口，由主窗口同步到账号
    if (!_ready || MultiWindow.skips(BackgroundTask.accountFollowQueue)) {
      return;
    }
    var sites = repo.jobs().map((e) => e.siteId).toSet();
    for (var siteId in sites) {
      queue
          .runSite(siteId)
          .catchError((e) => Log.e("同步关注到账号出错：$e", StackTrace.current))
          .whenComplete(_scheduleNext);
    }
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, kick);
  }

  void _scheduleNext() {
    var next = queue.nextWakeUp();
    if (next == null) {
      return;
    }
    var delay = next.difference(DateTime.now());
    _schedule(delay < const Duration(seconds: 1)
        ? const Duration(seconds: 1)
        : delay);
  }

  Future<void> retry(String jobId) async {
    var job = repo.job(jobId);
    await queue.retry(jobId);
    if (job != null) {
      var state = repo.siteState(job.siteId);
      if (state.pauseKind == FollowPauseKind.auth) {
        await queue.resumeSite(job.siteId);
      }
    }
    kick();
  }

  Future<void> discard(String jobId) => queue.discard(jobId);

  Future<void> resumeSite(String siteId) async {
    await queue.resumeSite(siteId);
    kick();
  }

  /// 本地关注变化后调用（[FollowService] 的 follow/unfollow）
  Future<void> onLocalChange(
    FollowUser user,
    FollowWriteAction action,
    FollowChangeOrigin origin, {
    bool localOnly = false,
  }) async {
    if (!_ready) {
      return;
    }
    try {
      var result = await sync.onLocalChange(
        siteId: user.siteId,
        roomId: user.roomId,
        userName: user.userName,
        face: user.face,
        action: action,
        origin: origin,
        localOnly: localOnly,
      );
      if (result == FollowEnqueueResult.queued ||
          result == FollowEnqueueResult.merged) {
        kick();
      }
    } catch (e, stackTrace) {
      Log.e("记录关注变化失败：$e", stackTrace);
    }
  }

  void _onJobFinished(FollowWriteJob job, Object? error) {
    // 手动同步的批量写入在同步页和待同步列表里看，不逐条提示
    if (job.origin != FollowChangeOrigin.user) {
      if (error is AccountFollowRiskError || error is AccountFollowAuthError) {
        SmartDialog.showToast(
          "{siteName}：{message}，已暂停同步".tf({"siteName": siteName(job.siteId), "message": (error as CoreError).message}),
        );
      }
      return;
    }
    var name = siteName(job.siteId);
    var word = AccountFollowPlatforms.of(job.siteId)?.followWord ?? "关注##verb".t;
    var action = job.action == FollowWriteAction.follow ? word : "取消{word}".tf({"word": word});
    if (error == null) {
      SmartDialog.showToast("已在{name}账号{action} {userName}".tf({"name": name, "action": action, "userName": job.userName}));
    } else if (error is AccountFollowRiskError ||
        error is AccountFollowAuthError) {
      SmartDialog.showToast("{name}：{message}，已暂停同步".tf({"name": name, "message": (error as CoreError).message}));
    } else if (job.state == FollowWriteState.failed) {
      SmartDialog.showToast("没能在{name}账号{action}：{lastError}".tf({"name": name, "action": action, "lastError": job.lastError}));
    } else {
      SmartDialog.showToast("同步到{name}账号失败，稍后自动重试".tf({"name": name}));
    }
  }

  /// 取关前确认。打开了“同步到账号”时说明会同时在账号上取关，并提供“仅在 App 里取消”。
  /// 返回 null 表示不取关，否则返回是否仅在 App 里取消
  static Future<bool?> confirmUnfollow(String siteId, String userName) async {
    var platform = AccountFollowPlatforms.of(siteId);
    var service = maybe;
    var writeBack = service != null &&
        service._ready &&
        platform != null &&
        platform.canWriteBack &&
        service.isWriteBackOn(siteId);
    var who = userName.isEmpty ? "这位主播".t : userName;
    if (!writeBack) {
      var ok = await Get.dialog<bool>(
        AlertDialog(
          title: Text("取消关注".t),
          content: Text("确定要取消关注{who}吗？".tf({"who": who})),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: false),
              child: Text("取消".t),
            ),
            TextButton(
              onPressed: () => Get.back(result: true),
              child: Text("确定".t),
            ),
          ],
        ),
      );
      return ok == true ? false : null;
    }
    var localOnly = false.obs;
    var word = platform.followWord;
    var ok = await Get.dialog<bool>(
      AlertDialog(
        title: Text("取消关注".t),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("确定要取消关注{who}吗？".tf({"who": who})),
            const SizedBox(height: 8),
            Obx(
              () => Text(
                localOnly.value
                    ? "只在 App 里取消，{name}账号不变。".tf({"name": platform.name})
                    : "同时会在{name}账号取消{word}。".tf({"name": platform.name, "word": word}),
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ),
            Obx(
              () => CheckboxListTile(
                value: localOnly.value,
                onChanged: (v) => localOnly.value = v ?? false,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: Text("仅在 App 里取消".t),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: Text("取消".t),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: Text("确定".t),
          ),
        ],
      ),
    );
    return ok == true ? localOnly.value : null;
  }

  /// 读取账号关注；B站、斗鱼还会把本地没对上的短号/靓号查一次
  Future<AccountFollowLoad> load(
    String siteId, {
    void Function(String text)? onProgress,
    bool Function()? isCancelled,
  }) async {
    var site = siteOf(siteId);
    if (site == null) {
      throw CoreError("{siteName}暂不支持".tf({"siteName": siteName(siteId)}));
    }
    if (!site.canReadAccountFollows) {
      throw CoreError("请先在账号管理里登录{siteName}".tf({"siteName": siteName(siteId)}));
    }
    var fetch = await fetchAllAccountFollows(
      site,
      isCancelled: isCancelled,
      onProgress: (page, count, total) => onProgress?.call(
        total == null || total <= 0
            ? "正在读取第 {page} 页，已读到 {count} 个".tf({"page": page, "count": count})
            : "正在读取第 {page} 页，已读到 {count} / {total} 个".tf({"page": page, "count": count, "total": total}),
      ),
    );
    var follows = DBService.instance.getFollowList();
    var locals = sync.localRefs(siteId, follows);
    var unmatched = AccountFollowMatcher.unmatched(
      siteId,
      locals,
      fetch.items,
    ).where((e) => e.accountUid.isEmpty);
    if (site.accountFollowPolicy.needsRoomResolve && unmatched.isNotEmpty) {
      onProgress?.call("正在比对已有的关注…".t);
      await sync.resolveUnmatched(
        siteId: siteId,
        site: site,
        locals: locals,
        items: fetch.items,
        isCancelled: isCancelled,
      );
      locals = sync.localRefs(siteId, follows);
    }
    return AccountFollowLoad(
      siteId: siteId,
      site: site,
      owner: site.accountFollowOwner,
      fetch: fetch,
      locals: locals,
    );
  }

  /// 预计回写耗时（按平台的平均间隔）
  static Duration estimateWriteTime(LiveAccountFollowSite site, int count) {
    if (count <= 0) {
      return Duration.zero;
    }
    var policy = site.accountFollowPolicy;
    var avg = (policy.writeIntervalMin.inMilliseconds +
            policy.writeIntervalMax.inMilliseconds) ~/
        2;
    return Duration(milliseconds: avg * (count - 1) + 1000);
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }
}
