import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 扫码页现在显示什么
enum DouyuScanView { loading, showing, scanned, expired, failed }

/// 斗鱼扫码登录页：显示二维码，每 3 秒查一次扫码结果，确认后保存账号并返回上一页
class DouyuScanLoginController extends GetxController {
  final DouyuQrLogin _login = DouyuQrLogin();
  Timer? _poller;

  /// 上一次查询还没回来时跳过这一次
  bool _busy = false;

  final qrContent = "".obs;
  final view = DouyuScanView.loading.obs;

  @override
  void onInit() {
    super.onInit();
    newCode();
  }

  /// 换一个新的二维码：打开页面时、失效后点刷新、加载失败后点重试
  Future<void> newCode() async {
    _poller?.cancel();
    view.value = DouyuScanView.loading;
    try {
      qrContent.value = await _login.begin();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast(e.toString());
      view.value = DouyuScanView.failed;
      return;
    }
    view.value = DouyuScanView.showing;
    _poller = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_busy) {
      return;
    }
    _busy = true;
    try {
      switch (await _login.check()) {
        case DouyuQrStep.waiting:
          break;
        case DouyuQrStep.scanned:
          view.value = DouyuScanView.scanned;
        case DouyuQrStep.expired:
          _poller?.cancel();
          view.value = DouyuScanView.expired;
        case DouyuQrStep.confirmed:
          _poller?.cancel();
          await _signIn();
      }
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast(e.toString());
    } finally {
      _busy = false;
    }
  }

  Future<void> _signIn() async {
    // check() 只在拿到凭据以后才返回 confirmed
    var credentials = _login.credentials;
    if (credentials == null) {
      return;
    }
    try {
      await DouyuAccountService.instance.signIn(credentials);
      SmartDialog.showToast("斗鱼账号已登录".t);
      Get.back();
    } catch (e, stackTrace) {
      Log.e("扫码后换取斗鱼 Cookie 失败：$e", stackTrace);
      SmartDialog.showToast(e.toString());
    }
  }

  @override
  void onClose() {
    _poller?.cancel();
    _login.dispose();
    super.onClose();
  }
}
