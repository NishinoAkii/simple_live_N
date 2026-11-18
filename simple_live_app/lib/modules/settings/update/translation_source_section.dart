import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/source_hooks.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/app_update/app_update_service.dart';
import 'package:simple_live_app/services/app_update/translation_sources.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';

/// 更新页的“翻译”：翻译源的地址、下载翻译（列出翻译源里的语言）、检查翻译更新
class TranslationSourceSection extends StatelessWidget {
  const TranslationSourceSection({super.key});

  AppUpdateService get service => AppUpdateService.instance;

  static bool _valid(String text) {
    var value = SourceHooks.normalizeUrl(text.trim());
    if (value.isEmpty || SourceHooks.isPrivate(value)) {
      return true;
    }
    var uri = Uri.tryParse(value);
    return uri != null &&
        (uri.isScheme("https") || uri.isScheme("http")) &&
        uri.host.isNotEmpty;
  }

  Future<void> _editSource() async {
    var text = await Utils.showEditTextDialog(
      service.settings.translationSource.value,
      title: "翻译源".t,
      hintText: service.config.translationSource.isEmpty
          ? "https://…/translations.json"
          : service.config.translationSource,
      validate: (value) {
        if (!_valid(value)) {
          SmartDialog.showToast(
            SourceHooks.isPrivateUrl == null
                ? "请填 http 或 https 开头的网址".t
                : "请填 https 开头的网址，或者 github:用户/仓库/路径".t,
          );
          return false;
        }
        return true;
      },
    );
    if (text == null) {
      return;
    }
    // 清空时回到默认的翻译源
    service.settings
        .setTranslationSource(SourceHooks.normalizeUrl(text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Obx(() {
            var url = service.translations.sourceUrl;
            var usingDefault = service.translations.usingDefault;
            return SettingsAction(
              title: "翻译源".t,
              subtitle: url.isEmpty
                  ? "未填写".t
                  : usingDefault
                      ? "默认：{url}".tf({"url": url})
                      : url,
              onTap: _editSource,
            );
          }),
          AppStyle.divider,
          SettingsAction(
            title: "下载翻译".t,
            subtitle: "列出翻译源里的语言，可以安装、更新、删除".t,
            onTap: TranslationListSheet.show,
          ),
          AppStyle.divider,
          Obx(() {
            var result = service.checkingTranslations.value
                ? "检查中…".t
                : service.translationResult.value;
            return SettingsAction(
              title: "检查翻译更新".t,
              subtitle: result.isEmpty ? "装过的翻译有变化时直接换成新的".t : result,
              onTap: service.checkTranslationsNow,
            );
          }),
        ],
      ),
    );
  }
}

/// 翻译源里的语言：没装的可以安装，装了的可以更新、删除
class TranslationListSheet extends StatefulWidget {
  const TranslationListSheet({super.key});

  static Future<void> show() => Utils.showBottomSheet(
        title: "下载翻译".t,
        child: const TranslationListSheet(),
      );

  @override
  State<TranslationListSheet> createState() => _TranslationListSheetState();
}

class _TranslationListSheetState extends State<TranslationListSheet> {
  late Future<List<TranslationEntry>> _entries = _load();

  /// 正在下载的语言
  final Set<String> _busy = {};

  TranslationSources get sources => AppUpdateService.instance.translations;

  Future<List<TranslationEntry>> _load() => sources.fetchIndex();

  void _reload() => setState(() => _entries = _load());

  Future<void> _install(TranslationEntry entry) async {
    setState(() => _busy.add(entry.code));
    try {
      var language = await sources.install(entry);
      SmartDialog.showToast("已安装：{name}".tf({"name": language.name}));
    } catch (e) {
      SmartDialog.showToast("下载失败：{e}".tf({"e": _reason(e)}));
    } finally {
      if (mounted) {
        setState(() => _busy.remove(entry.code));
      }
    }
  }

  Future<void> _remove(AppLanguage language) async {
    var ok = await Utils.showAlertDialog(
      "删除“{name}”这份翻译？".tf({"name": language.name}),
      title: "删除翻译".t,
    );
    if (!ok) {
      return;
    }
    await TranslationSources.remove(language);
    if (mounted) {
      setState(() {});
    }
  }

  static String _reason(Object e) =>
      e is FormatException ? e.message : e.toString();

  String _stateText(TranslationState state) {
    switch (state) {
      case TranslationState.notInstalled:
        return "未安装".t;
      case TranslationState.otherSource:
        return "已安装（不是从这个翻译源装的）".t;
      case TranslationState.upToDate:
        return "已是最新".t;
      case TranslationState.changed:
        return "有更新".t;
      case TranslationState.unknown:
        return "已安装".t;
    }
  }

  Widget _row(TranslationEntry entry, Map<String, InstalledTranslation> mine) {
    var installed = mine[entry.code];
    var state = TranslationSources.stateOf(entry, installed);
    var busy = _busy.contains(entry.code);
    return ListTile(
      title: Text(entry.name),
      subtitle: Text([
        entry.code,
        if (entry.version.isNotEmpty) entry.version,
        _stateText(state),
      ].join(" · ")),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const Padding(
              padding: AppStyle.edgeInsetsA12,
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (state == TranslationState.notInstalled ||
              state == TranslationState.otherSource)
            IconButton(
              tooltip: "安装".t,
              icon: const Icon(Icons.download),
              onPressed: () => _install(entry),
            )
          else
            IconButton(
              tooltip: "更新".t,
              icon: Icon(
                Icons.refresh,
                color: state == TranslationState.changed
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              onPressed: () => _install(entry),
            ),
          if (installed != null)
            IconButton(
              tooltip: "删除".t,
              icon: const Icon(Icons.delete_outline),
              onPressed: busy ? null : () => _remove(installed.language),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<TranslationEntry>>(
      future: _entries,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return ListView(
            children: [
              ListTile(
                title: Text("读不到翻译源".t),
                subtitle: Text(_reason(snapshot.error!)),
              ),
              TextButton(onPressed: _reload, child: Text("重试".t)),
            ],
          );
        }
        var entries = snapshot.data ?? const [];
        if (entries.isEmpty) {
          return Center(child: Text("翻译源里没有翻译".t));
        }
        return Obx(() {
          // 装、删以后 I18n.imported 会变，跟着重画
          var mine = TranslationSources.installed(I18n.imported.toList());
          return ListView(
            children: [for (var entry in entries) _row(entry, mine)],
          );
        });
      },
    );
  }
}
