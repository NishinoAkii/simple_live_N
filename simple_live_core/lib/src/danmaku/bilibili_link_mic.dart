import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';

/// 哔哩哔哩直播间的连麦状态。
///
/// 弹幕里的几种消息各管一块，这里合成完整的一份 [LiveLinkMicState]：
/// - 多人连线：UNIVERSAL_EVENT_GIFT_V2（旧版 UNIVERSAL_EVENT_GIFT 放在
///   data.info 里），business_label 为 universal_multi_conn，
///   data.members 每次都是完整名单，本房主播的 display_name 是“本房主播”
/// - PK：PK_BATTLE_PRE(_NEW) 的 data 是对手 {uname, face, uid, room_id}，
///   PK_BATTLE_END、PK_BATTLE_SETTLE(_V2/_NEW) 结束
/// - 视频连线：VIDEO_CONNECTION_JOIN_START 的 invited_*，
///   VIDEO_CONNECTION_START 的 {uid, uname, face, room_id}，
///   VIDEO_CONNECTION_JOIN_END 结束
/// - 语音连麦：VOICE_JOIN_STATUS（status 1 连上、0 断开），
///   VOICE_JOIN_LIST / VOICE_JOIN_ROOM_COUNT_INFO 的 apply_count 是排队人数，
///   VOICE_JOIN_SWITCH 关闭时清空
/// - 多人语音：MULTI_VOICE_APPLICATION_USER 的 count 是排队人数，
///   MULTI_VOICE_PK_STATUS 的 positions 是麦上的人
///
/// 字段名有的没有核实过，取不到的就当没有，格式不对的消息不改变状态
class BiliLinkMic {
  /// 本直播间的房间号（真实房间号），名单里是这个房间的就是本房主播
  String roomId;

  BiliLinkMic({this.roomId = ""});

  /// 处理的消息（cmd 去掉“:”后面的部分）
  static const Set<String> commands = {
    "UNIVERSAL_EVENT_GIFT",
    "UNIVERSAL_EVENT_GIFT_V2",
    "PK_BATTLE_PRE",
    "PK_BATTLE_PRE_NEW",
    "PK_BATTLE_START",
    "PK_BATTLE_START_NEW",
    "PK_BATTLE_END",
    "PK_BATTLE_SETTLE",
    "PK_BATTLE_SETTLE_V2",
    "PK_BATTLE_SETTLE_NEW",
    "VIDEO_CONNECTION_JOIN_START",
    "VIDEO_CONNECTION_START",
    "VIDEO_CONNECTION_JOIN_END",
    "VOICE_JOIN_STATUS",
    "VOICE_JOIN_LIST",
    "VOICE_JOIN_ROOM_COUNT_INFO",
    "VOICE_JOIN_SWITCH",
    "MULTI_VOICE_APPLICATION_USER",
    "MULTI_VOICE_PK_STATUS",
  };

  /// cmd 去掉“:”后面的部分（有的 cmd 带后缀，如“DANMU_MSG:4:0:2:2:2:0”）
  static String command(dynamic cmd) =>
      (cmd?.toString() ?? "").split(":").first.trim();

  static bool handles(dynamic cmd) => commands.contains(command(cmd));

  LiveLinkMicUser? _pk;
  String _pkId = "";
  List<LiveLinkMicUser> _multi = const [];
  LiveLinkMicUser? _video;

  /// 语音连麦的人，键是 uid（没有时是名字）
  final Map<String, LiveLinkMicUser> _voice = {};
  List<LiveLinkMicUser> _multiVoice = const [];
  int _voiceQueue = 0;
  int _multiVoiceQueue = 0;

  /// 本房主播的 uid（从多人连线的名单里认出来的），没有时为空
  String _ownUid = "";

  LiveLinkMicState _last = LiveLinkMicState.none;

  /// 最近一次发出的状态
  LiveLinkMicState get state => _last;

