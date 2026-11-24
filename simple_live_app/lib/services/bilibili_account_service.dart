import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/account/bilibili_user_info_page.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class BiliBiliAccountService extends GetxService {
  static BiliBiliAccountService get instance =>
      Get.find<BiliBiliAccountService>();

  var logined = false.obs;

  var cookie = "";
  var uid = 0;
  var name = "未登录".obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kBilibiliCookie, "");
    logined.value = cookie.isNotEmpty;
    // 没登录时也带上（网页端游客同样有这个 Cookie）
    _setLiveBuvid(_site);
    loadUserInfo();
    super.onInit();
  }

  Future loadUserInfo() async {
    if (cookie.isEmpty) {
      return;
    }
    try {
      var result = await HttpClient.instance.getJson(
        "https://api.bilibili.com/x/member/web/account",
        header: {
          "Cookie": cookie,
        },
      );
      if (result["code"] == 0) {
        var info = BiliBiliUserInfoModel.fromJson(result["data"]);
        name.value = info.uname ?? "未登录";
        uid = info.mid ?? 0;
        setSite();
      } else {
        SmartDialog.showToast("哔哩哔哩登录已失效，请重新登录".t);
        logout();
      }
    } catch (e) {
      SmartDialog.showToast("没读到哔哩哔哩账号信息，可到账号管理重试".t);
    }
  }

  BiliBiliSite get _site =>
      Sites.allSites[Constant.kBiliBili]!.liveSite as BiliBiliSite;

  /// 网页端的 LIVE_BUVID：平台发的优先，还没有时用自己生成的
  void _setLiveBuvid(BiliBiliSite site) {
    var issued = LocalStorageService.instance
        .getValue(LocalStorageService.kBiliLiveBuvidCookie, "");
    site.liveBuvidIssued = issued.isNotEmpty;
    site.savedLiveBuvid = issued.isNotEmpty ? issued : _liveBuvid;
    site.onLiveBuvidIssued = (value) => LocalStorageService.instance
        .setValue(LocalStorageService.kBiliLiveBuvidCookie, value);
  }

  /// 自己生成的 LIVE_BUVID：没有时生成一个存下，之后一直沿用
  String get _liveBuvid {
    var saved = LocalStorageService.instance
        .getValue(LocalStorageService.kBiliLiveBuvid, "");
    if (saved.isEmpty) {
      saved = BiliWatchHeart.newLiveBuvid();
      LocalStorageService.instance
          .setValue(LocalStorageService.kBiliLiveBuvid, saved);
    }
    return saved;
  }

  void setSite() {
    var site = _site;
    site.userId = uid;
    site.cookie = cookie;
    _setLiveBuvid(site);
  }

  void setCookie(String cookie) {
    this.cookie = cookie;
    LocalStorageService.instance
        .setValue(LocalStorageService.kBilibiliCookie, cookie);
    logined.value = cookie.isNotEmpty;
  }

  void logout() async {
    cookie = "";
    uid = 0;
    name.value = "未登录";
    setSite();
    LocalStorageService.instance
        .setValue(LocalStorageService.kBilibiliCookie, "");
    logined.value = false;

    if (Platform.isAndroid || Platform.isIOS) {
      CookieManager cookieManager = CookieManager.instance();
      await cookieManager.deleteAllCookies();
    }
  }
}
