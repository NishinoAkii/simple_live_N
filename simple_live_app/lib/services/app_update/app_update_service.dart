import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/source_hooks.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/windows_version.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/modules/settings/update/update_dialogs.dart';
import 'package:simple_live_app/services/app_update/installers/installers.dart';
import 'package:simple_live_app/services/app_update/release_api.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';
import 'package:simple_live_app/services/app_update/translation_sources.dart';
import 'package:simple_live_app/services/app_update/update_config.dart';
import 'package:simple_live_app/services/app_update/update_downloader.dart';
import 'package:simple_live_app/services/app_update/update_settings.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// 应用内更新：启动时检查、手动检查、更新对话框、下载并交给各平台的安装方式。
///
/// 只在 App 里弹对话框，不发系统通知
class AppUpdateService extends GetxService {
  static AppUpdateService get instance => Get.find<AppUpdateService>();

  static AppUpdateService? get maybeInstance =>
      Get.isRegistered<AppUpdateService>() ? instance : null;

  final UpdateConfig config;
  final Dio dio;

  /// 本机版本；测试里直接给
  final LocalBuild Function() localBuild;

  /// 当前平台的安装方式（installers/）
  final UpdateInstaller? Function() installer;

  /// 打开网页（Release 页）
  final Future<void> Function(String url) openUrl;

  /// 弹出更新对话框，返回用户的选择；测试里可以换掉
  final Future<UpdateChoice?> Function(UpdateDialog dialog) showUpdateDialog;

  final DateTime Function() now;

  /// 下载翻译、清单时临时放文件的文件夹；测试里直接给
  final Future<String> Function() sourcesDirectory;

  AppUpdateService({
    UpdateConfig? config,
    Dio? dio,
    LocalBuild Function()? localBuild,
    UpdateInstaller? Function()? installer,
    Future<void> Function(String url)? openUrl,
    Future<UpdateChoice?> Function(UpdateDialog dialog)? showUpdateDialog,
    DateTime Function()? now,
    Future<String> Function()? sourcesDirectory,
  })  : config = config ?? UpdateConfig.current,
        dio = dio ?? Dio(),
        localBuild = localBuild ?? _currentBuild,
        installer = installer ?? currentInstaller,
        openUrl = openUrl ?? _launch,
        showUpdateDialog = showUpdateDialog ?? UpdateDialog.show,
        now = now ?? DateTime.now,
        sourcesDirectory = sourcesDirectory ?? _sourcesDirectory;

  static Future<String> _sourcesDirectory() async =>
      p.join((await getApplicationCacheDirectory()).path, "app_sources");

  static LocalBuild _currentBuild() => LocalBuild.from(
        Utils.packageInfo.version,
        Utils.packageInfo.buildNumber,
        Utils.forkBuild,
      );

  static Future<void> _launch(String url) async {
    await launchUrlString(url, mode: LaunchMode.externalApplication);
  }

  final settings = UpdateSettings();

  /// 翻译源：列出、安装、更新翻译
  late final translations = TranslationSources(
    dio,
    config: config,
    settings: settings,
    workDirectory: sourcesDirectory,
  );

  /// 正在手动检查翻译更新
  final checkingTranslations = false.obs;

  /// 上次检查翻译更新的结果，设置页显示
  final translationResult = "".obs;

  /// 正在手动检查
  final checking = false.obs;

  /// 上次检查的结果，设置页“检查更新”下面显示
  final lastResult = "".obs;

  Timer? _startupTimer;

  @override
  void onInit() {
    settings.load();
    super.onInit();
  }

  @override
  void onClose() {
    _startupTimer?.cancel();
    super.onClose();
  }

  ReleaseApi get _api => ReleaseApi(dio, config);

  String get _token => settings.githubToken.value;

  AutoCheckBlock? startupBlocker() => UpdateCheckPolicy.blocker(
        isSecondary: MultiWindow.skips(BackgroundTask.appUpdateCheck),
        startedForRoom: MultiWindow.startedForRoom,
        autoCheck: settings.autoCheck.value,
        needsLogin: config.needsLogin,
        loggedIn: settings.loggedIn,
        lastCheck: settings.lastCheck,
        now: now(),
      );

  /// 翻译更新和 App 更新一起查，规则一样（主窗口、一天一次、开关），
  /// 只是不用登录
  AutoCheckBlock? translationBlocker() => UpdateCheckPolicy.blocker(
        isSecondary: MultiWindow.skips(BackgroundTask.appUpdateCheck),
        startedForRoom: MultiWindow.startedForRoom,
        autoCheck: settings.autoCheck.value,
        needsLogin: SourceHooks.isPrivate(translations.sourceUrl),
        loggedIn: settings.loggedIn,
        lastCheck: settings.translationLastCheck,
        now: now(),
      );