  /// 换房间或断开时清空（不发消息）
  void reset({String? roomId}) {
    if (roomId != null) {
      this.roomId = roomId;
    }
    _pk = null;
    _pkId = "";
    _multi = const [];
    _video = null;
    _voice.clear();
    _multiVoice = const [];
    _voiceQueue = 0;
    _multiVoiceQueue = 0;
    _ownUid = "";
    _last = LiveLinkMicState.none;
  }

  /// 处理一条消息（已经 json 解码），状态有变化时返回新的完整状态，
  /// 没变化或不是连麦消息时返回 null；不会抛出异常
  LiveLinkMicState? handle(dynamic obj) {
    try {
      if (obj is! Map) {
        return null;
      }
      var cmd = command(obj["cmd"]);
      if (!commands.contains(cmd)) {
        return null;
      }
      var data = _map(obj["data"]);
      switch (cmd) {
        case "UNIVERSAL_EVENT_GIFT":
        case "UNIVERSAL_EVENT_GIFT_V2":
          _multiConn(obj, data);
          break;
        case "PK_BATTLE_PRE":
        case "PK_BATTLE_PRE_NEW":
        case "PK_BATTLE_START":
        case "PK_BATTLE_START_NEW":
          _pkStart(obj, data);
          break;
        case "PK_BATTLE_END":
        case "PK_BATTLE_SETTLE":
        case "PK_BATTLE_SETTLE_V2":
        case "PK_BATTLE_SETTLE_NEW":
          var id = _pkIdOf(obj, data);
          if (id.isEmpty || _pkId.isEmpty || id == _pkId) {
            _pk = null;
            _pkId = "";
          }
          break;
        case "VIDEO_CONNECTION_JOIN_START":
          var user = _user(
            data,
            names: const ["invited_uname", "uname"],
            faces: const ["invited_face", "face"],
            uids: const ["invited_uid", "uid"],
            rooms: const ["invited_room_id", "room_id"],
          );
          if (user != null) {
            _video = user;
          }
          break;
        case "VIDEO_CONNECTION_START":
          var user = _user(data);
          if (user != null) {
            _video = user;
          }
          break;
        case "VIDEO_CONNECTION_JOIN_END":
          _video = null;
          break;
        case "VOICE_JOIN_STATUS":
          _voiceStatus(data);
          break;
        case "VOICE_JOIN_LIST":
        case "VOICE_JOIN_ROOM_COUNT_INFO":
          var count = _toInt(data?["apply_count"]);
          if (count != null && count >= 0) {
            _voiceQueue = count;
          }
          break;
        case "VOICE_JOIN_SWITCH":
          if (_switchedOff(data)) {
            _voice.clear();
            _voiceQueue = 0;
          }
          break;
        case "MULTI_VOICE_APPLICATION_USER":
          var count = _toInt(
            _first(data, const ["count", "apply_count", "total", "num"]),
          );
          if (count != null && count >= 0) {
            _multiVoiceQueue = count;
          }
          break;
        case "MULTI_VOICE_PK_STATUS":
          _multiVoicePositions(data);
          break;
      }
      return _emit(_compose());
    } catch (e) {
      CoreLog.error(e);
      return null;
    }
  }

