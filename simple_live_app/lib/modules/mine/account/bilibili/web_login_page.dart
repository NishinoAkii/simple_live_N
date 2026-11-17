import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/mine/account/bilibili/web_login_controller.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class BiliBiliWebLoginPage extends GetView<BiliBiliWebLoginController> {
  const BiliBiliWebLoginPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("哔哩哔哩账号登录".t),
        actions: [
          TextButton.icon(
            onPressed: controller.toQRLogin,
            icon: const Icon(Icons.qr_code),
            label: Text("二维码登录".t),
          ),
        ],
      ),
      body: InAppWebView(
        onWebViewCreated: controller.onWebViewCreated,
        onLoadStop: controller.onLoadStop,
        initialSettings: InAppWebViewSettings(
          userAgent:
              "Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1 Edg/118.0.0.0",
          useShouldOverrideUrlLoading: true,
        ),
        shouldOverrideUrlLoading: (webController, navigationAction) async {
          var uri = navigationAction.request.url;
          if (uri == null) {
            return NavigationActionPolicy.ALLOW;
          }
          if (uri.host == "m.bilibili.com" || uri.host == "www.bilibili.com") {
            await controller.logined();
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        },
      ),
    );
  }
}
