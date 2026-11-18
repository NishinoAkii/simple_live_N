import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/app_update/installers/ios_installer.dart';
import 'package:simple_live_app/services/app_update/installers/windows_installer.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_menu.dart';

/// 设置里的“回到上一个版本”（Windows）。没有更新前的备份时什么都不显示，
/// [dividerAbove] 为 true 时连同上面的分隔线一起显示
class RollbackTile extends StatefulWidget {
  final bool dividerAbove;
  const RollbackTile({this.dividerAbove = false, super.key});

  /// 测试用：代替查找备份
  @visibleForTesting
  static Future<WindowsBackup?> Function()? debugFindBackup;

  @override
  State<RollbackTile> createState() => _RollbackTileState();
}

class _RollbackTileState extends State<RollbackTile> {
  late final Future<WindowsBackup?> _backup =
      (RollbackTile.debugFindBackup ?? WindowsInstaller.findBackup)();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<WindowsBackup?>(
      future: _backup,
      builder: (context, snapshot) {
        var backup = snapshot.data;
        if (backup == null) {
          return const SizedBox.shrink();
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.dividerAbove) AppStyle.divider,
            SettingsAction(
              title: "回到上一个版本".t,
              value: backup.version,
              onTap: () => _rollback(backup),
            ),
          ],
        );
      },
    );
  }

  Future<void> _rollback(WindowsBackup backup) async {
    var ok = await Utils.showAlertDialog(
      "将关闭 Simple Live，换回 {version} 后重新打开".tf({"version": backup.version}),
      title: "回到上一个版本".t,
    );
    if (!ok) {
      return;
    }
    try {
      await WindowsInstaller().rollbackToPrevious();
    } catch (e) {
      SmartDialog.showToast(e.toString());
    }
  }
}

/// 设置里的“安装方式”（iOS）：新版的 IPA 交给谁装。别的平台上什么都不显示
class IosInstallTargetTile extends StatelessWidget {
  final bool dividerAbove;
  const IosInstallTargetTile({this.dividerAbove = false, super.key});

  /// 测试用：在别的平台上也显示
  @visibleForTesting
  static bool debugShow = false;

  static String subtitleFor(IosInstallTarget target) => switch (target) {
        IosInstallTarget.auto =>
          "依次尝试 TrollStore、AltStore、SideStore，都没有时分享安装包".t,
        IosInstallTarget.share => "下载后通过“分享”交给其他应用安装".t,
        _ => "无法打开 {name} 时分享安装包".tf({"name": IosInstaller.targetName(target)}),
      };

  @override
  Widget build(BuildContext context) {
    if (!debugShow && (kIsWeb || !Platform.isIOS)) {
      return const SizedBox.shrink();
    }
    return Obx(() {
      var target = IosInstallSetting.value.value;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dividerAbove) AppStyle.divider,
          SettingsMenu<IosInstallTarget>(
            title: "安装方式".t,
            subtitle: subtitleFor(target),
            value: target,
            valueMap: {
              for (var e in IosInstallTarget.values)
                e: IosInstaller.targetName(e),
            },
            onChanged: IosInstallSetting.set,
          ),
        ],
      );
    });
  }
}