  /// 多人连线：名单每次都是完整的
  void _multiConn(Map obj, Map? data) {
    if (data == null) {
      return;
    }
    var info = _map(data["info"]);
    var label = _text(data["business_label"]);
    if (label.isEmpty) {
      label = _text(info?["business_label"]);
    }
    if (label.isEmpty) {
      label = _text(obj["business_label"]);
    }
    if (label.isNotEmpty && label != "universal_multi_conn") {
      // 别的活动（不是连线）
      return;
    }
    var members = data["members"] ?? info?["members"];
    var ended = _ended(data["session_status"] ?? info?["session_status"]);
    if (members is! List) {
      if (label.isNotEmpty && ended) {
        _multi = const [];
      }
      return;
    }
    if (label.isEmpty &&
        !members.any((m) => m is Map && _id(_first(m, _roomKeys)).isNotEmpty)) {
      // 没有标签，名单也不像主播，认不出是不是连线
      return;
    }
    if (ended) {
      _multi = const [];
      return;
    }
    var users = <LiveLinkMicUser>[];
    for (var m in members) {
      if (m is! Map) {
        continue;
      }
      var uid = _id(_first(m, _uidKeys));
      var room = _id(_first(m, _roomKeys));
      var display = _text(m["display_name"]);
      if (display == "本房主播" ||
          _isTrue(m["is_self"]) ||
          (room.isNotEmpty && room == roomId)) {
        if (uid.isNotEmpty) {
          _ownUid = uid;
        }
        continue;
      }
      if (uid.isNotEmpty && uid == _ownUid) {
        continue;
      }
      var name = _text(_first(m, _nameKeys));
      if (name.isEmpty) {
        name = display;
      }
      if (name.isEmpty) {
        continue;
      }
      users.add(
        LiveLinkMicUser(
          name: name,
          face: liveEmoteUrl(_first(m, _faceKeys)),
          roomId: room,
        ),
      );
    }
    _multi = users;
  }

  void _pkStart(Map obj, Map? data) {
    var id = _pkIdOf(obj, data);
    var user = _user(data);
    if (user != null) {
      _pk = user;
      _pkId = id;
    } else if (_pk != null && _pkId.isEmpty) {
      // PK_BATTLE_START_NEW 不带对手，只补上 pk_id
      _pkId = id;
    }
  }

  void _voiceStatus(Map? data) {
    if (data == null) {
      return;
    }
    var status = _toInt(data["status"]);
    var uid = _id(data["uid"]);
    var name = _text(_first(data, const ["user_name", "uname", "name"]));
    if (status == 1) {
      if (name.isEmpty || (uid.isNotEmpty && uid == _ownUid)) {
        return;
      }
      _voice[uid.isEmpty ? "name:$name" : uid] = LiveLinkMicUser(
        name: name,
        face: liveEmoteUrl(_first(data, const ["head_pic", "face", "avatar"])),
      );
    } else if (status != null) {
      if (uid.isNotEmpty) {
        _voice.remove(uid);
      } else if (name.isNotEmpty) {
        _voice.remove("name:$name");
      } else {
        _voice.clear();
      }
    }
  }

  void _multiVoicePositions(Map? data) {
    var positions = _first(data, const ["positions", "position_list", "list"]);
    if (positions is! List) {
      return;
    }
    var users = <LiveLinkMicUser>[];
    for (var p in positions) {
      if (p is! Map) {
        continue;
      }
      var uid = _id(_first(p, _uidKeys));
      var room = _id(_first(p, _roomKeys));
      var role = _text(p["role"]).toLowerCase();
      if (_isTrue(p["is_anchor"]) ||
          role == "anchor" ||
          role == "host" ||
          (room.isNotEmpty && room == roomId) ||
          (uid.isNotEmpty && uid == _ownUid)) {
        continue;
      }
      var name = _text(
        _first(p, const ["nickname", "uname", "name", "user_name"]),
      );
      if (name.isEmpty) {
        // 空位
        continue;
      }
      users.add(
        LiveLinkMicUser(
          name: name,
          face: liveEmoteUrl(_first(p, const ["avatar", "face", "head_pic"])),
          roomId: room,
        ),
      );
    }
    _multiVoice = users;
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

    if (_pk != null) {
      add(_pk!);
    }
    _multi.forEach(add);
    if (_video != null) {
      add(_video!);
    }
    _voice.values.forEach(add);
    _multiVoice.forEach(add);
    // 两种排队可能说的是同一批人，取大的
    var queue = _voiceQueue > _multiVoiceQueue ? _voiceQueue : _multiVoiceQueue;
    String kind;
    if (_pk != null) {
      kind = "PK";
    } else if (_multi.isNotEmpty) {
      kind = "多人连线";
    } else if (_video != null) {
      kind = "视频连线";
    } else if (linked.isNotEmpty || queue > 0) {
      kind = "语音连麦";
    } else {
      // 结束了：保留刚才的方式，后面再来“没人连麦”的消息不会重复发
      kind = _last.kind;
    }
    return LiveLinkMicState(
      kind: kind,
      linked: List.unmodifiable(linked),
      queueCount: queue,
    );
  }

