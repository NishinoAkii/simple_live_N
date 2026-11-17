import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// InnerTube 客户端类型
///
/// 不同客户端返回的内容不同（2026-10 实测，匿名、不带 PO Token）：
/// - [web]：列表、搜索、聊天都正常；播放接口返回 UNPLAYABLE，但仍带有
///   videoDetails 与 microformat（开播时间、是否正在直播），只用来读信息。
/// - [mweb]：频道页响应体积只有网页端的三分之一，读频道信息用它。
/// - [androidVr]：唯一能匿名拿到直播 hlsManifestUrl 的客户端，
///   必须带 visitorData，否则返回“请登录以确认你不是机器人”。
///   IOS（20.x/21.x）只给 SABR，TVHTML5、MWEB 提示需要刷新页面。
enum YouTubeClient { web, mweb, androidVr }

/// YouTube 网页内部接口（InnerTube）
class YouTubeInnertube {
  static const String kOrigin = "https://www.youtube.com";

  static const String kWebUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

  static const String kMwebUserAgent =
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1";

  static const String kVrClientVersion = "1.65.10";

  /// 播放地址与分片按这个 UA 签发，播放器请求时也带上它
  static const String kVrUserAgent =
      "com.google.android.apps.youtube.vr.oculus/$kVrClientVersion (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip";

  /// 网页端版本号；读取网页时会更新为页面中的最新值
  static String webClientVersion = "2.20261023.01.00";

  /// 界面语言：影响“直播”等界面文字与贴纸说明，不影响标题
  static String hl = "zh-CN";

  /// 欧洲地区匿名访问网页会跳转到同意页面，带上“全部拒绝”的同意 Cookie 可直接访问
  static const String kConsentCookie = "SOCS=CAI";

  static String? _visitorData;
  static DateTime _visitorDataTime = DateTime.fromMillisecondsSinceEpoch(0);

  static Map<String, dynamic> clientContext(
    YouTubeClient client, {
    String? visitorData,
  }) {
    Map<String, dynamic> info;
    switch (client) {
      case YouTubeClient.web:
        info = {"clientName": "WEB", "clientVersion": webClientVersion};
        break;
      case YouTubeClient.mweb:
        info = {"clientName": "MWEB", "clientVersion": webClientVersion};
        break;
      case YouTubeClient.androidVr:
        info = {
          "clientName": "ANDROID_VR",
          "clientVersion": kVrClientVersion,
          "deviceMake": "Oculus",
          "deviceModel": "Quest 3",
          "androidSdkVersion": 32,
          "osName": "Android",
          "osVersion": "12L",
        };
        break;
    }
    info["hl"] = hl;
    if (visitorData != null && visitorData.isNotEmpty) {
      info["visitorData"] = visitorData;
    }
    return {"client": info};
  }

  static Map<String, String> clientHeaders(YouTubeClient client) {
    switch (client) {
      case YouTubeClient.web:
        return {
          "User-Agent": kWebUserAgent,
          "Origin": kOrigin,
          "X-Youtube-Client-Name": "1",
          "X-Youtube-Client-Version": webClientVersion,
        };
      case YouTubeClient.mweb:
        return {
          "User-Agent": kMwebUserAgent,
          "Origin": kOrigin,
          "X-Youtube-Client-Name": "2",
          "X-Youtube-Client-Version": webClientVersion,
        };
      case YouTubeClient.androidVr:
        return {
          "User-Agent": kVrUserAgent,
          "X-Youtube-Client-Name": "28",
          "X-Youtube-Client-Version": kVrClientVersion,
        };
    }
  }

  /// 匿名调用 InnerTube 接口，[body] 中不需要 context
  static Future<dynamic> post(
    String endpoint,
    Map<String, dynamic> body, {
    YouTubeClient client = YouTubeClient.web,
    String? visitorData,
    CancelToken? cancel,
  }) async {
    dynamic result;
    for (var attempt = 0; ; attempt++) {
      try {
        result = await HttpClient.instance.postJson(
          "$kOrigin/youtubei/v1/$endpoint",
          queryParameters: {"prettyPrint": "false"},
          data: {
            "context": clientContext(client, visitorData: visitorData),
            ...body,
          },
          header: {
            ...clientHeaders(client),
            "Content-Type": "application/json",
            "Cookie": kConsentCookie,
          },
          cancel: cancel,
        );
        break;
      } on CoreError catch (e) {
        // 这些接口都只读：连接失败、超时（statusCode 为 0）时重试一次；
        // 服务端返回错误或请求被取消时不重试
        if (e.statusCode != 0 ||
            attempt >= 1 ||
            (cancel?.isCancelled ?? false)) {
          rethrow;
        }
      }
    }
    if (result is String) {
      result = json.decode(result);
    }
    return result;
  }

  /// 匿名访客标识
  ///
  /// ANDROID_VR 播放接口缺少它会被当作机器人。只需要几百字节的 visitor_id 接口
  /// 就能拿到，不必下载整个首页。一天内复用。
  static Future<String> visitorData({bool refresh = false}) async {
    var cached = _visitorData;
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(_visitorDataTime) <
            const Duration(hours: 24)) {
      return cached;
    }
    var result = await post("visitor_id", {});
    var value = result?["responseContext"]?["visitorData"]?.toString() ?? "";
    if (value.isEmpty) {
      throw CoreError("无法获取 YouTube 访客标识".t);
    }
    _visitorData = value;
    _visitorDataTime = DateTime.now();
    return value;
  }

  /// 读取网页（如 live_chat 页面），[cookie] 为空时匿名
  static Future<String> getPage(
    String url, {
    String cookie = "",
    CancelToken? cancel,
  }) async {
    var headers = {
      "User-Agent": kWebUserAgent,
      "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    };
    if (cookie.isEmpty) {
      var text = await HttpClient.instance.getText(
        url,
        header: {...headers, "Cookie": kConsentCookie},
        cancel: cancel,
      );
      updateClientVersion(text);
      return text;
    }
    // 带 Cookie 的请求不经过 HttpClient，避免日志记下 Cookie
    var response = await YouTubeHttp.send(
      "GET",
      Uri.parse(url),
      headers: {...headers, "Cookie": cookie},
    );
    if (response.statusCode != 200) {
      throw CoreError("", statusCode: response.statusCode);
    }
    updateClientVersion(response.body);
    return response.body;
  }

  /// 从网页中读取最新的网页端版本号
  static void updateClientVersion(String html) {
    var match = RegExp(
      r'"INNERTUBE_CLIENT_VERSION":"([0-9.]+)"',
    ).firstMatch(html);
    if (match != null) {
      webClientVersion = match.group(1)!;
    }
  }
}

