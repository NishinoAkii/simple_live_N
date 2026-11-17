// 脚本返回的 JSON 结构 → simple_live_core 的模型，见 doc/live_source_api.md §1

import 'dart:convert';

import 'package:simple_live_core/src/model/live_anchor_item.dart';
import 'package:simple_live_core/src/model/live_category.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_suggestion.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 脚本直播间的弹幕参数：保存 room() 返回的原始对象，原样传回 danmaku.start
class ScriptDanmakuArgs {
  final Map<String, dynamic> room;
  ScriptDanmakuArgs(this.room);

  /// 脚本给的 danmakuData
  dynamic get data => room["danmakuData"];

  @override
  String toString() => jsonEncode(room["danmakuData"]);
}

String scriptString(dynamic v) => v == null ? "" : v.toString();

int scriptInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.isFinite ? v.toInt() : 0;
  var s = v?.toString() ?? "";
  return int.tryParse(s) ?? double.tryParse(s)?.toInt() ?? 0;
}

bool scriptBool(dynamic v) => v == true || v == 1 || v == "true";

Map<String, dynamic> scriptMap(dynamic v, String what) {
  if (v is Map) return Map<String, dynamic>.from(v);
  throw FormatException("{what} 应该返回对象".tf({"what": what}));
}

List<dynamic> scriptList(dynamic v, String what) {
  if (v == null) return const [];
  if (v is List) return v;
  throw FormatException("{what} 应该返回数组".tf({"what": what}));
}

LiveRoomItem scriptRoomItem(dynamic v) {
  var m = scriptMap(v, "rooms 的每一项".t);
  return LiveRoomItem(
    roomId: scriptString(m["roomId"]),
    title: scriptString(m["title"]),
    cover: scriptString(m["cover"]),
    userName: scriptString(m["userName"]),
    online: scriptInt(m["online"]),
  );
}

List<LiveRoomItem> scriptRoomItems(dynamic v) => scriptList(
  v,
  "rooms",
).map(scriptRoomItem).where((e) => e.roomId.isNotEmpty).toList();

LiveAnchorItem scriptAnchorItem(dynamic v) {
  var m = scriptMap(v, "anchors 的每一项".t);
  var lastTitle = scriptString(m["lastTitle"]).trim();
  return LiveAnchorItem(
    roomId: scriptString(m["roomId"]),
    avatar: scriptString(m["avatar"]),
    userName: scriptString(m["userName"]),
    liveStatus: scriptBool(m["live"]),
    isRecord: scriptBool(m["isRecord"]),
    followers: m["followers"] == null ? null : scriptInt(m["followers"]),
    lastTitle: lastTitle.isEmpty ? null : lastTitle,
    lastLiveTime: scriptTime(m["lastLiveTime"]),
  );
}

/// 时间：毫秒或秒的时间戳（数字或数字文字），或 ISO 8601 文字；认不出时为 null
DateTime? scriptTime(dynamic v) {
  if (v == null) return null;
  var n = v is num ? v : num.tryParse(v.toString().trim());
  if (n != null) {
    if (n <= 0 || !n.isFinite) return null;
    // 小于 1e11 的当成秒
    var ms = n < 100000000000 ? n * 1000 : n;
    return DateTime.fromMillisecondsSinceEpoch(ms.toInt());
  }
  return DateTime.tryParse(v.toString().trim())?.toLocal();
}

/// suggest() 的结果：字符串数组，或 [{ text, roomId?, userName?, avatar?, live?, isRecord?, subtitle? }]；
/// 有 roomId 的是能直接打开的频道卡片
List<LiveSuggestion> scriptSuggestions(dynamic v) {
  var items = <LiveSuggestion>[];
  for (var e in scriptList(v, "suggest()")) {
    if (e is String || e is num) {
      var text = e.toString().trim();
      if (text.isNotEmpty) items.add(LiveSuggestion(text: text));
      continue;
    }
    var m = scriptMap(e, "suggest() 的每一项".t);
    var roomId = scriptString(m["roomId"]).trim();
    var userName = scriptString(m["userName"]).trim();
    var text = scriptString(m["text"]).trim();
    if (text.isEmpty) text = userName;
    if (text.isEmpty) continue;
    String? optional(String key) {
      var s = m[key]?.toString().trim() ?? "";
      return s.isEmpty ? null : s;
    }

    items.add(
      LiveSuggestion(
        text: text,
        type: roomId.isNotEmpty ? LiveSuggestion.kRoom : LiveSuggestion.kWord,
        roomId: roomId.isEmpty ? null : roomId,
        userName: userName.isEmpty ? (roomId.isEmpty ? null : text) : userName,
        avatar: optional("avatar"),
        liveStatus: m.containsKey("live") ? scriptBool(m["live"]) : null,
        isRecord: scriptBool(m["isRecord"]),
        subtitle: optional("subtitle"),
      ),
    );
  }
  return items;
}

