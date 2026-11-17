// 各平台搜索接口的解析（不联网，测试直接喂保存的响应）
//
// 这里只放纯函数，站点类负责请求。

import 'dart:convert';

import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/model/live_anchor_item.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_search_result.dart';
import 'package:simple_live_core/src/model/live_suggestion.dart';
import 'package:simple_live_core/src/common/core_text.dart';

int _int(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is bool) return v ? 1 : 0;
  return int.tryParse(v?.toString() ?? "") ?? 0;
}

String _str(dynamic v) => v == null ? "" : v.toString();

/// 接口有时返回 JSON 文本（没有 Content-Type 或 text/html），统一成对象
dynamic searchJson(dynamic v) {
  if (v is String) {
    var text = v.trim();
    if (text.isEmpty) return null;
    try {
      return json.decode(text);
    } catch (_) {
      return null;
    }
  }
  return v;
}

/// 去掉搜索结果里高亮关键词的标签（如 `<em class="keyword">`）
String stripSearchHighlight(String text) =>
    text.replaceAll(RegExp(r"</?em\b[^>]*>", caseSensitive: false), "");

// ---------------------------------------------------------------------------
// 哔哩哔哩
// ---------------------------------------------------------------------------

/// 第 [page] 页之后还有没有：[numPages] 为接口给的总页数
bool biliSearchHasMore(int page, dynamic numPages) => page < _int(numPages);

/// 接口出错时抛出（-412 是请求太频繁被拦了）
void checkBiliSearchResult(dynamic result) {
  if (result is! Map) {
    throw CoreError("哔哩哔哩搜索没有返回数据".t);
  }
  var code = _int(result["code"]);
  if (code == 0) return;
  if (code == -412) {
    throw CoreError("哔哩哔哩搜索太频繁，请稍后再试(-412)".t);
  }
  var msg = _str(result["message"]);
  throw CoreError(msg.isEmpty ? "哔哩哔哩搜索出错({code})".tf({"code": code}) : "$msg($code)");
}

String? _biliCorrection(dynamic data) {
  var s = stripSearchHighlight(_str(data?["suggest_keyword"])).trim();
  return s.isEmpty ? null : s;
}

/// B站时间文字（北京时间 yyyy-MM-dd HH:mm:ss），0000-00-00 等无效值返回 null
DateTime? _biliTime(dynamic v) {
  var s = _str(v).trim();
  if (s.isEmpty || s.startsWith("0000")) return null;
  var t = DateTime.tryParse("${s.replaceFirst(' ', 'T')}+08:00");
  return t;
}

String _biliImage(dynamic url, String size) {
  var s = _str(url);
  if (s.isEmpty) return "";
  if (s.startsWith("//")) s = "https:$s";
  return "$s@$size";
}

LiveRoomItem biliSearchRoom(Map item) {
  return LiveRoomItem(
    roomId: _str(item["roomid"]),
    title: stripSearchHighlight(_str(item["title"])),
    cover: _biliImage(item["cover"], "400w.jpg"),
    userName: stripSearchHighlight(_str(item["uname"])),
    online: _int(item["online"]),
  );
}

/// live_user 的一项：live_status 0 未开播 / 1 直播中 / 2 轮播
LiveAnchorItem biliSearchAnchor(Map item) {
  var status = _int(item["live_status"]);
  var live = item["is_live"] == true || status == 1;
  return LiveAnchorItem(
    roomId: _str(item["roomid"]),
    avatar: _biliImage(item["uface"], "400w.jpg"),
    userName: stripSearchHighlight(_str(item["uname"])),
    liveStatus: live,
    isRecord: !live && status == 2,
    followers: item["attentions"] == null ? null : _int(item["attentions"]),
    lastLiveTime: _biliTime(item["live_time"]),
  );
}

List<Map> _maps(dynamic v) =>
    (v is List) ? v.whereType<Map>().toList() : const <Map>[];

/// 按键一层层取值，中间不是对象时返回 null
dynamic _path(dynamic v, List<String> keys) {
  for (var k in keys) {
    if (v is! Map) return null;
    v = v[k];
  }
  return v;
}

/// search_type=live_room 或 live（取 live_room）的结果
///
/// live 的分页在 `data.pageinfo.live_room.numPages`；live_room 在 `data.numPages`。
LiveSearchRoomResult parseBiliRoomSearch(dynamic result, int page) {
  checkBiliSearchResult(result);
  var data = result["data"];
  var res = data?["result"];
  var list = (res is Map) ? res["live_room"] : res;
  var items = _maps(
    list,
  ).map(biliSearchRoom).where((e) => e.roomId.isNotEmpty).toList();
  var numPages = _path(data, ["pageinfo", "live_room", "numPages"]);
  if (numPages == null && res is List) {
    numPages = _path(data, ["numPages"]);
  }
  return LiveSearchRoomResult(
    hasMore: items.isNotEmpty && biliSearchHasMore(page, numPages),
    items: items,
    correction: _biliCorrection(data),
  );
}

