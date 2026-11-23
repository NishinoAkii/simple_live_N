import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/secondary_process.dart';
import 'package:simple_live_app/app/multi_window/window_apply.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/multi_window/window_changes.dart';
import 'package:simple_live_app/app/multi_window/window_link.dart';
import 'package:simple_live_app/app/multi_window/window_server.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';
import 'package:simple_live_app/app/play_prefs.dart';
import 'package:simple_live_app/app/window_geometry.dart';
import 'package:simple_live_app/app/window_memory.dart';
import 'package:simple_live_app/app/window_pin.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/account_follow/account_follow_models.dart';
import 'package:simple_live_app/services/chat_users/chat_user.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/chat_users/user_block_store.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'fakes/memory_storage.dart';

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

/// 假的副窗口进程：自己退出（[exit]）或者被强制结束时才退出
class _FakeProcess implements SecondaryProcess {
  _FakeProcess(this.args);

  /// 启动参数（口令在里面）
  final List<String> args;
  final _done = Completer<void>();
  var killed = false;

  /// 被强制结束时记一笔（看关全部时的顺序）
  List<String>? log;

  /// 为 false 时强制结束以后要等 [exit] 才算退出（真的进程退出的消息晚一点才来）
  var exitOnKill = true;

  /// 主窗口开始等它退出（关全部时，已经要它关了）
  void Function()? onWait;
  var _waits = 0;

  @override
  Future<void> get exited {
    // 第一次是开窗口时挂上的；之后是关全部时在等它退出
    if (_waits++ > 0) {
      onWait?.call();
    }
    return _done.future;
  }

  void exit() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  void kill() {
    killed = true;
    log?.add("kill");
    if (exitOnKill) {
      exit();
    }
  }
}

/// 写进去的设置可以先压着：[hold] 不为空时，写的要等它
class _SlowStorage extends MemoryStorage {
  Completer<void>? hold;

  @override
  Future setValue<T>(dynamic key, T value) async {
    var gate = hold;
    if (gate != null) {
      await gate.future;
    }
    return super.setValue<T>(key, value);
  }
}

/// 记下关全部时按什么顺序调的
class _LoggingRecorder extends WindowSetRecorder {
  _LoggingRecorder(this.log)
      : super(
          mainRoom: () => MultiWindow.mainRoom,
          mainLayout: MultiWindow.mainLayoutNow,
          saveDelay: Duration.zero,
        );
  final List<String> log;

  @override
  Future<bool> closingAll() {
    log.add("closingAll");
    return super.closingAll();
  }

  @override
  void rememberClosing() {
    log.add("rememberClosing");
    super.rememberClosing();
  }

  @override
  Future<void> flush() {
    log.add("flush");
    return super.flush();
  }
}

/// 假的主窗口（window_manager）、屏幕（screen_retriever）和应用数据目录（path_provider）：
/// 窗口放到哪里就在哪里（window_manager 的逻辑坐标）
class _FakeDesktop {
  Rect bounds = const Rect.fromLTWH(100, 100, 1000, 700);
  bool maximized = false;
  late Directory support;

  /// 不为空时问“最大化没有”要等它（量主窗口量到一半）
  Completer<void>? holdMaximized;
  var maximizedAsked = 0;

  static const _window = MethodChannel("window_manager");
  static const _screens =
      MethodChannel("dev.leanflutter.plugins/screen_retriever");
  static const _paths = MethodChannel("plugins.flutter.io/path_provider");

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install() {
    support = Directory.systemTemp.createTempSync("sl_multi_window_");
    // 屏幕的缩放和窗口现在的一样（不用等缩放换过来）
    var scale = WindowMemory.windowScale;
    _messenger.setMockMethodCallHandler(_window, (call) async {
      switch (call.method) {
        case "isFullScreen":
        case "isMinimized":
          return false;
        case "isMaximized":
          maximizedAsked++;
          await holdMaximized?.future;
          return maximized;
        case "maximize":
          maximized = true;
        case "unmaximize":
          maximized = false;
        case "getBounds":
          return {
            "x": bounds.left,
            "y": bounds.top,
            "width": bounds.width,
            "height": bounds.height,
          };
        case "setBounds":
          var a = call.arguments as Map;
          bounds = Rect.fromLTWH(
              (a["x"] as num).toDouble(),
              (a["y"] as num).toDouble(),
              (a["width"] as num).toDouble(),
              (a["height"] as num).toDouble());
      }
      return null;
    });
    _messenger.setMockMethodCallHandler(
        _screens,
        (call) async => {
              "displays": [
                {
                  "id": "1",
                  "name": "screen",
                  "size": {"width": 1920.0, "height": 1080.0},
                  "visiblePosition": {"dx": 0.0, "dy": 0.0},
                  "visibleSize": {"width": 1920.0, "height": 1032.0},
                  "scaleFactor": scale,
                },
              ],
            });
    _messenger.setMockMethodCallHandler(_paths, (call) async => support.path);
  }

