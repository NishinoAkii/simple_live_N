import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/app_update/installers/install_common.dart';
import 'package:simple_live_app/services/app_update/installers/windows_update_script.dart';
import 'package:simple_live_app/services/app_update/release_api.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';

/// 一次更新（或回退）交给脚本的参数。只拼参数、不碰文件，测试直接用
class WindowsUpdatePlan {
  /// install 或 rollback
  final String mode;
  final String installDir;

  /// 正在运行的 exe：等它的进程退出，出错时重新打开它
  final String exePath;

  /// 解压出的新版本（回退时为空）
  final String newDir;

  /// 新版本里要打开的 exe 文件名
  final String newExe;
  final String backupRoot;

  /// 当前版本号，备份文件夹用它命名（回退时为空）
  final String oldVersion;
  final String logFile;
  final String statusFile;

  /// 安装文件夹写不进去：用管理员身份运行（弹一次 UAC）
  final bool elevate;

  /// 测试用：不等进程退出，也不打开 App
  final bool dryRun;
  final int timeoutSec;

  const WindowsUpdatePlan({
    required this.mode,
    required this.installDir,
    required this.exePath,
    this.newDir = "",
    this.newExe = WindowsInstaller.exeName,
    required this.backupRoot,
    this.oldVersion = "",
    required this.logFile,
    required this.statusFile,
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
        "-TimeoutSec",
        "$timeoutSec",
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

/// Windows：下载 zip，解压到缓存目录，写一个 PowerShell 脚本；App 退出后脚本备份旧文件、
/// 覆盖新文件、重新打开 App，出错就从备份还原。安装文件夹写不进去时脚本用管理员身份运行。
/// 只动当前 App 所在的文件夹，装在别处的 SimpleLive 不受影响
class WindowsInstaller implements UpdateInstaller {
  static const String exeName = "simple_live_app.exe";
  static const String backupFolderName = "SimpleLive-backup";
  static const String scriptName = "simple_live_updater.ps1";

  @override
  bool get canInstallInApp => true;

  @override
  String get installNote => "更新时 App 会退出，安装完成后自动重新打开".t;

  @override
  ReleaseAsset? pickAsset(List<ReleaseAsset> assets) => pickAssetBySuffix(
        // 同一个 Release 上的 Windows 7 安装包（…-win7-windows-x64.zip）不算
        [
          for (var asset in assets)
            if (!asset.name.toLowerCase().contains("-win7-")) asset,
        ],
        const ["-windows-x64.zip"],
      );

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

  /// 解压出的文件夹里 simple_live_app.exe 所在的那一层（压缩包多套了一层文件夹时也能找到）
  static String? findAppDir(String root) {
    if (File(p.join(root, exeName)).existsSync()) {
      return root;
    }
    var dirs = Directory(root)
        .listSync(followLinks: false)
        .whereType<Directory>()
        .toList();
    if (dirs.length == 1 &&
        File(p.join(dirs.first.path, exeName)).existsSync()) {
      return dirs.first.path;
    }
    return null;
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
    await for (var entry in dir.list(followLinks: false)) {
      if (entry is! Directory || entry.path.endsWith(".partial")) {
        continue;
      }
      if (await File(p.join(entry.path, exeName)).exists()) {
        return WindowsBackup(entry.path, p.basename(entry.path));
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
    var installDir = WindowsInstaller.installDir;
    _checkInstallDir(installDir);
    var updateDir = await UpdatePaths.updateDir();
    var target = p.join(updateDir.path, safeVersionName(version));
    // 下载的文件就放在这个文件夹里时，解压到下一层，不把它删掉
    if (p.isWithin(target, filePath)) {
      target = p.join(target, "files");
    }
    var dir = Directory(target);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);
    try {
      await _extract(filePath, target);
    } catch (e) {
      Log.w("解压更新失败：$e");
      // 磁盘满了、没有权限时照实说，别的当作安装包坏了
      var reason = e is FileSystemException ? UpdateErrorText.file(e) : null;
      throw UpdateInstallError(reason ?? "安装包不完整".t);
    }
    var appDir = findAppDir(target);
    if (appDir == null) {
      Log.w("更新包里没有 $exeName");
      throw UpdateInstallError("安装包不完整".t);
    }
    await _run(
      mode: "install",
      installDir: installDir,
      updateDir: updateDir,
      newDir: appDir,
      oldVersion: safeVersionName(Utils.packageInfo.version),
      downloaded: filePath,
      notice: "即将退出并安装更新…".t,
    );
  }

  /// 在后台 isolate 里解压（几十 MB，不卡界面）
  static Future<void> _extract(String zip, String out) =>
      Isolate.run(() => extractFileToDisk(zip, out));

  /// 回到上一个版本（更新前留下的备份）。App 会退出，换好后重新打开
  Future<void> rollbackToPrevious() async {
    checkDesktopUpdateAllowed();
    var installDir = WindowsInstaller.installDir;
    _checkInstallDir(installDir);
    if (await findBackup() == null) {
      throw UpdateInstallError("没有找到上一个版本".t);
    }
    await _run(
      mode: "rollback",
      installDir: installDir,
      updateDir: await UpdatePaths.updateDir(),
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
    required Directory updateDir,
    String newDir = "",
    String oldVersion = "",
    String? downloaded,
    String notice = "",
  }) async {
    var backupRoot = backupRootFor(installDir);
    var elevate = !await _canWrite(installDir, backupRoot);
    var script = await writeScript(updateDir);
    var status = await UpdateScriptStatus.prepare(updateDir);
    var plan = WindowsUpdatePlan(
      mode: mode,
      installDir: installDir,
      exePath: Platform.resolvedExecutable,
      newDir: newDir,
      backupRoot: backupRoot,
      oldVersion: oldVersion,
      logFile: (await UpdatePaths.logFile()).path,
      statusFile: status.path,
      elevate: elevate,
    );
    Log.i("更新脚本：$mode${elevate ? "，需要管理员权限" : ""}");
    await Process.start(
      _powershell,
      plan.powershellArgs(script.path),
      mode: ProcessStartMode.detached,
    );
    // 要管理员权限时等用户在 UAC 里点
    var result = await UpdateScriptStatus.wait(
      status,
      elevate ? const Duration(minutes: 5) : const Duration(seconds: 30),
    );
    if (!result.startsWith("started") && !result.startsWith("done")) {
      Log.w("更新脚本没有开始：$result");
    }
    UpdateScriptStatus.check(result);
    // 脚本开始了才删下载的 zip：取消 UAC 后再点更新不用重新下载
    if (downloaded != null) {
      try {
        await File(downloaded).delete();
      } catch (_) {}
    }
    await quitForUpdate(notice: notice);
  }

  /// 安装文件夹和放备份的地方都能写，才不用管理员权限
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
    return canWriteDir(dir);
  }
}
