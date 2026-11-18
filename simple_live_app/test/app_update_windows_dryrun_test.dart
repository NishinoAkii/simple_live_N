import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/services/app_update/installers/windows_installer.dart';

/// Windows 更新脚本在临时文件夹里真跑一遍（-DryRun：不等进程退出，也不打开 App）：
/// 覆盖新文件、备份并只留最新的一份、出错时还原、回到上一个版本、参数不对时不动手。
/// 用的都是假的文件夹，exe 只是一个小文本文件，不会运行。
/// SL_UPDATER_DRYRUN_DIR 可以指定放这些文件夹的地方（默认系统临时目录）
void main() {
  final skip = Platform.isWindows ? false : "只在 Windows 上运行";

  late Directory base;
  late String installDir;
  late String newDir;
  late String backupRoot;
  late String updateDir;
  late String logFile;
  late String statusFile;
  late File script;

  const oldFiles = {
    "simple_live_app.exe": "old exe",
    r"data\app.so": "old so",
    r"data\flutter_assets\old_only.txt": "old asset",
    "old_only.dll": "old dll",
    "readonly.dll": "old ro",
  };
  const newFiles = {
    "simple_live_app.exe": "new exe",
    r"data\app.so": "new so",
    r"data\flutter_assets\new_asset.txt": "new asset",
    "new_only.dll": "new dll",
    "readonly.dll": "new ro",
  };

  void writeTree(String root, Map<String, String> files) {
    files.forEach((rel, text) {
      var file = File(p.join(root, rel));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
    });
  }

  Map<String, String> readTree(String root) {
    var dir = Directory(root);
    if (!dir.existsSync()) {
      return {};
    }
    return {
      for (var f in dir.listSync(recursive: true).whereType<File>())
        p.relative(f.path, from: root): f.readAsStringSync(),
    };
  }

  String exe() => p.join(installDir, "simple_live_app.exe");

  WindowsUpdatePlan installPlan({String? backup}) => WindowsUpdatePlan(
        mode: "install",
        installDir: installDir,
        exePath: exe(),
        newDir: newDir,
        backupRoot: backup ?? backupRoot,
        oldVersion: "1.24.2",
        logFile: logFile,
        statusFile: statusFile,
        dryRun: true,
      );

  WindowsUpdatePlan rollbackPlan() => WindowsUpdatePlan(
        mode: "rollback",
        installDir: installDir,
        exePath: exe(),
        backupRoot: backupRoot,
        logFile: logFile,
        statusFile: statusFile,
        dryRun: true,
      );

  /// 和 App 一样的参数，只是不加 -WindowStyle Hidden（会把测试所在的控制台藏起来）
  Future<ProcessResult> run(WindowsUpdatePlan plan) => Process.run(
        "powershell.exe",
        [
          "-NoProfile",
          "-NonInteractive",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          script.path,
          ...plan.scriptArgs(),
        ],
      );

  String status() => File(statusFile).readAsStringSync().trim();
  String log() =>
      File(logFile).existsSync() ? File(logFile).readAsStringSync() : "";

  setUp(() async {
    if (!Platform.isWindows) {
      return;
    }
    var root = Platform.environment["SL_UPDATER_DRYRUN_DIR"];
    var parent = root == null ? Directory.systemTemp : Directory(root);
    await parent.create(recursive: true);
    base = await parent.createTemp("updater_");
    installDir = p.join(base.path, "apps", "Simple Live");
    updateDir = p.join(base.path, "cache", "update");
    newDir = p.join(updateDir, "1.25.0");
    backupRoot = WindowsInstaller.backupRootFor(installDir);
    logFile = p.join(base.path, "support", "update", "updater.log");
    statusFile = p.join(updateDir, "updater.status");
    writeTree(installDir, oldFiles);
    // 只读文件也要能覆盖
    await Process.run("attrib", ["+R", p.join(installDir, "readonly.dll")]);
    writeTree(newDir, newFiles);
    // 上次更新留下的备份（应被换掉），和同一个目录里另一份安装的备份（不能动）
    writeTree(p.join(backupRoot, "1.10.0"), {"simple_live_app.exe": "older"});
    writeTree(backupRoot, {"added-files.txt": "x.dll"});
    writeTree(p.join(p.dirname(backupRoot), "Other Install", "1.0.0"),
        {"simple_live_app.exe": "other"});
    script = await WindowsInstaller.writeScript(Directory(updateDir));
  });

  tearDown(() async {
    if (!Platform.isWindows) {
      return;
    }
    await Process.run("attrib", ["-R", "${base.path}\\*", "/S"]);
    await base.delete(recursive: true);
  });

  test("更新：新文件盖上去，旧版本整份备份，只留这一份；别的安装的备份不动", () async {
    var result = await run(installPlan());
    expect(result.exitCode, 0, reason: "${result.stdout}${result.stderr}");
    expect(status(), "done:ok");

    expect(readTree(installDir), {
      "simple_live_app.exe": "new exe",
      r"data\app.so": "new so",
      r"data\flutter_assets\old_only.txt": "old asset",
      r"data\flutter_assets\new_asset.txt": "new asset",
      "old_only.dll": "old dll",
      "new_only.dll": "new dll",
      "readonly.dll": "new ro",
    });
    expect(readTree(p.join(backupRoot, "1.24.2")), oldFiles);
    expect(
      Directory(backupRoot).listSync().map((e) => p.basename(e.path)).toSet(),
      {"1.24.2", "added-files.txt"},
    );
    expect(
      File(p.join(backupRoot, "added-files.txt"))
          .readAsLinesSync()
          .where((l) => l.isNotEmpty)
          .toSet(),
      {"new_only.dll", r"data\flutter_assets\new_asset.txt"},
    );
    expect(readTree(p.join(p.dirname(backupRoot), "Other Install")),
        {r"1.0.0\simple_live_app.exe": "other"});
    // 解压出的新文件用完删掉；试运行时只记下要打开哪个
    expect(Directory(newDir).existsSync(), isFalse);
    expect(log(), contains("dry run, would start ${exe()}"));

    var backup = await WindowsInstaller.findBackupIn(backupRoot);
    expect(backup?.version, "1.24.2");
  }, skip: skip);

  test("回到上一个版本：和更新前一模一样，备份用掉后删除", () async {
    expect((await run(installPlan())).exitCode, 0);
    var result = await run(rollbackPlan());
    expect(result.exitCode, 0, reason: "${result.stdout}${result.stderr}");
    expect(status(), "done:ok");
    expect(readTree(installDir), oldFiles);
    expect(Directory(backupRoot).existsSync(), isFalse);
    // 另一份安装的备份还在，所以 SimpleLive-backup 留着
    expect(readTree(p.join(p.dirname(backupRoot), "Other Install")),
        {r"1.0.0\simple_live_app.exe": "other"});
    expect(await WindowsInstaller.findBackupIn(backupRoot), isNull);
    expect(log(), contains("rolled back to 1.24.2"));
  }, skip: skip);

  test("复制到一半出错：删掉新加的文件，旧版本原样还原，打开旧版本", () async {
    // 锁住新文件里的一个，读它时出错（脚本重试约 5 秒后放弃）
    var locked = File(p.join(newDir, "new_only.dll")).openSync(
      mode: FileMode.append,
    );
    locked.lockSync(FileLock.exclusive);
    try {
      var result = await run(installPlan());
      expect(result.exitCode, 1, reason: "${result.stdout}${result.stderr}");
      expect(status(), "done:restored");
      expect(readTree(installDir), oldFiles);
      expect(readTree(p.join(backupRoot, "1.24.2")), oldFiles);
      expect(log(), contains("old version restored"));
      expect(log(), contains("dry run, would start ${exe()}"));
    } finally {
      locked.unlockSync();
      locked.closeSync();
    }
  }, skip: skip);

  test("参数不对时什么都不动：备份不在 SimpleLive-backup 下、没有备份可回退", () async {
    var result = await run(installPlan(backup: p.join(base.path, "elsewhere")));
    expect(result.exitCode, 3);
    expect(status(), startsWith("error"));
    expect(readTree(installDir), oldFiles);
    expect(Directory(newDir).existsSync(), isTrue);

    await Directory(backupRoot).delete(recursive: true);
    result = await run(rollbackPlan());
    expect(result.exitCode, 3);
    expect(status(), "error: no backup found");
    expect(readTree(installDir), oldFiles);
  }, skip: skip);
}
