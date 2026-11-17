import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/modules/live_room/danmaku_export_dialog.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/obs_bridge/obs_bridge_service.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';

/// 设置里“语言”那一行显示的值：跟随系统，或选中的语言自己的名字
String languageSettingText() => I18n.setting.value == I18n.followSystem
    ? "跟随系统".t
    : I18n.current.value.name;

/// 语言：跟随系统或手动选；导入、下载、导出翻译文件
class LanguageSettingsPage extends StatelessWidget {
  const LanguageSettingsPage({super.key});

  /// 换语言并记住
  static Future<void> choose(String value) async {
    await LocalStorageService.instance.setValue(
      LocalStorageService.kAppLanguage,
      value,
    );
    await I18n.select(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("语言".t)),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          SettingsCard(
            child: Obx(() {
              // 导入、删除、换语言后这一块都要重画
              var languages = [...I18n.builtIn, ...I18n.imported];
              I18n.current.value;
              return RadioGroup<String>(
                groupValue: I18n.setting.value,
                onChanged: (value) => choose(value ?? I18n.followSystem),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<String>(
                      value: I18n.followSystem,
                      title: Text("跟随系统".t),
                      subtitle: Text(I18n.systemLanguage.name),
                      visualDensity: VisualDensity.compact,
                      contentPadding: AppStyle.edgeInsetsH12,
                    ),
                    for (var language in languages)
                      RadioListTile<String>(
                        value: language.code,
                        // 语言的名字用它自己的写法，不翻译
                        title: Text(language.name),
                        visualDensity: VisualDensity.compact,
                        contentPadding: AppStyle.edgeInsetsH12,
                        secondary: language.builtIn
                            ? null
                            : _ImportedActions(language),
                      ),
                  ],
                ),
              );
            }),
          ),
          AppStyle.vGap12,
          Padding(
            padding: AppStyle.edgeInsetsA12,
            child: Text("其他语言".t, style: Get.textTheme.titleSmall),
          ),
          SettingsCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SettingsAction(
                  title: "导入翻译文件".t,
                  subtitle: "选一个 .json 文件".t,
                  onTap: _importFile,
                ),
                AppStyle.divider,
                SettingsAction(
                  title: "从网址下载".t,
                  subtitle: "填翻译文件的网址，比如 GitHub 上的文件".t,
                  onTap: () => _download(),
                ),
                AppStyle.divider,
                SettingsAction(
                  title: "导出翻译模板".t,
                  subtitle: "里面是全部句子，把英文改成你的语言再导入".t,
                  onTap: _exportTemplate,
                ),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12,
            child: Text(
              "导入的翻译会跟着 WebDAV 同步到其他设备。没翻译的句子显示英文。".t,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  static Future<void> _importFile() async {
    String? path;
    try {
      var picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ["json"],
        dialogTitle: "选择翻译文件（.json）".t,
      );
      path = picked?.files.single.path;
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开文件：{e}".tf({"e": e}));
      return;
    }
    if (path == null || path.isEmpty) {
      return;
    }
    try {
      var language = await I18n.importFile(path);
      SmartDialog.showToast("已导入：{name}".tf({"name": language.name}));
    } catch (e) {
      SmartDialog.showToast("导入失败：{e}".tf({"e": _reason(e)}));
    }
  }

  /// 下载 [url] 指向的翻译；不传时先让用户填网址
  static Future<void> _download([String? url]) async {
    url ??= await Utils.showEditTextDialog(
      "",
      title: "从网址下载".t,
      hintText: "https://",
    );
    if (url == null || url.trim().isEmpty) {
      return;
    }
    SmartDialog.showLoading(msg: "正在下载".t);
    try {
      var result = await I18n.addFromUrl(url);
      SmartDialog.dismiss(status: SmartStatus.loading);
      var added = result.added;
      if (added != null) {
        SmartDialog.showToast("已导入：{name}".tf({"name": added.name}));
        return;
      }
      if (result.choices.isEmpty) {
        SmartDialog.showToast("这个网址里没有翻译".t);
        return;
      }
      // 网址是一份清单：挑一种再下载
      Utils.showBottomSheet(
        title: "选择语言".t,
        child: ListView(
          children: [
            for (var item in result.choices)
              ListTile(
                title: Text(item.name),
                subtitle: item.code.isEmpty ? null : Text(item.code),
                onTap: () {
                  Get.back();
                  _download(item.url);
                },
              ),
          ],
        ),
      );
    } catch (e) {
      SmartDialog.dismiss(status: SmartStatus.loading);
      SmartDialog.showToast("下载失败：{e}".tf({"e": _reason(e)}));
    }
  }

  static Future<void> _exportTemplate() async {
    try {
      var folder = await ObsBridgeService.danmakuRecordDirectory();
      var file = File(p.join(folder.path, "SimpleLive-translation.json"));
      await file.writeAsString(await I18n.template());
      await showExportedFile(
        file,
        title: "导出翻译模板".t,
        summary: "在文件开头的 @@code 填语言代码（如 ja），@@name 填语言的名字。".t,
      );
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导出失败：{e}".tf({"e": e}));
    }
  }

  static String _reason(Object e) {
    if (e is FormatException) return e.message;
    if (e is HttpException) return e.message;
    return e.toString();
  }
}

/// 导入的语言右边的按钮：有来源网址的可以更新，都可以删除
class _ImportedActions extends StatelessWidget {
  final AppLanguage language;
  const _ImportedActions(this.language);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (language.source.isNotEmpty)
          IconButton(
            tooltip: "重新下载".t,
            icon: const Icon(Icons.refresh),
            onPressed: () => LanguageSettingsPage._download(language.source),
          ),
        IconButton(
          tooltip: "删除".t,
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            var ok = await Utils.showAlertDialog(
              "删除“{name}”这份翻译？".tf({"name": language.name}),
              title: "删除翻译".t,
            );
            if (!ok) return;
            if (I18n.setting.value == language.code) {
              await LocalStorageService.instance.setValue(
                LocalStorageService.kAppLanguage,
                I18n.followSystem,
              );
            }
            await I18n.remove(language);
          },
        ),
      ],
    );
  }
}
