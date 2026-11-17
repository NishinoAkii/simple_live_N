import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 确认里的一行：[warn] 为 true 时用醒目的颜色（权限扩大、签名问题）
typedef LiveSourcePermissionLine = ({String text, bool warn});

/// 安装、更新直播源前的确认：能访问的域名、敏感功能、签名；更新时显示和已安装版本的差别
class LiveSourcePermissionDialog {
  /// 签名状态的说明（详情页、订阅卡片也用）
  static String signatureText(String? publicKey) => publicKey == null
      ? "未签名：无法确认脚本是谁发布的".t
      : "已签名：发布者公钥指纹 {liveSourceKeyFingerprint}".tf({"liveSourceKeyFingerprint": liveSourceKeyFingerprint(publicKey)});

  /// 确认里的各行（测试也用）
  static List<LiveSourcePermissionLine> lines(LiveSourcePlan plan) {
    var next = plan.next;
    var out = <LiveSourcePermissionLine>[];
    if (plan.losesSignature) {
      out.add((
        text: plan.signed
            ? ("发布者公钥变了：安装时 {liveSourceKeyFingerprint}，"
                "现在 {liveSourceKeyFingerprint2}").tf({"liveSourceKeyFingerprint": liveSourceKeyFingerprint(plan.currentPublicKey!), "liveSourceKeyFingerprint2": liveSourceKeyFingerprint(plan.publicKey!)})
            : "已安装的版本有签名，这个版本没有".t,
        warn: true,
      ));
    } else {
      out.add((text: signatureText(plan.publicKey), warn: false));
    }
    if (plan.isUpdate) {
      var diff = plan.diff;
      if (diff.isEmpty) {
        out.add((text: "权限没有变化".t, warn: false));
      }
      out.addAll(diff.lines());
      return out;
    }
    out.add((
      text: next.domains.isEmpty
          ? "不能访问任何网站".t
          : "可以访问的域名：{domains}".tf({"domains": next.domains.join("、".t)}),
      warn: false,
    ));
    // 内置平台的修正：写清楚替换哪个平台的哪些功能、用不用帐号
    var target = next.overrides;
    if (target != null) {
      for (var line in describeLiveSourceOverride(
        target,
        next.overrideFunctions,
        useAccount: next.useAccount,
      )) {
        out.add((text: line, warn: true));
      }
      out.add((
        text: ("不会多出平台；装好后可在直播源详情里关掉，"
            "或设成出错时改用内置").t,
        warn: false,
      ));
    }
    var sensitive = next.capabilities
        .where(kLiveSourceSensitiveCapabilities.contains)
        .where((c) => target == null || (c != "overrides" && c != "useAccount"))
        .toList();
    for (var c in sensitive) {
      out.add((text: liveSourceCapabilityLabel(c), warn: true));
    }
    if (next.login != null) {
      out.add((
        text: "登录页：{p}".tf({"p": Uri.tryParse(next.login!.url)?.host ?? next.login!.url}),
        warn: false,
      ));
    }
    if (next.settings.isNotEmpty) {
      out.add((text: "有 {settingsCount} 个设置项（在直播源详情里改）".tf({"settingsCount": next.settings.length}), warn: false));
    }
    return out;
  }

  /// 用户同意时返回 true
  static Future<bool> show(LiveSourcePlan plan) async {
    var next = plan.next;
    var title = plan.isUpdate ? "更新直播源".t : "安装直播源".t;
    var header = plan.isUpdate
        ? "${next.name}：${plan.current!.version} → ${next.version}"
        : "${next.name} ${next.version}（${next.key}）";
    var result = await Get.dialog<bool>(
      Builder(
        builder: (context) {
          var theme = Theme.of(context);
          return AlertDialog(
            title: Text(title),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(header, style: theme.textTheme.titleSmall),
                    AppStyle.vGap8,
                    for (var line in lines(plan))
                      Padding(
                        padding: AppStyle.edgeInsetsV4,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              line.warn
                                  ? Icons.warning_amber_rounded
                                  : Icons.info_outline,
                              size: 18,
                              color: line.warn
                                  ? theme.colorScheme.error
                                  : Colors.grey,
                            ),
                            AppStyle.hGap8,
                            Expanded(
                              child: SelectableText(
                                line.text,
                                style: line.warn
                                    ? TextStyle(color: theme.colorScheme.error)
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    AppStyle.vGap8,
                    Text(
                      ("直播源只能访问它写明的域名；Cookie、设置只存在本机。"
                      "只安装你信任的来源。").t,
                      style: theme.textTheme.bodySmall!
                          .copyWith(color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Get.back(result: false),
                child: Text("取消".t),
              ),
              TextButton(
                onPressed: () => Get.back(result: true),
                child: Text(plan.isUpdate ? "更新".t : "安装".t),
              ),
            ],
          );
        },
      ),
    );
    return result ?? false;
  }
}
