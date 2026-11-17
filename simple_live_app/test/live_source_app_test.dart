import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/settings/live_source/live_source_permission_dialog.dart';
import 'package:simple_live_app/services/live_source_service.dart';
import 'package:simple_live_app/services/sync_backup_format.dart';
import 'package:simple_live_core/simple_live_core.dart';

Site fakeSite(String id) =>
    Site(id: id, name: id, logo: "", liveSite: LiveSite());

void main() {
  group("平台排序", () {
    var all = {
      "bilibili": fakeSite("bilibili"),
      "douyu": fakeSite("douyu"),
      "js:acfun": fakeSite("js:acfun"),
      "js:new": fakeSite("js:new"),
    };

    test("keeps the user's order, appends new sources, skips removed ones", () {
      var sorted = Sites.sortSites(
        ["js:acfun", "douyu", "js:removed", "bilibili", "douyu"],
        all,
      );
      expect(
          sorted.map((e) => e.id), ["js:acfun", "douyu", "bilibili", "js:new"]);
    });

    test("an empty or stale order still lists every installed platform", () {
      expect(Sites.sortSites(const [], all), hasLength(4));
      expect(Sites.sortSites(const ["js:gone"], all), hasLength(4));
    });

    test("script ids and the missing-platform text", () {
      expect(Sites.isScriptSiteId("js:acfun"), isTrue);
      expect(Sites.isScriptSiteId("douyu"), isFalse);
      expect(Sites.missingSiteText("js:acfun"), "平台未安装（js:acfun）");
      // 自带平台不受影响
      expect(Sites.allSites["bilibili"], isNotNull);
      expect(Sites.allSites["js:acfun"], isNull);
      expect(Sites.builtInSites["youtube"]!.hasRecommend, isTrue);
      expect(Sites.builtInSites["youtube"]!.isScript, isFalse);
    });
  });

  group("直播源同步数据", () {
    test("round trips and ignores broken entries", () {
      var data = LiveSourceSyncData.fromJson({
        "subscriptions": [
          "https://example.com/index.json",
          " https://example.com/index.json ",
          "",
        ],
        "sources": [
          {
            "key": "acfun",
            "name": "AcFun 直播",
            "version": "1.0.0",
            "url": "https://example.com/acfun.live.js",
          },
          {"name": "没有 key"},
          "bad",
        ],
      });
      expect(data.subscriptions, ["https://example.com/index.json"]);
      expect(data.sources.single.key, "acfun");
      var again = LiveSourceSyncData.fromJson(data.toJson());
      expect(again.sources.single.url, "https://example.com/acfun.live.js");
      expect(const LiveSourceSyncData().isEmpty, isTrue);
      expect(LiveSourceSyncData.fromJson(const {}).isEmpty, isTrue);
    });

    test("is an extra key of the settings file, invisible to data/ext", () {
      const settings = "SimpleLive_Settings.json";
      var file = SyncBackupFormat.pack(
        {"DanmuSize": 16.0},
        {"SiteSort": "bilibili,js:acfun"},
        {
          SyncBackupFormat.liveSourcesKey: const LiveSourceSyncData(
            subscriptions: ["https://example.com/index.json"],
          ).toJson(),
        },
      );
      var backup = SyncBackupFormat({settings: file});
      expect(backup.main(settings), {"DanmuSize": 16.0});
      expect(backup.extMap(settings, "settings"),
          {"SiteSort": "bilibili,js:acfun"});
      var live = backup.extraMap(settings, SyncBackupFormat.liveSourcesKey);
      expect(live, isNotNull);
      expect(LiveSourceSyncData.fromJson(live!).subscriptions, hasLength(1));
      expect(backup.liveSources(settings), isNotNull);
      // 旧版的备份没有这一项
      var old = SyncBackupFormat({
        settings: SyncBackupFormat.pack({"DanmuSize": 16.0}, {}),
      });
      expect(old.liveSources(settings), isNull);
      // 旧版本的备份用的是旧名字，同样认
      var r14 = SyncBackupFormat({
        settings: SyncBackupFormat.pack({}, {}, {
          SyncBackupFormat.liveSourcesKeyR14: const LiveSourceSyncData(
            subscriptions: ["https://example.com/index.json"],
          ).toJson(),
        }),
      });
      expect(r14.liveSources(settings), isNotNull);
      // 新格式不用旧名字：旧版本看到旧名字会清掉本机直播源关注再从 ext 恢复
      expect(backup.extraMap(settings, SyncBackupFormat.liveSourcesKeyR14),
          isNull);
    });

    test("only remote addresses are restored", () {
      expect(LiveSourceService.isRemoteUrl("https://a.com/x.live.js"), isTrue);
      expect(LiveSourceService.isRemoteUrl("file:///C:/x.live.js"), isFalse);
      expect(LiveSourceService.isValidUrl("file:///C:/x.live.js"), isTrue);
      expect(LiveSourceService.isValidUrl("ftp://a.com/x.js"), isFalse);
    });

    test("restore summary", () {
      var result = LiveSourceRestoreResult()
        ..subscriptions = 1
        ..installed = 2;
      result.failed.add("AcFun");
      expect(result.summary, "直播源：添加了 1 个订阅，安装了 2 个直播源，1 个安装失败");
      expect(LiveSourceRestoreResult().summary, "");
    });

    test("skeleton errors read as 'not supported'", () {
      expect(LiveSourceService.errorText(UnimplementedError()), "当前版本还不支持直播源");
      expect(LiveSourceService.errorText(Exception("网络错误")), "网络错误");
      expect(LiveSourceService.errorText(CoreError("脚本出错")), "脚本出错");
    });
  });

  group("直播源权限确认", () {
    LiveSourceInfo info(
            String version, List<String> domains, Set<String> caps) =>
        LiveSourceInfo(
          key: "a",
          name: "A",
          version: version,
          apiVersion: 1,
          file: "a.live.js",
          domains: domains,
          capabilities: caps,
        );
    LiveSourcePlan plan(LiveSourceInfo next, LiveSourceInfo? current,
            {String? key, String? currentKey}) =>
        LiveSourcePlan(
          next: next,
          current: current,
          publicKey: key,
          currentPublicKey: currentKey,
          origin: "https://example.com/a.live.js",
          code: "",
        );
    var pk = "A" * 43 + "=";

    test("new install lists domains and sensitive features", () {
      var fresh = plan(info("1.0.0", ["a.com"], {"room", "login"}), null);
      expect(fresh.needsConfirmation, isTrue);
      var lines = LiveSourcePermissionDialog.lines(fresh).map((e) => e.text);
      expect(lines.first, startsWith("未签名"));
      expect(lines, contains("可以访问的域名：a.com"));
      expect(lines, contains(liveSourceCapabilityLabel("login")));
      var signed = plan(info("1.0.0", ["a.com"], {}), null, key: pk);
      expect(LiveSourcePermissionDialog.lines(signed).first.text,
          startsWith("已签名"));
    });

    test("updates show only what changed; expansion and lost signature warn",
        () {
      var v1 = info("1.0.0", ["a.com"], {"room"});
      var same = plan(info("1.1.0", ["a.com"], {"room", "search"}), v1);
      expect(same.needsConfirmation, isFalse);
      var more = plan(info("1.1.0", ["a.com", "b.com"], {"room"}), v1);
      expect(more.needsConfirmation, isTrue);
      expect(
          LiveSourcePermissionDialog.lines(more)
              .where((e) => e.warn)
              .map((e) => e.text),
          ["新增可访问的域名：b.com"]);
      var lost = plan(info("1.1.0", ["a.com"], {"room"}), v1, currentKey: pk);
      expect(lost.needsConfirmation, isTrue);
      expect(LiveSourcePermissionDialog.lines(lost).first.warn, isTrue);
    });
  });
}
