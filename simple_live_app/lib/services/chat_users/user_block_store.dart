import 'package:simple_live_app/services/chat_users/chat_user.dart';

/// 屏蔽的范围和时长
enum UserBlockKind {
  /// 永久
  permanent,

  /// 到 [UserBlock.expireAt] 自动解除
  timed,

  /// 本次进入：离开直播间就解除，只在内存里
  visit,
}

/// 一条屏蔽记录：平台、用户 ID（有的话）、名字、范围（全平台或一个直播间）、到期时间
class UserBlock {
  UserBlock({
    required this.siteId,
    this.userId,
    this.midHash,
    required this.name,
    this.roomId,
    this.roomLabel = "",
    this.expireAt,
    this.visit = false,
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  final String siteId;

  /// 用户 ID；哔哩哔哩只有 crc32 的记录为空，直播间里认出来后补上
  String? userId;

  /// 哔哩哔哩有的记录只有 uid 的 crc32，见 [ChatUser.midHash]
  String? midHash;

  /// 最近一次用的名字（改名后跟着变）
  String name;

  /// 只在这个直播间（同一平台的房间号）；为空时是整个平台
  final String? roomId;

  /// 直播间的名字（主播名或标题），名单里显示用
  final String roomLabel;

  /// 到期时间（毫秒）；永久和本次进入为空
  final int? expireAt;

  /// 本次进入（只在内存里）
  final bool visit;

  final int createdAt;

  UserBlockKind get kind => visit
      ? UserBlockKind.visit
      : expireAt == null
          ? UserBlockKind.permanent
          : UserBlockKind.timed;

  bool get permanent => kind == UserBlockKind.permanent;

  ChatUser get user =>
      ChatUser(siteId, userId: userId, name: name, midHash: midHash);

  bool activeAt(int now) => expireAt == null || expireAt! > now;

  /// 是不是在屏蔽 [other]：只按用户 ID（或 crc32）认人，见 [sameChatUserId]
  bool blocks(ChatUser other) => sameChatUserId(user, other);

  /// 在 [roomId] 这个直播间里生效（整个平台的也算）
  bool coversRoom(String? room) => roomId == null || roomId == room;

  Map<String, dynamic> toJson() => {
        "s": siteId,
        if (userId != null) "i": userId,
        if (midHash != null) "h": midHash,
        "n": name,
        if (roomId != null) "r": roomId,
        if (roomLabel.isNotEmpty) "rl": roomLabel,
        if (expireAt != null) "e": expireAt,
        "c": createdAt,
      };

  static UserBlock? fromJson(dynamic json) {
    if (json is! Map) {
      return null;
    }
    var siteId = json["s"]?.toString() ?? "";
    var userId = json["i"]?.toString();
    var hash = json["h"]?.toString();
    var name = json["n"]?.toString() ?? "";
    // 只按 ID 屏蔽：没有用户 ID 也没有 crc32 的记录不要
    if (siteId.isEmpty ||
        ((userId?.isEmpty ?? true) && (hash?.isEmpty ?? true))) {
      return null;
    }
    return UserBlock(
      siteId: siteId,
      userId: (userId?.isEmpty ?? true) ? null : userId,
      midHash: (hash?.isEmpty ?? true) ? null : hash,
      name: name,
      roomId: json["r"]?.toString(),
      roomLabel: json["rl"]?.toString() ?? "",
      expireAt: json["e"] is num ? (json["e"] as num).toInt() : null,
      createdAt: json["c"] is num ? (json["c"] as num).toInt() : null,
    );
  }

  /// 同一个人、同一个范围（换一种时长时替换掉原来的）
  bool sameTarget(UserBlock other) =>
      siteId == other.siteId &&
      roomId == other.roomId &&
      visit == other.visit &&
      sameChatUserId(user, other.user);
}

/// 一组屏蔽记录：按 ID、crc32 建索引，每条消息进来时查一下，不随记录变多而变慢。
/// 只按 ID 认人，不按名字（见 [sameChatUserId]）。
///
/// 存在本机的（永久、定时）和直播间里“本次进入”的各用一个。
/// 改动后调用 [onChanged]（[persistent] 为 true 表示永久的那部分变了，要同步）
class UserBlockStore {
  UserBlockStore({this.onChanged, int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final void Function({required bool persistent})? onChanged;
  final int Function() _clock;

  final List<UserBlock> _items = [];
  final Map<String, List<UserBlock>> _byId = {};

  /// 哔哩哔哩的记录按 uid 的 crc32
  final Map<String, List<UserBlock>> _byHash = {};

  /// 只有 crc32 的记录，直播弹幕带 uid 时算一下再查
  final Map<String, List<UserBlock>> _hashOnly = {};

  int get now => _clock();

  /// 全部记录（含已到期还没清掉的）
  List<UserBlock> get items => List.unmodifiable(_items);

  bool get isEmpty => _items.isEmpty;

  /// 换成另一组记录（读本机存档、恢复备份）
  void load(Iterable<UserBlock> items) {
    _items
      ..clear()
      ..addAll(items);
    _reindex();
  }

  /// 存档用的 JSON（不含本次进入的；[permanentOnly] 只要永久的，同步用）
  List<Map<String, dynamic>> toJson({bool permanentOnly = false}) => [
        for (var e in _items)
          if (!e.visit && (!permanentOnly || e.permanent)) e.toJson(),
      ];

  /// 屏蔽：同一个人、同一个范围原来的记录换成这一条。返回被换掉的（撤销时放回）。
  /// 没有用户 ID 也没有 crc32 的不屏蔽（返回空表）
  List<UserBlock> add(UserBlock block) {
    if (!block.user.hasId) {
      return const [];
    }
    var replaced = _items.where(block.sameTarget).toList();
    _items.removeWhere(replaced.contains);
    _items.add(block);
    _reindex();
    _notify([block, ...replaced]);
    return replaced;
  }

  void remove(Iterable<UserBlock> blocks) {
    var list = blocks.toList();
    var before = _items.length;
    _items.removeWhere(list.contains);
    if (_items.length == before) {
      return;
    }
    _reindex();
    _notify(list);
  }

  /// 放回撤销的：去掉 [added]，放回 [replaced]
  void undo(UserBlock added, List<UserBlock> replaced) {
    _items.remove(added);
    _items.addAll(replaced.where((e) => !_items.contains(e)));
    _reindex();
    _notify([added, ...replaced]);
  }

  /// 解除全部临时的（定时和本次进入），永久的留着
  void removeTemporary() => remove(_items.where((e) => !e.permanent).toList());

  void clear() => remove(List.of(_items));

  /// 去掉已到期的，有变化时返回 true
  bool purgeExpired() {
    var t = now;
    var expired = _items.where((e) => !e.activeAt(t)).toList();
    if (expired.isEmpty) {
      return false;
    }
    remove(expired);
    return true;
  }

  /// 在 [roomId] 里屏蔽着 [user] 的记录（没有到期的）
  List<UserBlock> matches(ChatUser user, {String? roomId}) {
    if (_items.isEmpty || !user.hasId) {
      return const [];
    }
    var t = now;
    var seen = <UserBlock>{};
    var out = <UserBlock>[];
    void check(List<UserBlock>? list) {
      if (list == null) {
        return;
      }
      for (var e in list) {
        if (seen.add(e) &&
            e.activeAt(t) &&
            e.coversRoom(roomId) &&
            e.blocks(user)) {
          out.add(e);
        }
      }
    }

    if (user.userId != null) {
      check(_byId[_key(user.siteId, user.userId!)]);
    }
    if (user.midHash != null) {
      check(_byHash[_key(user.siteId, user.midHash!)]);
    } else if (_hashOnly.isNotEmpty && user.userId != null) {
      var hash = user.hashKey;
      if (hash != null) {
        check(_hashOnly[_key(user.siteId, hash)]);
      }
    }
    return out;
  }

  /// 最“重”的一条：永久的优先，其次剩得最久的；没有时为 null
  UserBlock? strongest(ChatUser user, {String? roomId}) =>
      strongestOf(matches(user, roomId: roomId));

  static UserBlock? strongestOf(Iterable<UserBlock> list) {
    UserBlock? best;
    int rank(UserBlock e) => switch (e.kind) {
          UserBlockKind.permanent => 1 << 62,
          UserBlockKind.visit => 1 << 61,
          UserBlockKind.timed => e.expireAt!,
        };
    for (var e in list) {
      if (best == null || rank(e) > rank(best)) {
        best = e;
      }
    }
    return best;
  }

  /// 在 [roomId] 里生效的全部记录（本直播间名单用）
  List<UserBlock> effectiveIn(String siteId, String? roomId) {
    var t = now;
    return [
      for (var e in _items)
        if (e.siteId == siteId && e.activeAt(t) && e.coversRoom(roomId)) e,
    ];
  }

  /// 收到 [user] 的消息：屏蔽的人跟着改名，只有 crc32 的补上 ID。有变化时返回 true
  bool observe(ChatUser user) {
    if (_items.isEmpty) {
      return false;
    }
    var changed = false;
    var persistent = false;
    if (user.userId != null) {
      for (var e
          in _byId[_key(user.siteId, user.userId!)] ?? const <UserBlock>[]) {
        if (user.name.isNotEmpty && e.name != user.name) {
          e.name = user.name;
          changed = true;
          persistent = persistent || e.permanent;
        }
      }
      if (_hashOnly.isNotEmpty) {
        var hash = user.hashKey;
        var list = hash == null ? null : _hashOnly[_key(user.siteId, hash)];
        for (var e in list ?? const <UserBlock>[]) {
          if (e.userId == null) {
            // 只有 crc32 的记录，在直播间里认出来了
            e.userId = user.userId;
            e.midHash = null;
            if (user.name.isNotEmpty) {
              e.name = user.name;
            }
            changed = true;
            persistent = persistent || e.permanent;
          }
        }
      }
    }
    if (changed) {
      _reindex();
      onChanged?.call(persistent: persistent);
    }
    return changed;
  }

  void _notify(List<UserBlock> touched) =>
      onChanged?.call(persistent: touched.any((e) => e.permanent));

  static String _key(String siteId, String value) => "$siteId|$value";

  void _reindex() {
    _byId.clear();
    _byHash.clear();
    _hashOnly.clear();
    for (var e in _items) {
      if (e.userId != null) {
        _byId.putIfAbsent(_key(e.siteId, e.userId!), () => []).add(e);
      }
      var hash = e.user.hashKey;
      if (hash != null) {
        _byHash.putIfAbsent(_key(e.siteId, hash), () => []).add(e);
      }
      if (e.midHash != null && e.userId == null) {
        _hashOnly.putIfAbsent(_key(e.siteId, e.midHash!), () => []).add(e);
      }
    }
  }
}