/// search_type=live_user 的结果，包括未开播的主播，每页 30 个
LiveSearchAnchorResult parseBiliAnchorSearch(dynamic result, int page) {
  checkBiliSearchResult(result);
  var data = result["data"];
  var res = data?["result"];
  var list = (res is Map) ? res["live_user"] : res;
  var items = _maps(list)
      .map(biliSearchAnchor)
      .where((e) => e.roomId.isNotEmpty && e.roomId != "0")
      .toList();
  var numPages = (res is Map)
      ? _path(data, ["pageinfo", "live_user", "numPages"])
      : _path(data, ["numPages"]);
  return LiveSearchAnchorResult(
    hasMore: items.isNotEmpty && biliSearchHasMore(page, numPages),
    items: items,
    correction: _biliCorrection(data),
  );
}

/// search_type=live 一次就有在播的直播间（live_room）和主播（live_user，含未开播）
LiveSearchAllResult parseBiliLiveSearch(dynamic result, int page) {
  var rooms = parseBiliRoomSearch(result, page);
  var anchors = parseBiliAnchorSearch(result, page);
  return LiveSearchAllResult(
    rooms: rooms.items,
    anchors: anchors.items,
    hasMoreRooms: rooms.hasMore,
    hasMoreAnchors: anchors.hasMore,
    correction: rooms.correction,
  );
}

/// room/v1/Room/getRoomInfoOld?mid= 的结果：UID 对应的直播间号，没有直播间时为 null
String? parseBiliRoomIdByUid(dynamic result) {
  if (result is! Map || _int(result["code"]) != 0) return null;
  var id = _int(result["data"]?["roomid"]);
  return id > 0 ? id.toString() : null;
}

// ---------------------------------------------------------------------------
// 斗鱼
// ---------------------------------------------------------------------------

/// 斗鱼的直播状态，和网页一致：isLoop（或 videoLoop）为 1 是轮播，否则 isLive 为 1 是直播中
({bool live, bool record}) douyuLiveState(
  dynamic isLive,
  dynamic isLoop, [
  dynamic videoLoop,
]) {
  var loop = _int(isLoop) == 1 || _int(videoLoop) == 1;
  if (loop) return (live: false, record: true);
  return (live: _int(isLive) == 1, record: false);
}

/// searchUser 的一项（anchorInfo）；不是主播的项（视频 UP 主、鱼吧用户）没有 anchorInfo，返回 null
LiveAnchorItem? douyuSearchAnchor(dynamic item) {
  var info = (item is Map) ? item["anchorInfo"] : null;
  if (info is! Map) return null;
  var rid = _str(info["rid"]);
  if (rid.isEmpty || rid == "0") return null;
  var state = douyuLiveState(info["isLive"], info["isLoop"], info["videoLoop"]);
  var last = _int(info["lastShowTime"]);
  return LiveAnchorItem(
    roomId: rid,
    avatar: _str(info["avatar"]),
    userName: _str(info["nickName"]),
    liveStatus: state.live,
    isRecord: state.record,
    followers: info["fansNum"] == null ? null : _int(info["fansNum"]),
    lastLiveTime: last > 0
        ? DateTime.fromMillisecondsSinceEpoch(last * 1000)
        : null,
  );
}

/// searchUser 的结果；`data.total` 为总数
LiveSearchAnchorResult parseDouyuAnchorSearch(
  dynamic result,
  int page,
  int pageSize,
) {
  if (result is! Map) {
    throw CoreError("斗鱼搜索没有返回数据".t);
  }
  if (_int(result["error"]) != 0) {
    throw CoreError(
      _str(result["msg"]).isEmpty
          ? "斗鱼搜索出错({result})".tf({"result": result["error"]})
          : _str(result["msg"]),
    );
  }
  var data = result["data"];
  var list = (data is Map) ? data["relateUser"] : null;
  var raw = (list is List) ? list : const [];
  var items = raw.map(douyuSearchAnchor).whereType<LiveAnchorItem>().toList();
  var total = (data is Map) ? _int(data["total"]) : 0;
  var hasMore = total > 0 ? page * pageSize < total : raw.isNotEmpty;
  return LiveSearchAnchorResult(hasMore: hasMore, items: items);
}

