import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/script/live_source_models.dart';
import 'package:simple_live_core/src/script/live_source_overrides.dart';
import 'package:simple_live_core/src/script/prelude.dart';
import 'package:simple_live_core/src/script/script_engine.dart';
import 'package:simple_live_core/src/scripts/crypto_js.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// App 支持的脚本接口版本（同 LiveSourceManager.apiVersion）
const int kLiveSourceApiVersion = 1;

/// 接口 v1 之后加的可选功能，脚本里 App.features 读到（旧版 App 没有这个字段）：
/// - emotes：chat 消息的 emotes / sticker 显示为图片
/// - login：login 字段 + account()，App 里可以登录、退出
/// - hlsFix：playUrls 返回 hlsFix 时经本机中转修正 HLS 列表
/// - history：chat 消息带 history: true 时只进聊天区，不上视频弹幕（进直播间时补发的之前的聊天）
/// - hlsRewrite：hlsFix 含 "rewrite" 时，中转每次取到列表后调用脚本的 hls.rewrite(text, info)
/// - settings：settings 字段声明的设置项显示在源的详情页里，脚本用 Settings.get(key) 读
/// - hash：Hash.md5 / sha1 / sha256 / sha512 / hmac（在 App 里算，比 CryptoJS 快）
/// - overrides：overrides = "bilibili" 之类的脚本替换内置平台的一部分功能（§9），可选 useAccount
const List<String> kLiveSourceFeatures = [
  "emotes",
  "login",
  "hlsFix",
  "history",
  "hlsRewrite",
  "settings",
  "hash",
  "overrides",
];

final RegExp kLiveSourceKeyPattern = RegExp(r'^[a-z0-9_]+$');
final RegExp _versionPattern = RegExp(
  r'^\d+(\.\d+){0,3}([-+][0-9A-Za-z.+\-]*)?$',
);
final RegExp _domainPattern = RegExp(
  r'^(\*\.)?([a-z0-9]([a-z0-9\-]*[a-z0-9])?)(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)*$',
);
final RegExp _settingKeyPattern = RegExp(r'^[A-Za-z0-9_.\-]{1,64}$');
final RegExp _classPattern = RegExp(
  r'\bclass\s+([A-Za-z_$][\w$]*)\s+extends\s+LiveSource\b',
);

/// 从脚本里读出的全部信息
class LiveSourceMeta {
  final String className;
  final String key;
  final String name;
  final String version;
  final int apiVersion;
  final String? url;
  final String? icon;
  final String? description;
  final List<String> domains;
  final List<String> links;

  /// 脚本定义了的方法
  final Set<String> methods;

  /// danmaku.start 是否存在
  final bool danmaku;

  /// 网页登录（脚本的 login 字段），没有时为 null
  final LiveSourceLogin? login;

  /// hls.rewrite 是否存在
  final bool hlsRewrite;

  /// 设置项（settings 字段）
  final List<LiveSourceSetting> settings;

  /// 替换的内置平台 id（overrides 字段），普通直播源为 null
  final String? overrides;

  /// 用内置平台在 App 里登录的帐号（useAccount 字段，只能和 overrides 一起用）
  final bool useAccount;

  const LiveSourceMeta({
    required this.className,
    required this.key,
    required this.name,
    required this.version,
    required this.apiVersion,
    required this.domains,
    required this.links,
    required this.methods,
    required this.danmaku,
    this.login,
    this.hlsRewrite = false,
    this.settings = const [],
    this.overrides,
    this.useAccount = false,
    this.url,
    this.icon,
    this.description,
  });

  Set<String> get capabilities => {
    ...methods,
    if (danmaku) "danmaku",
    if (login != null) "login",
    if (hlsRewrite) "hlsRewrite",
    if (settings.isNotEmpty) "settings",
    if (overrides != null) "overrides",
    if (overrides != null && useAccount) "useAccount",
  };

