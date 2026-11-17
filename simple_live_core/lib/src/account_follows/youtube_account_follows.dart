import 'dart:convert';

import 'package:simple_live_core/src/common/account_follow_http.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/youtube_data_api.dart';
import 'package:simple_live_core/src/common/youtube_innertube.dart';
import 'package:simple_live_core/src/common/youtube_parser.dart';
import 'package:simple_live_core/src/interface/live_account_follow_site.dart';
import 'package:simple_live_core/src/youtube_auth.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// YouTube：账号订阅的频道与订阅/取消订阅
///
/// 有谷歌官方授权时优先走 Data API（官方接口，风险最低，只受配额限制）：
/// - 读：`subscriptions.list?mine=true`，每页 50 个、1 单位配额；每条的 id 就是订阅 ID；
/// - 写：`subscriptions.insert`、`subscriptions.delete`，各 50 单位配额；
///   subscriptionDuplicate（已订阅）、subscriptionNotFound（已取消）按成功处理；
///   subscriptionForbidden（订阅数到上限，或“最近订阅太多，请几小时后再试”）当作风控停止。
///
/// 只有网页 Cookie 时走 InnerTube（不占配额，非官方接口）：
/// - 读：browse `FEchannels`（“管理订阅”页），continuation 翻页，解析 channelRenderer；
///   渲染器的结构常变，没有用真账号实测过；
/// - 写：`subscription/subscribe`、`subscription/unsubscribe`（YouTube.js InteractionManager）。
mixin YouTubeAccountFollows implements LiveAccountFollowSite {
  /// 登录凭据（YouTubeSite.credentials）
  YouTubeCredentials get credentials;

  /// 官方授权和 Cookie 登录的频道 ID，App 登录、启动时设置，只用于区分快照
  String followOAuthChannelId = "";
  String followCookieChannelId = "";

  Future<YouTubeOAuthToken>? _followRefreshing;

  /// 当前走官方授权
  bool get _useOAuth => credentials.hasOAuth;

  @override
  bool get canReadAccountFollows =>
      credentials.hasOAuth || credentials.hasCookie;

  @override
  String get accountFollowOwner {
    if (_useOAuth) {
      return followOAuthChannelId.isEmpty ? "" : "oauth:$followOAuthChannelId";
    }
    if (credentials.hasCookie) {
      return followCookieChannelId.isEmpty
          ? ""
          : "cookie:$followCookieChannelId";
    }
    return "";
  }

  @override
  bool get canWriteAccountFollows => canReadAccountFollows;

  @override
  AccountFollowPolicy get accountFollowPolicy => _useOAuth
      ? const AccountFollowPolicy(
          pageInterval: Duration(milliseconds: 100),
          writeIntervalMin: Duration(seconds: 1),
          writeIntervalMax: Duration(milliseconds: 1500),
          batchLimit: 20,
          maxPages: 100,
          writeQuotaCost: 50,
        )
      : const AccountFollowPolicy(
          pageInterval: Duration(milliseconds: 500),
          writeIntervalMin: Duration(seconds: 2),
          writeIntervalMax: Duration(seconds: 3),
          batchLimit: 20,
          maxPages: 100,
        );

  // ---- 官方授权 ----

  Future<YouTubeOAuthToken> _refreshFollowToken() {
    var pending = _followRefreshing;
    if (pending != null) {
      return pending;
    }
    var future = () async {
      try {
        var fresh = await YouTubeOAuth(
          credentials.oauthConfig!,
        ).refresh(credentials.oauthToken!);
        credentials.oauthToken = fresh;
        credentials.onTokenRefreshed?.call(fresh);
        return fresh;
      } on YouTubeNetworkException catch (e) {
        throw AccountFollowNetworkError(e.message);
      } on CoreError catch (e) {
        throw AccountFollowAuthError(e.message);
      }
    }();
    _followRefreshing = future;
    return future.whenComplete(() => _followRefreshing = null);
  }

  /// 带官方授权发一次请求：令牌过期先刷新，401 时刷新后重试一次
  Future<AccountFollowHttpResponse> _api(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    var token = credentials.oauthToken!;
    if (token.expired) {
      token = await _refreshFollowToken();
    }
    var url = Uri.parse(
      "${YouTubeDataApi.kBase}$path",
    ).replace(queryParameters: query);
    Future<AccountFollowHttpResponse> send(String accessToken) {
      return AccountFollowHttp.send(
        method,
        url,
        headers: {
          "Authorization": "Bearer $accessToken",
          "Accept": "application/json",
          if (body != null) "Content-Type": "application/json",
        },
        body: body == null ? null : jsonEncode(body),
        channel: AccountFollowChannel.youtube,
      );
    }

    var response = await send(token.accessToken);
    if (response.statusCode == 401) {
      token = await _refreshFollowToken();
      response = await send(token.accessToken);
    }
    return response;
  }

  // ---- 网页 Cookie ----

  Future<AccountFollowHttpResponse> _innertube(
    String endpoint,
    Map<String, dynamic> body,
  ) {
    return AccountFollowHttp.send(
      "POST",
      Uri.parse(
        "${YouTubeInnertube.kOrigin}/youtubei/v1/$endpoint?prettyPrint=false",
      ),
      headers: youTubeCookieHeaders(credentials.cookie),
      body: jsonEncode({
        "context": YouTubeInnertube.clientContext(YouTubeClient.web),
        ...body,
      }),
      channel: AccountFollowChannel.youtube,
    );
  }

  @override
  Future<AccountFollowPage> getAccountFollows({String? cursor}) async {
    if (_useOAuth) {
      var response = await _api(
        "GET",
        "/subscriptions",
        query: {
          "part": "snippet",
          "mine": "true",
          "maxResults": "50",
          "order": "alphabetical",
          if (cursor != null) "pageToken": cursor,
        },
      );
      checkYouTubeFollowResponse(
        response.statusCode,
        response.json,
        read: true,
      );
      return parseYouTubeSubscriptions(response.json);
    }
    if (!credentials.hasCookie) {
      throw AccountFollowAuthError("请先登录 YouTube 账号".t);
    }
    var response = await _innertube(
      "browse",
      cursor == null ? {"browseId": "FEchannels"} : {"continuation": cursor},
    );
    checkYouTubeCookieStatus(response.statusCode);
    return parseYouTubeChannelsFeed(response.json);
  }

  @override
  Future<AccountFollowTarget> resolveAccountFollowTarget(String roomId) async {
    return AccountFollowTarget(roomId: roomId, accountUid: roomId);
  }

  @override
  Future<void> followOnAccount(AccountFollowTarget target) async {
    var channelId = target.accountUid.isNotEmpty
        ? target.accountUid
        : target.roomId;
    if (!YouTubeLink.isChannelId(channelId)) {
      throw AccountFollowRejectedError("YouTube 频道 ID 不对：{channelId}".tf({"channelId": channelId}));
    }
    if (_useOAuth) {
      var response = await _api(
        "POST",
        "/subscriptions",
        query: {"part": "snippet"},
        body: {
          "snippet": {
            "resourceId": {"kind": "youtube#channel", "channelId": channelId},
          },
        },
      );
      if (YouTubeDataApi.errorReason(response.json) ==
          "subscriptionDuplicate") {
        return;
      }
      checkYouTubeFollowResponse(response.statusCode, response.json);
      return;
    }
    if (!credentials.hasCookie) {
      throw AccountFollowAuthError("请先登录 YouTube 账号".t);
    }
    var response = await _innertube("subscription/subscribe", {
      "channelIds": [channelId],
      "params": "EgIIAhgA",
    });
    checkYouTubeCookieStatus(response.statusCode);
  }

  @override
  Future<void> unfollowOnAccount(AccountFollowTarget target) async {
    var channelId = target.accountUid.isNotEmpty
        ? target.accountUid
        : target.roomId;
    if (!YouTubeLink.isChannelId(channelId)) {
      throw AccountFollowRejectedError("YouTube 频道 ID 不对：{channelId}".tf({"channelId": channelId}));
    }
    if (_useOAuth) {
      // 按频道查订阅 ID（1 单位配额），没订阅时为 null
      Future<String?> lookup() async {
        var response = await _api(
          "GET",
          "/subscriptions",
          query: {"part": "id", "mine": "true", "forChannelId": channelId},
        );
        checkYouTubeFollowResponse(
          response.statusCode,
          response.json,
          read: true,
        );
        return parseYouTubeSubscriptionId(response.json);
      }

      Future<AccountFollowHttpResponse> delete(String id) =>
          _api("DELETE", "/subscriptions", query: {"id": id});

      bool notFound(AccountFollowHttpResponse response) =>
          YouTubeDataApi.errorReason(response.json) == "subscriptionNotFound" ||
          response.statusCode == 404;

      var stored = target.extra["subscriptionId"] ?? "";
      var subscriptionId = stored.isNotEmpty ? stored : await lookup() ?? "";
      if (subscriptionId.isEmpty) {
        return;
      }
      var response = await delete(subscriptionId);
      if (notFound(response)) {
        if (stored.isEmpty) {
          return;
        }
        // 记下的订阅 ID 可能已经失效（在网页上退订后又订阅了），按频道再查一次
        var fresh = await lookup();
        if (fresh == null || fresh == stored) {
          return;
        }
        response = await delete(fresh);
        if (notFound(response)) {
          return;
        }
      }
      checkYouTubeFollowResponse(response.statusCode, response.json);
      return;
    }
    if (!credentials.hasCookie) {
      throw AccountFollowAuthError("请先登录 YouTube 账号".t);
    }
    var response = await _innertube("subscription/unsubscribe", {
      "channelIds": [channelId],
      "params": "CgIIAhgA",
    });
    checkYouTubeCookieStatus(response.statusCode);
  }
}

