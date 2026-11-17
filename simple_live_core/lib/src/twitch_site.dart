import 'dart:math';

import 'package:simple_live_core/src/account_follows/twitch_account_follows.dart';
import 'package:simple_live_core/src/common/avplayer_url.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/hls_master.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/room_area.dart';
import 'package:simple_live_core/src/common/search_parser.dart';
import 'package:simple_live_core/src/danmaku/twitch_danmaku.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
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

/// Twitch
///
/// 列表与详情走 Twitch 网页端的 GQL 接口（匿名可用）。
/// 带游标翻页的查询需要浏览器完整性令牌，因此各列表只取第一页；
/// 搜索例外：频道搜索（searchFor）可以带游标翻页，直播搜索（searchStreams）
/// 不给游标，按“多取一些再截取”翻页（最多 100 个）。
class TwitchSite
    with
        TwitchAccountFollows
    implements LiveSite {
  @override
  String id = "twitch";

  @override
  String name = "Twitch";

  /// 搜索直播每页的数量；searchStreams 一次最多给 100 个
  static const int kSearchStreamPageSize = 30;
  static const int kSearchStreamMax = 100;

  /// 频道搜索各页的游标：键为关键词，第 n 项是第 n + 2 页的游标
  final Map<String, List<String>> _channelCursors = {};

  /// 网页端 Client-ID
  static const String kClientId = "kimne78kx3ncx6brgo4mv6wki5h1ko";
  static const String kUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

  /// 登录后的 OAuth 令牌（网页 Cookie 中的 auth-token）
  @override
  String token = "";

  /// 登录用户名（小写 login）
  @override
  String login = "";

  /// 登录用户显示名称
  String displayName = "";

  @override
  LiveDanmaku getDanmaku() => TwitchDanmaku(site: this);

  Future<dynamic> _gql(
    String query, [
    Map<String, dynamic>? variables,
    bool withToken = false,
  ]) async {
    var result = await HttpClient.instance.postJson(
      "https://gql.twitch.tv/gql",
      data: {"query": query, if (variables != null) "variables": variables},
      header: {
        "Client-ID": kClientId,
        "User-Agent": kUserAgent,
        "Content-Type": "application/json",
        if (withToken && token.isNotEmpty) "Authorization": "OAuth $token",
      },
    );
    var errors = result["errors"];
    if (errors is List && errors.isNotEmpty && result["data"] == null) {
      throw CoreError(errors.first["message"]?.toString() ?? "Twitch 返回了错误".t);
    }
    return result["data"];
  }

  static const String _streamFields =
      "id title viewersCount previewImageURL(width: 440, height: 248) broadcaster { login displayName }";

  LiveRoomItem _roomItem(dynamic node) {
    var broadcaster = node["broadcaster"] ?? {};
    var displayName = broadcaster["displayName"]?.toString() ?? "";
    var login = broadcaster["login"]?.toString() ?? "";
    return LiveRoomItem(
      roomId: login,
      title: node["title"]?.toString() ?? "",
      cover: node["previewImageURL"]?.toString() ?? "",
      userName: _displayName(displayName, login),
      online: (node["viewersCount"] as num?)?.toInt() ?? 0,
    );
  }

  /// 显示名称与 login 不同（如中日韩文名称）时附上 login
  String _displayName(String displayName, String login) {
    if (displayName.isEmpty) {
      return login;
    }
    if (displayName.toLowerCase() == login.toLowerCase()) {
      return displayName;
    }
    return "$displayName($login)";
  }

  List<LiveRoomItem> _edgesToRooms(dynamic connection) {
    var edges = (connection?["edges"] as List?) ?? [];
    return edges
        .where((e) => e?["node"] != null)
        .map((e) => _roomItem(e["node"]))
        .where((e) => e.roomId.isNotEmpty)
        .toList();
  }

  @override
  Future<List<LiveCategory>> getCategores() async {
    var data = await _gql(
      "query { games(first: 100) { edges { node { id slug displayName boxArtURL(width: 144, height: 192) } } } }",
    );
    var edges = (data?["games"]?["edges"] as List?) ?? [];
    var children = edges
        .where((e) => e?["node"] != null)
        .map(
          (e) => LiveSubCategory(
            id: e["node"]["slug"].toString(),
            name: e["node"]["displayName"].toString(),
            parentId: "top",
            pic: e["node"]["boxArtURL"]?.toString(),
          ),
        )
        .toList();
    return [LiveCategory(id: "top", name: "热门分类", children: children)];
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    if (page > 1) {
      return LiveCategoryResult(hasMore: false, items: []);
    }
    var data = await _gql(
      "query(\$slug: String!) { game(slug: \$slug) { streams(first: 100) { edges { node { $_streamFields } } } } }",
      {"slug": category.id},
    );
    return LiveCategoryResult(
      hasMore: false,
      items: _edgesToRooms(data?["game"]?["streams"]),
    );
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    if (page > 1) {
      return LiveCategoryResult(hasMore: false, items: []);
    }
    var data = await _gql(
      "query { streams(first: 30) { edges { node { $_streamFields } } } }",
    );
    return LiveCategoryResult(
      hasMore: false,
      items: _edgesToRooms(data?["streams"]),
    );
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    // searchStreams 的游标是空的，第 n 页取前 n × 30 个再截掉前面几页
    var first = page * kSearchStreamPageSize;
    if (first > kSearchStreamMax) first = kSearchStreamMax;
    var skip = (page - 1) * kSearchStreamPageSize;
    if (skip >= first) {
      return LiveSearchRoomResult(hasMore: false, items: []);
    }
    var data = await _gql(
      "query(\$q: String!) { searchStreams(userQuery: \$q, first: $first) { edges { node { $_streamFields } } pageInfo { hasNextPage } } }",
      {"q": keyword},
    );
    var connection = data?["searchStreams"];
    var edges = (connection?["edges"] as List?) ?? const [];
    var rooms = _edgesToRooms(connection);
    return LiveSearchRoomResult(
      hasMore:
          first < kSearchStreamMax &&
          edges.length >= first &&
          connection?["pageInfo"]?["hasNextPage"] != false,
      items: rooms.length > skip ? rooms.sublist(skip) : [],
    );
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    // 包括未开播的频道；后续页用上一页带回的游标（类型是 String，不是 Cursor）
    String? cursor;
    if (page <= 1) {
      if (_channelCursors.length > 50) {
        _channelCursors.clear();
      }
      _channelCursors[keyword] = [];
    } else {
      var cursors = _channelCursors[keyword];
      if (cursors == null || cursors.length < page - 1) {
        return LiveSearchAnchorResult(hasMore: false, items: []);
      }
      cursor = cursors[page - 2];
    }
    const fields =
        "channels { cursor items { login displayName profileImageURL(width: 70) stream { id } lastBroadcast { startedAt title } followers { totalCount } } }";
    var data = cursor == null
        ? await _gql(
            "query(\$q: String!) { searchFor(userQuery: \$q, platform: \"web\", options: { targets: [{ index: CHANNEL }] }) { $fields } }",
            {"q": keyword},
          )
        : await _gql(
            "query(\$q: String!, \$c: String) { searchFor(userQuery: \$q, platform: \"web\", options: { targets: [{ index: CHANNEL, cursor: \$c, limit: 15 }] }) { $fields } }",
            {"q": keyword, "c": cursor},
          );
    var result = parseTwitchSearchChannels(data, _displayName);
    var cursors = _channelCursors.putIfAbsent(keyword, () => []);
    if (cursors.length > page - 1) {
      cursors.removeRange(page - 1, cursors.length);
    }
    var next = result.cursor;
    if (next != null && next != cursor && cursors.length == page - 1) {
      cursors.add(next);
    }
    return LiveSearchAnchorResult(
      hasMore: next != null && next != cursor && result.items.isNotEmpty,
      items: result.items,
    );
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    var loginName = roomId.trim().toLowerCase();
    var data = await _gql(
      "query(\$login: String!) { user(login: \$login) { id login displayName description profileImageURL(width: 300) offlineImageURL stream { id title type viewersCount createdAt previewImageURL(width: 640, height: 360) game { displayName } } } }",
      {"login": loginName},
    );
    var user = data?["user"];
    if (user == null) {
      throw CoreError("Twitch 频道不存在：{roomId}".tf({"roomId": roomId}));
    }
    var stream = user["stream"];
    var login = user["login"].toString();
    int? startTime;
    var createdAt = DateTime.tryParse(stream?["createdAt"]?.toString() ?? "");
    if (createdAt != null) {
      startTime = createdAt.millisecondsSinceEpoch ~/ 1000;
    }
    var title = stream?["title"]?.toString() ?? "";
    var game = stream?["game"]?["displayName"]?.toString();
    return LiveRoomDetail(
      roomId: login,
      title: title.isEmpty ? user["displayName"].toString() : title,
      cover:
          stream?["previewImageURL"]?.toString() ??
          user["offlineImageURL"]?.toString() ??
          "",
      userName: _displayName(user["displayName"]?.toString() ?? "", login),
      userAvatar: user["profileImageURL"]?.toString() ?? "",
      online: (stream?["viewersCount"] as num?)?.toInt() ?? 0,
      status: stream != null && stream["type"] == "live",
      url: "https://www.twitch.tv/$login",
      introduction: [
        if (game != null && game.isNotEmpty) game,
        user["description"]?.toString() ?? "",
      ].where((e) => e.isNotEmpty).join("\n"),
      notice: "",
      danmakuData: TwitchDanmakuArgs(
        channel: login,
        userId: user["id"]?.toString() ?? "",
      ),
      showTime: startTime?.toString(),
      area: LiveRoomArea.clean(game),
    );
  }

  /// 获取播放凭证并读取主播放列表
  ///
  /// 已登录时带上令牌申请凭证：订阅者/Turbo 用户可获得受限码率并减少广告。
  /// 令牌被拒绝时退回匿名凭证。
  Future<List<HlsVariant>> _getVariants(String login) async {
    const query =
        "query(\$login: String!) { streamPlaybackAccessToken(channelName: \$login, params: { platform: \"web\", playerBackend: \"mediaplayer\", playerType: \"site\" }) { value signature } }";
    dynamic data;
    if (token.isNotEmpty) {
      try {
        data = await _gql(query, {"login": login}, true);
      } catch (_) {
        data = null;
      }
    }
    data ??= await _gql(query, {"login": login});
    var accessToken = data?["streamPlaybackAccessToken"];
    if (accessToken == null) {
      throw CoreError("拿不到 Twitch 的播放授权".t);
    }
    var url = Uri.https("usher.ttvnw.net", "/api/v2/channel/hls/$login.m3u8", {
      "sig": accessToken["signature"].toString(),
      "token": accessToken["value"].toString(),
      "allow_source": "true",
      "allow_audio_only": "true",
      "fast_bread": "true",
      "playlist_include_framerate": "true",
      "player_backend": "mediaplayer",
      "supported_codecs": "h265,h264",
      "platform": "web",
      "p": Random().nextInt(9000000).toString(),
    });
    var text = await HttpClient.instance.getText(
      url.toString(),
      header: {"User-Agent": kUserAgent},
    );
    return parseHlsMaster(text, url);
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    var variants = await _getVariants(detail.roomId);
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
    // 码流地址带有时效令牌，每次播放都重新获取
    var variants = await _getVariants(detail.roomId);
    var matched = variants.where((e) => e.id == quality.data).toList();
    var urls = (matched.isNotEmpty ? matched : variants.take(1))
        .map((e) => e.url)
        .toList();
    return LivePlayUrl(urls: urls);
  }

  /// iOS 系统画中画（AVPlayer）用的地址：直播本来就是 HLS，和 [getPlayUrls] 相同
  @override
  Future<LivePlayUrl?> getAvPlayerUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    return hlsOnlyPlayUrl(await getPlayUrls(detail: detail, quality: quality));
  }

  /// 搜索联想：频道卡片（含是否在播，包括未开播；能容错，shro → shroud）、分类、词
  @override
  Future<List<LiveSuggestion>> getSearchSuggestions(String keyword) async {
    var requestId = List.generate(
      16,
      (_) => Random().nextInt(16).toRadixString(16),
    ).join();
    var data = await _gql(
      "query(\$q: String!) { searchSuggestions(queryFragment: \$q, requestID: \"$requestId\", withOfflineChannelContent: true) { edges { node { id text content { __typename ... on SearchSuggestionChannel { id login isLive isVerified profileImageURL(width: 50) user { id login displayName stream { id } } } ... on SearchSuggestionCategory { id boxArtURL game { id slug displayName } } } } } } }",
      {"q": keyword},
    );
    return parseTwitchSuggestions(data, _displayName);
  }

  /// 按用户 id 读的频道（共享聊天里别的频道用），每个 id 只请求一次
  static final Map<String, Future<LiveLinkMicUser?>> _channelsById = {};

  /// 频道现在的观看人数（匿名 GQL）；没开播时为 null
  Future<int?> getViewers(String login) async {
    var data = await _gql(
      "query(\$login: String!) { user(login: \$login) { stream { viewersCount } } }",
      {"login": login.trim().toLowerCase()},
    );
    return (data?["user"]?["stream"]?["viewersCount"] as num?)?.toInt();
  }

  /// 按用户 id 读频道：名称（[_displayName]）、login（作为直播间号）、头像。
  /// 匿名 GQL；每个 id 只请求一次，失败了也不再请求；不存在或失败时为 null
  Future<LiveLinkMicUser?> getChannelById(String id) {
    var key = id.trim();
    if (key.isEmpty || int.tryParse(key) == null) {
      return Future.value(null);
    }
    var cached = _channelsById[key];
    if (cached != null) {
      return cached;
    }
    while (_channelsById.length >= 500) {
      _channelsById.remove(_channelsById.keys.first);
    }
    return _channelsById[key] = () async {
      try {
        var data = await _gql(
          "query(\$id: ID!) { user(id: \$id, lookupType: ALL) { id login displayName profileImageURL(width: 70) } }",
          {"id": key},
        );
        var user = data?["user"];
        var login = user?["login"]?.toString() ?? "";
        if (login.isEmpty) {
          return null;
        }
        return LiveLinkMicUser(
          name: _displayName(user["displayName"]?.toString() ?? "", login),
          face: user["profileImageURL"]?.toString() ?? "",
          roomId: login,
        );
      } catch (e) {
        CoreLog.error(e);
        return null;
      }
    }();
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var data = await _gql(
      "query(\$login: String!) { user(login: \$login) { stream { type } } }",
      {"login": roomId.trim().toLowerCase()},
    );
    return data?["user"]?["stream"]?["type"] == "live";
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) {
    return Future.value([]);
  }

  /// 校验 OAuth 令牌并读取登录用户信息
  Future<({String login, String displayName})> getTokenUser(
    String token,
  ) async {
    var result = await HttpClient.instance.postJson(
      "https://gql.twitch.tv/gql",
      data: {"query": "query { currentUser { login displayName } }"},
      header: {
        "Client-ID": kClientId,
        "Authorization": "OAuth $token",
        "User-Agent": kUserAgent,
        "Content-Type": "application/json",
      },
    );
    var user = result["data"]?["currentUser"];
    if (user == null) {
      throw CoreError("Twitch 令牌无效或已过期".t);
    }
    return (
      login: user["login"].toString(),
      displayName: user["displayName"]?.toString() ?? user["login"].toString(),
    );
  }
}
