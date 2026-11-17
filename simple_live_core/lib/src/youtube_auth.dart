// YouTube 的登录：谷歌官方授权（OAuth 设备码 + YouTube Data API）
// 或网页 Cookie（InnerTube 网页接口）。
//
// 约定：这里的类名、字段和方法签名是 App 与 core 之间的接口，实现可以改，签名不要改。

import 'dart:convert';

import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/youtube_data_api.dart';
import 'package:simple_live_core/src/common/youtube_innertube.dart';
import 'package:simple_live_core/src/common/youtube_parser.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 谷歌 OAuth 客户端（用户在 Google Cloud 自建，类型为“电视和受限输入设备”）
class YouTubeOAuthConfig {
  final String clientId;
  final String clientSecret;
  const YouTubeOAuthConfig({
    required this.clientId,
    required this.clientSecret,
  });

  bool get isValid => clientId.isNotEmpty && clientSecret.isNotEmpty;
}

/// OAuth 令牌
class YouTubeOAuthToken {
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  const YouTubeOAuthToken({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  /// 提前一分钟当作过期
  bool get expired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 1)));

  Map<String, dynamic> toJson() => {
    "accessToken": accessToken,
    "refreshToken": refreshToken,
    "expiresAt": expiresAt.millisecondsSinceEpoch,
  };

  factory YouTubeOAuthToken.fromJson(Map<String, dynamic> json) =>
      YouTubeOAuthToken(
        accessToken: json["accessToken"] as String? ?? "",
        refreshToken: json["refreshToken"] as String? ?? "",
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          json["expiresAt"] as int? ?? 0,
        ),
      );
}

/// 设备码授权：在浏览器打开 [verificationUrl] 输入 [userCode]
class YouTubeDeviceCode {
  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final Duration interval;
  final DateTime expiresAt;
  const YouTubeDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.interval,
    required this.expiresAt,
  });
}

/// 登录的 YouTube 频道
class YouTubeChannelInfo {
  final String id;
  final String title;
  final String avatar;
  const YouTubeChannelInfo({
    required this.id,
    required this.title,
    required this.avatar,
  });
}

/// 设备码轮询的中间状态
enum YouTubeTokenPollState {
  /// 已授权，返回了令牌
  success,

  /// 用户还没有确认
  pending,

  /// 轮询太快，需要放慢
  slowDown,
}

/// 谷歌官方授权
///
/// 授权范围用 `https://www.googleapis.com/auth/youtube`：设备码流程只允许
/// youtube 与 youtube.readonly 两个 YouTube 范围
/// （developers.google.com/identity/protocols/oauth2/limited-input-device 的 Allowed scopes），
/// 关注和取关（subscriptions.insert/delete）不能用 youtube.readonly，所以用 youtube。
///
/// 网络失败或谷歌服务器 5xx 时抛出 [YouTubeNetworkException]（不是 CoreError），
/// 调用方可以重试；其余错误抛出带中文说明的 CoreError。
class YouTubeOAuth {
  final YouTubeOAuthConfig config;
  YouTubeOAuth(this.config);

  static const String kScope = "https://www.googleapis.com/auth/youtube";
  static final Uri kDeviceCodeUrl = Uri.parse(
    "https://oauth2.googleapis.com/device/code",
  );
  static final Uri kTokenUrl = Uri.parse("https://oauth2.googleapis.com/token");

  /// 收到 slow_down 后放慢的轮询间隔，以及下次允许轮询的时间（按设备码）
  static final Map<String, Duration> _intervals = {};
  static final Map<String, DateTime> _nextPoll = {};

  void _checkConfig() {
    if (!config.isValid) {
      throw CoreError("请先填写 OAuth 客户端的 Client ID 和 Client Secret".t);
    }
  }

  /// 申请设备码
  Future<YouTubeDeviceCode> startDeviceFlow() async {
    _checkConfig();
    YouTubeHttpResponse response;
    try {
      response = await YouTubeHttp.postForm(kDeviceCodeUrl, {
        "client_id": config.clientId,
        "scope": kScope,
      });
    } on YouTubeNetworkException {
      throw CoreError("连接谷歌授权服务器失败，请检查网络".t);
    }
    return parseDeviceCodeResponse(response.statusCode, response.jsonBody);
  }

