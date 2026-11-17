import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/mine/account/bilibili/qr_login_controller.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class BiliBiliQRLoginPage extends GetView<BiliBiliQRLoginController> {
  const BiliBiliQRLoginPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("哔哩哔哩账号登录".t)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Center(
            child: Obx(
              () {
                if (controller.qrStatus.value == QRStatus.loading) {
                  return const CircularProgressIndicator();
                }
                if (controller.qrStatus.value == QRStatus.failed) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text("二维码加载失败".t),
                      TextButton(
                        onPressed: controller.loadQRCode,
                        child: Text("重试".t),
                      ),
                    ],
                  );
                }
                if (controller.qrStatus.value == QRStatus.failed) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text("二维码已失效".t),
                      TextButton(
                        onPressed: controller.loadQRCode,
                        child: Text("刷新二维码".t),
                      ),
                    ],
                  );
                }
                return Column(
                  children: [
                    ClipRRect(
                      borderRadius: AppStyle.radius12,
                      child: QrImageView(
                        data: controller.qrcodeUrl.value,
                        version: QrVersions.auto,
                        backgroundColor: Colors.white,
                        size: 200.0,
                        padding: AppStyle.edgeInsetsA12,
                      ),
                    ),
                    AppStyle.vGap8,
                    Visibility(
                      visible: controller.qrStatus.value == QRStatus.scanned,
                      child: Text("已扫码，请在手机上确认登录".t),
                    ),
                  ],
                );
              },
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA24,
            child: Text(
              "用哔哩哔哩手机 App 扫码登录".t,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
