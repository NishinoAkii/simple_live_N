import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/services/app_update/installers/android_installer.dart';
import 'package:simple_live_app/services/app_update/installers/install_common.dart';
import 'package:simple_live_app/services/app_update/installers/ios_installer.dart';
import 'package:simple_live_app/services/app_update/installers/macos_installer.dart';
import 'package:simple_live_app/services/app_update/installers/windows_installer.dart';
import 'package:simple_live_app/services/app_update/installers/windows_native.dart';
import 'package:simple_live_app/services/app_update/installers/windows_update_script.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';
import 'package:simple_live_app/services/sync_compat.dart';

/// 应用内更新的安装部分：各平台挑哪个安装包、对话框里的说明、Windows 的更新脚本、iOS 的安装链接
void main() {
  const prefix = "SimpleLive-v1.24.2-b48-6b41418";
  ReleaseAsset asset(String name) => ReleaseAsset(
        name: name,
        size: 1,
        digest: "",
        apiUrl: "https://api.github.com/repos/o/r/releases/assets/1",
        browserUrl: "https://github.com/o/r/releases/download/v/$name",
      );
  final all = [
    asset("$prefix-windows-x64.zip"),
    asset("$prefix-android-arm64-v8a.apk"),
    asset("$prefix-android-armeabi-v7a.apk"),
    asset("$prefix-android-x86_64.apk"),
    asset("$prefix-ios-arm64-unsigned.ipa"),
    asset("$prefix-macos-universal.dmg"),
    asset("SHA256SUMS.txt"),
  ];

  group("挑安装包", () {
    test("Windows、iOS、macOS 各取自己的", () {
      expect(
          WindowsInstaller().pickAsset(all)?.name, "$prefix-windows-x64.zip");
      expect(IosInstaller().pickAsset(all)?.name,
          "$prefix-ios-arm64-unsigned.ipa");
      expect(MacosInstaller.pickForAbi(all, Abi.macosArm64)?.name,
          "$prefix-macos-universal.dmg");
      expect(MacosInstaller.pickForAbi(all, Abi.macosX64)?.name,
          "$prefix-macos-universal.dmg");
    });

    test("macOS 没有通用版时按 CPU 选", () {
      var split = [
        asset("$prefix-macos-x86_64.dmg"),
        asset("$prefix-macos-arm64.dmg"),
      ];
      expect(MacosInstaller.pickForAbi(split, Abi.macosArm64)?.name,
          "$prefix-macos-arm64.dmg");
      expect(MacosInstaller.pickForAbi(split, Abi.macosX64)?.name,
          "$prefix-macos-x86_64.dmg");
    });

    test("安卓按设备的 ABI 顺序，取第一个有 APK 的", () {
      String? pick(List<String> abis) =>
          AndroidInstaller.pickForAbis(all, abis)?.name;
      expect(pick(["arm64-v8a", "armeabi-v7a", "armeabi"]),
          "$prefix-android-arm64-v8a.apk");
      expect(
          pick(["armeabi-v7a", "armeabi"]), "$prefix-android-armeabi-v7a.apk");
      expect(pick(["x86_64", "arm64-v8a"]), "$prefix-android-x86_64.apk");
      // 没有 x86 的包：跳过它，用下一个
      expect(pick(["x86", "armeabi-v7a"]), "$prefix-android-armeabi-v7a.apk");
      expect(pick(["x86", "mips"]), isNull);
      expect(pick([]), isNull);
    });

    test("安卓读不到设备 ABI 时按当前进程的", () {
      expect(AndroidInstaller.processAbi(Abi.androidArm64), "arm64-v8a");
      expect(AndroidInstaller.processAbi(Abi.androidArm), "armeabi-v7a");
      expect(AndroidInstaller.processAbi(Abi.androidX64), "x86_64");
      expect(AndroidInstaller.processAbi(Abi.androidIA32), isNull);
    });

    test("同一个版本重新编译过：取运行编号最大的那份", () {
      var rebuilt = [
        asset("SimpleLive-v1.25.0-b9-aaaaaaa-windows-x64.zip"),
        asset("SimpleLive-v1.25.0-b51-ccccccc-windows-x64.zip"),
        asset("SimpleLive-v1.25.0-b50-bbbbbbb-windows-x64.zip"),
        asset("SimpleLive-v1.25.0-b50-bbbbbbb-android-arm64-v8a.apk"),
        asset("SimpleLive-v1.25.0-b51-ccccccc-android-arm64-v8a.apk"),
      ];
      expect(WindowsInstaller().pickAsset(rebuilt)?.name,
          "SimpleLive-v1.25.0-b51-ccccccc-windows-x64.zip");
      expect(AndroidInstaller.pickForAbis(rebuilt, ["arm64-v8a"])?.name,
          "SimpleLive-v1.25.0-b51-ccccccc-android-arm64-v8a.apk");
      // 没有编号的（本地打的包）排在有编号的后面
      expect(
        WindowsInstaller().pickAsset([
          asset("SimpleLive-v1.25.0-local-1119-windows-x64.zip"),
          asset("SimpleLive-v1.25.0-b3-ddddddd-windows-x64.zip"),
        ])?.name,
        "SimpleLive-v1.25.0-b3-ddddddd-windows-x64.zip",
      );
    });

    test("对话框里说明下载以后会怎样；macOS 说清楚要把 App 拖进“应用程序”", () {
      expect(WindowsInstaller().installNote, contains("询问是否安装"));
      expect(WindowsInstaller(kind: WindowsInstallKind.msix).installNote,
          contains("Windows 安装程序"));
      // 没有安装程序时用压缩包
      expect(WindowsInstaller(kind: WindowsInstallKind.setup).installNote,
          contains("询问是否安装"));
      expect(AndroidInstaller().installNote, contains("系统安装界面"));
      expect(IosInstaller().installNote, contains("TrollStore"));
      var mac = MacosInstaller();
      expect(mac.canInstallInApp, isFalse);
      expect(mac.installNote, allOf(contains("dmg"), contains("“应用程序”")));
    });

    test("Windows：压缩包装的只取 zip；签名的安装包各取各的，没有时安装程序的用压缩包、MSIX 去网页下载", () {
      var signed = [
        ...all,
        asset("$prefix-windows-x64.msix"),
        asset("$prefix-windows-x64-setup.exe"),
      ];
      String? pick(WindowsInstallKind kind, List<ReleaseAsset> from) =>
          WindowsInstaller(kind: kind).pickAsset(from)?.name;
      expect(
          pick(WindowsInstallKind.zip, signed), "$prefix-windows-x64.zip");
      expect(
          pick(WindowsInstallKind.msix, signed), "$prefix-windows-x64.msix");
      expect(pick(WindowsInstallKind.setup, signed),
          "$prefix-windows-x64-setup.exe");
      expect(pick(WindowsInstallKind.msix, all), isNull);
      expect(pick(WindowsInstallKind.setup, all), "$prefix-windows-x64.zip");
      expect(
        pick(WindowsInstallKind.msix, [asset("SimpleLive_1.msixbundle")]),
        "SimpleLive_1.msixbundle",
      );
      expect(pick(WindowsInstallKind.setup, [asset("SimpleLive.msi")]),
          "SimpleLive.msi");
    });

    test("Windows：有包名的是 MSIX，文件夹里有卸载程序的是安装程序装的，别的是压缩包", () {
      var dir = Directory.systemTemp.createTempSync("sl_kind_");
      addTearDown(() => dir.deleteSync(recursive: true));
      WindowsInstallKind kind([String? package]) => WindowsInstaller.kindOf(
          packageName: package, installDir: dir.path);
      File(p.join(dir.path, "simple_live_app.exe")).writeAsStringSync("x");
      File(p.join(dir.path, "uninstall.txt")).writeAsStringSync("x");
      File(p.join(dir.path, "reinstall.exe")).writeAsStringSync("x");
      expect(kind(), WindowsInstallKind.zip);
      expect(kind(""), WindowsInstallKind.zip);
      expect(kind("com.xycz.simple_1.0.0.0_x64__abc"), WindowsInstallKind.msix);
      for (var name in ["unins000.exe", "Uninstall.exe", "uninst.exe"]) {
        var file = File(p.join(dir.path, name))..writeAsStringSync("x");
        expect(kind(), WindowsInstallKind.setup, reason: name);
        file.deleteSync();
      }
      expect(
        WindowsInstaller.kindOf(
            packageName: null, installDir: p.join(dir.path, "none")),
        WindowsInstallKind.zip,
      );
    });

    test("Windows：安装前写明装到哪里、要不要管理员权限、会不会关多开窗口", () {
      const dir = r"D:\Apps\Simple Live";
      var plain = WindowsInstaller.confirmLines(
          installDir: dir, elevate: false, windows: 0);
      expect(plain, hasLength(2));
      expect(plain.first, contains(dir));
      expect(plain.last, contains("是否重新打开"));
      expect(plain.last, isNot(contains("多开")));
      var all = WindowsInstaller.confirmLines(
          installDir: dir, elevate: true, windows: 2);
      expect(all, hasLength(3));
      expect(all[1], contains("管理员权限"));
      expect(all[2], contains("多开窗口"));
    });

    test("同一个 Release 上的 Windows 7 安装包不算", () {
      var win7 = asset("simple_live_N-1.27.4-12704-win7-windows-x64.zip");
      var normal = asset("simple_live_N-1.27.4-12704-abcdef0-windows-x64.zip");
      for (var kind in [WindowsInstallKind.zip, WindowsInstallKind.setup]) {
        var installer = WindowsInstaller(kind: kind);
        expect(installer.pickAsset([win7, normal])?.name, normal.name);
        expect(installer.pickAsset([win7]), isNull);
      }
    });

    test("没有这个平台的包时为 null", () {
      var only = [asset("$prefix-windows-x64.zip")];
      expect(IosInstaller().pickAsset(only), isNull);
      expect(MacosInstaller.pickForAbi(only, Abi.macosArm64), isNull);
      expect(AndroidInstaller.pickForAbis(only, ["arm64-v8a"]), isNull);
      expect(WindowsInstaller().pickAsset([]), isNull);
    });
  });

  group("Windows 更新脚本", () {
    test("只有 ASCII，换行是 CRLF", () {
      var bad = windowsUpdateScript.runes.where((c) => c >= 0x80);
      expect(bad, isEmpty);
      var bytes = WindowsInstaller.scriptBytes();
      expect(bytes.every((b) => b < 0x80), isTrue);
      var text = ascii.decode(bytes);
      expect(text.contains("\r\n"), isTrue);
      expect(text.replaceAll("\r\n", "").contains("\n"), isFalse);
      // 第一条语句是 param()（前面只有注释）
      var code = text
          .split("\r\n")
          .where((l) => l.trim().isNotEmpty && !l.trim().startsWith("#"));
      expect(code.first.trim(), "param(");
    });

    test("脚本里不写路径，全部从参数来", () {
      expect(RegExp(r"[A-Za-z]:\\").hasMatch(windowsUpdateScript), isFalse);
      for (var word in ["Program Files", "Users", "AppData", "Simple Live"]) {
        expect(windowsUpdateScript.contains(word), isFalse, reason: word);
      }
      for (var name in [
        "InstallDir",
        "ExePath",
        "ZipFile",
        "NewDir",
        "BackupRoot",
        "LogFile",
        "StatusFile",
        "ProgressFile",
        "TextFile",
      ]) {
        expect(windowsUpdateScript.contains("[string]\$$name = ''"), isTrue,
            reason: name);
      }
    });

    test("参数：路径原样传，文件夹去掉结尾的反斜杠", () {
      const install = r"D:\Apps\Simple Live";
      const plan = WindowsUpdatePlan(
        mode: "install",
        installDir: "$install\\",
        exePath: "$install\\simple_live_app.exe",
        newDir: r"C:\Cache\update\1.25.0\",
        backupRoot: r"D:\Apps\SimpleLive-backup\Simple Live",
        oldVersion: "1.24.2",
        logFile: r"C:\Data\update\updater.log",
        statusFile: r"C:\Cache\update\updater.status",
      );
      var args = plan.scriptArgs();
      String valueOf(String name) => args[args.indexOf(name) + 1];
      expect(valueOf("-Mode"), "install");
      expect(valueOf("-InstallDir"), install);
      expect(valueOf("-ExePath"), "$install\\simple_live_app.exe");
      expect(valueOf("-NewDir"), r"C:\Cache\update\1.25.0");
      expect(valueOf("-NewExe"), "simple_live_app.exe");
      expect(valueOf("-BackupRoot"), r"D:\Apps\SimpleLive-backup\Simple Live");
      expect(valueOf("-OldVersion"), "1.24.2");
      expect(valueOf("-LogFile"), r"C:\Data\update\updater.log");
      expect(valueOf("-StatusFile"), r"C:\Cache\update\updater.status");
      for (var flag in [
        "-Elevate",
        "-DryRun",
        "-Ui",
        "-ZipFile",
        "-ProgressFile",
        "-TextFile",
      ]) {
        expect(args.contains(flag), isFalse, reason: flag);
      }

      var ps = plan.powershellArgs(r"C:\Cache\update\simple_live_updater.ps1");
      expect(ps.sublist(0, 8), [
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-WindowStyle",
        "Hidden",
        "-File",
        r"C:\Cache\update\simple_live_updater.ps1",
      ]);
      expect(ps.sublist(8), args);
    });

    test("压缩包、进度、窗口里的字也从参数传", () {
      const plan = WindowsUpdatePlan(
        mode: "install",
        installDir: r"D:\Apps\Simple Live",
        exePath: r"D:\Apps\Simple Live\simple_live_app.exe",
        zipFile: r"C:\Cache\app_update\a b.zip",
        newDir: r"C:\Cache\update\1.27.4",
        backupRoot: r"D:\Apps\SimpleLive-backup\Simple Live",
        oldVersion: "1.27.3",
        logFile: "log",
        statusFile: "status",
        progressFile: r"C:\Cache\update\updater.progress",
        textFile: r"C:\Cache\update\updater.txt",
        ui: true,
      );
      var args = plan.scriptArgs();
      String valueOf(String name) => args[args.indexOf(name) + 1];
      expect(valueOf("-ZipFile"), r"C:\Cache\app_update\a b.zip");
      expect(valueOf("-ProgressFile"), r"C:\Cache\update\updater.progress");
      expect(valueOf("-TextFile"), r"C:\Cache\update\updater.txt");
      expect(args, contains("-Ui"));
      // 参数名都是脚本认得的
      for (var name in args.where((e) => RegExp(r"^-[A-Z]").hasMatch(e))) {
        expect(windowsUpdateScript.contains("\$${name.substring(1)}"), isTrue,
            reason: name);
      }
    });

    test("窗口里的字：脚本用到的都有，两种操作都不缺", () {
      var block = RegExp(r"\$Texts = @\{([^}]*)\}", dotAll: true)
          .firstMatch(windowsUpdateScript)![1]!;
      var keys = [
        for (var m in RegExp(r"^\s+(\w+) = ", multiLine: true).allMatches(block))
          m[1]!,
      ];
      expect(keys, contains("okHint"));
      for (var mode in ["install", "rollback"]) {
        var texts = WindowsInstaller.windowTexts(
          mode: mode,
          version: "1.27.4",
          installDir: r"D:\Apps\Simple Live",
          logFile: r"C:\Data\update\updater.log",
        );
        // 主题色、深浅另外给（themeTexts）
        expect(
          texts.keys.toSet(),
          keys.toSet()..removeAll(["accent", "onAccent", "dark"]),
          reason: mode,
        );
        expect(texts.values.every((e) => e.isNotEmpty), isTrue);
        expect(texts["ok"], contains("1.27.4"));
        expect(texts["okHint"], contains("是否打开"));
        expect(texts["failedHint"], contains("updater.log"));
      }
    });

    test("窗口里的字写成一行一个，换行另写", () async {
      var dir = Directory.systemTemp.createTempSync("sl_texts_");
      addTearDown(() => dir.deleteSync(recursive: true));
      var file = await WindowsInstaller.writeTexts(
        File(p.join(dir.path, "t.txt")),
        // 路径里的反斜杠原样写（C:\new 不是换行）
        {"a": "一=二", "b": "第一行\r\n第二行\n第三行", "c": r"C:\new\nick"},
      );
      expect(utf8.decode(file.readAsBytesSync()),
          "a=一=二\nb=第一行 第二行 第三行\nc=C:\\new\\nick\n");
      expect(windowsUpdateScript, isNot(contains(r"Replace('\n'")));
    });

    test("颜色写成 #RRGGBB", () {
      expect(WindowsInstaller.hexColor(const Color(0xFF0A1BFF)), "#0A1BFF");
      expect(WindowsInstaller.hexColor(const Color(0x80000000)), "#000000");
    });

    test("命令行的引号和反斜杠", () {
      const cases = {
        "abc": "abc",
        "": '""',
        "a b": '"a b"',
        r"C:\a b\": r'"C:\a b\\"',
        r"C:\ab\": r"C:\ab\",
        'say "hi"': r'"say \"hi\""',
        r'a\"b': r'"a\\\"b"',
        "中文 路径": '"中文 路径"',
      };
      cases.forEach((value, quoted) {
        expect(WindowsNative.quote(value), quoted, reason: value);
      });
      expect(
        WindowsNative.commandLine(r"C:\x y\p.exe", ["-File", r"D:\a b.ps1"]),
        r'"C:\x y\p.exe" -File "D:\a b.ps1"',
      );
    });

    test("回退没有新文件夹和版本号；要管理员权限时带 -Elevate", () {
      const plan = WindowsUpdatePlan(
        mode: "rollback",
        installDir: r"D:\Apps\Simple Live",
        exePath: r"D:\Apps\Simple Live\simple_live_app.exe",
        backupRoot: r"D:\Apps\SimpleLive-backup\Simple Live",
        logFile: "log",
        statusFile: "status",
        elevate: true,
        dryRun: true,
      );
      var args = plan.scriptArgs();
      expect(args.contains("-NewDir"), isFalse);
      expect(args.contains("-OldVersion"), isFalse);
      expect(args.contains("-Elevate"), isTrue);
      expect(args.contains("-DryRun"), isTrue);
    });

    test("备份放在安装文件夹旁边，同一个目录里的两份安装各用各的", () {
      expect(WindowsInstaller.backupRootFor(r"D:\Apps\Simple Live"),
          r"D:\Apps\SimpleLive-backup\Simple Live");
      expect(WindowsInstaller.backupRootFor(r"D:\Apps\Simple Live 2\"),
          r"D:\Apps\SimpleLive-backup\Simple Live 2");
    });
  });

  group("等脚本的状态", () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync("sl_status_"));
    tearDown(() => dir.deleteSync(recursive: true));
    const tick = Duration(milliseconds: 250);

    test("准备好、取消、出错时马上返回；一直没动静时超时", () async {
      var file = await UpdateScriptStatus.prepare(dir);
      expect(file.readAsStringSync(), "waiting");
      expect(await UpdateScriptStatus.wait(file, tick), "");
      for (var text in [
        "started",
        "done:ok",
        "declined",
        "cancelled",
        "error: x",
      ]) {
        file.writeAsStringSync(text);
        expect(await UpdateScriptStatus.wait(file, tick), text);
      }
    });

    test("在等用户点 UAC、在解压：多等一会儿，没有动静了还是超时", () async {
      for (var text in ["opening", "elevating", "preparing"]) {
        var file = await UpdateScriptStatus.prepare(dir);
        file.writeAsStringSync(text);
        var waiting = UpdateScriptStatus.wait(file, tick,
            busy: const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 900));
        file.writeAsStringSync("started");
        expect(await waiting, "started", reason: text);

        file.writeAsStringSync(text);
        var watch = Stopwatch()..start();
        expect(
          await UpdateScriptStatus.wait(file, tick,
              busy: const Duration(milliseconds: 700)),
          "",
        );
        expect(watch.elapsedMilliseconds, inInclusiveRange(600, 4000));
      }
    });

    test("不等了：写下来给脚本看", () async {
      var file = await UpdateScriptStatus.prepare(dir);
      await UpdateScriptStatus.cancel(file);
      expect(file.readAsStringSync(), "cancelled");
      expect(windowsUpdateScript, contains("StartsWith('cancelled')"));
    });

    test("重新开始时上次的进度清掉", () async {
      var progress = UpdatePaths.progressFile(dir)..writeAsStringSync("copy 1 2");
      await UpdateScriptStatus.prepare(dir);
      expect(progress.existsSync(), isFalse);
    });

    test("取消的只提示一句；包坏了说包坏了，别的可以打开安装包所在的文件夹", () {
      UpdateInstallError? error(String status) {
        try {
          UpdateScriptStatus.check(status,
              logFile: r"C:\log.txt", package: "a.zip");
        } on UpdateInstallError catch (e) {
          return e;
        }
        return null;
      }

      expect(error("started"), isNull);
      expect(error("declined"), isA<UpdateInstallCancelled>());
      // 窗口在开始之前关了
      expect(error("cancelled"), isA<UpdateInstallCancelled>());
      // 还没让 App 退出就有了结果（不该有）：不退出
      expect(error("done:ok")!.message, r"请查看日志 C:\log.txt");
      expect(error("done:busy")!.package, "a.zip");
      expect(error("error: package not unpacked")!.message, "安装包不完整");
      expect(error("error: package not unpacked")!.package, isNull);
      expect(error("error: app not in the package")!.message, "安装包不完整");
      expect(error("error: install folder not found")!.message,
          r"请查看日志 C:\log.txt");
      expect(error("error: install folder not found")!.package, "a.zip");
      expect(error("error: unpack failed")!.package, "a.zip");
      expect(error("error: disk full")!.message, "磁盘空间不足");
      expect(error("error: disk full")!.package, "a.zip");
      expect(error("error: access denied")!.message, "没有写入权限");
      expect(
          error("error: another update is running")!.message, "另一个更新正在进行");
      expect(error("")!.message, "安装程序没有启动");
      expect(error("")!.package, "a.zip");
      // 脚本报的错都在上面这几种里
      for (var m in RegExp(r"Set-Status \(?'(error: [^']*)'")
          .allMatches(windowsUpdateScript)) {
        expect(m[1], anyOf(
          "error: ",
          "error: app not in the package",
          "error: another update is running",
          "error: elevation failed",
          "error: worker stopped",
          "error: worker not started",
        ));
      }
    });
  });

  group("以前的更新留下的", () {
    late Directory base;
    late Directory update;
    late Directory download;
    final now = DateTime(2026, 11, 24, 12);
    setUp(() {
      base = Directory.systemTemp.createTempSync("sl_left_");
      update = Directory(p.join(base.path, "update"))..createSync();
      download = Directory(p.join(base.path, "app_update"))..createSync();
      for (var name in ["1.27.2", "run-abc"]) {
        File(p.join(update.path, name, "data", "x"))
            .createSync(recursive: true);
      }
      for (var name in ["updater.txt", "updater.status"]) {
        File(p.join(update.path, name))
          ..writeAsStringSync("x")
          ..setLastModifiedSync(now.subtract(const Duration(days: 1)));
      }
      for (var name in [
        "SimpleLive-v1.27.2-b1-aaa-windows-x64.zip",
        "SimpleLive-v1.27.3-b2-bbb-windows-x64.zip",
        "SimpleLive-v1.27.3-b22-ccc-windows-x64.zip",
        "SimpleLive-v1.27.4-b3-ccc-windows-x64.zip",
        "SimpleLive-v1.27.10-b4-ddd-windows-x64.zip",
        "note.txt",
      ]) {
        File(p.join(download.path, name)).writeAsStringSync("x");
      }
    });
    tearDown(() => base.deleteSync(recursive: true));

    Set<String> names(Directory dir) =>
        dir.listSync().map((e) => p.basename(e.path)).toSet();
    Future<void> clean() => UpdateLeftovers.clean(
          updateDir: update,
          downloadDir: download,
          version: "1.27.3",
          build: "b2-bbb",
          now: now,
        );

    test("解压出的文件夹、已经装上的版本的安装包删掉；还没装的（新的、重新编译过的）、别的文件留着", () async {
      File(p.join(update.path, "run-abc", "updater.status"))
          .writeAsStringSync("done:ok");
      File(p.join(update.path, "fresh.txt"))
        ..writeAsStringSync("x")
        ..setLastModifiedSync(now);
      await clean();
      expect(names(update), {"fresh.txt"});
      expect(names(download), {
        "SimpleLive-v1.27.3-b22-ccc-windows-x64.zip",
        "SimpleLive-v1.27.4-b3-ccc-windows-x64.zip",
        "SimpleLive-v1.27.10-b4-ddd-windows-x64.zip",
        "note.txt",
      });
    });

    test("文件名里没有 v、编译编号只有提交编号的也认得出", () async {
      for (var name in [
        "simple_live_N-1.27.1-12701-aaa-windows-x64.zip",
        "simple_live_N-1.27.3-12703-bbb-windows-x64.zip",
        "simple_live_N-1.27.3-12703-ccc-windows-x64.zip",
        "simple_live_N-1.27.4-12704-ddd-windows-x64.zip",
        "simple_live_N-1.27.10-12710-eee-windows-x64.zip",
      ]) {
        File(p.join(download.path, name)).writeAsStringSync("x");
      }
      await clean();
      expect(names(download).where((e) => e.startsWith("simple_live_N")), {
        "simple_live_N-1.27.3-12703-ccc-windows-x64.zip",
        "simple_live_N-1.27.4-12704-ddd-windows-x64.zip",
        "simple_live_N-1.27.10-12710-eee-windows-x64.zip",
      });
    });

    test("脚本正在干活的那个文件夹不动；很久没动静、已经结束就删", () async {
      var status = File(p.join(update.path, "run-abc", "updater.status"));
      for (var text in [
        "waiting",
        "opening",
        "elevating",
        "preparing",
        "started",
      ]) {
        status
          ..writeAsStringSync(text)
          ..setLastModifiedSync(now.subtract(const Duration(minutes: 2)));
        await clean();
        expect(names(update), {"run-abc"}, reason: text);
      }
      status.setLastModifiedSync(now.subtract(const Duration(minutes: 11)));
      await clean();
      expect(names(update), isEmpty);
      for (var text in ["done:ok", "declined", "error: x", "cancelled"]) {
        status
          ..createSync(recursive: true)
          ..writeAsStringSync(text)
          ..setLastModifiedSync(now);
        await clean();
        expect(names(update), isEmpty, reason: text);
      }
    });

    test("没有这些文件夹：不出错", () async {
      base.listSync().forEach((e) => e.deleteSync(recursive: true));
      await clean();
      expect(base.listSync(), isEmpty);
    });
  });

  group("上一个版本的备份", () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync("sl_backup_"));
    tearDown(() => root.deleteSync(recursive: true));
    void make(String name, {bool exe = true}) {
      File(p.join(root.path, name, exe ? WindowsInstaller.exeName : "x.dll"))
        ..createSync(recursive: true)
        ..writeAsStringSync("x");
    }

    Future<String?> found() async =>
        p.basename((await WindowsInstaller.findBackupIn(root.path))?.dir ?? "");

    test("没写完的、没有 App 的不算；current.txt 写着的优先", () async {
      expect(await found(), "");
      make("1.27.3.partial");
      make("1.27.4", exe: false);
      make("1.27.2");
      File(p.join(root.path, "1.27.2.building")).writeAsStringSync("");
      expect(await found(), "");
      make("1.27.1");
      expect(await found(), "1.27.1");
      make("1.27.3-2");
      var current = File(p.join(root.path, "current.txt"))
        ..writeAsStringSync("1.27.3-2\r\n");
      expect(await found(), "1.27.3-2");
      expect((await WindowsInstaller.findBackupIn(root.path))!.version,
          "1.27.3");
      // 写着的那份不完整、不在了、不是这里的一个文件夹：另找一份完整的
      File(p.join(root.path, "1.27.3-2.building")).writeAsStringSync("");
      expect(await found(), "1.27.1");
      for (var name in ["none", r"..\x", "../x", ""]) {
        current.writeAsStringSync(name);
        expect(await found(), "1.27.1", reason: name);
      }
    });

    test("能不能在一个文件夹里建文件夹", () async {
      expect(await canCreateDirIn(root.path), isTrue);
      expect(root.listSync(), isEmpty);
      expect(await canCreateDirIn(p.join(root.path, "none")), isFalse);
    });
  });

  group("iOS", () {
    const ipa =
        "https://objects.githubusercontent.com/x/a.ipa?X-Amz-Signature=ab%2F&response-content-disposition=attachment";

    test("安装链接：网址整段编码", () {
      var encoded = Uri.encodeComponent(ipa);
      expect(IosInstaller.storeUrl(IosInstallTarget.trollStore, ipa).toString(),
          "apple-magnifier://install?url=$encoded");
      expect(IosInstaller.storeUrl(IosInstallTarget.altStore, ipa).toString(),
          "altstore://install?url=$encoded");
      expect(IosInstaller.storeUrl(IosInstallTarget.sideStore, ipa).toString(),
          "sidestore://install?url=$encoded");
      expect(IosInstaller.storeUrl(IosInstallTarget.share, ipa), isNull);
      expect(IosInstaller.storeUrl(IosInstallTarget.auto, ipa), isNull);
      // 商店读到的还是原来的网址
      var uri = IosInstaller.storeUrl(IosInstallTarget.trollStore, ipa)!;
      expect(uri.queryParameters["url"], ipa);
    });

    test("自动依次试三个商店；分享不试；指定了只试那一个", () {
      expect(IosInstaller.storesFor(IosInstallTarget.auto), [
        IosInstallTarget.trollStore,
        IosInstallTarget.altStore,
        IosInstallTarget.sideStore,
      ]);
      expect(IosInstaller.storesFor(IosInstallTarget.share), isEmpty);
      expect(IosInstaller.storesFor(IosInstallTarget.altStore),
          [IosInstallTarget.altStore]);
    });

    test("安装方式只存本机；不认识的按自动", () {
      expect(SyncCompat.isLocalOnlySetting(IosInstallSetting.kKey), isTrue);
      expect(IosInstallSetting.parse("sideStore"), IosInstallTarget.sideStore);
      expect(IosInstallSetting.parse("xx"), IosInstallTarget.auto);
      expect(IosInstallSetting.parse(null), IosInstallTarget.auto);
    });
  });
}
