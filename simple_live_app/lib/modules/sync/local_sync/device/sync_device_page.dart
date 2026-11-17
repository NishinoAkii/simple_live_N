import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/sync/local_sync/device/sync_device_controller.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class SyncDevicePage extends GetView<SyncDeviceController> {
  const SyncDevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("同步".t),
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
        children: [
          SettingsCard(
            child: ListTile(
              leading: buildIcon(),
              title: Text(controller.info.name),
              subtitle: Text(
                  "${controller.info.type.toUpperCase()}   ${controller.info.address}"),
            ),
          ),
          AppStyle.vGap12,
          SettingsCard(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Remix.heart_line),
                  title: Text("同步关注列表".t),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    controller.syncFollowAndTag();
                  },
                ),
                AppStyle.divider,
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text("同步观看记录".t),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    controller.syncHistory();
                  },
                ),
                AppStyle.divider,
                ListTile(
                  leading: const Icon(Remix.shield_keyhole_line),
                  title: Text("同步弹幕屏蔽词".t),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    controller.syncBlockedWord();
                  },
                ),
                AppStyle.divider,
                ListTile(
                  leading: const Icon(Remix.account_circle_line),
                  title: Text("同步哔哩哔哩账号".t),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    controller.syncBiliAccount();
                  },
                ),
                // 只有支持直播源的设备（本版本的新版）才显示
                if (controller.peerSupportsLiveSources) ...[
                  AppStyle.divider,
                  ListTile(
                    leading: const Icon(Remix.plug_line),
                    title: Text("同步直播源".t),
                    subtitle: Text("发送订阅和直播源，对方补上没有的".t),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      controller.syncLiveSources();
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildIcon() {
    var icon = controller.info.type.toLowerCase();

    if (icon == "android") {
      return const Icon(Remix.android_line);
    } else if (icon == "ios") {
      return const Icon(Remix.apple_line);
    } else if (icon == "tv") {
      return const Icon(Remix.tv_2_line);
    } else if (icon == "windows") {
      return const Icon(Remix.microsoft_fill);
    } else if (icon == "macos") {
      return const Icon(Remix.mac_line);
    } else if (icon == "linux") {
      return const Icon(Remix.ubuntu_line);
    } else {
      return const Icon(Remix.device_line);
    }
  }
}
