import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class SyncScanQRControlelr extends BaseController {
  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? qrController;
  StreamSubscription<Barcode>? barcodeStreamSubscription;
  bool pause = false;
  void onQRViewCreated(QRViewController controller) {
    qrController = controller;
    barcodeStreamSubscription =
        qrController!.scannedDataStream.listen((scanData) async {
      Log.d(scanData.toString());
      if (pause) {
        return;
      }
      pause = true;
      // 扫码成功后暂停摄像头
      await controller.pauseCamera();
      var code = scanData.code ?? "";
      // 处理扫码结果
      if (code.isEmpty) {
        pause = false;
        await controller.resumeCamera();
        return;
      }

      // 如果是5位字符串，为房间号
      if (code.length == 5) {
        Get.offAndToNamed(RoutePath.kRemoteSyncRoom, arguments: code);
        return;
      } else {
        var addressList = code.split(";");
        if (addressList.length >= 2) {
          //弹窗选择
          showPickerAddress(addressList);
        } else {
          Get.back(result: code);
        }
      }
    });
  }

  void showPickerAddress(List<String> addressList) async {
    SmartDialog.showToast("扫到了多个地址，选一个连接".t);
    var address = await Utils.showBottomSheet(
      title: '选择地址'.t,
      child: ListView.builder(
        itemBuilder: (_, i) {
          return ListTile(
            title: Text(addressList[i]),
            onTap: () {
              Get.back(result: addressList[i]);
            },
          );
        },
        itemCount: addressList.length,
      ),
    );
    if (address != null && address.isNotEmpty) {
      Get.back(result: address);
    }
  }

  @override
  void onClose() {
    barcodeStreamSubscription?.cancel();

    super.onClose();
  }
}
