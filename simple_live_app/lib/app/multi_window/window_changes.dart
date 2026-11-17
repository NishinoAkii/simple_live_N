import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/account_follow/account_follow_models.dart';
import 'package:simple_live_app/services/chat_users/user_block_store.dart';
import 'package:simple_live_app/services/chat_users/user_remark_store.dart';

/// 副窗口交给主窗口保存的改动。只收这里列出的几种，内容逐项检查，
/// 不对就抛 [FormatException]（主窗口回 400）。
///
/// 关注和取关、开播提醒、观看记录、屏蔽和备注、记住的清晰度
sealed class WindowChange {
  const WindowChange();

  String get op;
  Map<String, dynamic> get data;

  static const ops = {
    FollowAdded.opName,
    FollowRemoved.opName,
    FollowNotifyChanged.opName,
    HistoryPut.opName,
    HistoryRemoved.opName,
    HistoryCleared.opName,
    ChatUsersChanged.opName,
    QualityRemembered.opName,
  };

  static WindowChange decode(String op, Object? data) {
    if (data is! Map) {
      throw const FormatException("data");
    }
    return switch (op) {
      FollowAdded.opName => FollowAdded(
          _follow(data["user"]),
          _origin(data["origin"]),
        ),
      FollowRemoved.opName => FollowRemoved(
          _follow(data["user"]),
          _origin(data["origin"]),
          localOnly: _bool(data["localOnly"]),
        ),
      FollowNotifyChanged.opName => FollowNotifyChanged(
          _id(data["id"]),
          _bool(data["notify"]),
        ),
      HistoryPut.opName => HistoryPut(_history(data["history"])),
      HistoryRemoved.opName => HistoryRemoved(_ids(data["ids"])),
      HistoryCleared.opName => HistoryCleared(
          live: _bool(data["live"]),
        ),
      ChatUsersChanged.opName => _chatUsers(data),
      QualityRemembered.opName => QualityRemembered(
          siteId: _id(data["siteId"]),
          name: _text(data["name"], 256),
          index: _int(data["index"], 0, 99),
          cellular: _bool(data["cellular"]),
        ),
      _ => throw FormatException("op $op"),
    };
  }

  // ---------------- 检查 ----------------

  static String _text(Object? value, int max, {bool allowEmpty = false}) {
    if (value is! String ||
        value.length > max ||
        (!allowEmpty && value.isEmpty)) {
      throw const FormatException("text");
    }
    return value;
  }

  static String _id(Object? value) => _text(value, 512);

  static bool _bool(Object? value) {
    if (value is! bool) {
      throw const FormatException("bool");
    }
    return value;
  }

  static int _int(Object? value, int min, int max) {
    if (value is! int || value < min || value > max) {
      throw const FormatException("int");
    }
    return value;
  }

  static Map _map(Object? value) {
    if (value is! Map) {
      throw const FormatException("map");
    }
    return value;
  }

  static List _list(Object? value, int max) {
    if (value is! List || value.length > max) {
      throw const FormatException("list");
    }
    return value;
  }

  static List<String> _ids(Object? value) =>
      [for (var e in _list(value, 1000)) _id(e)];

  /// 关注和观看记录共用的几项（旧版存的 id 不一定是“平台_房间号”，不强求）
  static void _room(Map json) {
    _id(json["id"]);
    _text(json["siteId"], 256);
    _text(json["roomId"], 256);
    _text(json["userName"], 512, allowEmpty: true);
    _text(json["face"], 2048, allowEmpty: true);
  }

  static FollowUser _follow(Object? value) {
    var json = _map(value);
    _room(json);
    if (json["tag"] != null) {
      _text(json["tag"], 256);
    }
    if (json["notify"] != null) {
      _bool(json["notify"]);
    }
    try {
      return FollowUser.fromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      throw const FormatException("follow");
    }
  }

  static FollowChangeOrigin _origin(Object? value) {
    for (var e in FollowChangeOrigin.values) {
      if (e.name == value) {
        return e;
      }
    }
    throw const FormatException("origin");
  }

