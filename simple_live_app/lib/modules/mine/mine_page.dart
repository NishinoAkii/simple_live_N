import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/app_update/app_update_service.dart';
import 'package:simple_live_app/services/signalr_service.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class MinePage extends StatelessWidget {
  const MinePage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Get.isDarkMode
          ? SystemUiOverlayStyle.light.copyWith(
              systemNavigationBarColor: Colors.transparent,
            )
          : SystemUiOverlayStyle.dark.copyWith(
              systemNavigationBarColor: Colors.transparent,
            ),
      child: SafeArea(
        child: ListView(
          padding: AppStyle.edgeInsetsA4,
          children: [
            AppStyle.vGap12,
            ListTile(
              leading: Image.asset(
                'assets/images/logo.png',
                width: 56,
                height: 56,
              ),
              title: const Text(
                "Simple Live N",
                style: TextStyle(height: 1.0),
              ),
              subtitle: Text("简简单单看直播".t),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.dialog(AboutDialog(
                  applicationIcon: Image.asset(
                    'assets/images/logo.png',
                    width: 48,
                    height: 48,
                  ),
                  applicationName: "Simple Live N",
                  applicationVersion: "简简单单看直播".t,
                  applicationLegalese: "Ver ${Utils.displayVersion}",
                ));
              },
            ),
            Divider(
              indent: 12,
              endIndent: 12,
              color: Colors.grey.withAlpha(25),
            ),
            _buildCard(
              context,
              children: [
                ListTile(
                  leading: const Icon(Remix.history_line),
                  title: Text("观看记录".t),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kHistory);
                  },
                ),
              ],
            ),
            Divider(
              indent: 12,
              endIndent: 12,
              color: Colors.grey.withAlpha(25),
            ),
            ListTile(
              leading: const Icon(Remix.account_circle_line),
              title: Text("账号管理".t),
              trailing: const Icon(
                Icons.chevron_right,
                color: Colors.grey,
              ),
              onTap: () {
                Get.toNamed(RoutePath.kSettingsAccount);
              },
            ),
            Divider(
              indent: 12,
              endIndent: 12,
              color: Colors.grey.withAlpha(25),
            ),
            ListTile(
              leading: const Icon(Icons.devices),
              title: Text("数据同步".t),
              trailing: const Icon(
                Icons.chevron_right,
                color: Colors.grey,
              ),
              onTap: () {
                Get.toNamed(RoutePath.kSync);
              },
            ),
            Divider(
              indent: 12,
              endIndent: 12,
              color: Colors.grey.withAlpha(25),
            ),
            ListTile(
              leading: const Icon(Remix.link),
              title: Text("链接解析".t),
              trailing: const Icon(
                Icons.chevron_right,
                color: Colors.grey,
              ),
              onTap: () {
                Get.toNamed(RoutePath.kTools);
              },
            ),
            Divider(
              indent: 12,
              endIndent: 12,
              color: Colors.grey.withAlpha(25),
            ),
            _buildCard(
              context,
              children: [
                ListTile(
                  leading: const Icon(Remix.moon_line),
                  title: Text("外观设置".t),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kAppstyleSetting);
                  },
                ),
                ListTile(
                  leading: const Icon(Remix.home_2_line),
                  title: Text("主页设置".t),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsIndexed);
                  },
                ),
                ListTile(
                  leading: const Icon(Remix.plug_line),
                  title: Text("直播源订阅".t),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsLiveSource);
                  },
                ),
                ListTile(
                  leading: const Icon(Remix.play_circle_line),
                  title: Text("直播设置".t),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsPlay);
                  },
                ),
                ListTile(
                  leading: const Icon(Remix.text),
                  title: Text("弹幕设置".t),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsDanmu);
                  },
                ),
                ListTile(
                  leading: const Icon(Remix.heart_line),
                  title: Text("关注设置".t),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsFollow);
                  },
                ),
                ListTile(
                  leading: const Icon(Remix.timer_2_line),
                  title: Text("定时关闭".t),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsAutoExit);
                  },
                ),
                // 快捷键、记住窗口、显卡偏好
                if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
                  ListTile(
                    leading: const Icon(Remix.computer_line),
                    title: Text("电脑端设置".t),
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: Colors.grey,
                    ),
                    onTap: () {
                      Get.toNamed(RoutePath.kSettingsDesktop);
                    },
                  ),
                ListTile(
                  leading: const Icon(Remix.apps_line),
                  title: Text("其他设置".t),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsOther);
                  },
                ),
                if (kDebugMode)
                  ListTile(
                    leading: const Icon(Remix.apps_line),
                    title: Text("测试".t),
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: Colors.grey,
                    ),
                    onTap: () async {
                      SignalRService signalRService = SignalRService();
                      await signalRService.connect();
                      //Get.toNamed(RoutePath.kTest);
                      var room = await signalRService.createRoom();
                      Log.logPrint(room);
                    },
                  ),
              ],
            ),
            Divider(
              indent: 12,
              endIndent: 12,
              color: Colors.grey.withAlpha(25),
            ),
            _buildCard(
              context,
              children: [
                // 打开“更新”页并马上检查一次；启动时检查、下载源也在那里
                ListTile(
                  leading: const Icon(Remix.download_cloud_2_line),
                  title: Text("检查更新".t),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    Get.toNamed(RoutePath.kSettingsUpdate);
                    AppUpdateService.maybeInstance?.checkNow();
                  },
                ),
                ListTile(
                  leading: const Icon(Remix.error_warning_line),
                  title: Text("免责声明".t),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: Utils.showStatement,
                ),
                ListTile(
                  leading: const Icon(Remix.github_line),
                  title: Text("开源主页".t),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                  ),
                  onTap: () {
                    launchUrlString(
                      "https://github.com/NishinoAkii/simple_live_N",
                      mode: LaunchMode.externalApplication,
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context, {required List<Widget> children}) {
    return Theme(
      data: Theme.of(context).copyWith(
        listTileTheme: ListTileThemeData(
          shape: RoundedRectangleBorder(borderRadius: AppStyle.radius8),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}