  LiveSourceInfo toInfo(String file) => LiveSourceInfo(
    key: key,
    name: name,
    version: version,
    apiVersion: apiVersion,
    file: file,
    url: url,
    icon: icon,
    description: description,
    domains: domains,
    links: links,
    capabilities: capabilities,
    login: login,
    settings: settings,
    overrides: overrides,
    useAccount: overrides != null && useAccount,
  );
}

String liveSourcePlatformName() {
  if (Platform.isAndroid) return "android";
  if (Platform.isIOS) return "ios";
  if (Platform.isWindows) return "windows";
  if (Platform.isMacOS) return "macos";
  if (Platform.isLinux) return "linux";
  return Platform.operatingSystem;
}

/// 在引擎里装好运行环境（全局对象、CryptoJS、App 信息）
void prepareLiveSourceEngine(
  ScriptEngine engine, {
  String appVersion = "",
  String? platform,
}) {
  engine.eval(kLiveSourcePrelude, filename: "prelude.js");
  engine.eval(kCryptoJs, filename: "crypto-js.js");
  engine.eval(kLiveSourcePreludeAfterCrypto, filename: "prelude2.js");
  var random = Random.secure();
  engine.call("__dispatch", [
    jsonEncode({
      "t": "setup",
      "version": appVersion,
      "platform": platform ?? liveSourcePlatformName(),
      "apiVersion": kLiveSourceApiVersion,
      "features": kLiveSourceFeatures,
      "seed": List.generate(4, (_) => random.nextInt(1 << 32)),
    }),
  ]);
  engine.runJobs();
}

/// 把引擎异常整理成给作者看的中文说明
String describeScriptError(ScriptEngineException e, {String prefix = ""}) {
  var message = e.message;
  if (message.startsWith("SyntaxError")) {
    message =
        "脚本语法错误：{replaceFirst}".tf({"replaceFirst": message.substring("SyntaxError".length).replaceFirst(RegExp(r'^:\s*'), '')});
  }
  var location = _firstLocation(e.stack);
  if (location != null && !e.interrupted) {
    message = "$message（$location）";
  }
  return "$prefix$message";
}

String? _firstLocation(String? stack) {
  if (stack == null) return null;
  for (var line in const LineSplitter().convert(stack)) {
    var text = line.trim();
    if (!text.startsWith("at ")) continue;
    var m =
        RegExp(r'\(([^()]*:\d+(:\d+)?)\)').firstMatch(text) ??
        RegExp(r'at\s+([^\s()]+:\d+(:\d+)?)').firstMatch(text);
    if (m != null &&
        !m.group(1)!.startsWith("prelude") &&
        !m.group(1)!.startsWith("crypto-js")) {
      return m.group(1);
    }
  }
  return null;
}

/// 在 [engine] 里执行脚本并读出元数据；[create] 时把实例设为当前源（运行时用）
LiveSourceMeta loadLiveSourceScript(
  ScriptEngine engine,
  String code, {
  String filename = "source.live.js",
  bool create = false,
  int maxApiVersion = kLiveSourceApiVersion,
}) {
  try {
    engine.eval(code, filename: filename);
  } on ScriptEngineException catch (e) {
    throw CoreError(describeScriptError(e, prefix: "加载脚本失败：".t));
  }
  var names = <String>[];
  for (var m in _classPattern.allMatches(code)) {
    var name = m.group(1)!;
    if (!names.contains(name)) names.add(name);
  }
  if (names.isEmpty) {
    throw CoreError("没有找到继承 LiveSource 的类（class Xxx extends LiveSource）".t);
  }
  String? text;
  try {
    text = engine.call("__inspect", [jsonEncode(names), create ? "1" : "0"]);
    engine.runJobs();
  } on ScriptEngineException catch (e) {
    throw CoreError(describeScriptError(e, prefix: "创建直播源实例失败：".t));
  }
  var raw = jsonDecode(text ?? "{}") as Map<String, dynamic>;
  if (raw["error"] != null) {
    throw CoreError(raw["error"].toString());
  }
  return _validate(raw, maxApiVersion);
}

