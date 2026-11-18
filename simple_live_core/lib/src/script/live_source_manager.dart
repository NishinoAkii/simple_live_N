import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/script/live_source_models.dart';
import 'package:simple_live_core/src/script/live_source_overrides.dart';
import 'package:simple_live_core/src/script/live_source_permissions.dart';
import 'package:simple_live_core/src/script/live_source_signing.dart';
import 'package:simple_live_core/src/script/overridable_live_site.dart';
import 'package:simple_live_core/src/script/script_live_site.dart';
import 'package:simple_live_core/src/script/script_metadata.dart';
import 'package:simple_live_core/src/common/core_text.dart';

class _Subscription {
  final String url;
  String? name;

  /// 第一次见到时记下的发布者公钥（TOFU），没有签名的订阅为 null
  String? publicKey;

  /// 订阅的公钥和记下的不一样时的说明（不保存，每次读取订阅时重新判断）
  String? keyError;

  _Subscription(this.url, [this.name, this.publicKey]);
}

/// 已安装的直播源脚本和订阅，见 doc/live_source_api.md
///
/// 目录结构：
/// - `sources/<key>.live.js`：脚本；`sources/<key>.origin`：安装来源（没有 url 字段时用来更新）；
///   `sources/<key>.trust`：签名安装的源记下的发布者公钥（之后的更新必须是同一把公钥签的）
/// - `subscriptions.json`：订阅地址、名称、发布者公钥、上次检查更新的时间
/// - `overrides.json`：内置平台修正（§9）的开关、“失败时改用内置”、“允许未签名的修正”
/// - `data/<key>/`：各源的 cookies.json、storage.json、settings.json
///
/// 加载脚本只在后台 isolate 的临时引擎里读取元数据，不发网络请求。
///
/// 安装、更新分两步（§8）：`prepare…` 下载、解析、校验签名，得到 [LiveSourcePlan]（新版本的域名、
/// 敏感功能和与已安装版本的差别）；[applyPlan] 写进去。更新扩大了权限（新域名、新的敏感功能、
/// 登录地址换了主机）或去掉了签名时，没有确认（`confirmed: true`）就抛 [LiveSourceConfirmationRequired]。
class LiveSourceManager {
  /// App 支持的脚本接口版本，脚本的 apiVersion 大于它时不加载
  static const int apiVersion = kLiveSourceApiVersion;

  /// 保存脚本、订阅列表和各源数据的目录
  final String directory;

  /// App 版本，脚本里 App.version 读到的值
  final String appVersion;

  /// 下载前先交给 App 的地址（如要带登录从 GitHub 接口读的文件）。
  /// 返回 null 时照常下载。只换读文件的方式，签名校验、安装流程不变
  final Future<List<int>?> Function(String url)? fetchOverride;

  LiveSourceManager({
    required this.directory,
    required this.appVersion,
    this.fetchOverride,
  });

  final _changes = StreamController<void>.broadcast();

  /// 安装、更新、删除、订阅变化后触发
  Stream<void> get changes => _changes.stream;

  final Map<String, ScriptLiveSite> _sites = {};

  /// 各源的安装来源（脚本没写 url 时用它更新）
  final Map<String, String> _origins = {};

  /// 签名安装的源：key → 发布者公钥
  final Map<String, String> _trust = {};
  final Map<String, String> _loadErrors = {};
  final List<_Subscription> _subscriptions = [];

  /// 最近读到的订阅项：key → 订阅地址 → 项
  final Map<String, Map<String, LiveSourceIndexEntry>> _knownEntries = {};

  /// 修正的设置：key → (开关, 失败时改用内置)，没有时都是开
  final Map<String, ({bool enabled, bool fallback})> _overrideSettings = {};
  bool _allowUnsignedOverrides = false;
  DateTime? _lastCheck;
  bool _initialized = false;
  Future<void>? _initializing;

  /// 已安装且能加载的源
  List<ScriptLiveSite> get sites => List.unmodifiable(_sites.values);

  /// 按 key 找已安装的源
  ScriptLiveSite? site(String key) => _sites[key];

  /// 源的更新地址：脚本里的 url，没写时为安装来源（链接、订阅里的地址或本机文件）
  String? updateUrl(String key) {
    var url = _sites[key]?.info.url;
    return url != null && url.isNotEmpty ? url : _origins[key];
  }

  /// 签名安装的源记下的发布者公钥（Base64），没有签名时为 null
  String? publicKeyOf(String key) => _trust[key];

  /// 加载失败的脚本（文件名 → 原因），设置页里显示
  Map<String, String> get loadErrors => Map.unmodifiable(_loadErrors);

