import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/source_hooks.dart';
import 'package:simple_live_core/simple_live_core.dart'
    show CoreText, I18nText;

export 'package:simple_live_core/simple_live_core.dart' show CoreText, I18nText;

/// 把开头的小写拉丁字母改成大写（中文不受影响）。代码里拼出来、以动词开头的句子用，
/// 如“follow Alice”
String upperFirst(String text) =>
    text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

/// 一种界面语言
class AppLanguage {
  /// 语言代码：zh-Hans、zh-Hant、en，导入的文件用它自己写的（如 ja、de）
  final String code;

  /// 用这种语言自己写的名字，如“繁體中文”“English”
  final String name;

  /// 导入的翻译文件；内置的语言为 null
  final String? path;

  /// 导入的翻译是从哪个网址下载的（可以再下载一次更新）；不是下载的为空
  final String source;

  const AppLanguage(this.code, this.name, {this.path, this.source = ""});

  bool get builtIn => path == null;

  @override
  bool operator ==(Object other) => other is AppLanguage && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => "AppLanguage($code, $name)";
}

/// 网上的翻译清单里的一项
class RemoteLanguage {
  final String code;
  final String name;
  final String url;
  const RemoteLanguage(this.code, this.name, this.url);
}

/// 一份翻译文件的内容
typedef LanguageTable = ({
  String code,
  String name,
  String source,
  Map<String, String> table,
});

/// 界面语言。源码里写的是简体中文，同时也是翻译表的键（见 [CoreText]）；
/// 其他语言各有一张“简体中文 → 译文”的表：
///
/// - 内置的繁体中文、英文在 assets/lang/ 里
/// - 用户导入的翻译文件放在数据目录的 lang 文件夹里，格式和内置的一样：
///   `{"@@code": "ja", "@@name": "日本語", "设置": "設定", ...}`
///   可以选文件导入、填网址下载，也会跟着 WebDAV 同步到别的设备
///
/// 导入的文件里没有的句子用英文，英文也没有的用简体中文原文
class I18n {
  static const zhHans = AppLanguage("zh-Hans", "简体中文");
  static const zhHant = AppLanguage("zh-Hant", "繁體中文");
  static const english = AppLanguage("en", "English");
  static const builtIn = [zhHans, zhHant, english];

  /// 设置里“跟随系统”存的值
  static const followSystem = "";

  /// 现在用的语言（选了跟随系统时，是按系统语言选出来的那个）
  static final current = Rx<AppLanguage>(zhHans);

  /// 导入的语言
  static final imported = <AppLanguage>[].obs;

  /// 设置里选的值：[followSystem] 或语言代码
  static final setting = followSystem.obs;

  static Map<String, String> _table = const {};
  static Map<String, String> _english = const {};
  static Directory? _folder;

  /// 导入的文件的原文（代码 → 内容），WebDAV 同步时直接用
  static final Map<String, String> _texts = {};
  static _LocaleObserver? _observer;

  static List<AppLanguage> get languages => [...builtIn, ...imported];

  /// 选跟随系统时会用哪种语言
  static AppLanguage get systemLanguage => resolveSystem(
    WidgetsBinding.instance.platformDispatcher.locales,
    languages,
  );

  /// 启动时调用一次。[folder] 是放导入文件的文件夹
  static Future<void> init(String saved, Directory folder) async {
    _folder = folder;
    CoreText.lookup = _lookup;
    CoreText.snapshot = () => snapshot;
    await _scanFolder();
    await _apply(saved);
    if (_observer == null) {
      _observer = _LocaleObserver();
      WidgetsBinding.instance.addObserver(_observer!);
    }
  }

  /// 换了语言以后让界面重画。测试里没有界面，换成空函数
  static Future<void> Function(Locale locale) refreshApp = Get.updateLocale;

  /// 换语言（[value] 是 [followSystem] 或语言代码），界面马上跟着变
  static Future<void> select(String value) async {
    await _apply(value);
    await refreshApp(flutterLocale(current.value));
  }

