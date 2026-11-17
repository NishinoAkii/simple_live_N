import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:simple_live_core/src/common/kick_http.dart';
import 'package:simple_live_core/src/common/youtube_innertube.dart';
import 'package:simple_live_core/src/interface/live_account_follow_site.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 账号关注请求走哪条传输
enum AccountFollowChannel {
  /// 普通请求（哔哩哔哩、斗鱼、Twitch）
  generic,

  /// Kick：经 [KickHttp]（桌面端 curl、移动端系统网络栈）
  kick,

  /// YouTube：经 [YouTubeHttp]
  youtube,
}

class AccountFollowHttpResponse {
  final int statusCode;
  final String body;
  const AccountFollowHttpResponse(this.statusCode, this.body);

  /// 按 JSON 解析响应体，不是 JSON 时返回 null
  dynamic get json {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}

typedef AccountFollowTransport =
    Future<AccountFollowHttpResponse> Function(
      AccountFollowChannel channel,
      String method,
      Uri url,
      Map<String, String> headers,
      String? body,
    );

/// 读写账号关注的请求
///
/// 带着登录 Cookie/令牌，所以不经过 HttpClient（它的日志拦截器会记下请求头）。
/// 任何状态码都交给调用方判断。测试时用 [transport] 换成假的响应，不访问网络。
class AccountFollowHttp {
  /// 替换实际的请求实现（离线测试用）
  static AccountFollowTransport? transport;

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 20),
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
    ),
  );

  static Future<AccountFollowHttpResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
    AccountFollowChannel channel = AccountFollowChannel.generic,
  }) async {
    var custom = transport;
    if (custom != null) {
      return custom(channel, method, url, headers, body);
    }
    try {
      switch (channel) {
        case AccountFollowChannel.kick:
          var response = await KickHttp.send(
            method,
            url,
            headers: headers,
            body: body,
          );
          return AccountFollowHttpResponse(response.statusCode, response.body);
        case AccountFollowChannel.youtube:
          var response = await YouTubeHttp.send(
            method,
            url,
            headers: headers,
            body: body,
          );
          return AccountFollowHttpResponse(response.statusCode, response.body);
        case AccountFollowChannel.generic:
          var response = await _dio.requestUri<String>(
            url,
            data: body,
            options: Options(method: method, headers: headers),
          );
          return AccountFollowHttpResponse(
            response.statusCode ?? 0,
            response.data ?? "",
          );
      }
    } on AccountFollowNetworkError {
      rethrow;
    } catch (e) {
      throw AccountFollowNetworkError("网络请求失败（{host}）".tf({"host": url.host}));
    }
  }

  /// 表单编码
  static String form(Map<String, String> values) => values.entries
      .map(
        (e) =>
            "${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}",
      )
      .join("&");
}
