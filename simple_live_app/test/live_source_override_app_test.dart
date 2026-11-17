// 内置平台的直播源修正（doc/live_source_api.md §9）在 App 里：自带平台的类型不变、
// 修正不显示成平台、安装确认写清楚替换了什么
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/settings/live_source/live_source_permission_dialog.dart';
import 'package:simple_live_app/services/live_source_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

LiveSourceInfo fixInfo({bool useAccount = false}) => LiveSourceInfo(
      key: "fix",
      name: "修正",
      version: "1.0.0",
      apiVersion: 1,
      file: "fix.live.js",
      domains: const ["api.live.bilibili.com"],
      capabilities: {
        "liveStatus",
        "playUrls",
        "overrides",
        if (useAccount) "useAccount",
      },
      overrides: "bilibili",
      useAccount: useAccount,
    );

void main() {
  test("自带平台换成能修正的版本，类型和接口都不变", () {
    for (var site in Sites.builtInSites.values) {
      expect(site.liveSite, isA<OverridableLiveSite>(), reason: site.id);
      expect(site.activeOverride, isNull);
    }
    var bili = Sites.builtInSites["bilibili"]!.liveSite;
    expect(bili, isA<BiliBiliSite>());
    expect(bili, isA<LiveSearchAllSite>());
    expect(Sites.builtInSites["huya"]!.liveSite, isA<LiveSearchAllSite>());
    expect(
        Sites.builtInSites["twitch"]!.liveSite, isA<LiveAccountFollowSite>());
  });

  test("修正不显示成单独的平台", () {
    var fix = ScriptLiveSite(fixInfo());
    var plain = ScriptLiveSite(const LiveSourceInfo(
      key: "acfun",
      name: "AcFun",
      version: "1.0.0",
      apiVersion: 1,
      file: "acfun.live.js",
    ));
    Sites.setScriptSites([fix, plain]);
    expect(Sites.scriptSites.map((e) => e.id), ["js:acfun"]);
    expect(Sites.allSites.containsKey("js:fix"), isFalse);
    Sites.setScriptSites([]);
  });

  test("安装确认写清楚替换哪个平台的哪些功能、用不用帐号", () {
    var plan = LiveSourcePlan(
      next: fixInfo(useAccount: true),
      current: null,
      publicKey: null,
      origin: "https://example.com/fix.live.js",
      code: "",
    );
    var warn = LiveSourcePermissionDialog.lines(plan)
        .where((e) => e.warn)
        .map((e) => e.text)
        .toList();
    expect(warn[0], "这个直播源会替换内置的 哔哩哔哩 的：开播状态、播放地址");
    expect(warn[1], contains("会用你在 App 里登录的 哔哩哔哩 帐号"));
    expect(warn[1], contains("脚本读不到 Cookie"));
    expect(warn.length, 2);
    var restore = LiveSourceRestoreResult()..overrides.add("修正");
    expect(restore.summary, "直播源：1 个会替换内置平台，需要手动安装");
  });
}
