import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/src/account_follows/kick_account_follows.dart';
import 'package:simple_live_core/src/common/avplayer_url.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/hls_master.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/room_area.dart';
import 'package:simple_live_core/src/common/search_parser.dart';
import 'package:simple_live_core/src/common/kick_http.dart';
import 'package:simple_live_core/src/danmaku/kick_danmaku.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_rank_site.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_rank.dart';
import 'package:simple_live_core/src/rank_parsers.dart';
import 'package:simple_live_core/src/model/live_anchor_item.dart';
import 'package:simple_live_core/src/model/live_category.dart';
import 'package:simple_live_core/src/model/live_category_result.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_search_result.dart';
import 'package:simple_live_core/src/model/live_suggestion.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 频道接口（/api/v2/channels/{slug}）里主播的 user_id，没有时为 0。
/// 7TV 的 Kick 表情按它查，不是 channel id（xqc：id 668，user_id 676）
int kickChannelUserId(dynamic channel) {
  if (channel is! Map) {
    return 0;
  }
  var id =
      channel["user_id"] ??
      (channel["user"] is Map ? channel["user"]["id"] : null);
  return id is num ? id.toInt() : int.tryParse(id?.toString() ?? "") ?? 0;
}

/// Kick
///
/// 网页接口经由 [KickHttp] 请求（见其说明）；播放走 Amazon IVS 的 HLS。
class KickSite
    with
        KickAccountFollows
    implements LiveSite, LiveRankSite {
  @override
  String id = "kick";

  @override
  String name = "Kick";

  static const String kUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

  /// 登录后的会话令牌（网页 Cookie 中 session_token 解码后的值）
  @override
  String token = "";

  /// 搜索主播每页的数量；/channels/search 没有游标，第 n 页取前 n × 20 个再截掉前面几页
  static const int kSearchChannelPageSize = 20;
  static const int kSearchChannelMax = 100;

  /// 直播搜索各关键词已经给出的频道（第 2 页起只给新的）
  final Map<String, Set<String>> _searchSeen = {};

  /// 登录账号的用户名（App 登录、启动时设置），用于区分账号关注的快照
  @override
  String userName = "";

  @override
  LiveDanmaku getDanmaku() => KickDanmaku(site: this);

  @override
  List<LiveRankBoard> get rankBoards => kKickRankBoards;

  /// 送订阅榜：一次请求里有全部、本月、本周三份，取 [boardId] 那一份
  @override
  Future<LiveRankList> getRank(
    String boardId, {
    required LiveRoomDetail detail,
  }) async {
    if (!kKickRankBoards.any((e) => e.id == boardId)) {
      throw CoreError("不支持这个榜单".t);
    }
    var slug = detail.roomId.trim().toLowerCase();
    var result = await getJson("/api/v2/channels/$slug/leaderboards");
    return parseKickLeaderboard(result, boardId);
  }

  Future<dynamic> getJson(
    String path, [
    Map<String, String>? query,
    String host = "kick.com",
  ]) async {
    var url = Uri.https(host, path, query);
    var response = await KickHttp.send(
      "GET",
      url,
      headers: {
        "User-Agent": kUserAgent,
        "Accept": "application/json",
        "Accept-Language": "en-US,en;q=0.9",
        if (host != "kick.com") ...{
          "x-app-platform": "web",
          "Referer": "https://kick.com",
        },
      },
    );
    if (response.statusCode == 403 &&
        response.body.contains("blocked by security policy")) {
      throw CoreError("Kick 拒绝了当前网络请求(403)".t);
    }
    if (response.statusCode == 404) {
      throw CoreError("Kick 频道或页面不存在(404)".t);
    }
    if (response.statusCode != 200) {
      throw CoreError("", statusCode: response.statusCode);
    }
    return json.decode(response.body);
  }

  LiveRoomItem _roomItem(dynamic item) {
    var channel = item["channel"] ?? {};
    var user = channel["user"] ?? {};
    return LiveRoomItem(
      roomId: channel["slug"]?.toString() ?? "",
      title: item["session_title"]?.toString() ?? "",
      cover:
          item["thumbnail"]?["src"]?.toString() ??
          item["thumbnail"]?["url"]?.toString() ??
          "",
      userName: user["username"]?.toString() ?? channel["slug"].toString(),
      online:
          (item["viewer_count"] as num?)?.toInt() ??
          (item["viewers"] as num?)?.toInt() ??
          0,
    );
  }

  Future<LiveCategoryResult> _livestreams(
    int page, {
    String? subcategory,
  }) async {
    var result = await getJson("/stream/livestreams/en", {
      "page": page.toString(),
      "limit": "24",
      "sort": "desc",
      if (subcategory != null) "subcategory": subcategory,
    });
    var items = ((result["data"] as List?) ?? [])
        .map(_roomItem)
        .where((e) => e.roomId.isNotEmpty)
        .toList();
    return LiveCategoryResult(
      hasMore: result["next_page_url"] != null && items.isNotEmpty,
      items: items,
    );
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) {
    return _livestreams(page);
  }

  @override
  Future<List<LiveCategory>> getCategores() async {
    // 每页最多返回 32 个分类，按观看人数排序，取前三页
    var items = [];
    for (var page = 1; page <= 3; page++) {
      var result = await getJson("/api/v1/subcategories", {
        "page": page.toString(),
        "limit": "32",
      });
      items.addAll((result["data"] as List?) ?? []);
      if (result["next_page_url"] == null) {
        break;
      }
    }
    var groups = <String, LiveCategory>{};
    for (var item in items) {
      var parent = item["category"] ?? {};
      var parentId = parent["slug"]?.toString() ?? "other";
      var group = groups.putIfAbsent(
        parentId,
        () => LiveCategory(
          id: parentId,
          name: parent["name"]?.toString() ?? parentId,
          children: [],
        ),
      );
      group.children.add(
        LiveSubCategory(
          id: item["slug"].toString(),
          name: item["name"].toString(),
          parentId: parentId,
          pic: item["banner"]?["url"]?.toString(),
        ),
      );
    }
    return groups.values.toList();
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) {
    return _livestreams(page, subcategory: category.id);
  }

  /// 旧的网页搜索接口（kick.com/api/search），新接口出错时用
  Future<List<dynamic>> _searchChannels(String keyword) async {
    var result = await getJson("/api/search", {"searched_word": keyword});
    return (result["channels"] as List?) ?? [];
  }

  /// 网页现在用的搜索接口（search.kick.com/api/v1）
  Future<dynamic> _searchApi(String path, Map<String, String> query) {
    return getJson("/api/v1$path", query, "search.kick.com");
  }

  /// 在播频道（没有直播标题时标题用用户名、封面用头像）
  LiveRoomItem _channelRoom(LiveAnchorItem e) => LiveRoomItem(
    roomId: e.roomId,
    title: e.userName,
    cover: e.avatar,
    userName: e.userName,
  );

  /// 第 1 页用 /search/enriched：直播（按标题和频道名匹配，有标题、截图、观看人数）
  /// 加上名字匹配的在播频道；之后的页从 /channels/search?is_live=true 取还没给过的在播频道
  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    if (page <= 1) {
      if (_searchSeen.length > 50) {
        _searchSeen.clear();
      }
      var seen = _searchSeen[keyword] = <String>{};
      List<LiveRoomItem> items;
      bool hasMore;
      try {
        var result = await _searchApi("/search/enriched", {"query": keyword});
        var channels = parseKickSearchChannels(result);
        items = [
          ...parseKickSearchLivestreams(result),
          ...channels.where((e) => e.liveStatus).map(_channelRoom),
        ];
        hasMore = channels.isNotEmpty;
      } catch (e) {
        CoreLog.w("Kick 搜索接口出错，改用旧接口：$e");
        var channels = await _searchChannels(keyword);
        items = channels
            .where((e) => e["isLive"] == true)
            .map(
              (e) => LiveRoomItem(
                roomId: e["slug"].toString(),
                title: e["user"]?["username"]?.toString() ?? e["slug"],
                cover: e["user"]?["profilePic"]?.toString() ?? "",
                userName: e["user"]?["username"]?.toString() ?? e["slug"],
              ),
            )
            .toList();
        hasMore = false;
      }
      items = items.where((e) => seen.add(e.roomId)).toList();
      return LiveSearchRoomResult(hasMore: hasMore, items: items);
    }
    var seen = _searchSeen.putIfAbsent(keyword, () => <String>{});
    var limit = (page - 1) * kSearchChannelPageSize;
    if (limit > kSearchChannelMax) {
      return LiveSearchRoomResult(hasMore: false, items: []);
    }
    var result = await _searchApi("/channels/search", {
      "query": keyword,
      "is_live": "true",
      "limit": limit.toString(),
    });
    var channels = parseKickSearchChannels(result);
    var items = channels
        .where((e) => e.liveStatus && seen.add(e.roomId))
        .map(_channelRoom)
        .toList();
    return LiveSearchRoomResult(
      hasMore: channels.length >= limit && limit < kSearchChannelMax,
      items: items,
    );
  }

  /// /channels/search：名字匹配的频道，包括未开播的
  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    var limit = page * kSearchChannelPageSize;
    if (limit > kSearchChannelMax) limit = kSearchChannelMax;
    var skip = (page - 1) * kSearchChannelPageSize;
    if (skip >= limit) {
      return LiveSearchAnchorResult(hasMore: false, items: []);
    }
    List<LiveAnchorItem> channels;
    try {
      var result = await _searchApi("/channels/search", {
        "query": keyword,
        "limit": limit.toString(),
      });
      channels = parseKickSearchChannels(result);
    } catch (e) {
      if (page > 1) rethrow;
      CoreLog.w("Kick 搜索接口出错，改用旧接口：$e");
      var old = await _searchChannels(keyword);
      return LiveSearchAnchorResult(
        hasMore: false,
        items: old
            .map(
              (e) => LiveAnchorItem(
                roomId: e["slug"].toString(),
                avatar: e["user"]?["profilePic"]?.toString() ?? "",
                userName: e["user"]?["username"]?.toString() ?? e["slug"],
                liveStatus: e["isLive"] == true,
              ),
            )
            .toList(),
      );
    }
    return LiveSearchAnchorResult(
      hasMore: channels.length >= limit && limit < kSearchChannelMax,
      items: channels.length > skip ? channels.sublist(skip) : [],
    );
  }

  /// 频道现在的观看人数；没开播时为 null
  Future<int?> getViewers(String slug) async {
    var channel = await getJson("/api/v2/channels/${slug.trim().toLowerCase()}");
    var livestream = channel["livestream"];
    if (livestream == null || livestream["is_live"] != true) {
      return null;
    }
    return (livestream["viewer_count"] as num?)?.toInt();
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    var slug = roomId.trim().toLowerCase();
    var channel = await getJson("/api/v2/channels/$slug");
    var user = channel["user"] ?? {};
    var livestream = channel["livestream"];
    var live = livestream != null && livestream["is_live"] == true;
    String? showTime;
    var start =
        livestream?["start_time"]?.toString() ??
        livestream?["created_at"]?.toString();
    if (start != null) {
      // 形如 2026-10-19 14:58:32，为 UTC 时间
      var time = DateTime.tryParse("${start.replaceFirst(' ', 'T')}Z");
      if (time != null) {
        showTime = (time.millisecondsSinceEpoch ~/ 1000).toString();
      }
    }
    var title = livestream?["session_title"]?.toString() ?? "";
    var category = (livestream?["categories"] as List?)?.firstOrNull?["name"];
    return LiveRoomDetail(
      roomId: channel["slug"]?.toString() ?? slug,
      title: title.isEmpty ? (user["username"]?.toString() ?? slug) : title,
      cover:
          livestream?["thumbnail"]?["url"]?.toString() ??
          channel["banner_image"]?["url"]?.toString() ??
          channel["offline_banner_image"]?["src"]?.toString() ??
          "",
      userName: user["username"]?.toString() ?? slug,
      userAvatar: user["profile_pic"]?.toString() ?? "",
      online: (livestream?["viewer_count"] as num?)?.toInt() ?? 0,
      status: live,
      url: "https://kick.com/$slug",
      introduction: [
        if (category != null) category.toString(),
        user["bio"]?.toString() ?? "",
      ].where((e) => e.isNotEmpty).join("\n"),
      notice: "",
      data: channel["playback_url"]?.toString(),
      danmakuData: KickDanmakuArgs(
        chatroomId: (channel["chatroom"]?["id"] as num?)?.toInt() ?? 0,
        channelId: (channel["id"] as num?)?.toInt() ?? 0,
        slug: slug,
        userId: kickChannelUserId(channel),
      ),
      showTime: showTime,
      area: LiveRoomArea.kick(livestream),
    );
  }

  Future<List<HlsVariant>> _getVariants(String playbackUrl) async {
    var url = Uri.parse(playbackUrl);
    var text = await HttpClient.instance.getText(
      playbackUrl,
      header: {
        "User-Agent": kUserAgent,
        "Origin": "https://kick.com",
        "Referer": "https://kick.com/",
      },
    );
    return parseHlsMaster(text, url);
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    var playbackUrl = detail.data?.toString() ?? "";
    if (playbackUrl.isEmpty) {
      return [];
    }
    var variants = await _getVariants(playbackUrl);
    var qualities = <LivePlayQuality>[];
    for (var i = 0; i < variants.length; i++) {
      var v = variants[i];
      var name = v.audioOnly ? "仅音频" : v.name;
      if (i == 0 && !v.audioOnly) {
        name = "{name}(源画)".tf({"name": name});
      }
      qualities.add(
        LivePlayQuality(quality: name, data: v.id, sort: variants.length - i),
      );
    }
    return qualities;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    // 播放地址带令牌，每次播放都重新读取频道信息；读取失败时沿用详情中的地址
    var playbackUrl = detail.data?.toString() ?? "";
    try {
      var fresh = await getJson("/api/v2/channels/${detail.roomId}");
      playbackUrl = fresh["playback_url"]?.toString() ?? playbackUrl;
    } catch (_) {}
    if (playbackUrl.isEmpty) {
      return LivePlayUrl(urls: []);
    }
    var variants = await _getVariants(playbackUrl);
    var matched = variants.where((e) => e.id == quality.data).toList();
    var urls = (matched.isNotEmpty ? matched : variants.take(1))
        .map((e) => e.url)
        .toList();
    return LivePlayUrl(
      urls: urls,
      headers: {"user-agent": kUserAgent, "referer": "https://kick.com/"},
    );
  }

  /// iOS 系统画中画（AVPlayer）用的地址：直播本来就是 Amazon IVS 的 HLS，和 [getPlayUrls] 相同。
  /// 只有读取频道信息要经过 [KickHttp]，播放列表和分片在 IVS 上，AVPlayer 可以直接请求
  @override
  Future<LivePlayUrl?> getAvPlayerUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    return hlsOnlyPlayUrl(await getPlayUrls(detail: detail, quality: quality));
  }

  /// 搜索联想（search.kick.com/api/v1/search）：频道卡片（含未开播）、直播、分类
  @override
  Future<List<LiveSuggestion>> getSearchSuggestions(String keyword) async {
    var result = await _searchApi("/search", {"query": keyword});
    return parseKickSuggestions(result);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var channel = await getJson("/api/v2/channels/${roomId.trim()}");
    return channel["livestream"]?["is_live"] == true;
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) {
    return Future.value([]);
  }

  /// 已知的 Pusher 凭据，接口不可用时使用
  static const String kPusherAppKey = "34bf7a0ff419a2a775b9";
  static const String kPusherCluster = "us2";

  /// 读取聊天室的 Pusher 连接凭据
  ///
  /// Kick 会下发 Pusher 或 Centrifugo 两种实时通道，这里只请求 Pusher。
  Future<({String appKey, String cluster})> getPusherCredentials(
    int channelId,
  ) async {
    try {
      var response = await KickHttp.send(
        "POST",
        Uri.https(
          "web.kick.com",
          "/api/v1/realtime/channels/$channelId/chat/connection",
        ),
        headers: {
          "User-Agent": kUserAgent,
          "Accept": "application/json",
          "Content-Type": "application/json",
        },
        body: json.encode({
          "client": {"id": _randomClientId(), "type": "web"},
          "capabilities": {
            "accepted_providers": [
              {"provider": "pusher"},
            ],
          },
        }),
      );
      if (response.statusCode == 200) {
        var connections =
            (json.decode(response.body)["data"]?["connections"] as List?) ?? [];
        for (var item in connections) {
          var credentials = item["credentials"] ?? {};
          var key = credentials["app_key"]?.toString() ?? "";
          var cluster = credentials["cluster"]?.toString() ?? "";
          if (item["provider"] == "pusher" &&
              key.isNotEmpty &&
              cluster.isNotEmpty) {
            return (appKey: key, cluster: cluster);
          }
        }
      }
    } catch (_) {}
    return (appKey: kPusherAppKey, cluster: kPusherCluster);
  }

  static String _randomClientId() {
    var random = Random();
    String hex(int n) =>
        List.generate(n, (_) => random.nextInt(16).toRadixString(16)).join();
    return "${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}";
  }

  /// 读取会话令牌对应的用户名，用于校验登录
  Future<String> getTokenUser(String token) async {
    var response = await KickHttp.send(
      "GET",
      Uri.https("kick.com", "/api/v1/user"),
      headers: {
        "User-Agent": kUserAgent,
        "Accept": "application/json",
        "Authorization": "Bearer $token",
      },
    );
    if (response.statusCode != 200) {
      throw CoreError("Kick 令牌无效或已过期({statusCode})".tf({"statusCode": response.statusCode}));
    }
    var user = json.decode(response.body);
    var name = user["username"]?.toString() ?? "";
    if (name.isEmpty) {
      throw CoreError("Kick 令牌无效或已过期".t);
    }
    return name;
  }
}
