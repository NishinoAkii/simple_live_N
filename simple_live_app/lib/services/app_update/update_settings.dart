import 'package:get/get.dart';
import 'package:simple_live_app/services/app_update/release_api.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 更新的设置。全部只存本机，不跟着 WebDAV、局域网同步（见 SyncCompat）
class UpdateSettings {
  /// 启动时检查更新（默认开）
  static const String kAutoCheck = "AppUpdateAutoCheck";

  /// 上次检查成功的时间（毫秒）
  static const String kLastCheck = "AppUpdateLastCheck";

  /// 跳过的版本（[ReleaseParser.skipId]）
  static const String kSkipped = "AppUpdateSkipped";

  /// 下载源：[sourceAuto]、[sourceDirect]、[sourceCustom] 或内置镜像的 id
  static const String kSource = "AppUpdateSource";

  /// 自定义镜像的前缀
  static const String kCustomMirror = "AppUpdateCustomMirror";

  /// 翻译源（翻译清单的地址）；空着时用 UpdateConfig.translationSource
  static const String kTranslationSource = "TranslationSource";

  /// 上次检查翻译更新成功的时间（毫秒）
  static const String kTranslationLastCheck = "TranslationLastCheck";

  static const Set<String> storageKeys = {
    kAutoCheck,
    kLastCheck,
    kSkipped,
    kSource,
    kCustomMirror,
    kTranslationSource,
    kTranslationLastCheck,
  };

  static const String sourceAuto = "auto";
  static const String sourceDirect = "direct";
  static const String sourceCustom = "custom";

  final autoCheck = true.obs;
  final source = sourceAuto.obs;
  final customMirror = "".obs;

  /// 填的翻译源；空着时用默认的
  final translationSource = "".obs;

  /// GitHub 登录名；没登录为空
  final githubLogin = "".obs;

  /// GitHub 令牌；没登录为空
  final githubToken = "".obs;

  bool get loggedIn => githubToken.value.isNotEmpty;

  LocalStorageService get _storage => LocalStorageService.instance;

  void load() {
    autoCheck.value = _storage.getValue<bool>(kAutoCheck, true);
    source.value = _storage.getValue<String>(kSource, sourceAuto);
    customMirror.value = _storage.getValue<String>(kCustomMirror, "");
    translationSource.value = _storage.getValue<String>(kTranslationSource, "");
  }

  void setAutoCheck(bool value) {
    autoCheck.value = value;
    _storage.setValue(kAutoCheck, value);
  }

  void setSource(String value) {
    source.value = value;
    _storage.setValue(kSource, value);
  }

  void setCustomMirror(String value) {
    customMirror.value = value;
    _storage.setValue(kCustomMirror, value);
  }

  void setTranslationSource(String value) {
    translationSource.value = value;
    _storage.setValue(kTranslationSource, value);
  }

  int get lastCheck => _storage.getValue<int>(kLastCheck, 0);

  int get translationLastCheck =>
      _storage.getValue<int>(kTranslationLastCheck, 0);

  void markTranslationsChecked(DateTime time) =>
      _storage.setValue(kTranslationLastCheck, time.millisecondsSinceEpoch);

  void markChecked(DateTime time) =>
      _storage.setValue(kLastCheck, time.millisecondsSinceEpoch);

  String get skipped => _storage.getValue<String>(kSkipped, "");

  void skip(AppRelease release) =>
      _storage.setValue(kSkipped, ReleaseParser.skipId(release));


  /// 自定义前缀整理一下：要 http(s) 开头；不是以 /、=、? 结尾的补一个 /。
  /// 不像地址时返回 null，清空时返回空字符串
  static String? normalizePrefix(String text) {
    var value = text.trim();
    if (value.isEmpty) {
      return "";
    }
    var uri = Uri.tryParse(value);
    if (uri == null ||
        !(uri.isScheme("https") || uri.isScheme("http")) ||
        uri.host.isEmpty) {
      return null;
    }
    if (!value.endsWith("/") && !value.endsWith("=") && !value.endsWith("?")) {
      value = "$value/";
    }
    return value;
  }
}

/// 启动时为什么不自动检查
enum AutoCheckBlock {
  /// 多开的副窗口
  secondaryWindow,

  /// 带着链接启动（为了打开某个直播间）
  startedForRoom,

  /// 设置里关掉了
  turnedOff,

  /// 仓库要登录，还没登录 GitHub
  needLogin,

  /// 24 小时内查过了
  checkedRecently,
}

/// 什么时候自动检查、查到以后要不要提示
class UpdateCheckPolicy {
  UpdateCheckPolicy._();

  /// 主窗口启动后等多久再查（不和启动时的请求抢网络）
  static const Duration startDelay = Duration(seconds: 10);

  /// 自动检查最多一天一次
  static const Duration interval = Duration(hours: 24);

  /// 启动时能不能自动检查；能的话返回 null
  static AutoCheckBlock? blocker({
    required bool isSecondary,
    required bool startedForRoom,
    required bool autoCheck,
    required bool needsLogin,
    required bool loggedIn,
    required int lastCheck,
    required DateTime now,
  }) {
    if (isSecondary) {
      return AutoCheckBlock.secondaryWindow;
    }
    if (startedForRoom) {
      return AutoCheckBlock.startedForRoom;
    }
    if (!autoCheck) {
      return AutoCheckBlock.turnedOff;
    }
    if (needsLogin && !loggedIn) {
      return AutoCheckBlock.needLogin;
    }
    var elapsed = now.millisecondsSinceEpoch - lastCheck;
    // 时间往回调过（elapsed < 0）时照常检查
    if (elapsed >= 0 && elapsed < interval.inMilliseconds) {
      return AutoCheckBlock.checkedRecently;
    }
    return null;
  }

  /// 查到 [release] 以后要不要弹出提示：比本机新，而且（自动检查时）没有被跳过。
  /// 手动检查时跳过的版本也提示
  static bool shouldPrompt(
    AppRelease release,
    LocalBuild local, {
    required String skipped,
    required bool manual,
  }) {
    if (!ReleaseParser.isNewer(release, local)) {
      return false;
    }
    return manual || ReleaseParser.skipId(release) != skipped;
  }
}