/// 读取并校验脚本（短暂使用一个引擎，不会发出网络请求）
LiveSourceMeta parseLiveSourceScript(
  String code, {
  String filename = "source.live.js",
  String appVersion = "",
  int maxApiVersion = kLiveSourceApiVersion,
}) {
  var engine = ScriptEngine(
    memoryLimit: 32 * 1024 * 1024,
    sliceTimeout: const Duration(seconds: 5),
  );
  try {
    prepareLiveSourceEngine(engine, appVersion: appVersion);
    return loadLiveSourceScript(
      engine,
      code,
      filename: filename,
      maxApiVersion: maxApiVersion,
    );
  } finally {
    engine.dispose();
  }
}

LiveSourceMeta _validate(Map<String, dynamic> raw, int maxApiVersion) {
  String? optionalString(String field) {
    var v = raw[field];
    if (v == null) return null;
    if (v is! String) {
      throw CoreError("{field} 必须是字符串".tf({"field": field}));
    }
    return v.trim().isEmpty ? null : v.trim();
  }

  String requiredString(String field) {
    var v = optionalString(field);
    if (v == null) {
      throw CoreError("缺少必填字段 {field}".tf({"field": field}));
    }
    return v;
  }

  List<String> stringList(String field) {
    var v = raw[field];
    if (v == null) return const [];
    if (v is! List || v.any((e) => e is! String)) {
      throw CoreError("{field} 必须是字符串数组".tf({"field": field}));
    }
    return v.cast<String>().toList();
  }

  var key = requiredString("key");
  if (!kLiveSourceKeyPattern.hasMatch(key) || key.length > 64) {
    throw CoreError("key 只能包含小写字母、数字和下划线：{key}".tf({"key": key}));
  }
  var name = requiredString("name");
  var version = requiredString("version");
  if (!_versionPattern.hasMatch(version)) {
    throw CoreError("version 不是有效的版本号（如 1.0.0）：{version}".tf({"version": version}));
  }
  var api = raw["apiVersion"] ?? 1;
  if (api is! num || api != api.toInt() || api < 1) {
    throw CoreError("apiVersion 必须是正整数".t);
  }
  var apiVersion = api.toInt();
  if (apiVersion > maxApiVersion) {
    throw CoreError("脚本需要更新的 App（脚本接口版本 {apiVersion}，当前 App 支持 {maxApiVersion}）".tf({"apiVersion": apiVersion, "maxApiVersion": maxApiVersion}));
  }
  var url = optionalString("url");
  if (url != null) {
    var uri = Uri.tryParse(url);
    if (uri == null || !const ["http", "https", "file"].contains(uri.scheme)) {
      throw CoreError("url 必须是 http(s) 或 file 地址：{url}".tf({"url": url}));
    }
  }
  var icon = optionalString("icon");
  var description = optionalString("description");
  var domains = <String>[];
  for (var d in stringList("domains")) {
    var domain = d.trim().toLowerCase();
    if (!_domainPattern.hasMatch(domain)) {
      throw CoreError("domains 里的域名格式不对：{d}（写成 example.com 或 *.example.com）".tf({"d": d}));
    }
    domains.add(domain);
  }
  var links = stringList("links");
  for (var link in links) {
    try {
      RegExp(link);
    } catch (e) {
      throw CoreError("links 里的正则无效：{link}".tf({"link": link}));
    }
  }
  var methods = ((raw["methods"] as List?) ?? const []).cast<String>().toSet();
  var login = _validateLogin(raw["login"]);
  var danmaku = raw["danmaku"] == true;
  var (overrides, useAccount) = _validateOverrides(
    raw,
    methods: methods,
    danmaku: danmaku,
    login: login,
  );
  return LiveSourceMeta(
    className: raw["className"].toString(),
    key: key,
    name: name,
    version: version,
    apiVersion: apiVersion,
    url: url,
    icon: icon,
    description: description,
    domains: domains,
    links: links,
    methods: methods,
    danmaku: danmaku,
    login: login,
    hlsRewrite: raw["hlsRewrite"] == true,
    settings: validateLiveSourceSettings(raw["settings"]),
    overrides: overrides,
    useAccount: useAccount,
  );
}

