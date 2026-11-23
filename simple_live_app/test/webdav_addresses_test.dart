import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/remote_sync_webdav_controller.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/webdav_address_field.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_app/services/sync_vault.dart';
import 'package:simple_live_app/services/webdav_addresses.dart';

import 'fakes/memory_storage.dart';
import 'webdav_auto_sync_test.dart' show fakeWebDav;

/// 切换 WebDAV 地址（1.27.1）：用过的地址和备注、只有一个正在用、确认后先测连接再保存、
/// 随存档同步时两边合并
void main() {
  late MemoryStorage storage;
  const day = 24 * 3600 * 1000;
  const t0 = 1800000000000;

  setUp(() {
    Get.testMode = true;
    storage = MemoryStorage.install();
  });
  tearDown(Get.reset);

  String uri() => storage.getValue(LocalStorageService.kWebDAVUri, "");

  WebDavAddress? entry(String address) => WebDavAddressBook.load()
      .firstWhereOrNull((e) => e.key == WebDavAddressBook.keyOf(address));

  group("地址表", () {
    test("用过的地址记下来，末尾斜杠不同算同一个，最近用的在前", () async {
      await WebDavAddressBook.use("http://192.168.1.2:8090/", now: t0);
      await WebDavAddressBook.use("https://dav.example.com/dav", now: t0 + 1);
      await WebDavAddressBook.use(" http://192.168.1.2:8090 ", now: t0 + 2);
      var list = WebDavAddressBook.visible();
      expect(list.map((e) => e.uri), [
        "http://192.168.1.2:8090/",
        "https://dav.example.com/dav",
      ]);
      expect(list.first.used, t0 + 2);
    });

    test("正在用的地址还没进表也在列表里", () {
      expect(
        WebDavAddressBook.visible(active: "http://localhost:8090").map((e) => e.uri),
        ["http://localhost:8090"],
      );
    });

    test("备注、删除；删掉的不显示，再用时重新加上（备注不带回来）", () async {
      await WebDavAddressBook.use("http://a", now: t0);
      await WebDavAddressBook.setNote("http://a/", " 家里 ", now: t0 + 1);
      expect(entry("http://a")!.note, "家里");
      expect(WebDavAddressBook.visible().single.label, "家里");
      await WebDavAddressBook.remove("http://a", now: t0 + 2);
      expect(WebDavAddressBook.visible(), isEmpty);
      expect(entry("http://a")!.deleted, isTrue);
      await WebDavAddressBook.use("http://a", now: t0 + 3);
      expect(entry("http://a")!.deleted, isFalse);
      expect(entry("http://a")!.note, "");
    });

    test("给还没进表的正在用的地址写备注：加进表", () async {
      await WebDavAddressBook.setNote("http://localhost:8090", "本机", now: t0);
      expect(
        WebDavAddressBook.visible(active: "http://localhost:8090").single.label,
        "本机",
      );
    });

    test("ensure 只在表里没有时加", () async {
      await WebDavAddressBook.setNote("http://a", "家里", now: t0);
      await WebDavAddressBook.ensure("http://a", now: t0 + 5);
      expect(entry("http://a")!.used, 0);
      await WebDavAddressBook.ensure("http://b", now: t0 + 5);
      expect(entry("http://b")!.used, t0 + 5);
      await WebDavAddressBook.ensure("", now: t0 + 5);
      expect(WebDavAddressBook.load(), hasLength(2));
    });

    test("设置里的值坏了：当作空表", () {
      expect(WebDavAddressBook.parse("not json"), isEmpty);
      expect(WebDavAddressBook.parse('{"uri": "x"}'), isEmpty);
      expect(WebDavAddressBook.parse('[1, {"uri": ""}, {"uri": "http://a"}]').single.uri,
          "http://a");
      expect(WebDavAddressBook.parse(null), isEmpty);
    });

    test("地址格式：要 http:// 或 https:// 开头，有主机名", () {
      expect(WebDavAddressBook.isValidUri("http://192.168.1.2:8090"), isTrue);
      expect(WebDavAddressBook.isValidUri(" https://dav.jianguoyun.com/dav/ "), isTrue);
      expect(WebDavAddressBook.isValidUri("192.168.1.2:8090"), isFalse);
      expect(WebDavAddressBook.isValidUri("ftp://a"), isFalse);
      expect(WebDavAddressBook.isValidUri("http://"), isFalse);
      expect(WebDavAddressBook.isValidUri(""), isFalse);
    });
  });

  group("两台设备合并", () {
    String book(List<WebDavAddress> list) =>
        WebDavAddressBook.encode(list, now: t0);

    test("各自的地址都留着；同一个地址的备注以改得晚的为准，用过的时间取晚的", () {
      var local = book([
        const WebDavAddress(uri: "http://a", note: "旧备注", time: t0, used: t0 + 50),
        const WebDavAddress(uri: "http://b", time: t0),
      ]);
      var remote = book([
        const WebDavAddress(uri: "http://a/", note: "家里", time: t0 + 10, used: t0 + 5),
        const WebDavAddress(uri: "http://c", note: "外网", time: t0),
      ]);
      var merged = WebDavAddressBook.parse(
        WebDavAddressBook.mergeRaw(local, remote, now: t0),
      );
      var a = merged.firstWhere((e) => e.key == "http://a");
      expect(a.note, "家里");
      expect(a.used, t0 + 50);
      expect(merged.map((e) => e.key).toSet(), {"http://a", "http://b", "http://c"});
    });

    test("别的设备删掉的跟着删；删了以后本机又用过的留着", () {
      var local = book([
        const WebDavAddress(uri: "http://a", time: t0),
        const WebDavAddress(uri: "http://b", time: t0 + 20, used: t0 + 20),
      ]);
      var remote = book([
        const WebDavAddress(uri: "http://a", time: t0 + 10, deleted: true),
        const WebDavAddress(uri: "http://b", time: t0 + 10, deleted: true),
      ]);
      var merged = WebDavAddressBook.parse(
        WebDavAddressBook.mergeRaw(local, remote, now: t0),
      );
      expect(merged.firstWhere((e) => e.key == "http://a").deleted, isTrue);
      expect(merged.firstWhere((e) => e.key == "http://b").deleted, isFalse);
    });

    test("删除记录留半年，之后不再写", () {
      var list = [
        const WebDavAddress(uri: "http://old", time: t0, deleted: true),
        const WebDavAddress(uri: "http://new", time: t0 + 100 * day, deleted: true),
      ];
      var text = WebDavAddressBook.encode(list, now: t0 + 200 * day);
      expect(WebDavAddressBook.parse(text).map((e) => e.uri), ["http://new"]);
    });

    test("恢复存档：地址表合并，正在用的地址、账号密码还是本机的", () {
      var local = {
        LocalStorageService.kWebDAVUri: "http://localhost:8090",
        LocalStorageService.kWebDAVUser: "u",
        WebDavAddressBook.kKey: book([
          const WebDavAddress(uri: "http://localhost:8090", note: "本机", time: t0),
        ]),
      };
      var ext = <String, dynamic>{
        WebDavAddressBook.kKey: book([
          const WebDavAddress(uri: "http://192.168.1.2:8090", note: "局域网", time: t0),
        ]),
      };
      var merged = SyncCompat.mergeRestoredSettings(local, {}, ext);
      expect(merged[LocalStorageService.kWebDAVUri], "http://localhost:8090");
      expect(merged[LocalStorageService.kWebDAVUser], "u");
      expect(
        WebDavAddressBook.parse(merged[WebDavAddressBook.kKey]).map((e) => e.label).toSet(),
        {"本机", "局域网"},
      );
    });

    test("存档来自官方版或旧版（没有地址表）：本机的不变", () {
      var local = {WebDavAddressBook.kKey: book([const WebDavAddress(uri: "http://a", time: t0)])};
      for (var ext in [null, <String, dynamic>{}]) {
        var merged = SyncCompat.mergeRestoredSettings(local, {}, ext);
        expect(merged[WebDavAddressBook.kKey], local[WebDavAddressBook.kKey]);
      }
      expect(
        SyncCompat.mergeRestoredSettings({}, {}, {}).containsKey(WebDavAddressBook.kKey),
        isFalse,
      );
    });

    test("自动同步不同步设置时也合并地址表，改了地址表算本机有改动", () {
      var local = {WebDavAddressBook.kKey: book([const WebDavAddress(uri: "http://a", time: t0)])};
      var ext = <String, dynamic>{
        WebDavAddressBook.kKey: book([const WebDavAddress(uri: "http://b", time: t0)]),
      };
      var merged = SyncCompat.mergeAutoSettings(
        local,
        {},
        ext,
        syncSettings: false,
        syncAccounts: false,
        syncBilibili: false,
      );
      expect(
        WebDavAddressBook.parse(merged[WebDavAddressBook.kKey]).map((e) => e.uri).toSet(),
        {"http://a", "http://b"},
      );
      expect(
        SyncCompat.isAutoSyncedSetting(WebDavAddressBook.kKey, syncSettings: false),
        isTrue,
      );
      // 正在用的地址还是不算
      expect(
        SyncCompat.isAutoSyncedSetting(LocalStorageService.kWebDAVUri, syncSettings: true),
        isFalse,
      );
    });

    test("地址表放在扩展部分，不发给官方版", () {
      var settings = {WebDavAddressBook.kKey: "[]", "kStyleColor": 1};
      expect(SyncCompat.upstreamSettings(settings).containsKey(WebDavAddressBook.kKey), isFalse);
      expect(SyncCompat.extSettings(settings)[WebDavAddressBook.kKey], "[]");
    });

    test("存档和导出的配置里，地址表单独加密：不在明文部分，也不在旧版会解开的账号那一项里", () async {
      var value = book([const WebDavAddress(uri: "http://192.168.1.2", time: t0)]);
      var settings = {
        WebDavAddressBook.kKey: value,
        LocalStorageService.kWebDAVUri: "http://192.168.1.2",
        LocalStorageService.kTwitchToken: "token",
        "kStyleColor": 1,
      };
      var (plain, accounts) = SyncVault.split(settings);
      expect(plain.keys, ["kStyleColor"]);
      expect(accounts.keys, [LocalStorageService.kTwitchToken]);

      var key = await SyncVault.keyFor("u", "p", iterations: 1000);
      var sealed = SyncVault.sealAddresses(settings, key, SyncVault.webDavContext(1))!;
      expect(jsonEncode(sealed), isNot(contains("192.168.1.2")));
      Future<String?> open(String password, String context) => SyncVault.openAddresses(
            sealed,
            user: " U ",
            password: password,
            context: context,
          );
      expect(await open("p", SyncVault.webDavContext(1)), value);
      // 密码不对、换到别的文件（时间戳不同）都解不开
      expect(await open("x", SyncVault.webDavContext(1)), isNull);
      expect(await open("p", SyncVault.webDavContext(2)), isNull);
      // 没有密钥（没登录 WebDAV）、地址表是空的：不写进文件
      expect(SyncVault.sealAddresses(settings, null, "c"), isNull);
      expect(SyncVault.sealAddresses({WebDavAddressBook.kKey: ""}, key, "c"), isNull);
    });
  });

  group("切换地址（真的 WebDAV 客户端，服务器是本机的假服务器）", () {
    late HttpServer a;
    late HttpServer b;
    late Map<String, List<int>> files;
    String at(HttpServer server) => "http://127.0.0.1:${server.port}";

    setUp(() async {
      HttpOverrides.global = null;
      // 同一个服务器的两条路线（比如局域网和外网），文件是同一份
      files = {};
      a = await fakeWebDav(files);
      b = await fakeWebDav(files);
      await storage.setValue(LocalStorageService.kWebDAVUri, at(a));
      await storage.setValue(LocalStorageService.kWebDAVUser, "u");
      await storage.setValue(LocalStorageService.kWebDAVPassword, "p");
    });
    tearDown(() async {
      await a.close(force: true);
      await b.close(force: true);
    });

    test("连得上：换过去，账号密码不变，原来的地址留在列表里，新的排在前面", () async {
      var (result, client) = await WebDavAddressBook.switchTo(" ${at(b)} ");
      expect(result, WebDavSwitchResult.switched);
      expect(uri(), at(b));
      expect(storage.getValue(LocalStorageService.kWebDAVUser, ""), "u");
      expect(storage.getValue(LocalStorageService.kWebDAVPassword, ""), "p");
      expect(WebDavAddressBook.visible(active: uri()).map((e) => e.uri), [at(b), at(a)]);
      // 返回的客户端连的是新地址，能直接用
      await client!.backup(Uint8List.fromList(utf8.encode("zip")));
      expect(utf8.decode(files["/simple_live_app/backup.zip"]!), "zip");
    });

    test("连不上：不保存，还是原来的地址", () async {
      var port = b.port;
      await b.close(force: true);
      var (result, client) = await WebDavAddressBook.switchTo("http://127.0.0.1:$port");
      expect(result, WebDavSwitchResult.offline);
      expect(client, isNull);
      expect(uri(), at(a));
      expect(WebDavAddressBook.load(), isEmpty);
    });

    test("账号密码在新地址不对：不保存", () async {
      await storage.setValue(LocalStorageService.kWebDAVPassword, "wrong");
      var (result, _) = await WebDavAddressBook.switchTo(at(b));
      expect(result, WebDavSwitchResult.offline);
      expect(uri(), at(a));
    });

    test("地址格式不对：不连，不保存", () async {
      for (var input in ["127.0.0.1:${b.port}", "ftp://127.0.0.1", ""]) {
        var (result, _) = await WebDavAddressBook.switchTo(input);
        expect(result, WebDavSwitchResult.invalid);
      }
      expect(uri(), at(a));
    });

    test("就是正在用的地址：测一下，不算切换", () async {
      var (result, _) = await WebDavAddressBook.switchTo("${at(a)}/");
      expect(result, WebDavSwitchResult.same);
      expect(WebDavAddressBook.visible(active: uri()).map((e) => e.key), [at(a)]);
    });
  });

  group("界面", () {
    final addresses = [
      const WebDavAddress(uri: "http://192.168.1.2:8090", note: "局域网", used: 2),
      const WebDavAddress(uri: "https://dav.example.com/dav", used: 1),
    ];

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await tester.pumpAndSettle();
    }

    testWidgets("下拉菜单：点一下填进输入框，长按写备注，正在用的打勾", (tester) async {
      var text = TextEditingController();
      var edited = <WebDavAddress>[];
      await tester.pumpWidget(GetMaterialApp(
        home: Scaffold(
          body: WebDavAddressField(
            controller: text,
            addresses: addresses,
            active: "http://192.168.1.2:8090/",
            onEditNote: edited.add,
          ),
        ),
      ));
      await openMenu(tester);
      expect(find.text("局域网"), findsOneWidget);
      expect(find.text("http://192.168.1.2:8090"), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.text("长按可编辑备注或删除"), findsOneWidget);
      await tester.tap(find.text("https://dav.example.com/dav"));
      await tester.pumpAndSettle();
      expect(text.text, "https://dav.example.com/dav");
      expect(find.text("局域网"), findsNothing);
      await openMenu(tester);
      await tester.longPress(find.text("局域网"));
      await tester.pumpAndSettle();
      expect(edited.single.uri, "http://192.168.1.2:8090");
      // 输入框里的没被改
      expect(text.text, "https://dav.example.com/dav");
    });

    testWidgets("没有用过的地址：不显示下拉按钮", (tester) async {
      await tester.pumpWidget(GetMaterialApp(
        home: Scaffold(
          body: WebDavAddressField(
            controller: TextEditingController(),
            addresses: const [],
            onEditNote: (_) {},
          ),
        ),
      ));
      expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
    });

    testWidgets("备注对话框：保存备注、删除；正在用的地址不能删", (tester) async {
      await WebDavAddressBook.use("http://a", now: t0);
      await WebDavAddressBook.use("http://b", now: t0 + 1);
      await storage.setValue(LocalStorageService.kWebDAVUri, "");
      var controller = Get.put(RemoteSyncWebDAVController());
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      controller.activeUri.value = "http://b";

      var future = controller.editAddressNote(entry("http://a")!);
      await tester.pumpAndSettle();
      expect(find.text("地址备注"), findsOneWidget);
      await tester.enterText(find.byType(TextField), "家里");
      await tester.tap(find.text("保存"));
      await tester.pumpAndSettle();
      await future;
      expect(entry("http://a")!.note, "家里");
      expect(controller.addresses.firstWhere((e) => e.uri == "http://a").label, "家里");

      future = controller.editAddressNote(entry("http://b")!);
      await tester.pumpAndSettle();
      expect(find.text("删除"), findsNothing);
      await tester.tap(find.text("取消"));
      await tester.pumpAndSettle();
      await future;

      future = controller.editAddressNote(entry("http://a")!);
      await tester.pumpAndSettle();
      await tester.tap(find.text("删除"));
      await tester.pumpAndSettle();
      await future;
      expect(controller.addresses.map((e) => e.uri), ["http://b"]);
    });

    testWidgets("切换对话框：填好正在用的地址，从菜单选一个，确认后才切换；没换成时对话框还在",
        (tester) async {
      var controller = Get.put<RemoteSyncWebDAVController>(_FakeController());
      controller.activeUri.value = "http://192.168.1.2:8090";
      controller.addresses.assignAll(addresses);
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      Get.dialog(const WebDavSwitchAddressDialog());
      await tester.pumpAndSettle();
      expect(find.text("切换服务器地址"), findsOneWidget);
      var field = find.byType(TextField);
      expect(tester.widget<TextField>(field).controller!.text, "http://192.168.1.2:8090");
      await openMenu(tester);
      await tester.tap(find.text("https://dav.example.com/dav"));
      await tester.pumpAndSettle();
      // 只是填进去，还没切换
      expect((controller as _FakeController).tried, isEmpty);

      controller.succeed = false;
      await tester.tap(find.text("测试并保存"));
      await tester.pumpAndSettle();
      expect(controller.tried, ["https://dav.example.com/dav"]);
      expect(find.text("切换服务器地址"), findsOneWidget);

      controller.succeed = true;
      await tester.tap(find.text("测试并保存"));
      await tester.pumpAndSettle();
      expect(controller.tried, hasLength(2));
      expect(find.text("切换服务器地址"), findsNothing);
    });

    testWidgets("手机屏幕（320 宽）：对话框和菜单不溢出，长地址省略显示", (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var controller = Get.put<RemoteSyncWebDAVController>(_FakeController());
      controller.activeUri.value = "http://192.168.1.2:8090";
      controller.addresses.assignAll([
        ...addresses,
        const WebDavAddress(
          uri: "https://a-very-long-host-name.example.com:4443/remote.php/dav/files/someone/",
          note: "一个很长很长很长很长很长很长的备注",
        ),
      ]);
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      Get.dialog(const WebDavSwitchAddressDialog());
      await tester.pumpAndSettle();
      await openMenu(tester);
      expect(find.text("一个很长很长很长很长很长很长的备注"), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// 不连网络的控制器：只记下要换的地址
class _FakeController extends RemoteSyncWebDAVController {
  final tried = <String>[];
  var succeed = true;

  @override
  void doWebDAVInit() {}

  @override
  Future<bool> switchAddress(String input) async {
    tried.add(input);
    return succeed;
  }
}