  static History _history(Object? value) {
    var json = _map(value);
    _room(json);
    for (var key in ["cover", "title", "area"]) {
      if (json[key] != null) {
        _text(json[key], 2048, allowEmpty: true);
      }
    }
    try {
      return History.fromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      throw const FormatException("history");
    }
  }

  static ChatUsersChanged _chatUsers(Map data) {
    var key = data["key"];
    if (key != ChatUsersChanged.blocks && key != ChatUsersChanged.remarks) {
      throw const FormatException("key");
    }
    List<Map<String, dynamic>> items(Object? value) {
      var list = _list(value, 5000);
      var result = <Map<String, dynamic>>[];
      for (var e in list) {
        var ok = key == ChatUsersChanged.blocks
            ? UserBlock.fromJson(e) != null
            : UserRemark.fromJson(e) != null;
        if (!ok) {
          throw const FormatException("item");
        }
        result.add(Map<String, dynamic>.from(e as Map));
      }
      return result;
    }

    return ChatUsersChanged(
      key as String,
      add: items(data["add"]),
      remove: items(data["remove"]),
    );
  }
}

class FollowAdded extends WindowChange {
  static const opName = "follow.add";
  final FollowUser user;
  final FollowChangeOrigin origin;
  const FollowAdded(this.user, this.origin);

  @override
  String get op => opName;

  @override
  Map<String, dynamic> get data =>
      {"user": user.toJson(), "origin": origin.name};
}

class FollowRemoved extends WindowChange {
  static const opName = "follow.remove";
  final FollowUser user;
  final FollowChangeOrigin origin;
  final bool localOnly;
  const FollowRemoved(this.user, this.origin, {this.localOnly = false});

  @override
  String get op => opName;

  @override
  Map<String, dynamic> get data =>
      {"user": user.toJson(), "origin": origin.name, "localOnly": localOnly};
}

/// 开播提醒的开关
class FollowNotifyChanged extends WindowChange {
  static const opName = "follow.notify";
  final String id;
  final bool notify;
  const FollowNotifyChanged(this.id, this.notify);

  @override
  String get op => opName;

  @override
  Map<String, dynamic> get data => {"id": id, "notify": notify};
}

class HistoryPut extends WindowChange {
  static const opName = "history.put";
  final History history;
  const HistoryPut(this.history);

  @override
  String get op => opName;

  @override
  Map<String, dynamic> get data => {"history": history.toJson()};
}

class HistoryRemoved extends WindowChange {
  static const opName = "history.remove";
  final List<String> ids;
  const HistoryRemoved(this.ids);

  @override
  String get op => opName;

  @override
  Map<String, dynamic> get data => {"ids": ids};
}

/// 清空观看记录：[live] 直播的
class HistoryCleared extends WindowChange {
  static const opName = "history.clear";
  final bool live;
  const HistoryCleared({required this.live});

  @override
  String get op => opName;

  @override
  Map<String, dynamic> get data => {"live": live};
}

/// 屏蔽或备注变了：去掉 [remove]、加上 [add]（都是存档里的写法）
class ChatUsersChanged extends WindowChange {
  static const opName = "chatUsers.change";
  static const blocks = "blocks";
  static const remarks = "remarks";

  final String key;
  final List<Map<String, dynamic>> add;
  final List<Map<String, dynamic>> remove;
  const ChatUsersChanged(this.key,
      {this.add = const [], this.remove = const []});

  @override
  String get op => opName;

  @override
  Map<String, dynamic> get data => {"key": key, "add": add, "remove": remove};
}

/// 手动切换时记下的清晰度（「记住上次」用）
class QualityRemembered extends WindowChange {
  static const opName = "quality.remember";
  final String siteId;
  final String name;
  final int index;
  final bool cellular;
  const QualityRemembered({
    required this.siteId,
    required this.name,
    required this.index,
    required this.cellular,
  });

  @override
  String get op => opName;

  @override
  Map<String, dynamic> get data =>
      {"siteId": siteId, "name": name, "index": index, "cellular": cellular};
}
