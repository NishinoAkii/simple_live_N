import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/account_follow/account_follow_diff.dart';
import 'package:simple_live_app/services/account_follow/account_follow_models.dart';
import 'package:simple_live_app/services/account_follow/account_follow_platforms.dart';
import 'package:simple_live_app/services/account_follow/account_follow_queue.dart';
import 'package:simple_live_app/services/account_follow/account_follow_store.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 导入、同步和单条回写的规则（不依赖 GetX，便于测试）
///
/// 本地优先：App 的关注列表是主列表，改动马上生效；要写到账号上的放进
/// [AccountFollowQueue] 慢慢执行。只有用户在 App 里亲手关注/取关、并且该平台打开了
/// “同步到账号”，才会进队列。
class AccountFollowSync {
  final AccountFollowRepository repo;
  final AccountFollowQueue queue;

  /// 该平台的“同步到账号”开关
  final bool Function(String siteId) writeBackOn;
  final DateTime Function() now;

  AccountFollowSync({
    required this.repo,
    required this.queue,
    required this.writeBackOn,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  int _seq = 0;

  String _newJobId() => "${now().microsecondsSinceEpoch}-${_seq++}";

  /// 是否要写到账号：只有用户亲手的操作、平台支持、开关打开、没有选“仅在 App 里”
  static bool shouldWriteBack({
    required FollowChangeOrigin origin,
    required bool enabled,
    required bool supported,
    bool localOnly = false,
  }) =>
      origin == FollowChangeOrigin.user && enabled && supported && !localOnly;

  /// 本地关注变化后调用
  ///
  /// - 关注（任何来源）：清掉以前的取关记录；
  /// - 用户亲手取关：记下取关记录，手动同步时用来判断“App 里取关了”；
  /// - 同一个关注还在排队的反向操作先去掉（任何来源都这样），此时返回 cancelledOut；
  /// - 满足 [shouldWriteBack] 时加入回写队列，返回加入的结果，否则返回 null。
  Future<FollowEnqueueResult?> onLocalChange({
    required String siteId,
    required String roomId,
    required String userName,
    String face = "",
    required FollowWriteAction action,
    required FollowChangeOrigin origin,
    bool localOnly = false,
  }) async {
    var platform = AccountFollowPlatforms.of(siteId);
    if (platform == null) {
      return null;
    }
    var followId = "${siteId}_$roomId";
    // 不管这次要不要写到账号，先去掉还在排队的反向操作：
    // 例如关注还没同步过去，用户就选了“仅在 App 里取消”，那条关注不能再执行
    var cancelled = await queue.cancelOpposite(siteId, followId, action);
    if (action == FollowWriteAction.follow) {
      await repo.deleteTombstone(followId);
    } else if (origin == FollowChangeOrigin.user) {
      await repo.putTombstone(
        AccountFollowTombstone(
          siteId: siteId,
          roomId: roomId,
          accountUid: repo.link(followId)?.accountUid ?? "",
          localOnly: localOnly,
          time: now(),
        ),
      );
    }
    if (!shouldWriteBack(
      origin: origin,
      enabled: writeBackOn(siteId),
      supported: platform.canWriteBack,
      localOnly: localOnly,
    )) {
      return cancelled > 0 ? FollowEnqueueResult.cancelledOut : null;
    }
    if (cancelled > 0) {
      return FollowEnqueueResult.cancelledOut;
    }
    return queue.enqueue(
      FollowWriteJob(
        id: _newJobId(),
        siteId: siteId,
        roomId: roomId,
        userName: userName,
        face: face,
        action: action,
        origin: FollowChangeOrigin.user,
        createdAt: now(),
      ),
    );
  }

  /// 本地关注（带上对应关系）
  List<LocalFollowRef> localRefs(String siteId, Iterable<FollowUser> follows) =>
      follows
          .where((e) => e.siteId == siteId)
          .map(
            (e) => LocalFollowRef.of(
              siteId: siteId,
              roomId: e.roomId,
              userName: e.userName,
              face: e.face,
              link: repo.link(e.id),
            ),
          )
          .toList();

  /// 本地已有关注里还没和账号列表对上、也没有对应关系的（B站短号、斗鱼靓号），
  /// 查一次换成平台 ID 并记下。最多查 [max] 个，返回查到的个数
  Future<int> resolveUnmatched({
    required String siteId,
    required LiveAccountFollowSite site,
    required List<LocalFollowRef> locals,
    required List<AccountFollowItem> items,
    int max = 50,
    Future<void> Function(Duration)? sleep,
    bool Function()? isCancelled,
  }) async {
    if (!site.accountFollowPolicy.needsRoomResolve) {
      return 0;
    }
    var wait = sleep ?? (d) => Future<void>.delayed(d);
    var todo = AccountFollowMatcher.unmatched(
      siteId,
      locals,
      items,
    ).where((e) => e.accountUid.isEmpty).take(max).toList();
    var count = 0;
    for (var i = 0; i < todo.length; i++) {
      if (isCancelled?.call() ?? false) {
        break;
      }
      if (i > 0) {
        await wait(const Duration(milliseconds: 250));
      }
      var local = todo[i];
      try {
        var target = await site.resolveAccountFollowTarget(local.roomId);
        await repo.putLink(
          AccountFollowLink(
            siteId: siteId,
            roomId: local.roomId,
            accountUid: target.accountUid,
            accountRoomId: target.roomId,
            extra: target.extra,
            linkedAt: now(),
          ),
        );
        count++;
      } catch (_) {
        // 查不到的保持原样：只会少一个“已在关注里”的标记
      }
    }
    return count;
  }

  Future<void> _link(String siteId, String roomId, AccountFollowItem item) =>
      repo.putLink(
        AccountFollowLink(
          siteId: siteId,
          roomId: roomId,
          accountUid: item.accountUid,
          accountRoomId: item.roomId,
          extra: item.extra,
          linkedAt: now(),
        ),
      );

  /// 保存新的基准（没有账号标识时不保存）
  Future<void> saveSnapshot({
    required String siteId,
    required String owner,
    required AccountFollowFetchResult fetch,
  }) async {
    if (owner.isEmpty) {
      return;
    }
    await repo.putSnapshot(
      nextAccountFollowSnapshot(
        siteId: siteId,
        owner: owner,
        fetch: fetch,
        previous: repo.snapshot(siteId),
        now: now(),
      ),
    );
  }

  FollowUser _followUser(String siteId, AccountFollowItem item, String tag) =>
      FollowUser(
        id: "${siteId}_${item.roomId}",
        roomId: item.roomId,
        siteId: siteId,
        userName: item.userName,
        face: item.face,
        addTime: now(),
        tag: tag,
      );

  /// 导入预览里选中的加到 App（[addLocal] 以“导入”的来源添加，不会回写），
  /// 记下对应关系和基准。返回添加的个数
  Future<int> applyImport({
    required String siteId,
    required String owner,
    required AccountFollowFetchResult fetch,
    required List<ImportPreviewEntry> entries,
    String tag = "全部",
    required Future<void> Function(FollowUser user) addLocal,
  }) async {
    var added = 0;
    for (var entry in entries) {
      var existing = entry.existing;
      if (existing != null) {
        await _link(siteId, existing.roomId, entry.item);
        continue;
      }
      if (!entry.selected) {
        continue;
      }
      await addLocal(_followUser(siteId, entry.item, tag));
      await _link(siteId, entry.item.roomId, entry.item);
      added++;
    }
    await saveSnapshot(siteId: siteId, owner: owner, fetch: fetch);
    return added;
  }

  /// 执行同步预览里勾选的改动
  ///
  /// App 这边的马上改（[addLocal]、[removeLocal] 以“同步”的来源执行，不会回写），
  /// 账号这边的放进队列（只在打开了“同步到账号”时）。返回各类的个数
  Future<Map<SyncChangeKind, int>> applySync({
    required String siteId,
    required String owner,
    required AccountFollowFetchResult fetch,
    required AccountFollowDiff diff,
    String tag = "全部",
    required Future<void> Function(FollowUser user) addLocal,
    required Future<void> Function(String followId) removeLocal,
  }) async {
    var counts = <SyncChangeKind, int>{};
    var canWrite = writeBackOn(siteId) &&
        (AccountFollowPlatforms.of(siteId)?.canWriteBack ?? false);
    for (var change in diff.changes.where((e) => e.selected)) {
      switch (change.kind) {
        case SyncChangeKind.addToApp:
        case SyncChangeKind.restoreToApp:
          var item = change.item!;
          await addLocal(_followUser(siteId, item, tag));
          await _link(siteId, item.roomId, item);
          break;
        case SyncChangeKind.removeFromApp:
          await removeLocal(change.local!.followId);
          break;
        case SyncChangeKind.followOnAccount:
        case SyncChangeKind.unfollowOnAccount:
          if (!canWrite) {
            continue;
          }
          var local = change.local;
          var item = change.item;
          var roomId = local?.roomId ?? item!.roomId;
          if (item != null) {
            await _link(siteId, roomId, item);
          }
          await queue.enqueue(
            FollowWriteJob(
              id: _newJobId(),
              siteId: siteId,
              roomId: roomId,
              userName: change.userName,
              face: change.face,
              action: change.kind == SyncChangeKind.followOnAccount
                  ? FollowWriteAction.follow
                  : FollowWriteAction.unfollow,
              origin: FollowChangeOrigin.sync,
              createdAt: now(),
            ),
          );
          break;
      }
      counts[change.kind] = (counts[change.kind] ?? 0) + 1;
    }
    await saveSnapshot(siteId: siteId, owner: owner, fetch: fetch);
    return counts;
  }
}
