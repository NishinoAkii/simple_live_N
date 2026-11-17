import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/window_apply.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/multi_window/window_changes.dart';
import 'package:simple_live_app/app/multi_window/window_link.dart';
import 'package:simple_live_app/app/multi_window/window_server.dart';
import 'package:simple_live_app/app/play_prefs.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/account_follow/account_follow_models.dart';
import 'package:simple_live_app/services/chat_users/chat_user.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/chat_users/user_block_store.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

// 多开：副窗口把要留下的改动交给主窗口（两头都在这个进程里）

class _RecordingSink implements WindowChangeSink {
  final changes = <WindowChange>[];
  Object? failWith;

  @override
  Future<void> apply(WindowChange change) async {
    if (failWith != null) {
      throw failWith!;
    }
    changes.add(change);
  }
}

class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

FollowUser _follow(String room, {bool notify = false}) => FollowUser(
      id: "douyu_$room",
      roomId: room,
      siteId: "douyu",
      userName: "主播$room",
      face: "",
      addTime: DateTime(2026, 11, 15, 10),
      notify: notify,
    );

History _history(String room) => History(
      id: "douyu_$room",
      roomId: room,
      siteId: "douyu",
      userName: "主播$room",
      face: "",
      updateTime: DateTime(2026, 11, 15, 11),
      title: "标题",
    );

