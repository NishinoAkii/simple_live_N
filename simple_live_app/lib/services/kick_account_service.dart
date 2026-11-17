import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class KickAccountService extends GetxService {
  static KickAccountService get instance => Get.find<KickAccountService>();

  var logined = false.obs;
  var name = "未登录".obs;

  var token = "";

  KickSite get site => Sites.allSites[Constant.kKick]!.liveSite as KickSite;

  @override
  void onInit() {
    reload();
    super.onInit();
  }

  /// 从本地存储重新读取账号（同步恢复设置后调用）
  void reload() {
    token = LocalStorageService.instance
        .getValue(LocalStorageService.kKickToken, "");
    var userName = LocalStorageService.instance
        .getValue(LocalStorageService.kKickUserName, "");
    logined.value = token.isNotEmpty;
    name.value =
        logined.value ? (userName.isNotEmpty ? userName : "已登录") : "未登录";
    site.token = token;
    site.userName = logined.value ? userName : "";
  }

  /// 校验会话令牌（Cookie 中的 session_token）并保存
  Future<bool> loginWithToken(String value) async {
    var input = value.trim();
    input = input.replaceFirst(RegExp(r'^session_token='), "");
    input = input.replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), "");
    // Cookie 中的值经过 URL 编码（如 %7C），接口需要解码后的值
    try {
      input = Uri.decodeComponent(input);
    } catch (_) {}
    if (input.isEmpty) {
      return false;
    }
    try {
      var userName = await site.getTokenUser(input);
      token = input;
      site.token = token;
      site.userName = userName;
      LocalStorageService.instance
          .setValue(LocalStorageService.kKickToken, token);
      LocalStorageService.instance
          .setValue(LocalStorageService.kKickUserName, userName);
      logined.value = true;
      name.value = userName;
      SmartDialog.showToast("Kick 登录成功：{userName}".tf({"userName": userName}));
      return true;
    } catch (e) {
      SmartDialog.showToast(e.toString());
      return false;
    }
  }

  void logout() {
    token = "";
    site.token = "";
    site.userName = "";
    LocalStorageService.instance.setValue(LocalStorageService.kKickToken, "");
    LocalStorageService.instance
        .setValue(LocalStorageService.kKickUserName, "");
    logined.value = false;
    name.value = "未登录";
  }
}
