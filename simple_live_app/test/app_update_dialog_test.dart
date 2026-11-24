import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/modules/settings/update/update_dialogs.dart';
import 'package:simple_live_app/services/app_update/app_update_service.dart';
import 'package:simple_live_app/services/app_update/installers/install_common.dart';
import 'package:simple_live_app/services/app_update/installers/windows_installer.dart';
import 'package:simple_live_app/services/app_update/release_api.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';
import 'package:simple_live_app/services/app_update/update_downloader.dart';
import 'package:simple_live_app/services/app_update/update_settings.dart';

import 'fakes/fake_http_adapter.dart';
import 'fakes/memory_storage.dart';

/// 应用内更新（1.25.0）：更新对话框（按钮、安装包大小和说明、在 GitHub 查看、小屏幕）、
/// 下载进度对话框的取消、上次下好的直接装、失败时去 GitHub 下载、填令牌登录，
/// 启动后什么时候自动检查（主窗口、10 秒后、一天一次、跳过的版本、开关）
void main() {
  late MemoryStorage storage;
  final local = LocalBuild.from("1.24.2", "12402", "b48-6b41418");

  Map<String, dynamic> fixture() => jsonDecode(
        File("test/fixtures/github_release_latest.json").readAsStringSync(),
      ) as Map<String, dynamic>;

  AppRelease release() => ReleaseParser.parse(
        {...fixture(), "name": "1.25.0（12500）"},
        tagPrefix: "v",
      );

  setUp(() {
    Get.testMode = true;
    storage = MemoryStorage.install();
  });
  tearDown(() {
    MultiWindow.launch = null;
    MultiWindow.startedForRoom = false;
    Get.reset();
  });

  group("更新对话框", () {
    UpdateDialog dialog({
      bool withAsset = true,
      List<String>? opened,
    }) =>
        UpdateDialog(
          release: release(),
          local: local,
          asset: withAsset ? release().assets.first : null,
          installNote: withAsset ? "下载完成后询问是否安装，安装时 App 会退出" : "",
          pageUrl: release().htmlUrl,
          openUrl: opened == null ? null : (url) async => opened.add(url),
        );

    Future<UpdateChoice?> tapButton(WidgetTester tester, String label) async {
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      UpdateChoice? choice;
      var done = false;
      UpdateDialog.show(dialog()).then((value) {
        choice = value;
        done = true;
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(done, isTrue);
      return choice;
    }

    testWidgets("显示版本、日期、当前版本、安装包大小和接下来会怎样、更新内容", (tester) async {
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      var opened = <String>[];
      UpdateDialog.show(dialog(opened: opened));
      await tester.pumpAndSettle();
      expect(find.text("发现新版本"), findsOneWidget);
      expect(find.text("1.25.0（12500） · 2026-11-20"), findsOneWidget);
      expect(find.text("当前版本 1.24.2（12402）"), findsOneWidget);
      expect(
          find.text("安装包 50.00 MB · 下载完成后询问是否安装，安装时 App 会退出"), findsOneWidget);
      expect(find.text("前往下载"), findsNothing);
      // 头部的链接打开这个版本的网页
      await tester.tap(find.text("在 GitHub 查看"));
      expect(opened, [release().htmlUrl]);
      // 列表项、加粗去掉记号、链接只留文字
      expect(find.text("应用内更新：启动时检查新版本"), findsOneWidget);
      expect(find.text("GitHub 登录"), findsOneWidget);
      expect(find.text("安装包：v1.25.0-b52-1a2b3c4"), findsOneWidget);
    });

    testWidgets("立即更新", (tester) async {
      expect(await tapButton(tester, "立即更新"), UpdateChoice.update);
    });

    testWidgets("稍后", (tester) async {
      expect(await tapButton(tester, "稍后"), UpdateChoice.later);
    });

    testWidgets("跳过这个版本", (tester) async {
      expect(await tapButton(tester, "跳过这个版本"), UpdateChoice.skip);
    });

    testWidgets("这台设备没有能在 App 里装的包：主按钮是“前往下载”，不写大小", (tester) async {
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      UpdateChoice? choice;
      UpdateDialog.show(dialog(withAsset: false)).then((v) => choice = v);
      await tester.pumpAndSettle();
      expect(find.text("立即更新"), findsNothing);
      expect(find.textContaining("安装包 "), findsNothing);
      await tester.tap(find.text("前往下载"));
      await tester.pumpAndSettle();
      expect(choice, UpdateChoice.update);
    });

    testWidgets("小屏幕：内容可以滚，按钮一直在屏幕里", (tester) async {
      // 横屏的手机
      await tester.binding.setSurfaceSize(const Size(640, 320));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      UpdateDialog.show(dialog());
      await tester.pumpAndSettle();
      expect(find.text("立即更新").hitTestable(), findsOneWidget);
      expect(find.text("稍后").hitTestable(), findsOneWidget);
    });
  });

  group("按了按钮以后", () {
    late List<String> opened;
    late UpdateDialog shown;
    AppUpdateService service(UpdateChoice choice, {UpdateInstaller? target}) {
      opened = [];
      return Get.put(AppUpdateService(
        dio: FakeHttpAdapter.dio(FakeHttpAdapter((_) => fail("不该联网"))),
        localBuild: () => local,
        installer: () => target,
        openUrl: (url) async => opened.add(url),
        showUpdateDialog: (d) async {
          shown = d;
          return choice;
        },
      ));
    }

    test("弹框之前挑好安装包：有能装的包时带上它和这个平台的说明，没有时主按钮是“前往下载”", () async {
      await service(UpdateChoice.later, target: _FakeInstaller())
          .promptUpdate(release());
      expect(
          shown.asset?.name, "SimpleLive-v1.25.0-b52-1a2b3c4-windows-x64.zip");
      expect(shown.installNote, _FakeInstaller.note);
      expect(shown.pageUrl, release().htmlUrl);
      Get.reset();
      storage = MemoryStorage.install();
      await service(UpdateChoice.later).promptUpdate(release());
      expect(shown.asset, isNull);
      expect(shown.installNote, "");
    });

    test("跳过这个版本：只存在本机，下次自动检查不再提示这一版", () async {
      var s = service(UpdateChoice.skip);
      await s.promptUpdate(release());
      expect(storage.values[UpdateSettings.kSkipped],
          ReleaseParser.skipId(release()));
      expect(opened, isEmpty);
    });

    test("稍后：什么都不记", () async {
      var s = service(UpdateChoice.later);
      await s.promptUpdate(release());
      expect(storage.values.containsKey(UpdateSettings.kSkipped), isFalse);
      expect(opened, isEmpty);
    });

    test("立即更新：这个平台还不能在 App 里装时打开 Release 网页", () async {
      var s = service(UpdateChoice.update);
      await s.promptUpdate(release());
      expect(opened, [release().htmlUrl]);
    });
  });

  group("下载进度对话框", () {
    testWidgets("显示进度；点取消时停下，返回取消", (tester) async {
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      CancelToken? token;
      void Function(DownloadProgress)? report;
      Object? result;
      UpdateDownloadDialog.show((onProgress, cancel) async {
        token = cancel;
        report = onProgress;
        await cancel.whenCancel;
        throw const DownloadCancelled();
      }).then((value) => result = value);
      await tester.pump();
      report!(const DownloadProgress(
        DownloadStage.downloading,
        source: "ghfast.top",
        received: 512 * 1024,
        total: 1024 * 1024,
        speed: 2 * 1024 * 1024,
      ));
      await tester.pump();
      expect(find.text("正在从 ghfast.top 下载"), findsOneWidget);
      expect(find.text("50%"), findsOneWidget);
      expect(find.text("2.00 MB/s"), findsOneWidget);
      await tester.tap(find.text("取消"));
      await tester.pumpAndSettle();
      expect(token!.isCancelled, isTrue);
      expect(result, isA<DownloadCancelled>());
      expect(find.byType(UpdateDownloadDialog), findsNothing);
    });
  });

  group("是否现在安装的对话框", () {
    Future<bool?> show(WidgetTester tester, String button) async {
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      bool? result;
      UpdateInstallDialog.show(
        version: "1.27.4（12705）",
        lines: ["安装位置：D:\\Apps\\Simple Live", "需要管理员权限，安装时由系统询问"],
      ).then((value) => result = value);
      await tester.pumpAndSettle();
      expect(find.text("1.27.4（12705） 已下载，是否现在安装？"), findsOneWidget);
      expect(find.text("安装位置：D:\\Apps\\Simple Live"), findsOneWidget);
      expect(find.text("需要管理员权限，安装时由系统询问"), findsOneWidget);
      // 点外面不算
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      expect(find.byType(UpdateInstallDialog), findsNothing);
      return result;
    }

    testWidgets("现在安装", (tester) async {
      expect(await show(tester, "现在安装"), isTrue);
    });

    testWidgets("稍后", (tester) async {
      expect(await show(tester, "稍后"), isFalse);
    });

    testWidgets("小屏幕放得下", (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      expect(await show(tester, "现在安装"), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group("下载和安装（缓存目录是临时文件夹）", () {
    late Directory cache;
    late List<String> opened;
    late List<String> revealed;
    late _FakeInstaller target;
    late FakeHttpAdapter adapter;
    const zipApi =
        "https://api.github.com/repos/NishinoAkii/simple_live_N/releases/assets/310000001";
    const temp = "https://release-assets.githubusercontent.com/zip?sig=S";

    setUp(() {
      cache = Directory.systemTemp.createTempSync("app_update_cache");
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => cache.path,
      );
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      cache.deleteSync(recursive: true);
    });

    /// Windows 的包：内容是 "test"（fixture 里的 digest 就是它的 SHA-256）
    AppRelease small() {
      var json = {...fixture(), "name": "1.25.0（12500）"};
      var assets = [for (var a in json["assets"] as List) Map.of(a as Map)];
      assets.first["size"] = 4;
      json["assets"] = assets;
      return ReleaseParser.parse(json, tagPrefix: "v");
    }

    AppUpdateService start(
      FutureOr<ResponseBody> Function(RequestOptions) on, {
      _FakeInstaller? installer,
    }) {
      opened = [];
      revealed = [];
      target = installer ?? _FakeInstaller();
      adapter = FakeHttpAdapter(on);
      storage.values[UpdateSettings.kSource] = UpdateSettings.sourceDirect;
      return Get.put(AppUpdateService(
        dio: FakeHttpAdapter.dio(adapter),
        localBuild: () => local,
        installer: () => target,
        openUrl: (url) async => opened.add(url),
        revealFile: (path) async => revealed.add(path),
      ));
    }

    /// 安装包已经下好（不用联网）的服务
    AppUpdateService downloaded(_FakeInstaller installer) {
      var dir = Directory("${cache.path}${Platform.pathSeparator}app_update")
        ..createSync();
      File("${dir.path}/${small().assets.first.name}")
          .writeAsStringSync("test");
      return start(
        (options) => options.uri.toString() == zipApi
            ? FakeHttpAdapter.redirect(temp)
            : fail("不该下载：${options.uri}"),
        installer: installer,
      );
    }

    /// 跑 [work]，期间一直画界面（对话框要画出来），文件读写要真的等
    Future<void> drive(WidgetTester tester, Future<void> Function() work,
        {bool Function()? until}) async {
      var done = false;
      unawaited(work().whenComplete(() => done = true));
      for (var i = 0; i < 200 && !done && !(until?.call() ?? false); i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        // 让测试里的计时器（dio 里用到的）也走
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets("上次下好、校验对的直接装，不重新下载；别的旧文件清掉", (tester) async {
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      var dir = Directory("${cache.path}${Platform.pathSeparator}app_update")
        ..createSync();
      var name = small().assets.first.name;
      File("${dir.path}/$name").writeAsStringSync("test");
      File("${dir.path}/SimpleLive-v1.24.2-b48-6b41418-windows-x64.zip")
          .writeAsStringSync("old");
      var service = start((options) => options.uri.toString() == zipApi
          ? FakeHttpAdapter.redirect(temp)
          : fail("不该下载：${options.uri}"));
      await drive(tester, () => service.startUpdate(small()));
      expect(target.installed, ["${dir.path}${Platform.pathSeparator}$name"]);
      expect(dir.listSync().map((e) => e.path.split(RegExp(r"[\\/]")).last),
          [name]);
      expect(
          adapter.requests.where((e) => e.uri.toString() != zipApi), isEmpty);
    });

    testWidgets("先问是否现在安装：选稍后不装，安装包留着；选现在安装就装", (tester) async {
      await tester.pumpWidget(GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(),
      ));
      var later = _ConfirmingInstaller(answer: false);
      var service = downloaded(later);
      await drive(tester, () => service.startUpdate(small()));
      expect(later.asked, ["1.25.0（12500） x64.zip"]);
      expect(later.installed, isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text("安装包已保留，下次更新时直接安装"), findsOneWidget);
      expect(find.text("更新失败"), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(
        Directory("${cache.path}/app_update").listSync(),
        hasLength(1),
      );
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets("选现在安装就装，装之前只问一次", (tester) async {
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      var now = _ConfirmingInstaller(answer: true);
      var service = downloaded(now);
      await drive(tester, () => service.startUpdate(small()));
      expect(now.asked, hasLength(1));
      expect(now.installed, hasLength(1));
    });

    testWidgets("更新窗口的颜色跟着 App 的主题", (tester) async {
      expect(WindowsInstaller.themeTexts(), isEmpty);
      for (var brightness in Brightness.values) {
        var theme = ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: brightness,
          ),
        );
        await tester.pumpWidget(GetMaterialApp(
          key: ValueKey(brightness),
          theme: theme,
          home: const Scaffold(),
        ));
        await tester.pumpAndSettle();
        expect(WindowsInstaller.themeTexts(), {
          "accent": WindowsInstaller.hexColor(theme.colorScheme.primary),
          "onAccent": WindowsInstaller.hexColor(theme.colorScheme.onPrimary),
          "dark": brightness == Brightness.dark ? "1" : "0",
        });
      }
    });

    testWidgets("没让装（UAC 里点了否）：提示一句，不算失败", (tester) async {
      await tester.pumpWidget(GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(),
      ));
      var service = downloaded(_FakeInstaller()
        ..failWith = const UpdateInstallCancelled("已取消安装"));
      await drive(tester, () => service.startUpdate(small()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text("已取消安装"), findsOneWidget);
      expect(find.text("更新失败"), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets("安装失败：安装包下好了的，可以打开它所在的文件夹", (tester) async {
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      var service = downloaded(_FakeInstaller()
        ..failWith =
            const UpdateInstallError("安装程序没有启动", package: r"C:\a\b.zip"));
      await drive(tester, () => service.startUpdate(small()),
          until: () => find.text("打开安装包位置").evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text("安装失败：安装程序没有启动"), findsOneWidget);
      await tester.tap(find.text("打开安装包位置"));
      await tester.pumpAndSettle();
      expect(revealed, [r"C:\a\b.zip"]);
      await tester.tap(find.text("关闭"));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
    });

    testWidgets("下载失败：说明原因，可以去 GitHub 下载", (tester) async {
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      var service = start((options) => options.uri.toString() == zipApi
          ? FakeHttpAdapter.redirect(temp)
          : FakeHttpAdapter.bytes([], status: 503));
      await drive(tester, () => service.startUpdate(small()),
          until: () => find.text("前往 GitHub 下载").evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text("更新失败"), findsOneWidget);
      expect(find.textContaining("HTTP 503"), findsOneWidget);
      expect(find.text("打开安装包位置"), findsNothing);
      await tester.tap(find.text("前往 GitHub 下载"));
      await tester.pumpAndSettle();
      expect(opened, [small().htmlUrl]);
      expect(target.installed, isEmpty);
    });
  });


  group("启动时自动检查", () {
    late FakeHttpAdapter adapter;
    late List<AppRelease> prompted;

    AppUpdateService start({bool loggedIn = true}) {
      prompted = [];
      adapter = FakeHttpAdapter((_) => FakeHttpAdapter.json(
            {...fixture(), "name": "1.25.0（12500）"},
          ));
      var service = Get.put(AppUpdateService(
        dio: FakeHttpAdapter.dio(adapter),
        localBuild: () => local,
        installer: () => null,
        openUrl: (_) async {},
        showUpdateDialog: (d) async {
          prompted.add(d.release);
          return UpdateChoice.later;
        },
      ));
      service.scheduleStartupCheck();
      return service;
    }

    testWidgets("主窗口启动 10 秒后查一次，有新版本时提示；24 小时内不再查", (tester) async {
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      var service = start();
      await tester.pump(const Duration(seconds: 9));
      expect(adapter.requests, isEmpty);
      await tester.pump(const Duration(seconds: 2));
      expect(adapter.requests, hasLength(1));
      expect(prompted.single.version, "1.25.0");
      expect(storage.values[UpdateSettings.kLastCheck], isA<int>());

      // 再启动一次（同一天）
      service.scheduleStartupCheck();
      await tester.pump(const Duration(seconds: 20));
      expect(adapter.requests, hasLength(1));
    });

    testWidgets("跳过的版本不提示，但照样记下检查时间", (tester) async {
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      storage.values[UpdateSettings.kSkipped] = ReleaseParser.skipId(release());
      start();
      await tester.pump(const Duration(seconds: 11));
      expect(adapter.requests, hasLength(1));
      expect(prompted, isEmpty);
      expect(storage.values[UpdateSettings.kLastCheck], isA<int>());
    });

    testWidgets("开关关着、多开的副窗口、带着链接启动：都不查", (tester) async {
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      storage.values[UpdateSettings.kAutoCheck] = false;
      var service = start();
      expect(service.startupBlocker(), AutoCheckBlock.turnedOff);
      await tester.pump(const Duration(seconds: 11));
      expect(adapter.requests, isEmpty);
      Get.reset();


      storage = MemoryStorage.install();
      MultiWindow.launch = SecondaryLaunch(
        port: 1,
        token: WindowToken.generate(),
        dataDir: "/tmp/multi_window/w1-1",
        slot: 1,
        siteId: "douyu",
        roomId: "1",
      );
      service = start();
      expect(service.startupBlocker(), AutoCheckBlock.secondaryWindow);
      await tester.pump(const Duration(seconds: 11));
      expect(adapter.requests, isEmpty);
      MultiWindow.launch = null;
      Get.reset();

      storage = MemoryStorage.install();
      MultiWindow.startedForRoom = true;
      service = start();
      expect(service.startupBlocker(), AutoCheckBlock.startedForRoom);
      await tester.pump(const Duration(seconds: 11));
      expect(adapter.requests, isEmpty);
    });

    testWidgets("等待的 10 秒里关掉了开关：不查", (tester) async {
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      var service = start();
      await tester.pump(const Duration(seconds: 5));
      service.settings.setAutoCheck(false);
      await tester.pump(const Duration(seconds: 6));
      expect(adapter.requests, isEmpty);
    });
  });
}

/// 下载完先问一声的
class _ConfirmingInstaller extends _FakeInstaller
    implements UpdateInstallConfirm {
  _ConfirmingInstaller({required this.answer});

  final bool answer;
  final List<String> asked = [];

  @override
  Future<bool> confirmInstall(String version, ReleaseAsset asset) async {
    asked.add("$version ${asset.name.split("-").last}");
    return answer;
  }
}

class _FakeInstaller implements UpdateInstaller {
  static const note = "装好后重新打开";
  final List<String> installed = [];
  Object? failWith;

  @override
  bool get canInstallInApp => true;

  @override
  String get installNote => note;

  @override
  ReleaseAsset? pickAsset(List<ReleaseAsset> assets) {
    for (var asset in assets) {
      if (asset.name.endsWith("-windows-x64.zip")) {
        return asset;
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
    if (failWith != null) {
      throw failWith!;
    }
    installed.add(filePath);
  }
}
