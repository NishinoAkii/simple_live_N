import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/requests/sync_client_request.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/routes/route_path.dart';

import 'package:simple_live_app/services/sync_service.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class LocalSyncController extends BaseController {
  final String? address;
  LocalSyncController(this.address);

  @override
  void onInit() {
    SyncService.instance.refreshClients();
    Future.delayed(Duration.zero, initConnect);
    super.onInit();
  }

  void initConnect() {
    if (address != null && address!.isNotEmpty) {
      addressController.text = address!;
      connect();
    }
  }

  TextEditingController addressController = TextEditingController();
  SyncClientRequest request = SyncClientRequest();

  void connect() async {
    var address = addressController.text;
    if (address.isEmpty) {
      SmartDialog.showToast("请输入地址".t);
      return;
    }
    if (address.startsWith('http')) {
      var uri = Uri.tryParse(address);
      if (uri != null) {
        address = uri.host;
      }
    } else if (address.contains(':')) {
      var parts = address.split(":");
      address = parts.first;
    }

    var client = SyncClinet(
      id: 'manual',
      address: address,
      port: SyncService.httpPort,
      name: "手动输入".t,
      type: Platform.operatingSystem,
    );
    connectClient(client);
  }

  void connectClient(SyncClinet client) async {
    try {
      SmartDialog.showLoading(msg: "连接中...".t);
      var info = await request.getClientInfo(client);
      AppNavigator.toSyncDevice(client, info);
    } catch (e) {
      SmartDialog.showToast("连接失败：{e}".tf({"e": e}));
    } finally {
      SmartDialog.dismiss();
    }
  }

  void toScanQr() async {
    var result = await Get.toNamed(RoutePath.kSyncScan);
    if (result == null || result.isEmpty) {
      return;
    }
    var addressList = (result as String).split(";");
    if (addressList.length >= 2) {
      //弹窗选择
      showPickerAddress(addressList);
    } else {
      addressController.text = result;
      //connect();
    }
  }

  void showPickerAddress(List<String> addressList) {
    SmartDialog.showToast("扫到了多个地址，选一个连接".t);
    Utils.showBottomSheet(
      title: '选择地址'.t,
      child: ListView.builder(
        itemBuilder: (_, i) {
          return ListTile(
            title: Text(addressList[i]),
            onTap: () {
              Get.back();
              addressController.text = addressList[i];
              // connect();
            },
          );
        },
        itemCount: addressList.length,
      ),
    );
  }

  void showInfo() {
    Utils.showBottomSheet(
      title: "本机信息".t,
      child: Column(
        children: [
          Visibility(
            visible: SyncService.instance.httpRunning.value,
            child: GestureDetector(
              onTap: () {
                Get.back();
              },
              child: QrImageView(
                data: SyncService.instance.ipAddress.value,
                version: QrVersions.auto,
                backgroundColor: Colors.white,
                padding: AppStyle.edgeInsetsA12,
                size: 200,
              ),
            ),
          ),
          AppStyle.vGap24,
          Visibility(
            visible: SyncService.instance.httpRunning.value,
            child: Text(
              '本机地址：{map}'.tf({"map": SyncService.instance.ipAddress.value.split(';').map((e) => '$e:${SyncService.httpPort}').join("；".t)}),
              textAlign: TextAlign.center,
            ),
          ),
          Visibility(
            visible: !SyncService.instance.httpRunning.value,
            child: Text(
              '同步服务没有启动（{httpErrorMsg}），可以重启 App 试试'.tf({"httpErrorMsg": SyncService.instance.httpErrorMsg}),
              textAlign: TextAlign.center,
            ),
          ),
          AppStyle.vGap12,
          Visibility(
            visible: SyncService.instance.httpRunning.value,
            child: Text(
              "用另一台设备的 Simple Live 扫码\n连上后选要同步的数据".t,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
