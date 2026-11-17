// 内置平台的修正（overrides，doc/live_source_api.md §9）：解析、权限、分发和改用内置、
// 只装签名的、帐号只加在白名单主机上。不访问外网
//   dart test test/live_source_override_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/ed25519.dart';
import 'package:simple_live_core/src/script/live_source_signing.dart';
import 'package:simple_live_core/src/script/script_metadata.dart';
import 'package:simple_live_core/src/script/script_worker.dart';
import 'package:test/test.dart';

late Directory tmp;
const fixture = "test/fixtures/overrides/bilibili_live_status.live.js";

ScriptLiveSite loadSite(String name, String code) {
  var dir = Directory("${tmp.path}/sources")..createSync(recursive: true);
  var file = File("${dir.path}/$name")..writeAsStringSync(code);
  var meta = parseLiveSourceScript(code, filename: name);
  return ScriptLiveSite(
    meta.toInfo(file.path),
    dataDirectory: "${tmp.path}/data/${meta.key}",
  );
}

String fix(String body, {String extra = ""}) =>
    'class Fix extends LiveSource { key = "fix"; name = "修正"; version = "1.0.0"; '
    'overrides = "bilibili"; domains = []; $extra $body }';

Future<void> expectCoreError(Future<dynamic> future, dynamic message) async {
  try {
    await future;
  } on CoreError catch (e) {
    expect(e.message, message);
    return;
  }
  fail("应该抛出 CoreError");
}

/// 弹幕参数里带着登录 Cookie 的内置平台（像哔哩哔哩）
class FakeArgs {
  final String cookie;
  FakeArgs(this.cookie);
  @override
  String toString() => "cookie=$cookie";
}

class FakeBuiltIn extends LiveSite {
  FakeBuiltIn() {
    id = "bilibili";
    name = "假的内置平台";
  }

  final calls = <String>[];

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    calls.add("liveStatus");
    return false;
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    calls.add("recommend");
    return LiveCategoryResult(
      hasMore: false,
      items: [LiveRoomItem(roomId: "b1", title: "", cover: "", userName: "")],
    );
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    calls.add("room");
    return LiveRoomDetail(
      roomId: roomId,
      title: "内置",
      cover: "",
      userName: "主播",
      userAvatar: "",
      online: 1,
      status: true,
      url: "https://live.bilibili.com/$roomId",
      data: "sign-secret",
      danmakuData: FakeArgs("SESSDATA=secret"),
    );
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    calls.add("qualities:${detail.title}");
    return [LivePlayQuality(quality: "原画", data: 10000)];
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    calls.add("playUrls:${detail.title}:${quality.data}");
    return LivePlayUrl(urls: ["https://builtin.example/${detail.roomId}"]);
  }
}

class OvFake extends FakeBuiltIn with OverridableLiveSite {}

