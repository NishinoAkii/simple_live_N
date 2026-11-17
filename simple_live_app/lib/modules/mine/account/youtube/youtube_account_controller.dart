import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/mine/account/web_cookie_login_page.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/youtube_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// YouTube 账号页：谷歌官方授权（设备码）与网页 Cookie 两种登录
class YouTubeAccountController extends GetxController {
  YouTubeAccountService get service => YouTubeAccountService.instance;

  late final TextEditingController clientIdController =
      TextEditingController(text: service.clientId);
  late final TextEditingController clientSecretController =
      TextEditingController(text: service.clientSecret);
  final TextEditingController cookieController = TextEditingController();

  var secretVisible = false.obs;

  /// 正在进行的设备码授权，为空表示没有在授权
  final deviceCode = Rxn<YouTubeDeviceCode>();

  /// 授权码剩余秒数
  var remaining = 0.obs;

  /// 正在校验粘贴的 Cookie
  var verifyingCookie = false.obs;

  Timer? _countdown;

  /// 每次开始、取消授权或离开页面时加一，旧的轮询据此停止
  int _flowSeq = 0;

  /// 是否可以使用网页登录（需要系统 WebView）
  bool get supportWebLogin =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  static String errorText(Object e) => e is CoreError ? e.message : "$e";

  // ---------------- 谷歌官方授权 ----------------

