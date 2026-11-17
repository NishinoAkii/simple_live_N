import 'package:simple_live_core/src/common/core_text.dart';

class CoreError extends Error {
  /// 错误码
  final int statusCode;

  /// 错误信息
  final String message;

  CoreError(
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
      case 444:
        // 抖音访问太频繁时直接断开，不回内容
        return "访问太频繁，平台暂时拒绝了请求(444)，请稍后再试".t;
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

/// 平台要求登录后才能使用（如抖音搜索），App 可以据此提示去登录
class LoginRequiredError extends CoreError {
  /// 平台 id
  final String siteId;

  LoginRequiredError(super.message, {required this.siteId});
}
