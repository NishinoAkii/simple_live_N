import 'package:simple_live_core/src/common/account_follow_http.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/interface/live_account_follow_site.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// Kick：账号关注列表与关注/取关
///
/// - 读：`/api/v2/channels/followed` 和 `/api/v2/channels/followed-page` 两个列表，
///   返回 `{channels: [...], nextCursor}`，cursor 为 0 或没有时读完。两个接口给出的
///   集合不一样（StreamFusion 的记录：前者是侧边栏视图、不完整），所以两个都读、取并集，
///   并且不把“不在列表里”当作取关（StreamNook、enhancer、StreamFusion）；
/// - 写：`POST/DELETE /api/v2/channels/{slug}/follow`。422 表示已经是目标状态
///   （StreamFusion 用真账号验证过），按成功处理；
/// - 鉴权：session_token 作为 Bearer，同时放进 Cookie。
mixin KickAccountFollows implements LiveAccountFollowSite {
  /// 登录后的会话令牌（KickSite.token）
  String get token;

  /// 登录账号的用户名（KickSite.userName），只用于区分快照
  String get userName;

  static const String _ua =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

  static const String _followedPath = "/api/v2/channels/followed";
  static const String _followedPagePath = "/api/v2/channels/followed-page";

  @override
  bool get canReadAccountFollows => token.isNotEmpty;

  @override
  String get accountFollowOwner =>
      token.isEmpty ? "" : userName.trim().toLowerCase();

  @override
  bool get canWriteAccountFollows => token.isNotEmpty;

  @override
  AccountFollowPolicy get accountFollowPolicy => const AccountFollowPolicy(
    pageInterval: Duration(milliseconds: 300),
    writeIntervalMin: Duration(milliseconds: 1500),
    writeIntervalMax: Duration(seconds: 3),
    batchLimit: 30,
    maxPages: 200,
    listIsAuthoritative: false,
  );

  Map<String, String> get _headers => {
    "User-Agent": _ua,
    "Accept": "application/json",
    "Content-Type": "application/json",
    "Origin": "https://kick.com",
    "Referer": "https://kick.com/",
    "x-app-platform": "web",
    "Authorization": "Bearer $token",
    "Cookie": "session_token=${Uri.encodeComponent(token)}",
  };

  /// 游标形如 `f:3`（followed 的第几个游标）或 `p:3`（followed-page）
  @override
  Future<AccountFollowPage> getAccountFollows({String? cursor}) async {
    if (token.isEmpty) {
      throw AccountFollowAuthError("请先登录 Kick 账号".t);
    }
    var (list, value) = parseKickFollowCursor(cursor);
    var path = list == "p" ? _followedPagePath : _followedPath;
    var response = await AccountFollowHttp.send(
      "GET",
      Uri.https("kick.com", path, {"cursor": value}),
      headers: _headers,
      channel: AccountFollowChannel.kick,
    );
    // 第二个列表接口不存在或出错时，只用第一个的结果
    if (list == "p" &&
        response.statusCode != 200 &&
        response.statusCode != 401) {
      if (response.statusCode == 429 || response.statusCode == 403) {
        checkKickFollowStatus(response.statusCode, response.body);
      }
      return const AccountFollowPage(items: []);
    }
    checkKickFollowStatus(response.statusCode, response.body);
    return parseKickFollowedPage(response.json, list: list);
  }

  @override
  Future<AccountFollowTarget> resolveAccountFollowTarget(String roomId) async {
    var slug = roomId.trim().toLowerCase();
    return AccountFollowTarget(roomId: slug, accountUid: slug);
  }

  @override
  Future<void> followOnAccount(AccountFollowTarget target) =>
      _write(target, follow: true);

  @override
  Future<void> unfollowOnAccount(AccountFollowTarget target) =>
      _write(target, follow: false);

  Future<void> _write(
    AccountFollowTarget target, {
    required bool follow,
  }) async {
    if (token.isEmpty) {
      throw AccountFollowAuthError("请先登录 Kick 账号".t);
    }
    var slug =
        (target.accountUid.isNotEmpty ? target.accountUid : target.roomId)
            .trim()
            .toLowerCase();
    if (slug.isEmpty) {
      throw AccountFollowRejectedError("Kick 频道名为空".t);
    }
    var response = await AccountFollowHttp.send(
      follow ? "POST" : "DELETE",
      Uri.https(
        "kick.com",
        "/api/v2/channels/${Uri.encodeComponent(slug)}/follow",
      ),
      headers: _headers,
      channel: AccountFollowChannel.kick,
    );
    checkKickFollowWrite(response.statusCode, response.body);
  }
}