  /// 订阅地址
  List<String> get subscriptions =>
      List.unmodifiable(_subscriptions.map((e) => e.url));

  _Subscription? _subscription(String url) {
    for (var s in _subscriptions) {
      if (s.url == url) return s;
    }
    return null;
  }

  /// 订阅的名称（index.json 的 name，读取过才有）
  String? subscriptionName(String url) => _subscription(url)?.name;

  /// 订阅的发布者公钥（添加时记下的），没有签名的订阅为 null
  String? subscriptionPublicKey(String url) => _subscription(url)?.publicKey;

  /// 订阅的公钥变了、去掉了签名时的说明（这时不能从它安装、更新），没有问题时为 null
  String? subscriptionKeyError(String url) => _subscription(url)?.keyError;

  /// 上次 [checkUpdates] 的时间（App 每天检查一次）
  DateTime? get lastUpdateCheck => _lastCheck;

  String get _sep => Platform.pathSeparator;
  String get _sourcesDir => "$directory${_sep}sources";
  File _scriptFile(String key) => File("$_sourcesDir$_sep$key.live.js");
  File _originFile(String key) => File("$_sourcesDir$_sep$key.origin");
  File _trustFile(String key) => File("$_sourcesDir$_sep$key.trust");
  File get _subscriptionsFile => File("$directory${_sep}subscriptions.json");
  File get _overridesFile => File("$directory${_sep}overrides.json");
  String _dataDir(String key) => "$directory${_sep}data$_sep$key";

  /// 加载已安装的源（App 启动时调用一次）
  Future<void> init() {
    if (_initialized) return Future.value();
    return _initializing ??= _init().whenComplete(() => _initializing = null);
  }

