import 'package:simple_live_core/simple_live_core.dart';

/// 本地关注变化的来源
///
/// 只有用户在 App 里亲手关注/取关（[user]）才可能同步到账号；
/// 从账号导入、WebDAV/局域网恢复、抖音房间号迁移、手动同步里“账号 → App”的改动都不会。
enum FollowChangeOrigin { user, import, restore, migrate, sync }

/// 账号上的操作
enum FollowWriteAction { follow, unfollow }

/// 待同步的状态：等待（含等待重试）、失败（用完重试次数或平台拒绝，等用户处理）
enum FollowWriteState { pending, failed }

/// 统一房间号写法：Kick slug、Twitch login 不区分大小写
String normalizeFollowRoomId(String siteId, String roomId) {
  var value = roomId.trim();
  if (siteId == "kick" || siteId == "twitch") {
    return value.toLowerCase();
  }
  return value;
}

/// 一条待同步到账号的关注/取关
class FollowWriteJob {
  final String id;
  final String siteId;
  final String roomId;
  final String userName;
  final String face;
  final FollowWriteAction action;

  /// 来源：user（在 App 里关注/取关）或 sync（手动同步时勾选）
  final FollowChangeOrigin origin;
  final DateTime createdAt;

  /// 已经失败的次数（风控和登录失效不算）
  int attempts;

  /// 连续被风控拦下的次数
  int riskHits;

  /// 下次可以重试的时间，为空表示马上可以
  DateTime? nextAttemptAt;
  FollowWriteState state;
  String lastError;

  FollowWriteJob({
    required this.id,
    required this.siteId,
    required this.roomId,
    required this.userName,
    required this.face,
    required this.action,
    required this.origin,
    required this.createdAt,
    this.attempts = 0,
    this.riskHits = 0,
    this.nextAttemptAt,
    this.state = FollowWriteState.pending,
    this.lastError = "",
  });

  String get followId => "${siteId}_$roomId";

  Map<String, dynamic> toJson() => {
        "id": id,
        "siteId": siteId,
        "roomId": roomId,
        "userName": userName,
        "face": face,
        "action": action.name,
        "origin": origin.name,
        "createdAt": createdAt.millisecondsSinceEpoch,
        "attempts": attempts,
        "riskHits": riskHits,
        "nextAttemptAt": nextAttemptAt?.millisecondsSinceEpoch,
        "state": state.name,
        "lastError": lastError,
      };

  static T _enum<T extends Enum>(List<T> values, dynamic name, T fallback) =>
      values.firstWhere((e) => e.name == name, orElse: () => fallback);

  factory FollowWriteJob.fromJson(Map json) => FollowWriteJob(
        id: json["id"]?.toString() ?? "",
        siteId: json["siteId"]?.toString() ?? "",
        roomId: json["roomId"]?.toString() ?? "",
        userName: json["userName"]?.toString() ?? "",
        face: json["face"]?.toString() ?? "",
        action: _enum(
          FollowWriteAction.values,
          json["action"],
          FollowWriteAction.follow,
        ),
        origin: _enum(
          FollowChangeOrigin.values,
          json["origin"],
          FollowChangeOrigin.user,
        ),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (json["createdAt"] as num?)?.toInt() ?? 0,
        ),
        attempts: (json["attempts"] as num?)?.toInt() ?? 0,
        riskHits: (json["riskHits"] as num?)?.toInt() ?? 0,
        nextAttemptAt: json["nextAttemptAt"] is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (json["nextAttemptAt"] as num).toInt(),
              )
            : null,
        state: _enum(
          FollowWriteState.values,
          json["state"],
          FollowWriteState.pending,
        ),
        lastError: json["lastError"]?.toString() ?? "",
      );
}

/// 本地关注与平台账号上的对应关系（导入时记下，回写时用）
class AccountFollowLink {
  final String siteId;

  /// 本地关注的房间号（FollowUser.roomId）
  final String roomId;

  /// 平台用户 ID：B站 mid、斗鱼真实 rid、Kick slug、Twitch 用户 ID、YouTube 频道 ID
  final String accountUid;

  /// 平台上的房间号（B站短号对应的真实房间号等），没有时与 [roomId] 相同
  final String accountRoomId;

  /// 其它信息，如 YouTube 订阅 ID
  final Map<String, String> extra;
  final DateTime linkedAt;

