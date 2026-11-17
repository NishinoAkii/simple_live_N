import 'dart:convert';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// YouTube 账号（发送聊天消息用，观看不需要登录）
///
/// 两种登录可以同时存在，发送时 core 优先用官方授权：
/// - 谷歌官方授权：用户自建的 OAuth 客户端 + 设备码授权，走 YouTube Data API。
///   访问令牌由 core 自动刷新，刷新后通过 onTokenRefreshed 交回这里保存；
/// - 网页 Cookie：youtube.com 的登录 Cookie，走网页接口，不占 API 配额。
class YouTubeAccountService extends GetxService {
  static YouTubeAccountService get instance =>
      Get.find<YouTubeAccountService>();

  /// 任一方式已登录（可以发送）
  var logined = false.obs;
  var name = "未登录".obs;

  var clientId = "";
  var clientSecret = "";
  YouTubeOAuthToken? token;
  var cookie = "";

  /// 官方授权的频道（授权成功但没读到频道时为空）
  final oauthChannel = Rxn<YouTubeChannelInfo>();

  /// Cookie 登录的频道
  final cookieChannel = Rxn<YouTubeChannelInfo>();

  /// 账号有任何变化时加一（令牌等不是响应式的），界面据此刷新
  var version = 0.obs;

  YouTubeSite get site =>
      Sites.allSites[Constant.kYouTube]!.liveSite as YouTubeSite;

  YouTubeOAuthConfig get oauthConfig =>
      YouTubeOAuthConfig(clientId: clientId, clientSecret: clientSecret);

  bool get hasOAuth => oauthConfig.isValid && token != null;
  bool get hasCookie => cookie.isNotEmpty;

  LocalStorageService get _storage => LocalStorageService.instance;

  @override
  void onInit() {
    reload();
    super.onInit();
  }

  /// 从本地存储重新读取账号（启动和同步恢复设置后调用）
  void reload() {
    clientId = _storage.getValue(LocalStorageService.kYouTubeClientId, "");
    clientSecret =
        _storage.getValue(LocalStorageService.kYouTubeClientSecret, "");
    token = decodeToken(
        _storage.getValue(LocalStorageService.kYouTubeOAuthToken, ""));
    cookie = _storage.getValue(LocalStorageService.kYouTubeCookie, "");
    oauthChannel.value = token == null
        ? null
        : decodeChannel(
            _storage.getValue(LocalStorageService.kYouTubeOAuthChannel, ""));
    cookieChannel.value = cookie.isEmpty
        ? null
        : decodeChannel(
            _storage.getValue(LocalStorageService.kYouTubeCookieChannel, ""));
    _apply();
  }

  /// 把当前凭据交给 YouTubeSite，并刷新显示的名称
  void _apply() {
    site.credentials = YouTubeCredentials(
      oauthConfig: oauthConfig.isValid ? oauthConfig : null,
      oauthToken: token,
      cookie: cookie,
      onTokenRefreshed: _onTokenRefreshed,
    );
    // 账号关注的快照按频道分开
    site.followOAuthChannelId = hasOAuth ? oauthChannel.value?.id ?? "" : "";
    site.followCookieChannelId = hasCookie ? cookieChannel.value?.id ?? "" : "";
    logined.value = hasOAuth || hasCookie;
    var channel = (hasOAuth ? oauthChannel.value : null) ??
        (hasCookie ? cookieChannel.value : null);
    if (!logined.value) {
      name.value = "未登录";
    } else if (channel != null && channel.title.isNotEmpty) {
      name.value = channel.title;
    } else {
      name.value = "已登录";
    }
    version.value++;
  }

  /// core 刷新访问令牌后回调：凭据里的令牌 core 已经换好，这里只负责保存
  void _onTokenRefreshed(YouTubeOAuthToken value) {
    // 刷新请求返回前已经退出登录时不再存回去
    if (token == null) {
      return;
    }
    token = value;
    site.credentials.oauthToken = value;
    _storage.setValue(
        LocalStorageService.kYouTubeOAuthToken, jsonEncode(value.toJson()));
  }

  /// 保存 OAuth 客户端；换了客户端 ID 时旧令牌无法再刷新，一并退出授权
  void setOAuthConfig(String id, String secret) {
    id = id.trim();
    secret = secret.trim();
    if (id == clientId && secret == clientSecret) {
      return;
    }
    if (id != clientId && token != null) {
      _clearOAuthLogin();
    }
    clientId = id;
    clientSecret = secret;
    _storage.setValue(LocalStorageService.kYouTubeClientId, id);
    _storage.setValue(LocalStorageService.kYouTubeClientSecret, secret);
    _apply();
  }