  void uninstall() {
    for (var channel in [_window, _screens, _paths]) {
      _messenger.setMockMethodCallHandler(channel, null);
    }
    try {
      support.deleteSync(recursive: true);
    } on FileSystemException {
      // 快照目录还在删
    }
  }
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

  test("副窗口报告在看的直播间和位置：交给主窗口，口令对的才收", () async {
    var got = <(String, WindowReport)>[];
    server.onReport = (t, r) => got.add((t, r));
    var l = link();
    expect(
        await l.report(const WindowReport(
            room: WindowRoom(siteId: "douyu", roomId: "1", userName: "主播"))),
        isTrue);
    expect(
        await l.report(const WindowReport(
            bounds: Rect.fromLTWH(-1912, 8, 629, 504), scale: 1.5)),
        isTrue);
    expect(got.map((e) => e.$1), [token, token]);
    expect(got[0].$2.room!.userName, "主播");
    expect(got[0].$2.bounds, isNull);
    expect(got[1].$2.bounds, const Rect.fromLTWH(-1912, 8, 629, 504));
    expect(got[1].$2.scale, 1.5);
    // 没口令、内容不对、太大的不收
    var room = {"site": "douyu", "room": "1"};
    expect((await raw("POST", "/state", body: {"room": room})).statusCode, 401);
    expect(
        (await raw("POST", "/state",
                token: token,
                body: {"room": room},
                headers: {"origin": "https://example.com"}))
            .statusCode,
        403);
    expect(
        (await raw("POST", "/state", token: token, body: {})).statusCode, 400);
    expect(
        (await raw("POST", "/state",
                token: token,
                body: {"x": 1, "y": 2, "w": 0, "h": 4, "scale": 1}))
            .statusCode,
        400);
    expect(
        (await raw("POST", "/state", token: token, body: {
          "room": {"site": "douyu", "room": "1", "title": "x" * 20000}
        }))
            .statusCode,
        413);
    expect((await raw("GET", "/state", token: token)).statusCode, 404);
    expect(got, hasLength(2));
    // 报告不算改动
    expect(sink.changes, isEmpty);
    l.dispose();

    // 主窗口不在了：报告没送到，不提示“没保存”，算主窗口不在了
    var unsaved = <(WindowChange, bool)>[];
    var l2 = link(unsaved: unsaved);
    await server.close();
    expect(
        await l2.report(const WindowReport(
            bounds: Rect.fromLTWH(0, 0, 800, 450), scale: 1.0)),
        isFalse);
    expect(l2.online, isFalse);
    expect(unsaved, isEmpty);
    l2.dispose();
  });

  test("副窗口里换了直播间：没报的设置先报（算原来那个直播间的），新的直播间从头报", () async {
    var got = <WindowReport>[];
    server.onReport = (_, r) => got.add(r);
    MultiWindow.launch = SecondaryLaunch(
      port: server.port,
      token: token,
      dataDir: "/tmp/multi_window/w1-1",
      slot: 1,
      siteId: "douyu",
      roomId: "71",
    );
    MultiWindow.link = link();
    var page = Object();
    const plain = WindowSettings(volume: 40, muted: false, danmaku: true);
    const louder = WindowSettings(volume: 60, muted: false, danmaku: true);
    MultiWindow.noteRoom(page, const WindowRoom(siteId: "douyu", roomId: "71"));
    MultiWindow.noteSettings(page, plain);
    // 在 71 里调了音量，还没到报的时候就换到 72
    MultiWindow.noteSettings(page, louder,
        delay: const Duration(seconds: 5));
    MultiWindow.noteRoom(page, const WindowRoom(siteId: "douyu", roomId: "72"));
    // 换过来以后马上报现在的：和换之前最后报的一样也照报（主窗口那边 72 从这里算起）
    MultiWindow.noteSettings(page, louder);
    // 读到主播名（同一个直播间）：不算换，一样的设置不再报
    MultiWindow.noteRoom(page,
        const WindowRoom(siteId: "douyu", roomId: "72", userName: "乙"));
    MultiWindow.noteSettings(page, louder);
    // 收起聊天栏：报一次
    MultiWindow.noteChatCollapsed(page, true);
    MultiWindow.noteChatCollapsed(page, true);
    await _until(() => got.length == 7);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(got, hasLength(7));
    expect(got.map((e) => e.room?.roomId),
        ["71", null, null, "72", null, "72", null]);
    expect(got[1].settings, plain);
    expect(got[2].settings, louder);
    expect(got[4].settings, louder);
    expect(got[5].room!.userName, "乙");
    expect(got[6].chatCollapsed, isTrue);
    expect(got[6].windowFull, isNull);
  });

