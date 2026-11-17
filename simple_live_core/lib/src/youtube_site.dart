import 'package:simple_live_core/src/account_follows/youtube_account_follows.dart';
import 'package:simple_live_core/src/common/avplayer_url.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/hls_master.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/room_area.dart';
import 'package:simple_live_core/src/common/search_parser.dart';
import 'package:simple_live_core/src/common/youtube_hls_relay.dart';
import 'package:simple_live_core/src/common/youtube_innertube.dart';
import 'package:simple_live_core/src/common/youtube_parser.dart';
import 'package:simple_live_core/src/danmaku/youtube_danmaku.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
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
import 'package:simple_live_core/src/youtube_auth.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// YouTube 直播
///
/// 房间号是频道 ID（UC 开头）：同一频道每次开播的视频 ID 都不同，关注频道才有意义。
/// 约定：类名、id、[credentials] 和 [resolveRoomId] 是 App 使用的接口，签名不要改。
///
/// 全部走网页内部接口（InnerTube），匿名可用：列表、搜索、详情用网页端，
/// 播放地址用 ANDROID_VR 客户端（见 [YouTubeClient] 的说明）。
class YouTubeSite
    with
        YouTubeAccountFollows
    implements LiveSite {
  @override
  String id = "youtube";

  @override
  String name = "YouTube";

  /// 登录凭据（读写账号关注用），未登录时为空
  @override
  YouTubeCredentials credentials = YouTubeCredentials();

  /// YouTube 官方“直播”频道，频道页按“正在直播”“新闻”“游戏”“体育”分栏列出直播
  static const String kLiveDestination = "UC4R8DWoMoI7CAwX8_LjQHig";

  /// 搜索筛选参数：仅直播、仅频道
  static const String kLiveFilter = "EgJAAQ==";
  static const String kChannelFilter = "EgIQAg==";

  /// 分类：YouTube 没有直播分类接口，按关键词搜索正在进行的直播
  static const List<(String, String)> kCategories = [
    ("游戏", "gaming"),
    ("音乐", "music"),
    ("体育", "sports"),
    ("新闻", "news"),
    ("聊天", "just chatting"),
    ("虚拟主播", "vtuber"),
    ("学习陪伴", "study with me"),
    ("动物与自然", "animal live cam"),
  ];

  /// 各列表后续页的令牌：键为“类型:关键词”，第 n 项是第 n + 2 页的令牌
  final Map<String, List<String>> _pageTokens = {};

  /// 列表中各频道显示的那一场直播（频道 ID → 视频 ID）
  ///
  /// 同一频道可能同时开着几场直播，/channel/UC…/live 只指向其中一场；
  /// 从列表点进直播间时按这里记下的视频打开，与列表显示的一致。
  final Map<String, ({String videoId, DateTime time})> _videoHints = {};

  /// 最近一次读取的码流，选清晰度后紧接着取地址时复用
  ({String videoId, DateTime time, List<HlsVariant> variants})? _lastVariants;

  @override
  LiveDanmaku getDanmaku() => YouTubeDanmaku(site: this);

  /// 从链接或输入得到房间号（频道 ID），无法识别时返回 null。
  /// 支持 watch?v=、youtu.be/、/live/、/shorts/、/@handle、/channel/UC…；
  /// 视频链接和 @handle 需要联网查所属频道。
  static Future<String?> resolveRoomId(String input) async {
    var link = YouTubeLink.parse(input);
    if (link == null) {
      return null;
    }
    switch (link.type) {
      case YouTubeLinkType.channel:
        return link.value;
      case YouTubeLinkType.video:
        return _videoChannelId(link.value);
      case YouTubeLinkType.handle:
        return _resolveBrowseId(
          "https://www.youtube.com/@${Uri.encodeComponent(link.value)}",
        );
      case YouTubeLinkType.path:
        return _resolveBrowseId(link.value);
    }
  }

  /// 用 navigation/resolve_url 把频道链接解析为频道 ID
  static Future<String?> _resolveBrowseId(String url) async {
    var endpoint = await _resolveUrl(url);
    var browseId = endpoint?["browseEndpoint"]?["browseId"]?.toString() ?? "";
    if (YouTubeLink.isChannelId(browseId)) {
      return browseId;
    }
    var videoId = endpoint?["watchEndpoint"]?["videoId"]?.toString() ?? "";
    if (YouTubeLink.isVideoId(videoId)) {
      return _videoChannelId(videoId);
    }
    return null;
  }

  /// 解析链接，返回 endpoint；链接不存在时返回 null
  static Future<dynamic> _resolveUrl(String url) async {
    try {
      var result = await YouTubeInnertube.post("navigation/resolve_url", {
        "url": url,
      });
      return result?["endpoint"];
    } on CoreError catch (e) {
      if (e.statusCode == 404 || e.statusCode == 400) {
        return null;
      }
      rethrow;
    }
  }

  /// 视频所属频道
  static Future<String?> _videoChannelId(String videoId) async {
    var info = await _player(videoId, YouTubeClient.web);
    if (!YouTubeLink.isChannelId(info.channelId)) {
      info = await _player(videoId, YouTubeClient.androidVr);
    }
    return YouTubeLink.isChannelId(info.channelId) ? info.channelId : null;
  }

  /// 调用播放接口
  ///
  /// ANDROID_VR 需要访客标识；遇到机器人验证时换一个新的访客标识重试一次。
  static Future<YouTubePlayerInfo> _player(
    String videoId,
    YouTubeClient client,
  ) async {
    Future<YouTubePlayerInfo> request(bool refreshVisitor) async {
      String? visitor;
      if (client == YouTubeClient.androidVr) {
        visitor = await YouTubeInnertube.visitorData(refresh: refreshVisitor);
      }
      var result = await YouTubeInnertube.post(
        "player",
        {"videoId": videoId, "contentCheckOk": true, "racyCheckOk": true},
        client: client,
        visitorData: visitor,
      );
      return YouTubePlayerInfo.fromJson(result);
    }

    var info = await request(false);
    if (client == YouTubeClient.androidVr && info.status == "LOGIN_REQUIRED") {
      info = await request(true);
    }
    return info;
  }

  /// 直播信息：网页端播放接口带有 microformat（是否正在直播、开播时间），
  /// 体积也只有 ANDROID_VR 的三分之一；没有视频信息时退回 ANDROID_VR。
  static Future<YouTubePlayerInfo> _videoInfo(String videoId) async {
    var info = await _player(videoId, YouTubeClient.web);
    if (!info.hasDetails) {
      info = await _player(videoId, YouTubeClient.androidVr);
    }
    return info;
  }

  /// 频道当前的直播视频：/channel/UC…/live 在直播（或有预告）时解析为视频
  static Future<String?> _liveVideoId(String channelId) async {
    var endpoint = await _resolveUrl(
      "https://www.youtube.com/channel/$channelId/live",
    );
    var videoId = endpoint?["watchEndpoint"]?["videoId"]?.toString() ?? "";
    return YouTubeLink.isVideoId(videoId) ? videoId : null;
  }

  /// 同时在线人数
  static Future<int?> _viewers(String videoId) async {
    try {
      var result = await YouTubeInnertube.post("updated_metadata", {
        "videoId": videoId,
      });
      return parseYouTubeViewers(result);
    } catch (_) {
      return null;
    }
  }

  /// 读取频道名称、头像与简介（移动网页端的频道页体积较小）
  static Future<({String title, String avatar, String description})>
  _channelInfo(String channelId) async {
    dynamic result;
    try {
      result = await YouTubeInnertube.post("browse", {
        "browseId": channelId,
      }, client: YouTubeClient.mweb);
    } on CoreError catch (e) {
      if (e.statusCode == 404 || e.statusCode == 400) {
        throw CoreError("YouTube 频道不存在：{channelId}".tf({"channelId": channelId}));
      }
      result = await YouTubeInnertube.post("browse", {"browseId": channelId});
    }
    var meta = result?["metadata"]?["channelMetadataRenderer"];
    var micro = result?["microformat"]?["microformatDataRenderer"];
    if (meta is! Map && micro is! Map) {
      throw CoreError("YouTube 频道不存在：{channelId}".tf({"channelId": channelId}));
    }
    var title =
        (meta is Map ? meta["title"]?.toString() : null) ??
        (micro is Map ? micro["title"]?.toString() : null) ??
        "";
    var avatar = ytThumbnail(meta is Map ? meta["avatar"] : null);
    if (avatar.isEmpty && micro is Map) {
      avatar = ytThumbnail(micro["thumbnail"]);
    }
    var description =
        (meta is Map ? meta["description"]?.toString() : null) ??
        (micro is Map ? micro["description"]?.toString() : null) ??
        "";
    return (
      title: title,
      avatar: ytResizeAvatar(avatar, 176),
      description: description,
    );
  }

  /// 读取搜索结果的第 [page] 页，后续页用上一页带回的令牌
  Future<({dynamic data, bool hasMore})?> _searchPage(
    String kind,
    String query,
    String params,
    int page,
  ) async {
    var key = "$kind:$query";
    dynamic result;
    if (page <= 1) {
      if (_pageTokens.length > 50) {
        _pageTokens.clear();
      }
      _pageTokens[key] = [];
      result = await YouTubeInnertube.post("search", {
        "query": query,
        "params": params,
      });
    } else {
      var tokens = _pageTokens[key];
      if (tokens == null || tokens.length < page - 1) {
        return null;
      }
      result = await YouTubeInnertube.post("search", {
        "continuation": tokens[page - 2],
      });
    }
    var token = ytContinuationToken(result);
    var tokens = _pageTokens.putIfAbsent(key, () => []);
    if (tokens.length > page - 1) {
      tokens.removeRange(page - 1, tokens.length);
    }
    if (token != null && tokens.length == page - 1) {
      tokens.add(token);
    }
    return (data: result, hasMore: token != null);
  }

  /// 解析列表并记下各频道对应的视频
  List<LiveRoomItem> _liveRooms(dynamic response) {
    var videos = parseYouTubeLiveVideos(response);
    var now = DateTime.now();
    if (_videoHints.length > 500) {
      _videoHints.clear();
    }
    for (var item in videos) {
      if (YouTubeLink.isVideoId(item.videoId)) {
        _videoHints[item.room.roomId] = (videoId: item.videoId, time: now);
      }
    }
    return videos.map((e) => e.room).toList();
  }

  String? _videoHint(String channelId) {
    var hint = _videoHints[channelId];
    if (hint == null) {
      return null;
    }
    if (DateTime.now().difference(hint.time) > const Duration(hours: 1)) {
      _videoHints.remove(channelId);
      return null;
    }
    return hint.videoId;
  }

  /// 搜索结果第一页里的纠正词（“你是不是要找”），键为“类型:关键词”
  final Map<String, String> _corrections = {};

  void _keepCorrection(String kind, String query, dynamic data) {
    if (_corrections.length > 50) {
      _corrections.clear();
    }
    var correction = parseYouTubeCorrection(data);
    if (correction == null) {
      _corrections.remove("$kind:$query");
    } else {
      _corrections["$kind:$query"] = correction;
    }
  }

  Future<LiveCategoryResult> _searchLive(String query, int page) async {
    var result = await _searchPage("live", query, kLiveFilter, page);
    if (result == null) {
      return LiveCategoryResult(hasMore: false, items: []);
    }
    if (page <= 1) {
      _keepCorrection("live", query, result.data);
    }
    var items = _liveRooms(result.data);
    return LiveCategoryResult(
      hasMore: result.hasMore && items.isNotEmpty,
      items: items,
    );
  }

  @override
  Future<List<LiveCategory>> getCategores() async {
    return [
      LiveCategory(
        id: "live",
        name: "直播",
        children: kCategories
            .map((e) => LiveSubCategory(id: e.$2, name: e.$1, parentId: "live"))
            .toList(),
      ),
    ];
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) {
    return _searchLive(category.id, page);
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    // 直播频道页没有翻页，只有一页（约四五十个正在进行的直播）
    if (page > 1) {
      return LiveCategoryResult(hasMore: false, items: []);
    }
    var result = await YouTubeInnertube.post("browse", {
      "browseId": kLiveDestination,
    });
    return LiveCategoryResult(hasMore: false, items: _liveRooms(result));
  }

  /// 直播搜索第一页（一分钟内同一关键词共用）：搜直播间和给频道结果标“直播中”都要用，
  /// 综合搜索时两者同时请求，不重复搜
  final Map<String, ({DateTime time, Future<LiveCategoryResult> result})>
  _liveFirstPages = {};

  Future<LiveCategoryResult> _searchLiveFirstPage(String query) {
    var now = DateTime.now();
    var cached = _liveFirstPages[query];
    if (cached != null &&
        now.difference(cached.time) < const Duration(minutes: 1)) {
      return cached.result;
    }
    if (_liveFirstPages.length > 20) {
      _liveFirstPages.clear();
    }
    var future = _searchLive(query, 1);
    _liveFirstPages[query] = (time: now, result: future);
    future.catchError((_) {
      _liveFirstPages.remove(query);
      return LiveCategoryResult(hasMore: false, items: []);
    });
    return future;
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    var result = page <= 1
        ? await _searchLiveFirstPage(keyword)
        : await _searchLive(keyword, page);
    return LiveSearchRoomResult(
      hasMore: result.hasMore,
      items: result.items,
      correction: page <= 1 ? _corrections["live:$keyword"] : null,
    );
  }

  /// 频道搜索的结果里没有在播标记：同一关键词的直播搜索第一页里出现的频道标“直播中”
  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    var live = _searchLiveFirstPage(keyword)
        .then((e) => e.items.map((r) => r.roomId).toSet())
        .catchError((_) => <String>{});
    var result = await _searchPage("channel", keyword, kChannelFilter, page);
    if (result == null) {
      return LiveSearchAnchorResult(hasMore: false, items: []);
    }
    var liveIds = await live;
    var correction = page <= 1 ? parseYouTubeCorrection(result.data) : null;
    var items = parseYouTubeChannels(result.data)
        .map(
          (e) => liveIds.contains(e.roomId)
              ? LiveAnchorItem(
                  roomId: e.roomId,
                  avatar: e.avatar,
                  userName: e.userName,
                  liveStatus: true,
                )
              : e,
        )
        .toList();
    return LiveSearchAnchorResult(
      hasMore: result.hasMore && items.isNotEmpty,
      items: items,
      correction: correction,
    );
  }

  /// 统一成频道 ID：App 传入的就是频道 ID，其它形式（@handle 等）先解析
  Future<String> _channelId(String roomId) async {
    var id = roomId.trim();
    if (YouTubeLink.isChannelId(id)) {
      return id;
    }
    var resolved = await resolveRoomId(id);
    if (resolved == null) {
      throw CoreError("认不出这个 YouTube 频道：{roomId}".tf({"roomId": roomId}));
    }
    return resolved;
  }

  /// 直播信息与同时在线人数
  static Future<(YouTubePlayerInfo, int?)> _liveInfo(String videoId) async {
    var results = await Future.wait<dynamic>([
      _videoInfo(videoId),
      _viewers(videoId),
    ]);
    return (results[0] as YouTubePlayerInfo, results[1] as int?);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    var channelId = await _channelId(roomId);
    var hint = _videoHint(channelId);
    var first = await Future.wait<dynamic>([
      _channelInfo(channelId),
      hint != null ? Future.value(hint) : _liveVideoId(channelId),
    ]);
    var channel =
        first[0] as ({String title, String avatar, String description});
    var videoId = first[1] as String?;
    YouTubePlayerInfo? info;
    int? viewers;
    if (videoId != null) {
      (info, viewers) = await _liveInfo(videoId);
      if (hint != null &&
          (!info.isLive ||
              (info.channelId.isNotEmpty && info.channelId != channelId))) {
        // 列表中的那一场已经结束：改用频道当前的直播
        _videoHints.remove(channelId);
        info = null;
        viewers = null;
        videoId = await _liveVideoId(channelId);
        if (videoId != null) {
          (info, viewers) = await _liveInfo(videoId);
        }
      }
    }
    var live = info != null && info.isLive;
    var userName = channel.title.isNotEmpty
        ? channel.title
        : (info?.author ?? channelId);
    String? notice;
    if (info != null && info.isUpcoming && info.startTime != null) {
      var t = info.startTime!.toLocal();
      String two(int v) => v.toString().padLeft(2, '0');
      notice =
          "直播预定于 {year}-{two}-{two2} {two3}:{two4} 开始".tf({"year": t.year, "two": two(t.month), "two2": two(t.day), "two3": two(t.hour), "two4": two(t.minute)});
    }
    var title = live ? info.title : "";
    return LiveRoomDetail(
      roomId: channelId,
      title: title.isNotEmpty ? title : userName,
      cover: live
          ? (info.thumbnail.isNotEmpty
                ? info.thumbnail
                : "https://i.ytimg.com/vi/$videoId/hqdefault.jpg")
          : channel.avatar,
      userName: userName,
      userAvatar: channel.avatar,
      online: live ? (viewers ?? 0) : 0,
      status: live,
      url: live
          ? "https://www.youtube.com/watch?v=$videoId"
          : "https://www.youtube.com/channel/$channelId",
      introduction: live
          ? [
              info.category,
              info.description,
            ].where((e) => e.isNotEmpty).join("\n")
          : channel.description,
      notice: notice ?? "",
      data: live ? videoId : null,
      danmakuData: YouTubeDanmakuArgs(
        videoId: live ? videoId! : "",
        channelId: channelId,
      ),
      showTime: live && info.startTime != null
          ? (info.startTime!.millisecondsSinceEpoch ~/ 1000).toString()
          : null,
      area: live ? LiveRoomArea.clean(info.category) : null,
    );
  }

  /// 读取直播的各路码流
  Future<List<HlsVariant>> _getVariants(String videoId) async {
    var info = await _player(videoId, YouTubeClient.androidVr);
    var url = info.hlsManifestUrl;
    if (url.isEmpty) {
      if (!info.isLive) {
        throw CoreError("主播现在没在直播".t);
      }
      var reason = info.reason.isNotEmpty ? info.reason : info.status;
      throw CoreError("拿不到 YouTube 直播地址（{reason}）".tf({"reason": reason}));
    }
    String text;
    try {
      text = await HttpClient.instance.getText(
        url,
        header: {"User-Agent": YouTubeInnertube.kVrUserAgent},
      );
    } on CoreError catch (e) {
      // 连接失败时重试一次（播放列表地址 6 小时内有效，可以直接重用）
      if (e.statusCode != 0) {
        rethrow;
      }
      text = await HttpClient.instance.getText(
        url,
        header: {"User-Agent": YouTubeInnertube.kVrUserAgent},
      );
    }
    var variants = parseHlsMaster(text, Uri.parse(url));
    _lastVariants = (
      videoId: videoId,
      time: DateTime.now(),
      variants: variants,
    );
    return variants;
  }

  String _videoIdOf(LiveRoomDetail detail) {
    var data = detail.data;
    if (data is String && YouTubeLink.isVideoId(data)) {
      return data;
    }
    var args = detail.danmakuData;
    if (args is YouTubeDanmakuArgs) {
      return args.videoId;
    }
    return "";
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    var videoId = _videoIdOf(detail);
    if (videoId.isEmpty) {
      return [];
    }
    var variants = await _getVariants(videoId);
    var qualities = <LivePlayQuality>[];
    for (var i = 0; i < variants.length; i++) {
      var v = variants[i];
      qualities.add(
        LivePlayQuality(
          quality: v.audioOnly ? "仅音频" : v.name,
          data: v.id,
          sort: variants.length - i,
        ),
      );
    }
    return qualities;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    var videoId = _videoIdOf(detail);
    if (videoId.isEmpty) {
      return LivePlayUrl(urls: []);
    }
    // 播放地址 6 小时内有效，并绑定请求时的 IP；
    // 刚选完清晰度时复用，其余情况（重连、切换清晰度）重新获取
    var cached = _lastVariants;
    var variants =
        cached != null &&
            cached.videoId == videoId &&
            DateTime.now().difference(cached.time) < const Duration(seconds: 30)
        ? cached.variants
        : await _getVariants(videoId);
    _lastVariants = null;
    var matched = variants.where((e) => e.id == quality.data).toList();
    var urls = (matched.isNotEmpty ? matched : variants.take(1))
        .map((e) => e.url)
        .toList();
    var headers = {"user-agent": YouTubeInnertube.kVrUserAgent};
    if (urls.isEmpty) {
      return LivePlayUrl(urls: urls, headers: headers);
    }
    // 同一个地址约 30 秒后分片就全部 403：交给本机中转定期换新地址
    var variantId = matched.isNotEmpty ? matched.first.id : variants.first.id;
    try {
      var relay = await YouTubeHlsRelay.instance.register(
        key: "$videoId/$variantId",
        userAgent: YouTubeInnertube.kVrUserAgent,
        initial: urls.first,
        resolve: () async {
          var fresh = await _getVariants(videoId);
          var same = fresh.where((e) => e.id == variantId);
          return (same.isNotEmpty ? same.first : fresh.first).url;
        },
      );
      return LivePlayUrl(urls: [relay], headers: headers);
    } catch (e) {
      // 本机端口开不了时直接播（约 30 秒后会断流重连）
      CoreLog.error(e);
      return LivePlayUrl(urls: urls, headers: headers);
    }
  }

  /// iOS 系统画中画（AVPlayer）用的地址：直播本来就是 HLS，和 [getPlayUrls] 相同
  /// （同样带 ANDROID_VR 的 User-Agent；地址绑定请求时的 IP，手机上取、手机上播）
  @override
  Future<LivePlayUrl?> getAvPlayerUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    return hlsOnlyPlayUrl(await getPlayUrls(detail: detail, quality: quality));
  }

  /// 搜索联想：只要频道。suggestqueries 给的是视频搜索词，不用；
  /// 改成频道搜索的前 5 个（结果里没有在播标记，卡片不显示状态）。
  /// 不记翻页令牌，不影响正式搜索
  @override
  Future<List<LiveSuggestion>> getSearchSuggestions(String keyword) async {
    var result = await YouTubeInnertube.post("search", {
      "query": keyword,
      "params": kChannelFilter,
    });
    return anchorSuggestions(parseYouTubeChannels(result), knownStatus: false);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var channelId = await _channelId(roomId);
    var videoId = await _liveVideoId(channelId);
    if (videoId == null) {
      return false;
    }
    var info = await _videoInfo(videoId);
    return info.isLive;
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) {
    // 醒目留言随聊天推送，没有单独的列表接口
    return Future.value([]);
  }
}