  /// 主窗口启动约 10 秒后检查一次（一天最多一次）。多开的副窗口、带着链接启动、
  /// 设置里关掉、要登录却没登录时不查。装过的翻译同时检查
  void scheduleStartupCheck() {
    var block = startupBlocker();
    var translationBlock = translationBlocker();
    if (block != null && translationBlock != null) {
      Log.d("启动时不检查更新：${block.name}，翻译：${translationBlock.name}");
      return;
    }
    _startupTimer?.cancel();
    _startupTimer = Timer(UpdateCheckPolicy.startDelay, () {
      // 这 10 秒里可能关掉了开关、退出了登录
      if (startupBlocker() == null) {
        unawaited(autoCheck());
      }
      if (translationBlocker() == null) {
        unawaited(autoCheckTranslations());
      }
    });
  }

  /// 自动检查翻译：变了的直接换成新的，在 App 里提示一句；没装翻译时不联网
  Future<void> autoCheckTranslations() async {
    if (I18n.imported.isEmpty) {
      return;
    }
    TranslationCheckResult result;
    try {
      result = await translations.updateInstalled();
    } catch (e) {
      Log.w("自动检查翻译更新失败：$e");
      return;
    }
    settings.markTranslationsChecked(now());
    if (result.updated.isNotEmpty) {
      SmartDialog.showToast(_updatedText(result.updated));
    }
  }

  static String _updatedText(List<AppLanguage> languages) =>
      "已更新翻译：{names}".tf({
        "names": languages.map((e) => e.name).join("、".t),
      });

  /// 手动检查翻译更新（设置页的“检查翻译更新”）
  Future<void> checkTranslationsNow() async {
    if (checkingTranslations.value) {
      return;
    }
    if (I18n.imported.isEmpty) {
      _reportTranslations("还没有装翻译".t);
      return;
    }
    checkingTranslations.value = true;
    try {
      var result = await translations.updateInstalled();
      settings.markTranslationsChecked(now());
      var parts = [
        if (result.updated.isNotEmpty) _updatedText(result.updated),
        if (result.failed.isNotEmpty)
          "{names} 更新失败".tf({"names": result.failed.keys.join("、".t)}),
      ];
      _reportTranslations(
        parts.isEmpty ? "翻译都是最新的".t : parts.join("\n"),
      );
    } catch (e) {
      Log.w("检查翻译更新失败：$e");
      _reportTranslations("检查翻译更新失败：{e}".tf({"e": e}));
    } finally {
      checkingTranslations.value = false;
    }
  }

  void _reportTranslations(String text) {
    translationResult.value = text;
    SmartDialog.showToast(text);
  }

  /// 自动检查：有新版本（而且没有跳过）时弹出对话框，出错只记日志
  Future<void> autoCheck() async {
    // Windows 7 安装包维持 1.24.0 的功能，不自动检查
    if (WindowsVersion.isWindows7) {
      return;
    }
    AppRelease release;
    try {
      release = await _api.latest(token: _token);
    } catch (e) {
      Log.w("自动检查更新失败：$e");
      return;
    }
    settings.markChecked(now());
    var local = localBuild();
    Log.i("最新版本 ${release.tag}（${release.build}），本机 $local");
    if (!UpdateCheckPolicy.shouldPrompt(
      release,
      local,
      skipped: settings.skipped,
      manual: false,
    )) {
      return;
    }
    await _waitForOtherDialogs();
    await promptUpdate(release);
  }