  /// 设备码授权成功后保存令牌和频道
  void loginWithOAuth(YouTubeOAuthToken value, YouTubeChannelInfo? channel) {
    token = value;
    oauthChannel.value = channel;
    _storage.setValue(
        LocalStorageService.kYouTubeOAuthToken, jsonEncode(value.toJson()));
    _storage.setValue(
        LocalStorageService.kYouTubeOAuthChannel, encodeChannel(channel));
    _apply();
  }

  /// 校验网页 Cookie 并保存，返回 true 表示登录成功
  Future<bool> loginWithCookie(String value) async {
    var input = normalizeCookie(value);
    if (input.isEmpty) {
      return false;
    }
    if (!hasApiSid(input)) {
      SmartDialog.showToast(
          "Cookie 里没有 SAPISID 或 __Secure-3PAPISID，请确认已登录并复制完整".t);
      return false;
    }
    try {
      var channel = await YouTubeCookieAuth.verify(input);
      if (channel == null) {
        SmartDialog.showToast("Cookie 无效或已过期，请重新登录后再复制".t);
        return false;
      }
      cookie = input;
      cookieChannel.value = channel;
      _storage.setValue(LocalStorageService.kYouTubeCookie, cookie);
      _storage.setValue(
          LocalStorageService.kYouTubeCookieChannel, encodeChannel(channel));
      _apply();
      SmartDialog.showToast("YouTube 登录成功：{title}".tf({"title": channel.title}));
      return true;
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("检查 Cookie 失败：{p}".tf({"p": e is CoreError ? e.message : e}));
      return false;
    }
  }

  void _clearOAuthLogin() {
    token = null;
    oauthChannel.value = null;
    _storage.setValue(LocalStorageService.kYouTubeOAuthToken, "");
    _storage.setValue(LocalStorageService.kYouTubeOAuthChannel, "");
  }

  /// 退出官方授权。Client ID 和 Secret 是用户自建的配置，不是登录状态，保留下来方便重新授权
  void logoutOAuth() {
    _clearOAuthLogin();
    _apply();
  }

  void logoutCookie() {
    cookie = "";
    cookieChannel.value = null;
    _storage.setValue(LocalStorageService.kYouTubeCookie, "");
    _storage.setValue(LocalStorageService.kYouTubeCookieChannel, "");
    _apply();
  }

  /// 整理粘贴的 Cookie：去掉开头的“cookie:”和换行，统一成“a=b; c=d”
  static String normalizeCookie(String value) {
    var text = value.trim().replaceFirst(
          RegExp(r'^cookie\s*:\s*', caseSensitive: false),
          "",
        );
    return text
        .split(RegExp(r'[;\r\n]+'))
        .map((e) => e.trim())
        .where((e) => e.contains('='))
        .join("; ");
  }

  /// 网页接口的授权头要用 SAPISID（或 __Secure-3PAPISID）计算，没有就发不了
  static bool hasApiSid(String cookie) =>
      RegExp(r'(^|;\s*)(SAPISID|__Secure-3PAPISID)=[^;\s]+').hasMatch(cookie);

  static YouTubeOAuthToken? decodeToken(String value) {
    if (value.isEmpty) {
      return null;
    }
    try {
      var token = YouTubeOAuthToken.fromJson(
          (jsonDecode(value) as Map).cast<String, dynamic>());
      return token.refreshToken.isEmpty && token.accessToken.isEmpty
          ? null
          : token;
    } catch (e) {
      Log.logPrint(e);
      return null;
    }
  }

  static String encodeChannel(YouTubeChannelInfo? channel) {
    if (channel == null) {
      return "";
    }
    return jsonEncode({
      "id": channel.id,
      "title": channel.title,
      "avatar": channel.avatar,
    });
  }

  static YouTubeChannelInfo? decodeChannel(String value) {
    if (value.isEmpty) {
      return null;
    }
    try {
      var json = jsonDecode(value) as Map;
      return YouTubeChannelInfo(
        id: json["id"]?.toString() ?? "",
        title: json["title"]?.toString() ?? "",
        avatar: json["avatar"]?.toString() ?? "",
      );
    } catch (e) {
      Log.logPrint(e);
      return null;
    }
  }
}
