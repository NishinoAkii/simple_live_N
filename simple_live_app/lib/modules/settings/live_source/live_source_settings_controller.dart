import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/source_hooks.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/settings/live_source/live_source_permission_dialog.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/app_update/update_config.dart';
import 'package:simple_live_app/services/live_source_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 订阅里一项的状态（按本机已安装的版本算，安装、更新后立即变化）
enum LiveSourceEntryState { notInstalled, hasUpdate, latest }

class LiveSourceSettingsController extends GetxController {
  LiveSourceService get service => LiveSourceService.instance;

  /// 各订阅里的源
  final entries = <String, List<LiveSourceIndexEntry>>{}.obs;

  /// 读取失败的订阅：地址 → 原因
  final entryErrors = <String, String>{}.obs;

  /// 正在读取的订阅
  final loading = <String>{}.obs;

  /// 正在检查更新
  final checking = false.obs;

  bool _busy = false;

  @override
  void onInit() {
    refreshAllSubscriptions();
    // 菜单里显示“登录 / 退出登录”要用
    service.refreshAccounts();
    super.onInit();
  }

  void refreshAllSubscriptions() {
    for (var url in service.subscriptions) {
      refreshSubscription(url);
    }
  }

  Future<void> refreshSubscription(String url) async {
    if (loading.contains(url)) {
      return;
    }
    loading.add(url);
    entryErrors.remove(url);
    try {
      var list = await service.fetchSubscription(url);
      entries[url] = list;
    } catch (e) {
      Log.logPrint(e);
      entryErrors[url] = LiveSourceService.errorText(e);
    } finally {
      loading.remove(url);
    }
  }

  LiveSourceEntryState entryState(LiveSourceIndexEntry entry) {
    var site = service.siteOf(entry.key);
    if (site == null) {
      return LiveSourceEntryState.notInstalled;
    }
    return compareLiveSourceVersion(entry.version, site.info.version) > 0
        ? LiveSourceEntryState.hasUpdate
        : LiveSourceEntryState.latest;
  }

  /// 检查更新后得到的新版本，没有时为 null
  LiveSourceIndexEntry? updateOf(String key) =>
      service.updates.firstWhereOrNull((e) => e.key == key);

  /// 显示加载中、执行、提示结果；同一时间只做一件事
  Future<T?> _run<T>(
    String loadingText,
    Future<T> Function() action, {
    String Function(T result)? success,
    String? failure,
  }) async {
    failure ??= "失败".t;
    if (_busy) {
      SmartDialog.showToast("上一个操作还没完成，请稍等".t);
      return null;
    }
    _busy = true;
    SmartDialog.showLoading(msg: loadingText);
    try {
      var result = await action();
      SmartDialog.dismiss(status: SmartStatus.loading);
      if (success != null) {
        SmartDialog.showToast(success(result));
      }
      return result;
    } catch (e, stackTrace) {
      Log.e("$failure：$e", stackTrace);
      SmartDialog.dismiss(status: SmartStatus.loading);
      SmartDialog.showToast(
        "$failure${"：".t}${LiveSourceService.errorText(e)}",
      );
      return null;
    } finally {
      _busy = false;
    }
  }

  bool _checkUrl(String text) {
    if (!LiveSourceService.isValidUrl(text) &&
        !SourceHooks.isPrivate(SourceHooks.normalizeUrl(text))) {
      SmartDialog.showToast("请输入 https:// 开头的地址（本机测试可用 file:///）".t);
      return false;
    }
    return true;
  }

  // ---- 安装 ----

  Future<void> installFromUrlDialog() async {
    var url = await Utils.showEditTextDialog(
      "",
      title: "通过链接安装".t,
      hintText: "https://…/xxx.live.js",
      validate: _checkUrl,
    );
    if (url == null || url.trim().isEmpty) {
      return;
    }
    var address = SourceHooks.normalizeUrl(url.trim());
    await _installWithConfirm(
      "正在下载".t,
      () => service.prepareInstallFromUrl(address),
    );
  }