  /// 启动时可能有别的对话框（比如问要不要打开上次的多开窗口），等它关掉
  Future<void> _waitForOtherDialogs() async {
    for (var i = 0; i < 60; i++) {
      if (!(Get.isDialogOpen ?? false) && !(Get.isBottomSheetOpen ?? false)) {
        return;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  /// 手动检查：结果都告诉用户；跳过的版本也提示
  Future<void> checkNow() async {
    if (checking.value) {
      return;
    }
    // 更新时要退出 App，只在主窗口里做
    if (MultiWindow.skips(BackgroundTask.appUpdateCheck)) {
      _report("请在主窗口里检查更新".t);
      return;
    }
    if (config.needsLogin && !settings.loggedIn) {
      _report(const UpdateException(UpdateErrorKind.needLogin).message);
      return;
    }
    checking.value = true;
    AppRelease release;
    try {
      release = await _api.latest(token: _token);
    } on UpdateException catch (e) {
      _report(e.message);
      return;
    } catch (e) {
      Log.w("检查更新失败：$e");
      _report("检查更新失败：{e}".tf({"e": e}));
      return;
    } finally {
      checking.value = false;
    }
    settings.markChecked(now());
    var local = localBuild();
    if (!UpdateCheckPolicy.shouldPrompt(
      release,
      local,
      skipped: settings.skipped,
      manual: true,
    )) {
      _report("已经是最新版本".t);
      return;
    }
    lastResult.value =
        "有新版本 {version}".tf({"version": ReleaseParser.displayVersion(release)});
    await promptUpdate(release);
  }

  void _report(String text) {
    lastResult.value = text;
    SmartDialog.showToast(text);
  }

  /// 弹出更新对话框，按选的处理：立即更新 / 稍后 / 跳过这个版本。
  /// 这台设备没有能在 App 里装的包时，主按钮是“前往下载”
  Future<void> promptUpdate(AppRelease release) async {
    var target = installer();
    var asset = target?.pickAsset(release.assets);
    var choice = await showUpdateDialog(UpdateDialog(
      release: release,
      local: localBuild(),
      asset: asset,
      installNote: asset == null ? "" : target!.installNote,
      pageUrl: _releasePage(release),
      openUrl: openUrl,
    ));
    switch (choice) {
      case UpdateChoice.update:
        await startUpdate(release);
        break;
      case UpdateChoice.skip:
        settings.skip(release);
        break;
      case UpdateChoice.later:
      case null:
        break;
    }
  }

  String _releasePage(AppRelease release) =>
      release.htmlUrl.isNotEmpty ? release.htmlUrl : config.releasesPage;

  /// 立即更新：挑这台设备的安装包，下载、校验，交给平台的安装方式。
  /// 这个平台还不能在 App 里装、或者 Release 里没有合适的包时，打开 Release 网页
  Future<void> startUpdate(AppRelease release) async {
    var target = installer();
    var asset = target?.pickAsset(release.assets);
    if (target == null || asset == null) {
      await openUrl(_releasePage(release));
      return;
    }
    var downloader = UpdateDownloader(dio, config: config, token: _token);
    var plan = DownloadSource.forSetting(
      settings.source.value,
      config,
      settings.customMirror.value,
      // 要登录的仓库的安装包要先换成临时下载链接
      tempLinks: config.needsLogin,
    );
    String directory;
    try {
      directory = await _downloadDirectory(asset.name);
    } catch (e) {
      Log.w("准备下载目录失败：$e");
      await _showFailure(UpdateErrorText.of(e), release);
      return;
    }
    var result = await UpdateDownloadDialog.show(
      (onProgress, cancelToken) => downloader.download(
        asset: asset,
        assets: release.assets,
        sources: plan.sources,
        probe: plan.probe,
        directory: directory,
        onProgress: onProgress,
        cancelToken: cancelToken,
      ),
    );
    if (result is DownloadCancelled) {
      SmartDialog.showToast("已取消下载".t);
      return;
    }
    if (result is! UpdateDownloadResult) {
      Log.w("下载更新失败：$result");
      await _showFailure(_errorText(result), release);
      return;
    }
    Log.i(result.reused
        ? "沿用上次下载的安装包：${asset.name}"
        : "更新已下载（${result.source.label}）：${asset.name}");
    for (var reason in result.skipped) {
      Log.w("没用上的下载源：$reason");
    }
    String? tempUrl;
    try {
      tempUrl = await downloader.tempUrlFor(asset);
    } catch (e) {
      // 只有 iOS 交给别的工具时用得到，换不到也照常装
      Log.w("换临时下载链接失败：$e");
    }
    try {
      await target.install(
        result.path,
        asset,
        version: release.version,
        tempUrl: tempUrl,
      );
    } catch (e, stackTrace) {
      Log.e("安装更新失败：$e", stackTrace);
      await _showFailure(
        "安装失败：{e}".tf({"e": UpdateErrorText.of(e)}),
        release,
      );
    }
  }

  static String _errorText(Object? error) {
    if (error is UpdateException) return error.message;
    if (error is DownloadFailed) return error.message;
    if (error is NoChecksumException) return error.message;
    return "下载失败：{e}".tf({"e": UpdateErrorText.of(error)});
  }

  /// 更新失败的对话框，可以去 GitHub 网页上自己下载
  Future<void> _showFailure(String text, AppRelease release) async {
    if (await Utils.showAlertDialog(
      text,
      title: "更新失败".t,
      confirm: "前往 GitHub 下载".t,
      cancel: "关闭".t,
      selectable: true,
    )) {
      await openUrl(_releasePage(release));
    }
  }

  /// 缓存目录里的 app_update。要下的同名文件留着（上次下好、校验对的直接用，
  /// 见 [UpdateDownloader.downloadFile]），别的旧文件清掉
  Future<String> _downloadDirectory(String keep) async {
    var dir = Directory(
      p.join((await getApplicationCacheDirectory()).path, "app_update"),
    );
    if (await dir.exists()) {
      await for (var entry in dir.list(followLinks: false)) {
        if (p.basename(entry.path) == keep) {
          continue;
        }
        try {
          await entry.delete(recursive: true);
        } catch (e) {
          Log.w("清理旧的更新文件失败：$e");
        }
      }
    }
    await dir.create(recursive: true);
    return dir.path;
  }
}