  LiveLinkMicState? _emit(LiveLinkMicState state) {
    if (state == _last) {
      return null;
    }
    _last = state;
    return state;
  }

  /// 另一位主播（或观众），名字为空或是本直播间时为 null
  LiveLinkMicUser? _user(
    Map? data, {
    List<String> names = _nameKeys,
    List<String> faces = _faceKeys,
    List<String> uids = _uidKeys,
    List<String> rooms = _roomKeys,
  }) {
    if (data == null) {
      return null;
    }
    var name = _text(_first(data, names));
    var room = _id(_first(data, rooms));
    var uid = _id(_first(data, uids));
    if (name.isEmpty ||
        (room.isNotEmpty && room == roomId) ||
        (uid.isNotEmpty && uid == _ownUid)) {
      return null;
    }
    return LiveLinkMicUser(
      name: name,
      face: liveEmoteUrl(_first(data, faces)),
      roomId: room,
    );
  }

  static const List<String> _nameKeys = [
    "uname",
    "name",
    "user_name",
    "nickname",
    "anchor_name",
  ];
  static const List<String> _faceKeys = ["face", "avatar", "head_pic", "uface"];
  static const List<String> _uidKeys = ["uid", "mid", "anchor_uid"];
  static const List<String> _roomKeys = ["room_id", "roomid", "anchor_room_id"];

  static String _pkIdOf(Map obj, Map? data) {
    var id = _id(obj["pk_id"]);
    if (id.isEmpty) {
      id = _id(data?["pk_id"]);
    }
    return id;
  }

  /// 多人连线结束的标记：0、false 或“end”之类的字样（没核实过取值）
  static bool _ended(dynamic value) {
    if (value is bool) {
      return !value;
    }
    if (value is num) {
      return value == 0;
    }
    if (value is String) {
      return const {
        "0",
        "false",
        "end",
        "ended",
        "finish",
        "finished",
        "close",
        "closed",
        "stop",
        "stopped",
        "over",
      }.contains(value.trim().toLowerCase());
    }
    return false;
  }

  /// VOICE_JOIN_SWITCH：开关类的字段有一个是 0（关）就算关闭
  static bool _switchedOff(Map? data) {
    if (data == null) {
      return false;
    }
    for (var key in const [
      "room_status",
      "root_status",
      "status",
      "switch",
      "open",
      "is_open",
    ]) {
      if (!data.containsKey(key)) {
        continue;
      }
      var value = data[key];
      if (value == false ||
          _toInt(value) == 0 ||
          const {
            "off",
            "close",
            "closed",
          }.contains(_text(value).toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  /// 对象，或对象的 json 字符串，别的都是 null
  static Map? _map(dynamic value) {
    if (value is Map) {
      return value;
    }
    if (value is String && value.trimLeft().startsWith("{")) {
      try {
        var decoded = json.decode(value);
        return decoded is Map ? decoded : null;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// [map] 里按 [keys] 顺序第一个不为空的值（空字符串不算）
  static dynamic _first(Map? map, List<String> keys) {
    if (map == null) {
      return null;
    }
    for (var key in keys) {
      var value = map[key];
      if (value == null || (value is String && value.trim().isEmpty)) {
        continue;
      }
      return value;
    }
    return null;
  }

  /// 字符串或数字的文字，别的（null、数组、对象）都是空字符串
  static String _text(dynamic value) =>
      value is String || value is num ? value.toString().trim() : "";

  /// uid、房间号：0 也当作没有
  static String _id(dynamic value) {
    var text = _text(value);
    if (value is num) {
      text = value.toInt().toString();
    }
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

  static bool _isTrue(dynamic value) =>
      value == true || _toInt(value) == 1 || _text(value) == "true";
}
