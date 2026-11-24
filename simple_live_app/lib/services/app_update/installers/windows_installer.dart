import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Brightness, Color, Theme;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/modules/settings/update/update_dialogs.dart';
import 'package:simple_live_app/services/app_update/installers/install_common.dart';
import 'package:simple_live_app/services/app_update/installers/windows_native.dart';
import 'package:simple_live_app/services/app_update/installers/windows_update_script.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';
import 'package:url_launcher/url_launcher.dart';

/// 这个 App 是怎么装上的
enum WindowsInstallKind {
  /// 压缩包解压出来的：App 自己换文件
  zip,

  /// 签名的 MSIX 包：交给系统的应用安装程序
  msix,

  /// 安装程序（exe、msi）装的：运行新的安装程序
  setup,
}

/// 一次更新（或回退）交给脚本的参数。只拼参数、不碰文件，测试直接用
class WindowsUpdatePlan {
  /// install 或 rollback
  final String mode;
  final String installDir;

  /// 正在运行的 exe：等它的进程退出，出错时重新打开它
  final String exePath;

  /// 下载的安装包（回退时为空）：脚本解压到 [newDir]，装完删掉
  final String zipFile;

  /// 新版本解压到哪里（回退时为空）
  final String newDir;

  /// 新版本里要打开的 exe 文件名
  final String newExe;
  final String backupRoot;

  /// 当前版本号，备份文件夹用它命名（回退时为空）
  final String oldVersion;
  final String logFile;
  final String statusFile;

  /// 脚本写的进度、窗口里的字；不显示窗口时为空
  final String progressFile;
  final String textFile;

  /// 显示进度窗口，装完在窗口里问要不要打开 App
  final bool ui;

  /// 安装文件夹写不进去：用管理员身份运行（弹一次 UAC）
  final bool elevate;

  /// 测试用：不等进程退出，也不打开 App
  final bool dryRun;
  final int timeoutSec;

  const WindowsUpdatePlan({
    required this.mode,
    required this.installDir,
    required this.exePath,
    this.zipFile = "",
    this.newDir = "",
    this.newExe = WindowsInstaller.exeName,
    required this.backupRoot,
    this.oldVersion = "",
    required this.logFile,
    required this.statusFile,
    this.progressFile = "",
    this.textFile = "",
    this.ui = false,
    this.elevate = false,
    this.dryRun = false,
    this.timeoutSec = 120,
  });

  /// 脚本的参数：所有路径都从这里传，脚本文本里不写路径
  List<String> scriptArgs() => [
        "-Mode",
        mode,
        "-InstallDir",
        _trimDir(installDir),
        "-ExePath",
        exePath,
        if (zipFile.isNotEmpty) ...["-ZipFile", zipFile],
        if (newDir.isNotEmpty) ...["-NewDir", _trimDir(newDir)],
        "-NewExe",
        newExe,
        "-BackupRoot",
        _trimDir(backupRoot),
        if (oldVersion.isNotEmpty) ...["-OldVersion", oldVersion],
        "-LogFile",
        logFile,
        "-StatusFile",
        statusFile,
        if (progressFile.isNotEmpty) ...["-ProgressFile", progressFile],
        if (textFile.isNotEmpty) ...["-TextFile", textFile],
        "-TimeoutSec",
        "$timeoutSec",
        if (ui) "-Ui",
        if (elevate) "-Elevate",
        if (dryRun) "-DryRun",
      ];

  /// powershell.exe 的完整参数
  List<String> powershellArgs(String scriptPath) => [
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-WindowStyle",
        "Hidden",
        "-File",
        scriptPath,
        ...scriptArgs(),
      ];

  /// 文件夹结尾不带反斜杠：脚本提权时要给路径加引号，结尾的反斜杠会把引号转义掉
  static String _trimDir(String path) {
    var text = path.replaceAll(RegExp(r"[\\/]+$"), "");
    // D:\ 这种根目录留着
    return text.endsWith(":") ? "$text\\" : text;
  }
}

/// 回退用的备份
class WindowsBackup {
  final String dir;