/// 拆开游标：没有时从 followed 的 0 开始
(String, String) parseKickFollowCursor(String? cursor) {
  if (cursor == null || cursor.isEmpty) {
    return ("f", "0");
  }
  var index = cursor.indexOf(":");
  if (index <= 0) {
    return ("f", cursor);
  }
  return (cursor.substring(0, index), cursor.substring(index + 1));
}

bool _isChallenge(String body) {
  var text = body.trimLeft().toLowerCase();
  return text.startsWith("<") ||
      text.contains("cf-chl") ||
      text.contains("blocked by security policy");
}

/// 读列表的状态码：401/419 登录失效，429 与 403（Cloudflare/Kasada 拦截）停止
void checkKickFollowStatus(int statusCode, String body) {
  if (statusCode == 200 && !_isChallenge(body)) {
    return;
  }
  if (statusCode == 401 || statusCode == 419) {
    throw AccountFollowAuthError("Kick 登录已失效，请重新登录".t);
  }
  if (statusCode == 429) {
    throw AccountFollowRiskError("Kick 提示请求太频繁(429)".t);
  }
  if (statusCode == 403 || _isChallenge(body)) {
    throw AccountFollowRiskError("Kick 拦截了请求({statusCode})，请稍后再试".tf({"statusCode": statusCode}));
  }
  throw CoreError("", statusCode: statusCode);
}

/// 解析一页（两个列表接口格式相同）。nextCursor 为 0、没有或本页为空时，
/// followed 读完后接着读 followed-page，后者读完就结束
AccountFollowPage parseKickFollowedPage(dynamic json, {String list = "f"}) {
  if (json is! Map || json["channels"] is! List) {
    throw CoreError("读取 Kick 关注失败：返回内容不对".t);
  }
  var channels = json["channels"] as List;
  var items = <AccountFollowItem>[];
  for (var item in channels.whereType<Map>()) {
    var slug = item["channel_slug"]?.toString().trim().toLowerCase() ?? "";
    if (slug.isEmpty) {
      continue;
    }
    var name = item["user_username"]?.toString().trim() ?? "";
    items.add(
      AccountFollowItem(
        roomId: slug,
        accountUid: slug,
        userName: name.isEmpty ? slug : name,
        face: item["profile_picture"]?.toString() ?? "",
        isLive: item["is_live"] == true,
      ),
    );
  }
  var next = json["nextCursor"];
  var nextValue = next is num ? next.toInt() : int.tryParse("$next") ?? 0;
  String? nextCursor;
  if (nextValue > 0 && channels.isNotEmpty) {
    nextCursor = "$list:$nextValue";
  } else if (list == "f") {
    nextCursor = "p:0";
  }
  return AccountFollowPage(items: items, nextCursor: nextCursor);
}

/// 关注/取关的状态码：2xx 和 422（已经是目标状态）算成功
void checkKickFollowWrite(int statusCode, String body) {
  if ((statusCode >= 200 && statusCode < 300 && !_isChallenge(body)) ||
      statusCode == 422) {
    return;
  }
  if (statusCode == 404) {
    throw AccountFollowRejectedError("Kick 频道不存在(404)".t);
  }
  checkKickFollowStatus(statusCode, body);
}