List<LiveCategory> scriptCategories(dynamic v) {
  return scriptList(v, "categories()").map((e) {
    var m = scriptMap(e, "categories() 的每一项".t);
    var id = scriptString(m["id"]);
    return LiveCategory(
      id: id,
      name: scriptString(m["name"]),
      children: scriptList(m["children"], "children").map((c) {
        var child = scriptMap(c, "children 的每一项".t);
        var pic = child["pic"]?.toString();
        return LiveSubCategory(
          id: scriptString(child["id"]),
          name: scriptString(child["name"]),
          parentId: child["parentId"]?.toString() ?? id,
          pic: pic == null || pic.isEmpty ? null : pic,
        );
      }).toList(),
    );
  }).toList();
}

Map<String, dynamic> scriptCategoryArg(LiveSubCategory category) => {
  "id": category.id,
  "name": category.name,
  "parentId": category.parentId,
  "pic": category.pic,
};

LiveRoomDetail scriptRoomDetail(dynamic v, String requestedRoomId) {
  var m = scriptMap(v, "room()");
  var roomId = m["roomId"] == null
      ? requestedRoomId
      : scriptString(m["roomId"]);
  m["roomId"] = roomId;
  String? optional(String key) {
    var s = m[key]?.toString();
    return s == null || s.isEmpty ? null : s;
  }

  return LiveRoomDetail(
    roomId: roomId,
    title: scriptString(m["title"]),
    cover: scriptString(m["cover"]),
    userName: scriptString(m["userName"]),
    userAvatar: scriptString(m["userAvatar"]),
    online: scriptInt(m["online"]),
    introduction: optional("introduction"),
    notice: optional("notice"),
    status: scriptBool(m["live"]),
    data: m["data"],
    danmakuData: ScriptDanmakuArgs(m),
    url: scriptString(m["url"]),
    isRecord: scriptBool(m["isRecord"]),
    showTime: optional("showTime"),
  );
}

/// 把 LiveRoomDetail 还原成脚本的 RoomDetail（优先用 room() 返回的原始对象）。
/// 内置平台的直播间不要用它交给脚本，用 [scriptBuiltInRoomArg]（这里会带上 data、danmakuData）
Map<String, dynamic> scriptRoomArg(LiveRoomDetail detail) {
  var args = detail.danmakuData;
  if (args is ScriptDanmakuArgs) {
    return Map<String, dynamic>.from(args.room);
  }
  return {
    "roomId": detail.roomId,
    "title": detail.title,
    "cover": detail.cover,
    "userName": detail.userName,
    "userAvatar": detail.userAvatar,
    "online": detail.online,
    "live": detail.status,
    "introduction": detail.introduction,
    "notice": detail.notice,
    "url": detail.url,
    "data": _jsonSafe(detail.data),
    "danmakuData": _jsonSafe(detail.danmakuData),
  };
}

/// 内置平台的直播间交给修正脚本时的样子（§9）：只有显示用的公开字段，加上 builtIn: true。
/// 不给 data、danmakuData：里面可能有登录的 Cookie、uid（如哔哩哔哩的弹幕参数）
Map<String, dynamic> scriptBuiltInRoomArg(LiveRoomDetail detail) => {
  "roomId": detail.roomId,
  "title": detail.title,
  "cover": detail.cover,
  "userName": detail.userName,
  "userAvatar": detail.userAvatar,
  "online": detail.online,
  "live": detail.status,
  "introduction": detail.introduction,
  "notice": detail.notice,
  "url": detail.url,
  "isRecord": detail.isRecord,
  "showTime": detail.showTime,
  "builtIn": true,
};

dynamic _jsonSafe(dynamic v) {
  if (v == null || v is num || v is String || v is bool) return v;
  try {
    return jsonDecode(jsonEncode(v));
  } catch (_) {
    return v.toString();
  }
}

/// 能转成 JSON 的原样（深拷贝），不能的为 null
dynamic _jsonOrNull(dynamic v) {
  if (v == null || v is num || v is String || v is bool) return v;
  try {
    return jsonDecode(jsonEncode(v));
  } catch (_) {
    return null;
  }
}

List<LivePlayQuality> scriptQualities(dynamic v) {
  var list = scriptList(v, "qualities()");
  var result = <LivePlayQuality>[];
  for (var i = 0; i < list.length; i++) {
    var m = scriptMap(list[i], "qualities() 的每一项".t);
    result.add(
      LivePlayQuality(
        quality: scriptString(m["name"]),
        data: m["data"],
        sort: m["sort"] == null ? i : scriptInt(m["sort"]),
      ),
    );
  }
  return result;
}

Map<String, dynamic> scriptQualityArg(LivePlayQuality quality) {
  var data = quality.data;
  return {
    "name": quality.quality,
    "data": data is ScriptQualityData ? data.data : _jsonSafe(data),
    "sort": quality.sort,
  };
}