  /// 解析设备码响应
  static YouTubeDeviceCode parseDeviceCodeResponse(
    int statusCode,
    dynamic body, {
    DateTime? now,
  }) {
    if (statusCode == 200 && body is Map && body["device_code"] != null) {
      var time = now ?? DateTime.now();
      var interval = (body["interval"] as num?)?.toInt() ?? 5;
      var expiresIn = (body["expires_in"] as num?)?.toInt() ?? 1800;
      return YouTubeDeviceCode(
        deviceCode: body["device_code"].toString(),
        userCode: body["user_code"]?.toString() ?? "",
        verificationUrl:
            body["verification_url"]?.toString() ??
            body["verification_uri"]?.toString() ??
            "https://www.google.com/device",
        interval: Duration(seconds: interval < 1 ? 5 : interval),
        expiresAt: time.add(Duration(seconds: expiresIn)),
      );
    }
    throw oauthError(statusCode, body);
  }

  /// 解析轮询结果：成功返回令牌，等待中或需要放慢时返回对应状态，
  /// 拒绝、过期、客户端无效等抛出 CoreError，服务器错误抛出 [YouTubeNetworkException]
  static ({YouTubeTokenPollState state, YouTubeOAuthToken? token})
  parseTokenPollResponse(int statusCode, dynamic body, {DateTime? now}) {
    if (statusCode == 200 && body is Map && body["access_token"] != null) {
      return (
        state: YouTubeTokenPollState.success,
        token: parseTokenResponse(body, now: now),
      );
    }
    var error = body is Map ? body["error"]?.toString() ?? "" : "";
    if (error == "authorization_pending") {
      return (state: YouTubeTokenPollState.pending, token: null);
    }
    if (error == "slow_down") {
      return (state: YouTubeTokenPollState.slowDown, token: null);
    }
    throw oauthError(statusCode, body);
  }

  /// 令牌响应 → 令牌；刷新时响应中没有新的刷新令牌，沿用 [refreshToken]
  static YouTubeOAuthToken parseTokenResponse(
    Map body, {
    String refreshToken = "",
    DateTime? now,
  }) {
    var expiresIn = (body["expires_in"] as num?)?.toInt() ?? 3600;
    var newRefresh = body["refresh_token"]?.toString() ?? "";
    return YouTubeOAuthToken(
      accessToken: body["access_token"].toString(),
      refreshToken: newRefresh.isNotEmpty ? newRefresh : refreshToken,
      expiresAt: (now ?? DateTime.now()).add(Duration(seconds: expiresIn)),
    );
  }

  /// 谷歌授权接口的错误 → 中文提示；服务器错误抛出可重试的 [YouTubeNetworkException]
  static Object oauthError(
    int statusCode,
    dynamic body, {
    bool refreshing = false,
  }) {
    var error = body is Map ? body["error"]?.toString() ?? "" : "";
    var description = body is Map
        ? body["error_description"]?.toString() ?? ""
        : "";
    switch (error) {
      case "access_denied":
        return CoreError("你在谷歌授权页面拒绝了授权，要登录的话请重新开始".t);
      case "expired_token":
        return CoreError("授权码已过期，请重新开始登录".t);
      case "invalid_grant":
        return CoreError(
          refreshing
              ? "YouTube 授权已被撤销或已过期，请重新登录（OAuth 应用还在“测试”状态时，授权 7 天后会自动失效）".t
              : "授权码已失效或已被使用，请重新开始登录".t,
        );
      case "invalid_client":
        return CoreError(
          "Client ID 或 Client Secret 不对，请检查一下，并确认 OAuth 客户端类型是“电视和受限输入设备”".t,
        );
      case "unauthorized_client":
        return CoreError("这个 OAuth 客户端不能用设备码登录，请改用类型是“电视和受限输入设备”的客户端".t);
      case "invalid_scope":
        return CoreError("这个 OAuth 客户端不能申请 YouTube 权限".t);
      case "disabled_client":
        return CoreError("这个 OAuth 客户端已被停用".t);
      case "admin_policy_enforced":
        return CoreError("账号管理员不允许这项授权".t);
      case "org_internal":
        return CoreError("这个 OAuth 应用只允许本组织的账号使用，请在 Google Cloud 里把应用改为外部".t);
      case "invalid_request":
        return CoreError("授权请求无效：{description}".tf({"description": description}));
    }
    if (statusCode >= 500 || statusCode == 0) {
      return YouTubeNetworkException("谷歌授权服务器暂时不可用({statusCode})".tf({"statusCode": statusCode}));
    }
    var detail = [error, description].where((e) => e.isNotEmpty).join("：".t);
    return CoreError(detail.isNotEmpty ? "授权失败（{detail}）".tf({"detail": detail}) : "授权失败({statusCode})".tf({"statusCode": statusCode}));
  }