  Future<void> _init() async {
    await Directory(_sourcesDir).create(recursive: true);
    await _loadSubscriptions();
    await _loadOverrideSettings();
    var files =
        Directory(_sourcesDir)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith(".live.js"))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    var inputs = <(String, String)>[];
    for (var f in files) {
      try {
        inputs.add((f.path, await f.readAsString()));
      } catch (e) {
        _loadErrors[_baseName(f.path)] = "读取文件失败：{e}".tf({"e": e});
      }
    }
    var version = appVersion;
    var results = inputs.isEmpty
        ? const <Object>[]
        : await _runParse(inputs, version);
    for (var i = 0; i < inputs.length; i++) {
      var path = inputs[i].$1;
      var result = results[i];
      if (result is! LiveSourceMeta) {
        _loadErrors[_baseName(path)] = result.toString();
        continue;
      }
      var existing = _sites[result.key];
      if (existing != null) {
        _loadErrors[_baseName(path)] =
            "key “{key}”和 {baseName} 重复".tf({"key": result.key, "baseName": _baseName(existing.info.file)});
        continue;
      }
      _sites[result.key] = _createSite(result.toInfo(path));
      try {
        var origin = _originFile(result.key);
        if (await origin.exists()) {
          _origins[result.key] = (await origin.readAsString()).trim();
        }
        var trust = _trustFile(result.key);
        if (await trust.exists()) {
          var key = jsonDecode(await trust.readAsString())["publicKey"];
          if (key is String && liveSourceDecodePublicKey(key) != null) {
            _trust[result.key] = key;
          }
        }
      } catch (_) {}
    }
    _initialized = true;
    _notify();
  }

  ScriptLiveSite _createSite(LiveSourceInfo info) => ScriptLiveSite(
    info,
    dataDirectory: _dataDir(info.key),
    appVersion: appVersion,
  );

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

  // ---------------------------------------------------------------------
  // 安装、更新（两步：prepare → applyPlan）
  // ---------------------------------------------------------------------

  /// 从 https:// 或 file:/// 地址安装（本机测试也可以用 http://127.0.0.1）。
  /// 新装直接安装；覆盖已安装的源且权限扩大时，[allowExpanded] 为 false 就抛
  /// [LiveSourceConfirmationRequired]（App 应该先用 [prepareInstallFromUrl] 给用户看）
  Future<LiveSourceInfo> installFromUrl(
    String url, {
    bool allowExpanded = false,
  }) async {
    var plan = await prepareInstallFromUrl(url);
    return applyPlan(plan, confirmed: allowExpanded || !plan.isUpdate);
  }

  Future<LiveSourceInfo> installFromFile(
    String path, {
    bool allowExpanded = false,
  }) async {
    var plan = await prepareInstallFromFile(path);
    return applyPlan(plan, confirmed: allowExpanded || !plan.isUpdate);
  }

  /// 下载、解析、校验签名（订阅有签名时），不安装
  Future<LiveSourcePlan> prepareInstallFromUrl(String url) async {
    await init();
    url = url.trim();
    var entry = _entryForUrl(url);
    if (entry?.blockedReason != null) {
      throw CoreError("${entry!.name}：${entry.blockedReason}");
    }
    var bytes = await _downloadBytes(url);
    return _plan(
      bytes,
      origin: url,
      filename: _baseName(Uri.tryParse(url)?.path ?? url),
      entry: entry,
    );
  }

  Future<LiveSourcePlan> prepareInstallFromFile(String path) async {
    await init();
    var file = File(path);
    List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      throw CoreError("读取文件失败：{path}".tf({"path": path}));
    }
    return _plan(
      bytes,
      origin: Uri.file(file.absolute.path).toString(),
      filename: _baseName(path),
    );
  }

  /// 准备更新：订阅里有更新版本时从订阅的地址下载，否则从源的更新地址、安装来源重新下载
  Future<LiveSourcePlan> prepareUpdate(String key) async {
    await init();
    var site = _sites[key];
    if (site == null) {
      throw CoreError("没有安装 {key}".tf({"key": key}));
    }
    var pinned = _trust[key];
    var entry = _bestEntry(key, newerThan: site.info.version, pinned: pinned);
    if (entry?.blockedReason != null) {
      throw CoreError("${site.name}：${entry!.blockedReason}");
    }
    var url = entry?.url ?? site.info.url;
    if (url == null) {
      var origin = _originFile(key);
      if (await origin.exists()) {
        url = (await origin.readAsString()).trim();
      }
    }
    if (url == null || url.isEmpty) {
      throw CoreError("{name} 没有更新地址".tf({"name": site.name}));
    }
    entry ??= _entryForUrl(url);
    if (entry?.blockedReason != null) {
      throw CoreError("${site.name}：${entry!.blockedReason}");
    }
    var bytes = await _downloadBytes(url);
    return _plan(
      bytes,
      origin: url,
      filename: "$key.live.js",
      entry: entry,
      expectKey: key,
      update: true,
    );
  }

  /// 更新（[prepareUpdate] + [applyPlan]）；权限扩大或去掉签名时，[allowExpanded] 为 false
  /// 就抛 [LiveSourceConfirmationRequired]，可以用其中的 plan 确认后再 [applyPlan]
  Future<LiveSourceInfo> update(
    String key, {
    bool allowExpanded = false,
  }) async {
    var plan = await prepareUpdate(key);
    return applyPlan(plan, confirmed: allowExpanded);
  }

  Future<LiveSourcePlan> _plan(
    List<int> bytes, {
    required String origin,
    String? filename,
    LiveSourceIndexEntry? entry,
    String? expectKey,
    bool update = false,
  }) async {
    var code = utf8.decode(bytes, allowMalformed: true);
    var meta = await _parseInBackground(code, filename ?? "source.live.js");
    if (expectKey != null && meta.key != expectKey) {
      throw CoreError("下载到的脚本 key 是 {key}，不是 {expectKey}".tf({"key": meta.key, "expectKey": expectKey}));
    }
    if (entry != null && entry.key != meta.key) {
      throw CoreError("订阅里写的是 {key}，下载到的脚本 key 是 {key2}".tf({"key": entry.key, "key2": meta.key}));
    }
    var current = _sites[meta.key]?.info;
    var pinned = current == null ? null : _trust[meta.key];
    String? publicKey;

    if (entry?.publicKey != null) {
      await _verify(
        meta.name,
        origin,
        bytes,
        entry!.publicKey!,
        entry.signature,
      );
      publicKey = entry.publicKey;
    } else if (update && pinned != null) {
      // 签名安装的源从不在签名订阅里的地址更新：要有同一把公钥签的 <url>.sig
      await _verify(meta.name, origin, bytes, pinned, null);
      publicKey = pinned;
    }
    if (update && pinned != null) {
      if (publicKey != pinned) {
        throw CoreError(
          ("{name} 是按发布者签名安装的（公钥指纹 {liveSourceKeyFingerprint}），"
          "新版本的公钥是 {liveSourceKeyFingerprint2}，没有更新。"
          "确认发布者换了密钥时，删除这个源后重新安装").tf({"name": meta.name, "liveSourceKeyFingerprint": liveSourceKeyFingerprint(pinned), "liveSourceKeyFingerprint2": liveSourceKeyFingerprint(publicKey!)}),
        );
      }
      if (compareLiveSourceVersion(meta.version, current!.version) < 0) {
        throw CoreError(
          "{name} 下载到的版本 {version} 比已安装的 {version2} 旧，没有更新".tf({"name": meta.name, "version": meta.version, "version2": current.version}),
        );
      }
    }
    // 替换内置平台的修正只从有签名的来源装（开发者选项可以放开）
    if (meta.overrides != null &&
        publicKey == null &&
        !_allowUnsignedOverrides) {
      throw CoreError(
        ("{name} 会替换内置的 {builtInSiteName}，"
        "只能从有签名的订阅安装。自己写的、测试用的修正：在直播源设置的开发者选项里"
        "打开“允许未签名的内置平台修正（不安全）”").tf({"name": meta.name, "builtInSiteName": builtInSiteName(meta.overrides!)}),
      );
    }
    return LiveSourcePlan(
      next: meta.toInfo(_scriptFile(meta.key).path),
      current: current,
      publicKey: publicKey,
      currentPublicKey: pinned,
      subscription: entry?.subscription,
      origin: origin,
      code: code,
    );
  }

  /// 校验签名：[signature] 为空时读 `<url>.sig`
  Future<void> _verify(
    String name,
    String url,
    List<int> bytes,
    String publicKey,
    String? signature,
  ) async {
    var sig = signature ?? await _fetchSignature(url);
    if (sig == null || sig.isEmpty) {
      throw CoreError("{name} 没有签名（订阅要求签名，index.json 和 .sig 文件里都没有），没有安装".tf({"name": name}));
    }
    if (!await _runVerify(publicKey, bytes, sig)) {
      throw CoreError(
        ("{name} 的签名校验失败：脚本被改过，或者不是这个订阅的发布者签的"
        "（公钥指纹 {liveSourceKeyFingerprint}），没有安装").tf({"name": name, "liveSourceKeyFingerprint": liveSourceKeyFingerprint(publicKey)}),
      );
    }
  }

  Future<String?> _fetchSignature(String url) async {
    try {
      var uri = _toUri(url);
      return (await _download(
        uri.replace(path: "${uri.path}.sig").toString(),
      )).trim();
    } catch (_) {
      return null;
    }
  }

  // 静态方法里创建闭包，避免把 this 带进后台 isolate
  static Future<bool> _runVerify(String key, List<int> bytes, String sig) =>
      Isolate.run(() => liveSourceVerify(key, bytes, sig));

  /// 安装准备好的 [plan]。[LiveSourcePlan.needsConfirmation] 为 true 而 [confirmed] 为 false 时
  /// 抛 [LiveSourceConfirmationRequired]，什么也不改
  Future<LiveSourceInfo> applyPlan(
    LiveSourcePlan plan, {
    bool confirmed = false,
  }) async {
    await init();
    if (plan.needsConfirmation && !confirmed) {
      throw LiveSourceConfirmationRequired(plan);
    }
    var key = plan.next.key;
    if (!identical(_sites[key]?.info, plan.current)) {
      throw CoreError("{name} 在确认期间有了变化，请重新操作".tf({"name": plan.next.name}));
    }
    await Directory(_sourcesDir).create(recursive: true);
    var file = _scriptFile(key);
    await file.writeAsString(plan.code, flush: true);
    await _originFile(key).writeAsString(plan.origin, flush: true);
    var trust = _trustFile(key);
    if (plan.publicKey != null) {
      await trust.writeAsString(
        jsonEncode({
          "publicKey": plan.publicKey,
          if (plan.subscription != null) "subscription": plan.subscription,
        }),
        flush: true,
      );
      _trust[key] = plan.publicKey!;
    } else {
      _trust.remove(key);
      try {
        if (await trust.exists()) await trust.delete();
      } catch (_) {}
    }
    var old = _sites.remove(key);
    if (old != null) {
      await old.dispose();
      // 手动放进来的同 key 文件（文件名不同）
      if (File(old.info.file).absolute.path != file.absolute.path) {
        try {
          await File(old.info.file).delete();
        } catch (_) {}
      }
    }
    _loadErrors.remove(_baseName(file.path));
    _origins[key] = plan.origin;
    var site = _createSite(plan.next);
    _sites[key] = site;
    _notify();
    return site.info;
  }

  /// 删除源（脚本和它的 Cookie、Storage、设置）
  Future<void> remove(String key) async {
    await init();
    var site = _sites.remove(key);
    _origins.remove(key);
    _trust.remove(key);
    await site?.dispose();
    var files = <File>[
      _scriptFile(key),
      _originFile(key),
      _trustFile(key),
      if (site != null) File(site.info.file),
    ];
    for (var f in files) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    _loadErrors.remove("$key.live.js");
    try {
      var data = Directory(_dataDir(key));
      if (await data.exists()) await data.delete(recursive: true);
    } catch (_) {}
    if (_overrideSettings.remove(key) != null) await _saveOverrideSettings();
    _notify();
  }

  // ---------------------------------------------------------------------
  // 内置平台的修正（§9）
  // ---------------------------------------------------------------------

  /// 普通直播源（单独的平台）
  List<ScriptLiveSite> get platformSites =>
      List.unmodifiable(_sites.values.where((e) => !e.info.isOverride));

  /// 内置平台的修正（不显示成平台）
  List<ScriptLiveSite> get overrideSites =>
      List.unmodifiable(_sites.values.where((e) => e.info.isOverride));

  /// 开发者选项：允许没有签名的修正生效、安装（默认关；不安全）
  bool get allowUnsignedOverrides => _allowUnsignedOverrides;

  Future<void> setAllowUnsignedOverrides(bool value) async {
    await init();
    if (_allowUnsignedOverrides == value) return;
    _allowUnsignedOverrides = value;
    await _saveOverrideSettings();
    _notify();
  }

  /// 修正的开关（默认开）
  bool overrideEnabled(String key) => _overrideSettings[key]?.enabled ?? true;

  /// 失败时改用内置（默认开）
  bool overrideFallback(String key) => _overrideSettings[key]?.fallback ?? true;

  Future<void> setOverrideEnabled(String key, bool value) =>
      _setOverride(key, enabled: value);

  Future<void> setOverrideFallback(String key, bool value) =>
      _setOverride(key, fallback: value);

  Future<void> _setOverride(String key, {bool? enabled, bool? fallback}) async {
    await init();
    _overrideSettings[key] = (
      enabled: enabled ?? overrideEnabled(key),
      fallback: fallback ?? overrideFallback(key),
    );
    await _saveOverrideSettings();
    _notify();
  }

  /// 能生效：开着，而且是签名安装的（或者开发者选项允许未签名的）
  bool _overrideUsable(ScriptLiveSite site) =>
      overrideEnabled(site.info.key) &&
      (_trust.containsKey(site.info.key) || _allowUnsignedOverrides);

  /// 内置平台 [builtInId] 当前生效的修正：同一个平台有几个能生效的时用 key 排在前面的；没有时为 null
  LiveSourceOverrideBinding? activeOverride(String builtInId) {
    ScriptLiveSite? best;
    for (var site in _sites.values) {
      if (site.info.overrides != builtInId || !_overrideUsable(site)) continue;
      if (best == null || site.info.key.compareTo(best.info.key) < 0) {
        best = site;
      }
    }
    if (best == null) return null;
    return LiveSourceOverrideBinding(
      best,
      fallback: overrideFallback(best.info.key),
    );
  }

  /// 修正 [key] 现在的状态；不是修正时为 null
  LiveSourceOverrideStatus? overrideStatus(String key) {
    var site = _sites[key];
    var target = site?.info.overrides;
    if (site == null || target == null) return null;
    var name = builtInSiteName(target);
    if (!overrideEnabled(key)) {
      return LiveSourceOverrideStatus(false, "已关闭，{builtInText}".tf({"builtInText": _builtInText}));
    }
    if (!_trust.containsKey(key) && !_allowUnsignedOverrides) {
      return LiveSourceOverrideStatus(
        false,
        "没有签名，没有生效。自己写的修正可以在开发者选项里允许（不安全）".t,
      );
    }
    var active = activeOverride(target);
    if (active != null && active.site.info.key != key) {
      return LiveSourceOverrideStatus(
        false,
        "没有生效：{name} 已经在用“{name2}”（关掉它才会用这个）".tf({"name": name, "name2": active.info.name}),
      );
    }
    return LiveSourceOverrideStatus(true, "生效中：{name} 的这些功能由这个直播源处理".tf({"name": name}));
  }

  static String get _builtInText => "用的是 App 内置的代码".t;

  Future<void> _loadOverrideSettings() async {
    try {
      var f = _overridesFile;
      if (!await f.exists()) return;
      var json = jsonDecode(await f.readAsString());
      if (json is! Map) return;
      _allowUnsignedOverrides = json["allowUnsigned"] == true;
      var sources = json["sources"];
      if (sources is Map) {
        sources.forEach((k, v) {
          if (v is! Map) return;
          _overrideSettings[k.toString()] = (
            enabled: v["enabled"] != false,
            fallback: v["fallback"] != false,
          );
        });
      }
    } catch (e) {
      CoreLog.w("读取内置平台修正的设置失败：$e");
    }
  }

  Future<void> _saveOverrideSettings() async {
    try {
      await Directory(directory).create(recursive: true);
      await _overridesFile.writeAsString(
        const JsonEncoder.withIndent("  ").convert({
          "allowUnsigned": _allowUnsignedOverrides,
          "sources": {
            for (var e in _overrideSettings.entries)
              e.key: {"enabled": e.value.enabled, "fallback": e.value.fallback},
          },
        }),
        flush: true,
      );
    } catch (e) {
      CoreLog.w("保存内置平台修正的设置失败：$e");
    }
  }

  /// 删除加载失败的脚本文件（[loadErrors] 里的文件名）
  Future<void> removeFile(String fileName) async {
    var f = File("$_sourcesDir$_sep${_baseName(fileName)}");
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
    _loadErrors.remove(_baseName(fileName));
    _notify();
  }

  // ---------------------------------------------------------------------
  // 订阅
  // ---------------------------------------------------------------------

  /// 添加订阅；index.json 有 publicKey 时记下它（之后公钥变了就拒绝从这个订阅安装、更新）
  Future<void> addSubscription(String url) async {
    await init();
    url = url.trim();
    if (_subscriptions.any((e) => e.url == url)) return;
    var index = await _fetchIndex(url);
    _subscriptions.add(_Subscription(url, index.name, index.publicKey));
    if (index.publicKey != null) {
      CoreLog.i(
        "订阅 $url 有签名，记下公钥（指纹 ${liveSourceKeyFingerprint(index.publicKey!)}）",
      );
    }
    await _saveSubscriptions();
    _notify();
  }

  Future<void> removeSubscription(String url) async {
    await init();
    url = url.trim();
    _subscriptions.removeWhere((e) => e.url == url);
    for (var m in _knownEntries.values) {
      m.remove(url);
    }
    await _saveSubscriptions();
    _notify();
  }

  /// 读取订阅里的源列表（带已安装版本、签名状态）
  Future<List<LiveSourceIndexEntry>> fetchSubscription(String url) async {
    await init();
    var index = await _fetchIndex(url.trim());
    return index.entries;
  }

  /// 所有订阅里比已安装版本新的源；不在任何订阅里、但脚本写了 url 的源也会检查。
  /// 只检查，不安装；订阅的公钥变了的不算（订阅卡片上显示原因）
  Future<List<LiveSourceIndexEntry>> checkUpdates() async {
    await init();
    var covered = <String>{};
    for (var sub in List.of(_subscriptions)) {
      List<LiveSourceIndexEntry> entries;
      try {
        entries = (await _fetchIndex(sub.url)).entries;
      } catch (e) {
        CoreLog.w("检查订阅 ${sub.url} 失败：$e");
        continue;
      }
      for (var e in entries) {
        if (e.installed) covered.add(e.key);
      }
    }
    var updates = <LiveSourceIndexEntry>[];
    for (var site in _sites.values.toList()) {
      var info = site.info;
      var best = _bestEntry(
        info.key,
        newerThan: info.version,
        pinned: _trust[info.key],
      );
      if (best != null) {
        if (best.blockedReason == null) updates.add(best);
        continue;
      }
      if (covered.contains(info.key) || info.url == null) continue;
      try {
        var code = await _download(info.url!);
        var meta = await _parseInBackground(code, "${info.key}.live.js");
        if (meta.key == info.key &&
            compareLiveSourceVersion(meta.version, info.version) > 0) {
          var entry = LiveSourceIndexEntry(
            key: info.key,
            name: meta.name,
            version: meta.version,
            url: info.url!,
            subscription: "",
            description: meta.description,
            installedVersion: info.version,
          );
          _remember(entry);
          updates.add(entry);
        }
      } catch (e) {
        CoreLog.w("检查 ${info.name} 的更新失败：$e");
      }
    }
    _lastCheck = DateTime.now();
    await _saveSubscriptions();
    return updates;
  }

  void _remember(LiveSourceIndexEntry e) {
    (_knownEntries[e.key] ??= {})[e.subscription] = e;
  }

  /// 订阅里 [key] 比 [newerThan] 新的版本里最高的；源是签名安装的（[pinned]）时优先用同一把公钥签的
  LiveSourceIndexEntry? _bestEntry(
    String key, {
    required String newerThan,
    String? pinned,
  }) {
    var candidates = [
      for (var e in (_knownEntries[key] ?? const {}).values)
        if (compareLiveSourceVersion(e.version, newerThan) > 0) e,
    ];
    if (pinned != null && candidates.any((e) => e.publicKey == pinned)) {
      candidates.removeWhere((e) => e.publicKey != pinned);
    }
    LiveSourceIndexEntry? best;
    for (var e in candidates) {
      if (best == null ||
          compareLiveSourceVersion(e.version, best.version) > 0) {
        best = e;
      }
    }
    return best;
  }

  /// 订阅里地址为 [url] 的项（从订阅安装时用它的签名）
  LiveSourceIndexEntry? _entryForUrl(String url) {
    LiveSourceIndexEntry? found;
    for (var m in _knownEntries.values) {
      for (var e in m.values) {
        if (e.url != url) continue;
        // 同一个地址出现在几个订阅里：优先有签名的
        if (found == null || (found.publicKey == null && e.publicKey != null)) {
          found = e;
        }
      }
    }
    return found;
  }

  /// 下载并解析 index.json
  Future<
    ({String? name, String? publicKey, List<LiveSourceIndexEntry> entries})
  >
  _fetchIndex(String url) async {
    var text = await _download(url);
    dynamic json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      throw CoreError("订阅不是有效的 JSON：{url}".tf({"url": url}));
    }
    if (json is! Map || json["sources"] is! List) {
      throw CoreError("${"订阅格式不对，要有 name 和 sources".t}${"：".t}$url");
    }
    String? indexKey;
    var rawKey = json["publicKey"];
    if (rawKey != null) {
      if (rawKey is! String || liveSourceDecodePublicKey(rawKey) == null) {
        throw CoreError("订阅的 publicKey 不是有效的 Ed25519 公钥（32 字节的 Base64）：{url}".tf({"url": url}));
      }
      indexKey = rawKey.trim();
    }
    var sub = _subscription(url);
    var pinned = sub == null ? indexKey : sub.publicKey;
    String? blocked;
    if (sub != null) {
      if (pinned == null && indexKey != null) {
        // 原来没签名的订阅开始签名：第一次见到时记下
        sub.publicKey = pinned = indexKey;
        CoreLog.i(
          "订阅 $url 开始签名，记下公钥（指纹 ${liveSourceKeyFingerprint(indexKey)}）",
        );
        await _saveSubscriptions();
      } else if (pinned != null && indexKey != pinned) {
        var was = liveSourceKeyFingerprint(pinned);
        blocked = indexKey == null
            ? ("订阅去掉了签名（添加时有签名，公钥指纹 {was}），已停止从这个订阅安装、更新。"
                  "确认没有问题时，删除订阅后重新添加").tf({"was": was})
            : ("订阅的签名公钥变了（添加时 {was}，现在 {liveSourceKeyFingerprint}），"
                  "已停止从这个订阅安装、更新。如果是发布者换了密钥，删除订阅后重新添加").tf({"was": was, "liveSourceKeyFingerprint": liveSourceKeyFingerprint(indexKey)});
      }
      sub.keyError = blocked;
    }
    var base = _toUri(url);
    var name = json["name"]?.toString();
    var entries = <LiveSourceIndexEntry>[];
    // 订阅里去掉的源不再提供更新
    for (var m in _knownEntries.values) {
      m.remove(url);
    }
    for (var item in json["sources"] as List) {
      if (item is! Map) continue;
      var key = item["key"]?.toString() ?? "";
      var entryUrl = item["url"]?.toString() ?? "";
      if (!kLiveSourceKeyPattern.hasMatch(key) || entryUrl.isEmpty) continue;
      String resolved;
      try {
        resolved = base.resolve(entryUrl).toString();
      } catch (_) {
        continue;
      }
      var sig = item["signature"] ?? item["sig"];
      var entry = LiveSourceIndexEntry(
        key: key,
        name: item["name"]?.toString() ?? key,
        version: item["version"]?.toString() ?? "0.0.0",
        url: resolved,
        subscription: url,
        description: item["description"]?.toString(),
        installedVersion: _sites[key]?.info.version,
        publicKey: pinned,
        signature: sig is String && sig.trim().isNotEmpty ? sig.trim() : null,
        blockedReason: blocked,
      );
      entries.add(entry);
      _remember(entry);
    }
    if (sub != null && name != null && sub.name != name) {
      sub.name = name;
      await _saveSubscriptions();
    }
    return (name: name, publicKey: indexKey, entries: entries);
  }

  Future<void> _loadSubscriptions() async {
    try {
      var f = _subscriptionsFile;
      if (!await f.exists()) return;
      var json = jsonDecode(await f.readAsString());
      if (json is! Map) return;
      _subscriptions.clear();
      for (var item in (json["subscriptions"] as List?) ?? const []) {
        if (item is String) {
          _subscriptions.add(_Subscription(item));
        } else if (item is Map && item["url"] != null) {
          var key = item["publicKey"]?.toString();
          _subscriptions.add(
            _Subscription(
              item["url"].toString(),
              item["name"]?.toString(),
              liveSourceDecodePublicKey(key) == null ? null : key,
            ),
          );
        }
      }
      var last = json["lastCheck"];
      if (last is int) _lastCheck = DateTime.fromMillisecondsSinceEpoch(last);
    } catch (e) {
      CoreLog.w("读取直播源订阅失败：$e");
    }
  }

  Future<void> _saveSubscriptions() async {
    try {
      await Directory(directory).create(recursive: true);
      await _subscriptionsFile.writeAsString(
        const JsonEncoder.withIndent("  ").convert({
          "subscriptions": [
            for (var s in _subscriptions)
              {
                "url": s.url,
                if (s.name != null) "name": s.name,
                if (s.publicKey != null) "publicKey": s.publicKey,
              },
          ],
          if (_lastCheck != null)
            "lastCheck": _lastCheck!.millisecondsSinceEpoch,
        }),
        flush: true,
      );
    } catch (e) {
      CoreLog.w("保存直播源订阅失败：$e");
    }
  }

  // ---------------------------------------------------------------------
  // 下载、解析
  // ---------------------------------------------------------------------

  static bool _isLoopback(String host) =>
      host == "localhost" ||
      host == "127.0.0.1" ||
      host == "::1" ||
      host == "[::1]";

  static Uri _toUri(String url) {
    if (!url.contains("://") && File(url).isAbsolute) {
      return Uri.file(url);
    }
    var uri = Uri.tryParse(url);
    if (uri == null || uri.scheme.isEmpty) {
      throw CoreError("地址无效：{url}".tf({"url": url}));
    }
    return uri;
  }

  static const int _maxDownload = 5 * 1024 * 1024;

  Future<String> _download(String url) async =>
      utf8.decode(await _downloadBytes(url), allowMalformed: true);

  Future<List<int>> _downloadBytes(String url) async {
    var hook = fetchOverride;
    if (hook != null) {
      List<int>? bytes;
      try {
        bytes = await hook(url.trim());
      } catch (e) {
        throw CoreError("下载失败：{url}（{e}）".tf({"url": url, "e": e}));
      }
      if (bytes != null) {
        if (bytes.length > _maxDownload) {
          throw CoreError("文件过大：{url}".tf({"url": url}));
        }
        return bytes;
      }
    }
    var uri = _toUri(url.trim());
    if (uri.scheme == "file") {
      try {
        return await File(uri.toFilePath()).readAsBytes();
      } catch (e) {
        throw CoreError("读取文件失败：{toFilePath}".tf({"toFilePath": uri.toFilePath()}));
      }
    }
    if (uri.scheme != "https" &&
        !(uri.scheme == "http" && _isLoopback(uri.host))) {
      throw CoreError("只支持 https:// 地址（本机测试可用 file:/// 或 http://127.0.0.1）".t);
    }
    var client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      var request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      var response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        await response.drain<void>().catchError((_) {});
        throw CoreError("下载失败（HTTP {statusCode}）：{url}".tf({"statusCode": response.statusCode, "url": url}));
      }
      var bytes = BytesBuilder(copy: false);
      await for (var chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.add(chunk);
        if (bytes.length > _maxDownload) {
          throw CoreError("文件过大：{url}".tf({"url": url}));
        }
      }
      return bytes.takeBytes();
    } on CoreError {
      rethrow;
    } on TimeoutException {
      throw CoreError("下载超时：{url}".tf({"url": url}));
    } catch (e) {
      throw CoreError("下载失败：{url}（{e}）".tf({"url": url, "e": e}));
    } finally {
      client.close(force: true);
    }
  }

  Future<LiveSourceMeta> _parseInBackground(
    String code,
    String filename,
  ) async {
    var version = appVersion;
    var result = await _runParse([(filename, code)], version);
    var first = result.first;
    if (first is LiveSourceMeta) return first;
    throw CoreError(first.toString());
  }

  // 静态方法里创建闭包，避免把 this 带进后台 isolate
  static Future<List<Object>> _runParse(
    List<(String, String)> inputs,
    String appVersion,
  ) {
    var texts = CoreText.snapshot?.call();
    return Isolate.run(() {
      CoreText.use(texts);
      return _parseAll(inputs, appVersion);
    });
  }

  /// 关闭所有源的后台引擎
  Future<void> dispose() async {
    for (var site in _sites.values) {
      await site.dispose();
    }
    _sites.clear();
    await _changes.close();
  }
}

/// 在后台 isolate 里逐个解析：成功为 LiveSourceMeta，失败为错误说明
List<Object> _parseAll(List<(String, String)> inputs, String appVersion) {
  var results = <Object>[];
  for (var (path, code) in inputs) {
    try {
      results.add(
        parseLiveSourceScript(
          code,
          filename: LiveSourceManager._baseName(path),
          appVersion: appVersion,
        ),
      );
    } on CoreError catch (e) {
      results.add(e.message);
    } catch (e) {
      results.add(e.toString());
    }
  }
  return results;
}