  Future<void> startAuth() async {
    var id = clientIdController.text.trim();
    var secret = clientSecretController.text.trim();
    if (id.isEmpty || secret.isEmpty) {
      SmartDialog.showToast("请先填写 Client ID 和 Client Secret".t);
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    service.setOAuthConfig(id, secret);
    cancelAuth();
    var seq = _flowSeq;
    var oauth = YouTubeOAuth(service.oauthConfig);
    YouTubeDeviceCode code;
    SmartDialog.showLoading(msg: "");
    try {
      code = await oauth.startDeviceFlow();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("获取授权码失败：{errorText}".tf({"errorText": errorText(e)}));
      return;
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
    if (seq != _flowSeq) {
      return;
    }
    deviceCode.value = code;
    _startCountdown(code);
    _poll(oauth, code, seq);
  }

  void _startCountdown(YouTubeDeviceCode code) {
    void tick() {
      var left = code.expiresAt.difference(DateTime.now()).inSeconds;
      remaining.value = left < 0 ? 0 : left;
      if (left <= 0) {
        _countdown?.cancel();
      }
    }

    tick();
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  /// 按谷歌给的间隔查询授权结果，直到拿到令牌、被拒绝、过期或取消
  Future<void> _poll(
    YouTubeOAuth oauth,
    YouTubeDeviceCode code,
    int seq,
  ) async {
    var interval = code.interval < const Duration(seconds: 1)
        ? const Duration(seconds: 5)
        : code.interval;
    var failures = 0;
    while (true) {
      await Future<void>.delayed(interval);
      if (seq != _flowSeq) {
        return;
      }
      if (DateTime.now().isAfter(code.expiresAt)) {
        SmartDialog.showToast("授权码过期了，请重新授权".t);
        _endFlow();
        return;
      }
      YouTubeOAuthToken? token;
      try {
        token = await oauth.pollDeviceFlow(code);
        failures = 0;
      } on CoreError catch (e) {
        // 用户拒绝或授权码过期
        if (seq == _flowSeq) {
          SmartDialog.showToast("授权失败：{message}".tf({"message": e.message}));
          _endFlow();
        }
        return;
      } catch (e) {
        Log.logPrint(e);
        // 网络波动时继续等，连续失败几次再放弃
        failures++;
        if (failures >= 3) {
          if (seq == _flowSeq) {
            SmartDialog.showToast("授权失败：{errorText}".tf({"errorText": errorText(e)}));
            _endFlow();
          }
          return;
        }
        continue;
      }
      if (seq != _flowSeq) {
        return;
      }
      if (token != null) {
        await _finishAuth(oauth, token);
        return;
      }
    }
  }

  Future<void> _finishAuth(YouTubeOAuth oauth, YouTubeOAuthToken token) async {
    _endFlow();
    YouTubeChannelInfo? channel;
    SmartDialog.showLoading(msg: "");
    try {
      channel = await oauth.fetchMyChannel(token.accessToken);
    } catch (e) {
      // 令牌已经拿到，先保存下来；没有频道的账号发不了消息，提示出来
      Log.logPrint(e);
      SmartDialog.showToast("已授权，但没读到频道：{errorText}".tf({"errorText": errorText(e)}));
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
    service.loginWithOAuth(token, channel);
    if (channel != null) {
      SmartDialog.showToast("YouTube 授权成功：{title}".tf({"title": channel.title}));
    }
  }

  void cancelAuth() {
    _flowSeq++;
    _endFlow();
  }

  void _endFlow() {
    _countdown?.cancel();
    _countdown = null;
    deviceCode.value = null;
    remaining.value = 0;
  }

  void copyUserCode() {
    var code = deviceCode.value;
    if (code != null) {
      Utils.copyToClipboard(code.userCode);
    }
  }

  void openVerificationUrl() {
    var code = deviceCode.value;
    if (code != null) {
      openUrl(code.verificationUrl);
    }
  }

  void openCloudConsole() {
    openUrl("https://console.cloud.google.com/");
  }

  Future<void> openUrl(String url) async {
    try {
      await launchUrlString(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      Log.logPrint(e);
      Utils.copyToClipboard(url);
      SmartDialog.showToast("无法打开浏览器，已复制网址".t);
    }
  }

  void logoutOAuth() async {
    var result = await Utils.showAlertDialog(
      "确定要退出 YouTube 官方授权吗？\nClient ID 和 Client Secret 会保留。".t,
      title: "退出登录".t,
    );
    if (result) {
      service.logoutOAuth();
    }
  }

  // ---------------- 网页 Cookie ----------------

  void webLogin() {
    Get.toNamed(
      RoutePath.kWebCookieLogin,
      arguments: WebCookieLoginArgs(
        title: "YouTube 网页登录".t,
        loginUrl:
            "https://accounts.google.com/ServiceLogin?continue=https://www.youtube.com",
        cookieUrl: "https://www.youtube.com",
        cookieName: "SAPISID",
        otherCookieNames: const ["__Secure-3PAPISID"],
        wholeCookie: true,
        tip: ("登录谷歌账号，回到 YouTube 首页后自动返回。"
            "提示“此浏览器或应用可能不安全”时，改用粘贴 Cookie。").t,
        onCookie: service.loginWithCookie,
      ),
    );
  }

  Future<void> submitCookie() async {
    var text = cookieController.text.trim();
    if (text.isEmpty) {
      SmartDialog.showToast("请先粘贴 Cookie".t);
      return;
    }
    if (verifyingCookie.value) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    verifyingCookie.value = true;
    SmartDialog.showLoading(msg: "");
    try {
      if (await service.loginWithCookie(text)) {
        cookieController.clear();
      }
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
      verifyingCookie.value = false;
    }
  }

  void logoutCookie() async {
    var result = await Utils.showAlertDialog(
      "确定要清除 YouTube 网页 Cookie 吗？".t,
      title: "退出登录".t,
    );
    if (result) {
      service.logoutCookie();
    }
  }

  @override
  void onClose() {
    _flowSeq++;
    _countdown?.cancel();
    // 还没授权时保存填写的客户端（包括清空），下次进来不用重填；
    // 已授权时只在“开始授权”时更新，避免误改 Client ID 把令牌清掉
    if (service.token == null) {
      service.setOAuthConfig(
        clientIdController.text,
        clientSecretController.text,
      );
    }
    clientIdController.dispose();
    clientSecretController.dispose();
    cookieController.dispose();
    super.onClose();
  }
}
