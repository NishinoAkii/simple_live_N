import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';

import 'douyu_gifts.dart';

/// 斗鱼直播间的连麦（主播 PK）状态，合成完整的一份 [LiveLinkMicState]：
/// - mapkb：多人 PK。cmd 1 开始、3 进行中、4 出结果、5/6 结束；
///   members 是 STT 编码的名单 {rid, uid, nickname 或 nick, icon, team}，
///   rid 是本房间的是本房主播
/// - nlkstatus / nlkdoing：1v1 连麦 PK {pkId, status, rida, ridb,
///   ridainfo, ridbinfo（nn, avt）}，status 1、2 进行中，3 结束；
///   rid 不是本房间的那一边是对手
///
/// 字段名有的没有核实过，取不到的就当没有，格式不对的消息不改变状态
class DouyuLinkMic {
  /// 本直播间的房间号（真实房间号）
  String roomId;

  DouyuLinkMic({this.roomId = ""});

  /// 处理的消息类型：mapkb 和 nlk 开头的（连麦 PK）
  static bool handles(String? type) =>
      type != null && (type == "mapkb" || type.startsWith("nlk"));

  List<LiveLinkMicUser> _multi = const [];
  LiveLinkMicUser? _partner;
  String _partnerId = "";

  LiveLinkMicState _last = LiveLinkMicState.none;

  /// 最近一次发出的状态
  LiveLinkMicState get state => _last;

  /// 换房间或断开时清空（不发消息）
  void reset({String? roomId}) {
    if (roomId != null) {
      this.roomId = roomId;
    }
    _multi = const [];
    _partner = null;
    _partnerId = "";
    _last = LiveLinkMicState.none;
  }

  /// 处理一条已经解码的 STT 消息，状态有变化时返回新的完整状态，
  /// 没变化或不是连麦消息时返回 null；不会抛出异常。
  /// [stt] 用来解码还是 STT 字符串的嵌套字段
  LiveLinkMicState? handle(dynamic msg, {dynamic Function(String)? stt}) {
    try {
      if (msg is! Map) {
        return null;
      }
      var type = msg["type"]?.toString();
      if (!handles(type)) {
        return null;
      }
      if (type == "mapkb") {
        _mapkb(msg, stt);
      } else {
        _nlk(type!, msg, stt);
      }
      return _emit(_compose());
    } catch (e) {
      CoreLog.error(e);
      return null;
    }
  }

  void _mapkb(Map msg, dynamic Function(String)? stt) {
    var cmd = _toInt(msg["cmd"]);
    if (cmd == 5 || cmd == 6) {
      _multi = const [];
      return;
    }
    if (!msg.containsKey("members")) {
      // 只有分数之类，名单不变
      return;
    }
    var users = <LiveLinkMicUser>[];
    for (var m in _maps(msg["members"], stt)) {
      var rid = _id(m["rid"]);
      if (rid.isNotEmpty && rid == roomId) {
        continue;
      }
      var name = _text(_first(m, const ["nickname", "nick", "nn", "name"]));
      if (name.isEmpty) {
        continue;
      }
      users.add(
        LiveLinkMicUser(
          name: name,
          face: douyuAvatarUrl(
            _text(_first(m, const ["icon", "avatar", "avt", "ic"])),
          ),
          roomId: rid,
        ),
      );
    }
    _multi = users;
  }

  void _nlk(String type, Map msg, dynamic Function(String)? stt) {
    var id = _id(_first(msg, const ["pkId", "pkid", "pk_id"]));
    var sameId = id.isEmpty || _partnerId.isEmpty || id == _partnerId;
    var lower = type.toLowerCase();
    if (const [
      "end",
      "finish",
      "over",
      "stop",
      "close",
    ].any((e) => lower.contains(e))) {
      if (sameId) {
        _partner = null;
        _partnerId = "";
      }
      return;
    }
    if (type != "nlkstatus" && type != "nlkdoing") {
      return;
    }
    var status = _toInt(_first(msg, const ["status", "st"]));
    if (status != null && status != 1 && status != 2) {
      // 3 是结束；别的（0 之类）也当作没有连上
      if (sameId) {
        _partner = null;
        _partnerId = "";
      }
      return;
    }
    var partner = _nlkPartner(msg, stt);
    if (partner != null) {
      _partner = partner;
      if (id.isNotEmpty) {
        _partnerId = id;
      }
    }
  }

