import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/active_players.dart';
import 'package:simple_live_app/app/exit_guard.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/webdav_client.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_backup_format.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_app/services/sync_vault.dart';
import 'package:simple_live_app/services/webdav_archive.dart';
import 'package:simple_live_app/services/webdav_auto_sync.dart';
import 'package:window_manager/window_manager.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// WebDAV 自动同步：启动时比较时间戳，云端新就拉取、本机新就留着；
/// 改动后过一会儿上传（和 Venera 一样不等退出），退出时再补一次。
///
/// 开关默认关，每台设备各自设置。桌面端退出时先藏窗口再上传（mac 的 Cmd+Q 不经过窗口，
/// 走退出请求）。手机上 App 随时可能被划掉或者被系统杀掉，收不到退出的通知，所以失去焦点
/// 就上传（iOS 上向系统要一段后台时间），回到前台时再比较一次；没传成的下次启动时补上。
class WebDavSyncService extends GetxService
    with WidgetsBindingObserver, WindowListener
    implements WebDavAutoSyncHost {
  static WebDavSyncService get instance => Get.find<WebDavSyncService>();
  static bool get registered => Get.isRegistered<WebDavSyncService>();

  /// 退出时最多等这么久，连不上也不能让进程一直留着
  static const Duration _exitBudget = Duration(seconds: 12);

  /// 手机上在后台待了这么久，回到前台时再比较一次
  @visibleForTesting
  static Duration resumeCheckAfter = const Duration(minutes: 1);

  /// 改动后过这么久上传，连续改动只传一次
  @visibleForTesting
  static Duration uploadDelay = const Duration(seconds: 20);

  /// 测试时按手机的流程走
  @visibleForTesting
  static bool? debugIsDesktop;

  /// 测试时不弹提示
  @visibleForTesting
  static void Function(String text) showToastText = _defaultToast;

  static void _defaultToast(String text) => SmartDialog.showToast(text);

  static const MethodChannel _backgroundTask =
      MethodChannel("simple_live/background_task");

  static bool get _isDesktop =>
      debugIsDesktop ??
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  late final WebDavAutoSync _sync = WebDavAutoSync(this);
  final List<StreamSubscription> _subscriptions = [];

  /// 自动同步出的问题（连不上、没有覆盖），给同步页面显示；正常时为空
  final status = "".obs;

  Future<void> _tail = Future.value();
  bool _ready = false;
  bool _checking = false;
  bool _changedDuringCheck = false;
  int _quietDepth = 0;
  bool _closing = false;
  DateTime? _backgroundAt;
  Timer? _uploadTimer;
  Future<void>? _pushing;
  Future<void>? _flushing;

  LocalStorageService get _storage => LocalStorageService.instance;

  bool get enabled =>
      _storage.getValue(LocalStorageService.kWebDAVAutoSync, false) &&
      _storage.getValue(LocalStorageService.kWebDAVUri, "").isNotEmpty;

  /// 多开的副窗口里不自动同步（数据是快照，改动交给主窗口）
  bool get _passive => MultiWindow.skips(BackgroundTask.webdavAutoSync);

  @override
  void onInit() {
    super.onInit();
    if (_passive) {
      return;
    }
    status.value =
        _storage.getValue(LocalStorageService.kWebDAVAutoSyncStatus, "");
    _seedDataTime();
    // 开关关着时也记时间戳：关了一段时间再打开，这期间的改动也要算
    var db = DBService.instance;
    for (var stream in [
      db.followBox.watch(),
      db.tagBox.watch(),
      db.historyBox.watch(),
      _storage.shieldBox.watch(),
      // 永久屏蔽的人和备注
      if (ChatUsersService.maybeInstance case var users?) users.syncedChanges,
    ]) {
      _subscriptions.add(stream.listen((_) => _touch()));
    }
    _storage.onSettingChanged = (key) {
      if (SyncCompat.isAutoSyncedSetting(
        key,
        syncSettings: WebDavSyncOptions.autoSettings,
      )) {
        _touch();
      }
    };
    WidgetsBinding.instance.addObserver(this);
    if (_isDesktop) {
      windowManager.addListener(this);
      _updatePreventClose();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => onFirstFrame());
  }

  @visibleForTesting
  void onFirstFrame() {
    // 第一帧之前的写入都是启动时程序自己做的，不算用户改了存档，
    // 不然每次启动本机都比云端新，永远拉不到别的设备的内容
    _ready = true;
    if (!enabled) {
      return;
    }
    _checking = true;
    Future.delayed(const Duration(seconds: 1), () {
      unawaited(pullIfNewer(showToast: true));
    });
  }

  /// 升级到这个版本后第一次运行，或者新装：用已有数据里最新的时间当时间戳。
  /// 新装的设备是 0，比云端旧，打开自动同步时会拉取
  void _seedDataTime() {
    if (_storage.settingsBox.containsKey(LocalStorageService.kWebDAVDataTime)) {
      return;
    }
    var db = DBService.instance;
    var seed = [
      _storage.getValue(LocalStorageService.kWebDAVLastUploadTime, 0),
      _storage.getValue(LocalStorageService.kWebDAVLastRecoverTime, 0),
      for (var e in db.followBox.values) e.addTime.millisecondsSinceEpoch,
      for (var e in db.historyBox.values) e.updateTime.millisecondsSinceEpoch,
    ].fold<int>(0, math.max);
    dataTime = seed;
  }

  void _touch() {
    if (!_ready || _quietDepth > 0) {
      return;
    }
    if (_checking) {
      _changedDuringCheck = true;
      return;
    }
    dataTime = nextWebDavDataTime(
      dataTime,
      DateTime.now().millisecondsSinceEpoch,
    );
    if (enabled) {
      _uploadTimer?.cancel();
      _uploadTimer = Timer(
        uploadDelay,
        () => unawaited(pushIfNewer(showError: true)),
      );
    }
  }

  /// 同步自己写入数据时不算本机有改动
  Future<T> _quietly<T>(Future<T> Function() action) async {
    _quietDepth++;
    try {
      return await action();
    } finally {
      // Hive 的变化事件是异步发出的，等它们发完
      await Future.delayed(Duration.zero);
      _quietDepth--;
    }
  }

  /// 同步操作一个接一个做：打包用同一个临时文件夹，也不能边恢复边上传
  Future<T> _enqueue<T>(Future<T> Function() task) {
    var result = _tail.then((_) => task());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  // ---------------------------------------------------------------------
  // 开关
  // ---------------------------------------------------------------------

  /// 打开自动同步：先比较一次，连不上就不打开（抛出异常）。不然新设备可能在连不上时
  /// 改了点东西，时间戳变新，之后拿几乎是空的存档盖掉云端
  Future<WebDavPullResult> enable() async {
    var result = await _enqueue(_pull);
    await _storage.setValue(LocalStorageService.kWebDAVAutoSync, true);
    _updatePreventClose();
    return result;
  }

  Future<void> disable() async {
    await _storage.setValue(LocalStorageService.kWebDAVAutoSync, false);
    _updatePreventClose();
  }

  /// 退出 WebDAV 账号：下次登录的可能是另一个服务器
  Future<void> onLogout() async {
    await disable();
    syncedTime = 0;
    seenRemoteVersion = null;
    _setStatus("");
  }

  void _updatePreventClose() {
    if (_isDesktop) {
      ExitGuard.hold(ExitGuard.webdav, enabled);
    }
  }

  // ---------------------------------------------------------------------
  // 拉取和上传
  // ---------------------------------------------------------------------

  /// 比较时间戳，云端更新就拉取。出错只记下来，不打扰（比如手机不在家、连不上家里的服务器）
  Future<void> pullIfNewer({bool showToast = false}) async {
    if (!enabled || _passive) {
      _checking = false;
      return;
    }
    try {
      var result = await _enqueue(_pull);
      if (result == WebDavPullResult.localNewer ||
          result == WebDavPullResult.noRemote) {
        // 上次退出时没传成（被系统杀掉、当时连不上），现在补上
        unawaited(pushIfNewer());
      }
      if (!showToast) {
        return;
      }
      var text = pullToast(result);
      if (text != null) {
        showToastText(text);
      }
    } catch (e, stackTrace) {
      Log.e("WebDAV 自动同步失败：$e", stackTrace);
      if (showToast) {
        showToastText(errorText(e));
      }
    }
  }

  Future<WebDavPullResult> _pull() async {
    _checking = true;
    _restoreWarning = null;
    try {
      var result = await _sync.pullIfNewer();
      _setStatus(
        result == WebDavPullResult.remoteEmpty
            ? _remoteEmptyText
            : _restoreWarning ?? "",
      );
      if (result == WebDavPullResult.pulled) {
        _storage.setValue(
          LocalStorageService.kWebDAVLastRecoverTime,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
      return result;
    } catch (e) {
      _setStatus(errorText(e));
      rethrow;
    } finally {
      _checking = false;
      // 比较的时候已经进了直播间：看过的也要传上去
      if (_changedDuringCheck) {
        _changedDuringCheck = false;
        _touch();
      }
    }
  }

  /// 本机有新内容就上传。出错时时间戳不变，下次再传。
  /// 失去焦点、切到后台会接连触发，正在传时不用再排一次
  Future<void> pushIfNewer({bool showError = false}) {
    if (!enabled || _passive) {
      return Future.value();
    }
    return _pushing ??= _push(showError).whenComplete(() => _pushing = null);
  }

  Future<void> _push(bool showError) async {
    var task = await _beginBackgroundTime();
    try {
      var result = await _enqueue(_sync.pushIfNewer);
      if (result == WebDavPushResult.nothingNew) {
        return;
      }
      _setStatus(result == WebDavPushResult.localEmpty ? _localEmptyText : "");
      if (result == WebDavPushResult.uploaded) {
        _storage.setValue(
          LocalStorageService.kWebDAVLastUploadTime,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
    } catch (e, stackTrace) {
      Log.e("WebDAV 自动上传失败：$e", stackTrace);
      _setStatus(errorText(e));
      if (showError) {
        showToastText(errorText(e));
      }
    } finally {
      await _endBackgroundTime(task);
    }
  }

  /// iOS 切到后台后几秒就被挂起，要向系统要一段时间才传得完（最多约 30 秒）。
  /// 要不到也照样传，没传完的下次补上
  Future<int?> _beginBackgroundTime() async {
    if (!Platform.isIOS) {
      return null;
    }
    try {
      return await _backgroundTask.invokeMethod<int>("begin");
    } catch (e) {
      Log.w("申请后台时间失败：$e");
      return null;
    }
  }

  Future<void> _endBackgroundTime(int? task) async {
    if (task == null) {
      return;
    }
    try {
      await _backgroundTask.invokeMethod("end", task);
    } catch (e) {
      Log.w("结束后台时间失败：$e");
    }
  }

  /// 退出之前：声音先停，上传完（或者超时）再走。
  /// mac 上关窗口之后还会再来一次退出请求，只做一遍
  Future<void> flushBeforeExit() => _flushing ??= _flush();

  Future<void> _flush() async {
    if (!enabled || _passive) {
      return;
    }
    await ActivePlayers.pauseAll();
    try {
      await pushIfNewer().timeout(_exitBudget);
    } catch (e) {
      Log.w("退出时上传超时：$e");
    }
    await _storage.settingsBox.flush();
  }

  /// 手动上传：用户明确要传，当作本机有了新内容
  Future<void> uploadNow(DAVClient client) => _enqueue(() async {
        var stamp = nextWebDavDataTime(
          dataTime,
          DateTime.now().millisecondsSinceEpoch,
        );
        dataTime = stamp;
        var zip = WebDavArchive.build(stamp, key: await _vaultKey());
        await client.backup(Uint8List.fromList(zip));
        syncedTime = stamp;
      });

  /// 手动恢复：恢复完两边算对齐了。返回要额外提示的话（账号解不开时）
  Future<String?> recoverNow(DAVClient client) => _enqueue(() async {
        final data = await client.recovery();
        final files = await SyncBackupFormat.decodeZip(data);
        if (files.isEmpty) {
          throw "云端没有备份，或者备份格式不对".t;
        }
        var backup = SyncBackupFormat(files);
        String? warning;
        await _quietly(
          () => WebDavArchive.restore(
            backup,
            vaultUser: _davUser,
            vaultPassword: _davPassword,
            onWarning: (text) => warning = text,
          ),
        );
        var time = backup.dataTime ??
            (await client.backupTime())?.millisecondsSinceEpoch ??
            DateTime.now().millisecondsSinceEpoch;
        dataTime = time;
        syncedTime = time;
        return warning;
      });

  void _setStatus(String text) {
    var value = text.isEmpty ? "" : "${Utils.parseTime(DateTime.now())} $text";
    status.value = value;
    _storage.setValue(LocalStorageService.kWebDAVAutoSyncStatus, value);
  }

  static String errorText(Object e) {
    if (e is DioException) {
      var code = e.response?.statusCode;
      return code == null ? "连不上 WebDAV".t : "WebDAV 出错（{code}）".tf({"code": code});
    }
    if (e is SocketException || e is TimeoutException) {
      return "连不上 WebDAV".t;
    }
    var text = e.toString();
    return text.length > 60 ? "${text.substring(0, 60)}…" : text;
  }

  static String get _remoteEmptyText => "云端关注列表是空的，没有覆盖本机".t;
  static String get _localEmptyText => "本机关注列表是空的，没有覆盖云端".t;

  /// 比较之后要提示的话，其它情况不打扰
  static String? pullToast(WebDavPullResult result) {
    switch (result) {
      case WebDavPullResult.pulled:
        return "已同步云端的存档".t;
      case WebDavPullResult.remoteEmpty:
        return _remoteEmptyText;
      default:
        return null;
    }
  }

  // ---------------------------------------------------------------------
  // WebDavAutoSyncHost
  // ---------------------------------------------------------------------

  @override
  int get dataTime => _storage.getValue(LocalStorageService.kWebDAVDataTime, 0);

  @override
  set dataTime(int value) =>
      _storage.setValue(LocalStorageService.kWebDAVDataTime, value);

  @override
  int get syncedTime =>
      _storage.getValue(LocalStorageService.kWebDAVSyncedTime, 0);

  @override
  set syncedTime(int value) =>
      _storage.setValue(LocalStorageService.kWebDAVSyncedTime, value);

  @override
  Future<String?> remoteVersion() => _client().backupVersion();

  @override
  String? get seenRemoteVersion {
    var value = _storage.getValue(LocalStorageService.kWebDAVRemoteVersion, "");
    return value.isEmpty ? null : value;
  }

  @override
  set seenRemoteVersion(String? value) => _storage.setValue(
        LocalStorageService.kWebDAVRemoteVersion,
        value ?? "",
      );

  DAVClient _client() => DAVClient(
        _storage.getValue(LocalStorageService.kWebDAVUri, ""),
        _davUser,
        _davPassword,
      );

  String get _davUser => _storage.getValue(LocalStorageService.kWebDAVUser, "");

  String get _davPassword =>
      _storage.getValue(LocalStorageService.kWebDAVPassword, "");

  /// 加密账号的密钥（由 WebDAV 账号密码算出，每次运行只算一次）
  Future<SyncVaultKey?> _vaultKey() => SyncVault.keyFor(_davUser, _davPassword);

  /// 自动同步时账号没解开，拉取完显示在状态里
  String? _restoreWarning;

  @override
  Future<WebDavRemoteArchive?> fetchRemote() async {
    var client = _client();
    var data = await client.readBackup();
    if (data == null) {
      return null;
    }
    var files = await SyncBackupFormat.decodeZip(data);
    if (files.isEmpty) {
      throw "云端的备份打不开".t;
    }
    var backup = SyncBackupFormat(files);
    // 旧版和官方版传的备份没有时间戳，按文件的修改时间算
    var time = backup.dataTime ??
        (await client.backupTime())?.millisecondsSinceEpoch ??
        1;
    return WebDavRemoteArchive(backup, time);
  }

  @override
  Future<String?> uploadRemote(List<int> zip) async {
    var client = _client();
    var bytes = Uint8List.fromList(zip);
    await client.backup(bytes);
    try {
      await client.keepDailyCopy(bytes, DateTime.now());
    } catch (e) {
      // 只是多留一份，主存档已经传上去了
      Log.w("保存云端每日存档失败：$e");
    }
    try {
      var version = await client.backupVersion();
      return version != null && version.endsWith("|${zip.length}")
          ? version
          : null;
    } catch (_) {
      // 已经传上去了，只是没读到版本，下次多下载一次而已
      return null;
    }
  }

  @override
  Future<List<int>> buildArchive(int dataTime) async =>
      WebDavArchive.build(dataTime, key: await _vaultKey());

  @override
  Future<bool> restoreArchive(SyncBackupFormat backup) => _quietly(
        () => WebDavArchive.restore(
          backup,
          auto: true,
          baseTime: syncedTime,
          vaultUser: _davUser,
          vaultPassword: _davPassword,
          onWarning: (text) => _restoreWarning = text,
        ),
      );

  @override
  Future<void> keepSafetyCopy() async {
    try {
      var zip = WebDavArchive.build(dataTime, key: await _vaultKey());
      var dir = await getApplicationSupportDirectory();
      await File(p.join(dir.path, "webdav_before_pull.zip"))
          .writeAsBytes(zip, flush: true);
    } catch (e, stackTrace) {
      Log.e("保存同步前的存档失败：$e", stackTrace);
    }
  }

  @override
  bool get guardFollows => WebDavSyncOptions.isOn(WebDavSyncOptions.follows);

  @override
  int get localFollowCount => DBService.instance.followBox.length;

  // ---------------------------------------------------------------------
  // 退出和切到后台
  // ---------------------------------------------------------------------

  @override
  void onWindowClose() async {
    // 没拦截关闭时窗口自己会关；拦截了就一定要关掉，不管上传成不成功
    if (_closing || !await windowManager.isPreventClose()) {
      return;
    }
    _closing = true;
    try {
      await windowManager.hide();
      // 先关掉多开窗口，它们最后交来的改动也算进上传的存档
      await ExitGuard.runBeforeClose();
      await flushBeforeExit();
    } catch (e, stackTrace) {
      Log.e("退出时同步失败：$e", stackTrace);
    } finally {
      await _closeWindow();
    }
  }

  /// Windows 上 destroy 只是退出消息循环：窗口还在，引擎就开始拆除，
  /// 这时窗口消息转给已经销毁的视图会崩溃。所以走普通的关闭流程
  Future<void> _closeWindow() async {
    if (Platform.isWindows) {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } else {
      await windowManager.destroy();
    }
  }

  /// mac 的 Cmd+Q、关窗口之后的 terminate 都走这里
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await flushBeforeExit();
    return AppExitResponse.exit;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDesktop || !enabled) {
      return;
    }
    if (state == AppLifecycleState.inactive) {
      // 上划到多任务界面再划掉时，可能等不到 paused
      unawaited(pushIfNewer());
    } else if (state == AppLifecycleState.paused) {
      _backgroundAt = DateTime.now();
      unawaited(pushIfNewer());
    } else if (state == AppLifecycleState.resumed) {
      var at = _backgroundAt;
      _backgroundAt = null;
      if (at != null && DateTime.now().difference(at) >= resumeCheckAfter) {
        unawaited(pullIfNewer(showToast: true));
      }
    }
  }

  @override
  void onClose() {
    for (var subscription in _subscriptions) {
      subscription.cancel();
    }
    _uploadTimer?.cancel();
    _storage.onSettingChanged = null;
    WidgetsBinding.instance.removeObserver(this);
    if (_isDesktop) {
      windowManager.removeListener(this);
    }
    super.onClose();
  }
}