void main() {
  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync("live_source_override_test_");
  });
  tearDownAll(() {
    ScriptWorkerSettings.accountHostsForTest = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test("示例修正的解析；不允许的写法", () {
    var meta = parseLiveSourceScript(File(fixture).readAsStringSync());
    var info = meta.toInfo("x.live.js");
    expect(info.overrides, "bilibili");
    expect(info.overrideFunctions, {"liveStatus"});
    expect(info.capabilities, contains("overrides"));
    expect(info.useAccount, isFalse);
    expect(kLiveSourceFeatures, contains("overrides"));

    void bad(String code, String message) => expect(
      () => parseLiveSourceScript(code),
      throwsA(
        isA<CoreError>().having((e) => e.message, "message", contains(message)),
      ),
    );
    bad(
      fix("async room(id) { return {} }").replaceAll("bilibili", "acfun"),
      "内置平台的 id",
    );
    bad(fix("async qualities() { return [] }"), "也要替换 playUrls");
    bad(
      fix(
        "async room() {}",
        extra: 'login = { url: "https://a.com/", cookieNames: ["a"] };',
      ),
      "不能有 login",
    );
    bad(fix(""), "至少要实现");
    bad(
      'class A extends LiveSource { key = "a"; name = "A"; version = "1.0.0"; useAccount = true }',
      "只能和 overrides 一起用",
    );
    bad(
      fix(
        "async room() {}",
        extra: "useAccount = true;",
      ).replaceAll("bilibili", "huya"),
      "不能用 useAccount",
    );
  });

  test("权限：新装列出替换的功能，多替换、换平台、useAccount 要确认", () {
    LiveSourceInfo info(String? target, Set<String> caps) => LiveSourceInfo(
      key: "fix",
      name: "修正",
      version: "1.0.0",
      apiVersion: 1,
      file: "fix.live.js",
      overrides: target,
      useAccount: caps.contains("useAccount"),
      capabilities: {...caps, if (target != null) "overrides"},
    );
    var v1 = info("bilibili", {"liveStatus"});
    var fresh = diffLiveSourcePermissions(null, v1);
    expect(fresh.addedOverrides, ["liveStatus"]);
    expect(fresh.describe(), contains("新增：替换内置的 哔哩哔哩 的：开播状态"));
    expect(
      describeLiveSourceOverride("bilibili", v1.overrideFunctions).single,
      "这个直播源会替换内置的 哔哩哔哩 的：开播状态",
    );
    var more = diffLiveSourcePermissions(
      v1,
      info("bilibili", {"liveStatus", "playUrls"}),
    );
    expect(more.expanded, isTrue);
    expect(more.addedOverrides, ["playUrls"]);
    var less = diffLiveSourcePermissions(
      info("bilibili", {"liveStatus", "playUrls"}),
      v1,
    );
    expect(less.expanded, isFalse);
    expect(less.removedOverrides, ["playUrls"]);
    var moved = diffLiveSourcePermissions(v1, info("douyu", {"liveStatus"}));
    expect(moved.overrideTargetChange, "哔哩哔哩 → 斗鱼");
    expect(moved.expanded, isTrue);
    var account = diffLiveSourcePermissions(
      v1,
      info("bilibili", {"liveStatus", "useAccount"}),
    );
    expect(account.addedCapabilities, ["useAccount"]);
    expect(account.describe().single, contains("哔哩哔哩 帐号"));
    // 普通源改成修正也要确认
    expect(
      diffLiveSourcePermissions(info(null, {"room"}), v1).expanded,
      isTrue,
    );
  });

  test("分发：替换了的走脚本，没替换的走内置；出错时改用内置；脚本只拿到公开字段", () async {
    var site = loadSite(
      "fix.live.js",
      fix('''
        async liveStatus(id) { if (id === "bad") throw new Error("坏了"); return true }
        async playUrls(room, quality) {
          return { urls: ["https://cdn.example/play?" + encodeURIComponent(JSON.stringify({ room, quality }))] }
        }'''),
    );
    LiveSourceOverrideBinding? current = LiveSourceOverrideBinding(site);
    var b = OvFake()
      ..overrideLookup = (id) => id == "bilibili" ? current : null;
    expect(b.isOverridden("liveStatus"), isTrue);
    expect(await b.getLiveStatus(roomId: "1"), isTrue);
    expect((await b.getRecommendRooms()).items.single.roomId, "b1");
    expect(await b.getLiveStatus(roomId: "bad"), isFalse); // 改用内置
    expect(b.calls, ["recommend", "liveStatus"]);

    var detail = await b.getRoomDetail(roomId: "7");
    var quality = (await b.getPlayQualites(detail: detail)).single;
    var url = (await b.getPlayUrls(
      detail: detail,
      quality: quality,
    )).urls.single;
    expect(url, isNot(contains("secret")));
    var sent = jsonDecode(Uri.decodeComponent(url.split("?")[1]));
    expect(sent["room"]["builtIn"], isTrue);
    expect(sent["room"]["title"], "内置");
    expect(sent["room"].containsKey("data"), isFalse);
    expect(sent["room"].containsKey("danmakuData"), isFalse);
    expect(sent["quality"], {
      "name": "原画",
      "data": 10000,
      "sort": 0,
      "builtIn": true,
    });

    current = LiveSourceOverrideBinding(site, fallback: false);
    await expectCoreError(b.getLiveStatus(roomId: "bad"), contains("坏了"));
    current = null; // 关掉：全部内置
    expect(await b.getLiveStatus(roomId: "1"), isFalse);
    expect(
      (await b.getPlayUrls(detail: detail, quality: quality)).urls.single,
      "https://builtin.example/7",
    );
    await site.dispose();

    // 只替换 room：没替换的清晰度、播放地址拿到的是内置 room() 的结果
    var roomFix = loadSite(
      "room.live.js",
      fix(
        'async room(id) { return { roomId: id, title: "脚本", live: true } }',
      ).replaceAll('"fix"', '"roomfix"'),
    );
    current = LiveSourceOverrideBinding(roomFix);
    var c = OvFake()..overrideLookup = (_) => current;
    var scriptDetail = await c.getRoomDetail(roomId: "8");
    expect(scriptDetail.title, "脚本");
    var q = (await c.getPlayQualites(detail: scriptDetail)).single;
    await c.getPlayUrls(detail: scriptDetail, quality: q);
    expect(c.calls, ["room", "qualities:内置", "playUrls:内置:10000"]);
    await roomFix.dispose();
  });

  test("只装签名的修正；开发者选项放开未签名的；开关", () async {
    var root = Directory("${tmp.path}/m")..createSync(recursive: true);
    var manager = LiveSourceManager(
      directory: "${root.path}/app",
      appVersion: "1.0.0",
    );
    await manager.init();
    const key = "bilibili_live_status_fix";
    await expectCoreError(
      manager.prepareInstallFromFile(fixture),
      contains("只能从有签名的订阅安装"),
    );
    await manager.setAllowUnsignedOverrides(true);
    await manager.installFromFile(fixture);
    expect(manager.platformSites, isEmpty);
    expect(manager.activeOverride("bilibili")!.info.key, key);
    expect(manager.activeOverride("douyu"), isNull);
    expect(manager.overrideStatus(key)!.active, isTrue);
    await manager.setOverrideEnabled(key, false);
    expect(manager.activeOverride("bilibili"), isNull);
    await manager.setOverrideEnabled(key, true);
    await manager.setOverrideFallback(key, false);
    expect(manager.activeOverride("bilibili")!.fallback, isFalse);
    await manager.setAllowUnsignedOverrides(false);
    expect(manager.activeOverride("bilibili"), isNull);
    expect(manager.overrideStatus(key)!.text, contains("没有签名"));
    await manager.remove(key);

    // 签名订阅里的：不用开发者选项
    var repo = Directory("${root.path}/repo")..createSync();
    var seed = List<int>.generate(32, (i) => i + 3);
    var script = File("${repo.path}/fix.live.js")
      ..writeAsBytesSync(File(fixture).readAsBytesSync());
    File("${repo.path}/index.json").writeAsStringSync(
      jsonEncode({
        "name": "签名的修正",
        "publicKey": base64.encode(ed25519PublicKey(seed)),
        "sources": [
          {
            "key": key,
            "version": "1.0.0",
            "url": "fix.live.js",
            "signature": liveSourceSign(seed, script.readAsBytesSync()),
          },
        ],
      }),
    );
    var index = Uri.file("${repo.path}/index.json").toString();
    await manager.addSubscription(index);
    var entry = (await manager.fetchSubscription(index)).single;
    var plan = await manager.prepareInstallFromUrl(entry.url);
    expect(plan.signed, isTrue);
    expect(plan.needsConfirmation, isTrue);
    expect(plan.diff.addedOverrides, ["liveStatus"]);
    await manager.applyPlan(plan, confirmed: true);
    expect(manager.activeOverride("bilibili")!.info.key, key);
    expect(manager.activeOverride("bilibili")!.fallback, isTrue); // 删除时设置一起删了
    await manager.setOverrideEnabled(key, false);
    await manager.dispose();

    // 设置保存在本机（overrides.json）
    var again = LiveSourceManager(
      directory: "${root.path}/app",
      appVersion: "1.0.0",
    );
    await again.init();
    expect(again.overrideEnabled(key), isFalse);
    expect(again.allowUnsignedOverrides, isFalse);
    await again.dispose();
  });

  test("useAccount：帐号只加在白名单主机上，脚本读不到、存不下", () async {
    var server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var port = server.port;
    var seen = <String, String>{};
    server.listen((req) async {
      seen[req.uri.path] =
          "${req.headers.value("cookie") ?? ""}|${req.headers.value("authorization") ?? ""}";
      if (req.uri.path == "/redir") {
        req.response.statusCode = 302;
        req.response.headers.set("location", "http://localhost:$port/after");
      } else {
        req.response.headers.add("set-cookie", "SESSDATA=refreshed; Path=/");
        req.response.write("ok");
      }
      await req.response.close();
    });
    ScriptWorkerSettings.accountHostsForTest = {
      "bilibili": ["127.0.0.1"],
    };
    String code(String key, bool useAccount) => fix(
      '''
      async liveStatus() { return true }
      async probe(port) {
        const a = "http://127.0.0.1:" + port
        await Http.setCookies(a + "/", "SESSDATA=fake; own=1")
        const r = await Http.get(a + "/a", { headers: { Authorization: "mine" } })
        await Http.get("http://localhost:" + port + "/b")
        await Http.get(a + "/redir")
        return { setCookie: r.headers["set-cookie"] || null, jar: await Http.getCookies(a + "/"), all: JSON.stringify(r) }
      }''',
      extra: "useAccount = $useAccount; domains = ['127.0.0.1', 'localhost'];",
    ).replaceAll('"fix"', '"$key"');
    const auth = LiveSourceAccountAuth(
      cookie: "SESSDATA=secret; bili_jct=csrf",
      authorization: "Bearer t0ken",
    );
    try {
      var site = loadSite("acct.live.js", code("acct", true));
      site.accountAuth = auth;
      var r = await site.callScript("probe", [port]);
      expect(seen["/a"], "SESSDATA=secret; bili_jct=csrf; own=1|Bearer t0ken");
      expect(seen["/b"], "|"); // 不在白名单里的主机
      expect(seen["/redir"], startsWith("SESSDATA=secret"));
      // 重定向到别的主机：不带（只有脚本自己在 localhost 的 Cookie）
      expect(seen["/after"], "SESSDATA=refreshed|");
      expect(r["setCookie"], isNull);
      expect(r["jar"], "SESSDATA=fake; own=1"); // 刷新的 Cookie 没进 Cookie 罐
      expect(jsonEncode(r), isNot(contains("secret")));
      await site.dispose();

      // 没声明 useAccount：App 给了也不带
      seen.clear();
      var plain = loadSite("plain.live.js", code("plain", false));
      plain.accountAuth = auth;
      expect(plain.accountAuth, isNull);
      await plain.callScript("probe", [port]);
      expect(seen["/a"], "SESSDATA=fake; own=1|mine");
      await plain.dispose();
    } finally {
      ScriptWorkerSettings.accountHostsForTest = null;
      await server.close(force: true);
    }
  });
}