// ---------------------------------------------------------------------------
// 抖音
// ---------------------------------------------------------------------------

/// 抖音“请先登录，再继续搜索吧”
const int kDouyinSearchNeedLogin = 2483;

/// 抖音搜索接口的错误：要登录时抛 [LoginRequiredError]，其他错误抛 [CoreError]
void checkDouyinSearchResult(dynamic result) {
  if (result == null || result == "" || result == "blocked") {
    throw CoreError("抖音直播搜索被限制，请稍后再试".t);
  }
  if (result is! Map) {
    throw CoreError("抖音搜索返回的数据格式不对".t);
  }
  var code = _int(result["status_code"]);
  if (code == kDouyinSearchNeedLogin) {
    throw LoginRequiredError("抖音要登录后才能搜索".t, siteId: "douyin");
  }
  if (code != 0 && result["data"] == null) {
    var msg = _str(result["status_msg"]);
    throw CoreError(msg.isEmpty ? "抖音搜索出错({code})".tf({"code": code}) : "$msg($code)");
  }
}

/// aweme/v1/web/live/search 的结果：`data[].lives.rawdata` 是 JSON 文本
List<LiveRoomItem> parseDouyinLiveSearch(dynamic result) {
  checkDouyinSearchResult(result);
  var items = <LiveRoomItem>[];
  for (var item in _maps(result["data"])) {
    var raw = item["lives"]?["rawdata"];
    var data = (raw is Map) ? raw : searchJson(_str(raw));
    if (data is! Map) continue;
    var owner = data["owner"];
    var webRid = _str(owner?["web_rid"]);
    if (webRid.isEmpty) continue;
    var covers = data["cover"]?["url_list"];
    items.add(
      LiveRoomItem(
        roomId: webRid,
        title: _str(data["title"]),
        cover: covers is List && covers.isNotEmpty ? _str(covers.first) : "",
        userName: _str(owner?["nickname"]),
        online: _int(data["stats"]?["total_user"]),
      ),
    );
  }
  return items;
}

// ---------------------------------------------------------------------------
// Twitch
// ---------------------------------------------------------------------------

/// searchFor 的 CHANNEL 结果：频道（含未开播）、下一页游标
({List<LiveAnchorItem> items, String? cursor}) parseTwitchSearchChannels(
  dynamic data,
  String Function(String displayName, String login) displayName,
) {
  var channels = _path(data, ["searchFor", "channels"]);
  var items = <LiveAnchorItem>[];
  for (var e in _maps(channels?["items"])) {
    var login = _str(e["login"]);
    if (login.isEmpty) continue;
    var last = e["lastBroadcast"];
    var title = _str(last?["title"]).trim();
    items.add(
      LiveAnchorItem(
        roomId: login,
        avatar: _str(e["profileImageURL"]),
        userName: displayName(_str(e["displayName"]), login),
        liveStatus: e["stream"] != null,
        followers: e["followers"]?["totalCount"] == null
            ? null
            : _int(e["followers"]["totalCount"]),
        lastTitle: title.isEmpty ? null : title,
        lastLiveTime: DateTime.tryParse(_str(last?["startedAt"]))?.toLocal(),
      ),
    );
  }
  var cursor = _str(channels?["cursor"]);
  return (items: items, cursor: cursor.isEmpty ? null : cursor);
}

// ---------------------------------------------------------------------------
// Kick（search.kick.com/api/v1）
// ---------------------------------------------------------------------------

String _kickThumb(dynamic thumbnail) {
  if (thumbnail is Map) {
    return _str(thumbnail["src"] ?? thumbnail["url"]);
  }
  return _str(thumbnail);
}

/// /search/enriched 的 livestreams：有直播标题、截图和观看人数，房间号为 channel.slug
List<LiveRoomItem> parseKickSearchLivestreams(dynamic result) {
  var data = (result is Map) ? result["data"] : null;
  var items = <LiveRoomItem>[];
  for (var e in _maps((data is Map) ? data["livestreams"] : null)) {
    var channel = e["channel"];
    var slug = _str((channel is Map) ? channel["slug"] : e["slug"]);
    if (slug.isEmpty) continue;
    var name = _str((channel is Map) ? channel["username"] : null);
    items.add(
      LiveRoomItem(
        roomId: slug,
        title: _str(e["title"]),
        cover: _kickThumb(e["thumbnail"]),
        userName: name.isEmpty ? slug : name,
        online: _int(e["viewer_count"]),
      ),
    );
  }
  return items;
}