  /// 查询授权结果：用户还没确认时返回 null；拒绝或过期时抛出 CoreError
  ///
  /// 收到 slow_down 时把这个设备码的轮询间隔加 5 秒；调用得比间隔更早时，
  /// 先等到允许的时间再请求，因此 App 按 [YouTubeDeviceCode.interval] 轮询即可。
  /// 网络失败抛出 [YouTubeNetworkException]，可以重试。
  Future<YouTubeOAuthToken?> pollDeviceFlow(YouTubeDeviceCode code) async {
    _checkConfig();
    var key = code.deviceCode;
    if (DateTime.now().isAfter(code.expiresAt)) {
      _forget(key);
      throw CoreError("授权码已过期，请重新开始登录".t);
    }
    var wait = _nextPoll[key]?.difference(DateTime.now());
    if (wait != null && wait > Duration.zero) {
      await Future.delayed(wait);
    }
    var interval = _intervals[key] ?? code.interval;
    _nextPoll[key] = DateTime.now().add(interval);
    var response = await YouTubeHttp.postForm(kTokenUrl, {
      "client_id": config.clientId,
      "client_secret": config.clientSecret,
      "device_code": code.deviceCode,
      "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
    });
    ({YouTubeTokenPollState state, YouTubeOAuthToken? token}) result;
    try {
      result = parseTokenPollResponse(response.statusCode, response.jsonBody);
    } on CoreError {
      _forget(key);
      rethrow;
    }
    switch (result.state) {
      case YouTubeTokenPollState.success:
        _forget(key);
        return result.token;
      case YouTubeTokenPollState.pending:
        return null;
      case YouTubeTokenPollState.slowDown:
        var slower = interval + const Duration(seconds: 5);
        _intervals[key] = slower;
        _nextPoll[key] = DateTime.now().add(slower);
        return null;
    }
  }

  /// 设备码当前的轮询间隔（收到 slow_down 后会变长）
  static Duration currentInterval(YouTubeDeviceCode code) =>
      _intervals[code.deviceCode] ?? code.interval;

  static void _forget(String key) {
    _intervals.remove(key);
    _nextPoll.remove(key);
  }

  /// 用刷新令牌换新的访问令牌（刷新令牌不变时沿用旧的）
  ///
  /// 刷新令牌被撤销或过期时抛出 CoreError（需要重新登录）；
  /// 网络失败抛出 [YouTubeNetworkException]，令牌仍然有效。
  Future<YouTubeOAuthToken> refresh(YouTubeOAuthToken token) async {
    _checkConfig();
    if (token.refreshToken.isEmpty) {
      throw CoreError("缺少刷新令牌，请重新登录 YouTube".t);
    }
    var response = await YouTubeHttp.postForm(kTokenUrl, {
      "client_id": config.clientId,
      "client_secret": config.clientSecret,
      "refresh_token": token.refreshToken,
      "grant_type": "refresh_token",
    });
    var body = response.jsonBody;
    if (response.statusCode == 200 &&
        body is Map &&
        body["access_token"] != null) {
      return parseTokenResponse(body, refreshToken: token.refreshToken);
    }
    throw oauthError(response.statusCode, body, refreshing: true);
  }

