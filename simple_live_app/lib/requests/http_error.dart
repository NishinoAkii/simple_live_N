import 'package:simple_live_app/i18n/i18n.dart';

class HttpError extends Error {
  /// 错误码
  final int statusCode;

  /// 错误信息
  final String message;

  HttpError(
    this.message, {
    this.statusCode = 0,
  });
  @override
  String toString() {
    if (statusCode != 0) {
      return statusCodeToString(statusCode);
    }

    return message;
  }

  String statusCodeToString(int statusCode) {
    switch (statusCode) {
      case 400:
        return "请求有误(400)".t;
      case 401:
        return "没有访问权限(401)".t;
      case 403:
        return "没有访问权限(403)".t;
      case 404:
        return "找不到要访问的内容(404)".t;
      case 500:
        return "服务器出错了(500)".t;
      case 502:
        return "服务器出错了(502)".t;
      case 503:
        return "服务器出错了(503)".t;
      default:
        return "连接服务器失败，请稍后再试({statusCode})".tf({"statusCode": statusCode});
    }
  }
}
