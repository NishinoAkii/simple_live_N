import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 界面语言：选哪种语言、翻译文件的格式、内置的两张表有没有写坏
void main() {
  tearDown(() => CoreText.lookup = null);

  group("文字", () {
    test("没接语言表时就是简体中文原文", () {
      expect("复制弹幕".t, "复制弹幕");
      expect("共 {count} 条".tf({"count": 3}), "共 3 条");
    });

    test("有译文用译文，占位符按名字换，顺序可以不一样", () {
      CoreText.lookup = (key) => const {
        "复制弹幕": "Copy danmaku",
        "{name} 的第 {page} 页": "Page {page} of {name}",
      }[key];
      expect("复制弹幕".t, "Copy danmaku");
      expect("{name} 的第 {page} 页".tf({"name": "A", "page": 2}), "Page 2 of A");
      // 没有译文的显示原文；参数里没有的占位符原样留着
      expect("刷新".t, "刷新");
      expect("{a} 和 {b}".tf({"a": 1}), "1 和 {b}");
    });

    test("同一段中文要译成两个词时，键后面加“##说明”", () {
      expect("关注##verb".t, "关注");
      CoreText.lookup = (key) => const {"关注": "Following"}[key];
      expect("关注".t, "Following");
      // 没有带说明的那条：用不带说明的
      expect("关注##verb".t, "Following");
      CoreText.lookup = (key) => const {
        "关注": "Following",
        "关注##verb": "follow",
      }[key];
      expect("关注##verb".t, "follow");
    });

    test("大数的写法：中文按万、亿，译成拉丁字母单位的语言按 K、M", () {
      expect(Utils.compactNumber(9999), "9999");
      expect(Utils.compactNumber(198183), "19.8万");
      expect(Utils.compactNumber(230000000, yi: true), "2.3亿");
      CoreText.lookup = (key) => const {"万": "萬", "亿": "億"}[key];
      expect(Utils.compactNumber(198183), "19.8萬");
      expect(Utils.compactNumber(230000000, yi: true), "2.3億");
      CoreText.lookup = (key) => const {"万": "K", "亿": "B"}[key];
      expect(Utils.compactNumber(9999), "9999");
      expect(Utils.compactNumber(198183), "198.2K");
      expect(Utils.compactNumber(2300000), "2.3M");
      expect(Utils.compactNumber(2300000000, yi: true), "2.3B");
    });
  });

  group("跟随系统", () {
    AppLanguage pick(List<Locale> locales, [List<AppLanguage> more = const []]) =>
        I18n.resolveSystem(locales, [...I18n.builtIn, ...more]);

    test("中文看简体还是繁体", () {
      expect(pick([const Locale("zh", "CN")]), I18n.zhHans);
      expect(pick([const Locale("zh")]), I18n.zhHans);
      expect(pick([const Locale("zh", "TW")]), I18n.zhHant);
      expect(pick([const Locale("zh", "HK")]), I18n.zhHant);
      expect(
        pick([const Locale.fromSubtags(languageCode: "zh", scriptCode: "Hant")]),
        I18n.zhHant,
      );
      // 写明了简体字的，在台湾也是简体
      expect(
        pick([
          const Locale.fromSubtags(
            languageCode: "zh",
            scriptCode: "Hans",
            countryCode: "TW",
          ),
        ]),
        I18n.zhHans,
      );
    });

    test("英文用英文；别的语言有导入的翻译就用，没有用英文", () {
      const japanese = AppLanguage("ja", "日本語", path: "ja.json");
      const brazil = AppLanguage("pt-BR", "Português", path: "pt-BR.json");
      expect(pick([const Locale("en", "US")]), I18n.english);
      expect(pick([const Locale("ja", "JP")]), I18n.english);
      expect(pick([const Locale("ja", "JP")], [japanese]), japanese);
      expect(pick([const Locale("pt", "BR")], [brazil]), brazil);
      // 按系统的语言顺序，第一个能用的
      expect(
        pick([const Locale("fr"), const Locale("zh", "TW")]),
        I18n.zhHant,
      );
      expect(pick([]), I18n.english);
    });

    test("给 Flutter 自带控件的语言", () {
      expect(I18n.flutterLocale(I18n.zhHans), const Locale("zh", "CN"));
      expect(I18n.flutterLocale(I18n.zhHant), const Locale("zh", "TW"));
      expect(I18n.flutterLocale(I18n.english), const Locale("en"));
      expect(
        I18n.flutterLocale(const AppLanguage("pt-BR", "Português")),
        const Locale("pt"),
      );
      // Flutter 没有的语言用英文
      expect(
        I18n.flutterLocale(const AppLanguage("tlh", "Klingon")),
        const Locale("en"),
      );
    });
  });

  group("翻译文件", () {
    test("读：@@ 开头的是说明，不是文字对文字的不要", () {
      var parsed = I18n.parseTable(
        jsonEncode({
          "@@code": " ja ",
          "@@name": "日本語",
          "@@source": "https://example.com/ja.json",
          "设置": "設定",
          "空的": "",
          "数字": 1,
        }),
      );
      expect(parsed.code, "ja");
      expect(parsed.name, "日本語");
      expect(parsed.source, "https://example.com/ja.json");
      expect(parsed.table, {"设置": "設定"});
    });

    test("不是 JSON 对象的报错", () {
      expect(() => I18n.parseTable("not json"), throwsFormatException);
      expect(() => I18n.parseTable("[1, 2]"), throwsFormatException);
    });

    test("GitHub 网页上的文件地址换成直接下载的地址", () {
      expect(
        I18n.rawUrl("https://github.com/someone/lang/blob/main/app/ja.json"),
        "https://raw.githubusercontent.com/someone/lang/main/app/ja.json",
      );
      expect(
        I18n.rawUrl(" https://example.com/ja.json "),
        "https://example.com/ja.json",
      );
    });
  });

  group("选语言、导入、同步", () {
    late Directory folder;
    const japanese = '{"@@code": "ja", "@@name": "日本語", "设置": "設定"}';

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      folder = Directory.systemTemp.createTempSync("i18n_test");
      // 测试里没有界面可重画
      I18n.refreshApp = (_) async {};
      await I18n.init("en", folder);
    });

    tearDown(() async {
      await I18n.init("zh-Hans", Directory("${folder.path}/none"));
      folder.deleteSync(recursive: true);
    });

    test("选英文：用内置的英文表；选简体：就是原文", () async {
      expect(I18n.current.value, I18n.english);
      expect("设置".t, "Settings");
      await I18n.select("zh-Hans");
      expect(I18n.current.value, I18n.zhHans);
      expect("设置".t, "设置");
      await I18n.select("zh-Hant");
      expect("设置".t, "設定");
    });

    test("导入一份翻译：列出来、能选，缺的句子用英文；删掉后回到跟随系统", () async {
      var language = await I18n.importText(japanese);
      expect(language.code, "ja");
      expect(language.name, "日本語");
      expect(I18n.imported, [language]);
      expect(File("${folder.path}/ja.json").existsSync(), isTrue);

      await I18n.select("ja");
      expect(I18n.setting.value, "ja");
      expect("设置".t, "設定");
      expect("刷新".t, "Refresh");

      await I18n.remove(language);
      expect(I18n.imported, isEmpty);
      expect(I18n.setting.value, I18n.followSystem);
      expect(File("${folder.path}/ja.json").existsSync(), isFalse);
    });

    test("不收的文件：没有译文、代码不对、想替换内置语言", () async {
      expect(() => I18n.importText('{"@@code": "ja"}'), throwsFormatException);
      expect(
        () => I18n.importText('{"@@code": "a b", "设置": "x"}'),
        throwsFormatException,
      );
      expect(
        () => I18n.importText('{"@@code": "en", "设置": "x"}'),
        throwsFormatException,
      );
      // 文件里没写代码时用文件名
      var language = await I18n.importText(
        '{"设置": "Einstellungen"}',
        fallbackCode: "de",
      );
      expect(language.code, "de");
      expect(language.name, "de");
    });

    test("下载的翻译记着网址", () async {
      var language = await I18n.importText(
        japanese,
        source: "https://example.com/ja.json",
      );
      expect(language.source, "https://example.com/ja.json");
      expect(
        I18n.parseTable(File(language.path!).readAsStringSync()).table,
        {"设置": "設定"},
      );
    });

    test("WebDAV：备份里带着导入的翻译，另一台设备恢复时加上", () async {
      await I18n.importText(japanese);
      var backup = I18n.exportSync();
      expect(backup.keys, ["ja"]);

      // 另一台设备：自己有一份德文，没有日文
      var other = Directory.systemTemp.createTempSync("i18n_other");
      addTearDown(() => other.deleteSync(recursive: true));
      await I18n.init("en", other);
      await I18n.importText('{"@@code": "de", "设置": "Einstellungen"}');
      await I18n.restoreSync(backup);
      expect(I18n.imported.map((e) => e.code).toSet(), {"de", "ja"});
      // 备份里读不了的那份跳过，不影响别的
      await I18n.restoreSync({"xx": "not json", "ja": japanese});
      expect(I18n.imported.map((e) => e.code).toSet(), {"de", "ja"});
    });

    test("模板里是全部句子，右边是英文", () async {
      var template = jsonDecode(await I18n.template()) as Map;
      expect(template["@@code"], "");
      expect(template["设置"], "Settings");
      expect(template.length, greaterThan(1500));
    });
  });

  group("内置的翻译", () {
    final placeholder = RegExp(r"\{\w+\}");
    for (var code in ["en", "zh-Hant"]) {
      test("$code：格式对，占位符和原文一致", () {
        var text = File("assets/lang/$code.json").readAsStringSync();
        var parsed = I18n.parseTable(text);
        expect(parsed.code, code);
        expect(parsed.name, isNotEmpty);
        expect(parsed.table.length, greaterThan(1500));
        var wrong = <String>[];
        parsed.table.forEach((key, value) {
          var want = placeholder.allMatches(key).map((m) => m[0]).toSet();
          var got = placeholder.allMatches(value).map((m) => m[0]).toSet();
          if (want.length != got.length || !want.containsAll(got)) {
            wrong.add("$key -> $value");
          }
        });
        expect(wrong, isEmpty);
      });
    }

    test("英文里没有留下中文", () {
      var table = I18n.parseTable(
        File("assets/lang/en.json").readAsStringSync(),
      ).table;
      var chinese = RegExp(r"[㐀-鿿]");
      expect(table.values.where(chinese.hasMatch).toList(), isEmpty);
    });
  });
}
