import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/mine/account/youtube/youtube_account_controller.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// YouTube 账号：同步关注用，观看不需要登录
class YouTubeAccountPage extends GetView<YouTubeAccountController> {
  const YouTubeAccountPage({Key? key}) : super(key: key);

  static const _tipStyle = TextStyle(fontSize: 12, color: Colors.grey);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("YouTube 账号".t),
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          Padding(
            padding: AppStyle.edgeInsetsH12,
            child: Text(
              "两种方式选一种，都登录时优先用谷歌官方授权。".t,
              style: _tipStyle,
            ),
          ),
          buildTitle("谷歌官方授权（推荐）".t),
          SettingsCard(child: buildOAuth(context)),
          AppStyle.vGap12,
          SettingsCard(child: buildOAuthHelp()),
          buildTitle("网页 Cookie（备用）".t),
          SettingsCard(child: buildCookie(context)),
          AppStyle.vGap24,
        ],
      ),
    );
  }

  Widget buildTitle(String title) {
    return Padding(
      padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
      child: Text(title, style: Get.textTheme.titleSmall),
    );
  }

  /// 已登录的频道
  Widget buildChannel({
    required YouTubeChannelInfo? channel,
    required String subtitle,
    required VoidCallback onLogout,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: channel != null && channel.avatar.isNotEmpty
          ? NetImage(
              channel.avatar,
              width: 40,
              height: 40,
              borderRadius: 20,
            )
          : const CircleAvatar(
              radius: 20,
              child: Icon(Icons.person_outline),
            ),
      title: Text(
        channel == null || channel.title.isEmpty ? "已登录".t : channel.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(subtitle),
      trailing: TextButton(
        onPressed: onLogout,
        child: Text("退出登录".t),
      ),
    );
  }

  Widget buildOAuth(BuildContext context) {
    return Padding(
      padding: AppStyle.edgeInsetsA12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Obx(() {
            controller.service.version.value;
            if (!controller.service.hasOAuth) {
              return const SizedBox();
            }
            return Padding(
              padding: AppStyle.edgeInsetsB12,
              child: buildChannel(
                channel: controller.service.oauthChannel.value,
                subtitle: "已授权".t,
                onLogout: controller.logoutOAuth,
              ),
            );
          }),
          TextField(
            controller: controller.clientIdController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: "Client ID（客户端 ID）".t,
              hintText: "xxxx.apps.googleusercontent.com",
              isDense: true,
            ),
          ),
          AppStyle.vGap12,
          Obx(
            () => TextField(
              controller: controller.clientSecretController,
              obscureText: !controller.secretVisible.value,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: "Client Secret（客户端密钥）".t,
                isDense: true,
                suffixIcon: IconButton(
                  tooltip: controller.secretVisible.value ? "隐藏".t : "显示".t,
                  icon: Icon(
                    controller.secretVisible.value
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () => controller.secretVisible.toggle(),
                ),
              ),
            ),
          ),
          AppStyle.vGap12,
          Obx(() {
            controller.service.version.value;
            var code = controller.deviceCode.value;
            if (code == null) {
              return FilledButton.icon(
                onPressed: controller.startAuth,
                icon: const Icon(Icons.login),
                label: Text(controller.service.hasOAuth ? "重新授权".t : "开始授权".t),
              );
            }
            return buildDeviceCode(context, code);
          }),
        ],
      ),
    );
  }

  /// 设备码：在浏览器打开网址并输入授权码
  Widget buildDeviceCode(BuildContext context, YouTubeDeviceCode code) {
    var theme = Theme.of(context);
    return Container(
      padding: AppStyle.edgeInsetsA12,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withAlpha(20),
        borderRadius: AppStyle.radius8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text("在浏览器打开下面的网址，登录谷歌账号后输入授权码：".t),
          AppStyle.vGap8,
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  code.verificationUrl,
                  style: TextStyle(color: theme.colorScheme.primary),
                ),
              ),
              TextButton.icon(
                onPressed: controller.openVerificationUrl,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text("打开".t),
              ),
            ],
          ),
          AppStyle.vGap8,
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: SelectableText(
                  code.userCode,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              IconButton(
                tooltip: "复制授权码".t,
                onPressed: controller.copyUserCode,
                icon: const Icon(Icons.copy),
              ),
            ],
          ),
          AppStyle.vGap8,
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              AppStyle.hGap8,
              Expanded(
                child: Obx(
                  () => Text(
                    "等待授权，授权码 {formatRemaining} 后过期".tf({"formatRemaining": formatRemaining(controller.remaining.value)}),
                    style: _tipStyle,
                  ),
                ),
              ),
              TextButton(
                onPressed: controller.cancelAuth,
                child: Text("取消".t),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String formatRemaining(int seconds) {
    var m = seconds ~/ 60;
    var s = (seconds % 60).toString().padLeft(2, "0");
    return "$m:$s";
  }

  Widget buildOAuthHelp() {
    var steps = [
      "打开 Google Cloud Console，新建一个项目。".t,
      "在“API 和服务 → 库”中搜索“YouTube Data API v3”并启用。".t,
      ("在“OAuth 同意屏幕”选“外部（External）”，填应用名称和邮箱，"
              "并在“测试用户”添加自己的谷歌账号。\n"
              "“测试（Testing）”状态下授权 7 天后失效，要重新授权；"
              "发布为“正式版（In production）”可避免。\n"
              "授权时提示“Google 尚未验证此应用”是正常的，点“高级 → 继续”。")
          .t,
      ("在“凭据”点“创建凭据 → OAuth 客户端 ID”，"
              "应用类型选“电视和受限输入设备（TVs and Limited Input devices）”，"
              "再把客户端 ID 和密钥复制到上面。")
          .t,
    ];
    return ExpansionTile(
      title: Text("如何获取 Client ID 和 Client Secret".t),
      shape: const Border(),
      childrenPadding: AppStyle.edgeInsetsA12.copyWith(top: 0),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: AppStyle.edgeInsetsB8,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 20, child: Text("${i + 1}.")),
                Expanded(child: Text(steps[i])),
              ],
            ),
          ),
        Text(
          "Client Secret 和授权信息只存在本机（开启账号同步时会同步到你的其它设备）。".t,
          style: _tipStyle,
        ),
        AppStyle.vGap8,
        OutlinedButton.icon(
          onPressed: controller.openCloudConsole,
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text("打开 Google Cloud Console".t),
        ),
      ],
    );
  }

  Widget buildCookie(BuildContext context) {
    return Padding(
      padding: AppStyle.edgeInsetsA12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Obx(() {
            controller.service.version.value;
            var channel = controller.service.cookieChannel.value;
            if (!controller.service.hasCookie) {
              return const SizedBox();
            }
            return Padding(
              padding: AppStyle.edgeInsetsB12,
              child: buildChannel(
                channel: channel,
                subtitle: "已通过网页 Cookie 登录".t,
                onLogout: controller.logoutCookie,
              ),
            );
          }),
          Text(
            ("内置浏览器提示“此浏览器或应用可能不安全”时，"
            "到电脑浏览器登录 youtube.com，把 Cookie 复制到下面。"
            "Cookie 里要有 SAPISID 或 __Secure-3PAPISID。").t,
            style: _tipStyle,
          ),
          AppStyle.vGap12,
          if (controller.supportWebLogin) ...[
            OutlinedButton.icon(
              onPressed: controller.webLogin,
              icon: const Icon(Icons.account_circle_outlined),
              label: Text("网页登录".t),
            ),
            AppStyle.vGap12,
          ],
          TextField(
            controller: controller.cookieController,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: "粘贴 Cookie".t,
              hintText: "SAPISID=…; __Secure-3PAPISID=…; SID=…",
              isDense: true,
            ),
          ),
          AppStyle.vGap8,
          Obx(
            () => FilledButton.tonal(
              onPressed: controller.verifyingCookie.value
                  ? null
                  : controller.submitCookie,
              child: Text("检查并保存".t),
            ),
          ),
          AppStyle.vGap8,
          Text(
            ("复制方法：电脑浏览器登录 youtube.com → F12 → "
            "网络（Network）→ 刷新页面，点开任一 www.youtube.com 请求 → "
            "复制请求标头（Request Headers）里 cookie 的完整内容。").t,
            style: _tipStyle,
          ),
        ],
      ),
    );
  }
}