/// Data API 的返回：2xx 成功，其余按错误原因分类
void checkYouTubeFollowResponse(
  int statusCode,
  dynamic json, {
  bool read = false,
}) {
  if (statusCode >= 200 && statusCode < 300) {
    return;
  }
  var reason = YouTubeDataApi.errorReason(json);
  switch (reason) {
    case "quotaExceeded":
    case "dailyLimitExceeded":
      throw AccountFollowRiskError(
        "YouTube API 今天的配额用完了，明天再试".t,
        pause: const Duration(hours: 6),
      );
    case "subscriptionForbidden":
      throw AccountFollowRiskError(
        "YouTube 不让继续订阅（订阅数到上限，或最近订阅太多，请几小时后再试）".t,
        pause: const Duration(hours: 3),
      );
    case "rateLimitExceeded":
    case "userRateLimitExceeded":
    case "RATE_LIMIT_EXCEEDED":
      throw AccountFollowRiskError("YouTube 提示操作太频繁".t);
    case "insufficientPermissions":
    case "ACCESS_TOKEN_SCOPE_INSUFFICIENT":
      throw AccountFollowAuthError("授权时没有给管理 YouTube 账号的权限，请重新登录并允许所有权限".t);
    case "accessNotConfigured":
    case "SERVICE_DISABLED":
      throw AccountFollowAuthError("这个 Google Cloud 项目还没启用 YouTube Data API v3".t);
    case "subscriberNotFound":
    case "youtubeSignupRequired":
      throw AccountFollowAuthError("这个谷歌账号还没有 YouTube 频道".t);
    case "publisherNotFound":
    case "channelNotFound":
      throw AccountFollowRejectedError("YouTube 频道不存在".t);
  }
  if (statusCode == 401) {
    throw AccountFollowAuthError("YouTube 授权已失效，请重新登录".t);
  }
  if (statusCode == 429) {
    throw AccountFollowRiskError("YouTube 提示操作太频繁(429)".t);
  }
  var error = json is Map ? json["error"] : null;
  var message = error is Map ? error["message"]?.toString() ?? "" : "";
  var action = read ? "读取订阅".t : "修改订阅".t;
  throw CoreError(
    message.isEmpty
        ? "YouTube {action}失败({statusCode})".tf({"action": action, "statusCode": statusCode})
        : "YouTube {action}失败：{message}".tf({"action": action, "message": message}),
  );
}