  /// 备份的版本号（文件夹名）
  final String version;
  const WindowsBackup(this.dir, this.version);
}

/// Windows。压缩包解压出来的：下载 zip，问是否现在安装，写一个 PowerShell 脚本并启动它；
/// 脚本解压、等 App 退出、备份旧文件、换上新文件，出错就从备份还原，装完删掉 zip。
/// 进度显示在脚本的窗口里，装完在窗口里选要不要打开 App。安装文件夹写不进去时
/// 脚本用管理员身份运行。只动当前 App 所在的文件夹，装在别处的 SimpleLive 不受影响。
///
/// MSIX、安装程序装的：打开下载的安装包，由 Windows 安装
class WindowsInstaller implements UpdateInstaller, UpdateInstallConfirm {
  WindowsInstaller({WindowsInstallKind? kind}) : _kind = kind;

  static const String exeName = "simple_live_app.exe";
  static const String backupFolderName = "SimpleLive-backup";
  static const String scriptName = "simple_live_updater.ps1";

  final WindowsInstallKind? _kind;

  /// 读一次就行：运行中不会变
  static final WindowsInstallKind _detected = Platform.isWindows
      ? kindOf(
          packageName: WindowsNative.packageFullName(),
          installDir: installDir,
        )
      : WindowsInstallKind.zip;

  WindowsInstallKind get kind => _kind ?? _detected;