/// overrides = "<内置平台 id>"、useAccount = true（§9）。修正只能替换 LiveSite 的函数：
/// 不能有 login、account()（这一版不替换内置平台的登录）；
/// 替换 qualities 时也要替换 playUrls（清晰度的 data 只有脚本自己认识）
(String?, bool) _validateOverrides(
  Map<String, dynamic> raw, {
  required Set<String> methods,
  required bool danmaku,
  required LiveSourceLogin? login,
}) {
  var target = raw["overrides"];
  var useAccount = raw["useAccount"];
  if (useAccount != null && useAccount is! bool) {
    throw CoreError("useAccount 必须是 true 或 false".t);
  }
  if (target == null) {
    if (useAccount == true) {
      throw CoreError("useAccount 只能和 overrides 一起用（替换内置平台时用 App 里登录的帐号）".t);
    }
    return (null, false);
  }
  if (target is! String || !kBuiltInSiteNames.containsKey(target.trim())) {
    throw CoreError(
      "overrides 必须是内置平台的 id 之一：{keys}".tf({"keys": kBuiltInSiteNames.keys.join("、".t)}),
    );
  }
  var id = target.trim();
  if (login != null || methods.contains("account")) {
    throw CoreError("替换内置平台的直播源不能有 login、account()（这一版不替换内置平台的登录）".t);
  }
  var functions = {
    for (var f in kLiveSourceOverridableFunctions)
      if (f == "danmaku" ? danmaku : methods.contains(f)) f,
  };
  if (functions.isEmpty) {
    throw CoreError(
      "overrides 的脚本至少要实现一个可以替换的函数：{kLiveSourceOverridableFunctions}".tf({"kLiveSourceOverridableFunctions": kLiveSourceOverridableFunctions.join("、".t)}),
    );
  }
  if (functions.contains("qualities") && !functions.contains("playUrls")) {
    throw CoreError("替换 qualities 时也要替换 playUrls（清晰度的 data 只有脚本自己认识）".t);
  }
  if (useAccount == true && !kBuiltInAccountHosts.containsKey(id)) {
    throw CoreError("{builtInSiteName} 在 App 里没有登录，不能用 useAccount".tf({"builtInSiteName": builtInSiteName(id)}));
  }
  return (id, useAccount == true);
}

