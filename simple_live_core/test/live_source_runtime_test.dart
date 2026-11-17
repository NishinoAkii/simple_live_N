// 直播源脚本运行时（doc/live_source_api.md）的测试，只连本机服务器
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/script/script_metadata.dart';
import 'package:test/test.dart';

late HttpServer server;
late String base;
late Directory tmp;
final requests = <String>[];
final wsConnections = <String, int>{};
final wsReceived = <String, List<dynamic>>{};
final wsClosed = <String, int>{};
final serverFiles = <String, String>{};

List<int> _protoString(int field, String s) {
  var b = utf8.encode(s);
  return [field << 3 | 2, b.length, ...b];
}

Future<void> _handle(HttpRequest req) async {
  var path = req.uri.path;
  requests.add(path);
  var res = req.response;
  if (path.startsWith("/ws/") && WebSocketTransformer.isUpgradeRequest(req)) {
    var room = path.substring(4);
    var ws = await WebSocketTransformer.upgrade(req);
    var n = wsConnections[room] = (wsConnections[room] ?? 0) + 1;
    wsReceived.putIfAbsent(room, () => []);
    ws.add(jsonEncode({"cmd": "hello", "room": req.headers.value("x-room")}));
    ws.listen(
      (data) {
        wsReceived[room]!.add(data);
        if (data is String && data.startsWith("join:")) {
          if (room == "failme" && n == 1) {
            ws.add(jsonEncode({"cmd": "fail"}));
            return;
          }
          if (room == "sys") {
            ws.add(jsonEncode({"cmd": "sys", "text": "系统提示"}));
          }
          ws.add(jsonEncode({"cmd": "chat", "user": "张三", "text": "你好$n"}));
          ws.add([8, 99, ..._protoString(2, "老板"), ..._protoString(3, "醒目留言")]);
          if (room == "drop" && n == 1) {
            Timer(
              const Duration(milliseconds: 100),
              () => ws.close(4000, "bye"),
            );
          }
        }
      },
      onDone: () {
        wsClosed[room] = (wsClosed[room] ?? 0) + 1;
      },
    );
    return;
  }
  switch (path) {
    case "/rooms":
      var page = int.tryParse(req.uri.queryParameters["page"] ?? "1") ?? 1;
      res.headers.contentType = ContentType.json;
      res.write(
        jsonEncode({
          "hasMore": page < 3,
          "q": req.uri.queryParameters["q"],
          "rooms": [
            {
              "roomId": "r$page",
              "title": "第$page页",
              "cover": "",
              "userName": "主播",
              "online": 100,
            },
          ],
        }),
      );
      break;
    case "/echo":
      var raw = <int>[];
      await for (var chunk in req) {
        raw.addAll(chunk);
      }
      var body = utf8.decode(raw, allowMalformed: true);
      var headers = <String, String>{};
      req.headers.forEach((name, values) => headers[name] = values.join(","));
      res.headers.contentType = ContentType.json;
      res.write(
        jsonEncode({
          "method": req.method,
          "query": req.uri.query,
          "headers": headers,
          "body": body,
          "b64": base64.encode(raw),
        }),
      );
      break;
    case "/bytes":
      res.headers.contentType = ContentType.binary;
      res.add(List.generate(256, (i) => i));
      break;
    case "/setcookie":
      res.headers.add("set-cookie", "sid=abc; Path=/; HttpOnly");
      res.headers.add("set-cookie", "gone=1; Max-Age=0");
      res.headers.add("set-cookie", "other.domain=1; Domain=example.org");
      res.write("ok");
      break;
    case "/cookie":
      res.write(req.headers.value("cookie") ?? "");
      break;
    case "/redirect":
      await req.drain<void>();
      res.statusCode = 302;
      res.headers.set("location", "/echo");
      break;
    case "/redirect-out":
      res.statusCode = 302;
      res.headers.set("location", "https://evil.example.org/");
      break;
    case "/gzip":
      res.headers.set("content-encoding", "gzip");
      res.add(gzip.encode(utf8.encode("压缩的响应")));
      break;
    case "/slow":
      await Future.delayed(const Duration(seconds: 2));
      res.write("late");
      break;
    default:
      var file = serverFiles[path];
      if (file != null) {
        res.write(file);
      } else {
        res.statusCode = 404;
        res.write("not found");
      }
  }
  await res.close();
}

String fixture(String name) => File(
  "test/fixtures/live_sources/$name",
).readAsStringSync().replaceAll("{{BASE}}", base);

/// 把脚本写进临时目录并创建 ScriptLiveSite
ScriptLiveSite loadSite(String name, {String? code}) {
  code ??= fixture(name);
  var dir = Directory("${tmp.path}/sources")..createSync(recursive: true);
  var file = File("${dir.path}/$name")..writeAsStringSync(code);
  var meta = parseLiveSourceScript(code, filename: name);
  return ScriptLiveSite(
    meta.toInfo(file.path),
    dataDirectory: "${tmp.path}/data/${meta.key}",
    appVersion: "9.9.9",
  );
}