/// 解析 Cookie 字符串（“a=1; b=2”）
Map<String, String> parseYouTubeCookie(String cookie) {
  var result = <String, String>{};
  for (var part in cookie.split(';')) {
    var index = part.indexOf('=');
    if (index <= 0) {
      continue;
    }
    var name = part.substring(0, index).trim();
    var value = part.substring(index + 1).trim();
    if (name.isNotEmpty) {
      result[name] = value;
    }
  }
  return result;
}

/// 计算 SAPISIDHASH：`<时间戳>_<sha1("<时间戳> <SAPISID> <origin>")>`
String youTubeSapisidHash(
  String sapisid, {
  required int timestamp,
  String origin = YouTubeInnertube.kOrigin,
}) {
  var digest = sha1.convert(utf8.encode("$timestamp $sapisid $origin"));
  return "${timestamp}_$digest";
}

/// 网页端带 Cookie 调用 InnerTube 时的 Authorization 头
///
/// SAPISID 不存在时用 __Secure-3PAPISID（两者的值相同，部分浏览器导出时只有后者）；
/// 同时附上网页端也会发送的 1P/3P 变体。Cookie 中没有可用值时返回 null。
String? youTubeCookieAuthorization(String cookie, {int? timestamp}) {
  var cookies = parseYouTubeCookie(cookie);
  var sapisid = cookies["SAPISID"] ?? cookies["__Secure-3PAPISID"];
  if (sapisid == null || sapisid.isEmpty) {
    return null;
  }
  var ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  var parts = ["SAPISIDHASH ${youTubeSapisidHash(sapisid, timestamp: ts)}"];
  var p1 = cookies["__Secure-1PAPISID"];
  if (p1 != null && p1.isNotEmpty) {
    parts.add("SAPISID1PHASH ${youTubeSapisidHash(p1, timestamp: ts)}");
  }
  var p3 = cookies["__Secure-3PAPISID"];
  if (p3 != null && p3.isNotEmpty) {
    parts.add("SAPISID3PHASH ${youTubeSapisidHash(p3, timestamp: ts)}");
  }
  return parts.join(" ");
}

/// 带 Cookie 调用 InnerTube 时需要的请求头
Map<String, String> youTubeCookieHeaders(String cookie) {
  var authorization = youTubeCookieAuthorization(cookie);
  if (authorization == null) {
    throw CoreError("Cookie 中缺少 SAPISID，请重新获取完整的 YouTube Cookie".t);
  }
  return {
    ...YouTubeInnertube.clientHeaders(YouTubeClient.web),
    "Authorization": authorization,
    "X-Origin": YouTubeInnertube.kOrigin,
    "X-Goog-AuthUser": "0",
    "Cookie": cookie,
    "Content-Type": "application/json",
  };
}

class YouTubeHttpResponse {
  final int statusCode;
  final String body;
  YouTubeHttpResponse(this.statusCode, this.body);

  /// 按 JSON 解析响应体，不是 JSON 时返回 null
  dynamic get jsonBody {
    try {
      return json.decode(body);
    } catch (_) {
      return null;
    }
  }
}

/// 网络层失败（连接失败、超时、服务器 5xx 等可重试的错误）
///
/// 故意不继承 CoreError：App 把 CoreError 当作最终结果显示，
/// 这类错误则应当重试。
class YouTubeNetworkException implements Exception {
  final String message;
  YouTubeNetworkException(this.message);

  @override
  String toString() => message;
}

typedef YouTubeHttpTransport =
    Future<YouTubeHttpResponse> Function(
      String method,
      Uri url,
      Map<String, String> headers,
      String? body,
    );

/// 携带凭据（OAuth 令牌、客户端密钥、Cookie）的请求
///
/// 不使用 HttpClient：它的日志拦截器会记录请求头和请求体。
/// 任何状态码都返回给调用方，由调用方解析错误原因。
class YouTubeHttp {
  /// 替换实际的请求实现（离线测试用）
  static YouTubeHttpTransport? transport;

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 20),
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
    ),
  );

  static Future<YouTubeHttpResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    var custom = transport;
    if (custom != null) {
      return custom(method, url, headers, body);
    }
    try {
      var response = await _dio.requestUri<String>(
        url,
        data: body,
        options: Options(method: method, headers: headers),
      );
      return YouTubeHttpResponse(response.statusCode ?? 0, response.data ?? "");
    } catch (e) {
      throw YouTubeNetworkException("网络请求失败（{host}）".tf({"host": url.host}));
    }
  }

  /// 提交表单
  static Future<YouTubeHttpResponse> postForm(
    Uri url,
    Map<String, String> form,
  ) {
    return send(
      "POST",
      url,
      headers: {"Content-Type": "application/x-www-form-urlencoded"},
      body: form.entries
          .map(
            (e) =>
                "${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}",
          )
          .join("&"),
    );
  }
}
