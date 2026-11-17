import 'package:simple_live_app/modules/search/text/search_text.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 综合搜索的一项：直播间、主播，或同一房间号的两者合在一起
class SearchEntry {
  final String roomId;

  /// 在播的直播间（有标题、封面）
  final LiveRoomItem? room;

  /// 主播（可能没开播）
  final LiveAnchorItem? anchor;

  /// 结果来源的说明，如“按拼音匹配”，普通结果为 null
  final String? tag;

  SearchEntry({
    required this.roomId,
    this.room,
    this.anchor,
    this.tag,
  });

  String get userName => anchor?.userName ?? room?.userName ?? "";

  String get avatar => anchor?.avatar ?? "";

  /// 直播中（有直播间卡片的都是在播的）
  bool get live => room != null || (anchor?.liveStatus ?? false);

  /// 轮播
  bool get isRecord => !live && (anchor?.isRecord ?? false);

  SearchEntry withTag(String? tag) =>
      SearchEntry(roomId: roomId, room: room, anchor: anchor, tag: tag);

  /// 名字（或房间号、login）和关键词一样
  bool isExact(SearchKey query) {
    if (query.isEmpty) return false;
    var name = SearchKey(userName);
    if (name.compact == query.compact) return true;
    if (query.isLatin) {
      if (name.hasHan && name.pinyin == query.compact) return true;
      if (roomId.toLowerCase() == query.compact) return true;
    }
    // Twitch 的“显示名(login)”
    var m = RegExp(r"^(.+)\(([^()]+)\)$").firstMatch(userName);
    if (m != null) {
      return SearchKey(m.group(1)!).compact == query.compact ||
          SearchKey(m.group(2)!).compact == query.compact;
    }
    return false;
  }
}

/// 把一页的直播间和主播合在一起：按房间号去重（同一个房间的主播信息并进直播间），
/// 排序：名字完全相同的（在播的在前）> 在播的直播间 > 在播但没有直播间卡片的主播 > 未开播、轮播的主播；
/// 同一档里保持平台给的顺序。[exclude] 里的房间号（前几页、直达卡片已经有的）跳过。
List<SearchEntry> mergeSearchEntries({
  required String keyword,
  required List<LiveRoomItem> rooms,
  required List<LiveAnchorItem> anchors,
  Set<String> exclude = const {},
  String? tag,
}) {
  var query = SearchKey(keyword);
  var anchorById = <String, LiveAnchorItem>{};
  for (var a in anchors) {
    if (a.roomId.isNotEmpty) {
      anchorById.putIfAbsent(a.roomId, () => a);
    }
  }
  var seen = <String>{...exclude};
  var entries = <SearchEntry>[];
  for (var r in rooms) {
    if (r.roomId.isEmpty || !seen.add(r.roomId)) continue;
    entries.add(SearchEntry(
      roomId: r.roomId,
      room: r,
      anchor: anchorById[r.roomId],
      tag: tag,
    ));
  }
  for (var a in anchors) {
    if (a.roomId.isEmpty || !seen.add(a.roomId)) continue;
    entries.add(SearchEntry(roomId: a.roomId, anchor: a, tag: tag));
  }
  int rank(SearchEntry e) {
    if (e.isExact(query)) return e.live ? 0 : 1;
    if (e.room != null) return 2;
    if (e.live) return 3;
    return 4;
  }

  var ranks = [for (var e in entries) rank(e)];
  var order = List<int>.generate(entries.length, (i) => i)
    ..sort((a, b) {
      var d = ranks[a] - ranks[b];
      return d != 0 ? d : a - b;
    });
  return [for (var i in order) entries[i]];
}

/// 只有直播间或只有主播的结果也包成 [SearchEntry]（直达卡片去重等用）
String searchItemRoomId(Object item) {
  if (item is SearchEntry) return item.roomId;
  if (item is LiveRoomItem) return item.roomId;
  if (item is LiveAnchorItem) return item.roomId;
  return "";
}

/// “上次直播”的时间：刚刚、N 分钟前、N 小时前、N 天前，再早显示日期
String searchTimeAgo(DateTime time, [DateTime? now]) {
  now ??= DateTime.now();
  var d = now.difference(time);
  if (d.inMinutes < 1) return "刚刚".t;
  if (d.inHours < 1) return "{d} 分钟前".tf({"d": d.inMinutes});
  if (d.inDays < 1) return "{inHours} 小时前".tf({"inHours": d.inHours});
  if (d.inDays < 30) return "{inDays} 天前".tf({"inDays": d.inDays});
  String two(int v) => v.toString().padLeft(2, "0");
  var date = "${two(time.month)}-${two(time.day)}";
  return time.year == now.year ? date : "${time.year}-$date";
}

/// 主播卡片上的状态文字：直播中 / 轮播 / 未开播
String searchStatusText(bool live, bool isRecord) =>
    live ? "直播中".t : (isRecord ? "轮播".t : "未开播".t);

