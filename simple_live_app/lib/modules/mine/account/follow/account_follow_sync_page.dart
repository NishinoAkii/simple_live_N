import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_import_controller.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_sync_controller.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_widgets.dart';
import 'package:simple_live_app/services/account_follow/account_follow_diff.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 与账号同步：分组列出两边的变化，勾选后执行
class AccountFollowSyncPage extends GetView<AccountFollowSyncController> {
  const AccountFollowSyncPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Obx(
          () => Text(
            controller.siteId.value == null
                ? "与账号同步".t
                : "与{platformName}账号同步".tf({"platformName": controller.platformName}),
          ),
        ),
      ),
      body: Obx(() {
        switch (controller.stage.value) {
          case AccountFollowStage.pick:
            return AccountFollowPlatformPicker(onPick: controller.pick);
          case AccountFollowStage.loading:
            return AccountFollowLoading(
              text: controller.progress.value,
              onCancel: controller.cancel,
            );
          case AccountFollowStage.error:
            return AccountFollowError(
              text: controller.error.value,
              onRetry: controller.load,
            );
          case AccountFollowStage.loaded:
            return buildDiff(context);
        }
      }),
    );
  }

  String groupTitle(SyncChangeKind kind) {
    var word = controller.followWord;
    switch (kind) {
      case SyncChangeKind.addToApp:
        return "账号新增 · 加到 App".t;
      case SyncChangeKind.restoreToApp:
        return "账号里有、App 里没有 · 加到 App".t;
      case SyncChangeKind.removeFromApp:
        return "账号上取消{word}了 · 从 App 移除".tf({"word": word});
      case SyncChangeKind.followOnAccount:
        return "App 里新增 · 在账号上{word}".tf({"word": word});
      case SyncChangeKind.unfollowOnAccount:
        return "App 里取消了 · 在账号上取消{word}".tf({"word": word});
    }
  }

  Widget buildDiff(BuildContext context) {
    var diff = controller.diff.value!;
    var fetch = controller.result!.fetch;
    var tips = <Widget>[
      if (diff.warning != null) AccountFollowBanner(diff.warning!),
      if (diff.firstSync && fetch.complete)
        AccountFollowBanner("首次同步或换了账号，这次不会建议从 App 移除。".t),
    ];
    var hint =
        !controller.writeBack && (controller.platform?.canWriteBack ?? false)
            ? "打开“同步到账号”后，这里还会列出 App 里的改动。".t
            : null;
    var footer = [
      "两边一致 {inSync} 个".tf({"inSync": diff.inSync}),
      if (diff.ignored > 0) "选过“仅在 App 里取消”的 {ignored} 个不再提示".tf({"ignored": diff.ignored}),
    ].join("，".t);
    if (diff.isEmpty) {
      return ListView(
        children: [
          ...tips,
          Padding(
            padding: AppStyle.edgeInsetsA24,
            child: Column(
              children: [
                const Icon(Icons.check_circle_outline,
                    size: 40, color: Colors.green),
                AppStyle.vGap12,
                Text("没有要改的。{footer}".tf({"footer": footer}), textAlign: TextAlign.center),
                if (hint != null) ...[
                  AppStyle.vGap12,
                  Text(hint,
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Obx(() {
            controller.version.value;
            return ListView(
              children: [
                ...tips,
                for (var kind in SyncChangeKind.values)
                  if (diff.of(kind).isNotEmpty)
                    ...buildGroup(kind, diff.of(kind)),
                Padding(
                  padding: AppStyle.edgeInsetsA12,
                  child: Text(
                    [footer, if (hint != null) hint].join("\n"),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            );
          }),
        ),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Padding(
            padding: AppStyle.edgeInsetsA8,
            child: Obx(() {
              controller.version.value;
              var count = controller.selectedCount;
              return FilledButton(
                onPressed: controller.saving.value || count == 0
                    ? null
                    : controller.apply,
                child: Text(count == 0 ? "勾选要执行的项目".t : "执行（{count} 项）".tf({"count": count})),
              );
            }),
          ),
        ),
      ],
    );
  }

  List<Widget> buildGroup(SyncChangeKind kind, List<SyncChange> changes) {
    var selected = changes.where((e) => e.selected).length;
    return [
      ListTile(
        dense: true,
        title: Text(
          "${groupTitle(kind)}（${changes.length}）",
          style: Get.textTheme.titleSmall,
        ),
        trailing: Checkbox(
          tristate: true,
          value: selected == 0
              ? false
              : selected == changes.length
                  ? true
                  : null,
          onChanged: (_) =>
              controller.selectGroup(kind, selected != changes.length),
        ),
      ),
      for (var change in changes)
        CheckboxListTile(
          dense: true,
          value: change.selected,
          onChanged: (v) => controller.toggle(change, v ?? false),
          secondary: AccountFollowAvatar(change.face),
          title:
              AccountFollowName(change.userName, isLive: change.item?.isLive),
          subtitle: change.note == null
              ? null
              : Text(change.note!, style: const TextStyle(fontSize: 12)),
        ),
      const Divider(height: 1),
    ];
  }
}