/// 网页接口的状态码：401/403 Cookie 失效，429 频繁
void checkYouTubeCookieStatus(int statusCode) {
  if (statusCode == 200) {
    return;
  }
  if (statusCode == 401 || statusCode == 403) {
    throw AccountFollowAuthError("YouTube Cookie 已失效，请重新登录".t);
  }
  if (statusCode == 429) {
    throw AccountFollowRiskError("YouTube 提示操作太频繁(429)".t);
  }
  throw CoreError("", statusCode: statusCode);
}

String _pickThumbnail(dynamic thumbnails) {
  if (thumbnails is! Map) {
    return "";
  }
  for (var key in ["medium", "default", "high"]) {
    var url = thumbnails[key]?["url"]?.toString() ?? "";
    if (url.isNotEmpty) {
      return url;
    }
  }
  return "";
}

/// 解析 subscriptions.list 的一页
AccountFollowPage parseYouTubeSubscriptions(dynamic json) {
  if (json is! Map) {
    throw CoreError("读取 YouTube 订阅失败：返回内容不对".t);
  }
  var items = <AccountFollowItem>[];
  for (var item
      in (json["items"] is List ? json["items"] as List : const [])
          .whereType<Map>()) {
    var snippet = item["snippet"];
    if (snippet is! Map) {
      continue;
    }
    var channelId = snippet["resourceId"]?["channelId"]?.toString() ?? "";
    if (channelId.isEmpty) {
      continue;
    }
    var subscriptionId = item["id"]?.toString() ?? "";
    items.add(
      AccountFollowItem(
        roomId: channelId,
        accountUid: channelId,
        userName: snippet["title"]?.toString() ?? channelId,
        face: _pickThumbnail(snippet["thumbnails"]),
        extra: subscriptionId.isEmpty
            ? const {}
            : {"subscriptionId": subscriptionId},
      ),
    );
  }
  var next = json["nextPageToken"]?.toString() ?? "";
  return AccountFollowPage(
    items: items,
    nextCursor: next.isEmpty ? null : next,
    total: (json["pageInfo"]?["totalResults"] as num?)?.toInt(),
  );
}

