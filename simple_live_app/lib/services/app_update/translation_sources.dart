import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/source_hooks.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/app_update/update_config.dart';
import 'package:simple_live_app/services/app_update/update_downloader.dart';
import 'package:simple_live_app/services/app_update/update_settings.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 翻译清单里的一种语言
class TranslationEntry {
  final String code;
  final String name;

  /// 按清单的地址补全了的文件地址
  final String url;

  /// 可选：版本（变了就更新）
  final String version;

  /// 可选：文件的 SHA-256（十六进制小写），下载后比对
  final String sha256;

  const TranslationEntry({
    required this.code,
    required this.name,
    required this.url,
    this.version = "",
    this.sha256 = "",
  });
}

/// 翻译清单：`{"languages": [{"code", "name", "url", "version"?, "sha256"?}]}`。
/// 和“从网址下载”认的清单一样；version、sha256 可以不写（旧的清单没有）
class TranslationIndex {
  TranslationIndex._();

  static final RegExp _code = RegExp(r"^[A-Za-z0-9_-]{2,20}$");
  static final RegExp _hex = RegExp(r"^[0-9a-f]{64}$");

  static List<TranslationEntry> parse(String text, String indexUrl) {
    dynamic json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      throw FormatException("翻译清单不是 JSON".t);
    }
    if (json is! Map || json["languages"] is! List) {
      throw FormatException("翻译清单的格式不对，要有 languages".t);
    }
    var base = Uri.tryParse(indexUrl);
    var entries = <TranslationEntry>[];
    for (var item in json["languages"] as List) {
      if (item is! Map || item["url"] is! String) {
        continue;
      }
      var code = "${item["code"] ?? ""}".trim();
      if (!_code.hasMatch(code) || I18n.builtIn.any((e) => e.code == code)) {
        continue;
      }
      var url = (item["url"] as String).trim();
      try {
        url = base == null ? url : base.resolve(url).toString();
      } catch (_) {
        continue;
      }
      var sha = "${item["sha256"] ?? ""}".trim().toLowerCase();
      if (sha.startsWith("sha256:")) {
        sha = sha.substring(7);
      }
      var name = "${item["name"] ?? ""}".trim();
      entries.add(TranslationEntry(
        code: code,
        name: name.isEmpty ? code : name,
        url: url,
        version: "${item["version"] ?? ""}".trim(),
        // 写错的校验值当作没写
        sha256: _hex.hasMatch(sha) ? sha : "",
      ));
    }
    return entries;
  }
}

/// 装过的一份翻译：文件里记的来源、版本、校验值和内容
class InstalledTranslation {
  final AppLanguage language;
  final String source;
  final String version;
  final String sha256;
  final String name;
  final Map<String, String> table;

  const InstalledTranslation({
    required this.language,
    required this.source,
    required this.version,
    required this.sha256,
    required this.name,
    required this.table,
  });

  static InstalledTranslation? read(AppLanguage language) {
    var path = language.path;
    if (path == null) {
      return null;
    }
    try {
      var text = File(path).readAsStringSync();
      var parsed = I18n.parseTable(text);
      var json = jsonDecode(text) as Map;
      String meta(String key) => "${json["@@$key"] ?? ""}".trim();
      return InstalledTranslation(
        language: language,
        source: parsed.source,
        version: meta("version"),
        sha256: meta("sha256").toLowerCase(),
        name: parsed.name,
        table: parsed.table,
      );
    } catch (_) {
      return null;
    }
  }
}

enum TranslationState {
  /// 没装
  notInstalled,

  /// 装了同一种语言，但不是从这个翻译源装的（不自动更新）
  otherSource,

  upToDate,

  /// 清单里的版本或校验值和装的不一样
  changed,

  /// 清单没写版本和校验值：要下载下来比内容
  unknown,
}

/// 检查翻译更新的结果
class TranslationCheckResult {
  /// 换成了新内容的语言
  final List<AppLanguage> updated;

  /// 更新失败的：语言的名字 → 原因
  final Map<String, String> failed;

  const TranslationCheckResult(this.updated, this.failed);
}

/// 翻译源：设置里填的翻译清单（默认是 [UpdateConfig.translationSource]），
/// 列出能下载的语言，安装、更新、删除，检查装过的有没有更新。
///
/// 装的翻译放在 [I18n] 导入的地方（数据目录的 lang 文件夹），照常跟着 WebDAV 同步。
/// 下载：github: 地址交给 [SourceHooks]（装了时，只发给 api.github.com）；
/// 公开的 GitHub 地址按“下载源”的设置可以走镜像，别的地址直连
class TranslationSources {
  final Dio dio;
  final UpdateConfig config;
  final UpdateSettings settings;

  /// 下载时临时放文件的文件夹
  final Future<String> Function() workDirectory;

  TranslationSources(
    this.dio, {
    required this.config,
    required this.settings,
    required this.workDirectory,
  });

  /// 现在用的翻译源
  String get sourceUrl {
    var value = settings.translationSource.value.trim();
    return value.isEmpty ? config.translationSource : value;
  }

  bool get usingDefault => settings.translationSource.value.trim().isEmpty;

  static const Set<String> _githubHosts = {
    "github.com",
    "raw.githubusercontent.com",
    "gist.githubusercontent.com",
    "objects.githubusercontent.com",
  };

  /// 能走镜像的地址（GitHub 上公开的文件）
  static bool isGitHubHost(String url) =>
      _githubHosts.contains(Uri.tryParse(url)?.host.toLowerCase() ?? "");

  static bool _sameSha(List<int> bytes, String sha256) =>
      sha256.isEmpty || crypto.sha256.convert(bytes).toString() == sha256;