Future<void> expectCoreError(Future<dynamic> future, dynamic message) async {
  try {
    await future;
  } on CoreError catch (e) {
    expect(e.message, message);
    return;
  }
  fail("应该抛出 CoreError");
}

String script(String body, {String key = "x", String extra = ""}) =>
    '''
class X extends LiveSource {
  key = "$key";
  name = "X";
  version = "1.0.0";
  $extra
  $body
}
''';

void main() {
  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync("live_source_test_");
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = "http://127.0.0.1:${server.port}";
    server.listen(
      (req) => _handle(req).catchError((Object e) {
        try {
          req.response.close();
        } catch (_) {}
      }),
    );
    ScriptLiveSite.callTimeout = const Duration(seconds: 8);
  });

  tearDownAll(() async {
    await server.close(force: true);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group("元数据", () {
    test("读取字段和功能", () {
      var meta = parseLiveSourceScript(
        fixture("basic.live.js"),
        filename: "basic.live.js",
      );
      expect(meta.key, "test_basic");
      expect(meta.name, "测试直播");
      expect(meta.version, "1.2.3");
      expect(meta.apiVersion, 1);
      expect(meta.description, "运行时测试用");
      expect(meta.url, "$base/sources/basic.live.js");
      expect(meta.domains, ["127.0.0.1", "*.example.com"]);
      expect(meta.links, [r"test\.example\.com/(\d+)"]);
      expect(
        meta.methods,
        containsAll([
          "recommend",
          "categories",
          "categoryRooms",
          "search",
          "searchAnchors",
          "room",
          "qualities",
          "playUrls",
          "superChats",
        ]),
      );
      expect(meta.methods, isNot(contains("avPlayerUrls")));
      expect(meta.methods, isNot(contains("liveStatus")));
      expect(meta.danmaku, isFalse);
      var info = meta.toInfo("/x/basic.live.js");
      expect(info.siteId, "js:test_basic");
      expect(info.capabilities, contains("recommend"));
    });

    test("加载时顶层的网络请求不会发出", () async {
      var before = requests.where((e) => e == "/toplevel").length;
      parseLiveSourceScript(fixture("features.live.js"));
      await Future.delayed(const Duration(milliseconds: 100));
      expect(requests.where((e) => e == "/toplevel").length, before);
    });

    void bad(String code, Matcher message) {
      expect(
        () => parseLiveSourceScript(code, filename: "bad.live.js"),
        throwsA(isA<CoreError>().having((e) => e.message, "message", message)),
      );
    }

    test("校验错误", () {
      bad("var a = 1;", contains("没有找到继承 LiveSource 的类"));
      bad(
        "${script("")}\nclass Y extends LiveSource { key = 'y'; name = 'Y'; version = '1.0.0' }",
        contains("只能有一个继承 LiveSource 的类"),
      );
      bad(script("", key: "Bad-Key"), contains("key 只能包含"));
      bad(
        "class X extends LiveSource { key = 'x'; version = '1.0.0' }",
        contains("缺少必填字段 name"),
      );
      bad(
        "class X extends LiveSource { key = 'x'; name = 'X'; version = 'abc' }",
        contains("version 不是有效的版本号"),
      );
      bad(script("", extra: "apiVersion = 99;"), contains("需要更新的 App"));
      bad(script("", extra: 'links = ["("];'), contains("links 里的正则无效"));
      bad(
        script("", extra: 'domains = ["http://a.com"];'),
        contains("domains 里的域名格式不对"),
      );
      bad(
        script("", extra: 'domains = "a.com";'),
        contains("domains 必须是字符串数组"),
      );
      bad(
        "class X extends LiveSource {\n  key = 'x'\n  name = \n}",
        allOf(contains("脚本语法错误"), contains("bad.live.js:")),
      );
      bad(
        "class X extends LiveSource { constructor() { super(); throw new Error('构造失败'); } }",
        contains("构造失败"),
      );
      // 注释里提到的类名不算
      var ok = parseLiveSourceScript(
        "// class Fake extends LiveSource\n${script("")}",
      );
      expect(ok.className, "X");
    });
  });

  group("ScriptLiveSite", () {
    late ScriptLiveSite site;
    setUpAll(() => site = loadSite("basic.live.js"));
    tearDownAll(() => site.dispose());

    test("功能和链接识别", () async {
      expect(site.id, "js:test_basic");
      expect(site.name, "测试直播");
      expect(site.hasRecommend, isTrue);
      expect(site.hasCategories, isTrue);
      expect(site.hasSearch, isTrue);
      expect(site.hasSearchAnchors, isTrue);
      expect(site.hasSuperChat, isTrue);
      expect(site.hasDanmaku, isFalse);
      expect(site.hasAvPlayer, isFalse);
      expect(site.matchRoomId("看 https://test.example.com/456?x=1"), "456");
      expect(site.matchRoomId("https://other.com/1"), isNull);
      // 没有 danmaku 的源：start 什么也不做
      var none = site.getDanmaku() as ScriptLiveDanmaku;
      var closed = <String>[];
      none.onClose = closed.add;
      await none.start(null);
      expect(none.running, isFalse);
      expect(closed, isEmpty);
    });

    test("推荐、分类、搜索", () async {
      var rec = await site.getRecommendRooms(page: 1);
      expect(rec.hasMore, isTrue);
      expect(rec.items.single.roomId, "r1");
      expect(rec.items.single.title, "第1页");
      expect(rec.items.single.online, 100);
      var cats = await site.getCategores();
      expect(cats.single.id, "game");
      expect(cats.single.children.single.parentId, "game");
      expect(cats.single.children.single.pic, "https://example.com/lol.png");
      var rooms = await site.getCategoryRooms(
        cats.single.children.single,
        page: 2,
      );
      expect(rooms.items.single.roomId, "game-lol");
      expect(rooms.items.single.online, 2);
      var search = await site.searchRooms("关键词", page: 1);
      expect(search.hasMore, isTrue);
      expect(search.items.single.title, "搜索：关键词");
      expect(search.items.single.online, 7);
      var anchors = await site.searchAnchors("主播A");
      expect(anchors.items.single.userName, "主播A");
      expect(anchors.items.single.liveStatus, isTrue);
    });

    test("直播间、清晰度、播放地址、醒目留言", () async {
      var detail = await site.getRoomDetail(roomId: "123");
      expect(detail.roomId, "123");
      expect(detail.title, "房间123");
      expect(detail.userName, "主播123");
      expect(detail.online, 1234);
      expect(detail.status, isTrue);
      expect(detail.introduction, "简介");
      expect(detail.notice, isNull);
      expect(detail.data, {"rid": "123", "n": 1});
      expect(detail.danmakuData, isA<ScriptDanmakuArgs>());
      var qualities = await site.getPlayQualites(detail: detail);
      expect(qualities.map((e) => e.quality), ["原画", "高清"]);
      // 原样传回 room() 返回的对象（包括额外字段）
      expect(qualities.first.data, {
        "q": "origin",
        "rid": "123",
        "extra": "保留字段",
      });
      expect(qualities.map((e) => e.sort), [0, 1]);
      var play = await site.getPlayUrls(
        detail: detail,
        quality: qualities.first,
      );
      expect(
        play.urls.single,
        "https://cdn.example.com/live/123_origin.flv?token=abc",
      );
      expect(play.headers, {"referer": "https://test.example.com/"});
      expect(
        await site.getAvPlayerUrls(detail: detail, quality: qualities.first),
        isNull,
      );
      expect(await site.getLiveStatus(roomId: "123"), isTrue);
      expect(await site.getLiveStatus(roomId: "off"), isFalse);
      var sc = await site.getSuperChatMessage(roomId: "123");
      expect(sc.single.userName, "老板");
      expect(sc.single.message, "加油");
      expect(sc.single.price, 30);
      expect(sc.single.id, "sc1");
      expect(sc.single.startTime.millisecondsSinceEpoch, 1700000000000);
      expect(sc.single.backgroundBottomColor, "#2A60B2");
    });

    test("脚本错误、中文、BigInt、任意方法", () async {
      await expectCoreError(site.getRoomDetail(roomId: "missing"), "房间不存在");
      await expectCoreError(site.callScript("boom"), "脚本出错了");
      await expectCoreError(
        site.callScript("nothing"),
        contains("没有实现 nothing()"),
      );
      var u = await site.callScript("utf8");
      expect(u, {
        "name": "测试直播",
        "len": 4,
        "bytes": "e79bb4e692adf09f9880",
        "back": "直播😀",
      });
      expect(
        await site.callScript("echo", [
          1,
          "中文",
          {
            "b": [true, null],
          },
        ]),
        [
          1,
          "中文",
          {
            "b": [true, null],
          },
        ],
      );
      expect(await site.callScript("big"), {
        "v": "12345678901234567890",
        "s": 5,
      });
    });
  });

  group("全局 API", () {
    late ScriptLiveSite site;
    setUpAll(() => site = loadSite("features.live.js"));
    tearDownAll(() => site.dispose());

    test("Http GET / POST json、form、bytes", () async {
      var j = await site.callScript("httpJson");
      expect(j["status"], 200);
      expect(j["type"], contains("application/json"));
      expect(j["body"]["rooms"][0]["roomId"], "r2");
      expect(j["body"]["q"], "中 文");
      var post = await site.callScript("httpPostJson");
      expect(post["method"], "POST");
      expect(jsonDecode(post["body"]), {"a": 1, "中文": "值"});
      expect(post["headers"]["content-type"], contains("application/json"));
      expect(post["headers"]["user-agent"], contains("Mozilla/5.0"));
      var form = await site.callScript("httpPostForm");
      expect(form["query"], "x=1");
      expect(form["body"], "a=1%202&b=x&b=y");
      expect(
        form["headers"]["content-type"],
        contains("application/x-www-form-urlencoded"),
      );
      expect(form["headers"]["x-test"], "yes");
      expect(form["headers"]["user-agent"], "TestAgent/1.0");
      var put = await site.callScript("httpPutBytes");
      expect(put["method"], "PUT");
      expect(put["b64"], base64.encode([0, 255, 16]));
      expect(put["headers"]["content-type"], "application/octet-stream");
      var bytes = await site.callScript("httpBytes");
      expect(bytes, {"len": 256, "first": 0, "last": 255, "isU8": true});
      var nf = await site.callScript("http404");
      expect(nf["status"], 404);
      expect(nf["body"], "not found");
      expect(nf["jsonBody"], isNull);
      expect(nf["jsonText"], "not found");
      expect(await site.callScript("gzipResponse"), "压缩的响应");
    });

    test("Cookie", () async {
      var c = await site.callScript("cookies");
      expect(c["echoed"], "sid=abc");
      expect(
        c["jar"],
        allOf(contains("sid=abc"), contains("manual=1"), contains("other=2")),
      );
      expect(c["jar"], isNot(contains("gone")));
      expect(
        c["echoed2"],
        allOf(contains("sid=abc"), contains("manual=1"), contains("extra=3")),
      );
      expect(await site.getCookies("$base/"), contains("sid=abc"));
      await site.setCookies(base, "fromApp=1");
      expect(await site.getCookies("$base/a/b"), contains("fromApp=1"));
    });

    test("重定向和域名白名单", () async {
      var r = await site.callScript("redirect");
      expect(r["status"], 200);
      expect(r["url"], "$base/echo");
      expect(r["method"], "GET");
      expect(r["postMethod"], "GET");
      var n = await site.callScript("noRedirect");
      expect(n, {"status": 302, "location": "/echo"});
      await expectCoreError(
        site.callScript("forbidden"),
        contains("不允许访问 not-allowed.example.org"),
      );
      await expectCoreError(
        site.callScript("forbiddenRedirect"),
        contains("不允许访问 evil.example.org"),
      );
      await expectCoreError(site.callScript("httpTimeout"), contains("超时"));
    });

    test("Proto", () async {
      var p = await site.callScript("proto");
      expect(p["hex"], "089601");
      expect(p["v1"], [150, 1099511627776]);
      expect(p["s2"], "直播");
      expect(p["z3"], -5);
      expect(p["f4"], "9223372036854775808");
      expect(p["inner"], [true, "内层"]);
      expect(p["n6"], -1);
      expect(p["b7"], "0102");
      expect(p["f8"], 0xdeadbeef);
      expect(p["d9"], 1.5);
      expect(p["missing"], [0, ""]);
    });

    test("Zip", () async {
      var z = await site.callScript("zip");
      var text = "压缩测试" * 20;
      expect(z["gzMagic"], "1f8b");
      expect(z["gunzip"], text);
      expect(z["inflate"], text);
      expect(z["inflateRaw"], text);
      expect(z["brotli"], "time");
      expect(
        await site.callScript("gunzipBase64", [
          base64.encode(gzip.encode(utf8.encode("来自 Dart"))),
        ]),
        "来自 Dart",
      );
      await expectCoreError(site.callScript("badZip"), contains("解压失败"));
    });

    test("CryptoJS", () async {
      var c = await site.callScript("crypto");
      expect(c["md5"], "5d41402abc4b2a76b9719d911017c592");
      expect(
        c["sha256"],
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      );
      expect(
        c["hmac"],
        "5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0",
      );
      expect(c["ecb"], "69c4e0d86a7b0430d8cdb78070b4c55a");
      expect(c["plain"], "你好，直播");
      expect(c["pass"], "口令加密");
      expect(c["wordArray"], "0102030405");
      expect(c["base64"], base64.encode(utf8.encode("直播")));
    });

    test("Storage 持久化", () async {
      var s = await site.callScript("storage");
      expect(s, {
        "a": {"x": 1, "s": "中文"},
        "b": null,
      });
      // 重启后还在
      await site.shutdown();
      await Future.delayed(const Duration(milliseconds: 200));
      expect(await site.callScript("storageGet", ["a"]), {"x": 1, "s": "中文"});
      expect(File("${site.dataDirectory}/storage.json").existsSync(), isTrue);
    });

    test("定时器", () async {
      List order = await site.callScript("timers");
      expect(order, containsAll(["t5!", "t60", "i1", "i2", "i3"]));
      expect(order, isNot(contains("never")));
      expect(order.where((e) => e.toString().startsWith("i")).length, 3);
      expect(order.indexOf("t5!"), lessThan(order.indexOf("t60")));
    });

    test("TextEncoder、Base64、App、随机", () async {
      var t = await site.callScript("textCodec");
      expect(t, {
        "len": 13,
        "back": "直播abc😀",
        "b64": "aGVsbG8=",
        "atob": "hello",
        "bytesB64": base64.encode(utf8.encode("直播")),
        "fromB64": "直播",
        "concat": "01020304",
      });
      var m = await site.callScript("misc");
      expect(m["app"], {
        "version": "9.9.9",
        "platform": Platform.operatingSystem,
        "apiVersion": 1,
      });
      expect(m["rid"], 12);
      expect(m["uuid"], isTrue);
    });

    test("log 带源名前缀", () async {
      var logs = <String>[];
      var old = CoreLog.onPrintLog;
      CoreLog.onPrintLog = (level, msg) => logs.add(msg);
      try {
        expect(await site.callScript("logs"), isTrue);
        await Future.delayed(const Duration(milliseconds: 100));
      } finally {
        CoreLog.onPrintLog = old;
      }
      expect(logs, contains('[功能测试] 日志 1 {"a":2} Uint8Array(2) abcd'));
      expect(logs, contains("[功能测试] 警告"));
    });
  });

  group("超时和重启", () {
    late ScriptLiveSite site;
    setUp(() {
      site = loadSite("basic.live.js");
      ScriptLiveSite.callTimeout = const Duration(seconds: 1);
      ScriptLiveSite.scriptSliceTimeout = const Duration(milliseconds: 500);
    });
    tearDown(() async {
      ScriptLiveSite.callTimeout = const Duration(seconds: 8);
      ScriptLiveSite.scriptSliceTimeout = const Duration(seconds: 10);
      await site.dispose();
    });

    test("调用超时，连续超时后重启", () async {
      await expectCoreError(site.callScript("never"), contains("超时"));
      expect(site.worker.running, isTrue);
      await expectCoreError(site.callScript("never"), contains("超时"));
      // 连续两次超时：后台已丢弃，下次调用重新启动
      expect(site.worker.running, isFalse);
      expect(await site.callScript("echo", ["ok"]), ["ok"]);
    });

    test("同步死循环被中断，源重启后可用", () async {
      var sw = Stopwatch()..start();
      await expectCoreError(site.callScript("spin"), contains("超时"));
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      expect(await site.callScript("echo", [1]), [1]);
    });
  });

  group("弹幕", () {
    late ScriptLiveSite site;
    setUpAll(() => site = loadSite("danmaku.live.js"));
    tearDownAll(() => site.dispose());

    Future<void> waitFor(
      bool Function() test, {
      Duration timeout = const Duration(seconds: 8),
    }) async {
      var sw = Stopwatch()..start();
      while (!test()) {
        if (sw.elapsed > timeout) fail("等待超时");
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }

    test("WebSocket：消息、心跳、断开后重连、stop", () async {
      expect(site.hasDanmaku, isTrue);
      var detail = await site.getRoomDetail(roomId: "drop");
      var danmaku = site.getDanmaku() as ScriptLiveDanmaku;
      var messages = <LiveMessage>[];
      var closes = <String>[];
      var ready = 0;
      danmaku.onMessage = messages.add;
      danmaku.onClose = closes.add;
      danmaku.onReady = () => ready++;
      await danmaku.start(detail.danmakuData);
      await waitFor(
        () => messages.any((m) => m.type == LiveMessageType.superChat),
      );
      expect(ready, 1);
      var chat = messages.firstWhere((m) => m.type == LiveMessageType.chat);
      expect(chat.userName, "张三");
      expect(chat.message, "你好1");
      expect(chat.color.toString(), "#0000ff");
      expect(chat.face, "https://example.com/f.png");
      var online = messages.firstWhere((m) => m.type == LiveMessageType.online);
      expect(online.data, 99);
      var sc =
          messages.firstWhere((m) => m.type == LiveMessageType.superChat).data
              as LiveSuperChatMessage;
      expect(sc.userName, "老板");
      expect(sc.message, "醒目留言");
      expect(sc.id, "sc99");
      // 服务器 100 毫秒后断开（4000），2 秒后用新会话重连
      await waitFor(() => closes.isNotEmpty);
      expect(closes.first, allOf(contains("4000"), contains("2 秒后重新连接")));
      await waitFor(
        () => messages.any((m) => m.message == "你好2"),
        timeout: const Duration(seconds: 6),
      );
      expect(wsConnections["drop"], 2);
      expect(ready, 2);
      // 心跳（二进制）和 join 都送到了服务器，请求头也带上了
      await waitFor(
        () => wsReceived["drop"]!.whereType<List<int>>().length >= 2,
      );
      expect(wsReceived["drop"], contains("join:drop"));
      var closedBefore = wsClosed["drop"] ?? 0;
      await danmaku.stop();
      await waitFor(() => (wsClosed["drop"] ?? 0) > closedBefore);
      // danmaku.stop 每个会话结束都会调用（断开一次 + 停止一次）
      expect(await site.callScript("getStopped"), greaterThanOrEqualTo(2));
      var count = messages.length;
      await Future.delayed(const Duration(milliseconds: 300));
      expect(messages.length, count);
      expect(wsConnections["drop"], 2);
    });

    test("session.fail 和 system 消息", () async {
      var detail = await site.getRoomDetail(roomId: "failme");
      var danmaku = site.getDanmaku() as ScriptLiveDanmaku;
      var closes = <String>[];
      var messages = <LiveMessage>[];
      danmaku.onClose = closes.add;
      danmaku.onMessage = messages.add;
      await danmaku.start(detail.danmakuData);
      await waitFor(() => closes.isNotEmpty);
      expect(closes.first, "服务器要求断开，2 秒后重新连接");
      await waitFor(
        () => messages.isNotEmpty,
        timeout: const Duration(seconds: 6),
      );
      await danmaku.stop();

      var sys = site.getDanmaku() as ScriptLiveDanmaku;
      var systemTexts = <String>[];
      sys.onSystemMessage = systemTexts.add;
      await sys.start((await site.getRoomDetail(roomId: "sys")).danmakuData);
      await waitFor(() => systemTexts.isNotEmpty);
      expect(systemTexts.single, "系统提示");
      await sys.stop();
    });

    test("轮询型", () async {
      var detail = await site.getRoomDetail(roomId: "poll1");
      var danmaku = site.getDanmaku();
      var messages = <LiveMessage>[];
      var ready = 0;
      danmaku.onMessage = messages.add;
      danmaku.onReady = () => ready++;
      await danmaku.start(detail.danmakuData);
      await waitFor(() => messages.length >= 3);
      expect(ready, 1);
      expect(messages.first.message, "第1次 r1");
      await danmaku.stop();
      var count = messages.length;
      await Future.delayed(const Duration(milliseconds: 200));
      expect(messages.length, lessThanOrEqualTo(count + 1));
    });
  });

  group("联想和直达（suggest / resolve）", () {
    late ScriptLiveSite site;
    setUpAll(() {
      site = loadSite(
        "suggest.live.js",
        code: script(r'''
  async suggest(keyword) {
    if (keyword === "slow") {
      await new Promise((r) => setTimeout(r, 3000));
      return [];
    }
    if (keyword === "words") return ["甲", "  ", 7];
    return [
      { text: "主播A", roomId: "100", avatar: "a.png", live: true },
      { userName: "主播B", roomId: 200, live: false, isRecord: true, subtitle: "游戏" },
      { text: "只是词" },
      { roomId: "" },
    ];
  }
  async resolve(input) {
    if (/^\d+$/.test(input)) return input;
    if (input === "obj") return { roomId: 300 };
    return null;
  }
  async searchAnchors(keyword, page) {
    return {
      hasMore: false,
      anchors: [
        { roomId: "1", userName: "a", live: false, followers: "12", lastTitle: "上次", lastLiveTime: 1700000000, isRecord: 1 },
        { roomId: "2", userName: "b", live: false, lastLiveTime: "2026-10-01T12:00:00Z" },
        { roomId: "3", userName: "c", live: true },
      ],
    };
  }
''', key: "suggest_test"),
      );
    });
    tearDownAll(() => site.dispose());

    test("有 suggest、resolve 时能力里有它们", () {
      expect(site.hasSuggest, isTrue);
      expect(site.hasResolve, isTrue);
      expect(site.info.capabilities, containsAll(["suggest", "resolve"]));
    });

    test("suggest：对象数组（有 roomId 的是频道卡片）或字符串数组", () async {
      var items = await site.getSearchSuggestions("x");
      expect(items, hasLength(3));
      expect(items[0].isRoom, isTrue);
      expect(items[0].roomId, "100");
      expect(items[0].userName, "主播A");
      expect(items[0].avatar, "a.png");
      expect(items[0].liveStatus, isTrue);
      expect(items[1].text, "主播B");
      expect(items[1].roomId, "200");
      expect(items[1].liveStatus, isFalse);
      expect(items[1].isRecord, isTrue);
      expect(items[1].subtitle, "游戏");
      expect(items[2].isRoom, isFalse);
      expect(items[2].text, "只是词");
      expect(items[2].liveStatus, isNull);
      var words = await site.getSearchSuggestions("words");
      expect(words.map((e) => e.text), ["甲", "7"]);
    });

    test("suggest 的超时较短，而且不算进连续超时重启", () async {
      var old = ScriptLiveSite.suggestTimeout;
      ScriptLiveSite.suggestTimeout = const Duration(milliseconds: 300);
      try {
        for (var i = 0; i < 3; i++) {
          await expectCoreError(
            site.getSearchSuggestions("slow"),
            contains("超时"),
          );
        }
        expect(site.worker.running, isTrue);
      } finally {
        ScriptLiveSite.suggestTimeout = old;
      }
    });

    test("resolve：房间号、{roomId} 或 null", () async {
      expect(await site.resolveRoomId("123"), "123");
      expect(await site.resolveRoomId("obj"), "300");
      expect(await site.resolveRoomId("abc"), isNull);
    });

    test("searchAnchors 可以多给粉丝数、上次直播、轮播", () async {
      var result = await site.searchAnchors("x");
      var a = result.items[0];
      expect(a.liveStatus, isFalse);
      expect(a.isRecord, isTrue);
      expect(a.followers, 12);
      expect(a.lastTitle, "上次");
      expect(
        a.lastLiveTime,
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );
      expect(
        result.items[1].lastLiveTime,
        DateTime.parse("2026-10-01T12:00:00Z").toLocal(),
      );
      expect(result.items[2].followers, isNull);
      expect(result.items[2].lastLiveTime, isNull);
    });

    test("没有实现时联想为空、不试直达", () async {
      var basic = loadSite("basic.live.js");
      try {
        expect(basic.hasSuggest, isFalse);
        expect(basic.hasResolve, isFalse);
        expect(await basic.getSearchSuggestions("x"), isEmpty);
        expect(await basic.resolveRoomId("123"), isNull);
      } finally {
        await basic.dispose();
      }
    });
  });

  group("LiveSourceManager", () {
    late Directory repo;
    late Directory appDir;
    late LiveSourceManager manager;

    String source(String key, String version, {String extra = ""}) =>
        '''
class S extends LiveSource {
  key = "$key";
  name = "源 $key";
  version = "$version";
  domains = ["127.0.0.1"];
  $extra
  async room(roomId) { return { roomId, title: "$version", live: true }; }
}
''';

    void writeIndex(Map<String, String> versions, {String name = "测试订阅"}) {
      File("${repo.path}/index.json").writeAsStringSync(
        jsonEncode({
          "name": name,
          "sources": [
            for (var e in versions.entries)
              {
                "key": e.key,
                "name": "源 ${e.key}",
                "version": e.value,
                "url": e.key == "mgr_b" ? "sub/b.live.js" : "${e.key}.live.js",
                "description": "说明",
              },
            {"key": "Bad Key", "version": "1", "url": "x.live.js"},
          ],
        }),
      );
    }

    void serveRepo() {
      for (var f in repo.listSync(recursive: true).whereType<File>()) {
        var rel = f.path.substring(repo.path.length).replaceAll("\\", "/");
        serverFiles["/repo$rel"] = f.readAsStringSync();
      }
    }

    setUp(() async {
      var root = Directory(
        "${tmp.path}/mgr_${DateTime.now().microsecondsSinceEpoch}",
      );
      repo = Directory("${root.path}/repo")..createSync(recursive: true);
      Directory("${repo.path}/sub").createSync();
      appDir = Directory("${root.path}/app");
      File(
        "${repo.path}/mgr_a.live.js",
      ).writeAsStringSync(source("mgr_a", "1.0.0"));
      File(
        "${repo.path}/sub/b.live.js",
      ).writeAsStringSync(source("mgr_b", "2.0.0"));
      writeIndex({"mgr_a": "1.0.0", "mgr_b": "2.0.0"});
      manager = LiveSourceManager(directory: appDir.path, appVersion: "1.24.0");
      await manager.init();
    });

    tearDown(() => manager.dispose());

    test("file:/// 订阅、安装、检查更新、更新、删除", () async {
      expect(manager.sites, isEmpty);
      var changes = 0;
      var sub = manager.changes.listen((_) => changes++);
      var indexUrl = Uri.file("${repo.path}/index.json").toString();
      await manager.addSubscription(indexUrl);
      expect(manager.subscriptions, [indexUrl]);
      expect(manager.subscriptionName(indexUrl), "测试订阅");
      var entries = await manager.fetchSubscription(indexUrl);
      expect(entries.map((e) => e.key), ["mgr_a", "mgr_b"]);
      var a = entries.first;
      expect(a.url, Uri.file("${repo.path}/mgr_a.live.js").toString());
      expect(
        entries.last.url,
        Uri.file("${repo.path}/sub/b.live.js").toString(),
      );
      expect(a.installed, isFalse);
      expect(a.description, "说明");
      expect(a.subscription, indexUrl);

      var info = await manager.installFromUrl(a.url);
      expect(info.key, "mgr_a");
      expect(info.version, "1.0.0");
      expect(File("${appDir.path}/sources/mgr_a.live.js").existsSync(), isTrue);
      expect(manager.sites.single.id, "js:mgr_a");
      expect(
        (await manager.fetchSubscription(indexUrl)).first.installedVersion,
        "1.0.0",
      );
      expect(await manager.checkUpdates(), isEmpty);
      expect(manager.lastUpdateCheck, isNotNull);

      // 发布新版本
      File(
        "${repo.path}/mgr_a.live.js",
      ).writeAsStringSync(source("mgr_a", "1.1.0"));
      writeIndex({"mgr_a": "1.1.0", "mgr_b": "2.0.0"});
      var updates = await manager.checkUpdates();
      expect(updates.single.key, "mgr_a");
      expect(updates.single.version, "1.1.0");
      expect(updates.single.hasUpdate, isTrue);
      var site = manager.site("mgr_a")!;
      expect((await site.getRoomDetail(roomId: "1")).title, "1.0.0");
      var updated = await manager.update("mgr_a");
      expect(updated.version, "1.1.0");
      expect(manager.site("mgr_a"), isNot(same(site)));
      expect(
        (await manager.site("mgr_a")!.getRoomDetail(roomId: "1")).title,
        "1.1.0",
      );

      // 重新加载后还在
      var again = LiveSourceManager(
        directory: appDir.path,
        appVersion: "1.24.0",
      );
      await again.init();
      expect(again.sites.single.info.version, "1.1.0");
      expect(again.subscriptions, [indexUrl]);
      await again.dispose();

      await Directory("${appDir.path}/data/mgr_a").create(recursive: true);
      await manager.remove("mgr_a");
      expect(manager.sites, isEmpty);
      expect(
        File("${appDir.path}/sources/mgr_a.live.js").existsSync(),
        isFalse,
      );
      expect(Directory("${appDir.path}/data/mgr_a").existsSync(), isFalse);
      await manager.removeSubscription(indexUrl);
      expect(manager.subscriptions, isEmpty);
      await Future.delayed(Duration.zero);
      expect(changes, greaterThanOrEqualTo(5));
      await sub.cancel();
    });

    test("http 订阅（相对地址）和 installFromFile", () async {
      serveRepo();
      var indexUrl = "$base/repo/index.json";
      await manager.addSubscription(indexUrl);
      var entries = await manager.fetchSubscription(indexUrl);
      expect(entries.last.url, "$base/repo/sub/b.live.js");
      var info = await manager.installFromUrl(entries.last.url);
      expect(info.key, "mgr_b");
      expect(info.version, "2.0.0");

      var local = File("${repo.path}/local.live.js")
        ..writeAsStringSync(
          source(
            "mgr_local",
            "0.1.0",
            extra: 'url = "$base/repo/local.live.js";',
          ),
        );
      var localInfo = await manager.installFromFile(local.path);
      expect(localInfo.key, "mgr_local");
      expect(
        manager.sites.map((e) => e.info.key),
        containsAll(["mgr_b", "mgr_local"]),
      );
      // 不在订阅里的源按脚本自己的 url 检查更新
      serverFiles["/repo/local.live.js"] = source(
        "mgr_local",
        "0.2.0",
        extra: 'url = "$base/repo/local.live.js";',
      );
      var updates = await manager.checkUpdates();
      var local2 = updates.singleWhere((e) => e.key == "mgr_local");
      expect(local2.version, "0.2.0");
      expect(local2.subscription, "");
      expect((await manager.update("mgr_local")).version, "0.2.0");
    });

    test("安装失败、加载错误", () async {
      var bad = File("${repo.path}/bad.live.js")
        ..writeAsStringSync("class X extends LiveSource { key = 'bad' }");
      await expectCoreError(
        manager.installFromFile(bad.path),
        contains("缺少必填字段 name"),
      );
      await expectCoreError(
        manager.installFromUrl("http://example.com/a.live.js"),
        contains("只支持 https://"),
      );
      await expectCoreError(
        manager.installFromUrl("$base/repo/none.live.js"),
        contains("404"),
      );
      var newer = File("${repo.path}/newer.live.js")
        ..writeAsStringSync(
          source("mgr_new", "1.0.0", extra: "apiVersion = 2;"),
        );
      await expectCoreError(
        manager.installFromFile(newer.path),
        contains("需要更新的 App"),
      );
      await expectCoreError(
        manager.addSubscription(
          Uri.file("${repo.path}/mgr_a.live.js").toString(),
        ),
        contains("订阅"),
      );
      expect(manager.subscriptions, isEmpty);
      expect(manager.sites, isEmpty);

      // 目录里坏掉的脚本、重复的 key
      var sources = Directory("${appDir.path}/sources");
      File(
        "${sources.path}/broken.live.js",
      ).writeAsStringSync("class X extends LiveSource {");
      File(
        "${sources.path}/mgr_a.live.js",
      ).writeAsStringSync(source("mgr_a", "1.0.0"));
      File(
        "${sources.path}/zz_copy.live.js",
      ).writeAsStringSync(source("mgr_a", "1.0.0"));
      var again = LiveSourceManager(
        directory: appDir.path,
        appVersion: "1.24.0",
      );
      await again.init();
      expect(again.sites.single.info.key, "mgr_a");
      expect(
        again.loadErrors.keys,
        containsAll(["broken.live.js", "zz_copy.live.js"]),
      );
      expect(again.loadErrors["broken.live.js"], contains("语法错误"));
      expect(again.loadErrors["zz_copy.live.js"], contains("重复"));
      await again.removeFile("broken.live.js");
      expect(again.loadErrors.keys, isNot(contains("broken.live.js")));
      await again.dispose();
    });
  });
}
