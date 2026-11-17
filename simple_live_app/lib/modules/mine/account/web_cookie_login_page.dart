import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/log.dart';

/// 网页登录参数：登录后从 Cookie 中读取令牌
class WebCookieLoginArgs {
  final String title;
  final String loginUrl;

  /// 读取 Cookie 用的地址
  final String cookieUrl;

  /// 保存令牌的 Cookie 名称
  final String cookieName;

  /// 登录提示
  final String tip;

  /// 拿到 Cookie 值后的处理，返回 true 表示登录成功
  final Future<bool> Function(String value) onCookie;

  /// 交给 [onCookie] 的是 [cookieUrl] 下的全部 Cookie（name=value; …），
  /// 而不只是 [cookieName] 的值：YouTube 要 SAPISID、SID 等多个 Cookie 一起用
  final bool wholeCookie;

  /// 除 [cookieName] 外，出现这些 Cookie 也算登录完成
  final List<String> otherCookieNames;

  WebCookieLoginArgs({
    required this.title,
    required this.loginUrl,
    required this.cookieUrl,
    required this.cookieName,
    required this.tip,
    required this.onCookie,
    this.wholeCookie = false,
    this.otherCookieNames = const [],
  });
}

class WebCookieLoginController extends GetxController {
  final WebCookieLoginArgs args;
  WebCookieLoginController(this.args);

  final CookieManager cookieManager = CookieManager.instance();
  Timer? _timer;
  bool _checking = false;
  bool _done = false;

  @override
  void onInit() {
    // 登录弹窗不一定触发页面跳转，定时检查 Cookie
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => check());
    super.onInit();
  }

  Future<void> check() async {
    if (_checking || _done) {
      return;
    }
    _checking = true;
    try {
      var value = await readCookie();
      if (value.isNotEmpty) {
        _done = true;
        _timer?.cancel();
        var ok = await args.onCookie(value);
        if (ok) {
          Get.back();
        } else {
          _done = false;
        }
      }
    } catch (e) {
      Log.logPrint(e);
    } finally {
      _checking = false;
    }
  }

  /// 读取登录后的令牌；还没登录完成时返回空
  Future<String> readCookie() async {
    var url = WebUri(args.cookieUrl);
    if (!args.wholeCookie) {
      var cookie =
          await cookieManager.getCookie(url: url, name: args.cookieName);
      return cookie?.value?.toString() ?? "";
    }
    var cookies = await cookieManager.getCookies(url: url);
    var names = {args.cookieName, ...args.otherCookieNames};
    var ready = cookies.any(
      (e) => names.contains(e.name) && (e.value?.toString() ?? "").isNotEmpty,
    );
    if (!ready) {
      return "";
    }
    return cookies.map((e) => "${e.name}=${e.value ?? ""}").join("; ");
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }
}

class WebCookieLoginPage extends StatelessWidget {
  const WebCookieLoginPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var args = Get.arguments as WebCookieLoginArgs;
    var controller = Get.put(WebCookieLoginController(args));
    return Scaffold(
      appBar: AppBar(
        title: Text(args.title),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: AppStyle.edgeInsetsA12,
            child: Text(
              args.tip,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(args.loginUrl)),
              initialSettings: InAppWebViewSettings(
                userAgent:
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
              ),
              onLoadStop: (_, __) => controller.check(),
            ),
          ),
        ],
      ),
    );
  }
}
