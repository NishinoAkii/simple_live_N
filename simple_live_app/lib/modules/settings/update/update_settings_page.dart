import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/modules/settings/update/translation_source_section.dart';
import 'package:simple_live_app/services/app_update/app_update_service.dart';
import 'package:simple_live_app/services/app_update/installers/update_settings_tiles.dart';
import 'package:simple_live_app/services/app_update/update_settings.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_menu.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';

/// 我的 → 更新：检查更新、所有版本、启动时检查、下载源、翻译源
class UpdateSettingsPage extends StatelessWidget {
  const UpdateSettingsPage({super.key});

  AppUpdateService get service => AppUpdateService.instance;

  UpdateSettings get settings => service.settings;

  Map<String, String> get _sources => {
        UpdateSettings.sourceAuto: "自动选择".t,
        UpdateSettings.sourceDirect: "直连 GitHub".t,
        for (var mirror in service.config.mirrors) mirror.id: mirror.name,
        UpdateSettings.sourceCustom: "自定义镜像".t,
      };

  Future<void> _editCustomMirror() async {
    var text = await Utils.showEditTextDialog(
      settings.customMirror.value,
      title: "自定义镜像前缀".t,
      hintText: "https://example.com/",
      validate: (value) {
        if (UpdateSettings.normalizePrefix(value) == null) {
          SmartDialog.showToast("请填 http 或 https 开头的网址".t);
          return false;
        }
        return true;
      },
    );
    if (text == null) {
      return;
    }
    var prefix = UpdateSettings.normalizePrefix(text) ?? "";
    settings.setCustomMirror(prefix);
    if (prefix.isEmpty &&
        settings.source.value == UpdateSettings.sourceCustom) {
      settings.setSource(UpdateSettings.sourceAuto);
    }
  }

  Future<void> _pickSource(String value) async {
    if (value == UpdateSettings.sourceCustom &&
        settings.customMirror.value.isEmpty) {
      await _editCustomMirror();
      if (settings.customMirror.value.isEmpty) {
        return;
      }
    }
    settings.setSource(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("更新".t)),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          SettingsCard(
            child: Column(
              children: [
                Obx(() {
                  var result = service.checking.value
                      ? "检查中…".t
                      : service.lastResult.value;
                  return SettingsAction(
                    title: "检查更新".t,
                    subtitle: [
                      "当前版本 {version}".tf({"version": Utils.displayVersion}),
                      if (result.isNotEmpty) result,
                    ].join("\n"),
                    onTap: service.checkNow,
                  );
                }),
                AppStyle.divider,
                // GitHub 上的 Release 列表
                SettingsAction(
                  title: "所有版本".t,
                  onTap: () => service.openUrl(service.config.releasesPage),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "启动时检查更新".t,
                    subtitle: "每天最多一次，有新版本时在 App 里提示".t,
                    value: settings.autoCheck.value,
                    onChanged: settings.setAutoCheck,
                  ),
                ),
                AppStyle.divider,
                Obx(() {
                  var sources = _sources;
                  var value = settings.source.value;
                  if (!sources.containsKey(value)) {
                    value = UpdateSettings.sourceAuto;
                  }
                  return SettingsMenu<String>(
                    title: "下载源".t,
                    subtitle: "只用来下载安装包，下完都会校验".t,
                    value: value,
                    valueMap: sources,
                    onChanged: _pickSource,
                  );
                }),
                AppStyle.divider,
                Obx(
                  () => SettingsAction(
                    title: "自定义镜像前缀".t,
                    subtitle: settings.customMirror.value.isEmpty
                        ? "未填写".t
                        : settings.customMirror.value,
                    onTap: _editCustomMirror,
                  ),
                ),
                // iOS：交给哪个应用安装；Windows：回到上一个版本（有备份时才显示）
                const IosInstallTargetTile(dividerAbove: true),
                const RollbackTile(dividerAbove: true),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text("翻译".t, style: Get.textTheme.titleSmall),
          ),
          const TranslationSourceSection(),
        ],
      ),
    );
  }
}