  /// 系统语言变了：选的是跟随系统时跟着换
  static Future<void> systemLocaleChanged() async {
    if (setting.value != followSystem) return;
    if (systemLanguage != current.value) {
      await select(followSystem);
    }
  }

  static String? _lookup(String key) => _table[key] ?? _english[key];

  /// 现在这种语言的表（后台跑直播源脚本的 isolate 要一份）
  static Map<String, String> get snapshot => {..._english, ..._table};

  static Future<void> _apply(String value) async {
    var language = value == followSystem
        ? systemLanguage
        : languages.firstWhereOrNull((e) => e.code == value);
    if (language == null) {
      // 导入的文件没有了：回到跟随系统
      value = followSystem;
      language = systemLanguage;
    }
    var table = await _load(language);
    // 导入的语言缺的句子用英文补；中文两种不用补，缺的直接显示原文
    _english = language.builtIn ? const {} : await _load(english);
    _table = table;
    setting.value = value;
    current.value = language;
  }

  static Future<Map<String, String>> _load(AppLanguage language) async {
    if (language == zhHans) return const {};
    try {
      var text =
          _texts[language.code] ??
          await rootBundle.loadString("assets/lang/${language.code}.json");
      return parseTable(text).table;
    } catch (_) {
      return const {};
    }
  }

  /// 读一份翻译文件。不是“文字 → 文字”的 JSON 对象时抛 [FormatException]
  static LanguageTable parseTable(String text) {
    dynamic json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      throw FormatException("这不是翻译文件（不是 JSON）".t);
    }
    if (json is! Map) {
      throw FormatException("这不是翻译文件（不是 JSON）".t);
    }
    var table = <String, String>{};
    json.forEach((key, value) {
      if (key is String &&
          value is String &&
          !key.startsWith("@@") &&
          value.isNotEmpty) {
        table[key] = value;
      }
    });
    String meta(String key) {
      var value = json[key];
      return value is String ? value.trim() : "";
    }