/// /channels/search 的 `data`，或 /search、/search/enriched 的 `data.channels`
List<LiveAnchorItem> parseKickSearchChannels(dynamic result) {
  var data = (result is Map) ? result["data"] : null;
  var list = (data is Map) ? data["channels"] : data;
  var items = <LiveAnchorItem>[];
  for (var e in _maps(list)) {
    var slug = _str(e["slug"]);
    if (slug.isEmpty) continue;
    var name = _str(e["username"]);
    items.add(
      LiveAnchorItem(
        roomId: slug,
        avatar: _str(e["profile_picture"]),
        userName: name.isEmpty ? slug : name,
        liveStatus: e["is_live"] == true,
        followers: e["follower_count"] == null
            ? null
            : _int(e["follower_count"]),
      ),
    );
  }
  return items;
}

// ---------------------------------------------------------------------------
// 虎牙
// ---------------------------------------------------------------------------

LiveRoomItem huyaSearchRoom(Map item) {
  var cover = _str(item["game_screenshot"]);
  if (cover.isNotEmpty && !cover.contains("?")) {
    cover += "?x-oss-process=style/w338_h190&";
  }
  var title = _str(item["game_introduction"]);
  if (title.isEmpty) {
    title = _str(item["game_roomName"]);
  }
  return LiveRoomItem(
    roomId: _str(item["room_id"]),
    title: title,
    cover: cover,
    userName: _str(item["game_nick"]),
    online: _int(item["game_total_count"]),
  );
}

LiveAnchorItem huyaSearchAnchor(Map item) {
  return LiveAnchorItem(
    roomId: _str(item["room_id"]),
    avatar: _str(item["game_avatarUrl180"]),
    userName: _str(item["game_nick"]),
    liveStatus: item["gameLiveOn"] == true,
    followers: item["game_activityCount"] == null
        ? null
        : _int(item["game_activityCount"]),
  );
}

/// getSearchContent 的结果：不管 v=1 还是 v=4，`response["1"]` 都是主播（含未开播），
/// `response["3"]` 是在播的直播间，各自有 numFound
LiveSearchAllResult parseHuyaSearch(dynamic result, int page, int rows) {
  result = searchJson(result);
  var response = _path(result, ["response"]);
  if (response is! Map) {
    throw CoreError("虎牙搜索没有返回数据".t);
  }
  var anchors = _maps(_path(response, ["1", "docs"]))
      .map(huyaSearchAnchor)
      .where((e) => e.roomId.isNotEmpty && e.roomId != "0")
      .toList();
  var rooms = _maps(_path(response, ["3", "docs"]))
      .map(huyaSearchRoom)
      .where((e) => e.roomId.isNotEmpty && e.roomId != "0")
      .toList();
  return LiveSearchAllResult(
    rooms: rooms,
    anchors: anchors,
    hasMoreRooms: _int(_path(response, ["3", "numFound"])) > page * rows,
    hasMoreAnchors: _int(_path(response, ["1", "numFound"])) > page * rows,
  );
}

// ---------------------------------------------------------------------------
// 搜索联想（只要直播相关的：主播、直播间卡片）
//
// 各平台的通用联想词（哔哩哔哩 main/suggest、抖音 search/sug、YouTube suggestqueries、
// 虎牙 typ=-7）大多是视频、话题词，不用；没有直播专用联想的平台改用一次轻量的主播搜索。
// ---------------------------------------------------------------------------

/// 每个平台最多给几张主播卡片
const int kMaxSuggestions = 5;

/// 只留有房间号的卡片，同一个房间只留一次，最多 [limit] 张
List<LiveSuggestion> _distinctRooms(
  Iterable<LiveSuggestion> items, {
  int limit = kMaxSuggestions,
}) {
  var seen = <String>{};
  var result = <LiveSuggestion>[];
  for (var e in items) {
    if (!e.isRoom || e.text.trim().isEmpty) continue;
    if (!seen.add(e.roomId!)) continue;
    result.add(e);
    if (result.length >= limit) break;
  }
  return result;
}

/// 主播搜索的结果换成主播卡片（包括未开播的）；[knownStatus] 为 false 时
/// 平台没给在播状态（如 YouTube 的频道搜索），卡片不显示状态
List<LiveSuggestion> anchorSuggestions(
  List<LiveAnchorItem> anchors, {
  bool knownStatus = true,
  int limit = kMaxSuggestions,
}) {
  return _distinctRooms(
    anchors.map(
      (e) => LiveSuggestion(
        text: e.userName,
        type: LiveSuggestion.kRoom,
        roomId: e.roomId,
        userName: e.userName,
        avatar: e.avatar,
        liveStatus: knownStatus ? e.liveStatus : null,
        isRecord: knownStatus && e.isRecord,
      ),
    ),
    limit: limit,
  );
}