  /// 有包名的是 MSIX；安装文件夹里有卸载程序（Inno Setup 的 unins000.exe、NSIS 的 uninstall.exe）的
  /// 是安装程序装的；别的是压缩包
  @visibleForTesting
  static WindowsInstallKind kindOf({
    required String? packageName,
    required String installDir,
  }) {
    if (packageName != null && packageName.isNotEmpty) {
      return WindowsInstallKind.msix;
    }
    var uninstaller = RegExp(
      r"^(unins\d{3}|uninst|uninstall(er)?)\.exe$",
      caseSensitive: false,
    );
    try {
      for (var entry in Directory(installDir).listSync(followLinks: false)) {
        if (entry is File && uninstaller.hasMatch(p.basename(entry.path))) {
          return WindowsInstallKind.setup;
        }
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return WindowsInstallKind.zip;
  }

  @override
  bool get canInstallInApp => true;

  @override
  String get installNote => kind == WindowsInstallKind.msix
      ? "下载完成后打开 Windows 安装程序".t
      : "下载完成后询问是否安装，安装时 App 会退出".t;

  @override
  ReleaseAsset? pickAsset(List<ReleaseAsset> assets) => pickAssetBySuffix(
        // 同一个 Release 上的 Windows 7 安装包（…-win7-windows-x64.zip）不算
        [
          for (var asset in assets)
            if (!asset.name.toLowerCase().contains("-win7-")) asset,
        ],
        switch (kind) {
          WindowsInstallKind.zip => const ["-windows-x64.zip"],
          WindowsInstallKind.msix => const [
              "-windows-x64.msixbundle",
              "-windows-x64.msix",
              ".msixbundle",
              ".msix",
            ],
          // 没有安装程序时用压缩包：文件夹里的卸载程序可能是别的软件的
          WindowsInstallKind.setup => const [
              "-windows-x64-setup.exe",
              "-windows-x64.exe",
              "-windows-x64.msi",
              "-setup.exe",
              ".msi",
              "-windows-x64.zip",
            ],
        },
      );

  static bool _isZip(ReleaseAsset asset) =>
      asset.name.toLowerCase().endsWith(".zip");

  /// 现在安装吗：压缩包写明装到哪里、要不要管理员权限
  @override
  Future<bool> confirmInstall(String version, ReleaseAsset asset) async {
    checkDesktopUpdateAllowed();
    if (!_isZip(asset)) {
      return UpdateInstallDialog.show(
        version: version,
        lines: ["将打开 Windows 安装程序".t],
      );
    }
    var dir = installDir;
    _checkInstallDir(dir);
    return UpdateInstallDialog.show(
      version: version,
      lines: confirmLines(
        installDir: dir,
        elevate: !await _canWrite(dir, backupRootFor(dir)),
        windows: MultiWindow.openCount.value,
      ),
    );
  }

  @visibleForTesting
  static List<String> confirmLines({
    required String installDir,
    required bool elevate,
    required int windows,
  }) =>
      [
        "安装位置：{path}".tf({"path": installDir}),
        if (elevate) "需要管理员权限，安装时由系统询问".t,
        windows > 0
            ? "安装时 Simple Live N 和多开窗口会退出，完成后可选择是否重新打开".t
            : "安装时 Simple Live N 会退出，完成后可选择是否重新打开".t,
      ];

  /// 当前 App 所在的文件夹
  static String get installDir => p.dirname(Platform.resolvedExecutable);

  /// 这个安装的备份放在安装文件夹旁边：SimpleLive-backup\<安装文件夹名>\<版本号>\。
  /// 按文件夹名分开，同一个上级目录里装的另一份 SimpleLive 不会被清掉
  static String backupRootFor(String installDir) {
    var dir = p.windows.normalize(installDir);
    return p.windows.join(
      p.windows.dirname(dir),
      backupFolderName,
      p.windows.basename(dir),
    );
  }

  /// 脚本的字节：只能是 ASCII（有别的字符时 ascii.encode 会报错），换行用 CRLF
  static List<int> scriptBytes() => ascii.encode(
        windowsUpdateScript.replaceAll("\r\n", "\n").replaceAll("\n", "\r\n"),
      );

  static Future<File> writeScript(Directory dir) async {
    var file = File(p.join(dir.path, scriptName));
    await file.writeAsBytes(scriptBytes(), flush: true);
    return file;
  }

  static String get _powershell => p.join(
        Platform.environment["SystemRoot"] ?? r"C:\Windows",
        "System32",
        "WindowsPowerShell",
        "v1.0",
        "powershell.exe",
      );

  /// 上一次更新留下的备份；没有时为 null
  static Future<WindowsBackup?> findBackup() async {
    if (!Platform.isWindows || !kReleaseMode) {
      return null;
    }
    return findBackupIn(backupRootFor(installDir));
  }

  @visibleForTesting
  static Future<WindowsBackup?> findBackupIn(String root) async {
    var dir = Directory(root);
    if (!await dir.exists()) {
      return null;
    }
    // 和脚本的 Find-Backup 一样：current.txt 写着哪一份，没有时找一份完整的
    Future<bool> finished(String path) async =>
        !path.endsWith(".partial") &&
        !await File("$path.building").exists() &&
        await File(p.join(path, exeName)).exists();
    // 同一个版本的第二份备份叫 1.27.4-2
    WindowsBackup backup(String path) => WindowsBackup(
        path, p.basename(path).replaceFirst(RegExp(r"-\d+$"), ""));
    try {
      var name = (await File(p.join(root, "current.txt")).readAsString()).trim();
      if (RegExp(r"^[0-9A-Za-z._+-]+$").hasMatch(name)) {
        var path = p.join(root, name);
        if (await finished(path)) {
          return backup(path);
        }
      }
    } catch (_) {}
    await for (var entry in dir.list(followLinks: false)) {
      if (entry is Directory && await finished(entry.path)) {
        return backup(entry.path);
      }
    }
    return null;
  }

  @override
  Future<void> install(
    String filePath,
    ReleaseAsset asset, {
    required String version,
    String? tempUrl,
  }) async {
    checkDesktopUpdateAllowed();
    if (!_isZip(asset)) {
      return _openInstaller(filePath, asset);
    }
    var installDir = WindowsInstaller.installDir;
    _checkInstallDir(installDir);
    await _run(
      mode: "install",
      installDir: installDir,
      version: version,
      zipFile: filePath,
      oldVersion: safeVersionName(Utils.packageInfo.version),
      notice: "即将退出并安装更新…".t,
    );
  }

  /// 签名的安装包：交给 Windows 安装。MSIX 由系统的应用安装程序关掉 App 再更新；
  /// exe、msi 要先退出 App 换文件
  Future<void> _openInstaller(String filePath, ReleaseAsset asset) async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.file(filePath, windows: true));
    } catch (e) {
      Log.w("打开安装包失败：$e");
    }
    if (!ok) {
      throw UpdateInstallError("无法打开安装包".t, package: filePath);
    }
    if (!asset.name.toLowerCase().contains(".msix")) {
      await quitForUpdate(notice: "即将退出并安装更新…".t);
    }
  }

  /// 回到上一个版本（更新前留下的备份）。App 会退出，换好后问要不要打开
  Future<void> rollbackToPrevious() async {
    checkDesktopUpdateAllowed();
    var installDir = WindowsInstaller.installDir;
    _checkInstallDir(installDir);
    var backup = await findBackup();
    if (backup == null) {
      throw UpdateInstallError("没有找到上一个版本".t);
    }
    await _run(
      mode: "rollback",
      installDir: installDir,
      version: backup.version,
      notice: "即将退出并换回上一个版本…".t,
    );
  }

  void _checkInstallDir(String installDir) {
    var dir = p.windows.normalize(installDir);
    if (p.windows.dirname(dir) == dir) {
      throw UpdateInstallError("这个安装位置不能自动更新".t);
    }
  }

  Future<void> _run({
    required String mode,
    required String installDir,
    required String version,
    String zipFile = "",
    String oldVersion = "",
    String notice = "",
  }) async {
    var backupRoot = backupRootFor(installDir);
    var elevate = !await _canWrite(installDir, backupRoot);
    // 每次一个文件夹：上一次的脚本还没结束时，两次的状态、解压出的文件不会混在一起
    var runDir = await UpdatePaths.newRunDir();
    var script = await writeScript(runDir);
    var status = await UpdateScriptStatus.prepare(runDir);
    var log = await UpdatePaths.logFile();
    var texts = await writeTexts(
      UpdatePaths.textFile(runDir),
      {
        ...windowTexts(
          mode: mode,
          version: version,
          installDir: installDir,
          logFile: log.path,
        ),
        ...themeTexts(),
      },
    );
    var plan = WindowsUpdatePlan(
      mode: mode,
      installDir: installDir,
      exePath: Platform.resolvedExecutable,
      zipFile: zipFile,
      newDir: zipFile.isEmpty ? "" : p.join(runDir.path, "files"),
      backupRoot: backupRoot,
      oldVersion: oldVersion,
      logFile: log.path,
      statusFile: status.path,
      progressFile: UpdatePaths.progressFile(runDir).path,
      textFile: texts.path,
      ui: true,
      elevate: elevate,
    );
    Log.i("更新脚本：$mode${elevate ? "，需要管理员权限" : ""}");
    unawaited(SmartDialog.showLoading(msg: "正在准备安装…".t));
    try {
      await startScript(plan, script, runDir);
      var result =
          await UpdateScriptStatus.wait(status, const Duration(seconds: 60));
      if (result.isEmpty) {
        // 不等了：脚本晚些时候起来也不动手
        await UpdateScriptStatus.cancel(status);
      }
      if (!result.startsWith("started")) {
        Log.w("更新脚本没有开始：$result");
      }
      UpdateScriptStatus.check(
        result,
        logFile: log.path,
        package: zipFile.isEmpty ? null : zipFile,
      );
    } catch (e) {
      await SmartDialog.dismiss(status: SmartStatus.loading);
      if (e is UpdateInstallError) {
        rethrow;
      }
      // 两种办法都没能启动 PowerShell（被策略、杀毒软件拦下）
      Log.w("启动更新脚本失败：$e");
      throw UpdateInstallError(
        "安装程序没有启动".t,
        package: zipFile.isEmpty ? null : zipFile,
      );
    }
    await quitForUpdate(notice: notice);
  }

  /// 启动更新脚本。它要在这个 App 退出以后接着跑，见 [WindowsNative.startHidden]
  @visibleForTesting
  static Future<void> startScript(
    WindowsUpdatePlan plan,
    File script,
    Directory runDir,
  ) async {
    var args = plan.powershellArgs(script.path);
    try {
      var pid = WindowsNative.startHidden(
        _powershell,
        args,
        directory: runDir.path,
      );
      // 更新窗口到最前面
      WindowsNative.allowForeground(pid);
    } catch (e) {
      Log.w("启动更新脚本失败：$e，换一种办法");
      var process = await Process.start(
        _powershell,
        args,
        workingDirectory: runDir.path,
      );
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
    }
  }

  /// 更新窗口里的字（脚本里没有的用它自己的英文），键和脚本的 $Texts 一样
  @visibleForTesting
  static Map<String, String> windowTexts({
    required String mode,
    required String version,
    required String installDir,
    required String logFile,
  }) {
    var rollback = mode == "rollback";
    var logHint = "日志：{path}".tf({"path": logFile});
    return {
      "title": "Simple Live N 更新".t,
      "folder": installDir,
      "icon": p.join(
        installDir,
        "data",
        "flutter_assets",
        "assets",
        "images",
        "logo.png",
      ),
      "preparing": rollback
          ? "正在准备换回 {version}".tf({"version": version})
          : "正在准备安装 {version}".tf({"version": version}),
      "elevating": "正在请求管理员权限".t,
      "extract": "正在解压 {version}".tf({"version": version}),
      "wait": "正在等待 Simple Live N 退出".t,
      "backup": rollback ? "正在保留当前版本".t : "正在备份当前版本".t,
      "copy": "正在安装 {version}".tf({"version": version}),
      "restore": rollback
          ? "正在换回 {version}".tf({"version": version})
          : "安装出错，正在恢复原来的版本".t,
      "ok": rollback
          ? "已换回 {version}".tf({"version": version})
          : "已更新到 {version}".tf({"version": version}),
      "okHint": "是否打开 Simple Live N？".t,
      "restored": rollback ? "换回失败，仍是当前版本".t : "安装失败，已恢复原来的版本".t,
      "restoredHint": logHint,
      "failed": rollback ? "换回失败".t : "安装失败".t,
      "failedHint": logHint,
      "busy": rollback
          ? "Simple Live N 没有退出，未换回".t
          : "Simple Live N 没有退出，未安装".t,
      "busyHint": rollback
          ? "退出 Simple Live N 后重新操作".t
          : "安装包已保留，退出 Simple Live N 后重新更新".t,
      "open": "打开".t,
      "skip": "不打开".t,
      "close": "关闭".t,
    };
  }

  /// 更新窗口跟着 App 的主题色和深浅
  @visibleForTesting
  static Map<String, String> themeTexts() {
    var context = Get.context;
    if (context == null) {
      return const {};
    }
    var scheme = Theme.of(context).colorScheme;
    return {
      "accent": hexColor(scheme.primary),
      "onAccent": hexColor(scheme.onPrimary),
      "dark": scheme.brightness == Brightness.dark ? "1" : "0",
    };
  }

  @visibleForTesting
  static String hexColor(Color color) =>
      "#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, "0").toUpperCase()}";

  /// 一行一个 键=值，值里没有换行
  static Future<File> writeTexts(File file, Map<String, String> texts) =>
      file.writeAsString(
        [
          for (var e in texts.entries)
            "${e.key}=${e.value.replaceAll(RegExp(r"[\r\n]+"), " ")}\n",
        ].join(),
        flush: true,
      );

  /// 安装文件夹能写、放备份的地方能建文件夹：不用管理员权限
  static Future<bool> _canWrite(String installDir, String backupRoot) async {
    if (!await canWriteDir(installDir)) {
      return false;
    }
    // 备份文件夹还没有时，看它最近的上级
    var dir = backupRoot;
    while (!await Directory(dir).exists()) {
      var parent = p.dirname(dir);
      if (parent == dir) {
        return false;
      }
      dir = parent;
    }
    // C:\\ 这种地方不让建文件、让建文件夹
    return canCreateDirIn(dir);
  }
}
