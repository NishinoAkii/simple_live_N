import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_import_controller.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_widgets.dart';
import 'package:simple_live_app/services/account_follow/account_follow_diff.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 从账号导入关注：预览列表，勾选后添加到 App
class AccountFollowImportPage extends GetView<AccountFollowImportController> {
  const AccountFollowImportPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Obx(
          () => Text(
            controller.siteId.value == null
                ? "从账号导入关注".t
                : "从{platformName}导入关注".tf({"platformName": controller.platformName}),
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
            return buildPreview(context);
        }
      }),
    );
  }

  Widget buildPreview(BuildContext context) {
    var fetch = controller.result!.fetch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!fetch.complete)
          AccountFollowBanner(
            "{p}，下面只有读到的部分".tf({"p": fetch.incompleteReason ?? "列表没读完".t}),
          ),
        Padding(
          padding: AppStyle.edgeInsetsH12.copyWith(top: 8),
          child: Obx(
            () => Text(
              ("账号里 {entriesCount} 个，"
              "已在关注里 {followedCount} 个，"
              "已选 {selectedCount} 个").tf({"entriesCount": controller.entries.length, "followedCount": controller.followedCount, "selectedCount": controller.selectedCount}),
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
        ),
        buildToolbar(context),
        const Divider(height: 1),
        Expanded(
          child: Obx(() {
            var list = controller.visible;
            if (controller.entries.isEmpty) {
              return Center(child: Text("账号里还没有关注".t));
            }
            if (list.isEmpty) {
              return Center(child: Text("没有符合条件的".t));
            }
            return ListView.builder(
              itemCount: list.length,
              itemBuilder: (_, i) => buildEntry(list[i]),
            );
          }),
        ),
        const Divider(height: 1),
        buildBottom(context),
      ],
    );
  }

  Widget buildToolbar(BuildContext context) {
    return Padding(
      padding: AppStyle.edgeInsetsH8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: "搜索名字".t,
              border: InputBorder.none,
            ),
            onChanged: (v) => controller.keyword.value = v,
          ),
          Row(
            children: [
              Obx(
                () => FilterChip(
                  label: Text("只看直播中".t),
                  selected: controller.onlyLive.value,
                  onSelected: (v) => controller.onlyLive.value = v,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => controller.selectAll(true),
                child: Text("全选".t),
              ),
              TextButton(
                onPressed: () => controller.selectAll(false),
                child: Text("全不选".t),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildEntry(ImportPreviewEntry entry) {
    var followed = entry.alreadyFollowed;
    var hint = followed
        ? "已在关注里".t
        : entry.removedBefore
            ? "以前在 App 里取消过".t
            : null;
    return Opacity(
      opacity: followed ? 0.5 : 1,
      child: CheckboxListTile(
        value: followed ? true : entry.selected,
        onChanged:
            followed ? null : (v) => controller.toggle(entry, v ?? false),
        secondary: AccountFollowAvatar(entry.item.face),
        title:
            AccountFollowName(entry.item.userName, isLive: entry.item.isLive),
        subtitle: hint == null
            ? null
            : Text(hint, style: const TextStyle(fontSize: 12)),
        dense: true,
      ),
    );
  }

  Widget buildBottom(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: AppStyle.edgeInsetsA8,
        child: Row(
          children: [
            Text("放入标签".t),
            AppStyle.hGap8,
            Expanded(
              child: Obx(() {
                var tags = controller.existingTags;
                var hasNew = tags.contains(controller.newTagName);
                return DropdownButton<String>(
                  isExpanded: true,
                  value: controller.tag.value,
                  items: [
                    DropdownMenuItem(value: "", child: Text("不放".t)),
                    if (!hasNew)
                      DropdownMenuItem(
                        value: AccountFollowImportController.kNewTag,
                        child: Text("新建「{newTagName}」".tf({"newTagName": controller.newTagName})),
                      ),
                    for (var tag in tags)
                      DropdownMenuItem(value: tag, child: Text(tag)),
                  ],
                  onChanged: (v) => controller.tag.value = v ?? "",
                );
              }),
            ),
            AppStyle.hGap8,
            Obx(
              () => FilledButton(
                onPressed:
                    controller.saving.value || controller.selectedCount == 0
                        ? null
                        : controller.apply,
                child: Text("添加 {selectedCount} 个".tf({"selectedCount": controller.selectedCount})),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
