import 'dart:convert';

import 'package:simple_live_core/src/common/account_follow_http.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/interface/live_account_follow_site.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// Twitch：只读账号关注（GQL currentUser.follows，用网页登录的 auth-token）
///
/// 匿名验证过：第一页正常，带游标的下一页会返回 `failed integrity check`
/// （extensions.code = IntegrityCheckFailed）。带登录令牌时是否同样被拦未经实测，
/// 被拦时返回已读到的第一页（最多 100 个），并说明只读到了前面一部分。
///
/// 回写不做：网页端的关注 mutation 很可能要浏览器完整性令牌，
/// 第三方客户端（Xtra、StreamFusion）都要额外的 WebView 截取或冒用第一方客户端，
/// 见调研笔记 follow_sync.md §7。
mixin TwitchAccountFollows implements LiveAccountFollowSite {
  /// 网页登录的 OAuth 令牌（TwitchSite.token）
  String get token;

  /// 登录用户名（TwitchSite.login）
  String get login;

  static const String _clientId = "kimne78kx3ncx6brgo4mv6wki5h1ko";
  static const String _ua =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

  static const String kFollowsQuery =
      r"query($after: Cursor) { currentUser { follows(first: 100, after: $after, order: ASC) { totalCount edges { cursor node { id login displayName profileImageURL(width: 70) stream { type } } } pageInfo { hasNextPage } } } }";

  @override
  bool get canReadAccountFollows => token.isNotEmpty && login.isNotEmpty;

  @override
  String get accountFollowOwner =>
      canReadAccountFollows ? login.toLowerCase() : "";

  /// 不支持回写，见上面的说明
  @override
  bool get canWriteAccountFollows => false;

  @override
  AccountFollowPolicy get accountFollowPolicy => const AccountFollowPolicy(
    pageInterval: Duration(milliseconds: 300),
    writeIntervalMin: Duration(seconds: 3),
    writeIntervalMax: Duration(seconds: 4),
    batchLimit: 10,
    maxPages: 100,
  );

  @override
  Future<AccountFollowPage> getAccountFollows({String? cursor}) async {
    if (!canReadAccountFollows) {
      throw AccountFollowAuthError("请先登录 Twitch 账号".t);
    }
    var response = await AccountFollowHttp.send(
      "POST",
      Uri.https("gql.twitch.tv", "/gql"),
      headers: {
        "Client-ID": _clientId,
        "User-Agent": _ua,
        "Content-Type": "application/json",
        "Authorization": "OAuth $token",
      },
      body: jsonEncode({
        "query": kFollowsQuery,
        "variables": {"after": cursor},
      }),
    );
    if (response.statusCode == 401) {
      throw AccountFollowAuthError("Twitch 登录已失效，请重新登录".t);
    }
    if (response.statusCode == 429) {
      throw AccountFollowRiskError("Twitch 提示请求太频繁(429)".t);
    }
    if (response.statusCode != 200) {
      throw CoreError("", statusCode: response.statusCode);
    }
    return parseTwitchAccountFollows(response.json, firstPage: cursor == null);
  }

  @override
  Future<AccountFollowTarget> resolveAccountFollowTarget(String roomId) async {
    var login = roomId.trim().toLowerCase();
    return AccountFollowTarget(roomId: login, accountUid: login);
  }

  @override
  Future<void> followOnAccount(AccountFollowTarget target) {
    throw CoreError("Twitch 暂不支持同步关注到账号".t);
  }

  @override
  Future<void> unfollowOnAccount(AccountFollowTarget target) {
    throw CoreError("Twitch 暂不支持同步关注到账号".t);
  }
}

/// Twitch 只让读前 100 个时的提示
String get kTwitchFollowsTruncated => "Twitch 只让读取前 100 个关注，后面的没有读到".t;

bool _isIntegrityError(dynamic errors) {
  if (errors is! List) {
    return false;
  }
  return errors.whereType<Map>().any(
    (e) =>
        e["extensions"]?["code"] == "IntegrityCheckFailed" ||
        (e["message"]?.toString().contains("integrity") ?? false),
  );
}

/// 显示名称与 login 不同（如中日韩文名称）时附上 login，与 TwitchSite 一致
String _twitchName(String displayName, String login) {
  if (displayName.isEmpty) {
    return login;
  }
  if (displayName.toLowerCase() == login.toLowerCase()) {
    return displayName;
  }
  return "$displayName($login)";
}

/// 解析 currentUser.follows 的一页
///
/// - currentUser 为 null：令牌无效；
/// - 下一页被完整性校验拦下：返回空页并标记截断（已读到的仍然有效）；
/// - 第一页就被拦：抛出错误。
AccountFollowPage parseTwitchAccountFollows(
  dynamic json, {
  required bool firstPage,
}) {
  if (json is! Map) {
    throw CoreError("读取 Twitch 关注失败：返回内容不对".t);
  }
  var errors = json["errors"];
  var follows = json["data"]?["currentUser"]?["follows"];
  if (_isIntegrityError(errors) && follows == null) {
    if (firstPage) {
      throw CoreError("Twitch 拒绝了请求（需要网页验证），暂时读不到关注".t);
    }
    return AccountFollowPage(
      items: [],
      truncatedReason: kTwitchFollowsTruncated,
    );
  }
  var data = json["data"];
  if (data is Map &&
      data.containsKey("currentUser") &&
      data["currentUser"] == null) {
    throw AccountFollowAuthError("Twitch 登录已失效，请重新登录".t);
  }
  if (follows is! Map) {
    var message = errors is List && errors.isNotEmpty && errors.first is Map
        ? errors.first["message"]?.toString() ?? ""
        : "";
    throw CoreError(
      message.isEmpty ? "读取 Twitch 关注失败".t : "读取 Twitch 关注失败：{message}".tf({"message": message}),
    );
  }
  var edges = follows["edges"] is List ? follows["edges"] as List : const [];
  var items = <AccountFollowItem>[];
  String? lastCursor;
  for (var edge in edges.whereType<Map>()) {
    lastCursor = edge["cursor"]?.toString() ?? lastCursor;
    var node = edge["node"];
    if (node is! Map) {
      continue;
    }
    var login = node["login"]?.toString().toLowerCase() ?? "";
    if (login.isEmpty) {
      continue;
    }
    items.add(
      AccountFollowItem(
        roomId: login,
        accountUid: node["id"]?.toString() ?? "",
        userName: _twitchName(node["displayName"]?.toString() ?? "", login),
        face: node["profileImageURL"]?.toString() ?? "",
        isLive: node["stream"] is Map && node["stream"]["type"] == "live",
      ),
    );
  }
  var hasNext = follows["pageInfo"]?["hasNextPage"] == true;
  return AccountFollowPage(
    items: items,
    nextCursor: hasNext && lastCursor != null && lastCursor.isNotEmpty
        ? lastCursor
        : null,
    total: (follows["totalCount"] as num?)?.toInt(),
  );
}