    return (
      code: meta("@@code"),
      name: meta("@@name"),
      source: meta("@@source"),
      table: table,
    );
  }

  static final RegExp _codePattern = RegExp(r"^[A-Za-z0-9_-]{2,20}$");

  static Future<void> _scanFolder() async {
    var folder = _folder;
    var found = <AppLanguage>[];
    _texts.clear();
    if (folder != null && await folder.exists()) {
      var files = await folder
          .list()
          .where((e) => e is File && e.path.toLowerCase().endsWith(".json"))
          .toList();
      files.sort((a, b) => a.path.compareTo(b.path));
      for (var file in files) {
        try {
          var text = await File(file.path).readAsString();
          var parsed = parseTable(text);
          var code = parsed.code.isEmpty ? _fileCode(file.path) : parsed.code;
          if (!_codePattern.hasMatch(code) ||
              builtIn.any((e) => e.code == code) ||
              found.any((e) => e.code == code)) {
            continue;
          }
          _texts[code] = text;
          found.add(
            AppLanguage(
              code,
              parsed.name.isEmpty ? code : parsed.name,
              path: file.path,
              source: parsed.source,
            ),
          );
        } catch (_) {
          // 读不了的文件不列出来
        }
      }
    }
    imported.assignAll(found);
  }

  static String _fileCode(String path) {
    var name = path.split(RegExp(r"[\\/]")).last;
    return name.toLowerCase().endsWith(".json")
        ? name.substring(0, name.length - ".json".length)
        : name;
  }

  /// 导入一份翻译文件，返回它对应的语言
  static Future<AppLanguage> importFile(String path) async => importText(
    await File(path).readAsString(),
    fallbackCode: _fileCode(path),
  );

  /// 导入翻译文件的内容。文件里没写 @@code 时用 [fallbackCode]；
  /// [source] 是下载的网址，记在文件里，之后可以再下载一次更新；
  /// [meta] 是翻译源清单里这一项的版本、校验值（@@version、@@sha256），检查更新时用
  static Future<AppLanguage> importText(
    String text, {
    String fallbackCode = "",
    String source = "",
    Map<String, String> meta = const {},
  }) async {
    var parsed = parseTable(text);
    var code = parsed.code.isEmpty ? fallbackCode : parsed.code;
    if (!_codePattern.hasMatch(code)) {
      throw FormatException("文件里的 @@code 要写语言代码，如 ja、de、pt-BR".t);
    }
    if (builtIn.any((e) => e.code == code)) {
      throw FormatException("内置的语言不能替换：{code}".tf({"code": code}));
    }
    if (parsed.table.isEmpty) {
      throw FormatException("文件里没有译文".t);
    }
    var extra = {
      for (var entry in meta.entries)
        if (entry.value.isNotEmpty) "@@${entry.key}": entry.value,
    };
    if ((source.isNotEmpty && parsed.source != source) || extra.isNotEmpty) {
      var json = Map<String, dynamic>.from(jsonDecode(text) as Map)
        ..remove("@@code")
        ..remove("@@name")
        ..remove("@@source")
        ..removeWhere((key, _) => extra.containsKey(key));
      text = const JsonEncoder.withIndent("  ").convert({
        "@@code": code,
        "@@name": parsed.name.isEmpty ? code : parsed.name,
        if (source.isNotEmpty || parsed.source.isNotEmpty)
          "@@source": source.isNotEmpty ? source : parsed.source,
        ...extra,
        ...json,
      });
    }
    var folder = _folder!;
    await folder.create(recursive: true);
    await File(
      "${folder.path}${Platform.pathSeparator}$code.json",
    ).writeAsString(text);
    await _scanFolder();
    var language = imported.firstWhere((e) => e.code == code);
    if (current.value == language) {
      // 更新了正在用的语言
      await select(setting.value);
    }
    return language;
  }

  /// 删掉一份导入的翻译；正在用它时回到跟随系统
  static Future<void> remove(AppLanguage language) async {
    var path = language.path;
    if (path == null) return;
    var file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
    var using = current.value == language || setting.value == language.code;
    await _scanFolder();
    if (using) {
      await select(followSystem);
    }
  }

  /// 给翻译的人用的模板：全部句子，右边先填着英文，改成自己的语言就行
  static Future<String> template() async {
    var table = await _load(english);
    return const JsonEncoder.withIndent(
      "  ",
    ).convert({"@@code": "", "@@name": "", ...table});
  }

  /// GitHub 网页上的文件地址换成能直接下载的地址，别的地址原样
  static String rawUrl(String url) {
    var match = RegExp(
      r"^https?://github\.com/([^/]+)/([^/]+)/(?:blob|raw)/(.+)$",
    ).firstMatch(url.trim());
    return match == null
        ? url.trim()
        : "https://raw.githubusercontent.com/${match[1]}/${match[2]}/${match[3]}";
  }

  static Future<String> _download(String url) async {
    // 装了 SourceHooks 时，github: 地址由它读
    var hook = SourceHooks.fetch;
    if (hook != null) {
      var bytes = await hook(url.trim());
      if (bytes != null) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
    var uri = Uri.tryParse(rawUrl(url));
    if (uri == null || !(uri.isScheme("https") || uri.isScheme("http"))) {
      throw FormatException("请填 http 或 https 开头的网址".t);
    }
    var client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      var request = await client.getUrl(uri);
      var response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException(
          "下载失败（{code}）".tf({"code": response.statusCode}),
        );
      }
      var bytes = BytesBuilder(copy: false);
      await for (var chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.add(chunk);
        if (bytes.length > 4 << 20) {
          throw FormatException("文件太大，不像翻译文件".t);
        }
      }
      return utf8.decode(bytes.takeBytes(), allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }

  /// 从网址添加翻译。网址是一份翻译文件时直接导入，返回 added；
  /// 是一份清单（`{"languages": [{"code", "name", "url"}]}`）时返回 choices，
  /// 让用户挑了以后再用其中的 url 调一次
  static Future<({AppLanguage? added, List<RemoteLanguage> choices})>
  addFromUrl(String url) async {
    var address = rawUrl(SourceHooks.normalizeUrl(url.trim()));
    var text = await _download(address);
    dynamic json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      throw FormatException("这不是翻译文件（不是 JSON）".t);
    }
    if (json is Map && json["languages"] is List) {
      var base = Uri.parse(address);
      var choices = <RemoteLanguage>[];
      for (var item in json["languages"] as List) {
        if (item is! Map || item["url"] is! String) continue;
        var code = "${item["code"] ?? ""}".trim();
        var name = "${item["name"] ?? ""}".trim();
        choices.add(
          RemoteLanguage(
            code,
            name.isEmpty ? code : name,
            base.resolve(item["url"] as String).toString(),
          ),
        );
      }
      return (added: null, choices: choices);
    }
    var fallback = _fileCode(Uri.parse(address).pathSegments.lastOrNull ?? "");
    var language = await importText(
      text,
      fallbackCode: fallback,
      source: address,
    );
    return (added: language, choices: const <RemoteLanguage>[]);
  }

  /// 导入的翻译（代码 → 文件内容），放进 WebDAV 的备份里
  static Map<String, String> exportSync() => Map.of(_texts);

  /// 备份里带来的翻译：本机没有的加上，内容不一样的换成备份里的；本机多出来的不删
  static Future<void> restoreSync(Map<dynamic, dynamic> data) async {
    for (var entry in data.entries) {
      var code = entry.key;
      var text = entry.value;
      if (code is! String || text is! String || _texts[code] == text) continue;
      try {
        await importText(text, fallbackCode: code);
      } catch (_) {
        // 备份里的这份读不了：跳过，不影响别的
      }
    }
  }

  /// 按系统的语言顺序挑一种：中文看是简体还是繁体，别的语言有导入的翻译就用，
  /// 都没有时用英文
  static AppLanguage resolveSystem(
    List<Locale> locales,
    List<AppLanguage> available,
  ) {
    for (var locale in locales) {
      var language = locale.languageCode.toLowerCase();
      if (language == "zh") {
        var script = locale.scriptCode?.toLowerCase();
        var country = locale.countryCode?.toUpperCase();
        var traditional =
            script == "hant" ||
            (script == null && const {"TW", "HK", "MO"}.contains(country));
        return traditional ? zhHant : zhHans;
      }
      if (language == "en") return english;
      var country = locale.countryCode ?? "";
      var tag = (country.isEmpty ? language : "$language-$country")
          .toLowerCase();
      for (var item in available) {
        var code = item.code.toLowerCase().replaceAll("_", "-");
        if (code == tag || code == language) return item;
      }
    }
    return english;
  }

  /// Flutter 自带控件（日期、复制粘贴菜单等）用的语言；它不支持的语言用英文
  static Locale flutterLocale(AppLanguage language) {
    switch (language.code) {
      case "zh-Hans":
        return const Locale("zh", "CN");
      case "zh-Hant":
        return const Locale("zh", "TW");
    }
    var locale = Locale(
      language.code.split(RegExp("[-_]")).first.toLowerCase(),
    );
    return kMaterialSupportedLanguages.contains(locale.languageCode)
        ? locale
        : const Locale("en");
  }

  /// 给 MaterialApp 的 supportedLocales
  static List<Locale> get flutterLocales => [
    const Locale("zh", "CN"),
    const Locale("zh", "TW"),
    for (var code in kMaterialSupportedLanguages)
      if (code != "zh") Locale(code),
  ];
}

class _LocaleObserver with WidgetsBindingObserver {
  @override
  void didChangeLocales(List<Locale>? locales) {
    I18n.systemLocaleChanged();
  }
}
