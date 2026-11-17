import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/account/account_controller.dart';
import 'package:simple_live_app/modules/mine/account/live_source_login.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/live_source_service.dart';
import 'package:simple_live_app/widgets/site_logo.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/kick_account_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';
import 'package:simple_live_app/services/youtube_account_service.dart';

class AccountPage extends GetView<AccountController> {
  const AccountPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("账号管理".t),
      ),
      body: ListView(
        children: [
          Padding(
            padding: AppStyle.edgeInsetsA12,
            child: Text(
              "哔哩哔哩要登录才能看高清直播。".t,
              textAlign: TextAlign.center,
            ),
          ),
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/bilibili_2.png',
                width: 36,
                height: 36,
              ),
              title: Text("哔哩哔哩".t),
              subtitle: _subtitle(
                Constant.kBiliBili,
                Text(BiliBiliAccountService.instance.name.value.t),
              ),
              trailing: BiliBiliAccountService.instance.logined.value
                  ? const Icon(Icons.logout)
                  : const Icon(Icons.chevron_right),
              onTap: controller.bilibiliTap,
            ),
          ),
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/douyu.png',
                width: 36,
                height: 36,
              ),
              title: Text("斗鱼直播".t),
              subtitle: _subtitle(
                Constant.kDouyu,
                Text(DouyuAccountService.instance.logined.value
                    ? DouyuAccountService.instance.name.value.t
                    : "登录后可导入关注".t),
              ),
              trailing: DouyuAccountService.instance.logined.value
                  ? const Icon(Icons.logout)
                  : const Icon(Icons.chevron_right),
              onTap: controller.douyuTap,
            ),
          ),
          ListTile(
            leading: Image.asset(
              'assets/images/huya.png',
              width: 36,
              height: 36,
            ),
            title: Text("虎牙直播".t),
            subtitle: _subtitle(Constant.kHuya, Text("不用登录".t)),
            enabled: false,
            trailing: const Icon(Icons.chevron_right),
          ),
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/douyin.png',
                width: 36,
                height: 36,
              ),
              title: Text("抖音直播".t),
              subtitle: _subtitle(
                Constant.kDouyin,
                Text(DouyinAccountService.instance.hasCookie.value
                    ? "已自定义（{cookieCount} 字符）".tf({"cookieCount": DouyinAccountService.instance.cookie.length})
                    : "使用默认 ttwid".t),
              ),
              trailing: DouyinAccountService.instance.hasCookie.value
                  ? const Icon(Icons.delete_outline)
                  : const Icon(Icons.chevron_right),
              onTap: controller.douyinTap,
            ),
          ),
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/twitch.png',
                width: 36,
                height: 36,
              ),
              title: const Text("Twitch"),
              subtitle: _subtitle(
                Constant.kTwitch,
                Text(TwitchAccountService.instance.logined.value
                    ? TwitchAccountService.instance.name.value.t
                    : "登录后可导入关注，订阅或 Turbo 账号还能看受限画质".t),
              ),
              trailing: TwitchAccountService.instance.logined.value
                  ? const Icon(Icons.logout)
                  : const Icon(Icons.chevron_right),
              onTap: controller.twitchTap,
            ),
          ),
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/kick.png',
                width: 36,
                height: 36,
              ),
              title: const Text("Kick"),
              subtitle: _subtitle(
                Constant.kKick,
                Text(KickAccountService.instance.logined.value
                    ? KickAccountService.instance.name.value.t
                    : "登录后可导入关注".t),
              ),
              trailing: KickAccountService.instance.logined.value
                  ? const Icon(Icons.logout)
                  : const Icon(Icons.chevron_right),
              onTap: controller.kickTap,
            ),
          ),
          // 有官方授权和网页 Cookie 两种登录，统一进账号页管理
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/youtube.png',
                width: 36,
                height: 36,
              ),
              title: const Text("YouTube"),
              subtitle: _subtitle(
                Constant.kYouTube,
                Text(YouTubeAccountService.instance.logined.value
                    ? YouTubeAccountService.instance.name.value.t
                    : "登录后可导入关注".t),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Get.toNamed(RoutePath.kYouTubeAccount),
            ),
          ),
          // 直播源（脚本声明了 login 的）
          if (LiveSourceService.registered)
            Obx(() {
              var service = LiveSourceService.instance;
              var list = service.loginSites;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var site in list)
                    ListTile(
                      leading: SiteLogo(
                        Sites.allSites[site.id],
                        width: 36,
                        height: 36,
                      ),
                      title: Text(site.name),
                      subtitle: Text(_scriptSubtitle(
                        service.accounts[site.info.key],
                        site,
                      )),
                      trailing: service.accounts[site.info.key]?.loggedIn ??
                              false
                          ? const Icon(Icons.logout)
                          : const Icon(Icons.chevron_right),
                      onTap: () => LiveSourceLoginFlow.tap(site),
                    ),
                ],
              );
            }),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.group_add_outlined, size: 32),
            title: Text("账号关注".t),
            subtitle: Text("从账号导入关注".t),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Get.toNamed(RoutePath.kAccountFollow),
          ),
        ],
      ),
    );
  }

  /// 自带平台正在用直播源修正（§9）时，副标题下面加一行“正在使用直播源修正：名字 版本”
  static Widget _subtitle(String siteId, Widget text) {
    if (!LiveSourceService.registered) {
      return text;
    }
    return Obx(() {
      var info = LiveSourceService.instance.activeOverrideOf(siteId);
      if (info == null) {
        return text;
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          text,
          Text(
            "正在使用直播源修正：{name} {version}".tf({"name": info.name, "version": info.version}),
            style: TextStyle(fontSize: 12, color: Get.theme.colorScheme.primary),
          ),
        ],
      );
    });
  }

  static String _scriptSubtitle(LiveSourceAccount? account, ScriptLiveSite site) {
    if (account == null) {
      return "直播源".t;
    }
    if (account.loggedIn) {
      return account.userName ?? "已登录".t;
    }
    return "未登录".t;
  }
}