  /// rida、ridb 里不是本房间的一边
  LiveLinkMicUser? _nlkPartner(Map msg, dynamic Function(String)? stt) {
    if (roomId.isEmpty) {
      return null;
    }
    var a = _id(msg["rida"]);
    var b = _id(msg["ridb"]);
    String side;
    if (a == roomId && b.isNotEmpty && b != roomId) {
      side = "b";
    } else if (b == roomId && a.isNotEmpty && a != roomId) {
      side = "a";
    } else {
      // 认不出哪边是本房间
      return null;
    }
    var rid = side == "a" ? a : b;
    var infos = _maps(msg["rid${side}info"], stt);
    var info = infos.isEmpty ? const {} : infos.first;
    var name = _text(_first(info, const ["nn", "nickname", "nick", "name"]));
    if (name.isEmpty) {
      // nlkdoing 可能只带分数，对手没变时沿用之前的
      if (_partner != null && _partner!.roomId == rid) {
        return _partner;
      }
      name = "直播间 {rid}".tf({"rid": rid});
    }
    return LiveLinkMicUser(
      name: name,
      face: douyuAvatarUrl(
        _text(_first(info, const ["avt", "icon", "avatar", "ic"])),
      ),
      roomId: rid,
    );
  }

  LiveLinkMicState _compose() {
    var linked = <LiveLinkMicUser>[];
    var seen = <String>{};
    void add(LiveLinkMicUser user) {
      var key = user.roomId.isNotEmpty ? "room:${user.roomId}" : user.name;
      if (seen.add(key)) {
        linked.add(user);
      }
    }

    _multi.forEach(add);
    if (_partner != null) {
      add(_partner!);
    }
    return LiveLinkMicState(
      // 结束了：保留刚才的方式，后面再来“没人连麦”的消息不会重复发
      kind: linked.isEmpty ? _last.kind : "PK",
      linked: List.unmodifiable(linked),
    );
  }

  LiveLinkMicState? _emit(LiveLinkMicState state) {
    if (state == _last) {
      return null;
    }
    _last = state;
    return state;
  }

  /// 名单里的每个人：可能已经是对象或数组，也可能还是 STT 字符串或 json
  static List<Map> _maps(
    dynamic value,
    dynamic Function(String)? stt, [
    int depth = 0,
  ]) {
    if (depth > 4 || value == null) {
      return const [];
    }
    if (value is Map) {
      return [value];
    }
    if (value is List) {
      return [for (var e in value) ..._maps(e, stt, depth + 1)];
    }
    if (value is String) {
      var text = value.trim();
      if (text.startsWith("{") || text.startsWith("[")) {
        try {
          return _maps(json.decode(text), stt, depth + 1);
        } catch (_) {
          return const [];
        }
      }
      if (stt != null && text.contains("@")) {
        return _maps(stt(text), stt, depth + 1);
      }
    }
    return const [];
  }

  /// [map] 里按 [keys] 顺序第一个不为空的值（空字符串不算）
  static dynamic _first(Map map, List<String> keys) {
    for (var key in keys) {
      var value = map[key];
      if (value == null || (value is String && value.trim().isEmpty)) {
        continue;
      }
      return value;
    }
    return null;
  }

  /// 文字；值里有“//”（如完整的图片地址）时 STT 解码会切成数组，拼回去
  static String _text(dynamic value) {
    if (value is String || value is num) {
      return value.toString().trim();
    }
    if (value is List && value.isNotEmpty && value.every((e) => e is String)) {
      return value.join("//").trim();
    }
    return "";
  }

  /// uid、房间号：0 也当作没有
  static String _id(dynamic value) {
    var text = value is num ? value.toInt().toString() : _text(value);
    return text == "0" ? "" : text;
  }

  static int? _toInt(dynamic value) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }
}
