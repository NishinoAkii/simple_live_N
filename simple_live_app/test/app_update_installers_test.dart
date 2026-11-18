import 'dart:convert';
import 'dart:ffi' show Abi;

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/app_update/installers/android_installer.dart';
import 'package:simple_live_app/services/app_update/installers/ios_installer.dart';
import 'package:simple_live_app/services/app_update/installers/macos_installer.dart';
import 'package:simple_live_app/services/app_update/installers/windows_installer.dart';
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
      expect(WindowsInstaller().installNote, contains("重新打开"));
      expect(AndroidInstaller().installNote, contains("系统安装界面"));
      expect(IosInstaller().installNote, contains("TrollStore"));
      var mac = MacosInstaller();
      expect(mac.canInstallInApp, isFalse);
      expect(mac.installNote, allOf(contains("dmg"), contains("“应用程序”")));
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
        "NewDir",
        "BackupRoot",
        "LogFile",
        "StatusFile",
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
      expect(args.contains("-Elevate"), isFalse);
      expect(args.contains("-DryRun"), isFalse);

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
