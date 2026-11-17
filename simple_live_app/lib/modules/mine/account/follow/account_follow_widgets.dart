import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/account_follow/account_follow_platforms.dart';
import 'package:simple_live_app/services/account_follow_service.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/site_logo.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 选平台：不支持的灰色并写明原因，没登录的提示先登录
class AccountFollowPlatformPicker extends StatelessWidget {
  final void Function(String siteId) onPick;
  const AccountFollowPlatformPicker({required this.onPick, super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: AppStyle.edgeInsetsA12,
      children: [
        Padding(
          padding: AppStyle.edgeInsetsA12,
          child: Text(
            "选择平台，读取账号里的关注".t,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
        for (var platform in AccountFollowPlatforms.all)
          Builder(builder: (context) {
            var canRead = AccountFollowService.siteOf(platform.siteId)
                    ?.canReadAccountFollows ??
                false;
            var enabled = platform.canImport;
            return ListTile(
              enabled: enabled,
              leading: Opacity(
                opacity: enabled ? 1 : 0.5,
                child: SiteLogo(Sites.allSites[platform.siteId], width: 32),
              ),
              title: Text(platform.name),
              subtitle: Text(
                !enabled
                    ? platform.importUnsupportedReason ?? "暂不支持".t
                    : canRead
                        ? "已登录".t
                        : "未登录，请先在账号管理里登录".t,
              ),
              trailing: enabled ? const Icon(Icons.chevron_right) : null,
              onTap: !enabled
                  ? null
                  : () {
                      if (!canRead) {
                        SmartDialog.showToast("请先在账号管理里登录{name}".tf({"name": platform.name}));
                        return;
                      }
                      onPick(platform.siteId);
                    },
            );
          }),
      ],
    );
  }
}

/// 读取中：进度文字和取消按钮
class AccountFollowLoading extends StatelessWidget {
  final String text;
  final VoidCallback onCancel;
  const AccountFollowLoading({
    required this.text,
    required this.onCancel,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: AppStyle.edgeInsetsA24,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            AppStyle.vGap24,
            Text(text, textAlign: TextAlign.center),
            AppStyle.vGap12,
            TextButton(onPressed: onCancel, child: Text("取消".t)),
          ],
        ),
      ),
    );
  }
}

/// 出错：原因和重试按钮
class AccountFollowError extends StatelessWidget {
  final String text;
  final VoidCallback onRetry;
  const AccountFollowError({
    required this.text,
    required this.onRetry,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: AppStyle.edgeInsetsA24,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Colors.grey),
            AppStyle.vGap12,
            Text(text, textAlign: TextAlign.center),
            AppStyle.vGap12,
            TextButton(onPressed: onRetry, child: Text("重试".t)),
          ],
        ),
      ),
    );
  }
}

/// 黄色提示条
class AccountFollowBanner extends StatelessWidget {
  final String text;
  const AccountFollowBanner(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: AppStyle.edgeInsetsA8,
      padding: AppStyle.edgeInsetsA12,
      decoration: BoxDecoration(
        color: Colors.amber.withAlpha(40),
        borderRadius: AppStyle.radius8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: Colors.orange),
          AppStyle.hGap8,
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

/// 头像
class AccountFollowAvatar extends StatelessWidget {
  final String face;
  const AccountFollowAvatar(this.face, {super.key});

  @override
  Widget build(BuildContext context) {
    if (face.isEmpty) {
      return const CircleAvatar(radius: 20, child: Icon(Icons.person_outline));
    }
    return NetImage(face, width: 40, height: 40, borderRadius: 20);
  }
}

/// 名字后面的“直播中”绿点
class AccountFollowName extends StatelessWidget {
  final String name;
  final bool? isLive;
  const AccountFollowName(this.name, {this.isLive, super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (isLive == true) ...[
          AppStyle.hGap8,
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Colors.green,
              shape: BoxShape.circle,
            ),
          ),
          AppStyle.hGap4,
          Text("直播中".t, style: const TextStyle(fontSize: 12)),
        ],
      ],
    );
  }
}
