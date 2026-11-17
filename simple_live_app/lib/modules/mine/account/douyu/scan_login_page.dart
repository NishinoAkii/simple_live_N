import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/modules/mine/account/douyu/scan_login_controller.dart';

/// 斗鱼扫码登录
class DouyuScanLoginPage extends GetView<DouyuScanLoginController> {
  const DouyuScanLoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("斗鱼账号登录".t)),
      body: Center(
        child: SingleChildScrollView(
          padding: AppStyle.edgeInsetsA24,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Obx(_codeArea),
              AppStyle.vGap24,
              Text(
                "用斗鱼 App 扫码并确认登录\n登录状态自动续期".t,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _codeArea() {
    var view = controller.view.value;
    switch (view) {
      case DouyuScanView.loading:
        return const CircularProgressIndicator();
      case DouyuScanView.failed:
        return _again("二维码加载失败".t, "重试".t);
      case DouyuScanView.expired:
        return _again("二维码已失效".t, "刷新二维码".t);
      case DouyuScanView.showing:
      case DouyuScanView.scanned:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: AppStyle.radius12,
              child: QrImageView(
                data: controller.qrContent.value,
                version: QrVersions.auto,
                backgroundColor: Colors.white,
                size: 200,
                padding: AppStyle.edgeInsetsA12,
              ),
            ),
            if (view == DouyuScanView.scanned) ...[
              AppStyle.vGap8,
              Text("已扫码，请在斗鱼 App 里确认登录".t),
            ],
          ],
        );
    }
  }

  /// 一句说明加一个按钮，点了换新的二维码
  Widget _again(String message, String action) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message),
        TextButton(onPressed: controller.newCode, child: Text(action)),
      ],
    );
  }
}