  /// 读取授权账号的频道
  Future<YouTubeChannelInfo> fetchMyChannel(String accessToken) async {
    YouTubeHttpResponse response;
    try {
      response = await YouTubeDataApi.myChannel(accessToken);
    } on YouTubeNetworkException {
      throw CoreError("连接 YouTube 失败，请检查网络".t);
    }
    var body = response.jsonBody;
    if (response.statusCode != 200) {
      throw YouTubeDataApi.toError(response.statusCode, body);
    }
    var items = body is Map ? body["items"] : null;
    if (items is! List || items.isEmpty || items.first is! Map) {
      throw CoreError("这个谷歌账号还没有 YouTube 频道".t);
    }
    var item = items.first;
    var snippet = item["snippet"] ?? {};
    var thumbs = snippet["thumbnails"] ?? {};
    var avatar =
        thumbs["medium"]?["url"] ??
        thumbs["high"]?["url"] ??
        thumbs["default"]?["url"] ??
        "";
    return YouTubeChannelInfo(
      id: item["id"]?.toString() ?? "",
      title: snippet["title"]?.toString() ?? "",
      avatar: avatar.toString(),
    );
  }
}

/// 网页 Cookie 登录
class YouTubeCookieAuth {
  /// 校验 youtube.com 的 Cookie（需包含 SAPISID 等），返回登录的频道；无效时返回 null
  ///
  /// 调用网页端的账号菜单接口（account/account_menu），与网页右上角头像菜单相同。
  static Future<YouTubeChannelInfo?> verify(String cookie) async {
    if (youTubeCookieAuthorization(cookie) == null) {
      return null;
    }
    YouTubeHttpResponse response;
    try {
      response = await YouTubeHttp.send(
        "POST",
        Uri.parse(
          "${YouTubeInnertube.kOrigin}/youtubei/v1/account/account_menu?prettyPrint=false",
        ),
        headers: youTubeCookieHeaders(cookie),
        body: json.encode({
          "context": YouTubeInnertube.clientContext(YouTubeClient.web),
        }),
      );
    } on YouTubeNetworkException {
      throw CoreError("连接 YouTube 失败，请检查网络".t);
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      return null;
    }
    if (response.statusCode != 200) {
      throw CoreError("", statusCode: response.statusCode);
    }
    return parseAccountMenu(response.jsonBody);
  }

  /// 解析账号菜单：没有当前账号信息时（未登录）返回 null；
  /// 账号没有创建频道时 id 为空
  static YouTubeChannelInfo? parseAccountMenu(dynamic body) {
    var header = ytFindFirst(body, "activeAccountHeaderRenderer");
    if (header is! Map) {
      return null;
    }
    var id = "";
    for (var endpoint in ytFindAll(body, "browseEndpoint")) {
      var browseId = endpoint is Map ? endpoint["browseId"]?.toString() : null;
      if (browseId != null && YouTubeLink.isChannelId(browseId)) {
        id = browseId;
        break;
      }
    }
    return YouTubeChannelInfo(
      id: id,
      title: ytText(header["accountName"]),
      avatar: ytThumbnail(header["accountPhoto"], target: 88),
    );
  }
}

/// 当前使用的凭据，App 登录、退出或启动时设置到 YouTubeSite.credentials。
class YouTubeCredentials {
  final YouTubeOAuthConfig? oauthConfig;
  YouTubeOAuthToken? oauthToken;
  final String cookie;

  /// 访问令牌自动刷新后回调，App 据此保存新令牌
  final void Function(YouTubeOAuthToken token)? onTokenRefreshed;

  YouTubeCredentials({
    this.oauthConfig,
    this.oauthToken,
    this.cookie = "",
    this.onTokenRefreshed,
  });

  bool get hasOAuth => oauthConfig?.isValid == true && oauthToken != null;
  bool get hasCookie => cookie.isNotEmpty;
}
