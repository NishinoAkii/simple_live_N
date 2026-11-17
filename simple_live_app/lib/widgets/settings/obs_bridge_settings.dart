import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/obs_bridge/obs_bridge_service.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 录屏接口（OBS 等）设置：开关、端口、局域网访问、可复制的页面地址，
/// 以及电脑上“记录弹幕（ASS）”的保存位置
class ObsBridgeSettings extends StatefulWidget {
  const ObsBridgeSettings({super.key});

  @override
  State<ObsBridgeSettings> createState() => _ObsBridgeSettingsState();
}

class _ObsBridgeSettingsState extends State<ObsBridgeSettings> {
  ObsBridgeService? get service => ObsBridgeService.maybeInstance;

  static bool get _desktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    var service = this.service;
    if (service != null && service.lanAccess.value) {
      service.refreshLanAddresses();
    }
  }

  @override
  Widget build(BuildContext context) {
    var service = this.service;
    if (service == null) {
      return const SizedBox.shrink();
    }
    return Obx(() {
      var on = service.enabled.value;
      var lan = service.lanAccess.value;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingsSwitch(
            title: "启用录屏接口".t,
            subtitle: _status(service),
            value: on,
            onChanged: service.setEnabled,
          ),
          if (on) ...[
            AppStyle.divider,
            SettingsAction(
              title: "端口".t,
              value: "${service.port.value}",
              onTap: () => _editPort(service),
            ),
            AppStyle.divider,
            SettingsSwitch(
              title: "允许局域网访问".t,
              subtitle: "手机看直播、电脑用 OBS 时打开；地址带访问码，别发给别人".t,
              value: lan,
              onChanged: (e) async {
                await service.setLanAccess(e);
                if (e) {
                  await service.refreshLanAddresses();
                }
              },
            ),
            if (lan) ...[
              AppStyle.divider,
              SettingsAction(
                title: "更换访问码".t,
                subtitle: "换了以后，旧地址就不能用了".t,
                onTap: () => _regenerateToken(service),
              ),
            ],
            AppStyle.divider,
            _urlTile(service, "弹幕层".t, "/overlay"),
            _urlTile(service, "聊天框".t, "/chat"),
            _urlTile(service, "醒目留言".t, "/sc"),
            _urlTile(service, "实时 ASS 弹幕".t, "/ass/live"),
            _urlTile(service, "说明和全部地址".t, "/"),
            Padding(
              padding: AppStyle.edgeInsetsA12.copyWith(top: 4),
              child: Text(
                "OBS 里添加“浏览器”来源，填地址，宽高和画面一样".t,
                style: Get.textTheme.bodySmall!.copyWith(color: Colors.grey),
              ),
            ),
          ],
          if (_desktop) ...[
            AppStyle.divider,
            SettingsAction(
              title: "弹幕记录保存位置".t,
              subtitle: "直播间“更多”里的“记录弹幕（ASS）”存到这里".t,
              value: service.recordDir.value.isEmpty
                  ? "下载/SimpleLive".t
                  : _shortPath(service.recordDir.value),
              onTap: () => _pickRecordDir(service),
            ),
          ],
        ],
      );
    });
  }

  String _status(ObsBridgeService service) {
    if (!service.enabled.value) {
      return "打开后，弹幕、聊天和醒目留言可显示在 OBS 等录屏软件里".t;
    }
    if (service.errorMsg.value.isNotEmpty) {
      return service.errorMsg.value;
    }
    if (!service.running.value) {
      return "正在启动…".t;
    }
    return service.lanAccess.value ? "运行中，本机和局域网都可以访问".t : "运行中，只有本机可以访问".t;
  }

  Widget _urlTile(ObsBridgeService service, String title, String path) {
    var local = service.localUrl(path);
    var lan = service.lanUrl(path);
    var lines = [
      lan == null ? local : "本机：{local}".tf({"local": local}),
      if (lan != null) "局域网：{lan}".tf({"lan": lan}),
    ];
    return ListTile(
      visualDensity: VisualDensity.compact,
      shape: RoundedRectangleBorder(borderRadius: AppStyle.radius8),
      contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 4),
      title: Text(title, style: Get.textTheme.bodyLarge),
      subtitle: Text(
        lines.join("\n"),
        style: Get.textTheme.bodySmall!.copyWith(color: Colors.grey),
      ),
      // 局域网地址给另一台电脑用，排在前面
      onTap: () => Utils.copyToClipboard(lan ?? local),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (lan != null)
            IconButton(
              tooltip: "复制局域网地址".t,
              onPressed: () => Utils.copyToClipboard(lan),
              icon: const Icon(Icons.lan_outlined, size: 20),
            ),
          IconButton(
            tooltip: "复制本机地址".t,
            onPressed: () => Utils.copyToClipboard(local),
            icon: const Icon(Icons.copy, size: 20),
          ),
        ],
      ),
    );
  }

  Future<void> _editPort(ObsBridgeService service) async {
    var text = await Utils.showEditTextDialog(
      "${service.port.value}",
      title: "端口".t,
      hintText: "1024~65535，默认 {kDefaultPort}".tf({"kDefaultPort": ObsBridgeService.kDefaultPort}),
      validate: (text) {
        var value = int.tryParse(text.trim());
        if (value == null || value < 1024 || value > 65535) {
          SmartDialog.showToast("请输入 1024~65535 之间的数字".t);
          return false;
        }
        return true;
      },
    );
    if (text == null) {
      return;
    }
    await service.setPort(int.parse(text.trim()));
  }

  Future<void> _regenerateToken(ObsBridgeService service) async {
    var ok = await Utils.showAlertDialog(
      "换了以后，OBS 里的来源要改成新地址。".t,
      title: "更换访问码".t,
      confirm: "更换".t,
    );
    if (ok) {
      await service.regenerateToken();
      SmartDialog.showToast("访问码已更换".t);
    }
  }

  Future<void> _pickRecordDir(ObsBridgeService service) async {
    if (service.recordDir.value.isNotEmpty) {
      var choice = await Utils.showMapOptionDialog<int>(
        {
          0: "选择其它文件夹".t,
          1: "改回下载文件夹里的 SimpleLive".t,
        },
        -1,
        title: "弹幕记录保存位置".t,
      );
      if (choice == null) {
        return;
      }
      if (choice == 1) {
        service.setRecordDir("");
        return;
      }
    }
    try {
      var dir = await FilePicker.platform.getDirectoryPath();
      if (dir != null && dir.isNotEmpty) {
        service.setRecordDir(dir);
      }
    } catch (e) {
      SmartDialog.showToast("无法选择文件夹：{e}".tf({"e": e}));
    }
  }

  static String _shortPath(String path) {
    if (path.length <= 24) {
      return path;
    }
    return "…${path.substring(path.length - 22)}";
  }
}