/// 内置平台的清晰度交给修正脚本时的样子（§9）：data 为内置代码的格式（能转成 JSON 时），builtIn: true
Map<String, dynamic> scriptBuiltInQualityArg(LivePlayQuality quality) => {
  "name": quality.quality,
  "data": _jsonOrNull(quality.data),
  "sort": quality.sort,
  "builtIn": true,
};

/// 修正脚本的 qualities() 给的清晰度：data 包一层，App 据此知道它只有脚本认识（不交给内置代码）
class ScriptQualityData {
  /// 脚本给的 data
  final dynamic data;

  /// 哪个源给的（"js:<key>"）
  final String source;

  const ScriptQualityData(this.data, this.source);

  @override
  String toString() => jsonEncode(_jsonSafe(data));
}

/// playUrls() 返回的 hlsFix（字符串或字符串数组），没有时为空列表
List<String> scriptHlsFixes(dynamic v) {
  if (v is! Map) return const [];
  var fix = v["hlsFix"];
  if (fix is String) fix = [fix];
  if (fix is! List) return const [];
  return fix
      .map((e) => e.toString().trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

/// 表情：{ text, url, staticUrl?, width?, height?, spaced?, cacheKey? }，text、url 必填（url 为 http(s)）
LiveEmote? scriptEmote(dynamic v) {
  if (v is! Map) return null;
  var text = scriptString(v["text"]);
  var url = scriptString(v["url"]).trim();
  if (text.isEmpty || !_httpUrl(url)) return null;
  var staticUrl = scriptString(v["staticUrl"]).trim();
  var cacheKey = scriptString(v["cacheKey"]).trim();
  return LiveEmote(
    text: text,
    url: url,
    staticUrl: _httpUrl(staticUrl) ? staticUrl : null,
    width: scriptInt(v["width"]).clamp(0, 4096),
    height: scriptInt(v["height"]).clamp(0, 4096),
    spaced: scriptBool(v["spaced"]),
    cacheKey: cacheKey.isEmpty ? null : cacheKey,
  );
}

/// 消息的 emotes 数组 → 只保留文字里出现的表情（最多 50 个），没有时为 null
List<LiveEmote>? scriptEmotes(dynamic v, String message) {
  if (v is! List || v.isEmpty) return null;
  var result = <LiveEmote>[];
  var seen = <String>{};
  for (var item in v) {
    var e = scriptEmote(item);
    if (e == null || !message.contains(e.text) || !seen.add(e.text)) continue;
    result.add(e);
    if (result.length >= 50) break;
  }
  return result.isEmpty ? null : result;
}

bool _httpUrl(String url) =>
    url.startsWith("https://") || url.startsWith("http://");

LivePlayUrl scriptPlayUrl(dynamic v, String what) {
  if (v is List) {
    return LivePlayUrl(
      urls: v.map(scriptString).where((e) => e.isNotEmpty).toList(),
    );
  }
  var m = scriptMap(v, what);
  var headers = <String, String>{};
  var h = m["headers"];
  if (h is Map) {
    h.forEach((k, value) {
      if (value != null) headers[k.toString()] = value.toString();
    });
  }
  return LivePlayUrl(
    urls: scriptList(
      m["urls"],
      "urls",
    ).map(scriptString).where((e) => e.isNotEmpty).toList(),
    headers: headers.isEmpty ? null : headers,
  );
}

LiveMessageColor scriptColor(dynamic v) {
  int? value;
  if (v is num) {
    value = v.toInt();
  } else if (v is String && v.isNotEmpty) {
    var s = v.startsWith("#") ? v.substring(1) : v;
    if (s.startsWith("0x") || s.startsWith("0X")) s = s.substring(2);
    value = int.tryParse(s, radix: 16);
  }
  if (value == null) return LiveMessageColor.white;
  return LiveMessageColor(
    (value >> 16) & 0xff,
    (value >> 8) & 0xff,
    value & 0xff,
  );
}

LiveSuperChatMessage scriptSuperChat(dynamic v) {
  var m = scriptMap(v, "醒目留言".t);
  var now = DateTime.now();
  DateTime time(dynamic t, DateTime fallback) {
    var ms = scriptInt(t);
    if (ms <= 0) return fallback;
    // 秒级时间戳也认
    if (ms < 100000000000) ms *= 1000;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  var start = time(m["startTime"], now);
  var priceText = m["priceText"]?.toString();
  return LiveSuperChatMessage(
    id: m["id"]?.toString(),
    userName: scriptString(m["user"]),
    face: scriptString(m["face"]),
    message: scriptString(m["text"]),
    price: scriptInt(m["price"]),
    priceText: priceText == null || priceText.isEmpty ? null : priceText,
    startTime: start,
    endTime: time(m["endTime"], start.add(const Duration(seconds: 60))),
    backgroundColor: m["backgroundColor"]?.toString() ?? "#EDF5FF",
    backgroundBottomColor: m["backgroundBottomColor"]?.toString() ?? "#2A60B2",
    userId: liveUserId(m["userId"]),
  );
}
