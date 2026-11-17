import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/mine/account/web_cookie_login_page.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/live_source_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 直播源（.live.js）的登录：脚本的 login 字段声明登录页和登录 Cookie 的名称。
///
/// - 网页登录：在 App 里打开登录页（复用 [WebCookieLoginPage]），出现登录 Cookie 后把
///   cookieUrl 下的全部 Cookie 写进这个源自己的 Cookie 罐；
/// - Cookie 登录：没有 WebView 的平台（或网页登录不方便时）粘贴整段 Cookie（a=1; b=2）。
///
/// Cookie 只交给直播源保存，不写日志。
class LiveSourceLoginFlow {
  /// 系统 WebView 能用的平台
  static bool get supportWebLogin =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  /// 账号管理、直播源设置里点了这个源：已登录时问是否退出，否则选择登录方式
  static Future<void> tap(ScriptLiveSite site) async {
    var service = LiveSourceService.instance;
    var account = service.accounts[site.info.key];
    if (account?.loggedIn ?? await site.isLoggedIn()) {
      var name = account?.userName;
      var ok = await Utils.showAlertDialog(
        name == null
            ? "确定要退出{name}的账号吗？".tf({"name": site.name})
            : "确定要退出{name}的账号（{name2}）吗？".tf({"name": site.name, "name2": name}),
        title: "退出登录".t,
      );
      if (ok) {
        await service.logoutSource(site.info.key);
        SmartDialog.showToast("已退出登录".t);
      }
      return;
    }
    start(site);
  }

  /// 选择登录方式
  static void start(ScriptLiveSite site) {
    var login = site.login;
    if (login == null) {
      SmartDialog.showToast("{name}不支持登录".tf({"name": site.name}));
      return;
    }
    Utils.showBottomSheet(
      title: "登录{name}".tf({"name": site.name}),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (login.tip != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                login.tip!,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          Visibility(
            visible: supportWebLogin,
            child: ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: Text("网页登录".t),
              subtitle: Text("在 App 里打开网页登录".t),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                Get.toNamed(
                  RoutePath.kWebCookieLogin,
                  arguments: webArgs(site, login),
                );
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text("Cookie 登录".t),
            subtitle: Text("粘贴浏览器里的整段 Cookie".t),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              cookieLogin(site, login);
            },
          ),
        ],
      ),
    );
  }

  static WebCookieLoginArgs webArgs(ScriptLiveSite site, LiveSourceLogin login) {
    return WebCookieLoginArgs(
      title: "{name}登录".tf({"name": site.name}),
      loginUrl: login.url,
      cookieUrl: login.cookieUrl,
      cookieName: login.cookieNames.first,
      otherCookieNames: login.cookieNames.skip(1).toList(),
      wholeCookie: true,
      tip: login.tip ?? "登录完成后会自动返回".t,
      onCookie: (cookies) => _save(site, cookies),
    );
  }

  /// Cookie 登录：粘贴 cookieUrl 下的整段 Cookie
  static Future<void> cookieLogin(
    ScriptLiveSite site,
    LiveSourceLogin login,
  ) async {
    var host = Uri.tryParse(login.cookieUrl)?.host ?? login.cookieUrl;
    var names = login.cookieNames.join("、".t);
    var text = await Utils.showEditTextDialog(
      "",
      title: "Cookie 登录".t,
      hintText: "浏览器登录 {host} 后，复制发往 {host} 的整段 Cookie（要含 {names}）".tf({"host": host, "names": names}),
    );
    if (text == null || text.trim().isEmpty) {
      return;
    }
    // 只粘贴了登录 Cookie 的值：补上名称
    var cookies = text.trim();
    if (!cookies.contains("=") && login.cookieNames.length == 1) {
      cookies = "${login.cookieNames.first}=$cookies";
    }
    SmartDialog.showLoading(msg: "");
    try {
      var ok = await _save(site, cookies);
      if (!ok) {
        SmartDialog.showToast("没有找到登录 Cookie（需要 {names}）".tf({"names": names}));
      }
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  static Future<bool> _save(ScriptLiveSite site, String cookies) async {
    try {
      var ok = await LiveSourceService.instance.loginSource(
        site.info.key,
        cookies,
      );
      if (ok) {
        var name = LiveSourceService.instance.accounts[site.info.key]?.userName;
        SmartDialog.showToast(name == null ? "已登录".t : "已登录：{name}".tf({"name": name}));
      }
      return ok;
    } catch (e) {
      // 错误信息里不会有 Cookie 内容
      Log.logPrint("直播源登录失败：${site.info.key} ${e.runtimeType}");
      SmartDialog.showToast("登录失败：{errorText}".tf({"errorText": LiveSourceService.errorText(e)}));
      return false;
    }
  }
}
