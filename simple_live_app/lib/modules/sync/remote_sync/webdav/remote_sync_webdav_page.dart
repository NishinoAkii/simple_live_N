import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/remote_sync_webdav_controller.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class RemoteSyncWebDAVPage extends GetView<RemoteSyncWebDAVController> {
  const RemoteSyncWebDAVPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("WebDAV同步".t),
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          SettingsCard(
            child: Obx(
              () => Column(
                children: controller.notLogin.value
                    ? [
                        ListTile(
                          title: Text("登录 WebDAV".t),
                          leading: const Icon(Icons.login),
                          subtitle: Text("登录后可以同步你的数据".t),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Get.toNamed(RoutePath.kRemoteSyncWebDavConfig);
                          },
                        ),
                      ]
                    : [
                        ListTile(
                          title: Text("已登录".t),
                          leading: const Icon(Icons.cloud_circle_outlined),
                          subtitle: Text(controller.user.value),
                          trailing: const Icon(Icons.logout),
                          onTap: () {
                            controller.onLogout();
                          },
                        ),
                        AppStyle.divider,
                        ListTile(
                          title: Text("上传到云端".t),
                          subtitle: Text("上次上传：{lastUploadTime}".tf({"lastUploadTime": controller.lastUploadTime})),
                          leading: const Icon(Icons.cloud_upload_outlined),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            controller.doWebDAVUpload();
                          },
                        ),
                        AppStyle.divider,
                        ListTile(
                          title: Text("恢复到本地".t),
                          subtitle: Text("上次恢复：{lastRecoverTime}".tf({"lastRecoverTime": controller.lastRecoverTime})),
                          leading: const Icon(Icons.cloud_download_outlined),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.settings),
                                onPressed: showSetting,
                              ),
                              const Icon(Icons.chevron_right),
                            ],
                          ),
                          onTap: () {
                            controller.doWebDAVRecovery();
                          },
                          onLongPress: showSetting,
                        ),
                        AppStyle.divider,
                        ListTile(
                          title: Text("自动同步".t),
                          subtitle: Text(
                            ("启动时拉取，有改动时上传"
                            "{p}").tf({"p": controller.autoSyncStatus.isEmpty ? "" : "\n${controller.autoSyncStatus}"}),
                          ),
                          leading: const Icon(Icons.sync),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.settings),
                                onPressed: showSetting,
                              ),
                              Switch(
                                value: controller.autoSync.value,
                                onChanged: controller.changeAutoSync,
                              ),
                            ],
                          ),
                        ),
                      ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void showSetting() {
    Utils.showBottomSheet(
      title: '同步选项'.t,
      // 手机上一屏放不下：可以上下滑，右边一直显示滚动条
      child: SyncOptionsScroll(
        children: [
          AppStyle.divider,
          Obx(
            () => CheckboxListTile(
              secondary: const Icon(Remix.heart_line),
              title: Text("同步关注列表".t),
              value: controller.isSyncFollows.value,
              controlAffinity: ListTileControlAffinity.trailing,
              onChanged: (value) => controller.changeIsSyncFollows(),
            ),
          ),
          AppStyle.divider,
          Obx(
            () => CheckboxListTile(
              secondary: const Icon(Icons.history),
              title: Text("同步观看记录".t),
              value: controller.isSyncHistories.value,
              controlAffinity: ListTileControlAffinity.trailing,
              onChanged: (value) => controller.changeIsSyncHistories(),
            ),
          ),
          AppStyle.divider,
          Obx(
            () => CheckboxListTile(
              secondary: const Icon(Remix.shield_keyhole_line),
              title: Text("同步弹幕屏蔽词".t),
              value: controller.isSyncBlockWord.value,
              controlAffinity: ListTileControlAffinity.trailing,
              onChanged: (value) => controller.changeIsSyncBlockWord(),
            ),
          ),
          AppStyle.divider,
          Obx(
            () => CheckboxListTile(
              secondary: const Icon(Remix.account_circle_line),
              title: Text("同步哔哩哔哩账号".t),
              subtitle: Text("账号加密保存，仅登录同一 WebDAV 账号的设备可读取".t),
              value: controller.isSyncBilibiliAccount.value,
              controlAffinity: ListTileControlAffinity.trailing,
              onChanged: (value) => controller.changeIsSyncBilibiliAccount(),
            ),
          ),
          AppStyle.divider,
          Obx(
            () => CheckboxListTile(
              secondary: const Icon(Icons.account_circle_outlined),
              title: Text("同步斗鱼、Twitch、Kick、YouTube 账号".t),
              subtitle: Text("账号加密保存，仅登录同一 WebDAV 账号的设备可读取".t),
              value: controller.isSyncPlatformAccounts.value,
              controlAffinity: ListTileControlAffinity.trailing,
              onChanged: (value) => controller.changeIsSyncPlatformAccounts(),
            ),
          ),
          AppStyle.divider,
          Obx(
            () => CheckboxListTile(
              secondary: const Icon(Remix.plug_line),
              title: Text("同步直播源".t),
              subtitle: Text("添加备份里的订阅，并从地址安装本机没有的直播源".t),
              value: controller.isSyncLiveSources.value,
              controlAffinity: ListTileControlAffinity.trailing,
              onChanged: (value) => controller.changeIsSyncLiveSources(),
            ),
          ),
          AppStyle.divider,
          Obx(
            () => CheckboxListTile(
              secondary: const Icon(Icons.tune),
              title: Text("自动同步时也同步设置".t),
              value: controller.isAutoSyncSettings.value,
              controlAffinity: ListTileControlAffinity.trailing,
              onChanged: (value) => controller.changeAutoSyncSettings(),
            ),
          ),
          AppStyle.divider,
        ],
      ),
    );
  }
}

/// 同步选项的列表：内容比弹窗高时能滚动，滚动条一直显示，不会有选项藏在下面够不着
class SyncOptionsScroll extends StatefulWidget {
  final List<Widget> children;
  const SyncOptionsScroll({required this.children, super.key});

  @override
  State<SyncOptionsScroll> createState() => _SyncOptionsScrollState();
}

class _SyncOptionsScrollState extends State<SyncOptionsScroll> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: widget.children,
        ),
      ),
    );
  }
}