/// 斗鱼 getSearchRecV2：只用 roomResult（主播卡片，含未开播，isLive 2），分类、鱼吧用户等不要
List<LiveSuggestion> parseDouyuSuggestions(dynamic result) {
  result = searchJson(result);
  if (result is! Map || _int(result["error"]) != 0) return [];
  var items = <LiveSuggestion>[];
  for (var e in _maps(result["data"])) {
    var room = e["roomResult"];
    if (room is! Map || _str(room["rid"]).isEmpty) continue;
    var kw = _str(e["kw"]);
    var state = douyuLiveState(room["isLive"], room["isLoop"]);
    var name = _str(room["nickName"]);
    items.add(
      LiveSuggestion(
        text: name.isEmpty ? kw : name,
        type: LiveSuggestion.kRoom,
        roomId: _str(room["rid"]),
        userName: name.isEmpty ? kw : name,
        avatar: _str(room["avatar"]),
        liveStatus: state.live,
        isRecord: state.record,
        subtitle: _str(room["cateName"]).isEmpty
            ? null
            : _str(room["cateName"]),
      ),
    );
  }
  return _distinctRooms(items);
}

/// Twitch GQL searchSuggestions：只用频道卡片（含是否在播，包括未开播），分类和纯词不要
List<LiveSuggestion> parseTwitchSuggestions(
  dynamic data,
  String Function(String displayName, String login) displayName,
) {
  var edges = _path(data, ["searchSuggestions", "edges"]);
  var items = <LiveSuggestion>[];
  for (var edge in _maps(edges)) {
    var content = _path(edge, ["node", "content"]);
    if (content is! Map ||
        _str(content["__typename"]) != "SearchSuggestionChannel") {
      continue;
    }
    var login = _str(content["login"]);
    if (login.isEmpty) continue;
    var user = content["user"];
    var name = displayName(
      _str((user is Map) ? user["displayName"] : null),
      login,
    );
    items.add(
      LiveSuggestion(
        text: name,
        type: LiveSuggestion.kRoom,
        roomId: login,
        userName: name,
        avatar: _str(content["profileImageURL"]),
        liveStatus:
            content["isLive"] == true ||
            (user is Map && user["stream"] != null),
      ),
    );
  }
  return _distinctRooms(items);
}

/// Kick search.kick.com/api/v1/search：频道卡片（含未开播）和按标题匹配到的直播，分类不要
List<LiveSuggestion> parseKickSuggestions(dynamic result) {
  var data = _path(result, ["data"]);
  var items = <LiveSuggestion>[];
  for (var e in parseKickSearchChannels(result)) {
    items.add(
      LiveSuggestion(
        text: e.userName,
        type: LiveSuggestion.kRoom,
        roomId: e.roomId,
        userName: e.userName,
        avatar: e.avatar,
        liveStatus: e.liveStatus,
      ),
    );
  }
  for (var e in _maps(_path(data, ["livestreams"]))) {
    var slug = _str(e["slug"]);
    if (slug.isEmpty) continue;
    var title = _str(e["title"]).trim();
    items.add(
      LiveSuggestion(
        text: slug,
        type: LiveSuggestion.kRoom,
        roomId: slug,
        userName: slug,
        liveStatus: true,
        subtitle: title.isEmpty ? null : title,
      ),
    );
  }
  return _distinctRooms(items);
}

/// YouTube 搜索结果里的纠正词：showingResultsForRenderer（已显示 X 的结果）或
/// didYouMeanRenderer（你是不是要找：X），没有时返回 null
String? parseYouTubeCorrection(dynamic response) {
  for (var key in ["showingResultsForRenderer", "didYouMeanRenderer"]) {
    var renderer = _findFirst(response, key);
    if (renderer is! Map) continue;
    var query = _path(renderer, [
      "correctedQueryEndpoint",
      "searchEndpoint",
      "query",
    ]);
    var text = _str(query).trim();
    if (text.isEmpty) {
      var runs = _path(renderer, ["correctedQuery", "runs"]);
      text = _maps(runs).map((e) => _str(e["text"])).join().trim();
    }
    if (text.isNotEmpty) return text;
  }
  return null;
}

dynamic _findFirst(dynamic v, String key, [int depth = 0]) {
  if (depth > 40) return null;
  if (v is Map) {
    if (v.containsKey(key)) return v[key];
    for (var e in v.values) {
      var r = _findFirst(e, key, depth + 1);
      if (r != null) return r;
    }
  } else if (v is List) {
    for (var e in v) {
      var r = _findFirst(e, key, depth + 1);
      if (r != null) return r;
    }
  }
  return null;
}
