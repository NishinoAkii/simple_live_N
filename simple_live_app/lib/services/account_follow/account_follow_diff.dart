import 'package:simple_live_app/services/account_follow/account_follow_models.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 本地的一个关注（只取比对要用的几项）
class LocalFollowRef {
  final String siteId;
  final String roomId;
  final String userName;
  final String face;

  /// 对应关系里的平台用户 ID 与平台房间号（没有对应关系时为空）
  final String accountUid;
  final String accountRoomId;

  const LocalFollowRef({
    required this.siteId,
    required this.roomId,
    required this.userName,
    this.face = "",
    this.accountUid = "",
    this.accountRoomId = "",
  });

  String get followId => "${siteId}_$roomId";

  factory LocalFollowRef.of({
    required String siteId,
    required String roomId,
    required String userName,
    String face = "",
    AccountFollowLink? link,
  }) =>
      LocalFollowRef(
        siteId: siteId,
        roomId: roomId,
        userName: userName,
        face: face,
        accountUid: link?.accountUid ?? "",
        accountRoomId: link?.accountRoomId ?? "",
      );
}

/// 把账号关注和本地关注对上：房间号相同（含对应关系里记的真实房间号），或平台用户 ID 相同
class AccountFollowMatcher {
  final String siteId;
  final Map<String, LocalFollowRef> _byRoom = {};
  final Map<String, LocalFollowRef> _byUid = {};

  AccountFollowMatcher(this.siteId, Iterable<LocalFollowRef> locals) {
    for (var local in locals) {
      _byRoom.putIfAbsent(
          normalizeFollowRoomId(siteId, local.roomId), () => local);
      if (local.accountRoomId.isNotEmpty) {
        _byRoom.putIfAbsent(
          normalizeFollowRoomId(siteId, local.accountRoomId),
          () => local,
        );
      }
      if (local.accountUid.isNotEmpty) {
        _byUid.putIfAbsent(local.accountUid, () => local);
      }
    }
  }

  LocalFollowRef? match(AccountFollowItem item) =>
      _byRoom[normalizeFollowRoomId(siteId, item.roomId)] ??
      (item.accountUid.isEmpty ? null : _byUid[item.accountUid]);

  /// 本地关注里还没对上的（没有对应关系，房间号也不在账号列表里）
  static List<LocalFollowRef> unmatched(
    String siteId,
    Iterable<LocalFollowRef> locals,
    Iterable<AccountFollowItem> items,
  ) {
    var matched = <String>{};
    var matcher = AccountFollowMatcher(siteId, locals);
    for (var item in items) {
      var local = matcher.match(item);
      if (local != null) {
        matched.add(local.followId);
      }
    }
    return locals.where((e) => !matched.contains(e.followId)).toList();
  }
}

/// 导入预览里的一项
class ImportPreviewEntry {
  final AccountFollowItem item;

  /// 已经在 App 关注里的那一个
  final LocalFollowRef? existing;

  /// 用户以前在 App 里取消过它
  final bool removedBefore;

  bool selected;

  ImportPreviewEntry({
    required this.item,
    this.existing,
    this.removedBefore = false,
    required this.selected,
  });

  bool get alreadyFollowed => existing != null;
}

/// 导入预览：账号里每个关注一项，已在关注里的不能选，以前在 App 里取消过的默认不选
List<ImportPreviewEntry> buildImportPreview({
  required String siteId,
  required List<AccountFollowItem> items,
  required List<LocalFollowRef> locals,
  List<AccountFollowTombstone> tombstones = const [],
}) {
  var matcher = AccountFollowMatcher(siteId, locals);
  return items.map((item) {
    var existing = matcher.match(item);
    var removed = existing == null && tombstones.any((t) => t.matches(item));
    return ImportPreviewEntry(
      item: item,
      existing: existing,
      removedBefore: removed,
      selected: existing == null && !removed,
    );
  }).toList();
}

