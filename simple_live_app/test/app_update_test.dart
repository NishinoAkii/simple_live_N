import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/app_update/release_api.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';
import 'package:simple_live_app/services/app_update/update_config.dart';
import 'package:simple_live_app/services/app_update/update_downloader.dart';
import 'package:simple_live_app/services/app_update/update_settings.dart';
import 'package:simple_live_app/services/sync_compat.dart';

import 'fakes/fake_http_adapter.dart';

/// 应用内更新（1.25.0）：读 Release、比新旧、什么时候查、
/// 下载（临时链接、测速排序、校验不对换源、上次下好的直接用）、出错时的短话。
/// 全部用假的 HTTP，不联网
void main() {
  // 要登录的仓库（令牌、临时下载链接）的情形
  const config = UpdateConfig(
    owner: "NishinoAkii",
    repo: "simple_live_N",
    tagPrefix: "v",
    needsLogin: true,
    mirrors: [
      UpdateMirror("gh-proxy-org", "gh-proxy.org", "https://gh-proxy.org/",
          tempLinks: true),
      UpdateMirror("gh-proxy", "gh-proxy.com", "https://gh-proxy.com/",
          tempLinks: true),
      UpdateMirror("ghfast", "ghfast.top", "https://ghfast.top/"),
      UpdateMirror("ghproxy-net", "ghproxy.net", "https://ghproxy.net/"),
    ],
  );
  const publicConfig = UpdateConfig(
    owner: "someone",
    repo: "simple_live_N",
    tagPrefix: "v",
    needsLogin: false,
    mirrors: [UpdateMirror("m1", "m1.example", "https://m1.example/")],
  );

  Map<String, dynamic> fixture() => jsonDecode(
        File("test/fixtures/github_release_latest.json").readAsStringSync(),
      ) as Map<String, dynamic>;

  AppRelease release({String? title, String? body, String? tag}) {
    var json = fixture();
    if (title != null) json["name"] = title;
    if (body != null) json["body"] = body;
    if (tag != null) json["tag_name"] = tag;
    return ReleaseParser.parse(json, tagPrefix: "v");
  }

  test("更新的设置只在本机", () {
    for (var key in UpdateSettings.storageKeys) {
      expect(SyncCompat.isLocalOnlySetting(key), isTrue, reason: key);
    }
  });

  group("读 Release", () {
    test("GitHub 返回的 latest release：版本、日期、正文、安装包和校验值", () {
      var r = release();
      expect(r.tag, "v1.25.0");
      expect(r.version, "1.25.0");
      // 标题只有版本号，正文开头没有“## 版本（构建号）”
      expect(r.build, 0);
      expect(r.publishedAt, DateTime.utc(2026, 11, 20, 8, 5));
      expect(r.htmlUrl, endsWith("/releases/tag/v1.25.0"));
      expect(r.body, startsWith("新功能"));
      expect(r.assets, hasLength(3));
      var zip = r.assets.first;
      expect(zip.name, "SimpleLive-v1.25.0-b52-1a2b3c4-windows-x64.zip");
      expect(zip.size, 52428800);
      expect(zip.apiUrl, endsWith("/releases/assets/310000001"));
      expect(zip.browserUrl, contains("/releases/download/v1.25.0/"));
      expect(zip.sha256, startsWith("9f86d081"));
      // 大写的十六进制换成小写；digest 为 null 的没有校验值
      expect(r.assets[1].sha256, startsWith("60303ae2"));
      expect(r.assets[2].sha256, "");
      // 运行编号取安装包里最大的（同一个版本重新编译过）
      expect(ReleaseParser.runNumber(r.assets), 52);
    });

    test("构建号：标题（12500）优先，其次正文的第一个标题", () {
      expect(release(title: "1.25.0（12500）").build, 12500);
      expect(release(title: "1.25.0 (12500)").build, 12500);
      expect(
        release(body: "## 1.25.0（12501）\n\n新功能\n\n## 1.24.2（12402）").build,
        12501,
      );
      // 正文第一个标题不是版本标题时不往下找
      expect(release(body: "### 新功能\n\n## 1.25.0（12501）").build, 0);
    });

    test("标签里的版本号", () {
      expect(
          ReleaseParser.versionFromTag("v1.24.2", "v"), "1.24.2");
      expect(ReleaseParser.versionFromTag("v1.24.2", "v"), "1.24.2");
      expect(ReleaseParser.versionFromTag("v1.24.2", ""), "1.24.2");
      expect(ReleaseParser.versionFromTag("nightly", "v"), "");
      // 标签读不出来时用标题
      expect(release(tag: "latest", title: "1.25.1").version, "1.25.1");
    });
  });

  group("和本机比新旧", () {
    AppRelease remote(String version, int build, int run) => AppRelease(
          tag: "v$version",
          version: version,
          build: build,
          body: "",
          publishedAt: null,
          htmlUrl: "",
          assets: [
            ReleaseAsset(
              name: "SimpleLive-v$version-b$run-abcdef1-windows-x64.zip",
              size: 1,
              digest: "",
              apiUrl: "",
              browserUrl: "",
            ),
          ],
        );

    test("版本号按数字比", () {
      expect(ReleaseParser.compareVersions("1.24.10", "1.24.9"), 1);
      expect(ReleaseParser.compareVersions("1.25", "1.25.0"), 0);
      expect(ReleaseParser.compareVersions("1.24.2", "1.25.0"), -1);
    });

    test("版本更高的新；更低的不新", () {
      var local = LocalBuild.from("1.24.2", "12402", "b48-6b41418");
      expect(local.run, 48);
      expect(ReleaseParser.isNewer(remote("1.25.0", 0, 1), local), isTrue);
      expect(
          ReleaseParser.isNewer(remote("1.24.1", 99999, 99), local), isFalse);
    });

    test("版本一样：构建号更高的新；构建号一样时看 CI 运行编号", () {
      var local = LocalBuild.from("1.24.2", "12402", "b48-6b41418");
      expect(ReleaseParser.isNewer(remote("1.24.2", 12403, 1), local), isTrue);
      expect(
          ReleaseParser.isNewer(remote("1.24.2", 12401, 99), local), isFalse);
      expect(ReleaseParser.isNewer(remote("1.24.2", 12402, 50), local), isTrue);
      expect(
          ReleaseParser.isNewer(remote("1.24.2", 12402, 48), local), isFalse);
      // Release 里没写构建号（现在的 CI）：只能比运行编号
      expect(ReleaseParser.isNewer(remote("1.24.2", 0, 50), local), isTrue);
      expect(ReleaseParser.isNewer(remote("1.24.2", 0, 48), local), isFalse);
      // 本机是自己编译的（没有运行编号）：版本和构建号一样就不算新
      var dev = LocalBuild.from("1.24.2", "12402", "");
      expect(ReleaseParser.isNewer(remote("1.24.2", 0, 50), dev), isFalse);
    });

    test("跳过的版本：重新编译过的算新的一版", () {
      expect(
        ReleaseParser.skipId(remote("1.25.0", 12500, 52)),
        isNot(ReleaseParser.skipId(remote("1.25.0", 12500, 53))),
      );
    });
  });

  group("什么时候自动检查", () {
    var now = DateTime(2026, 11, 20, 12);
    AutoCheckBlock? block({
      bool secondary = false,
      bool forRoom = false,
      bool on = true,
      bool needsLogin = true,
      bool loggedIn = true,
      DateTime? last,
    }) =>
        UpdateCheckPolicy.blocker(
          isSecondary: secondary,
          startedForRoom: forRoom,
          autoCheck: on,
          needsLogin: needsLogin,
          loggedIn: loggedIn,
          lastCheck: last?.millisecondsSinceEpoch ?? 0,
          now: now,
        );

    test("只在主窗口、不是带着链接启动、开关开着时查", () {
      expect(block(), isNull);
      expect(block(secondary: true), AutoCheckBlock.secondaryWindow);
      expect(block(forRoom: true), AutoCheckBlock.startedForRoom);
      expect(block(on: false), AutoCheckBlock.turnedOff);
    });

    test("要登录的仓库没登录不查；不用登录的照常查", () {
      expect(block(loggedIn: false), AutoCheckBlock.needLogin);
      expect(block(loggedIn: false, needsLogin: false), isNull);
    });

    test("24 小时内查过不查；时间往回调过照常查", () {
      expect(
        block(last: now.subtract(const Duration(hours: 23))),
        AutoCheckBlock.checkedRecently,
      );
      expect(block(last: now.subtract(const Duration(hours: 24))), isNull);
      expect(block(last: now.add(const Duration(hours: 2))), isNull);
    });

    test("跳过的版本自动检查时不提示，手动检查照样提示", () {
      var r = release();
      var local = LocalBuild.from("1.24.2", "12402", "b48-6b41418");
      var skipped = ReleaseParser.skipId(r);
      expect(
        UpdateCheckPolicy.shouldPrompt(r, local, skipped: "", manual: false),
        isTrue,
      );
      expect(
        UpdateCheckPolicy.shouldPrompt(r, local,
            skipped: skipped, manual: false),
        isFalse,
      );
      expect(
        UpdateCheckPolicy.shouldPrompt(r, local,
            skipped: skipped, manual: true),
        isTrue,
      );
      // 已经是这个版本
      var same = LocalBuild.from("1.25.0", "12500", "b52-1a2b3c4");
      expect(
        UpdateCheckPolicy.shouldPrompt(r, same, skipped: "", manual: true),
        isFalse,
      );
    });
  });

  group("GitHub 接口", () {
    test("带着令牌读 latest release", () async {
      var adapter = FakeHttpAdapter((_) => FakeHttpAdapter.json(fixture()));
      var api = ReleaseApi(FakeHttpAdapter.dio(adapter), config);
      var r = await api.latest(token: "gho_test");
      expect(r.version, "1.25.0");
      var request = adapter.requests.single;
      expect(
        request.uri.toString(),
        "https://api.github.com/repos/NishinoAkii/simple_live_N/releases/latest",
      );
      expect(request.headers["Accept"], "application/vnd.github+json");
      expect(request.headers["Authorization"], "Bearer gho_test");
    });

    Future<UpdateException> failWith(
      ResponseBody Function() response, {
      String? token,
      UpdateConfig cfg = config,
    }) async {
      var api = ReleaseApi(
        FakeHttpAdapter.dio(FakeHttpAdapter((_) => response())),
        cfg,
      );
      try {
        await api.latest(token: token);
      } on UpdateException catch (e) {
        return e;
      }
      fail("没有报错");
    }

    test("401：令牌失效；404：没登录 / 没权限；403：限流或没权限", () async {
      expect(
        (await failWith(() => FakeHttpAdapter.json({}, status: 401),
                token: "x"))
            .kind,
        UpdateErrorKind.loginExpired,
      );
      expect(
        (await failWith(() => FakeHttpAdapter.json({}, status: 404))).kind,
        UpdateErrorKind.needLogin,
      );
      expect(
        (await failWith(() => FakeHttpAdapter.json({}, status: 404),
                token: "x"))
            .kind,
        UpdateErrorKind.notFound,
      );
      // 公开仓库不登录的 404 就是没有发布过版本
      expect(
        (await failWith(() => FakeHttpAdapter.json({}, status: 404),
                cfg: publicConfig))
            .kind,
        UpdateErrorKind.notFound,
      );
      var limited = await failWith(
        () => FakeHttpAdapter.json({},
            status: 403,
            headers: {
              "x-ratelimit-remaining": ["0"],
              "x-ratelimit-reset": ["1795000000"],
            }),
        token: "x",
      );
      expect(limited.kind, UpdateErrorKind.rateLimited);
      expect(limited.retryAt,
          DateTime.fromMillisecondsSinceEpoch(1795000000 * 1000));
      expect(
        (await failWith(() => FakeHttpAdapter.json({}, status: 403),
                token: "x"))
            .kind,
        UpdateErrorKind.forbidden,
      );
    });

    test("连不上：网络错误", () async {
      var error = await failWith(() => throw DioException.connectionError(
            requestOptions: RequestOptions(),
            reason: "offline",
          ));
      expect(error.kind, UpdateErrorKind.network);
    });
  });


  group("下载", () {
    late Directory dir;
    final good = utf8.encode("the real installer " * 100);
    final bad = utf8.encode("tampered installer " * 100);
    final goodSha = crypto.sha256.convert(good).toString();
    const apiUrl =
        "https://api.github.com/repos/NishinoAkii/simple_live_N/releases/assets/310000001";
    const tempUrl =
        "https://release-assets.githubusercontent.com/github-production-release-asset/1/abc?sp=r&sv=2018-11-09&se=2026-11-20T08%3A10%3A00Z&sig=SIG&jwt=JWT";
    const name = "SimpleLive-v1.25.0-b52-1a2b3c4-windows-x64.zip";

    ReleaseAsset asset({String digest = ""}) => ReleaseAsset(
          name: name,
          size: good.length,
          digest: digest,
          apiUrl: apiUrl,
          browserUrl:
              "https://github.com/NishinoAkii/simple_live_N/releases/download/v1.25.0/$name",
        );

    setUp(() => dir = Directory.systemTemp.createTempSync("app_update_test"));
    tearDown(() => dir.deleteSync(recursive: true));

    test("要登录的仓库：带令牌请求 API 地址、不跟随跳转，取 302 的临时链接", () async {
      var adapter =
          FakeHttpAdapter((options) => FakeHttpAdapter.redirect(tempUrl));
      var downloader = UpdateDownloader(
        FakeHttpAdapter.dio(adapter),
        config: config,
        token: "gho_x",
      );
      expect(await downloader.resolveTempUrl(asset()), tempUrl);
      var request = adapter.requests.single;
      expect(request.uri.toString(), apiUrl);
      expect(request.followRedirects, isFalse);
      expect(request.headers["Accept"], "application/octet-stream");
      expect(request.headers["Authorization"], "Bearer gho_x");
    });

    test("临时链接用了 4 分钟以上就重新换", () async {
      var now = DateTime(2026, 11, 20, 8);
      var count = 0;
      var adapter = FakeHttpAdapter(
        (_) => FakeHttpAdapter.redirect("$tempUrl&n=${++count}"),
      );
      var downloader = UpdateDownloader(
        FakeHttpAdapter.dio(adapter),
        config: config,
        token: "gho_x",
        now: () => now,
      );
      var first = await downloader.downloadUrl(asset());
      now = now.add(const Duration(minutes: 3));
      expect(await downloader.downloadUrl(asset()), first);
      now = now.add(const Duration(minutes: 2));
      expect(await downloader.downloadUrl(asset()), isNot(first));
      expect(count, 2);
      // 公开仓库直接用网页上的下载地址，也不交临时链接给安装方式
      var public = UpdateDownloader(
        FakeHttpAdapter.dio(adapter),
        config: publicConfig,
      );
      expect(await public.downloadUrl(asset()), asset().browserUrl);
      expect(await public.tempUrlFor(asset()), isNull);
    });

    test("测速排序：快的在前，一样快时直连在后，测速失败的镜像不用，直连失败也放在最后", () {
      var direct = DownloadSource.direct;
      const a = DownloadSource("a", "a", "https://a/");
      const b = DownloadSource("b", "b", "https://b/");
      expect(
        UpdateDownloader.rank([direct, a, b], {"direct": 10, "a": 30, "b": 20})
            .map((e) => e.id),
        ["a", "b", "direct"],
      );
      expect(
        UpdateDownloader.rank(
                [direct, a, b], {"direct": 50, "a": 30, "b": null})
            .map((e) => e.id),
        ["direct", "a"],
      );
      expect(
        UpdateDownloader.rank([direct, a], {"direct": 30, "a": 30})
            .map((e) => e.id),
        ["a", "direct"],
      );
      expect(
        UpdateDownloader.rank(
                [direct, a, b], {"direct": null, "a": null, "b": 5})
            .map((e) => e.id),
        ["b", "direct"],
      );
    });

    test("设置里选的下载源", () {
      var auto = DownloadSource.forSetting("auto", config, "https://my.proxy/",
          tempLinks: true);
      expect(auto.probe, isTrue);
      expect(auto.sources.map((e) => e.id),
          ["direct", "gh-proxy-org", "gh-proxy", "custom"]);
      // 下临时链接：转发不了它的镜像（ghfast.top、ghproxy.net）不进“自动”
      expect(auto.sources.map((e) => e.id), isNot(contains("ghfast")));
      // 公开的文件（翻译等）四个镜像都用
      expect(
          DownloadSource.forSetting("auto", config, "").sources.map((e) => e.id),
          ["direct", "gh-proxy-org", "gh-proxy", "ghfast", "ghproxy-net"]);
      var direct = DownloadSource.forSetting("direct", config, "");
      expect(direct.sources.map((e) => e.id), ["direct"]);
      var mirror = DownloadSource.forSetting("ghfast", config, "");
      expect(mirror.probe, isFalse);
      expect(mirror.sources.map((e) => e.id), ["ghfast", "direct"]);
      // 自定义没填前缀时当作自动
      expect(DownloadSource.forSetting("custom", config, "").probe, isTrue);
      expect(UpdateSettings.normalizePrefix(" https://my.proxy "),
          "https://my.proxy/");
      expect(UpdateSettings.normalizePrefix("https://x.dev/?url="),
          "https://x.dev/?url=");
      expect(UpdateSettings.normalizePrefix("ftp://x"), isNull);
      expect(UpdateSettings.normalizePrefix(""), "");
    });

    test("自动：测速后先用最快的镜像；它给的文件校验不对，删掉换下一个；令牌不发给镜像", () async {
      var adapter = FakeHttpAdapter((options) {
        var url = options.uri.toString();
        if (url == apiUrl) {
          return FakeHttpAdapter.redirect(tempUrl);
        }
        var range = options.headers["Range"] ?? options.headers["range"];
        if (url == "https://gh-proxy.org/$tempUrl") {
          // 最快，但给的文件被改过
          return FakeHttpAdapter.bytes(bad);
        }
        if (url == "https://gh-proxy.com/$tempUrl") {
          return FakeHttpAdapter.bytes([], status: 502);
        }
        if (url == tempUrl) {
          return FakeHttpAdapter.bytes(
            good,
            delay: Duration(milliseconds: range != null ? 400 : 0),
          );
        }
        return FakeHttpAdapter.bytes([], status: 404);
      });
      var downloader = UpdateDownloader(
        FakeHttpAdapter.dio(adapter),
        config: config,
        token: "gho_x",
      );
      var plan = DownloadSource.forSetting("auto", config, "", tempLinks: true);
      var stages = <DownloadStage>{};
      var result = await downloader.download(
        asset: asset(digest: "sha256:$goodSha"),
        assets: [asset(digest: "sha256:$goodSha")],
        sources: plan.sources,
        probe: plan.probe,
        directory: dir.path,
        onProgress: (p) => stages.add(p.stage),
      );
      expect(result.source.isDirect, isTrue);
      expect(result.skipped.single, contains("gh-proxy.org"));
      expect(File(result.path).readAsBytesSync(), good);
      expect(File("${result.path}.part").existsSync(), isFalse);
      expect(stages, containsAll(DownloadStage.values));
      // 先测速（带 Range），再按快慢下载：gh-proxy.org 在直连前面，测速失败的 gh-proxy.com 没用上
      var downloads = adapter.requests
          .where(
              (e) => e.uri.toString() != apiUrl && e.headers["Range"] == null)
          .map((e) => e.uri.toString())
          .toList();
      expect(downloads, ["https://gh-proxy.org/$tempUrl", tempUrl]);
      // 令牌只发给 api.github.com
      for (var request in adapter.requests) {
        if (request.uri.host != "api.github.com") {
          expect(request.headers["Authorization"], isNull,
              reason: request.uri.toString());
        }
      }
    });

    test("每个源都不对：报错，列出原因，不留文件", () async {
      var adapter = FakeHttpAdapter((options) {
        var url = options.uri.toString();
        if (url == apiUrl) return FakeHttpAdapter.redirect(tempUrl);
        if (url.startsWith("https://ghfast.top/")) {
          return FakeHttpAdapter.bytes(bad);
        }
        return FakeHttpAdapter.bytes([], status: 503);
      });
      var downloader = UpdateDownloader(
        FakeHttpAdapter.dio(adapter),
        config: config,
        token: "gho_x",
      );
      var plan = DownloadSource.forSetting("ghfast", config, "");
      await expectLater(
        downloader.download(
          asset: asset(digest: "sha256:$goodSha"),
          assets: const [],
          sources: plan.sources,
          probe: plan.probe,
          directory: dir.path,
        ),
        throwsA(isA<DownloadFailed>()
            .having((e) => e.reasons, "reasons", hasLength(2))),
      );
      expect(dir.listSync(), isEmpty);
    });

    test("没有 digest 时用 SHA256SUMS.txt（只从 GitHub 直接读）；都没有时不下载", () async {
      const sumsApi =
          "https://api.github.com/repos/NishinoAkii/simple_live_N/releases/assets/310000009";
      const sumsTemp =
          "https://release-assets.githubusercontent.com/sums?sig=S";
      var sums = const ReleaseAsset(
        name: "SHA256SUMS.txt",
        size: 100,
        digest: "",
        apiUrl: sumsApi,
        browserUrl: "",
      );
      var adapter = FakeHttpAdapter((options) {
        var url = options.uri.toString();
        if (url == apiUrl) return FakeHttpAdapter.redirect(tempUrl);
        if (url == sumsApi) return FakeHttpAdapter.redirect(sumsTemp);
        if (url == sumsTemp) {
          return FakeHttpAdapter.text(
            "${"0" * 64}  other.apk\n$goodSha *$name\n",
          );
        }
        if (url == tempUrl) return FakeHttpAdapter.bytes(good);
        return FakeHttpAdapter.bytes([], status: 404);
      });
      var downloader = UpdateDownloader(
        FakeHttpAdapter.dio(adapter),
        config: config,
        token: "gho_x",
      );
      expect(
          await downloader.expectedSha256(asset(), [asset(), sums]), goodSha);
      var result = await downloader.download(
        asset: asset(),
        assets: [asset(), sums],
        sources: [DownloadSource.direct],
        probe: false,
        directory: dir.path,
      );
      expect(File(result.path).existsSync(), isTrue);

      adapter.requests.clear();
      await expectLater(
        downloader.download(
          asset: asset(),
          assets: [asset()],
          sources: [DownloadSource.direct],
          probe: false,
          directory: dir.path,
        ),
        throwsA(isA<NoChecksumException>()),
      );
      expect(adapter.requests, isEmpty);
    });

    test("上次下好的（取消了 UAC、安装失败）：大小和校验值都对就直接用，不再联网", () async {
      var adapter = FakeHttpAdapter((_) => fail("不该联网"));
      var downloader = UpdateDownloader(
        FakeHttpAdapter.dio(adapter),
        config: config,
        token: "gho_x",
      );
      File("${dir.path}/$name").writeAsBytesSync(good);
      var stages = <DownloadStage>[];
      var result = await downloader.download(
        asset: asset(digest: "sha256:$goodSha"),
        assets: const [],
        sources: [DownloadSource.direct],
        probe: false,
        directory: dir.path,
        onProgress: (p) => stages.add(p.stage),
      );
      expect(result.reused, isTrue);
      expect(result.path, "${dir.path}${Platform.pathSeparator}$name");
      expect(File(result.path).readAsBytesSync(), good);
      expect(stages, [DownloadStage.preparing, DownloadStage.verifying]);
      expect(adapter.requests, isEmpty);
    });

    test("上次留下的文件不对（下了一半、被改过）：删掉重新下载", () async {
      var adapter = FakeHttpAdapter((options) {
        if (options.uri.toString() == apiUrl) {
          return FakeHttpAdapter.redirect(tempUrl);
        }
        return FakeHttpAdapter.bytes(good);
      });
      var downloader = UpdateDownloader(
        FakeHttpAdapter.dio(adapter),
        config: config,
        token: "gho_x",
      );
      File("${dir.path}/$name").writeAsBytesSync(bad.sublist(0, good.length));
      var result = await downloader.download(
        asset: asset(digest: "sha256:$goodSha"),
        assets: const [],
        sources: [DownloadSource.direct],
        probe: false,
        directory: dir.path,
      );
      expect(result.reused, isFalse);
      expect(File(result.path).readAsBytesSync(), good);
      expect(adapter.to(tempUrl), hasLength(1));
    });

    test("取消：停下，不留文件", () async {
      var cancel = CancelToken();
      var adapter = FakeHttpAdapter((options) {
        if (options.uri.toString() == apiUrl) {
          return FakeHttpAdapter.redirect(tempUrl);
        }
        cancel.cancel();
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: "cancel",
        );
      });
      var downloader = UpdateDownloader(
        FakeHttpAdapter.dio(adapter),
        config: config,
        token: "gho_x",
      );
      await expectLater(
        downloader.download(
          asset: asset(digest: "sha256:$goodSha"),
          assets: const [],
          sources: [DownloadSource.direct],
          probe: false,
          directory: dir.path,
          cancelToken: cancel,
        ),
        throwsA(isA<DownloadCancelled>()),
      );
      expect(dir.listSync(), isEmpty);
    });
  });

  group("出错的原因写成短话", () {
    FileSystemException fs(int code) =>
        FileSystemException("x", "update.zip", OSError("os", code));

    test("没有写入权限、磁盘空间不足；认不出的为 null", () {
      expect(UpdateErrorText.file(fs(5), windows: true), "没有写入权限");
      expect(UpdateErrorText.file(fs(112), windows: true), "磁盘空间不足");
      expect(UpdateErrorText.file(fs(39), windows: true), "磁盘空间不足");
      expect(UpdateErrorText.file(fs(13), windows: false), "没有写入权限");
      expect(UpdateErrorText.file(fs(28), windows: false), "磁盘空间不足");
      // 同一个数字在另一种系统上是别的意思
      expect(UpdateErrorText.file(fs(28), windows: true), isNull);
      expect(UpdateErrorText.file(fs(5), windows: false), isNull);
      expect(UpdateErrorText.file(const FileSystemException("x")), isNull);
    });

    test("网络：超时、连不上、HTTP 状态码；下载时写文件出错也认", () {
      var options = RequestOptions(path: "https://example.com/a");
      expect(
        UpdateErrorText.network(DioException.receiveTimeout(
          timeout: const Duration(seconds: 1),
          requestOptions: options,
        )),
        "连接超时",
      );
      expect(
        UpdateErrorText.network(DioException.connectionError(
          requestOptions: options,
          reason: "offline",
        )),
        "网络连接失败",
      );
      expect(
        UpdateErrorText.network(DioException.badResponse(
          statusCode: 503,
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 503),
        )),
        "HTTP 503",
      );
      var disk = DioException(
        requestOptions: options,
        error: FileSystemException(
          "write",
          "x",
          OSError("full", Platform.isWindows ? 112 : 28),
        ),
      );
      expect(UpdateErrorText.network(disk), "磁盘空间不足");
      expect(UpdateErrorText.of(disk), "磁盘空间不足");
      expect(
        UpdateErrorText.of(const UpdateException(UpdateErrorKind.needLogin)),
        "需要先登录 GitHub",
      );
    });
  });
}
