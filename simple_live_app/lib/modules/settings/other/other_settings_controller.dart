import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_share.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';
import 'package:intl/intl.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_vault.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class OtherSettingsController extends BaseController {
  RxList<LogFileModel> logFiles = <LogFileModel>[].obs;

  var videoOutputDrivers = {
    "gpu": "gpu",
    "gpu-next": "gpu-next",
    "xv": "xv (X11 only)",
    "x11": "x11 (X11 only)",
    "vdpau": "vdpau (X11 only)",
    "direct3d": "direct3d (Windows only)",
    "sdl": "sdl",
    "dmabuf-wayland": "dmabuf-wayland",
    "vaapi": "vaapi",
    "null": "null",
    "libmpv": "libmpv",
    "mediacodec_embed": "mediacodec_embed (Android only)",
  };

  var audioOutputDrivers = {
    "null": "null (No audio output)",
    "pulse": "pulse (Linux, uses PulseAudio)",
    "pipewire": "pipewire (Linux, via Pulse compatibility or native)",
    "alsa": "alsa (Linux only)",
    "oss": "oss (Linux only)",
    "jack": "jack (Linux/macOS, low-latency audio)",
    "directsound": "directsound (Windows only)",
    "wasapi": "wasapi (Windows only)",
    "winmm": "winmm (Windows only, legacy API)",
    "audiounit": "audiounit (iOS only)",
    "coreaudio": "coreaudio (macOS only)",
    "opensles": "opensles (Android only)",
    "audiotrack": "audiotrack (Android only)",
    "aaudio": "aaudio (Android only)",
    "pcm": "pcm (Cross-platform)",
    "sdl": "sdl (Cross-platform, via SDL library)",
    "openal": "openal (Cross-platform, OpenAL backend)",
    "libao": "libao (Cross-platform, uses libao library)",
    "auto": "auto (Not available)"
  };

  var hardwareDecoder = {
    "no": "no",
    "auto": "auto",
    "auto-safe": "auto-safe",
    "yes": "yes",
    "auto-copy": "auto-copy",
    "d3d11va": "d3d11va",
    "d3d11va-copy": "d3d11va-copy",
    "videotoolbox": "videotoolbox",
    "videotoolbox-copy": "videotoolbox-copy",
    "vaapi": "vaapi",
    "vaapi-copy": "vaapi-copy",
    "nvdec": "nvdec",
    "nvdec-copy": "nvdec-copy",
    "drm": "drm",
    "drm-copy": "drm-copy",
    "vulkan": "vulkan",
    "vulkan-copy": "vulkan-copy",
    "dxva2": "dxva2",
    "dxva2-copy": "dxva2-copy",
    "vdpau": "vdpau",
    "vdpau-copy": "vdpau-copy",
    "mediacodec": "mediacodec",
    "mediacodec-copy": "mediacodec-copy",
    "cuda": "cuda",
    "cuda-copy": "cuda-copy",
    "crystalhd": "crystalhd",
    "rkmpp": "rkmpp"
  };

  @override
  void onInit() {
    loadLogFiles();
    super.onInit();
  }

  void setLogEnable(e) {
    AppSettingsController.instance.setLogEnable(e);
    if (e) {
      Log.initWriter();
      Future.delayed(const Duration(milliseconds: 100), () {
        loadLogFiles();
      });
    } else {
      Log.disposeWriter();
    }
  }

  void loadLogFiles() async {
    var supportDir = await getApplicationSupportDirectory();
    var logDir = Directory("${supportDir.path}/log");
    if (!await logDir.exists()) {
      await logDir.create();
    }
    logFiles.clear();
    await logDir.list().forEach((element) {
      var file = element as File;
      var name = p.basename(file.path);
      var time = file.lastModifiedSync();
      var size = file.lengthSync();
      logFiles.add(LogFileModel(name, file.path, time, size));
    });
    //logFiles 名称倒序
    logFiles.sort((a, b) => b.time.compareTo(a.time));
  }

  void cleanLog() async {
    if (AppSettingsController.instance.logEnable.value) {
      SmartDialog.showToast("请先关闭日志记录".t);
      return;
    }

    var supportDir = await getApplicationSupportDirectory();
    var logDir = Directory("${supportDir.path}/log");
    if (await logDir.exists()) {
      await logDir.delete(recursive: true);
    }
    loadLogFiles();
  }

  void shareLogFile(LogFileModel item) {
    AppShare.share(ShareParams(
      files: [XFile(item.path)],
    ));
  }

  void saveLogFile(LogFileModel item) async {
    await _saveAs(item.path, item.name, 'log');
  }

  /// 和单个日志的“保存”一样：选好保存的位置，把文件复制过去
  Future<void> _saveAs(String path, String name, String extension) async {
    var filePath = await FilePicker.platform.saveFile(
      allowedExtensions: [extension],
      type: FileType.custom,
      fileName: name,
      bytes: Uint8List(0),
    );
    if (filePath != null) {
      var file = File(path);
      await file.copy(filePath);
      SmartDialog.showToast("保存成功".t);
    }
  }

  /// 导出日志：所有日志文件打成一个 zip，再按单个日志的“保存”存下来
  void exportAllLogs() async {
    try {
      // 正在写的那个文件先写到磁盘上
      await Log.flush();
      var supportDir = await getApplicationSupportDirectory();
      var logDir = Directory("${supportDir.path}/log");
      var files = await logDir.exists()
          ? logDir.listSync().whereType<File>().toList()
          : <File>[];
      if (files.isEmpty) {
        SmartDialog.showToast("还没有日志，请先开启调试模式".t);
        return;
      }
      var time = DateFormat("yyyyMMdd-HHmmss").format(DateTime.now());
      var name = "SimpleLive-log-$time.zip";
      var zip = File(p.join((await getTemporaryDirectory()).path, name));
      await zip.writeAsBytes(buildLogZip({
        for (var file in files) p.basename(file.path): file.readAsBytesSync(),
      }));
      await _saveAs(zip.path, name, 'zip');
      loadLogFiles();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导出失败：{e}".tf({"e": e}));
    }
  }

  /// 文件名 → 内容，打成 zip
  static List<int> buildLogZip(Map<String, List<int>> files) {
    var archive = Archive();
    for (var entry in files.entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    return ZipEncoder().encode(archive);
  }

  /// 配置文件第 2 版：账号用 WebDAV 账号密码加密（见 SyncVault），
  /// WebDAV 的连接不导出。第 1 版（含官方版）是全部明文
  static const int _configVersion = 2;

  void exportConfig() async {
    try {
      var storage = LocalStorageService.instance;
      var time = DateTime.now().millisecondsSinceEpoch;
      var (config, accounts) = SyncVault.split(
        storage.settingsBox.toMap(),
        includeLocalOnly: true,
      );
      var key = await SyncVault.keyFor(
        storage.getValue(LocalStorageService.kWebDAVUser, ""),
        storage.getValue(LocalStorageService.kWebDAVPassword, ""),
      );
      // 组装数据
      var data = {
        "type": "simple_live",
        "platform": Platform.operatingSystem,
        "version": _configVersion,
        "time": time,
        "config": config,
        "shield": storage.shieldBox.toMap(),
        if (key != null && accounts.isNotEmpty)
          SyncVault.extraKey: SyncVault.seal(
            accounts,
            key,
            SyncVault.configContext(time),
          ),
      };

      var bytes = Uint8List.fromList(utf8.encode(jsonEncode(data)));

      // FilePicker 直接写入
      var inlineSave = Platform.isAndroid || Platform.isIOS || kIsWeb;

      var path = await FilePicker.platform.saveFile(
        allowedExtensions: ['json'],
        type: FileType.custom,
        fileName: "simple_live_config.json",
        bytes: inlineSave ? bytes : null,
      );

      if (path == null && !kIsWeb) {
        SmartDialog.showToast("已取消保存".t);
        return;
      }

      // 桌面平台需要手动写入
      if (!inlineSave && path != null) {
        await File(path).writeAsBytes(bytes);
      }

      SmartDialog.showToast(
        key == null && accounts.isNotEmpty ? "保存成功。未登录 WebDAV，账号未导出".t : "保存成功".t,
      );
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导出失败：{e}".tf({"e": e}));
    }
  }

  void importConfig() async {
    try {
      var file = await FilePicker.platform.pickFiles(
        allowedExtensions: ['json'],
        type: FileType.custom,
      );
      if (file == null) {
        return;
      }
      var filePath = file.files.single.path!;
      var data = jsonDecode(await File(filePath).readAsString());
      if (data["type"] != "simple_live") {
        SmartDialog.showToast("这不是 SimpleLive 的配置文件".t);
        return;
      }
      // 检查platform
      if (data["platform"] != Platform.operatingSystem &&
          !await Utils.showAlertDialog("这份配置来自别的系统，还要导入吗？".t, title: "系统不一致".t)) {
        return;
      }
      var config = Map<String, dynamic>.from(data["config"]);
      String? warning;
      var version = data["version"];
      if (version is int && version >= 2) {
        warning = await _restoreAccounts(config, data);
      }
      LocalStorageService.instance.settingsBox.clear();
      LocalStorageService.instance.shieldBox.clear();
      LocalStorageService.instance.settingsBox.putAll(config);
      LocalStorageService.instance.shieldBox
          .putAll(data["shield"].cast<String, String>());
      SmartDialog.showToast(
        warning == null ? "导入成功，重启后生效".t : "导入成功，重启后生效。{warning}".tf({"warning": warning}),
      );
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导入失败：{e}".tf({"e": e}));
    }
  }

  /// 第 2 版配置：WebDAV 连接用本机的；账号从加密的一项解开，
  /// 解不开或者文件里没有账号时保留本机登录。返回要额外提示的话
  Future<String?> _restoreAccounts(
      Map<String, dynamic> config, Map data) async {
    var storage = LocalStorageService.instance;
    var local = storage.settingsBox.toMap();
    config.removeWhere(
      (key, _) =>
          SyncVault.connectionKeys.contains(key) ||
          LocalStorageService.isAccountKey(key),
    );
    for (var key in SyncVault.connectionKeys) {
      if (local.containsKey(key)) {
        config[key] = local[key];
      }
    }
    Map<String, dynamic>? accounts;
    String? warning;
    var vault = data[SyncVault.extraKey];
    if (vault is Map) {
      var time = data["time"];
      accounts = await SyncVault.open(
        vault,
        user: storage.getValue(LocalStorageService.kWebDAVUser, ""),
        password: storage.getValue(LocalStorageService.kWebDAVPassword, ""),
        context: SyncVault.configContext(time is int ? time : 0),
      );
      if (accounts == null) {
        warning = "账号无法解密，已保留本机登录".t;
      }
    }
    var (_, localAccounts) = SyncVault.split(local, includeLocalOnly: true);
    config.addAll(accounts ?? localAccounts);
    return warning;
  }

  void resetDefaultConfig() {
    Utils.showAlertDialog("要把所有设置恢复成默认吗？".t).then((value) {
      if (value) {
        LocalStorageService.instance.settingsBox.clear();
        LocalStorageService.instance.shieldBox.clear();
        SmartDialog.showToast("已恢复默认，重启后生效".t);
      }
    });
  }
}

class LogFileModel {
  late String name;
  late String path;
  late DateTime time;
  late int size;
  LogFileModel(this.name, this.path, this.time, this.size);
}
