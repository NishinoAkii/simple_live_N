import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/source_hooks.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/app_update/app_update_service.dart';
import 'package:simple_live_app/services/app_update/translation_sources.dart';
import 'package:simple_live_app/services/app_update/update_config.dart';
import 'package:simple_live_app/services/app_update/update_downloader.dart';
import 'package:simple_live_app/services/app_update/update_settings.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

import 'fakes/fake_http_adapter.dart';
import 'fakes/memory_storage.dart';

/// 翻译源和直播源订阅（1.25.0）：翻译清单、安装 / 更新 / 删除、检查更新时怎么判断变了。
/// 全部用假的 HTTP，不联网
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const gist =
      "https://gist.githubusercontent.com/NishinoAkii/7ef617aacd2b81be3a337db6ae33cdaa/raw/translations.json";
  const gistJa =
      "https://gist.githubusercontent.com/NishinoAkii/7ef617aacd2b81be3a337db6ae33cdaa/raw/ja.json";
  const config = UpdateConfig(
    owner: "NishinoAkii",
    repo: "simple_live_N",
    tagPrefix: "v",
    needsLogin: true,
    mirrors: [UpdateMirror("ghfast", "ghfast.top", "https://ghfast.top/")],
    translationSource: gist,
  );

  late Directory folder;
  late Directory work;
  late MemoryStorage storage;
  late UpdateSettings settings;

  List<int> ja(String settingsText) => utf8.encode(jsonEncode({
        "@@code": "ja",
        "@@name": "日本語",
        "设置": settingsText,
        "刷新": "更新",
      }));
  String sha(List<int> bytes) => crypto.sha256.convert(bytes).toString();

  setUp(() async {
    Get.testMode = true;
    storage = MemoryStorage.install();
    settings = UpdateSettings();
    folder = Directory.systemTemp.createTempSync("app_sources_lang");
    work = Directory.systemTemp.createTempSync("app_sources_work");
    I18n.refreshApp = (_) async {};
    await I18n.init("zh-Hans", folder);
  });

  tearDown(() async {
    SourceHooks.reset();
    MultiWindow.launch = null;
    await I18n.init("zh-Hans", Directory("${folder.path}/none"));
    folder.deleteSync(recursive: true);
    work.deleteSync(recursive: true);
    Get.reset();
  });

  TranslationSources sourcesWith(FakeHttpAdapter adapter) => TranslationSources(
        FakeHttpAdapter.dio(adapter),
        config: config,
        settings: settings,
        workDirectory: () async => work.path,
      );

  group("翻译清单", () {
    test("旧的清单（没有 version、sha256）照样能用；新的可以写版本和校验值", () {
      var entries = TranslationIndex.parse(
        jsonEncode({
          "languages": [
            {"code": "es", "name": "Español", "url": "es.json"},
            {
              "code": "ja",
              "name": "日本語",
              "url": "ja.json",
              "version": "3",
              "sha256": "sha256:${"AB" * 32}",
            },
            // 写错的校验值当作没写
            {"code": "ko", "url": "ko.json", "sha256": "xyz"},
            // 内置的语言、没有地址的、代码不对的不要
            {"code": "en", "url": "en.json"},
            {"code": "de"},
            {"code": "a b", "url": "x.json"},
          ],
        }),
        gist,
      );
      expect(entries.map((e) => e.code), ["es", "ja", "ko"]);
      expect(entries[0].url, endsWith("/raw/es.json"));
      expect(entries[0].version, "");
      expect(entries[0].sha256, "");
      expect(entries[1].version, "3");
      expect(entries[1].sha256, "ab" * 32);
      expect(entries[2].name, "ko");
      expect(entries[2].sha256, "");
      expect(
        () => TranslationIndex.parse('{"sources": []}', gist),
        throwsFormatException,
      );
    });
  });

  group("安装、更新、删除", () {
    test("安装：记下来源、版本、校验值；版本变了时更新；删除时正在用的回到跟随系统", () async {
      var v1 = ja("設定");
      var v2 = ja("設定（新）");
      var index = {
        "languages": [
          {
            "code": "ja",
            "name": "日本語",
            "url": "ja.json",
            "version": "1",
            "sha256": sha(v1)
          },
        ],
      };
      var file = v1;
      var adapter = FakeHttpAdapter((options) {
        var url = options.uri.toString();
        if (url == gist) {
          return FakeHttpAdapter.bytes(utf8.encode(jsonEncode(index)));
        }
        if (url == gistJa) return FakeHttpAdapter.bytes(file);
        return FakeHttpAdapter.bytes([], status: 404);
      });
      var sources = sourcesWith(adapter);
      var entries = await sources.fetchIndex();
      expect(entries.single.url, gistJa);
      expect(
        TranslationSources.stateOf(entries.single, null),
        TranslationState.notInstalled,
      );

      var language = await sources.install(entries.single);
      expect(I18n.imported.map((e) => e.code), ["ja"]);
      var installed = TranslationSources.installed()["ja"]!;
      expect(installed.source, gistJa);
      expect(installed.version, "1");
      expect(installed.sha256, sha(v1));
      expect(installed.table["设置"], "設定");
      expect(
        TranslationSources.stateOf(entries.single, installed),
        TranslationState.upToDate,
      );
      // 装好就能选
      await I18n.select("ja");
      expect("设置".t, "設定");

      // 发布了新版本
      file = v2;
      index["languages"]![0]["version"] = "2";
      index["languages"]![0]["sha256"] = sha(v2);
      var result = await sources.updateInstalled();
      expect(result.updated.map((e) => e.code), ["ja"]);
      expect(result.failed, isEmpty);
      expect(TranslationSources.installed()["ja"]!.version, "2");
      expect("设置".t, "設定（新）");

      await TranslationSources.remove(language);
      expect(I18n.imported, isEmpty);
      expect(I18n.setting.value, I18n.followSystem);
      expect(
          storage.values[LocalStorageService.kAppLanguage], I18n.followSystem);
    });

    test("校验值对不上：每个源都不要，不装", () async {
      var adapter =
          FakeHttpAdapter((options) => FakeHttpAdapter.bytes(ja("x")));
      var sources = sourcesWith(adapter);
      var entry = TranslationEntry(
        code: "ja",
        name: "日本語",
        url: gistJa,
        sha256: "0" * 64,
      );
      await expectLater(sources.install(entry), throwsA(isA<DownloadFailed>()));
      expect(I18n.imported, isEmpty);
    });
  });

  group("检查翻译更新：哪些变了", () {
    InstalledTranslation installed({
      String source = gistJa,
      String version = "",
      String sha256 = "",
    }) =>
        InstalledTranslation(
          language: const AppLanguage("ja", "日本語", path: "ja.json"),
          source: source,
          version: version,
          sha256: sha256,
          name: "日本語",
          table: const {"设置": "設定"},
        );

    test("有校验值看校验值，有版本看版本，都没有要比内容；别处装的不管", () {
      TranslationState state(TranslationEntry e, InstalledTranslation i) =>
          TranslationSources.stateOf(e, i);
      var plain = const TranslationEntry(code: "ja", name: "", url: gistJa);
      expect(state(plain, installed()), TranslationState.unknown);
      expect(state(plain, installed(source: "https://other.example/ja.json")),
          TranslationState.otherSource);
      var versioned = const TranslationEntry(
          code: "ja", name: "", url: gistJa, version: "2");
      expect(
          state(versioned, installed(version: "2")), TranslationState.upToDate);
      expect(
          state(versioned, installed(version: "1")), TranslationState.changed);
      var hashed = TranslationEntry(
          code: "ja", name: "", url: gistJa, sha256: "a" * 64, version: "2");
      // 校验值优先：版本一样、内容换了也算变了
      expect(state(hashed, installed(version: "2", sha256: "b" * 64)),
          TranslationState.changed);
      expect(state(hashed, installed(sha256: "a" * 64)),
          TranslationState.upToDate);
    });

    test("旧的清单：内容一样不动，变了才换；别处装的、没装翻译时不联网", () async {
      var file = ja("設定");
      var index = {
        "languages": [
          {"code": "ja", "name": "日本語", "url": "ja.json"},
        ],
      };
      var adapter = FakeHttpAdapter((options) {
        var url = options.uri.toString();
        if (url == gist) {
          return FakeHttpAdapter.bytes(utf8.encode(jsonEncode(index)));
        }
        if (url == gistJa) return FakeHttpAdapter.bytes(file);
        return FakeHttpAdapter.bytes([], status: 404);
      });
      var sources = sourcesWith(adapter);
      // 没装翻译：不联网
      expect((await sources.updateInstalled()).updated, isEmpty);
      expect(adapter.requests, isEmpty);

      await sources.install((await sources.fetchIndex()).single);
      var before = File(I18n.imported.single.path!).readAsStringSync();
      expect((await sources.updateInstalled()).updated, isEmpty);
      expect(File(I18n.imported.single.path!).readAsStringSync(), before);

      file = ja("設定２");
      expect(
        (await sources.updateInstalled()).updated.map((e) => e.code),
        ["ja"],
      );

      // 自己导入的同一种语言（来源不一样）不自动换
      await I18n.importText(utf8.decode(ja("自分の")));
      adapter.requests.clear();
      file = ja("設定３");
      expect((await sources.updateInstalled()).updated, isEmpty);
      expect(adapter.requests.map((e) => e.uri.toString()), [gist]);
      expect("设置".t, "设置");
      expect(TranslationSources.installed()["ja"]!.table["设置"], "自分の");
    });

    test("和 App 更新一起查：主窗口、开关；不用登录（翻译源是 github: 时才要）", () {
      var service = Get.put(AppUpdateService(
        config: config,
        dio: FakeHttpAdapter.dio(FakeHttpAdapter((_) => fail("不该联网"))),
        sourcesDirectory: () async => work.path,
      ));
      expect(service.startupBlocker(), AutoCheckBlock.needLogin);
      expect(service.translationBlocker(), isNull);
      service.settings.setAutoCheck(false);
      expect(service.translationBlocker(), AutoCheckBlock.turnedOff);
      service.settings.setAutoCheck(true);
      MultiWindow.launch = SecondaryLaunch(
        port: 1,
        token: WindowToken.generate(),
        dataDir: "/tmp/multi_window/w1-1",
        slot: 1,
        siteId: "douyu",
        roomId: "1",
      );
      expect(service.translationBlocker(), AutoCheckBlock.secondaryWindow);
    });
  });

}
