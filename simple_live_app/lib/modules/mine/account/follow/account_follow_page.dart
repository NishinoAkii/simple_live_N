import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_controller.dart';
import 'package:simple_live_app/services/account_follow/account_follow_models.dart';
import 'package:simple_live_app/services/account_follow/account_follow_platforms.dart';
import 'package:simple_live_app/services/account_follow_service.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_app/widgets/site_logo.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 账号关注：从账号导入、与账号同步、在 App 里关注/取关时同步到账号
class AccountFollowPage extends GetView<AccountFollowController> {
  const AccountFollowPage({Key? key}) : super(key: key);

  static const _tipStyle = TextStyle(fontSize: 12, color: Colors.grey);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("账号关注".t)),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          Padding(
            padding: AppStyle.edgeInsetsH12,
            child: Text(
              ("把账号里的关注导入 App，或对比两边的差别。"
              "导入和同步预览都要确认，只改 App，不动账号。").t,
              style: _tipStyle,
            ),
          ),
          buildPending(context),
          for (var platform in AccountFollowPlatforms.all) ...[
            AppStyle.vGap12,
            buildPlatform(context, platform),
          ],
          AppStyle.vGap24,
        ],
      ),
    );
  }

  Widget buildPlatform(BuildContext context, AccountFollowPlatform platform) {
    var site = Sites.allSites[platform.siteId];
    var account = controller.account(platform.siteId);
    if (!platform.canImport || account == null) {
      return SettingsCard(
        child: Opacity(
          opacity: 0.6,
          child: ListTile(
            leading: SiteLogo(site, width: 32),
            title: Text(platform.name),
            subtitle: Text(platform.importUnsupportedReason ?? "暂不支持".t),
          ),
        ),
      );
    }
    var header = Obx(
      () => ListTile(
        leading: SiteLogo(site, width: 32),
        title: Text(platform.name),
        // 斗鱼等拿不到账号名时名字就是“已登录”，不要重复
        subtitle: Text(
          !account.logined.value
              ? "未登录，请先在账号管理里登录".t
              : account.name.value.isEmpty || account.name.value == "已登录"
                  ? "已登录".t
                  : "已登录：{name}".tf({"name": account.name.value}),
        ),
      ),
    );
    var word = platform.followWord;
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          AppStyle.divider,
          SettingsAction(
            title: "从账号导入{word}".tf({"word": word}),
            subtitle: "先看预览，挑选要加到 App 的".t,
            onTap: () => controller.openImport(platform.siteId),
          ),
          SettingsAction(
            title: "与账号同步".t,
            subtitle: "对比两边的变化，确认后再改".t,
            onTap: () => controller.openSync(platform.siteId),
          ),
          if (platform.canWriteBack && controller.service != null)
            Obx(() {
              var service = controller.service!;
              service.version.value;
              return SettingsSwitch(
                value: service.isWriteBackOn(platform.siteId),
                title: "在 App 里{word}/取关时同步到账号".tf({"word": word}),
                subtitle: "频繁操作可能触发风控".t,
                onChanged: (v) => controller.toggleWriteBack(platform, v),
              );
            })
          else if (platform.writeBackUnsupportedReason != null)
            ListTile(
              enabled: false,
              title: Text("同步到账号".t),
              subtitle: Text(platform.writeBackUnsupportedReason!),
            ),
        ],
      ),
    );
  }

  /// 待同步 / 失败
  Widget buildPending(BuildContext context) {
    var service = controller.service;
    if (service == null) {
      return const SizedBox();
    }
    return Obx(() {
      var jobs = service.jobs.toList();
      service.siteStates.length;
      var pausedSites = AccountFollowPlatforms.all
          .where((e) => controller.pauseText(e.siteId) != null)
          .where((e) => jobs.any((j) => j.siteId == e.siteId))
          .toList();
      if (jobs.isEmpty) {
        return const SizedBox();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "待同步 / 失败（{jobsCount}）".tf({"jobsCount": jobs.length}),
              style: Get.textTheme.titleSmall,
            ),
          ),
          for (var platform in pausedSites)
            Padding(
              padding: AppStyle.edgeInsetsB8,
              child: buildPaused(context, platform),
            ),
          SettingsCard(
            child: Column(
              children: [
                for (var job in jobs) buildJob(context, job),
              ],
            ),
          ),
        ],
      );
    });
  }

  Widget buildPaused(BuildContext context, AccountFollowPlatform platform) {
    return Material(
      color: Colors.amber.withAlpha(40),
      borderRadius: AppStyle.radius8,
      child: ListTile(
        leading: const Icon(Icons.pause_circle_outline, color: Colors.orange),
        title:
            Text("${platform.name}：${controller.pauseText(platform.siteId)}"),
        trailing: TextButton(
          onPressed: () => controller.resume(platform.siteId),
          child: Text("继续".t),
        ),
      ),
    );
  }

  Widget buildJob(BuildContext context, FollowWriteJob job) {
    var platform = AccountFollowPlatforms.of(job.siteId);
    var word = platform?.followWord ?? "关注##verb".t;
    var action = job.action == FollowWriteAction.follow ? word : "取消{word}".tf({"word": word});
    var failed = job.state == FollowWriteState.failed;
    return ListTile(
      leading: job.face.isEmpty
          ? const CircleAvatar(radius: 18, child: Icon(Icons.person_outline))
          : NetImage(job.face, width: 36, height: 36, borderRadius: 18),
      title: Text(
        // 这一行以动词开头，英文的首字母要大写
        "${upperFirst(action)} ${job.userName.isEmpty ? job.roomId : job.userName}",
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        "${AccountFollowService.siteName(job.siteId)} · ${controller.jobStatus(job)}",
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: failed ? Colors.red : Colors.grey,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (failed)
            IconButton(
              tooltip: "重试".t,
              icon: const Icon(Icons.refresh),
              onPressed: () => controller.retry(job),
            ),
          IconButton(
            tooltip: "放弃（不在账号上执行）".t,
            icon: const Icon(Icons.close),
            onPressed: () => controller.discard(job),
          ),
        ],
      ),
    );
  }
}
