import 'dart:io';

import 'package:flutter/services.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 通过系统网络栈发送请求
///
/// Kick 会按 TLS 指纹拦截 dart:io 的请求，移动端和 macOS 改用系统自带的
/// HttpURLConnection / URLSession（原生代码见 MainActivity、AppDelegate、
/// MainFlutterWindow）。Windows/Linux 由核心库调用系统 curl。
class NativeHttp {
  static const _channel = MethodChannel("simple_live/native_http");

  static void install() {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      KickHttp.request = _request;
    }
  }

  static Future<KickHttpResponse> _request(
    String method,
    Uri url,
    Map<String, String> headers,
    String? body,
  ) async {
    try {
      var result = await _channel.invokeMapMethod<String, dynamic>("request", {
        "method": method,
        "url": url.toString(),
        "headers": headers,
        "body": body,
      });
      return KickHttpResponse(
        (result?["status"] as num?)?.toInt() ?? 0,
        result?["body"]?.toString() ?? "",
      );
    } on MissingPluginException {
      return KickHttp.sendDefault(method, url, headers: headers, body: body);
    } on PlatformException catch (e) {
      Log.w("原生请求失败：${e.message}");
      throw CoreError("网络请求失败：{p}".tf({"p": e.message ?? e.code}));
    }
  }
}