/// 等异步发出去的改动到主窗口
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: "等了 2 秒还没到");
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 测试框架默认把 HTTP 请求都换成假的 400，这里要真连本机的服务
  HttpOverrides.global = null;
  late _RecordingSink sink;
  late WindowServer server;
  late String token;

  setUp(() async {
    sink = _RecordingSink();
    server = WindowServer(sink, pollTimeout: const Duration(seconds: 2));
    await server.start();
    token = server.addPeer();
  });

  tearDown(() async {
    MultiWindow.link?.dispose();
    MultiWindow.link = null;
    MultiWindow.launch = null;
    await server.close();
  });

  MainWindowLink link(
          {List<(WindowChange, bool)>? unsaved, String? withToken}) =>
      MainWindowLink(
        port: server.port,
        token: withToken ?? token,
        onUnsaved: (c, gone) => unsaved?.add((c, gone)),
      );

  Future<HttpClientResponse> raw(String method, String path,
      {String? token,
      Object? body,
      Map<String, String> headers = const {}}) async {
    var client = HttpClient();
    var request = await client.open(method, "127.0.0.1", server.port, path);
    if (token != null) {
      request.headers.set(WindowServer.tokenHeader, token);
    }
    headers.forEach(request.headers.set);
    if (body != null) {
      request.add(utf8.encode(body is String ? body : json.encode(body)));
    }
    var response = await request.close();
    try {
      await response.drain<void>();
    } on HttpException {
      // 太大的请求：主窗口回了 413 就断开，不再读剩下的
    }
    client.close();
    return response;
  }

  test("只听 127.0.0.1，端口是系统随机给的；只收 8 种改动", () {
    expect(server.address!.address, "127.0.0.1");
    expect(server.port, greaterThan(0));
    expect(WindowChange.ops, hasLength(8));
  });

  test("每种改动都原样到了主窗口，按发出的顺序", () async {
    var l = link();
    var changes = <WindowChange>[
      FollowAdded(_follow("1"), FollowChangeOrigin.user),
      FollowRemoved(_follow("2"), FollowChangeOrigin.user, localOnly: true),
      const FollowNotifyChanged("douyu_1", true),
      HistoryPut(_history("1")),
      const HistoryRemoved(["douyu_1", "douyu_2"]),
      const HistoryCleared(live: true),
      ChatUsersChanged(ChatUsersChanged.blocks, add: [
        UserBlock(siteId: "douyu", userId: "7", name: "甲", createdAt: 5)
            .toJson()
      ]),
      const QualityRemembered(
          siteId: "douyu", name: "超清", index: 1, cellular: false),
    ];
    for (var c in changes) {
      expect(await l.send(c), isTrue, reason: c.op);
    }
    expect(sink.changes.map((e) => e.op), changes.map((e) => e.op));
    for (var i = 0; i < changes.length; i++) {
      expect(json.encode(sink.changes[i].data), json.encode(changes[i].data),
          reason: changes[i].op);
    }
    var removed = sink.changes[1] as FollowRemoved;
    expect(removed.localOnly, isTrue);
    expect(removed.user.id, "douyu_2");
    l.dispose();
  });

  test("口令不对、没有口令、作废了的口令、浏览器发来的都不收", () async {
    var body = {
      "op": HistoryRemoved.opName,
      "data": {
        "ids": ["douyu_1"]
      },
    };
    expect((await raw("POST", "/op", body: body)).statusCode, 401);
    expect(
        (await raw("POST", "/op", token: WindowToken.generate(), body: body))
            .statusCode,
        401);
    expect(
        (await raw("POST", "/op", token: "${token}x", body: body)).statusCode,
        401);
    expect(
        (await raw("POST", "/op",
                token: token,
                body: body,
                headers: {"origin": "https://example.com"}))
            .statusCode,
        403);
    expect(sink.changes, isEmpty);
    // 口令对的照常收
    expect(
        (await raw("POST", "/op", token: token, body: body)).statusCode, 200);
    expect(sink.changes, hasLength(1));
    // 副窗口关了以后口令作废
    server.removePeer(token);
    expect(
        (await raw("POST", "/op", token: token, body: body)).statusCode, 401);
    // 作废以后副窗口这边算主窗口不在了
    var unsaved = <(WindowChange, bool)>[];
    var l = link(unsaved: unsaved);
    expect(await l.send(const HistoryRemoved(["x_1"])), isFalse);
    expect(unsaved.single.$2, isTrue);
    l.dispose();
  });

  test("只收列出的几种改动，内容逐项检查", () async {
    Future<int> post(Object body) async =>
        (await raw("POST", "/op", token: token, body: body)).statusCode;
    expect(await post({"op": "settings.set", "data": {}}), 400);
    expect(await post({"op": FollowAdded.opName}), 400);
    expect(await post("not json"), 400);
    expect(await post([1, 2]), 400);
    // 少了房间号
    var user = _follow("1").toJson()..remove("roomId");
    expect(
        await post({
          "op": FollowAdded.opName,
          "data": {"user": user, "origin": "user"}
        }),
        400);
    // origin 不在列表里
    expect(
        await post({
          "op": FollowAdded.opName,
          "data": {"user": _follow("1").toJson(), "origin": "hack"}
        }),
        400);
    // 类型不对
    expect(
        await post({
          "op": FollowNotifyChanged.opName,
          "data": {"id": "douyu_1", "notify": "yes"}
        }),
        400);
    expect(
        await post({
          "op": QualityRemembered.opName,
          "data": {
            "siteId": "douyu",
            "name": "超清",
            "index": 500,
            "cellular": false
          }
        }),
        400);
    // 屏蔽记录没有用户 ID
    expect(
        await post({
          "op": ChatUsersChanged.opName,
          "data": {
            "key": "blocks",
            "add": [
              {"s": "douyu", "n": "甲"}
            ],
            "remove": []
          }
        }),
        400);
    expect(
        await post({
          "op": ChatUsersChanged.opName,
          "data": {"key": "settings", "add": [], "remove": []}
        }),
        400);
    // 太大的不收
    expect(
        await post({
          "op": HistoryRemoved.opName,
          "data": {"ids": List.filled(600, "a" * 500)}
        }),
        413);
    // 别的地址、方法
    expect((await raw("GET", "/op", token: token)).statusCode, 404);
    expect((await raw("DELETE", "/wait", token: token)).statusCode, 404);
    expect(sink.changes, isEmpty);
  });

  test("主窗口不在了：改动算没保存，之后的也不再发", () async {
    var unsaved = <(WindowChange, bool)>[];
    var gone = 0;
    var l = MainWindowLink(
      port: server.port,
      token: token,
      onUnsaved: (c, g) => unsaved.add((c, g)),
      onMainGone: () => gone++,
    );
    expect(await l.ping(), isTrue);
    expect(await l.send(HistoryPut(_history("1"))), isTrue);
    await server.close();
    expect(await l.send(FollowAdded(_follow("1"), FollowChangeOrigin.user)),
        isFalse);
    expect(l.online, isFalse);
    expect(gone, 1);
    expect(await l.send(const FollowNotifyChanged("douyu_1", true)), isFalse);
    expect(unsaved.map((e) => e.$1.op),
        [FollowAdded.opName, FollowNotifyChanged.opName]);
    expect(unsaved.every((e) => e.$2), isTrue);
    expect(gone, 1);
    l.dispose();
  });

  test("主窗口存的时候出错：算没保存，但主窗口还在", () async {
    var unsaved = <(WindowChange, bool)>[];
    var l = link(unsaved: unsaved);
    sink.failWith = StateError("disk full");
    expect(await l.send(const HistoryRemoved(["a_1"])), isFalse);
    expect(unsaved.single.$2, isFalse);
    expect(l.online, isTrue);
    l.dispose();
  });

  test("等指令：主窗口要求关闭时副窗口收到；主窗口没了也知道", () async {
    var l = link();
    var closed = 0;
    var watching = l.watch(onClose: () => closed++);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    server.requestClose(token);
    await watching;
    expect(closed, 1);
    expect(l.online, isTrue);
    l.dispose();

    // 主窗口没了：等着的请求断开，算主窗口不在了
    var token2 = server.addPeer();
    var gone = 0;
    var l2 = MainWindowLink(
        port: server.port, token: token2, onMainGone: () => gone++);
    var watching2 = l2.watch(onClose: () => closed++);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await server.close();
    await watching2;
    expect(gone, 1);
    expect(closed, 1);
    l2.dispose();
  });

  group("真正改的地方：副窗口里改，主窗口里存", () {
    late Directory dir;

    setUp(() async {
      Get.testMode = true;
      dir = Directory.systemTemp.createTempSync("multi_window_");
      Hive.init(dir.path);
      if (!Hive.isAdapterRegistered(1)) {
        Hive.registerAdapter(FollowUserAdapter());
      }
      if (!Hive.isAdapterRegistered(2)) {
        Hive.registerAdapter(HistoryAdapter());
      }
      if (!Hive.isAdapterRegistered(3)) {
        Hive.registerAdapter(FollowUserTagAdapter());
      }
      var db = DBService()
        ..followBox = await Hive.openBox<FollowUser>("FollowUser")
        ..tagBox = await Hive.openBox<FollowUserTag>("FollowUserTag")
        ..historyBox = await Hive.openBox<History>("History");
      Get.put(db);
      Get.put<AppSettingsController>(_TestSettings())
          .autoUpdateFollowEnable
          .value = false;
      Get.put(FollowService());
      await Get.put(ChatUsersService(
              storage: MemoryChatUsersStorage(), purgeInterval: null))
          .init();
      PlayPrefs.instance = PlayPrefs.forTest();
    });

    tearDown(() async {
      PlayPrefs.instance = null;
      Get.reset();
      await Hive.close();
      dir.deleteSync(recursive: true);
    });

    void becomeSecondary() {
      MultiWindow.launch = SecondaryLaunch(
        port: server.port,
        token: token,
        dataDir: dir.path,
        slot: 1,
        siteId: "douyu",
        roomId: "1",
      );
      MultiWindow.link = link();
    }

    void becomeMain() {
      MultiWindow.link?.dispose();
      MultiWindow.link = null;
      MultiWindow.launch = null;
    }

    test("关注、取关、开播提醒、观看记录、清晰度", () async {
      becomeSecondary();
      var db = DBService.instance;
      var follow = FollowService.instance;
      await follow.follow(_follow("1"));
      await follow.follow(_follow("2"));
      await follow.unfollow(_follow("2"), localOnly: true);
      await follow.setNotify(db.followBox.get("douyu_1")!, true);
      await db.addOrUpdateHistory(_history("1"));
      await db.addOrUpdateHistory(_history("2"));
      await db.deleteHistory("douyu_2");
      PlayPrefs.instance.rememberManualQuality(
        "douyu",
        [
          LivePlayQuality(quality: "原画", data: 0),
          LivePlayQuality(quality: "超清", data: 1),
        ],
        1,
        cellular: false,
      );
      // 副窗口自己的快照里也改了
      expect(db.followBox.keys, ["douyu_1"]);
      await _until(() => sink.changes.length == 8);
      expect(sink.changes.map((e) => e.op), [
        FollowAdded.opName,
        FollowAdded.opName,
        FollowRemoved.opName,
        FollowNotifyChanged.opName,
        HistoryPut.opName,
        HistoryPut.opName,
        HistoryRemoved.opName,
        QualityRemembered.opName,
      ]);

      // 换成主窗口：清空数据库，把收到的改动存进去
      becomeMain();
      await db.followBox.clear();
      await db.historyBox.clear();
      PlayPrefs.instance = PlayPrefs.forTest();
      var apply = AppWindowChangeSink();
      for (var c in sink.changes) {
        await apply.apply(c);
      }
      expect(db.followBox.keys, ["douyu_1"]);
      expect(db.followBox.get("douyu_1")!.notify, isTrue);
      expect(db.historyBox.keys, ["douyu_1"]);
      expect(db.getHistory("douyu_1")!.title, "标题");
      expect(
          PlayPrefs.instance.remembered("douyu", cellular: false)?.name, "超清");

      // 清空记录也能交过去
      becomeSecondary();
      sink.changes.clear();
      await db.clearHistories();
      await _until(() => sink.changes.isNotEmpty);
      var cleared = sink.changes.single as HistoryCleared;
      expect(cleared.live, isTrue);
    });

    /// 在主窗口那边存（这时不是副窗口，存的时候不会再往外发）
    void applyOnMain(ChatUsersService main) {
      var launch = MultiWindow.launch;
      MultiWindow.launch = null;
      for (var c in sink.changes) {
        main.applyWindowChange(c as ChatUsersChanged);
      }
      MultiWindow.launch = launch;
    }

    test("屏蔽、撤销、备注：主窗口只动改了的那几条", () async {
      // 主窗口原来就屏蔽了乙
      var main = ChatUsersService(
          storage: MemoryChatUsersStorage(), purgeInterval: null);
      await main.init();
      main.blocks.add(UserBlock(siteId: "douyu", userId: "2", name: "乙"));

      becomeSecondary();
      var secondary = ChatUsersService.instance;
      const jia = ChatUser("douyu", userId: "1", name: "甲");
      var block = UserBlock(
          siteId: "douyu", userId: "1", name: "甲", expireAt: 9999999999999);
      var replaced = secondary.blocks.add(block);
      secondary.remarks.set(jia, "老朋友");
      await _until(() => sink.changes.length == 2);
      applyOnMain(main);
      expect(
          main.blocks.items.map((e) => e.userId), unorderedEquals(["1", "2"]));
      expect(main.remarkOf(jia), "老朋友");

      // 撤销屏蔽、删掉备注
      sink.changes.clear();
      secondary.blocks.undo(block, replaced);
      secondary.remarks.set(jia, "");
      await _until(() => sink.changes.length == 2);
      applyOnMain(main);
      expect(main.blocks.items.map((e) => e.userId), ["2"]);
      expect(main.remarkOf(jia), isNull);
    });
  });
}
