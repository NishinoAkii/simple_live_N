import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/mine/account/web_cookie_login_page.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/kick_account_service.dart';
import 'package:simple_live_app/services/live_source_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class AccountController extends GetxController {
  @override
  void onInit() {
    super.onInit();
    // 直播源的登录状态（脚本的 account() 可能要联网，打开这页时再读）
    if (LiveSourceService.registered) {
      LiveSourceService.instance.refreshAccounts();
    }
  }

  void bilibiliTap() async {
    if (BiliBiliAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出哔哩哔哩账号吗？".t, title: "退出登录".t);
      if (result) {
        BiliBiliAccountService.instance.logout();
      }
    } else {
      //AppNavigator.toBiliBiliLogin();
      bilibiliLogin();
    }
  }

  void bilibiliLogin() {
    Utils.showBottomSheet(
      title: "登录哔哩哔哩".t,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Visibility(
            visible: Platform.isAndroid || Platform.isIOS,
            child: ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: Text("网页登录".t),
              subtitle: Text("输入账号和密码登录".t),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                Get.toNamed(RoutePath.kBiliBiliWebLogin);
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code),
            title: Text("扫码登录".t),
            subtitle: Text("用哔哩哔哩 App 扫码登录".t),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              Get.toNamed(RoutePath.kBiliBiliQRLogin);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text("Cookie 登录".t),
            subtitle: Text("手动粘贴 Cookie 登录".t),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              doBiliBiliCookieLogin();
            },
          ),
        ],
      ),
    );
  }

  void doBiliBiliCookieLogin() async {
    var cookie = await Utils.showEditTextDialog(
      "",
      title: "Cookie 登录".t,
      hintText: "粘贴 Cookie".t,
    );
    if (cookie == null || cookie.isEmpty) {
      return;
    }
    BiliBiliAccountService.instance.setCookie(cookie);
    await BiliBiliAccountService.instance.loadUserInfo();
  }

  void douyuTap() async {
    if (DouyuAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出斗鱼账号吗？".t, title: "退出登录".t);
      if (result) {
        DouyuAccountService.instance.logout();
      }
    } else {
      Get.toNamed(RoutePath.kDouyuScanLogin);
    }
  }

  /// 是否可以使用网页登录（需要系统 WebView）
  bool get supportWebLogin =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  void twitchTap() async {
    if (TwitchAccountService.instance.logined.value) {
      var result =
          await Utils.showAlertDialog("确定要退出 Twitch 账号吗？".t, title: "退出登录".t);
      if (result) {
        TwitchAccountService.instance.logout();
      }
      return;
    }
    tokenLoginSheet(
      title: "登录 Twitch".t,
      webArgs: WebCookieLoginArgs(
        title: "Twitch 账号登录".t,
        loginUrl: "https://www.twitch.tv/login",
        cookieUrl: "https://www.twitch.tv",
        cookieName: "auth-token",
        tip: "登录完成后会自动返回".t,
        onCookie: TwitchAccountService.instance.loginWithToken,
      ),
      tokenHint:
          "浏览器登录 twitch.tv 后按 F12 → 应用(Application) → Cookie → https://www.twitch.tv，复制 auth-token 的值".t,
      onToken: TwitchAccountService.instance.loginWithToken,
    );
  }

  void kickTap() async {
    if (KickAccountService.instance.logined.value) {
      var result =
          await Utils.showAlertDialog("确定要退出 Kick 账号吗？".t, title: "退出登录".t);
      if (result) {
        KickAccountService.instance.logout();
      }
      return;
    }
    tokenLoginSheet(
      title: "登录 Kick".t,
      webArgs: WebCookieLoginArgs(
        title: "Kick 账号登录".t,
        loginUrl: "https://kick.com/",
        cookieUrl: "https://kick.com",
        cookieName: "session_token",
        tip: "点右上角 Log In 登录，完成后自动返回".t,
        onCookie: KickAccountService.instance.loginWithToken,
      ),
      tokenHint:
          "浏览器登录 kick.com 后按 F12 → 应用(Application) → Cookie → https://kick.com，复制 session_token 的值".t,
      onToken: KickAccountService.instance.loginWithToken,
    );
  }

  void tokenLoginSheet({
    required String title,
    required WebCookieLoginArgs webArgs,
    required String tokenHint,
    required Future<bool> Function(String) onToken,
  }) {
    Utils.showBottomSheet(
      title: title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Visibility(
            visible: supportWebLogin,
            child: ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: Text("网页登录".t),
              subtitle: Text("在 App 里打开网页登录".t),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                Get.toNamed(RoutePath.kWebCookieLogin, arguments: webArgs);
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text("Cookie 登录".t),
            subtitle: Text("粘贴浏览器 Cookie 里的一项".t),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              Get.back();
              var token = await showTokenDialog(tokenHint);
              if (token == null || token.trim().isEmpty) {
                return;
              }
              SmartDialog.showLoading(msg: "");
              try {
                await onToken(token);
              } finally {
                SmartDialog.dismiss(status: SmartStatus.loading);
              }
            },
          ),
        ],
      ),
    );
  }

  Future<String?> showTokenDialog(String tip) async {
    var textController = TextEditingController();
    return await Get.dialog<String>(
      AlertDialog(
        title: Text("Cookie 登录".t),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tip,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textController,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: "粘贴复制的值".t,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text("取消".t),
          ),
          TextButton(
            onPressed: () => Get.back(result: textController.text),
            child: Text("登录".t),
          ),
        ],
      ),
    );
  }

  void douyinTap() async {
    if (DouyinAccountService.instance.hasCookie.value) {
      var result =
          await Utils.showAlertDialog("确定要清除自定义 ttwid 吗？".t, title: "恢复默认".t);
      if (result) {
        DouyinAccountService.instance.clearCookie();
        SmartDialog.showToast("已清除，改用默认 ttwid".t);
      }
    } else {
      doDouyinCookieConfig();
    }
  }

  void doDouyinCookieConfig() {
    // 初始化文本框时，只显示 ttwid 的值部分
    var savedCookie = DouyinAccountService.instance.cookie;
    var displayText = savedCookie;
    if (savedCookie.startsWith('ttwid=') && !savedCookie.contains(';')) {
      displayText = savedCookie.substring(6); // 去掉 "ttwid="
    }
    var controller = TextEditingController(text: displayText);

    Get.dialog(
      AlertDialog(
        title: Text("设置抖音 ttwid".t),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ("不填也能看所有画质（含蓝光）。\n"
                "抖音搜索要登录：粘贴网页版登录后的完整 Cookie（格式 a=1; b=2）。").t,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: "粘贴 ttwid 的值，留空就用默认的".t,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  // 提取 ttwid 的值部分（去掉 "ttwid=" 前缀）
                  var defaultValue = DouyinSite.kDefaultCookie;
                  if (defaultValue.startsWith('ttwid=')) {
                    defaultValue = defaultValue.substring(6); // 去掉 "ttwid="
                  }
                  controller.text = defaultValue;
                },
                icon: const Icon(Icons.restore),
                label: Text("恢复默认 ttwid".t),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: Text("取消".t),
          ),
          TextButton(
            onPressed: () {
              var input = controller.text.trim();
              Get.back();
              if (input.isEmpty) {
                DouyinAccountService.instance.clearCookie();
                SmartDialog.showToast("已清除 Cookie，改用默认 ttwid".t);
              } else {
                // 如果用户只输入了 ttwid 值，自动添加 "ttwid=" 前缀；
                // 带 "=" 的是完整 Cookie（如登录后的），原样保存
                var cookie = input;
                var whole = input.contains('=');
                if (!whole) {
                  cookie = 'ttwid=$input';
                }
                DouyinAccountService.instance.setCookie(cookie);
                SmartDialog.showToast(whole ? "Cookie 已保存".t : "ttwid 已保存".t);
              }
            },
            child: Text("确定".t),
          ),
        ],
      ),
    );
  }
}