  test("副窗口：抖音换成平台认的房间号不算换直播间，设置不从头报", () async {
    var got = <WindowReport>[];
    server.onReport = (_, r) => got.add(r);
    MultiWindow.launch = SecondaryLaunch(
      port: server.port,
      token: token,
      dataDir: "/tmp/multi_window/w1-1",
      slot: 1,
      siteId: "douyin",
      roomId: "81",
    );
    MultiWindow.link = link();
    var page = Object();
    const plain = WindowSettings(volume: 40, muted: true, danmaku: true);
    MultiWindow.noteRoom(
        page, const WindowRoom(siteId: "douyin", roomId: "81"));
    MultiWindow.noteSettings(page, plain);
    // 读到直播间信息，房间号换成 WebRid：带着原来的房间号报，一样的设置不再报
    MultiWindow.noteRoom(
        page, const WindowRoom(siteId: "douyin", roomId: "8001"),
        renamedFrom: "81");
    MultiWindow.noteSettings(page, plain);
    // 原来的房间号对不上：照换了直播间算，设置从头报
    MultiWindow.noteRoom(page, const WindowRoom(siteId: "douyin", roomId: "9"),
        renamedFrom: "81");
    MultiWindow.noteSettings(page, plain);
    await _until(() => got.length == 5);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(got, hasLength(5));
    expect(got.map((e) => e.room?.roomId), ["81", null, "8001", "9", null]);
    expect(got.map((e) => e.renamedFrom), [null, null, "81", null, null]);
    expect(got[1].settings, plain);
    expect(got[4].settings, plain);
  });

