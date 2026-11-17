import 'package:simple_live_app/services/chat_users/chat_user.dart';

/// 给一个人写的备注。按平台存，只按用户 ID 认人（和屏蔽一样，见 [sameChatUserId]），改名后备注还在
class UserRemark {
  UserRemark({
    required this.siteId,
    this.userId,
    this.midHash,
    required this.name,
    required this.remark,
    int? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  final String siteId;
  String? userId;
  String? midHash;

  /// 最近一次用的名字
  String name;
  final String remark;
  final int updatedAt;

  ChatUser get user =>
      ChatUser(siteId, userId: userId, name: name, midHash: midHash);

  Map<String, dynamic> toJson() => {
        "s": siteId,
        if (userId != null) "i": userId,
        if (midHash != null) "h": midHash,
        "n": name,
        "r": remark,
        "t": updatedAt,
      };

  static UserRemark? fromJson(dynamic json) {
    if (json is! Map) {
      return null;
    }
    var siteId = json["s"]?.toString() ?? "";
    var userId = json["i"]?.toString();
    var hash = json["h"]?.toString();
    var name = json["n"]?.toString() ?? "";
    var remark = json["r"]?.toString().trim() ?? "";
    // 只按 ID 认人：没有用户 ID 也没有 crc32 的不要
    if (siteId.isEmpty ||
        remark.isEmpty ||
        ((userId?.isEmpty ?? true) && (hash?.isEmpty ?? true))) {
      return null;
    }
    return UserRemark(
      siteId: siteId,
      userId: (userId?.isEmpty ?? true) ? null : userId,
      midHash: (hash?.isEmpty ?? true) ? null : hash,
      name: name,
      remark: remark,
      updatedAt: json["t"] is num ? (json["t"] as num).toInt() : null,
    );
  }
}

/// 全部备注，按 ID、crc32 建索引（聊天区每一行都要查）。不按名字认人，免得同名的人显示别人的备注
class UserRemarkStore {
  UserRemarkStore({this.onChanged});

  final void Function()? onChanged;

  /// 备注最长多少个字
  static const int maxLength = 30;

  final List<UserRemark> _items = [];
  final Map<String, List<UserRemark>> _byId = {};
  final Map<String, List<UserRemark>> _byHash = {};

  /// 有只知道 crc32 的备注
  bool _hasHashOnly = false;

  List<UserRemark> get items => List.unmodifiable(_items);

  bool get isEmpty => _items.isEmpty;

  void load(Iterable<UserRemark> items) {
    _items
      ..clear()
      ..addAll(items);
    _reindex();
  }

  List<Map<String, dynamic>> toJson() => [for (var e in _items) e.toJson()];

  UserRemark? find(ChatUser user) {
    if (_items.isEmpty || !user.hasId) {
      return null;
    }
    UserRemark? pick(List<UserRemark>? list) {
      for (var e in list ?? const <UserRemark>[]) {
        if (sameChatUserId(e.user, user)) {
          return e;
        }
      }
      return null;
    }

    if (user.userId != null) {
      var hit = pick(_byId[_key(user.siteId, user.userId!)]);
      if (hit != null) {
        return hit;
      }
    }
    // 哔哩哔哩：只有 crc32 的备注，直播弹幕的 uid 算成 crc32 再查
    var hash = user.hashKey;
    if (hash != null) {
      return pick(_byHash[_key(user.siteId, hash)]);
    }
    return null;
  }

  String? remarkOf(ChatUser user) => find(user)?.remark;

  /// 写备注；[remark] 为空时删掉。同一个人原来的备注换成新的。没有用户 ID 的不写
  void set(ChatUser user, String remark) {
    if (!user.hasId) {
      return;
    }
    var text = remark.trim();
    if (text.length > maxLength) {
      text = text.substring(0, maxLength);
    }
    var old = _items.where((e) => sameChatUserId(e.user, user)).toList();
    _items.removeWhere(old.contains);
    if (text.isNotEmpty) {
      _items.add(
        UserRemark(
          siteId: user.siteId,
          userId: user.userId,
          midHash: user.userId == null ? user.midHash : null,
          name: user.name.isNotEmpty
              ? user.name
              : (old.isEmpty ? "" : old.first.name),
          remark: text,
        ),
      );
    }
    if (old.isEmpty && text.isEmpty) {
      return;
    }
    _reindex();
    onChanged?.call();
  }

  /// 合并另一份（手动恢复备份、局域网同步）：同一个人以新写的为准
  void merge(Iterable<UserRemark> incoming) {
    var changed = false;
    for (var e in incoming) {
      if (!e.user.hasId) {
        continue;
      }
      var same = _items.where((x) => sameChatUserId(x.user, e.user)).toList();
      if (same.any((x) => x.updatedAt >= e.updatedAt)) {
        continue;
      }
      _items.removeWhere(same.contains);
      _items.add(e);
      changed = true;
    }
    if (changed) {
      _reindex();
      onChanged?.call();
    }
  }

  /// 收到 [user] 的消息：有 ID 的跟着改名，只有 crc32 的补上 ID
  bool observe(ChatUser user) {
    if (_items.isEmpty || user.userId == null) {
      return false;
    }
    var changed = false;
    for (var e
        in _byId[_key(user.siteId, user.userId!)] ?? const <UserRemark>[]) {
      if (user.name.isNotEmpty && e.name != user.name) {
        e.name = user.name;
        changed = true;
      }
    }
    var hash = _hasHashOnly ? user.hashKey : null;
    for (var e in hash == null
        ? const <UserRemark>[]
        : _byHash[_key(user.siteId, hash)] ?? const <UserRemark>[]) {
      if (e.userId == null) {
        e.userId = user.userId;
        e.midHash = null;
        if (user.name.isNotEmpty) {
          e.name = user.name;
        }
        changed = true;
      }
    }
    if (changed) {
      _reindex();
      onChanged?.call();
    }
    return changed;
  }

  static String _key(String siteId, String value) => "$siteId|$value";

  void _reindex() {
    _byId.clear();
    _byHash.clear();
    _hasHashOnly = false;
    for (var e in _items) {
      if (e.midHash != null && e.userId == null) {
        _hasHashOnly = true;
      }
      if (e.userId != null) {
        _byId.putIfAbsent(_key(e.siteId, e.userId!), () => []).add(e);
      }
      var hash = e.user.hashKey;
      if (hash != null) {
        _byHash.putIfAbsent(_key(e.siteId, hash), () => []).add(e);
      }
    }
  }
}
