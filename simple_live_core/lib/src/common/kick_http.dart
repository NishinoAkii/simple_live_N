import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/core_text.dart';

class KickHttpResponse {
  final int statusCode;
  final String body;
  KickHttpResponse(this.statusCode, this.body);
}

/// 发送一次 HTTP 请求
typedef KickHttpRequest =
    Future<KickHttpResponse> Function(
      String method,
      Uri url,
      Map<String, String> headers,
      String? body,
    );

/// Kick 网页接口的 HTTP 传输
///
/// kick.com 位于 Cloudflare 之后，会按 TLS 指纹拦截 dart:io 发出的请求
/// （返回 403 "Request blocked by security policy"）。系统自带的 TLS 实现
/// 不受影响，因此桌面端默认调用系统 curl；移动端由应用通过 [request]
/// 注入平台原生实现。
class KickHttp {
  /// 应用注入的原生请求实现，优先使用
  static KickHttpRequest? request;

  static Future<KickHttpResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    if (request != null) {
      return request!(method, url, headers, body);
    }
    return sendDefault(method, url, headers: headers, body: body);
  }

  /// 不经过注入实现的默认请求：桌面端用系统 curl，其余用 dart:io
  static Future<KickHttpResponse> sendDefault(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      try {
        return await _curl(method, url, headers, body);
      } on ProcessException {
        // 没有 curl 时退回 dart:io
      }
    }
    return _dio(method, url, headers, body);
  }

  static Future<KickHttpResponse> _curl(
    String method,
    Uri url,
    Map<String, String> headers,
    String? body,
  ) async {
    var args = <String>[
      "-s",
      "--compressed",
      "--max-time",
      "20",
      "-X",
      method,
      "-w",
      "\n%{http_code}",
    ];
    headers.forEach((key, value) {
      args.addAll(["-H", "$key: $value"]);
    });
    if (body != null) {
      args.addAll(["--data-binary", "@-"]);
    }
    args.add(url.toString());
    var process = await Process.start(
      Platform.isWindows ? "curl.exe" : "curl",
      args,
    );
    if (body != null) {
      process.stdin.add(utf8.encode(body));
    }
    await process.stdin.close();
    var output = process.stdout.transform(utf8.decoder).join();
    process.stderr.drain<void>();
    var exitCode = await process.exitCode;
    var text = await output;
    var split = text.lastIndexOf("\n");
    var status = int.tryParse(split >= 0 ? text.substring(split + 1) : "") ?? 0;
    if (exitCode != 0 && status == 0) {
      throw CoreError("请求 Kick 失败(curl {exitCode})".tf({"exitCode": exitCode}));
    }
    return KickHttpResponse(status, split >= 0 ? text.substring(0, split) : "");
  }

  static Future<KickHttpResponse> _dio(
    String method,
    Uri url,
    Map<String, String> headers,
    String? body,
  ) async {
    try {
      var response = await HttpClient.instance.dio.requestUri<String>(
        url,
        data: body,
        options: Options(
          method: method,
          headers: headers,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      return KickHttpResponse(response.statusCode ?? 0, response.data ?? "");
    } catch (e) {
      throw CoreError("请求 Kick 失败".t);
    }
  }
}
