
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/youtube_innertube.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// YouTube Data API v3（官方授权后使用）
class YouTubeDataApi {

  static const String kBase = "https://www.googleapis.com/youtube/v3";

  static Map<String, String> _headers(String accessToken) => {
    "Authorization": "Bearer $accessToken",
    "Accept": "application/json",
  };

  /// 授权账号的频道（channels.list?mine=true）
  static Future<YouTubeHttpResponse> myChannel(String accessToken) {
    return YouTubeHttp.send(
      "GET",
      Uri.parse("$kBase/channels?part=snippet&mine=true"),
      headers: _headers(accessToken),
    );
  }

  /// 错误原因（error.errors[0].reason，没有时用 error.status）
  static String errorReason(dynamic body) {
    var error = body is Map ? body["error"] : null;
    if (error is! Map) {
      return "";
    }
    var errors = error["errors"];
    if (errors is List && errors.isNotEmpty && errors.first is Map) {
      var reason = errors.first["reason"]?.toString() ?? "";
      if (reason.isNotEmpty) {
        return reason;
      }
    }
    var details = error["details"];
    if (details is List) {
      for (var item in details) {
        var reason = item is Map ? item["reason"]?.toString() ?? "" : "";
        if (reason.isNotEmpty) {
          return reason;
        }
      }
    }
    return error["status"]?.toString() ?? "";
  }

  /// 把 API 的错误响应转换为中文提示
  static CoreError toError(int statusCode, dynamic body) {
    var reason = errorReason(body);
    var message = body is Map
        ? (body["error"]?["message"]?.toString() ?? "")
        : "";
    switch (reason) {
      case "insufficientPermissions":
      case "ACCESS_TOKEN_SCOPE_INSUFFICIENT":
        return CoreError("授权时没有给管理 YouTube 账号的权限，请重新登录并允许所有权限".t);
      case "accessNotConfigured":
      case "SERVICE_DISABLED":
        return CoreError("这个 Google Cloud 项目还没启用 YouTube Data API v3，请到控制台启用".t);
    }
    if (statusCode == 401) {
      return CoreError("YouTube 授权已失效，请重新登录".t);
    }
    return CoreError(
      message.isNotEmpty
          ? "YouTube 报错：{message}".tf({"message": message})
          : "YouTube 报错({statusCode})".tf({"statusCode": statusCode}),
    );
  }
}