/// 同步预览里的一类改动
enum SyncChangeKind {
  /// 账号新增（基准里没有），加到 App
  addToApp,

  /// 账号里有、App 里没有、基准里有（以前同步过），加回 App
  restoreToApp,

  /// 上次同步后在账号上取关了，从 App 移除
  removeFromApp,

  /// App 新增、账号里没有，在账号上关注（打开“同步到账号”时才有）
  followOnAccount,

  /// App 里取关了、账号里还有，在账号上取关（打开“同步到账号”时才有）
  unfollowOnAccount,
}

class SyncChange {
  final SyncChangeKind kind;

  /// 账号上的那一项（addToApp、restoreToApp、unfollowOnAccount）
  final AccountFollowItem? item;

  /// 本地的那一个（removeFromApp、followOnAccount；unfollowOnAccount 时为取关记录里的房间号）
  final LocalFollowRef? local;

  /// 补充说明（如 Kick 的列表可能不全）
  final String? note;

  bool selected;

  SyncChange({
    required this.kind,
    this.item,
    this.local,
    this.note,
    required this.selected,
  });

  String get roomId => local?.roomId ?? item!.roomId;
  String get userName => item?.userName ?? local!.userName;
  String get face => item?.face ?? local!.face;

  /// 要在账号上执行
  bool get writesAccount =>
      kind == SyncChangeKind.followOnAccount ||
      kind == SyncChangeKind.unfollowOnAccount;
}

class AccountFollowDiff {
  final List<SyncChange> changes;

  /// 两边一致的个数
  final int inSync;

  /// 以前在 App 里“仅在 App 里取消”、这次不再建议的个数
  final int ignored;

  /// 能不能据此从 App 移除（列表完整、不是空列表）
  final bool removalsAllowed;

  /// 第一次同步（没有基准，或换了账号）
  final bool firstSync;

  /// 提示（读取不完整等）
  final String? warning;

  const AccountFollowDiff({
    required this.changes,
    required this.inSync,
    this.ignored = 0,
    required this.removalsAllowed,
    required this.firstSync,
    this.warning,
  });

  List<SyncChange> of(SyncChangeKind kind) =>
      changes.where((e) => e.kind == kind).toList();

  bool get isEmpty => changes.isEmpty;
}