  const AccountFollowLink({
    required this.siteId,
    required this.roomId,
    required this.accountUid,
    required this.accountRoomId,
    this.extra = const {},
    required this.linkedAt,
  });

  String get followId => "${siteId}_$roomId";

  AccountFollowTarget get target => AccountFollowTarget(
        roomId: accountRoomId.isEmpty ? roomId : accountRoomId,
        accountUid: accountUid,
        extra: extra,
      );

  Map<String, dynamic> toJson() => {
        "siteId": siteId,
        "roomId": roomId,
        "accountUid": accountUid,
        "accountRoomId": accountRoomId,
        "extra": extra,
        "linkedAt": linkedAt.millisecondsSinceEpoch,
      };

  factory AccountFollowLink.fromJson(Map json) => AccountFollowLink(
        siteId: json["siteId"]?.toString() ?? "",
        roomId: json["roomId"]?.toString() ?? "",
        accountUid: json["accountUid"]?.toString() ?? "",
        accountRoomId: json["accountRoomId"]?.toString() ?? "",
        extra: json["extra"] is Map
            ? (json["extra"] as Map).map((k, v) => MapEntry("$k", "$v"))
            : const {},
        linkedAt: DateTime.fromMillisecondsSinceEpoch(
          (json["linkedAt"] as num?)?.toInt() ?? 0,
        ),
      );
}

/// 快照里的一项：账号上关注的一个主播
class SnapshotEntry {
  final String roomId;
  final String uid;
  const SnapshotEntry(this.roomId, this.uid);

  Map<String, dynamic> toJson() => {"r": roomId, "u": uid};

  factory SnapshotEntry.fromJson(Map json) =>
      SnapshotEntry(json["r"]?.toString() ?? "", json["u"]?.toString() ?? "");
}

/// 上次同步（或导入）时账号的关注集合，三方比对的基准
///
/// 按平台存一份，并记下是哪个账号的：换了账号就当作第一次同步，不推导任何取关。
class AccountFollowSnapshot {
  final String siteId;
  final String owner;
  final List<SnapshotEntry> entries;
  final DateTime time;

  AccountFollowSnapshot({
    required this.siteId,
    required this.owner,
    required List<SnapshotEntry> entries,
    required this.time,
  }) : entries = List.of(entries);

  bool contains({String roomId = "", String uid = ""}) {
    var room = normalizeFollowRoomId(siteId, roomId);
    return entries.any(
      (e) =>
          (room.isNotEmpty &&
              normalizeFollowRoomId(siteId, e.roomId) == room) ||
          (uid.isNotEmpty && e.uid == uid),
    );
  }

  bool containsItem(AccountFollowItem item) =>
      contains(roomId: item.roomId, uid: item.accountUid);

  AccountFollowSnapshot added(String roomId, String uid, DateTime now) {
    if (contains(roomId: roomId, uid: uid)) {
      return this;
    }
    return AccountFollowSnapshot(
      siteId: siteId,
      owner: owner,
      entries: [...entries, SnapshotEntry(roomId, uid)],
      time: now,
    );
  }

  AccountFollowSnapshot removed(String roomId, String uid, DateTime now) {
    var room = normalizeFollowRoomId(siteId, roomId);
    return AccountFollowSnapshot(
      siteId: siteId,
      owner: owner,
      entries: entries
          .where(
            (e) => !((room.isNotEmpty &&
                    normalizeFollowRoomId(siteId, e.roomId) == room) ||
                (uid.isNotEmpty && e.uid == uid)),
          )
          .toList(),
      time: now,
    );
  }

  Map<String, dynamic> toJson() => {
        "siteId": siteId,
        "owner": owner,
        "entries": entries.map((e) => e.toJson()).toList(),
        "time": time.millisecondsSinceEpoch,
      };

  factory AccountFollowSnapshot.fromJson(Map json) => AccountFollowSnapshot(
        siteId: json["siteId"]?.toString() ?? "",
        owner: json["owner"]?.toString() ?? "",
        entries: (json["entries"] is List ? json["entries"] as List : const [])
            .whereType<Map>()
            .map(SnapshotEntry.fromJson)
            .toList(),
        time: DateTime.fromMillisecondsSinceEpoch(
          (json["time"] as num?)?.toInt() ?? 0,
        ),
      );
}