  test("主窗口置顶、取消置顶：开着的副窗口都跟着变；副窗口自己点只改自己", () async {
    var host = WindowHost(sink, WindowSetRecorder());
    addTearDown(() async {
      host.dispose();
      WindowPin.instance.pinned.value = false;
      await host.server.close();
    });
    await host.server.start();
    var tokens = [host.server.addPeer(), host.server.addPeer()];
    var got = [<bool>[], <bool>[]];
    var links = [
      for (var i = 0; i < 2; i++)
        MainWindowLink(port: host.server.port, token: tokens[i]),
    ];
    // 第二个还没开始等指令：之后来取时照样收到
    unawaited(links[0].watch(onClose: () {}, onPin: got[0].add));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    WindowPin.instance.pinned.value = true;
    await _until(() => got[0].length == 1);
    unawaited(links[1].watch(onClose: () {}, onPin: got[1].add));
    await _until(() => got[1].length == 1);
    WindowPin.instance.pinned.value = false;
    await _until(() => got[0].length == 2 && got[1].length == 2);
    expect(got, [
      [true, false],
      [true, false],
    ]);

    // 副窗口自己点置顶：只在它那个进程里，不往主窗口发任何东西
    MultiWindow.launch = SecondaryLaunch(
      port: host.server.port,
      token: tokens[0],
      dataDir: "/tmp/multi_window/w1-1",
      slot: 1,
      siteId: "douyu",
      roomId: "1",
    );
    var reports = 0;
    host.server.onReport = (_, __) => reports++;
    if (WindowPin.supported) {
      await WindowPin.instance.toggle();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(reports, 0);
    expect(sink.changes, isEmpty);
    for (var l in links) {
      l.dispose();
    }
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

  group("主窗口开窗口、关窗口（假的进程和桌面）", () {
    late _FakeDesktop desktop;
    late _SlowStorage storage;
    late WindowSetRecorder savedRecorder;
    var processes = <_FakeProcess>[];
    const room1 = WindowRoom(siteId: "douyu", roomId: "1");
    const room2 = WindowRoom(siteId: "douyu", roomId: "2");

    Future<SecondaryProcess> start(String exe, List<String> args) async {
      var process = _FakeProcess(args);
      processes.add(process);
      return process;
    }

    /// [settle]：主窗口放回去以后等多久再量；默认的很长，测试里用 [MultiWindow.remeasureNow]
    WindowHost host(WindowSetRecorder recorder,
        {Duration settle = const Duration(minutes: 10)}) {
      MultiWindow.recorder = recorder;
      var host =
          WindowHost(sink, recorder, startProcess: start, mainSettle: settle);
      addTearDown(() async {
        host.dispose();
        await host.server.close();
      });
      return host;
    }

    WindowSet? open() =>
        WindowSet.decode(storage.values[WindowSetRecorder.kOpen] as String?);

    setUp(() {
      storage = _SlowStorage();
      Get.put<LocalStorageService>(storage);
      desktop = _FakeDesktop()..install();
      savedRecorder = MultiWindow.recorder;
      MultiWindow.debugSupported = true;
      processes = [];
    });

    tearDown(() async {
      for (var p in processes) {
        p.kill();
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      MultiWindow.recorder = savedRecorder;
      MultiWindow.debugSupported = null;
      MultiWindow.mainRestoreRequest.value = null;
      desktop.uninstall();
      Get.reset();
    });

    test("打开上次的一组：主窗口放回记的位置，开着的这一组马上记下，系统挪完以后再量一次", () async {
      var recorder = WindowSetRecorder(
        mainRoom: () => MultiWindow.mainRoom,
        mainLayout: MultiWindow.mainLayoutNow,
        saveDelay: Duration.zero,
      );
      var h = host(recorder);
      var scale = WindowMemory.windowScale;
      Rect physical(Rect r) => Rect.fromLTWH(
          r.left * scale, r.top * scale, r.width * scale, r.height * scale);
      var target = WindowPlacement(
          physical(const Rect.fromLTWH(200, 150, 1200, 800)), scale);
      var result = (await h.restore(WindowSet(
        [
          const WindowEntry(
              slot: 1, room: room1, bounds: Rect.fromLTWH(10, 10, 800, 450)),
        ],
        mainRoom: const WindowRoom(siteId: "douyu", roomId: "9"),
        mainPlacement: target,
        time: DateTime(2026, 11, 23),
      )))!;
      expect(result.opened, 1);
      expect(processes, hasLength(1));
      // 主窗口挪到了记的位置；开着的这一组记的是放回去的，不是放之前量到的
      expect(desktop.bounds, const Rect.fromLTWH(200, 150, 1200, 800));
      expect(MultiWindow.mainPlacement!.rect, target.rect);
      expect(open()!.mainPlacement!.rect, target.rect);
      // 等系统挪完再量：测试里不等时间到，自己让它量
      expect(MultiWindow.remeasurePending, isTrue);
      // 系统随后又挪了一下（贴靠、换到别的屏幕）：再量的时候记下挪到的地方
      desktop.bounds = const Rect.fromLTWH(260, 180, 1200, 800);
      var moved = physical(const Rect.fromLTWH(260, 180, 1200, 800));
      await MultiWindow.remeasureNow();
      expect(MultiWindow.remeasurePending, isFalse);
      expect(MultiWindow.mainPlacement!.rect, moved);
      expect(open()!.mainPlacement!.rect, moved);
      expect(open()!.mainPlacement!.maximized, isFalse);
    });

    test("量主窗口量到一半时又放回了一次：量到的是放回之前的，不用", () async {
      MultiWindow.recorder = WindowSetRecorder(
        mainRoom: () => MultiWindow.mainRoom,
        mainLayout: MultiWindow.mainLayoutNow,
        saveDelay: Duration.zero,
      );
      var scale = WindowMemory.windowScale;
      Rect physical(Rect r) => Rect.fromLTWH(
          r.left * scale, r.top * scale, r.width * scale, r.height * scale);

      /// 放回 [first] 以后再量，量到一半（问最大化没有）时又放回了 [then]
      Future<void> placeTwice(WindowPlacement then) async {
        var asked = desktop.maximizedAsked;
        desktop.holdMaximized = Completer<void>();
        MultiWindow.mainPlaced(
            WindowPlacement(
                physical(const Rect.fromLTWH(0, 0, 800, 600)), scale),
            settle: const Duration(milliseconds: 10));
        await _until(() => desktop.maximizedAsked > asked);
        MultiWindow.mainPlaced(then, settle: const Duration(milliseconds: 200));
        // 系统真的把窗口挪过去了（之后再量时量到的就是这里）
        desktop.bounds = Rect.fromLTWH(
            then.rect.left / scale,
            then.rect.top / scale,
            then.rect.width / scale,
            then.rect.height / scale);
        desktop.maximized = then.maximized;
        var hold = desktop.holdMaximized!;
        desktop.holdMaximized = null;
        hold.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      // 量到一半的那次用的是放回之前的位置：不用，留着后放回的
      var placed = WindowPlacement(
          physical(const Rect.fromLTWH(300, 200, 1200, 800)), scale);
      await placeTwice(placed);
      expect(MultiWindow.mainPlacement!.rect, placed.rect);
      expect(MultiWindow.mainPlacement!.maximized, isFalse);
      // 后放回的是最大化的（连同最大化之前的位置）：也不换成先放回的
      var maximized = WindowPlacement(
          physical(const Rect.fromLTWH(400, 250, 1200, 800)), scale,
          maximized: true);
      await placeTwice(maximized);
      expect(MultiWindow.mainPlacement!.rect, maximized.rect);
      expect(MultiWindow.mainPlacement!.maximized, isTrue);
      // 之后照常再量一次：最大化着，留着放回去时的位置
      await _until(() => !MultiWindow.remeasurePending);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(MultiWindow.mainPlacement!.rect, maximized.rect);
      expect(MultiWindow.mainPlacement!.maximized, isTrue);
    });

    test("关全部：没退出的强制结束，先照最后报的记下它的直播间，再等都写完", () async {
      var log = <String>[];
      var recorder = _LoggingRecorder(log);
      var h = host(recorder);
      var result = (await h.restore(WindowSet(
        [
          const WindowEntry(
              slot: 1, room: room1, bounds: Rect.fromLTWH(10, 10, 800, 450)),
          const WindowEntry(
              slot: 2, room: room2, bounds: Rect.fromLTWH(820, 10, 800, 450)),
        ],
        time: DateTime(2026, 11, 23),
      )))!;
      expect(result.opened, 2);
      expect(MultiWindow.openCount.value, 2);
      // 第二个自己先关了：从这一组去掉，它的直播间记下
      processes[1].exit();
      await _until(() => MultiWindow.openCount.value == 1);
      expect(open()!.windows.map((e) => e.slot), [1]);
      expect(recorder.roomLayout(room2), isNotNull);
      // 第一个关全部时一直不退出：要它关以后才报了最后的音量这些、进了窗口全屏（都还没记成
      // 这个直播间的），之后被强制结束，退出的消息晚一点才来
      var first = processes[0]
        ..log = log
        ..exitOnKill = false;
      var token = SecondaryLaunch.parse(first.args)!.token;
      const last = WindowSettings(
          volume: 55, muted: true, danmaku: false, quality: "原画");
      first.onWait = () {
        log.add("report");
        h.server.onReport!(
            token, const WindowReport(settings: last, windowFull: true));
        // 之后写的先压着：写完以前不算关好
        storage.hold = Completer<void>();
      };
      var done = false;
      var closing = h
          .closeAll(grace: const Duration(milliseconds: 50))
          .whenComplete(() => done = true);
      await _until(() => log.contains("flush"));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // 强制结束以后先照最后报上来的记下（主窗口可能马上退出），再等写完
      expect(log, ["closingAll", "report", "kill", "rememberClosing", "flush"]);
      expect(first.killed, isTrue);
      expect(done, isFalse);
      storage.hold!.complete();
      expect(await closing, 1);
      expect(recorder.roomSettings(room1), last.roomPart);
      expect(recorder.roomLayout(room1)!.windowFull, isTrue);
      expect(storage.values[WindowSetRecorder.kRoomLayouts] as String,
          contains("douyu_1"));
      expect(recorder.last.value!.windows.map((e) => e.slot), [1]);
      first.exit();
      await _until(() => MultiWindow.openCount.value == 0);
    });
  });
}
