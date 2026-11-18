import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/source_hooks.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 直播源（.live.js 脚本平台）：安装、订阅与更新，见 doc/live_source_api.md
///
/// 加载失败（或当前版本还没有脚本运行环境）时当作没有直播源，App 照常使用自带平台
class LiveSourceService extends GetxService {
  static LiveSourceService get instance => Get.find<LiveSourceService>();

  static bool get registered => Get.isRegistered<LiveSourceService>();

  LiveSourceManager? manager;

  /// 脚本运行环境是否可用（init 成功）
  final available = false.obs;

  /// init 失败的原因
  final initError = "".obs;

  /// 已安装且能加载的源
  final sites = <ScriptLiveSite>[].obs;

  /// 加载失败的脚本：文件名 → 原因
  final loadErrors = <String, String>{}.obs;

  /// 订阅地址
  final subscriptions = <String>[].obs;

  /// 启动时每天检查一次更新
  final autoCheck = true.obs;

  /// 上次检查到的可更新的源（设置页显示“更新到 x.y.z”）
  final updates = <LiveSourceIndexEntry>[].obs;

  StreamSubscription<void>? _changes;
  Timer? _refreshTimer;

  static const Duration _initTimeout = Duration(seconds: 5);
  static const Duration _checkInterval = Duration(hours: 24);

  Future<void> init() async {
    autoCheck.value = LocalStorageService.instance
        .getValue(LocalStorageService.kLiveSourceAutoCheck, true);
    try {
      var dir = await getApplicationSupportDirectory();
      manager = LiveSourceManager(
        directory: p.join(dir.path, "live_sources"),
        appVersion: Utils.packageInfo.version,
        // 装了 SourceHooks 时，github: 地址由它读，别的照常下载
        fetchOverride: fetchOverride,
      );
      _changes = manager!.changes.listen((_) => _scheduleRefresh());
      // 自带平台每次调用时查有没有生效的修正（§9）；没有加载好时查不到，照常用内置代码
      Sites.bindOverrides((id) => manager?.activeOverride(id));
    } catch (e, stackTrace) {
      Log.e("直播源初始化失败：$e", stackTrace);
      initError.value = errorText(e);
      manager = null;
      return;
    }
    Future<void> loading;
    try {
      loading = manager!.init();
    } catch (e, stackTrace) {
      _onInitError(e, stackTrace);
      return;
    }
    try {
      await loading.timeout(_initTimeout);
      _onInitDone();
    } on TimeoutException {
      // 不挡住启动，加载完再刷新平台列表
      Log.w("直播源加载超过 ${_initTimeout.inSeconds} 秒，改为后台加载");
      loading.then((_) => _onInitDone(), onError: _onInitError);
    } catch (e, stackTrace) {
      _onInitError(e, stackTrace);
    }
  }

  void _onInitDone() {
    available.value = true;
    initError.value = "";
    reload();
    _scheduleDailyCheck();
  }