/// 用户在 App 里取消过的关注
///
/// 手动同步时据此判断“App 里取关了”：没有这条记录时（例如 WebDAV 恢复后少了几个），
/// 不会建议在账号上取关。[localOnly] 为 true 表示用户选了“仅在 App 里取消”，
/// 同步时不再建议任何操作。
class AccountFollowTombstone {
  final String siteId;
  final String roomId;
  final String accountUid;
  final bool localOnly;
  final DateTime time;

  const AccountFollowTombstone({
    required this.siteId,
    required this.roomId,
    required this.accountUid,
    required this.localOnly,
    required this.time,
  });

  String get followId => "${siteId}_$roomId";

  bool matches(AccountFollowItem item) =>
      normalizeFollowRoomId(siteId, item.roomId) ==
          normalizeFollowRoomId(siteId, roomId) ||
      (accountUid.isNotEmpty && item.accountUid == accountUid);

  Map<String, dynamic> toJson() => {
        "siteId": siteId,
        "roomId": roomId,
        "accountUid": accountUid,
        "localOnly": localOnly,
        "time": time.millisecondsSinceEpoch,
      };

  factory AccountFollowTombstone.fromJson(Map json) => AccountFollowTombstone(
        siteId: json["siteId"]?.toString() ?? "",
        roomId: json["roomId"]?.toString() ?? "",
        accountUid: json["accountUid"]?.toString() ?? "",
        localOnly: json["localOnly"] == true,
        time: DateTime.fromMillisecondsSinceEpoch(
          (json["time"] as num?)?.toInt() ?? 0,
        ),
      );
}

/// 平台队列暂停的原因
enum FollowPauseKind {
  /// 平台风控或频率限制
  risk,

  /// 登录失效或缺少权限，等用户处理
  auth,

  /// 连续同步了一批，休息一会
  batch,

  /// 今天的条数用完了
  daily,
}

/// 各平台回写队列的状态
class AccountFollowSiteState {
  final String siteId;
  FollowPauseKind? pauseKind;

  /// 暂停到什么时候；为空且 [pauseKind] 不为空时一直暂停，直到用户点“继续”
  DateTime? pausedUntil;
  String message;
  DateTime? lastWriteAt;

  /// 当天（yyyy-MM-dd）已经回写的条数
  String dayKey;
  int dayCount;

  /// 用户在这一天点了“继续”，不再受每天条数的限制
  String dailyOverride;

  AccountFollowSiteState({
    required this.siteId,
    this.pauseKind,
    this.pausedUntil,
    this.message = "",
    this.lastWriteAt,
    this.dayKey = "",
    this.dayCount = 0,
    this.dailyOverride = "",
  });

  bool isPaused(DateTime now) =>
      pauseKind != null && (pausedUntil == null || now.isBefore(pausedUntil!));

  void clearPause() {
    pauseKind = null;
    pausedUntil = null;
    message = "";
  }

  Map<String, dynamic> toJson() => {
        "siteId": siteId,
        "pauseKind": pauseKind?.name,
        "pausedUntil": pausedUntil?.millisecondsSinceEpoch,
        "message": message,
        "lastWriteAt": lastWriteAt?.millisecondsSinceEpoch,
        "dayKey": dayKey,
        "dayCount": dayCount,
        "dailyOverride": dailyOverride,
      };

  factory AccountFollowSiteState.fromJson(Map json) {
    DateTime? time(dynamic value) => value is num
        ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
        : null;
    var kind = json["pauseKind"];
    return AccountFollowSiteState(
      siteId: json["siteId"]?.toString() ?? "",
      pauseKind: kind == null
          ? null
          : FollowPauseKind.values.firstWhere(
              (e) => e.name == kind,
              orElse: () => FollowPauseKind.risk,
            ),
      pausedUntil: time(json["pausedUntil"]),
      message: json["message"]?.toString() ?? "",
      lastWriteAt: time(json["lastWriteAt"]),
      dayKey: json["dayKey"]?.toString() ?? "",
      dayCount: (json["dayCount"] as num?)?.toInt() ?? 0,
      dailyOverride: json["dailyOverride"]?.toString() ?? "",
    );
  }
}

/// 日期键（本地时间 yyyy-MM-dd）
String followDayKey(DateTime time) =>
    "${time.year.toString().padLeft(4, "0")}-${time.month.toString().padLeft(2, "0")}-${time.day.toString().padLeft(2, "0")}";
