import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class SyncPage extends StatelessWidget {
  const SyncPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("数据同步".t),
        actions: [
          Visibility(
            visible: GetPlatform.isAndroid || GetPlatform.isIOS,
            child: TextButton.icon(
              onPressed: () async {
                var result = await Get.toNamed(RoutePath.kSyncScan);
                if (result == null || result.isEmpty) {
                  return;
                }
                if (result.length == 5) {
                  Get.toNamed(RoutePath.kRemoteSyncRoom, arguments: result);
                } else {
                  Get.toNamed(RoutePath.kLocalSync, arguments: result);
                }
              },
              icon: const Icon(Remix.qr_scan_line),
              label: Text("扫一扫".t),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
            child: Text(
              "远程同步".t,
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              children: [
                ListTile(
                  title: Text("创建房间".t),
                  leading: const Icon(Remix.home_wifi_line),
                  subtitle: Text("其他设备输入房间号就能加入".t),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Get.toNamed(RoutePath.kRemoteSyncRoom);
                  },
                ),
                AppStyle.divider,
                ListTile(
                  title: Text("加入房间".t),
                  leading: const Icon(Remix.add_circle_line),
                  subtitle: Text("加入其他设备创建的房间".t),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    var input = await Utils.showEditTextDialog(
                      "",
                      title: "加入房间".t,
                      hintText: "输入房间号，不分大小写".t,
                      validate: (text) {
                        if (text.isEmpty) {
                          SmartDialog.showToast("请输入房间号".t);
                          return false;
                        }
                        if (text.length != 5) {
                          SmartDialog.showToast("房间号是 5 位".t);
                          return false;
                        }
                        return true;
                      },
                    );
                    if (input != null && input.isNotEmpty) {
                      Get.toNamed(RoutePath.kRemoteSyncRoom,
                          arguments: input.toUpperCase());
                    }
                  },
                ),
                AppStyle.divider,
                ListTile(
                  title: const Text("WebDAV"),
                  leading: const Icon(Icons.cloud_upload_outlined),
                  subtitle: Text("用 WebDAV 同步数据".t),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Get.toNamed(RoutePath.kRemoteSyncWebDav);
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "局域网同步".t,
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              children: [
                ListTile(
                  title: Text("局域网同步".t),
                  subtitle: Text("同一网络下的设备之间同步".t),
                  leading: const Icon(Remix.device_line),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Get.toNamed(RoutePath.kLocalSync);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