  /// 读一个地址：github: 地址交给 [SourceHooks]，别的走下载源（GitHub 上的可以用镜像）。
  /// 给了 [sha256] 时比对；[validate] 看内容对不对，不对时换下一个源
  Future<List<int>> fetch(
    String url, {
    String sha256 = "",
    bool Function(List<int> bytes)? validate,
  }) async {
    var private = await SourceHooks.fetch?.call(url);
    if (private != null) {
      if (!_sameSha(private, sha256)) {
        throw FormatException("文件校验不对：{url}".tf({"url": url}));
      }
      if (validate != null && !validate(private)) {
        throw FormatException("内容不对：{url}".tf({"url": url}));
      }
      return private;
    }
    var sources = isGitHubHost(url)
        ? DownloadSource.forSetting(
            settings.source.value,
            config,
            settings.customMirror.value,
          ).sources
        : [DownloadSource.direct];
    var directory = await workDirectory();
    var name = "source-${crypto.md5.convert(utf8.encode(url))}";
    // 小文件不测速：自动时先直连，不行再换镜像
    var result = await UpdateDownloader(dio, config: config).downloadFile(
      name: name,
      url: () async => url,
      sources: sources,
      directory: directory,
      sha256: sha256,
      validate: validate == null
          ? null
          : (path) async => validate(await File(path).readAsBytes()),
    );
    var file = File(result.path);
    try {
      return await file.readAsBytes();
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  static bool _isIndex(List<int> bytes, String url) {
    try {
      TranslationIndex.parse(utf8.decode(bytes, allowMalformed: true), url);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 读翻译源里的语言列表
  Future<List<TranslationEntry>> fetchIndex() async {
    var url = I18n.rawUrl(sourceUrl);
    var bytes = await fetch(url, validate: (b) => _isIndex(b, url));
    return TranslationIndex.parse(
        utf8.decode(bytes, allowMalformed: true), url);
  }

  /// 装了的语言（代码 → 文件里记的东西）
  static Map<String, InstalledTranslation> installed([
    Iterable<AppLanguage>? languages,
  ]) =>
      {
        for (var language in languages ?? I18n.imported)
          if (InstalledTranslation.read(language) case var item?)
            language.code: item,
      };

  /// 清单里这一项和装的比：没装、别处装的、最新、变了、要比内容
  static TranslationState stateOf(
    TranslationEntry entry,
    InstalledTranslation? installed,
  ) {
    if (installed == null) {
      return TranslationState.notInstalled;
    }
    if (installed.source != entry.url) {
      return TranslationState.otherSource;
    }
    if (entry.sha256.isNotEmpty) {
      return installed.sha256 == entry.sha256
          ? TranslationState.upToDate
          : TranslationState.changed;
    }
    if (entry.version.isNotEmpty) {
      return installed.version == entry.version
          ? TranslationState.upToDate
          : TranslationState.changed;
    }
    return TranslationState.unknown;
  }

  /// 下载的文件像不像这一种语言的翻译：JSON、有译文、@@code（写了的话）和清单一样
  static bool looksLike(List<int> bytes, String code) {
    try {
      var parsed = I18n.parseTable(utf8.decode(bytes, allowMalformed: true));
      return parsed.table.isNotEmpty &&
          (parsed.code.isEmpty || parsed.code == code);
    } catch (_) {
      return false;
    }
  }

  Future<List<int>> _download(TranslationEntry entry) => fetch(
        entry.url,
        sha256: entry.sha256,
        validate: (bytes) => looksLike(bytes, entry.code),
      );

  Future<AppLanguage> _import(TranslationEntry entry, List<int> bytes) =>
      I18n.importText(
        utf8.decode(bytes, allowMalformed: true),
        fallbackCode: entry.code,
        source: entry.url,
        meta: {"version": entry.version, "sha256": entry.sha256},
      );

  /// 安装（已经装了的换成新的）
  Future<AppLanguage> install(TranslationEntry entry) async =>
      _import(entry, await _download(entry));

  /// 删掉一份翻译；正在用它时回到跟随系统
  static Future<void> remove(AppLanguage language) async {
    if (I18n.setting.value == language.code) {
      await LocalStorageService.instance.setValue(
        LocalStorageService.kAppLanguage,
        I18n.followSystem,
      );
    }
    await I18n.remove(language);
  }

  /// 检查从这个翻译源装的语言有没有更新，变了的直接换成新的。
  /// 没有装过翻译时不联网
  Future<TranslationCheckResult> updateInstalled() async {
    var mine = installed();
    if (mine.isEmpty) {
      return const TranslationCheckResult([], {});
    }
    var updated = <AppLanguage>[];
    var failed = <String, String>{};
    for (var entry in await fetchIndex()) {
      var current = mine[entry.code];
      var state = stateOf(entry, current);
      if (state != TranslationState.changed &&
          state != TranslationState.unknown) {
        continue;
      }
      try {
        var bytes = await _download(entry);
        if (state == TranslationState.unknown && current != null) {
          // 清单没写版本：内容和名字都一样就不动
          var parsed =
              I18n.parseTable(utf8.decode(bytes, allowMalformed: true));
          String nameOf(String name) => name.isEmpty ? entry.code : name;
          if (nameOf(parsed.name) == nameOf(current.name) &&
              const MapEquality<String, String>()
                  .equals(parsed.table, current.table)) {
            continue;
          }
        }
        updated.add(await _import(entry, bytes));
      } catch (e) {
        Log.w("更新翻译失败：${entry.code} $e");
        failed[entry.name] = "$e";
      }
    }
    return TranslationCheckResult(updated, failed);
  }
}
