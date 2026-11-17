import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class TwitchAccountService extends GetxService {
  static TwitchAccountService get instance => Get.find<TwitchAccountService>();

  var logined = false.obs;
  var name = "未登录".obs;

  var token = "";
  var login = "";

  TwitchSite get site =>
      Sites.allSites[Constant.kTwitch]!.liveSite as TwitchSite;

  @override
  void onInit() {
    reload();
    super.onInit();
  }

  /// 从本地存储重新读取账号（同步恢复设置后调用）
  void reload() {
    token = LocalStorageService.instance
        .getValue(LocalStorageService.kTwitchToken, "");
    login = LocalStorageService.instance
        .getValue(LocalStorageService.kTwitchLogin, "");
    var displayName = LocalStorageService.instance
        .getValue(LocalStorageService.kTwitchDisplayName, "");
    logined.value = token.isNotEmpty && login.isNotEmpty;
    name.value =
        logined.value ? (displayName.isNotEmpty ? displayName : login) : "未登录";
    setSite(displayName);
  }

  void setSite(String displayName) {
    site.token = token;
    site.login = login;
    site.displayName = displayName;
  }

  /// 校验令牌并保存登录信息
  Future<bool> loginWithToken(String value) async {
    var input = value.trim();
    // 允许直接粘贴 oauth:xxx 或 auth-token=xxx
    input = input.replaceFirst(RegExp(r'^oauth:', caseSensitive: false), "");
    input = input.replaceFirst(RegExp(r'^auth-token='), "");
    if (input.isEmpty) {
      return false;
    }
    try {
      var user = await site.getTokenUser(input);
      token = input;
      login = user.login;
      LocalStorageService.instance
          .setValue(LocalStorageService.kTwitchToken, token);
      LocalStorageService.instance
          .setValue(LocalStorageService.kTwitchLogin, login);
      LocalStorageService.instance
          .setValue(LocalStorageService.kTwitchDisplayName, user.displayName);
      logined.value = true;
      name.value = user.displayName;
      setSite(user.displayName);
      SmartDialog.showToast("Twitch 登录成功：{displayName}".tf({"displayName": user.displayName}));
      return true;
    } catch (e) {
      SmartDialog.showToast(e.toString());
      return false;
    }
  }

  void logout() {
    token = "";
    login = "";
    LocalStorageService.instance.setValue(LocalStorageService.kTwitchToken, "");
    LocalStorageService.instance.setValue(LocalStorageService.kTwitchLogin, "");
    LocalStorageService.instance
        .setValue(LocalStorageService.kTwitchDisplayName, "");
    logined.value = false;
    name.value = "未登录";
    setSite("");
  }
}
