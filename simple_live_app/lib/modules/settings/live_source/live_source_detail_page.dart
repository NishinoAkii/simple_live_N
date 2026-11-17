import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/settings/live_source/live_source_permission_dialog.dart';
import 'package:simple_live_app/services/live_source_service.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_app/widgets/site_logo.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 一个直播源的详情：版本、签名、能访问的域名、敏感功能，以及脚本声明的设置项；
/// 内置平台的修正另有替换了什么、开关和“失败时改用内置”。参数（Get.arguments）为源的 key
class LiveSourceDetailPage extends StatefulWidget {
  const LiveSourceDetailPage({super.key});

  @override
  State<LiveSourceDetailPage> createState() => _LiveSourceDetailPageState();
}

class _LiveSourceDetailPageState extends State<LiveSourceDetailPage> {
  static const _grey = TextStyle(fontSize: 12, color: Colors.grey);

  final String sourceKey = Get.arguments?.toString() ?? "";
  LiveSourceService get service => LiveSourceService.instance;

  /// 设置项的当前值（读取前为 null）
  Map<String, dynamic>? values;
  String? settingsError;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    var site = service.siteOf(sourceKey);
    if (site == null || site.settings.isEmpty) {
      return;
    }
    try {
      var v = await service.getSettings(sourceKey);
      if (mounted) setState(() => values = v);
    } catch (e) {
      if (mounted) {
        setState(() => settingsError = LiveSourceService.errorText(e));
      }
    }
  }

  Future<void> _change(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      SmartDialog.showToast("保存失败：{errorText}".tf({"errorText": LiveSourceService.errorText(e)}));
    }
    if (mounted) setState(() {});
  }

  Future<void> _set(LiveSourceSetting setting, dynamic value) async {
    try {
      var v = await service.setSetting(sourceKey, setting.key, value);
      if (mounted) setState(() => values = v);
    } catch (e) {
      SmartDialog.showToast("保存失败：{errorText}".tf({"errorText": LiveSourceService.errorText(e)}));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      var site = service.sites.firstWhereOrNull((e) => e.info.key == sourceKey);
      return Scaffold(
        appBar: AppBar(title: Text(site?.info.name ?? "直播源".t)),
        body: site == null
            ? Center(child: Text("这个直播源已经删除".t, style: _grey))
            : ListView(
                padding: AppStyle.edgeInsetsA12,
                children: _buildBody(context, site.info),
              ),
      );
    });
  }

  List<Widget> _buildBody(BuildContext context, LiveSourceInfo info) {
    var url = service.updateUrl(info.key) ?? "";
    var publicKey = service.publicKeyOf(info.key);
    var sensitive = info.capabilities
        .where(kLiveSourceSensitiveCapabilities.contains)
        .toList();
    var features = info.capabilities
        .where((e) => !kLiveSourceSensitiveCapabilities.contains(e))
        .toList();
    return [
      SettingsCard(
        child: ListTile(
          leading: SiteLogo(
            Sites.allSites[info.overrides ?? info.siteId],
            width: 36,
            height: 36,
          ),
          title: Text(info.name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("${info.version} · ${info.key}", style: _grey),
              if ((info.description ?? "").isNotEmpty)
                Text(info.description!, style: _grey),
              Text(url.isEmpty ? "更新地址：无".t : "更新地址：{url}".tf({"url": url}), style: _grey),
              Text(
                LiveSourcePermissionDialog.signatureText(publicKey),
                style: _grey,
              ),
            ],
          ),
        ),
      ),
      if (info.overrides != null) ...[
        _title("替换内置平台".t),
        _buildOverride(context, info),
      ],
      _title("权限".t),
      SettingsCard(
        child: Column(
          children: [
            ListTile(
              title: Text("可以访问的域名".t),
              subtitle: SelectableText(
                info.domains.isEmpty ? "（无）".t : info.domains.join("\n"),
                style: _grey,
              ),
            ),
            AppStyle.divider,
            ListTile(
              title: Text("敏感功能".t),
              subtitle: Text(
                sensitive.isEmpty
                    ? "（无）".t
                    : sensitive.map(liveSourceCapabilityLabel).join("\n"),
                style: _grey,
              ),
            ),
            AppStyle.divider,
            ListTile(
              title: Text("功能".t),
              subtitle: Text(features.join("、".t), style: _grey),
            ),
          ],
        ),
      ),
      if (info.settings.isNotEmpty) ...[
        _title("设置".t),
        _buildSettings(context, info.settings),
        Padding(
          padding: AppStyle.edgeInsetsA12,
          child: Text(
            "设置只存在本机，不同步；下次调用时生效。".t,
            style: Get.textTheme.bodySmall!.copyWith(color: Colors.grey),
          ),
        ),
      ],
      AppStyle.vGap24,
    ];
  }

  Widget _buildOverride(BuildContext context, LiveSourceInfo info) {
    var target = info.overrides!;
    var functions = [
      for (var f in kLiveSourceOverridableFunctions)
        if (info.overrideFunctions.contains(f))
          liveSourceOverrideFunctionLabel(f),
    ];
    var status = service.overrideStatus(info.key);
    var active = status?.active ?? false;
    return SettingsCard(
      child: Column(
        children: [
          ListTile(
            leading: SiteLogo(Sites.allSites[target], width: 32, height: 32),
            title: Text(
              "替换内置平台：{builtInSiteName}（{functions}）".tf({"builtInSiteName": builtInSiteName(target), "functions": functions.join("、".t)}),
            ),
            subtitle: Text(
              [
                if (status != null) status.text,
                if (info.useAccount)
                  ("用你登录的 {builtInSiteName} 帐号："
                      "只在发往 {p} "
                      "的请求上加登录信息，脚本读不到 Cookie").tf({"builtInSiteName": builtInSiteName(target), "p": (kBuiltInAccountHosts[target] ?? const []).join("、".t)}),
              ].join("\n"),
              style: active
                  ? TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : _grey,
            ),
          ),
          AppStyle.divider,
          SettingsSwitch(
            value: service.overrideEnabled(info.key),
            title: "启用".t,
            subtitle: "关掉后 {builtInSiteName} 全部用 App 内置的代码".tf({"builtInSiteName": builtInSiteName(target)}),
            onChanged: (v) =>
                _change(() => service.setOverrideEnabled(info.key, v)),
          ),
          AppStyle.divider,
          SettingsSwitch(
            value: service.overrideFallback(info.key),
            title: "失败时改用内置".t,
            subtitle: "脚本出错或超时时改用内置代码，并记日志".t,
            onChanged: (v) =>
                _change(() => service.setOverrideFallback(info.key, v)),
          ),
        ],
      ),
    );
  }

  Widget _title(String text) => Padding(
        padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
        child: Text(text, style: Get.textTheme.titleSmall),
      );

  Widget _buildSettings(BuildContext context, List<LiveSourceSetting> list) {
    var v = values;
    if (settingsError != null) {
      return SettingsCard(
        child: ListTile(
          title: Text("读取设置失败：{settingsError}".tf({"settingsError": settingsError}), style: _grey),
          trailing: TextButton(
            onPressed: () {
              setState(() => settingsError = null);
              _loadSettings();
            },
            child: Text("重试".t),
          ),
        ),
      );
    }
    if (v == null) {
      return SettingsCard(
        child: ListTile(title: Text("正在读取…".t, style: _grey)),
      );
    }
    var children = <Widget>[];
    for (var s in list) {
      if (children.isNotEmpty) children.add(AppStyle.divider);
      children.add(_buildSetting(s, s.valueIn(v)));
    }
    return SettingsCard(child: Column(children: children));
  }

  Widget _buildSetting(LiveSourceSetting s, dynamic value) {
    switch (s.type) {
      case "switch":
        return SettingsSwitch(
          value: value == true,
          title: s.label,
          subtitle: s.description,
          onChanged: (b) => _set(s, b),
        );
      case "select":
        var index = s.options.indexWhere((o) => o.value == value);
        return SettingsAction(
          title: s.label,
          subtitle: s.description,
          value: index < 0 ? null : s.options[index].label,
          onTap: () async {
            var picked = await Utils.showMapOptionDialog<int>(
              {
                for (var i = 0; i < s.options.length; i++) i: s.options[i].label
              },
              index,
              title: s.label,
            );
            if (picked != null) _set(s, s.options[picked].value);
          },
        );
      default:
        var text = value?.toString() ?? "";
        var range = [
          if (s.min != null) "最小 {min}".tf({"min": s.min}),
          if (s.max != null) "最大 {max}".tf({"max": s.max}),
        ].join("，".t);
        return SettingsAction(
          title: s.label,
          subtitle: s.description,
          value: text.isEmpty
              ? "未填".t
              : (text.length > 16 ? "${text.substring(0, 16)}…" : text),
          onTap: () async {
            var input = await Utils.showEditTextDialog(
              text,
              title: s.label,
              hintText: s.placeholder ?? (range.isEmpty ? s.label : range),
              validate: (t) {
                if (s.coerce(s.type == "number" ? t.trim() : t) != null) {
                  return true;
                }
                SmartDialog.showToast(
                  range.isEmpty ? "请输入数字".t : "请输入数字（{range}）".tf({"range": range}),
                );
                return false;
              },
            );
            if (input != null) {
              _set(s, s.type == "number" ? num.tryParse(input.trim()) : input);
            }
          },
        );
    }
  }
}
