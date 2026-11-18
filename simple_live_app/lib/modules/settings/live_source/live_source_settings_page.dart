import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/account/live_source_login.dart';
import 'package:simple_live_app/modules/settings/live_source/live_source_permission_dialog.dart';
import 'package:simple_live_app/modules/settings/live_source/live_source_settings_controller.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_app/widgets/site_logo.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 直播源订阅：安装 .live.js 直播源、管理订阅与更新
class LiveSourceSettingsPage extends GetView<LiveSourceSettingsController> {
  const LiveSourceSettingsPage({super.key});

  static const _grey = TextStyle(fontSize: 12, color: Colors.grey);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("直播源订阅".t),
      ),
      body: Obx(
        () => ListView(
          padding: AppStyle.edgeInsetsA12,
          children: [
            if (!controller.service.available.value) _buildUnavailable(context),
            Padding(
              padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
              child: Text(
                ("每个直播源是一个 .live.js 文件，写法见模板 live_sources/_template.live.js。"
                "装好后，带推荐、分类或搜索的会出现在对应页面。").t,
                style: Get.textTheme.bodySmall!.copyWith(color: Colors.grey),
              ),
            ),
            _buildTitle("添加".t, top: 12),
            SettingsCard(
              child: Column(
                children: [
                  SettingsAction(
                    title: "通过链接安装".t,
                    subtitle: "输入 .live.js 文件的地址".t,
                    onTap: controller.installFromUrlDialog,
                  ),
                  AppStyle.divider,
                  SettingsAction(
                    title: "从文件安装".t,
                    subtitle: "选择本机的 .live.js 文件".t,
                    onTap: controller.installFromFile,
                  ),
                  AppStyle.divider,
                  SettingsAction(
                    title: "添加订阅".t,
                    subtitle: "输入订阅（index.json）的地址".t,
                    onTap: controller.addSubscriptionDialog,
                  ),
                ],
              ),
            ),
            _buildTitle("已安装（{sitesCount}）".tf({"sitesCount": controller.service.sites.length})),
            _buildInstalled(context),
            _buildTitle("订阅（{subscriptionsCount}）".tf({"subscriptionsCount": controller.service.subscriptions.length})),
            ..._buildSubscriptions(context),
            _buildTitle("更新".t),
            _buildUpdates(context),
            _buildTitle("开发者选项".t),
            _buildDeveloper(context),
            AppStyle.vGap24,
          ],
        ),
      ),
    );
  }

  Widget _buildTitle(String title, {double top = 24}) {
    return Padding(
      padding: AppStyle.edgeInsetsA12.copyWith(top: top),
      child: Text(
        title,
        style: Get.textTheme.titleSmall,
      ),
    );
  }

  Widget _buildUnavailable(BuildContext context) {
    var reason = controller.service.initError.value;
    return Padding(
      padding: AppStyle.edgeInsetsB12,
      child: SettingsCard(
        child: ListTile(
          leading: Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.error,
          ),
          title: Text("直播源功能不可用".t),
          subtitle: Text(reason.isEmpty ? "正在加载…".t : reason, style: _grey),
        ),
      ),
    );
  }

  Widget _buildInstalled(BuildContext context) {
    var sites = controller.service.sites;
    var errors = controller.service.loadErrors;
    if (sites.isEmpty && errors.isEmpty) {
      return SettingsCard(
        child: ListTile(
          title: Text("还没有安装直播源".t, style: _grey),
        ),
      );
    }
    var children = <Widget>[];
    for (var site in sites) {
      if (children.isNotEmpty) {
        children.add(AppStyle.divider);
      }
      children.add(_buildInstalledItem(context, site.info));
    }
    errors.forEach((file, reason) {
      if (children.isNotEmpty) {
        children.add(AppStyle.divider);
      }
      children.add(
        ListTile(
          leading: Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.error,
          ),
          title: Text(file, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            reason,
            style: _grey,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: TextButton(
            onPressed: () => controller.showLoadError(file, reason),
            child: Text("查看出错原因".t),
          ),
          onTap: () => controller.showLoadError(file, reason),
        ),
      );
    });
    return SettingsCard(child: Column(children: children));
  }

  Widget _buildInstalledItem(BuildContext context, LiveSourceInfo info) {
    var update = controller.updateOf(info.key);
    var url = controller.service.updateUrl(info.key) ?? "";
    var signed = controller.service.publicKeyOf(info.key) != null;
    var target = info.overrides;
    var status =
        target == null ? null : controller.service.overrideStatus(info.key);
    return ListTile(
      contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 4),
      // 内置平台的修正用那个平台的图标
      leading: SiteLogo(
        Sites.allSites[target ?? info.siteId],
        width: 32,
        height: 32,
      ),
      title: Text(info.name),
      onTap: () => controller.openDetail(info),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "${info.version} · ${info.key} · ${signed ? "已签名".t : "未签名".t}",
            style: _grey,
          ),
          if (target != null)
            Text(
              ("替换内置的 {builtInSiteName}"
              "（{map}）"
              " · {p}").tf({"builtInSiteName": builtInSiteName(target), "map": info.overrideFunctions.map(liveSourceOverrideFunctionLabel).join("、".t), "p": status?.active ?? false ? "生效中".t : "没有生效".t}),
              style: TextStyle(
                fontSize: 12,
                color: status?.active ?? false
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          Text(
            url.isEmpty ? "更新地址：无".t : "更新地址：{url}".tf({"url": url}),
            style: _grey,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (update != null)
            Text(
              "可以更新到 {version}".tf({"version": update.version}),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
        ],
      ),
      trailing: PopupMenuButton<int>(
        tooltip: "操作".t,
        onSelected: (value) {
          if (value == 0) {
            controller.updateSource(info);
          } else if (value == 3) {
            controller.openDetail(info);
          } else if (value == 1) {
            controller.removeSource(info);
          } else if (value == 2) {
            var site = controller.service.siteOf(info.key);
            if (site != null) {
              LiveSourceLoginFlow.tap(site);
            }
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 0,
            child: Text(update == null ? "更新".t : "更新到 {version}".tf({"version": update.version})),
          ),
          PopupMenuItem(
            value: 3,
            child: Text(info.settings.isEmpty ? "详情和权限".t : "详情和设置".t),
          ),
          // 脚本声明了 login 的源：登录 / 退出登录
          if (info.login != null)
            PopupMenuItem(
              value: 2,
              child: Text(
                controller.service.accounts[info.key]?.loggedIn ?? false
                    ? "退出登录".t
                    : "登录".t,
              ),
            ),
          PopupMenuItem(
            value: 1,
            child: Text("删除".t),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSubscriptions(BuildContext context) {
    var subs = controller.service.subscriptions;
    if (subs.isEmpty) {
      var fallback = controller.defaultSubscription;
      return [
        SettingsCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text("还没有添加订阅".t, style: _grey),
              ),
              // 默认的订阅（UpdateConfig.liveSourceSubscription），点一下添加
              if (fallback.isNotEmpty)
                SettingsAction(
                  title: "添加默认订阅".t,
                  subtitle: fallback,
                  onTap: controller.addDefaultSubscription,
                ),
            ],
          ),
        ),
      ];
    }
    var result = <Widget>[];
    for (var url in subs) {
      if (result.isNotEmpty) {
        result.add(AppStyle.vGap12);
      }
      result.add(_buildSubscription(context, url));
    }
    return result;
  }

  Widget _buildSubscription(BuildContext context, String url) {
    var loading = controller.loading.contains(url);
    var error = controller.entryErrors[url];
    var entries = controller.entries[url];
    // 读取过订阅后才知道公钥有没有变（entries 变化时重建）
    var publicKey = controller.service.subscriptionPublicKey(url);
    var keyError = controller.service.subscriptionKeyError(url);
    var name = controller.service.subscriptionName(url);
    var children = <Widget>[
      ListTile(
        contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 4),
        leading: const Icon(Icons.rss_feed),
        title: Text(
          name ?? url,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Get.textTheme.bodyMedium,
        ),
        subtitle: Text(
          [
            if (name != null) url,
            LiveSourcePermissionDialog.signatureText(publicKey),
          ].join("\n"),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: _grey,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            loading
                ? const Padding(
                    padding: AppStyle.edgeInsetsA12,
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: "刷新".t,
                    onPressed: () => controller.refreshSubscription(url),
                    icon: const Icon(Icons.refresh),
                  ),
            IconButton(
              tooltip: "删除订阅".t,
              onPressed: () => controller.removeSubscription(url),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    ];
    if (keyError != null) {
      children.add(AppStyle.divider);
      children.add(
        ListTile(
          leading: Icon(
            Icons.gpp_bad_outlined,
            color: Theme.of(context).colorScheme.error,
          ),
          title: Text(
            keyError,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      );
    }
    if (error != null) {
      children.add(AppStyle.divider);
      children.add(
        ListTile(
          title: Text("读取失败：{error}".tf({"error": error}), style: _grey),
          trailing: TextButton(
            onPressed: () => controller.refreshSubscription(url),
            child: Text("重试".t),
          ),
        ),
      );
    } else if (entries != null && entries.isEmpty) {
      children.add(AppStyle.divider);
      children.add(
        ListTile(title: Text("订阅里没有直播源".t, style: _grey)),
      );
    } else if (entries != null) {
      for (var entry in entries) {
        children.add(AppStyle.divider);
        children.add(_buildEntry(context, entry));
      }
    }
    return SettingsCard(child: Column(children: children));
  }

  Widget _buildEntry(BuildContext context, LiveSourceIndexEntry entry) {
    var state = controller.entryState(entry);
    var description = entry.description ?? "";
    Widget action;
    if (entry.blockedReason != null && state != LiveSourceEntryState.latest) {
      // 订阅的公钥变了：不能从这里安装、更新（原因显示在订阅卡片上）
      return ListTile(
        contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 8),
        title: Text(entry.name),
        subtitle: Text("${entry.version} · ${entry.key}", style: _grey),
        trailing: Padding(
          padding: AppStyle.edgeInsetsH12,
          child: Text("已停止".t, style: _grey),
        ),
      );
    }
    switch (state) {
      case LiveSourceEntryState.notInstalled:
        action = FilledButton.tonal(
          onPressed: () => controller.installEntry(entry),
          child: Text("安装".t),
        );
        break;
      case LiveSourceEntryState.hasUpdate:
        var info = controller.service.siteOf(entry.key)?.info;
        action = FilledButton.tonal(
          onPressed: info == null ? null : () => controller.updateSource(info),
          child: Text("更新到 {version}".tf({"version": entry.version})),
        );
        break;
      case LiveSourceEntryState.latest:
        action = Padding(
          padding: AppStyle.edgeInsetsH12,
          child: Text("已是最新".t, style: _grey),
        );
        break;
    }
    return ListTile(
      contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 8),
      title: Text(entry.name),
      subtitle: Text(
        description.isEmpty
            ? "${entry.version} · ${entry.key}"
            : "${entry.version} · ${entry.key}\n$description",
        style: _grey,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: action,
    );
  }

  Widget _buildDeveloper(BuildContext context) {
    return SettingsCard(
      child: SettingsSwitch(
        value: controller.service.allowUnsignedOverrides.value,
        title: "允许未签名的内置平台修正（不安全）".t,
        subtitle: "只在自己写、测试修正时打开，用完关掉".t,
        onChanged: controller.setAllowUnsignedOverrides,
      ),
    );
  }

  Widget _buildUpdates(BuildContext context) {
    var updates = controller.service.updates;
    return SettingsCard(
      child: Column(
        children: [
          SettingsAction(
            title: "检查更新".t,
            subtitle: "检查订阅里有没有新版本".t,
            value: controller.checking.value
                ? "检查中…".t
                : (updates.isEmpty ? null : "{updatesCount} 个可更新".tf({"updatesCount": updates.length})),
            onTap: controller.checkUpdates,
          ),
          if (updates.isNotEmpty) ...[
            AppStyle.divider,
            SettingsAction(
              title: "全部更新".t,
              subtitle: updates.map((e) => "${e.name} ${e.version}").join("、".t),
              onTap: controller.updateAll,
            ),
          ],
          AppStyle.divider,
          SettingsSwitch(
            value: controller.service.autoCheck.value,
            title: "每天自动检查更新".t,
            subtitle: "打开 App 时检查，有新版本会提醒".t,
            onChanged: controller.setAutoCheck,
          ),
        ],
      ),
    );
  }
}