/// subscriptions.list?forChannelId= 的订阅 ID，没有订阅时为 null
String? parseYouTubeSubscriptionId(dynamic json) {
  var items = json is Map ? json["items"] : null;
  if (items is! List || items.isEmpty || items.first is! Map) {
    return null;
  }
  var id = items.first["id"]?.toString() ?? "";
  return id.isEmpty ? null : id;
}

/// 解析“管理订阅”页（browse FEchannels）或它的 continuation：
/// 所有 channelRenderer（也认 gridChannelRenderer），下一页令牌在 continuationItemRenderer 里
AccountFollowPage parseYouTubeChannelsFeed(dynamic json) {
  if (json is! Map) {
    throw CoreError("读取 YouTube 订阅失败：返回内容不对".t);
  }
  var items = <AccountFollowItem>[];
  var seen = <String>{};
  for (var key in ["channelRenderer", "gridChannelRenderer"]) {
    for (var channel in ytFindAll(json, key).whereType<Map>()) {
      var id = channel["channelId"]?.toString() ?? "";
      if (!YouTubeLink.isChannelId(id) || !seen.add(id)) {
        continue;
      }
      items.add(
        AccountFollowItem(
          roomId: id,
          accountUid: id,
          userName: ytText(channel["title"]).isEmpty
              ? id
              : ytText(channel["title"]),
          face: ytThumbnail(channel["thumbnail"], target: 88),
        ),
      );
    }
  }
  return AccountFollowPage(items: items, nextCursor: ytContinuationToken(json));
}