/// settings = [{ key, type: "switch" | "text" | "number" | "select", label, default?, description?,
/// options?（select：[{ value, label }] 或值的数组）, min?, max?, placeholder? }]，最多 50 项
List<LiveSourceSetting> validateLiveSourceSettings(dynamic v) {
  if (v == null) return const [];
  if (v is! List) {
    throw CoreError("settings 必须是数组：[{ key, type, label, default }]".t);
  }
  if (v.length > 50) throw CoreError("settings 最多 50 项".t);
  var keys = <String>{};
  var out = <LiveSourceSetting>[];
  for (var item in v) {
    if (item is! Map) {
      throw CoreError("settings 的每一项必须是对象 { key, type, label, default }".t);
    }
    String text(String field) {
      var s = item[field] == null ? "" : item[field].toString().trim();
      return s.length > 200 ? s.substring(0, 200) : s;
    }

    var key = text("key");
    if (!_settingKeyPattern.hasMatch(key)) {
      throw CoreError("settings 的 key 只能是字母、数字和 _ . -（最多 64 个字符）：{key}".tf({"key": key}));
    }
    if (!keys.add(key)) throw CoreError("settings 的 key 重复：{key}".tf({"key": key}));
    var type = text("type");
    if (!LiveSourceSetting.types.contains(type)) {
      throw CoreError("settings.{key} 的 type 必须是 switch、text、number、select 之一".tf({"key": key}));
    }
    num? number(String field) {
      var n = item[field];
      if (n == null) return null;
      if (n is! num || n.isNaN || n.isInfinite) {
        throw CoreError("settings.{key} 的 {field} 必须是数字".tf({"key": key, "field": field}));
      }
      return n;
    }

    var options = <LiveSourceSettingOption>[];
    if (type == "select") {
      var list = item["options"];
      if (list is! List || list.isEmpty || list.length > 100) {
        throw CoreError("settings.{key} 是 select，options 必须是 1～100 个选项".tf({"key": key}));
      }
      for (var o in list) {
        var value = o is Map ? o["value"] : o;
        if (value is! String && value is! num && value is! bool) {
          throw CoreError("settings.{key} 的选项值必须是字符串、数字或 true/false".tf({"key": key}));
        }
        var label = o is Map && o["label"] != null
            ? o["label"].toString()
            : "$value";
        options.add(LiveSourceSettingOption(value, label));
      }
    }
    var description = text("description");
    var placeholder = text("placeholder");
    var setting = LiveSourceSetting(
      key: key,
      type: type,
      label: text("label").isEmpty ? key : text("label"),
      description: description.isEmpty ? null : description,
      defaultValue: null,
      options: options,
      min: number("min"),
      max: number("max"),
      placeholder: placeholder.isEmpty ? null : placeholder,
    );
    var fallback = switch (type) {
      "switch" => false,
      "number" => setting.min ?? 0,
      "select" => options.first.value,
      _ => "",
    };
    out.add(
      LiveSourceSetting(
        key: key,
        type: type,
        label: setting.label,
        description: setting.description,
        defaultValue: setting.coerce(item["default"]) ?? fallback,
        options: options,
        min: setting.min,
        max: setting.max,
        placeholder: setting.placeholder,
      ),
    );
  }
  return out;
}

/// 设置项的当前值：[stored] 里合法的值，其余为默认值
Map<String, dynamic> liveSourceSettingValues(
  List<LiveSourceSetting> settings,
  Map<String, dynamic> stored,
) => {for (var s in settings) s.key: s.valueIn(stored)};

/// login = { url, cookieUrl?, cookieNames, tip? }：url / cookieUrl 为 https，cookieNames 至少一个
LiveSourceLogin? _validateLogin(dynamic v) {
  if (v == null) return null;
  if (v is! Map) throw CoreError("login 必须是对象 { url, cookieNames }".t);
  String text(String field) =>
      v[field] == null ? "" : v[field].toString().trim();
  var url = text("url");
  var cookieUrl = text("cookieUrl");
  if (cookieUrl.isEmpty) cookieUrl = url;
  for (var u in [url, cookieUrl]) {
    var uri = Uri.tryParse(u);
    if (uri == null || uri.scheme != "https" || uri.host.isEmpty) {
      throw CoreError("login.url / login.cookieUrl 必须是 https 地址：{u}".tf({"u": u}));
    }
  }
  var names = v["cookieNames"];
  if (names is String) names = [names];
  if (names is! List ||
      names.isEmpty ||
      names.any((e) => e is! String || e.trim().isEmpty)) {
    throw CoreError("login.cookieNames 必须是非空的字符串数组（登录后才有的 Cookie 名称）".t);
  }
  var tip = text("tip");
  return LiveSourceLogin(
    url: url,
    cookieUrl: cookieUrl,
    cookieNames: names.map((e) => e.toString().trim()).toList(),
    tip: tip.isEmpty ? null : tip,
  );
}

/// 域名白名单匹配："a.com" 只匹配 a.com，"*.a.com" 匹配 a.com 的任意子域名
bool liveSourceDomainAllowed(List<String> domains, String host) {
  var h = host.toLowerCase();
  if (h.endsWith(".")) h = h.substring(0, h.length - 1);
  if (h.startsWith("[") && h.endsWith("]")) h = h.substring(1, h.length - 1);
  for (var d in domains) {
    if (d.startsWith("*.")) {
      if (h.endsWith(d.substring(1))) return true;
    } else if (h == d) {
      return true;
    }
  }
  return false;
}