  void _onInitError(Object e, [StackTrace? stackTrace]) {
    Log.e("直播源加载失败：$e", stackTrace ?? StackTrace.current);
    available.value = false;
    initError.value = errorText(e);
    reload();
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 50), reload);
  }

  /// 从 manager 重新读取已安装的源和订阅，更新平台列表
  void reload() {
    var m = manager;
    if (m == null) {
      return;
    }
    List<ScriptLiveSite> list;
    Map<String, String> errors;
    List<String> subs;
    try {
      list = List.of(m.sites);
      errors = Map.of(m.loadErrors);
      subs = List.of(m.subscriptions);
    } catch (e) {
      Log.logPrint(e);
      list = [];
      errors = {};
      subs = [];
    }
    var oldIds = sites.map((e) => e.id).toSet();
    sites.assignAll(list);
    loadErrors.assignAll(errors);
    subscriptions.assignAll(subs);
    _reloadOverrides(m);
    // 内置平台的修正不是单独的平台：不进平台列表、排序
    var platforms = list.where((e) => !e.info.isOverride).toList();
    // 已经更新、删除的源不再提示更新
    updates.removeWhere((e) {
      var site = list.firstWhereOrNull((s) => s.info.key == e.key);
      return site == null ||
          compareLiveSourceVersion(e.version, site.info.version) <= 0;
    });
    Sites.setScriptSites(list);
    if (Get.isRegistered<AppSettingsController>()) {
      AppSettingsController.instance.appendSiteSort(platforms.map((e) => e.id));
    }
    // 新装的源上已有关注（如同步过来的）：之前显示为“平台未安装”，重新读取直播状态
    var added =
        platforms.map((e) => e.id).where((e) => !oldIds.contains(e)).toSet();
    if (added.isNotEmpty &&
        Get.isRegistered<FollowService>() &&
        FollowService.instance.followList
            .any((e) => added.contains(e.siteId))) {
      FollowService.instance.loadData();
    }
  }

  ScriptLiveSite? siteOf(String key) =>
      sites.firstWhereOrNull((e) => e.info.key == key);

  // ---- 内置平台的修正（脚本写了 overrides 的源，§9） ----

  /// 自带平台 id → 正在替换它的修正（账号管理、直播间里提示用）
  final activeOverrides = <String, LiveSourceInfo>{}.obs;

  /// 开发者选项：允许未签名的内置平台修正（不安全，默认关）
  final allowUnsignedOverrides = false.obs;

  void _reloadOverrides(LiveSourceManager m) {
    var active = <String, LiveSourceInfo>{};
    try {
      for (var id in Sites.builtInSites.keys) {
        var binding = m.activeOverride(id);
        if (binding != null) active[id] = binding.info;
      }
      allowUnsignedOverrides.value = m.allowUnsignedOverrides;
    } catch (e) {
      Log.logPrint(e);
    }
    activeOverrides.assignAll(active);
  }

  /// 自带平台 [siteId] 正在用的修正，没有时为 null
  LiveSourceInfo? activeOverrideOf(String siteId) => activeOverrides[siteId];

  bool overrideEnabled(String key) => manager?.overrideEnabled(key) ?? true;

  bool overrideFallback(String key) => manager?.overrideFallback(key) ?? true;

  /// 修正现在的状态（生效中、已关闭、没有签名……），不是修正时为 null
  LiveSourceOverrideStatus? overrideStatus(String key) =>
      manager?.overrideStatus(key);

  Future<void> setOverrideEnabled(String key, bool value) async {
    await _requireManager().setOverrideEnabled(key, value);
    reload();
  }

  Future<void> setOverrideFallback(String key, bool value) async {
    await _requireManager().setOverrideFallback(key, value);
    reload();
  }

  Future<void> setAllowUnsignedOverrides(bool value) async {
    await _requireManager().setAllowUnsignedOverrides(value);
    reload();
  }

  // ---- 登录（脚本声明了 login 的源） ----

  /// 声明了登录的源的帐号状态：key → 帐号（没读过的不在里面）
  final accounts = <String, LiveSourceAccount>{}.obs;

  /// 声明了登录的源
  List<ScriptLiveSite> get loginSites =>
      sites.where((e) => e.hasLogin).toList();

  /// 重新读取一个源的帐号状态（脚本的 account()，出错时只按 Cookie 判断）
  Future<LiveSourceAccount?> refreshAccount(String key) async {
    var site = siteOf(key);
    if (site == null || !site.hasLogin) {
      accounts.remove(key);
      return null;
    }
    LiveSourceAccount account;
    try {
      account = await site.account();
    } catch (e) {
      Log.logPrint("读取直播源帐号失败：$key ${e.runtimeType}");
      var loggedIn = false;
      try {
        loggedIn = await site.isLoggedIn();
      } catch (_) {}
      account = LiveSourceAccount(loggedIn: loggedIn);
    }
    accounts[key] = account;
    return account;
  }

  /// 读取所有声明了登录的源的帐号状态（打开账号管理时）
  Future<void> refreshAccounts() async {
    await Future.wait(loginSites.map((e) => refreshAccount(e.info.key)));
  }

  /// 登录：把 Cookie（"a=1; b=2"）写进这个源的 Cookie 罐，返回是否已登录。Cookie 不写日志
  Future<bool> loginSource(String key, String cookies) async {
    var site = siteOf(key);
    if (site == null) {
      throw LiveSourceException("没有安装这个直播源".t);
    }
    var ok = await site.loginWithCookies(cookies);
    await refreshAccount(key);
    return ok;
  }

  /// 退出登录：删除这个源登录地址下的 Cookie
  Future<void> logoutSource(String key) async {
    var site = siteOf(key);
    if (site == null) {
      return;
    }
    await site.logout();
    accounts[key] = const LiveSourceAccount(loggedIn: false);
  }

  LiveSourceManager _requireManager() {
    var m = manager;
    if (m == null) {
      throw LiveSourceException(
        initError.value.isEmpty ? "直播源功能不可用".t : "直播源功能不可用：{initError}".tf({"initError": initError.value}),
      );
    }
    return m;
  }

  /// 订阅和直播源地址：https:// 或本机测试用的 file:///
  static bool isValidUrl(String url) {
    var u = url.trim().toLowerCase();
    return u.startsWith("https://") ||
        u.startsWith("http://") ||
        u.startsWith("file:///");
  }

  static bool isRemoteUrl(String? url) {
    var u = (url ?? "").trim().toLowerCase();
    return u.startsWith("https://") || u.startsWith("http://");
  }

  /// 能下载的地址：网址，或者装了 SourceHooks 时的 github:用户/仓库/路径
  static bool isFetchableUrl(String? url) =>
      isRemoteUrl(url) || SourceHooks.isPrivate(url ?? "");

  /// 交给管理器的下载钩子：github: 地址由 [SourceHooks] 读，别的返回 null 照常下载
  static Future<List<int>?> fetchOverride(String url) async =>
      await SourceHooks.fetch?.call(url);

  Future<LiveSourceInfo> installFromUrl(String url) async {
    var info = await _requireManager().installFromUrl(url.trim());
    reload();
    return info;
  }

  Future<LiveSourceInfo> installFromFile(String path) async {
    var info = await _requireManager().installFromFile(path);
    reload();
    return info;
  }

  // ---- 两步安装、更新：先给用户看权限（域名、敏感功能、签名），确认后再装 ----

  Future<LiveSourcePlan> prepareInstallFromUrl(String url) =>
      _requireManager().prepareInstallFromUrl(url.trim());

  Future<LiveSourcePlan> prepareInstallFromFile(String path) =>
      _requireManager().prepareInstallFromFile(path);

  Future<LiveSourcePlan> prepareUpdate(String key) =>
      _requireManager().prepareUpdate(key);

  /// 安装准备好的版本；[confirmed] 表示用户看过权限并同意了
  Future<LiveSourceInfo> applyPlan(
    LiveSourcePlan plan, {
    bool confirmed = false,
  }) async {
    var info = await _requireManager().applyPlan(plan, confirmed: confirmed);
    updates.removeWhere(
      (e) =>
          e.key == info.key &&
          compareLiveSourceVersion(e.version, info.version) <= 0,
    );
    reload();
    return info;
  }

  /// 签名安装的源记下的发布者公钥，没有签名为 null
  String? publicKeyOf(String key) => manager?.publicKeyOf(key);

  /// 订阅的发布者公钥（添加时记下的），没有签名的订阅为 null
  String? subscriptionPublicKey(String url) =>
      manager?.subscriptionPublicKey(url);

  /// 订阅的公钥变了、去掉了签名时的说明
  String? subscriptionKeyError(String url) =>
      manager?.subscriptionKeyError(url);

  // ---- 源的设置项（脚本的 settings 字段，只存在本机） ----

  Future<Map<String, dynamic>> getSettings(String key) async {
    var site = siteOf(key);
    if (site == null) {
      throw LiveSourceException("没有安装这个直播源".t);
    }
    return site.getSettings();
  }

  Future<Map<String, dynamic>> setSetting(
    String key,
    String settingKey,
    dynamic value,
  ) async {
    var site = siteOf(key);
    if (site == null) {
      throw LiveSourceException("没有安装这个直播源".t);
    }
    return site.setSettings({settingKey: value});
  }

  Future<void> remove(String key) async {
    var id = "js:$key";
    await _requireManager().remove(key);
    updates.removeWhere((e) => e.key == key);
    reload();
    if (Get.isRegistered<AppSettingsController>()) {
      AppSettingsController.instance.removeSiteSort(id);
    }
  }

  /// 删除加载失败的脚本文件
  Future<void> removeFile(String fileName) async {
    await _requireManager().removeFile(fileName);
    reload();
  }

  /// 源的更新地址（脚本里的 url，没写时为安装来源）
  String? updateUrl(String key) => manager?.updateUrl(key);

  /// 订阅的名称（index.json 里的 name），没读过时为 null
  String? subscriptionName(String url) => manager?.subscriptionName(url);

  Future<LiveSourceInfo> update(String key) async {
    var info = await _requireManager().update(key);
    updates.removeWhere((e) => e.key == key);
    reload();
    return info;
  }

  Future<void> addSubscription(String url) async {
    await _requireManager().addSubscription(url.trim());
    reload();
  }

  Future<void> removeSubscription(String url) async {
    await _requireManager().removeSubscription(url);
    reload();
  }

  Future<List<LiveSourceIndexEntry>> fetchSubscription(String url) =>
      _requireManager().fetchSubscription(url);

  /// 检查所有订阅里的更新
  Future<List<LiveSourceIndexEntry>> checkUpdates() async {
    var list = await _requireManager().checkUpdates();
    updates.assignAll(list);
    LocalStorageService.instance.setValue(
      LocalStorageService.kLiveSourceLastCheck,
      DateTime.now().millisecondsSinceEpoch,
    );
    return list;
  }

  void setAutoCheck(bool value) {
    autoCheck.value = value;
    LocalStorageService.instance
        .setValue(LocalStorageService.kLiveSourceAutoCheck, value);
  }

  /// 启动后每天自动检查一次更新，有更新时提示
  void _scheduleDailyCheck() {
    if (!autoCheck.value ||
        subscriptions.isEmpty ||
        MultiWindow.skips(BackgroundTask.liveSourceUpdateCheck)) {
      return;
    }
    var last = LocalStorageService.instance
        .getValue<int>(LocalStorageService.kLiveSourceLastCheck, 0);
    var elapsed = DateTime.now().millisecondsSinceEpoch - last;
    if (elapsed >= 0 && elapsed < _checkInterval.inMilliseconds) {
      return;
    }
    // 等首页加载完再检查，不和启动时的请求抢网络
    Future.delayed(const Duration(seconds: 8), () async {
      try {
        var list = await checkUpdates();
        if (list.isNotEmpty) {
          showUpdateNotice(list.length);
        }
      } catch (e) {
        Log.logPrint("直播源自动检查更新失败：$e");
      }
    });
  }

  /// 底部提示“有 N 个直播源可以更新”，点“查看”进入直播源设置
  static void showUpdateNotice(int count) {
    SmartDialog.show(
      alignment: Alignment.bottomCenter,
      usePenetrate: true,
      maskColor: Colors.transparent,
      clickMaskDismiss: false,
      displayTime: const Duration(seconds: 8),
      builder: (context) => SafeArea(
        child: Padding(
          padding: AppStyle.edgeInsetsA12.copyWith(bottom: 72),
          child: Material(
            elevation: 4,
            color: Theme.of(context).colorScheme.inverseSurface,
            borderRadius: AppStyle.radius8,
            child: Padding(
              padding: AppStyle.edgeInsetsL16.copyWith(right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "有 {count} 个直播源可以更新".tf({"count": count}),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onInverseSurface,
                    ),
                  ),
                  AppStyle.hGap8,
                  TextButton(
                    onPressed: () {
                      SmartDialog.dismiss(status: SmartStatus.custom);
                      Get.toNamed(RoutePath.kSettingsLiveSource);
                    },
                    child: Text(
                      "查看".t,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.inversePrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---- 同步 ----

  /// 同步备份里的直播源：订阅地址与已安装的源（只有地址，不含脚本内容）
  Map<String, dynamic> exportSyncData() {
    return LiveSourceSyncData(
      subscriptions: subscriptions.toList(),
      sources: sites
          .map((e) => LiveSourceSyncEntry(
                key: e.info.key,
                name: e.info.name,
                version: e.info.version,
                url: updateUrl(e.info.key) ?? "",
              ))
          .toList(),
    ).toJson();
  }

  /// 恢复直播源：补上没有的订阅，再从地址安装本机没有的源。
  /// 本机路径（file:///）在别的设备上没有意义，跳过
  Future<LiveSourceRestoreResult> restoreSyncData(Map data) async {
    var result = LiveSourceRestoreResult();
    var m = manager;
    if (m == null || !available.value) {
      result.unavailable = true;
      return result;
    }
    var sync = LiveSourceSyncData.fromJson(data);
    var subs = List.of(subscriptions);
    for (var url in sync.subscriptions) {
      if (!isFetchableUrl(url) || subs.contains(url)) {
        continue;
      }
      try {
        await m.addSubscription(url);
        subs.add(url);
        result.subscriptions++;
      } catch (e) {
        Log.logPrint("恢复直播源订阅失败：$url $e");
        result.failed.add(url);
      }
    }
    for (var source in sync.sources) {
      if (siteOf(source.key) != null) {
        continue;
      }
      if (!isFetchableUrl(source.url)) {
        result.skipped.add(source.name.isEmpty ? source.key : source.name);
        continue;
      }
      try {
        var plan = await m.prepareInstallFromUrl(source.url);
        // 替换内置平台的修正不跟着备份自动装：要用户自己在直播源设置里看过、确认
        if (plan.next.isOverride) {
          result.overrides.add(source.name.isEmpty ? source.key : source.name);
          continue;
        }
        await m.applyPlan(plan, confirmed: true);
        result.installed++;
      } catch (e) {
        Log.logPrint("恢复直播源失败：${source.key} $e");
        result.failed.add(source.name.isEmpty ? source.key : source.name);
      }
    }
    reload();
    return result;
  }

  /// 在后台恢复直播源，完成后提示结果
  void restoreSyncDataInBackground(Map data) {
    restoreSyncData(data).then((result) {
      var text = result.summary;
      if (text.isNotEmpty) {
        SmartDialog.showToast(text, displayTime: const Duration(seconds: 4));
      }
    }).catchError((e) {
      Log.logPrint(e);
    });
  }

  /// 给用户看的错误信息
  static String errorText(Object e) {
    if (e is UnimplementedError || e is UnsupportedError) {
      return "当前版本还不支持直播源".t;
    }
    if (e is LiveSourceException) {
      return e.message;
    }
    if (e is CoreError) {
      return e.toString();
    }
    if (e is TimeoutException) {
      return "超时".t;
    }
    return e.toString().replaceFirst(RegExp(r"^(Exception|Error):\s*"), "");
  }

  @override
  void onClose() {
    _refreshTimer?.cancel();
    _changes?.cancel();
    manager?.dispose();
    super.onClose();
  }
}

class LiveSourceException implements Exception {
  final String message;
  LiveSourceException(this.message);

  @override
  String toString() => message;
}

/// 同步时一个已安装的源
class LiveSourceSyncEntry {
  final String key;
  final String name;
  final String version;
  final String url;
  const LiveSourceSyncEntry({
    required this.key,
    required this.name,
    required this.version,
    required this.url,
  });

  static LiveSourceSyncEntry? fromJson(dynamic json) {
    if (json is! Map) {
      return null;
    }
    var key = json["key"]?.toString() ?? "";
    if (key.isEmpty) {
      return null;
    }
    return LiveSourceSyncEntry(
      key: key,
      name: json["name"]?.toString() ?? "",
      version: json["version"]?.toString() ?? "",
      url: json["url"]?.toString() ?? "",
    );
  }

  Map<String, dynamic> toJson() => {
        "key": key,
        "name": name,
        "version": version,
        "url": url,
      };
}

/// 同步备份里的直播源部分（只在本版本之间同步，官方版不读取）
class LiveSourceSyncData {
  final List<String> subscriptions;
  final List<LiveSourceSyncEntry> sources;
  const LiveSourceSyncData({
    this.subscriptions = const [],
    this.sources = const [],
  });

  factory LiveSourceSyncData.fromJson(Map json) {
    var subs = json["subscriptions"];
    var sources = json["sources"];
    return LiveSourceSyncData(
      subscriptions: subs is List
          ? subs
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toSet()
              .toList()
          : const [],
      sources: sources is List
          ? sources
              .map(LiveSourceSyncEntry.fromJson)
              .whereType<LiveSourceSyncEntry>()
              .toList()
          : const [],
    );
  }

  bool get isEmpty => subscriptions.isEmpty && sources.isEmpty;

  Map<String, dynamic> toJson() => {
        "subscriptions": subscriptions,
        "sources": sources.map((e) => e.toJson()).toList(),
      };
}

class LiveSourceRestoreResult {
  /// 本机的直播源功能不可用
  bool unavailable = false;
  int subscriptions = 0;
  int installed = 0;

  /// 安装失败的源或订阅
  final List<String> failed = [];

  /// 从本机文件安装、没有地址的源
  final List<String> skipped = [];

  /// 替换内置平台的修正：不自动安装
  final List<String> overrides = [];

  String get summary {
    if (unavailable) {
      return "";
    }
    var parts = <String>[
      if (subscriptions > 0) "添加了 {subscriptions} 个订阅".tf({"subscriptions": subscriptions}),
      if (installed > 0) "安装了 {installed} 个直播源".tf({"installed": installed}),
      if (failed.isNotEmpty) "{failedCount} 个安装失败".tf({"failedCount": failed.length}),
      if (skipped.isNotEmpty) "{skippedCount} 个是本机文件安装的，需要手动安装".tf({"skippedCount": skipped.length}),
      if (overrides.isNotEmpty) "{overridesCount} 个会替换内置平台，需要手动安装".tf({"overridesCount": overrides.length}),
    ];
    return parts.isEmpty ? "" : "直播源：{parts}".tf({"parts": parts.join("，".t)});
  }
}
