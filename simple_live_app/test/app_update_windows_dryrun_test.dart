import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/services/app_update/installers/windows_installer.dart';
import 'package:simple_live_app/services/app_update/installers/windows_native.dart';

/// Windows 更新脚本在临时文件夹里真跑一遍（-DryRun：不等进程退出，也不打开 App）：
/// 解压、覆盖新文件、备份并只留最新的一份、出错时还原、回到上一个版本、参数不对时不动手；
/// 启动脚本的办法真的把它启动起来。
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
  late String progressFile;
  late String zipFile;
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

  /// 从压缩包装：[newFiles] 打成 zip，[prefix] 是压缩包里外面套的文件夹
  WindowsUpdatePlan zipPlan({String prefix = "", Map<String, String>? files}) {
    var unpacked = Directory(newDir);
    if (unpacked.existsSync()) {
      unpacked.deleteSync(recursive: true);
    }
    var archive = Archive();
    (files ?? newFiles).forEach((rel, text) {
      var data = utf8.encode(text);
      archive.addFile(ArchiveFile(
          "$prefix${rel.replaceAll(r"\", "/")}", data.length, data));
    });
    File(zipFile)
      ..createSync(recursive: true)
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    return WindowsUpdatePlan(
      mode: "install",
      installDir: installDir,
      exePath: exe(),
      zipFile: zipFile,
      newDir: newDir,
      backupRoot: backupRoot,
      oldVersion: "1.24.2",
      logFile: logFile,
      statusFile: statusFile,
      progressFile: progressFile,
      dryRun: true,
    );
  }

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
    progressFile = p.join(updateDir, "updater.progress");
    zipFile = p.join(base.path, "cache", "app_update", "new version.zip");
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

  // 更新会换掉的那几个（备份只留这些：安装文件夹里可能还放着别的东西）
  const changedFiles = {
    "simple_live_app.exe": "old exe",
    r"data\app.so": "old so",
    "readonly.dll": "old ro",
  };
  const updated = {
    "simple_live_app.exe": "new exe",
    r"data\app.so": "new so",
    r"data\flutter_assets\old_only.txt": "old asset",
    r"data\flutter_assets\new_asset.txt": "new asset",
    "old_only.dll": "old dll",
    "new_only.dll": "new dll",
    "readonly.dll": "new ro",
  };

  test("更新：新文件盖上去，换掉的旧文件备份，只留这一份；别的安装的备份不动", () async {
    var result = await run(installPlan());
    expect(result.exitCode, 0, reason: "${result.stdout}${result.stderr}");
    expect(status(), "done:ok");

    expect(readTree(installDir), updated);
    expect(readTree(p.join(backupRoot, "1.24.2")), changedFiles);
    expect(
      Directory(backupRoot).listSync().map((e) => p.basename(e.path)).toSet(),
      {"1.24.2", "1.24.2.added.txt", "current.txt"},
    );
    expect(
      File(p.join(backupRoot, "1.24.2.added.txt"))
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

  test("换回到一半出错：仍是当前版本，备份还在", () async {
    expect((await run(installPlan())).exitCode, 0);
    // 锁住备份里的一个，读它时出错（脚本重试约 5 秒后放弃）
    var locked = File(p.join(backupRoot, "1.24.2", "readonly.dll"));
    await Process.run("attrib", ["-R", locked.path]);
    var handle = locked.openSync(mode: FileMode.append);
    handle.lockSync(FileLock.exclusive);
    try {
      var result = await run(rollbackPlan());
      expect(result.exitCode, 1, reason: "${result.stdout}${result.stderr}");
      expect(status(), "done:restored");
      expect(readTree(installDir), updated);
      expect(log(), contains("current version kept"));
      expect(
        Directory(backupRoot)
            .listSync()
            .where((e) => e.path.endsWith(".partial")),
        isEmpty,
      );
    } finally {
      handle.unlockSync();
      handle.closeSync();
    }
    // 还能再换回一次
    expect((await run(rollbackPlan())).exitCode, 0);
    expect(readTree(installDir), oldFiles);
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
      // 没装成的这一份备份不留，原来那份还在
      expect(Directory(p.join(backupRoot, "1.24.2")).existsSync(), isFalse);
      expect(readTree(p.join(backupRoot, "1.10.0")),
          {"simple_live_app.exe": "older"});
      expect((await WindowsInstaller.findBackupIn(backupRoot))?.version,
          "1.10.0");
      expect(
          File(p.join(backupRoot, "update-in-progress.txt")).existsSync(),
          isFalse);
      expect(log(), contains("old version restored"));
      expect(log(), contains("dry run, would start ${exe()}"));
    } finally {
      locked.unlockSync();
      locked.closeSync();
    }
  }, skip: skip);

  test("要换的一个文件被别的程序开着：整个不换，说已恢复", () async {
    var busy = File(p.join(installDir, "data", "app.so"));
    var handle = busy.openSync(mode: FileMode.append);
    handle.lockSync(FileLock.shared);
    try {
      var result = await run(zipPlan());
      expect(result.exitCode, 1);
      expect(status(), startsWith("done:"));
      expect(status(), isNot("done:ok"));
      expect(File(zipFile).existsSync(), isTrue);
    } finally {
      handle.unlockSync();
      handle.closeSync();
    }
    // 一个都没换，开着的那个也没有写坏，没有留下写了一半的
    expect(readTree(installDir), oldFiles);
    // 放开以后再更新
    expect((await run(zipPlan())).exitCode, 0);
    expect(readTree(installDir), updated);
  }, skip: skip);

  test("解压出的文件在换之前少了（被杀毒软件拿走）：什么都不动", () async {
    File(p.join(newDir, "simple_live_app.exe")).deleteSync();
    var result = await run(installPlan());
    expect(status(), "error: new files not found");
    expect(result.exitCode, 3);
    expect(readTree(installDir), oldFiles);
    expect(readTree(p.join(backupRoot, "1.10.0")),
        {"simple_live_app.exe": "older"});
  }, skip: skip);

  test("上次换到一半停了：先从备份换回来再更新；换回用的还是好的那份", () async {
    // 上次：备份好了、写了标记，换了一部分，加了一个文件，然后停了
    writeTree(p.join(backupRoot, "1.24.2"), changedFiles);
    File(p.join(backupRoot, "1.24.2.added.txt"))
        .writeAsStringSync("half.dll\r\n");
    File(p.join(backupRoot, "update-in-progress.txt"))
        .writeAsStringSync("1.24.2");
    File(p.join(installDir, "data", "app.so")).writeAsStringSync("half");
    File(p.join(installDir, "half.dll")).writeAsStringSync("half");
    var result = await run(zipPlan());
    expect(result.exitCode, 0, reason: "${result.stdout}${result.stderr}");
    expect(log(), contains("unfinished install, putting back 1.24.2"));
    expect(readTree(installDir), updated);
    expect(File(p.join(backupRoot, "update-in-progress.txt")).existsSync(),
        isFalse);
    var backup = await WindowsInstaller.findBackupIn(backupRoot);
    expect(p.basename(backup!.dir), "1.24.2-2");
    expect(backup.version, "1.24.2");
    expect(readTree(backup.dir), changedFiles);
    expect((await run(rollbackPlan())).exitCode, 0);
    expect(readTree(installDir), oldFiles);
  }, skip: skip);

  test("只恢复（脚本换到一半被结束，窗口再起一份）；没有要恢复的不动手", () async {
    writeTree(p.join(backupRoot, "1.24.2"), changedFiles);
    File(p.join(backupRoot, "1.24.2.added.txt")).writeAsStringSync("");
    var marker = File(p.join(backupRoot, "update-in-progress.txt"))
      ..writeAsStringSync("1.24.2");
    File(p.join(installDir, "data", "app.so")).writeAsStringSync("half");
    WindowsUpdatePlan repair() => WindowsUpdatePlan(
          mode: "repair",
          installDir: installDir,
          exePath: exe(),
          backupRoot: backupRoot,
          logFile: logFile,
          statusFile: statusFile,
          dryRun: true,
        );
    await run(repair());
    expect(status(), "done:restored");
    expect(readTree(installDir), oldFiles);
    expect(marker.existsSync(), isFalse);
    var result = await run(repair());
    expect(result.exitCode, 3);
    expect(status(), "error: nothing to repair");
    // 标记里写的不是这里的一份备份：不认
    marker.writeAsStringSync(r"..\..\x");
    expect((await run(repair())).exitCode, 3);
  }, skip: skip);

  test("以前的备份也能换回", () async {
    expect((await run(installPlan())).exitCode, 0);
    // 换成以前的样子：没有 current.txt，新加的文件记在 added-files.txt 里
    File(p.join(backupRoot, "current.txt")).deleteSync();
    File(p.join(backupRoot, "1.24.2.added.txt"))
        .renameSync(p.join(backupRoot, "added-files.txt"));
    expect((await WindowsInstaller.findBackupIn(backupRoot))?.version,
        "1.24.2");
    var result = await run(rollbackPlan());
    expect(result.exitCode, 0, reason: "${result.stdout}${result.stderr}");
    expect(readTree(installDir), oldFiles);
  }, skip: skip);

  test("两次更新同时进行：后来的不动手", () async {
    // 先来的在等 App 退出（拿系统的 ping 当作 App）
    File(exe()).deleteSync();
    File(p.join(Platform.environment["SystemRoot"]!, "System32", "PING.EXE"))
        .copySync(exe());
    var app = await Process.start(exe(), ["-t", "127.0.0.1"]);
    app.stdout.drain<void>();
    app.stderr.drain<void>();
    addTearDown(app.kill);
    var plan = zipPlan();
    var first = Process.run("powershell.exe", [
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      script.path,
      ...WindowsUpdatePlan(
        mode: "install",
        installDir: installDir,
        exePath: exe(),
        zipFile: zipFile,
        newDir: newDir,
        backupRoot: backupRoot,
        oldVersion: "1.24.2",
        logFile: logFile,
        statusFile: statusFile,
        timeoutSec: 4,
      ).scriptArgs(),
      "-Worker",
    ]);
    for (var i = 0; i < 100; i++) {
      if (File(statusFile).existsSync() && status() == "started") {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    var other = p.join(base.path, "other.status");
    var second = await run(WindowsUpdatePlan(
      mode: plan.mode,
      installDir: installDir,
      exePath: exe(),
      zipFile: zipFile,
      newDir: p.join(updateDir, "other"),
      backupRoot: backupRoot,
      oldVersion: "1.24.2",
      logFile: logFile,
      statusFile: other,
      dryRun: true,
    ));
    expect(second.exitCode, 6);
    expect(File(other).readAsStringSync(), "error: another update is running");
    expect((await first).exitCode, 1);
    expect(status(), "done:busy");
    app.kill();
    await app.exitCode;
  }, skip: skip);

  test("exe 改过名字：新的也换到那个名字上，换回时照样换回", () async {
    var renamed = p.join(installDir, "MySimpleLive.exe");
    File(exe()).renameSync(renamed);
    WindowsUpdatePlan plan(String mode) => WindowsUpdatePlan(
          mode: mode,
          installDir: installDir,
          exePath: renamed,
          newDir: mode == "install" ? newDir : "",
          backupRoot: p.join(p.dirname(backupRoot), "renamed"),
          oldVersion: mode == "install" ? "1.24.2" : "",
          logFile: logFile,
          statusFile: statusFile,
          dryRun: true,
        );
    expect((await run(plan("install"))).exitCode, 0);
    expect(File(renamed).readAsStringSync(), "new exe");
    expect(File(exe()).readAsStringSync(), "new exe");
    expect((await run(plan("rollback"))).exitCode, 0);
    expect(File(renamed).readAsStringSync(), "old exe");
    expect(File(exe()).existsSync(), isFalse);
  }, skip: skip);

  test("从压缩包更新：解压、换上、装完删掉压缩包和解压出的文件，进度写到最后", () async {
    for (var prefix in ["", "SimpleLive/"]) {
      var result = await run(zipPlan(prefix: prefix));
      expect(result.exitCode, 0, reason: "${result.stdout}${result.stderr}");
      expect(status(), "done:ok");
      expect(readTree(installDir), updated);
      expect(File(zipFile).existsSync(), isFalse);
      expect(Directory(newDir).existsSync(), isFalse);
      expect(log(), contains("package deleted"));
      // 最后一步是复制，做完了
      var progress = File(progressFile).readAsStringSync().split(" ");
      expect(progress.first, "copy");
      expect(progress[1], progress[2]);
      // 再来一次：上次装的当旧版本
      writeTree(newDir, newFiles);
    }
  }, skip: skip);

  test("压缩包坏了：什么都不动，说包有问题，压缩包留着", () async {
    var plan = zipPlan();
    var bytes = File(zipFile).readAsBytesSync();
    File(zipFile).writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
    var result = await run(plan);
    expect(result.exitCode, 2);
    expect(status(), "error: package not unpacked");
    expect(readTree(installDir), oldFiles);
    expect(Directory(newDir).existsSync(), isFalse);
    expect(File(zipFile).existsSync(), isTrue);
    expect(readTree(p.join(backupRoot, "1.10.0")),
        {"simple_live_app.exe": "older"});
  }, skip: skip);

  test("压缩包里没有 App、有跑到外面去的文件：不装", () async {
    var result = await run(zipPlan(files: {"readme.txt": "x"}));
    expect(result.exitCode, 2);
    expect(status(), "error: app not in the package");
    expect(readTree(installDir), oldFiles);

    Directory(newDir).createSync(recursive: true);
    result = await run(zipPlan(files: {
      ...newFiles,
      r"..\escaped.txt": "x",
    }));
    expect(result.exitCode, 2);
    expect(status(), "error: package not unpacked");
    expect(log(), contains("entry outside the folder"));
    expect(readTree(installDir), oldFiles);
    expect(File(p.join(updateDir, "escaped.txt")).existsSync(), isFalse);
    expect(Directory(newDir).existsSync(), isFalse);
  }, skip: skip);

  test("App 已经不等了：什么都不动", () async {
    var plan = zipPlan();
    File(statusFile)
      ..createSync(recursive: true)
      ..writeAsStringSync("cancelled");
    var result = await run(plan);
    expect(result.exitCode, 4);
    expect(status(), "cancelled");
    expect(readTree(installDir), oldFiles);
    expect(File(zipFile).existsSync(), isTrue);
    expect(Directory(newDir).existsSync(), isFalse);
  }, skip: skip);

  test("压缩包放在要清空的文件夹里：不动手", () async {
    var plan = zipPlan();
    zipFile = p.join(newDir, "inside.zip");
    File(zipFile)
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    var result = await run(WindowsUpdatePlan(
      mode: "install",
      installDir: installDir,
      exePath: exe(),
      zipFile: zipFile,
      newDir: newDir,
      backupRoot: backupRoot,
      oldVersion: plan.oldVersion,
      logFile: logFile,
      statusFile: statusFile,
      dryRun: true,
    ));
    expect(result.exitCode, 3);
    expect(status(), "error: package is inside the new folder");
    expect(File(zipFile).existsSync(), isTrue);
  }, skip: skip);

  test("App 还开着：等到时间还没退出就不装，压缩包留着", () async {
    // 真的开着一个：拿系统的 ping 当作 App
    File(exe()).deleteSync();
    File(p.join(Platform.environment["SystemRoot"]!, "System32", "PING.EXE"))
        .copySync(exe());
    var app = await Process.start(exe(), ["-t", "127.0.0.1"]);
    app.stdout.drain<void>();
    app.stderr.drain<void>();
    addTearDown(app.kill);
    var plan = zipPlan();
    WindowsUpdatePlan real(int timeout) => WindowsUpdatePlan(
          mode: plan.mode,
          installDir: plan.installDir,
          exePath: plan.exePath,
          zipFile: plan.zipFile,
          newDir: plan.newDir,
          backupRoot: plan.backupRoot,
          oldVersion: plan.oldVersion,
          logFile: plan.logFile,
          statusFile: plan.statusFile,
          progressFile: plan.progressFile,
          timeoutSec: timeout,
        );
    var result = await run(real(2));
    expect(result.exitCode, 1);
    expect(status(), "done:busy");
    expect(File(zipFile).existsSync(), isTrue);
    expect(readTree(p.join(installDir, "data"))["app.so"], "old so");
    expect(File(progressFile).readAsStringSync(), startsWith("wait"));
    app.kill();
    await app.exitCode;
  }, skip: skip);

  test("启动脚本的办法：Windows PowerShell 真的跑起来，参数原样传到（空格、引号、中文）", () async {
    var dir = p.join(base.path, "空 格 [1] it's");
    var out = File(p.join(dir, "out.txt"));
    var probe = File(p.join(dir, "probe.ps1"))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        "param([string]\$Out, [string]\$Text)\r\n"
        "[System.IO.File]::WriteAllText(\$Out, \$Text + '|' + "
        "[System.IO.Directory]::GetCurrentDirectory())\r\n",
      );
    const text = r'a b "c" \ 中文 &|^%';
    var pid = WindowsNative.startHidden(
      p.join(Platform.environment["SystemRoot"]!, "System32",
          "WindowsPowerShell", "v1.0", "powershell.exe"),
      [
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-WindowStyle",
        "Hidden",
        "-File",
        probe.path,
        "-Out",
        out.path,
        "-Text",
        text,
      ],
      directory: dir,
    );
    expect(pid, greaterThan(0));
    for (var i = 0; i < 150 && !out.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(out.existsSync(), isTrue, reason: "脚本没有跑");
    expect(out.readAsStringSync(), "$text|$dir");

    // 没有这个程序：报错，不是悄悄没反应
    expect(
      () => WindowsNative.startHidden(p.join(dir, "none.exe"), const []),
      throwsA(isA<WindowsNativeError>().having((e) => e.code, "code", 2)),
    );
    WindowsNative.allowForeground(pid);
    expect(WindowsNative.packageFullName(), isNull);
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