/// 三方比对：账号列表、上次同步的基准（快照）、App 的关注
///
/// | 账号 | 基准 | App | 判定 | 默认 |
/// |---|---|---|---|---|
/// | 有 | 无 | 无 | 账号新增 → 加到 App | 勾选 |
/// | 有 | 有 | 无 | 账号里有、App 没有 → 加回 App | 不勾 |
/// | 有 | — | 无，且用户在 App 里取消过 | App 里取关了 → 在账号取关（只在打开同步开关时） | 不勾 |
/// | 无 | 有 | 有 | 账号上取关了 → 从 App 移除 | 不勾 |
/// | 无 | 无 | 有 | App 新增 → 在账号关注（只在打开同步开关、列表完整时） | 不勾 |
///
/// - 列表不完整（截断、出错）、或账号列表为空而基准不为空时，不推断“账号上取关了”；
/// - 没有基准或换了账号（owner 不同）时当作第一次同步，同样不推断取关；
/// - [listIsAuthoritative] 为 false（Kick）时，“账号上取关了”只作为建议并附说明；
/// - “仅在 App 里取消”过的不再建议任何操作。
AccountFollowDiff computeAccountFollowDiff({
  required String siteId,
  required String owner,
  required AccountFollowFetchResult fetch,
  required List<LocalFollowRef> locals,
  AccountFollowSnapshot? snapshot,
  List<AccountFollowTombstone> tombstones = const [],
  bool listIsAuthoritative = true,
  bool writeBack = false,
}) {
  var base = snapshot != null && snapshot.owner == owner && owner.isNotEmpty
      ? snapshot
      : null;
  var emptyButHadSome =
      fetch.items.isEmpty && (base?.entries.isNotEmpty ?? false);
  var removalsAllowed = fetch.complete && base != null && !emptyButHadSome;
  String? warning;
  if (!fetch.complete) {
    warning = "{p}，不会从 App 移除关注，也不会在账号上补关注".tf({"p": fetch.incompleteReason ?? "列表没读完".t});
  } else if (emptyButHadSome) {
    warning = "账号的关注列表是空的，可能没读到，不会从 App 移除关注".t;
  }

  var matcher = AccountFollowMatcher(siteId, locals);
  var matched = <String>{};
  var changes = <SyncChange>[];
  var inSync = 0;
  var ignored = 0;
  for (var item in fetch.items) {
    var local = matcher.match(item);
    if (local != null) {
      matched.add(local.followId);
      inSync++;
      continue;
    }
    var tombstone = tombstones.where((t) => t.matches(item)).firstOrNull;
    if (tombstone != null) {
      if (writeBack && !tombstone.localOnly) {
        // 回写用取关记录里的本地房间号，成功后对应的取关记录一起清掉
        changes.add(
          SyncChange(
            kind: SyncChangeKind.unfollowOnAccount,
            item: item,
            local: LocalFollowRef(
              siteId: siteId,
              roomId: tombstone.roomId,
              userName: item.userName,
              face: item.face,
              accountUid: tombstone.accountUid,
            ),
            selected: false,
          ),
        );
      } else {
        ignored++;
      }
      continue;
    }
    var known = base?.containsItem(item) ?? false;
    changes.add(
      SyncChange(
        kind: known ? SyncChangeKind.restoreToApp : SyncChangeKind.addToApp,
        item: item,
        selected: !known,
      ),
    );
  }
  for (var local in locals) {
    if (matched.contains(local.followId)) {
      continue;
    }
    var known = base != null &&
        (base.contains(roomId: local.roomId, uid: local.accountUid) ||
            (local.accountRoomId.isNotEmpty &&
                base.contains(roomId: local.accountRoomId)));
    if (known) {
      if (removalsAllowed) {
        changes.add(
          SyncChange(
            kind: SyncChangeKind.removeFromApp,
            local: local,
            selected: false,
            note: listIsAuthoritative ? null : "列表可能不全，请确认真的取关了".t,
          ),
        );
      }
      continue;
    }
    if (writeBack && fetch.complete) {
      changes.add(
        SyncChange(
          kind: SyncChangeKind.followOnAccount,
          local: local,
          selected: false,
        ),
      );
    }
  }
  return AccountFollowDiff(
    changes: changes,
    inSync: inSync,
    ignored: ignored,
    removalsAllowed: removalsAllowed,
    firstSync: base == null,
    warning: warning,
  );
}

/// 同步或导入后新的基准：列表完整时就是这次读到的；不完整时只把读到的并进旧基准（不删）；
/// 读到空列表而旧基准不为空时保留旧基准
AccountFollowSnapshot nextAccountFollowSnapshot({
  required String siteId,
  required String owner,
  required AccountFollowFetchResult fetch,
  AccountFollowSnapshot? previous,
  required DateTime now,
}) {
  var entries =
      fetch.items.map((e) => SnapshotEntry(e.roomId, e.accountUid)).toList();
  var base = previous != null && previous.owner == owner ? previous : null;
  // 读到的是空列表时不信它（可能没读到），保留原来的基准
  if (entries.isEmpty && base != null && base.entries.isNotEmpty) {
    return base;
  }
  if (!fetch.complete && base != null) {
    var merged = base;
    for (var entry in entries) {
      merged = merged.added(entry.roomId, entry.uid, now);
    }
    return AccountFollowSnapshot(
      siteId: siteId,
      owner: owner,
      entries: merged.entries,
      time: now,
    );
  }
  return AccountFollowSnapshot(
    siteId: siteId,
    owner: owner,
    entries: entries,
    time: now,
  );
}
