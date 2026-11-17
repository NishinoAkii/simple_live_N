import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/webdav_client.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/webdav_archive.dart';
import 'package:simple_live_app/services/webdav_sync_service.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class RemoteSyncWebDAVController extends BaseController {
  // ui
  var passwordVisible = true.obs;
  // ui-用户选择是否同步
  var isSyncFollows = WebDavSyncOptions.isOn(WebDavSyncOptions.follows).obs;
  var isSyncHistories = WebDavSyncOptions.isOn(WebDavSyncOptions.histories).obs;
  var isSyncBlockWord = WebDavSyncOptions.isOn(WebDavSyncOptions.blockWord).obs;
  var isSyncBilibiliAccount =
      WebDavSyncOptions.isOn(WebDavSyncOptions.bilibiliAccount).obs;

  /// 斗鱼、Twitch、Kick、YouTube 账号（本版本专用，官方版不读取）
  var isSyncPlatformAccounts =
      WebDavSyncOptions.isOn(WebDavSyncOptions.platformAccounts).obs;

  /// 直播源：恢复时补上订阅，并从地址安装本机没有的源（本版本专用）
  var isSyncLiveSources =
      WebDavSyncOptions.isOn(WebDavSyncOptions.liveSources).obs;

  /// 自动同步开关
  var autoSync = false.obs;

  /// 自动同步时也同步设置（默认不同步）
  var isAutoSyncSettings = WebDavSyncOptions.autoSettings.obs;

  /// 自动同步出的问题，正常时为空
  RxString get autoSyncStatus => WebDavSyncService.instance.status;

  late DAVClient davClient;
  var user = "--".obs;
  var lastRecoverTime = "--".obs;
  var lastUploadTime = "--".obs;

  @override
  void onInit() {
    doWebDAVInit();
    super.onInit();
  }

  // webDAV 逻辑
  // 初始化webDAV
  void doWebDAVInit() {
    var uri = LocalStorageService.instance
        .getValue(LocalStorageService.kWebDAVUri, "");
    if (uri.isEmpty) {
      notLogin.value = true;
    } else {
      user.value = LocalStorageService.instance
          .getValue(LocalStorageService.kWebDAVUser, "");
      var password = LocalStorageService.instance
          .getValue(LocalStorageService.kWebDAVPassword, "");
      davClient = DAVClient(uri, user.value, password);
      autoSync.value = WebDavSyncService.instance.enabled;
      _loadSyncTimes();
      // 连不上只提示，还是已登录，账号密码也留着：手机不在家时连不上家里的服务器很常见
      _reportIfOffline();
    }
  }

  Future<void> _reportIfOffline() async {
    if (!await davClient.pingCompleter.future) {
      SmartDialog.showToast("连不上 WebDAV".t);
    }
  }

  void _loadSyncTimes() {
    lastRecoverTime.value =
        _timeText(LocalStorageService.kWebDAVLastRecoverTime);
    lastUploadTime.value = _timeText(LocalStorageService.kWebDAVLastUploadTime);
  }

  String _timeText(String key) {
    int time = LocalStorageService.instance.getValue(key, 0);
    return time == 0
        ? "--"
        : Utils.parseTime(DateTime.fromMillisecondsSinceEpoch(time));
  }

  // 检查webDAV登录状态
  Future<void> checkIsLogin() async {
    try {
      // 返回登录结果
      bool value = await davClient.pingCompleter.future;
      notLogin.value = !value;
    } catch (e) {
      Log.e("$e", StackTrace.current);
      notLogin.value = true;
    }
  }

  // WebDAV登录
  void doWebDAVLogin(
      String webDAVUri, String webDAVUser, String webDAVPassword) async {
    // 确认登录
    davClient = DAVClient(webDAVUri, webDAVUser, webDAVPassword);
    await checkIsLogin();
    if (!notLogin.value) {
      // 保存到本地
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVUri, webDAVUri);
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVUser, webDAVUser);
      user.value = webDAVUser;
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVPassword, webDAVPassword);
      Get.back();
      SmartDialog.showToast("登录成功".t);
    } else {
      SmartDialog.showToast("WebDAV 登录失败，请检查账号和密码".t);
    }
  }

  // WebDAV登出
  @override
  Future<void> onLogout() async {
    var result =
        await Utils.showAlertDialog("确定要退出 WebDAV 账号吗？".t, title: "退出登录".t);
    if (result) {
      // 清除本地账号数据
      LocalStorageService.instance.setValue(LocalStorageService.kWebDAVUri, "");
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVUser, "");
      LocalStorageService.instance
          .setValue(LocalStorageService.kWebDAVPassword, "");
      await WebDavSyncService.instance.onLogout();
      autoSync.value = false;
      notLogin.value = true;
    }
  }

  // webDAV上传到云端
  Future<void> doWebDAVUpload() async {
    SmartDialog.showLoading(msg: "正在上传到云端".t);
    try {
      await WebDavSyncService.instance.uploadNow(davClient);
      SmartDialog.showToast("上传成功".t);
      DateTime uploadTime = DateTime.now();
      lastUploadTime.value = Utils.parseTime(uploadTime);
      LocalStorageService.instance.setValue(
          LocalStorageService.kWebDAVLastUploadTime,
          uploadTime.millisecondsSinceEpoch);
    } catch (e, stackTrace) {
      Log.e("WebDAV 上传失败：$e", stackTrace);
      SmartDialog.showToast("上传失败：{e}".tf({"e": e}));
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  // webDAV恢复到本地
  void doWebDAVRecovery() async {
    SmartDialog.showLoading(msg: "正在恢复到本地".t);
    try {
      var warning = await WebDavSyncService.instance.recoverNow(davClient);
      SmartDialog.showToast(warning == null ? '恢复完成'.t : '恢复完成。{warning}'.tf({"warning": warning}));
      DateTime recoverTime = DateTime.now();
      lastRecoverTime.value = Utils.parseTime(recoverTime);
      LocalStorageService.instance.setValue(
          LocalStorageService.kWebDAVLastRecoverTime,
          recoverTime.millisecondsSinceEpoch);
    } catch (e, stackTrace) {
      Log.e('WebDAV 恢复失败：$e', stackTrace);
      SmartDialog.showToast('恢复失败：{e}'.tf({"e": e}));
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  // 自动同步开关
  void changeAutoSync(bool value) async {
    var service = WebDavSyncService.instance;
    if (!value) {
      await service.disable();
      autoSync.value = false;
      return;
    }
    SmartDialog.showLoading(msg: "正在同步".t);
    try {
      var result = await service.enable();
      autoSync.value = true;
      var text = WebDavSyncService.pullToast(result);
      if (text != null) {
        SmartDialog.showToast(text);
      }
      _loadSyncTimes();
    } catch (e, stackTrace) {
      Log.e("打开 WebDAV 自动同步失败：$e", stackTrace);
      SmartDialog.showToast("{errorText}，没有打开".tf({"errorText": WebDavSyncService.errorText(e)}));
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  void changeAutoSyncSettings() {
    isAutoSyncSettings.value = !isAutoSyncSettings.value;
    LocalStorageService.instance.setValue(
      LocalStorageService.kWebDAVAutoSyncSettings,
      isAutoSyncSettings.value,
    );
  }

  // ui控制--密码可见控制
  void changePasswordVisible() {
    passwordVisible.value = !passwordVisible.value;
  }

  void changeIsSyncFollows() {
    isSyncFollows.value = !isSyncFollows.value;
    WebDavSyncOptions.set(WebDavSyncOptions.follows, isSyncFollows.value);
  }

  void changeIsSyncHistories() {
    isSyncHistories.value = !isSyncHistories.value;
    WebDavSyncOptions.set(WebDavSyncOptions.histories, isSyncHistories.value);
  }

  void changeIsSyncBlockWord() {
    isSyncBlockWord.value = !isSyncBlockWord.value;
    WebDavSyncOptions.set(WebDavSyncOptions.blockWord, isSyncBlockWord.value);
  }

  void changeIsSyncBilibiliAccount() {
    isSyncBilibiliAccount.value = !isSyncBilibiliAccount.value;
    WebDavSyncOptions.set(
        WebDavSyncOptions.bilibiliAccount, isSyncBilibiliAccount.value);
  }

  void changeIsSyncPlatformAccounts() {
    isSyncPlatformAccounts.value = !isSyncPlatformAccounts.value;
    WebDavSyncOptions.set(
        WebDavSyncOptions.platformAccounts, isSyncPlatformAccounts.value);
  }

  void changeIsSyncLiveSources() {
    isSyncLiveSources.value = !isSyncLiveSources.value;
    WebDavSyncOptions.set(
        WebDavSyncOptions.liveSources, isSyncLiveSources.value);
  }
}