  /// 下载、解析（订阅有签名时校验签名）后给用户看权限，同意了才安装
  Future<void> _installWithConfirm(
    String loadingText,
    Future<LiveSourcePlan> Function() prepare,
  ) async {
    var plan = await _run(loadingText, prepare, failure: "安装失败".t);
    if (plan == null || !await LiveSourcePermissionDialog.show(plan)) {
      return;
    }
    await _run(
      "正在安装".t,
      () => service.applyPlan(plan, confirmed: true),
      success: (info) => "已安装 {name} {version}".tf({"name": info.name, "version": info.version}),
      failure: "安装失败".t,
    );
  }

  Future<void> installFromFile() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['js'],
        dialogTitle: "选择直播源（.live.js）".t,
      );
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开文件：{e}".tf({"e": e}));
      return;
    }
    var path = picked?.files.single.path;
    if (path == null || path.isEmpty) {
      return;
    }
    await _installWithConfirm(
      "正在读取".t,
      () => service.prepareInstallFromFile(path),
    );
  }

  Future<void> installEntry(LiveSourceIndexEntry entry) async {
    await _installWithConfirm(
      "正在下载 {name}".tf({"name": entry.name}),
      () => service.prepareInstallFromUrl(entry.url),
    );
  }

  // ---- 已安装 ----

  void openDetail(LiveSourceInfo info) {
    Get.toNamed(RoutePath.kSettingsLiveSourceDetail, arguments: info.key);
  }

  /// 更新：权限没有扩大时直接装；新增了域名、敏感功能或签名有变化时先给用户确认
  Future<void> updateSource(LiveSourceInfo info) async {
    var plan = await _run(
      "正在下载 {name}".tf({"name": info.name}),
      () => service.prepareUpdate(info.key),
      failure: "更新失败".t,
    );
    if (plan == null) {
      return;
    }
    await _applyUpdate(plan, info.version);
  }

  Future<void> _applyUpdate(LiveSourcePlan plan, String oldVersion) async {
    if (plan.needsConfirmation &&
        !await LiveSourcePermissionDialog.show(plan)) {
      return;
    }
    await _run(
      "正在更新 {name}".tf({"name": plan.next.name}),
      () => service.applyPlan(plan, confirmed: true),
      success: (next) => next.version == oldVersion
          ? "{name} 已是最新（{version}）".tf({"name": next.name, "version": next.version})
          : "{name} 已更新到 {version}".tf({"name": next.name, "version": next.version}),
      failure: "更新失败".t,
    );
  }

  Future<void> removeSource(LiveSourceInfo info) async {
    var confirm = await Utils.showAlertDialog(
      "确定要删除直播源“{name}”吗？\n关注和观看记录会保留，重装后可继续用。".tf({"name": info.name}),
      title: "删除直播源".t,
      confirm: "删除".t,
    );
    if (!confirm) {
      return;
    }
    await _run(
      "正在删除".t,
      () => service.remove(info.key),
      success: (_) => "已删除 {name}".tf({"name": info.name}),
      failure: "删除失败".t,
    );
  }

  void showLoadError(String file, String reason) {
    Get.dialog(
      AlertDialog(
        title: Text("加载失败".t),
        content: Container(
          constraints: const BoxConstraints(maxHeight: 400),
          child: SingleChildScrollView(
            child: Padding(
              padding: AppStyle.edgeInsetsV12,
              child: SelectableText("$file\n\n$reason"),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Utils.copyToClipboard("$file\n$reason");
              SmartDialog.showToast("已复制".t);
            },
            child: Text("复制".t),
          ),
          TextButton(
            onPressed: () async {
              Get.back();
              try {
                await service.removeFile(file);
                SmartDialog.showToast("已删除 {file}".tf({"file": file}));
              } catch (e) {
                SmartDialog.showToast("删除失败：{e}".tf({"e": e}));
              }
            },
            child: Text("删除这个文件".t),
          ),
          TextButton(
            onPressed: Get.back,
            child: Text("关闭".t),
          ),
        ],
      ),
    );
  }

  // ---- 订阅 ----

  Future<void> addSubscriptionDialog() async {
    var url = await Utils.showEditTextDialog(
      "",
      title: "添加订阅".t,
      hintText: "https://…/index.json",
      validate: _checkUrl,
    );
    if (url == null || url.trim().isEmpty) {
      return;
    }
    await addSubscription(SourceHooks.normalizeUrl(url.trim()));
  }

  /// 默认的订阅（UpdateConfig.liveSourceSubscription）；没有时为空
  String get defaultSubscription => UpdateConfig.current.liveSourceSubscription;

  /// 添加默认的订阅（还没有订阅时设置页上有这一项）
  Future<void> addDefaultSubscription() => addSubscription(defaultSubscription);

  Future<void> addSubscription(String url) async {
    if (url.isEmpty) {
      return;
    }
    if (service.subscriptions.contains(url)) {
      SmartDialog.showToast("已经添加过这个订阅".t);
      return;
    }
    var added = await _run(
      "正在添加订阅".t,
      () async {
        await service.addSubscription(url);
        return true;
      },
      success: (_) => "已添加订阅".t,
      failure: "添加失败".t,
    );
    if (added == true) {
      refreshSubscription(url);
    }
  }

  Future<void> removeSubscription(String url) async {
    var confirm = await Utils.showAlertDialog(
      "确定要删除这个订阅吗？\n{url}\n已安装的直播源不会删除。".tf({"url": url}),
      title: "删除订阅".t,
      confirm: "删除".t,
    );
    if (!confirm) {
      return;
    }
    var removed = await _run(
      "正在删除".t,
      () async {
        await service.removeSubscription(url);
        return true;
      },
      success: (_) => "已删除订阅".t,
      failure: "删除失败".t,
    );
    if (removed == true) {
      entries.remove(url);
      entryErrors.remove(url);
    }
  }

  // ---- 更新 ----

  Future<void> checkUpdates() async {
    if (checking.value) {
      return;
    }
    if (service.subscriptions.isEmpty) {
      SmartDialog.showToast("还没有添加订阅，没法检查更新".t);
      return;
    }
    checking.value = true;
    try {
      var list = await service.checkUpdates();
      SmartDialog.showToast(
        list.isEmpty ? "所有直播源都是最新的".t : "有 {listCount} 个直播源可以更新".tf({"listCount": list.length}),
      );
      refreshAllSubscriptions();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("检查更新失败：{errorText}".tf({"errorText": LiveSourceService.errorText(e)}));
    } finally {
      checking.value = false;
    }
  }

  Future<void> updateAll() async {
    var list = service.updates.toList();
    if (list.isEmpty) {
      return;
    }
    // 权限没有扩大的直接更新；扩大了的（新域名、新的敏感功能、签名变化）不自动装，逐个问用户
    var pending = <(LiveSourcePlan, String)>[];
    await _run(
      "正在更新".t,
      () async {
        var failed = <String>[];
        var done = 0;
        for (var entry in list) {
          try {
            var old = service.siteOf(entry.key)?.info.version ?? "";
            var plan = await service.prepareUpdate(entry.key);
            if (plan.needsConfirmation) {
              pending.add((plan, old));
              continue;
            }
            await service.applyPlan(plan);
            done++;
          } catch (e) {
            Log.logPrint(e);
            failed.add(entry.name);
          }
        }
        return (done, failed);
      },
      success: (r) => [
        if (r.$1 > 0) "已更新 {p} 个直播源".tf({"p": r.$1}),
        if (pending.isNotEmpty) "{pendingCount} 个需要确认权限".tf({"pendingCount": pending.length}),
        if (r.$2.isNotEmpty) "{p} 更新失败".tf({"p": r.$2.join("、".t)}),
      ].join("，".t),
      failure: "更新失败".t,
    );
    for (var (plan, old) in pending) {
      await _applyUpdate(plan, old);
    }
  }

  void setAutoCheck(bool value) => service.setAutoCheck(value);

  /// 开发者选项：允许未签名的内置平台修正。打开前再确认一次
  Future<void> setAllowUnsignedOverrides(bool value) async {
    if (value) {
      var confirm = await Utils.showAlertDialog(
        ("打开后，没签名的直播源也能替换内置平台的功能"
        "（播放地址、直播间信息……），别人改过的脚本也发现不了。\n"
        "只在自己写、测试修正时打开，用完关掉。").t,
        title: "允许未签名的内置平台修正".t,
        confirm: "打开".t,
      );
      if (!confirm) {
        return;
      }
    }
    try {
      await service.setAllowUnsignedOverrides(value);
    } catch (e) {
      SmartDialog.showToast("设置失败：{errorText}".tf({"errorText": LiveSourceService.errorText(e)}));
    }
  }
}