/// 未开播主播的“上次直播”说明，没有信息时为 null
String? searchLastLiveText(LiveAnchorItem anchor, [DateTime? now]) {
  if (anchor.liveStatus) return null;
  var time = anchor.lastLiveTime;
  var title = anchor.lastTitle?.trim() ?? "";
  if (time == null && title.isEmpty) return null;
  var parts = <String>[
    if (time != null) "上次直播 {searchTimeAgo}".tf({"searchTimeAgo": searchTimeAgo(time, now)}) else "上次直播".t,
    if (title.isNotEmpty) title,
  ];
  return parts.join("：".t);
}

/// 结果的名字和关键词接近（相同、前缀、包含，或全拼一样）
bool searchNearName(SearchKey query, SearchEntry entry) =>
    searchScore(query, SearchKey(entry.userName)) >= 50;

/// 结果少时的补救搜索用哪些词：第一页不到 3 条，或者没有名字接近关键词的结果时，
/// 中文关键词用全拼再搜一次（能补上同音错字），有繁体字时用简体再搜一次；
/// 每次最多两个（哔哩哔哩搜太多会 -412）。[serverHandlesTraditional] 为 true 的平台
/// （哔哩哔哩、虎牙自己会繁简互换）不用简体再搜
List<({String keyword, String tag})> searchRescueQueries(
  String keyword,
  List<SearchEntry> entries, {
  bool serverHandlesTraditional = false,
}) {
  var query = SearchKey(keyword);
  if (!query.hasHan) return [];
  var near = entries.any((e) => searchNearName(query, e));
  if (entries.length >= 3 && near) return [];
  var result = <({String keyword, String tag})>[];
  if (query.pinyin.length >= 2 && query.pinyin != keyword.trim()) {
    result.add((keyword: query.pinyin, tag: "按拼音匹配".t));
  }
  var simplified = SearchText.toSimplified(keyword.trim());
  if (!serverHandlesTraditional && simplified != keyword.trim()) {
    result.add((keyword: simplified, tag: "按简体匹配".t));
  }
  return result.take(2).toList();
}

/// 把补救搜到的结果并进去：名字完全相同的原结果在最前，补救结果里名字接近的放在它们后面，
/// 然后是其他原结果，最后是补救结果里的其他；已经有的房间号跳过
List<Object> mergeRescuedEntries(
  String keyword,
  List<Object> current,
  List<SearchEntry> rescued,
) {
  var query = SearchKey(keyword);
  var ids = current.map(searchItemRoomId).toSet();
  var fresh = rescued.where((e) => ids.add(e.roomId)).toList();
  if (fresh.isEmpty) return current;
  var exact = <Object>[];
  var rest = <Object>[];
  for (var item in current) {
    if (item is SearchEntry && item.isExact(query)) {
      exact.add(item);
    } else {
      rest.add(item);
    }
  }
  var near = fresh.where((e) => searchNearName(query, e)).toList();
  var other = fresh.where((e) => !searchNearName(query, e)).toList();
  return [...exact, ...near, ...rest, ...other];
}

/// “你是不是要找”：只指向主播。按优先顺序给主播名：[local] 是关注和看过的，
/// [others] 是平台的主播卡片和搜索结果里的。取第一个“字面上对不上，但全拼、首字母能对上”的
/// （打分 45～59，见 [searchScore]），如 lfq → 老番茄、老翻茄 → 老番茄；
/// 关注和看过的还认拼错一两个字母（打分 30，如 shrod → shroud），
/// 搜索结果里随便哪个名字差一两个字母不算（搜游戏名时会乱提示）。
/// 有名字和关键词完全一样的，说明已经找对了，不提示。
///
/// [serverCorrection] 是平台给的纠正词（哔哩哔哩 suggest_keyword、YouTube didYouMean），
/// 只有它正好是某个主播的名字时才用
String? searchDidYouMean(
  String keyword, {
  Iterable<String> local = const [],
  Iterable<String> others = const [],
  String? serverCorrection,
}) {
  var query = SearchKey(keyword);
  if (query.isEmpty) return null;
  var keys = <(SearchKey, int)>[];
  var seen = <String>{};
  for (var (names, minScore) in [(local, 30), (others, 45)]) {
    for (var name in names) {
      var key = SearchKey(name);
      if (key.isEmpty || !seen.add(key.compact)) continue;
      // 已经有名字完全一样的：用户找对了
      if (key.compact == query.compact) return null;
      keys.add((key, minScore));
    }
  }
  var server = SearchKey(serverCorrection ?? "");
  if (!server.isEmpty && server.compact != query.compact) {
    for (var (key, _) in keys) {
      if (key.compact == server.compact) return key.raw.trim();
    }
  }
  for (var (key, minScore) in keys) {
    var score = searchScore(query, key);
    if (score >= minScore && score < 60) return key.raw.trim();
  }
  return null;
}
