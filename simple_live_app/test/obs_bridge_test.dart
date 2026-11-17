import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/obs_bridge/ass_writer.dart';
import 'package:simple_live_app/services/obs_bridge/danmaku_recorder.dart';
import 'package:simple_live_app/services/obs_bridge/obs_bridge_hub.dart';
import 'package:simple_live_app/services/obs_bridge/obs_bridge_server.dart';
import 'package:simple_live_app/services/obs_bridge/obs_events.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_core/simple_live_core.dart';

LiveMessage chat(
  String text, {
  String user = "观众",
  LiveMessageColor? color,
  List<LiveEmote>? emotes,
  LiveEmote? sticker,
  String? face,
}) =>
    LiveMessage(
      type: LiveMessageType.chat,
      userName: user,
      message: text,
      color: color ?? LiveMessageColor.white,
      emotes: emotes,
      sticker: sticker,
      face: face,
    );

LiveSuperChatMessage superChat({String id = "sc1", int seconds = 60}) {
  var start = DateTime.now();
  return LiveSuperChatMessage(
    id: id,
    userName: "老板",
    face: "https://example.com/face.png",
    message: "加油",
    price: 30,
    startTime: start,
    endTime: start.add(Duration(seconds: seconds)),
    backgroundColor: "#EDF5FF",
    backgroundBottomColor: "FF2A60B2",
  );
}

const room = ObsRoomInfo(
  site: "bilibili",
  siteName: "哔哩哔哩",
  roomId: "6",
  title: "标题",
  streamer: "主播",
  live: true,
  url: "https://live.bilibili.com/6",
  online: 100,
);

const config = <String, dynamic>{
  "size": 16.0,
  "speed": 10.0,
  "area": 0.8,
  "opacity": 1.0,
  "stroke": 2.0,
  "fontWeight": 4,
  "emoteImage": true,
  "emoteScale": 1.0,
  "chatSize": 14.0,
  "chatShowFace": true,
};

/// 跳过不匹配的行，等到第一行满足 [test] 的
Future<String> nextLine(
    StreamIterator<String> lines, bool Function(String) test) async {
  while (await lines.moveNext().timeout(const Duration(seconds: 5))) {
    if (test(lines.current)) {
      return lines.current;
    }
  }
  throw StateError("流已结束");
}

Future<bool> waitFor(bool Function() test) async {
  for (var i = 0; i < 100; i++) {
    if (test()) return true;
    await Future.delayed(const Duration(milliseconds: 50));
  }
  return test();
}

void main() {
  group('事件 JSON', () {
    test('聊天：表情、大表情、颜色、头像', () {
      var msg = chat(
        "你好[doge]",
        color: LiveMessageColor(255, 0, 0),
        emotes: const [
          LiveEmote(
              text: "[doge]", url: "https://e/doge.png", width: 20, height: 20),
          LiveEmote(text: "[没图]", url: ""),
        ],
        face: "https://e/face.png",
      );
      var json =
          ObsEvents.chat(msg, id: 7, time: 123, site: "bilibili", roomId: "6");
      expect(json, {
        "v": 1,
        "type": "chat",
        "id": 7,
        "time": 123,
        "site": "bilibili",
        "roomId": "6",
        "user": "观众",
        "text": "你好[doge]",
        "color": "#ff0000",
        "face": "https://e/face.png",
        "emotes": [
          {
            "text": "[doge]",
            "url": "https://e/doge.png",
            "width": 20,
            "height": 20
          },
        ],
        "sticker": null,
      });
      var sticker = ObsEvents.chat(
        chat("赞",
            sticker: const LiveEmote(text: "赞", url: "https://e/zan.png")),
        id: 8,
        time: 124,
        site: "bilibili",
        roomId: "6",
      );
      expect(sticker["sticker"],
          {"text": "赞", "url": "https://e/zan.png", "width": 0, "height": 0});
      expect(sticker["emotes"], isEmpty);
      expect(sticker["face"], isNull);
      // 能编码成 JSON
      expect(jsonDecode(jsonEncode(json)), json);
    });

    test('醒目留言：金额、起止时间、颜色转成 #rrggbb', () {
      var sc = superChat();
      var json = ObsEvents.superChat(sc,
          id: 1, time: 5, site: "bilibili", roomId: "6");
      expect(json["type"], "superchat");
      expect(json["scId"], "sc1");
      expect(json["priceText"], "￥30");
      expect(json["start"], sc.startTime.millisecondsSinceEpoch);
      expect(json["end"], sc.endTime.millisecondsSinceEpoch);
      expect(json["color"], "#edf5ff");
      expect(json["colorBottom"], "#2a60b2");
      expect(ObsEvents.cssColor("bad"), isNull);
    });

    test('直播间', () {
      var json = ObsEvents.room(room, time: 1);
      expect(json["type"], "room");
      expect((json["room"] as Map)["roomId"], "6");
      expect(ObsEvents.room(null, time: 1)["room"], isNull);
      expect(room.label, "哔哩哔哩 6 标题 - 主播");
    });
  });

  group('ASS', () {
    const options = AssOptions();

    test('文件头：画面大小、样式来自弹幕设置', () {
      var o = AssOptions.fromConfig({
        ...config,
        "opacity": 0.5,
        "speed": 8.0,
        "fontWeight": 6,
      });
      expect(o.fontSize, 32);
      expect(o.outline, 2);
      expect(o.scrollDuration, const Duration(seconds: 8));
      expect(o.bold, isTrue);
      var header = AssDanmakuWriter(o).header(title: "测试");
      expect(header, startsWith("[Script Info]\n"));
      expect(header, contains("Title: 测试\n"));
      expect(header, contains("PlayResX: 1920\nPlayResY: 1080\n"));
      expect(header, contains("WrapStyle: 2\n"));
      expect(header, contains("ScaledBorderAndShadow: yes\n"));
      expect(
        header,
        contains("Style: Default,Microsoft YaHei,32,&H80FFFFFF,&H80FFFFFF,"
            "&H80000000,&H80000000,-1,0,0,0,100,100,0,0,1,2,0,7,0,0,0,1\n"),
      );
      expect(
        header,
        endsWith("[Events]\nFormat: Layer, Start, End, Style, Name, "
            "MarginL, MarginR, MarginV, Effect, Text\n"),
      );
    });

    test('时间格式', () {
      expect(assTime(Duration.zero), "0:00:00.00");
      expect(assTime(const Duration(milliseconds: 3723456)), "1:02:03.46");
    });

    test('滚动弹幕：从右边进入，完全移出左边；同时的弹幕分到不同行', () {
      var writer = AssDanmakuWriter(options);
      expect(writer.laneHeight, 39);
      expect(writer.laneCount, 22);
      var first = writer.line(AssComment.chat(chat("你好")));
      expect(
        first,
        "Dialogue: 0,0:00:00.00,0:00:10.00,Default,观众,0,0,0,,"
        "{\\move(1920,0,-68,0)}你好",
      );
      var second = writer.line(AssComment.chat(chat("abc", user: "a,b")));
      // ASCII 每个字约 0.55 个字宽：3 × 0.55 × 32 + 描边 4 = 56.8
      expect(
        second,
        "Dialogue: 0,0:00:00.00,0:00:10.00,Default,a，b,0,0,0,,"
        "{\\move(1920,39,-57,39)}abc",
      );
      // 5 秒后第一行已经空出来
      var third =
          writer.line(AssComment.chat(chat("你好"), const Duration(seconds: 5)));
      expect(third, contains("{\\move(1920,0,-68,0)}"));
      expect(third, startsWith("Dialogue: 0,0:00:05.00,0:00:15.00,"));
    });

    test('后面的长弹幕更快，会追上前一条时换一行', () {
      var writer = AssDanmakuWriter(options);
      writer.line(AssComment.chat(chat("a")));
      // 进入时前一条早已完全进入画面，但移出前会追上它
      var long = writer
          .line(AssComment.chat(chat("长" * 60), const Duration(seconds: 1)));
      expect(long, contains(",39,"));
      // 短的不会追上
      var short =
          writer.line(AssComment.chat(chat("b"), const Duration(seconds: 1)));
      expect(short, contains("{\\move(1920,0,"));
    });

    test('没有空行时丢掉；keepAll 时叠在最早的一行上', () {
      var small = const AssOptions(area: 0.05);
      var writer = AssDanmakuWriter(small);
      expect(writer.laneCount, 1);
      expect(writer.line(AssComment.chat(chat("一"))), isNotNull);
      expect(writer.line(AssComment.chat(chat("二"))), isNull);
      expect(writer.written, 1);
      expect(writer.dropped, 1);
      var all = AssDanmakuWriter(const AssOptions(area: 0.05, keepAll: true));
      all.line(AssComment.chat(chat("一")));
      expect(all.line(AssComment.chat(chat("二"))), contains("{\\move(1920,0,"));
    });

    test('转义花括号、反斜杠和换行；颜色只在不是白色时写', () {
      expect(escapeAssText("{\\b1}x\\N\ny"), "\\{\\\u200bb1\\}x\\\u200bN y");
      var writer = AssDanmakuWriter(options);
      var red = writer.line(
          AssComment.chat(chat("{红}", color: LiveMessageColor(255, 0, 0))));
      expect(red, endsWith("{\\move(1920,0,-72,0)\\c&H0000FF&}\\{红\\}"));
      var white = writer.line(AssComment.chat(chat("白")));
      expect(white, isNot(contains("\\c&H")));
      expect(writer.line(AssComment.chat(chat("   "))), isNull);
    });

    test('表情保留文字，大表情用它的文字说明', () {
      var c = AssComment.chat(chat("好[doge]",
          emotes: const [LiveEmote(text: "[doge]", url: "https://e/d.png")]));
      expect(c.text, "好[doge]");
      var s = AssComment.chat(chat("",
          sticker: const LiveEmote(text: "[大笑]", url: "https://e/s.png")));
      expect(s.text, "[大笑]");
    });

    test('顶部、底部固定弹幕和醒目留言', () {
      var writer = AssDanmakuWriter(options);
      var top = writer.line(const AssComment(
          time: Duration.zero, text: "顶", type: AssCommentType.top));
      expect(
          top,
          "Dialogue: 1,0:00:00.00,0:00:04.00,Default,,0,0,0,,"
          "{\\an8\\pos(960,0)}顶");
      var top2 = writer.line(const AssComment(
          time: Duration(seconds: 1), text: "顶2", type: AssCommentType.top));
      expect(top2, contains("{\\an8\\pos(960,39)}"));
      var bottom = writer.line(const AssComment(
          time: Duration.zero, text: "底", type: AssCommentType.bottom));
      expect(bottom, contains("{\\an2\\pos(960,1080)}底"));
      var sc = writer
          .line(AssComment.superChat(superChat(), const Duration(seconds: 10)));
      expect(
        sc,
        "Dialogue: 2,0:00:10.00,0:00:18.00,Default,老板,0,0,0,,"
        "{\\an8\\pos(960,0)\\c&H4FD5FF&}【SC ￥30】老板：加油",
      );
      var noSc = AssDanmakuWriter(const AssOptions(superChats: false));
      expect(noSc.line(AssComment.superChat(superChat())), isNull);
      expect(
        writer.line(const AssComment.note(Duration(seconds: 2), "直播间：{x}")),
        "Comment: 0,0:00:02.00,0:00:02.00,Default,,0,0,0,,直播间：\\{x\\}",
      );
    });

    test('一次写出整个文件时按时间排序', () {
      var text = AssDanmakuWriter.build(options, [
        AssComment.chat(chat("后"), const Duration(seconds: 3)),
        AssComment.chat(chat("前"), const Duration(seconds: 1)),
      ]);
      expect(text.indexOf("}前"), lessThan(text.indexOf("}后")));
    });

    test('文件名', () {
      var name = assFileName(
        site: "js:acfun",
        roomId: "a b",
        time: DateTime(2026, 10, 28, 9, 5, 7),
      );
      expect(name, "SimpleLive_js_acfun_a_b_20261028-090507.ass");
      expect(assFileName(time: DateTime(2026, 1, 2, 3, 4, 5)),
          "SimpleLive_20260102-030405.ass");
    });
  });

  group('数据', () {
    test('换直播间时先 clear 再 room，并清掉最近消息', () async {
      var hub = ObsBridgeHub();
      var events = <String>[];
      var sub = hub.events.listen((e) => events.add(e.type));
      hub.addChat(chat("没有直播间时忽略"));
      expect(hub.lastId, 0);
      hub.setRoom(room);
      hub.addChat(chat("一"));
      hub.addChat(chat("二"));
      hub.setOnline(200);
      hub.setRoom(room.copyWith(online: 200)); // 没变
      hub.addSuperChat(superChat());
      hub.addSuperChat(superChat()); // 同一个 SC
      await Future.delayed(Duration.zero);
      expect(events, ["clear", "room", "chat", "chat", "online", "superchat"]);
      expect(hub.room!.online, 200);
      expect(hub.messagesSince(1).map((e) => e["id"]), [2, 3]);
      expect(hub.messagesSince(99).length, 3); // 接口重启过
      expect(hub.recentChats(1).single["text"], "二");
      expect(hub.activeSuperChats().length, 1);
      hub.setRoom(const ObsRoomInfo(site: "douyu", roomId: "1"));
      expect(hub.messagesSince(0), isEmpty);
      expect(hub.activeSuperChats(), isEmpty);
      hub.setRoom(null);
      await Future.delayed(Duration.zero);
      expect(events.skip(6), ["clear", "room", "clear", "room"]);
      await sub.cancel();
      await hub.close();
    });

    test('弹幕记录有上限，进房时读到的历史 SC 不写进记录', () async {
      var hub = ObsBridgeHub(historyLimit: 3);
      hub.setRoom(room);
      for (var i = 0; i < 5; i++) {
        hub.addChat(chat("$i"));
      }
      hub.addSuperChat(superChat(), live: false);
      expect(hub.historyLength, 3);
      expect(hub.history().map((e) => e.comment.text), ["2", "3", "4"]);
      await hub.close();
    });
  });

  group('HTTP 服务', () {
    late ObsBridgeHub hub;
    late ObsBridgeServer server;
    late HttpClient client;
    var now = 1000000;

    Future<(int, String, HttpHeaders)> get(String path,
        {Map<String, String>? headers}) async {
      var request = await client
          .getUrl(Uri.parse("http://127.0.0.1:${server.boundPort}$path"));
      headers?.forEach(request.headers.set);
      var response = await request.close();
      var body = await response.transform(utf8.decoder).join();
      return (response.statusCode, body, response.headers);
    }

    Future<List<int>> getBytes(String path) async {
      var request = await client
          .getUrl(Uri.parse("http://127.0.0.1:${server.boundPort}$path"));
      var response = await request.close();
      var bytes = <int>[];
      await for (var chunk in response) {
        bytes.addAll(chunk);
      }
      return bytes;
    }

    setUp(() async {
      now = 1000000;
      hub = ObsBridgeHub(clock: () => now);
      server = ObsBridgeServer(hub: hub, config: () => config, port: 0);
      await server.start();
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      await hub.close();
    });

    test('/api/room、/api/messages、/api/config', () async {
      var (status, body, _) = await get("/api/room");
      expect(status, 200);
      expect(jsonDecode(body)["room"], isNull);

      hub.setRoom(room);
      hub.addChat(chat("一"));
      hub.addChat(chat("二"));
      (status, body, _) = await get("/api/room");
      expect(jsonDecode(body)["room"]["title"], "标题");

      (status, body, _) = await get("/api/messages?since=1");
      var data = jsonDecode(body);
      expect(data["lastId"], 2);
      expect(data["instance"], hub.instance);
      expect((data["messages"] as List).map((e) => e["text"]), ["二"]);

      (status, body, _) = await get("/api/config");
      expect(jsonDecode(body), {"v": 1, ...config});

      (status, body, _) = await get("/nothing");
      expect(status, 404);
    });

    test('页面：不用外部脚本，首页列出地址', () async {
      for (var path in ["/overlay", "/chat", "/sc"]) {
        var (status, body, headers) = await get(path);
        expect(status, 200);
        expect(headers.contentType?.mimeType, "text/html");
        expect(body, contains("background: transparent"));
        expect(body, contains("new WebSocket"));
        expect(body, isNot(contains("<script src")));
        expect(body, isNot(contains("<link")));
      }
      var (_, index, _) = await get("/");
      var base = "http://127.0.0.1:${server.boundPort}";
      expect(index, contains("$base/overlay"));
      expect(index, contains("$base/ass/live"));
      expect(index, contains('"type":"chat"'));
      expect(index, isNot(contains("token=")));
    });

    test('只监听本机时拒绝别的 Host', () async {
      var (status, _, _) =
          await get("/api/room", headers: {"host": "evil.example"});
      expect(status, 403);
    });

    test('WebSocket：连上先收到 room，之后收到推送的聊天', () async {
      hub.setRoom(room);
      hub.addChat(chat("之前的"));
      var socket = await WebSocket.connect(
          "ws://127.0.0.1:${server.boundPort}/ws?history=5");
      var messages = StreamIterator(socket.map((e) => jsonDecode(e as String)));
      Future<Map> next() async {
        expect(await messages.moveNext().timeout(const Duration(seconds: 5)),
            isTrue);
        return messages.current as Map;
      }

      var first = await next();
      expect(first["type"], "room");
      expect(first["room"]["roomId"], "6");
      var earlier = await next();
      expect(earlier["text"], "之前的");
      expect(await waitFor(() => server.webSocketCount == 1), isTrue);

      hub.addChat(chat("你好[doge]", emotes: const [
        LiveEmote(text: "[doge]", url: "https://e/d.png", width: 1, height: 1),
      ]));
      var event = await next();
      expect(event["type"], "chat");
      expect(event["text"], "你好[doge]");
      expect(event["emotes"][0]["url"], "https://e/d.png");
      expect(event["site"], "bilibili");

      hub.setRoom(null);
      expect((await next())["type"], "clear");
      var closed = await next();
      expect(closed["type"], "room");
      expect(closed["room"], isNull);
      await socket.close();
      await messages.cancel();
    });

    test('/api/ass 按时间范围导出，时间从 from 算起', () async {
      hub.setRoom(room); // 1000000 的备注
      now = 1001000;
      hub.addChat(chat("早"));
      now = 1002000;
      hub.addChat(chat("中"));
      now = 1005000;
      hub.addChat(chat("晚"));
      var bytes = await getBytes("/api/ass?from=1001500&to=1003000");
      expect(bytes.take(3), [0xef, 0xbb, 0xbf]);
      var (status, body, headers) =
          await get("/api/ass?from=1001500&to=1003000");
      expect(status, 200);
      expect(body.replaceFirst("\uFEFF", ""), startsWith("[Script Info]"));
      expect(body, contains("Dialogue: 0,0:00:00.50,0:00:10.50,Default,观众,"));
      expect(body, contains("}中"));
      expect(body, isNot(contains("}早")));
      expect(body, isNot(contains("}晚")));
      expect(body, isNot(contains("Comment:")));
      var name = assFileName(
        site: "bilibili",
        roomId: "6",
        time: DateTime.fromMillisecondsSinceEpoch(1001500),
      );
      expect(
          headers.value("content-disposition"), contains('filename="$name"'));

      // 不带范围：全部，从最早一条（换直播间的备注）算起
      (status, body, _) = await get("/api/ass?w=1280&h=720");
      expect(body, contains("PlayResX: 1280"));
      expect(
          body,
          contains(
              "Comment: 0,0:00:00.00,0:00:00.00,Default,,0,0,0,,直播间：哔哩哔哩 6 标题 - 主播"));
      expect(body, contains("Dialogue: 0,0:00:01.00,"));
      expect(body, contains("Dialogue: 0,0:00:05.00,"));

      (status, _, _) = await get("/api/ass?from=abc");
      expect(status, 400);
    });

    test('/ass/live：先写文件头，之后每条弹幕一行；断开后结束', () async {
      hub.setRoom(room);
      var request = await client
          .getUrl(Uri.parse("http://127.0.0.1:${server.boundPort}/ass/live"));
      var response = await request.close();
      expect(response.statusCode, 200);
      var lines = StreamIterator(
          response.transform(utf8.decoder).transform(const LineSplitter()));
      await nextLine(lines, (e) => e.startsWith("Format: Layer"));
      expect(await nextLine(lines, (e) => e.isNotEmpty),
          contains("直播间：哔哩哔哩 6 标题 - 主播"));
      expect(server.assStreamCount, 1);

      now += 2500;
      hub.addChat(chat("你好"));
      var line = await nextLine(lines, (e) => e.startsWith("Dialogue:"));
      expect(
          line,
          "Dialogue: 0,0:00:02.50,0:00:12.50,Default,观众,0,0,0,,"
          "{\\move(1920,0,-68,0)}你好");

      now += 500;
      hub.setRoom(
          const ObsRoomInfo(site: "douyu", siteName: "斗鱼直播", roomId: "9"));
      expect(await nextLine(lines, (e) => e.startsWith("Comment:")),
          "Comment: 0,0:00:03.00,0:00:03.00,Default,,0,0,0,,直播间：斗鱼直播 9");

      await lines.cancel();
      client.close(force: true);
      // 对方断开后不再保留这个连接（不用等下一次写入）
      expect(await waitFor(() => server.assStreamCount == 0), isTrue);
    });
  });

  group('HTTP 服务（停止）', () {
    test('接口停止时 /ass/live 正常结束（chunked 结束标记）', () async {
      var hub = ObsBridgeHub();
      var server = ObsBridgeServer(hub: hub, config: () => config, port: 0);
      await server.start();
      var client = HttpClient();
      addTearDown(() => client.close(force: true));
      var request = await client
          .getUrl(Uri.parse("http://127.0.0.1:${server.boundPort}/ass/live"));
      var response = await request.close();
      expect(response.headers.chunkedTransferEncoding, isTrue);
      var lines = StreamIterator(
          response.transform(utf8.decoder).transform(const LineSplitter()));
      await nextLine(lines, (e) => e.startsWith("Format: Layer"));
      await server.stop();
      // 流正常结束，没有报错
      var more = <String>[];
      while (await lines.moveNext().timeout(const Duration(seconds: 5))) {
        more.add(lines.current);
      }
      expect(more.where((e) => e.startsWith("Dialogue:")), isEmpty);
      expect(server.assStreamCount, 0);
      await hub.close();
    });

    test('WebSocket 补发还在显示的醒目留言', () async {
      var hub = ObsBridgeHub();
      var server = ObsBridgeServer(hub: hub, config: () => config, port: 0);
      await server.start();
      hub.setRoom(room);
      hub.addSuperChat(superChat(id: "a"));
      hub.addSuperChat(superChat(id: "ended", seconds: -1));
      hub.addChat(chat("聊天不补发"));
      var socket = await WebSocket.connect(
          "ws://127.0.0.1:${server.boundPort}/ws?superchats=1");
      var events = <Map>[];
      var sub = socket.listen((e) => events.add(jsonDecode(e as String)));
      expect(await waitFor(() => events.length >= 2), isTrue);
      await Future.delayed(const Duration(milliseconds: 200));
      expect(events.map((e) => e["type"]), ["room", "superchat"]);
      expect(events[1]["scId"], "a");
      await sub.cancel();
      await socket.close();
      await server.stop();
      await hub.close();
    });
  });

  group('局域网访问', () {
    late ObsBridgeHub hub;
    late ObsBridgeServer server;
    late HttpClient client;

    setUp(() async {
      hub = ObsBridgeHub();
      // 测试里只监听本机，免得弹出防火墙提示
      server = ObsBridgeServer(
        hub: hub,
        config: () => config,
        port: 0,
        lan: true,
        token: "secret",
        address: InternetAddress.loopbackIPv4,
      );
      await server.start();
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      await hub.close();
    });

    Future<int> status(String path, {String? header}) async {
      var request = await client
          .getUrl(Uri.parse("http://127.0.0.1:${server.boundPort}$path"));
      if (header != null) request.headers.set("x-token", header);
      var response = await request.close();
      await response.drain();
      return response.statusCode;
    }

    test('没有令牌或令牌不对时拒绝', () async {
      expect(await status("/api/room"), 403);
      expect(await status("/overlay"), 403);
      expect(await status("/api/room?token=wrong"), 403);
      expect(await status("/api/room?token=secret"), 200);
      expect(await status("/api/config", header: "secret"), 200);
      await expectLater(
        WebSocket.connect("ws://127.0.0.1:${server.boundPort}/ws"),
        throwsA(isA<WebSocketException>()),
      );
      var socket = await WebSocket.connect(
          "ws://127.0.0.1:${server.boundPort}/ws?token=secret");
      var first = jsonDecode(await socket.first as String);
      expect(first["type"], "room");
    });

    test('首页的地址带上令牌', () async {
      var request = await client.getUrl(
          Uri.parse("http://127.0.0.1:${server.boundPort}/?token=secret"));
      var body = await (await request.close()).transform(utf8.decoder).join();
      expect(body, contains("/overlay?token=secret"));
      expect(body, contains("/api/messages?since=0&amp;token=secret"));
    });
  });

  test('记录弹幕（ASS）：文件头、弹幕、换直播间的备注', () async {
    var dir = Directory.systemTemp.createTempSync("obs_record_");
    addTearDown(() => dir.deleteSync(recursive: true));
    var recorder = await DanmakuAssRecorder.start(
      dir: dir,
      options: AssOptions.fromConfig(config),
      site: "js:acfun",
      roomId: "1",
      roomKey: "js:acfun|1",
      roomLabel: "AcFun 1 标题",
      now: DateTime(2026, 10, 28, 12, 0, 0),
    );
    expect(recorder.file.path,
        endsWith("SimpleLive_js_acfun_1_20261028-120000.ass"));
    recorder.addChat(chat("第一条"), at: const Duration(seconds: 1));
    recorder.noteRoom("js:acfun|1", "AcFun 1 标题"); // 没变
    recorder.noteRoom("bilibili|6", "哔哩哔哩 6", at: const Duration(seconds: 2));
    recorder.addSuperChats([superChat()], at: const Duration(seconds: 3));
    var file = await recorder.stop();
    expect(recorder.count, 2);
    expect(file.readAsBytesSync().take(3), [0xef, 0xbb, 0xbf]);
    var text = (await file.readAsString()).replaceFirst("\uFEFF", "");
    expect(text, startsWith("[Script Info]"));
    expect(text, contains("Title: SimpleLive 弹幕 - AcFun 1 标题"));
    expect(
        text,
        contains(
            "Comment: 0,0:00:00.00,0:00:00.00,Default,,0,0,0,,直播间：AcFun 1 标题\n"));
    expect(text, contains("Dialogue: 0,0:00:01.00,0:00:11.00,Default,观众,"));
    expect(
        text,
        contains(
            "Comment: 0,0:00:02.00,0:00:02.00,Default,,0,0,0,,直播间：哔哩哔哩 6\n"));
    expect(text, contains("【SC ￥30】老板：加油"));
    expect("Comment:".allMatches(text).length, 2);
    // 同一秒再开始一次不覆盖
    var again = await DanmakuAssRecorder.start(
      dir: dir,
      options: const AssOptions(),
      site: "js:acfun",
      roomId: "1",
      now: DateTime(2026, 10, 28, 12, 0, 0),
    );
    expect(again.file.path, endsWith("_20261028-120000_2.ass"));
    await again.stop();
  });

  test('录屏接口的设置不进同步备份，恢复时保留本机值', () {
    var settings = {
      "DanmuSize": 16.0,
      LocalStorageService.kObsBridgeEnable: true,
      LocalStorageService.kObsBridgePort: 30000,
      LocalStorageService.kObsBridgeLan: true,
      LocalStorageService.kObsBridgeToken: "secret",
      LocalStorageService.kDanmakuRecordDir: "D:/rec",
    };
    expect(SyncCompat.upstreamSettings(settings).keys, ["DanmuSize"]);
    var ext = SyncCompat.extSettings(settings);
    for (var key in SyncCompat.localOnlySettingKeys) {
      expect(ext.containsKey(key), isFalse, reason: key);
    }
    var merged = SyncCompat.mergeRestoredSettings(
      settings,
      {"DanmuSize": 20.0, LocalStorageService.kObsBridgeToken: "other"},
      {LocalStorageService.kObsBridgePort: 1},
    );
    expect(merged["DanmuSize"], 20.0);
    expect(merged[LocalStorageService.kObsBridgeToken], "secret");
    expect(merged[LocalStorageService.kObsBridgePort], 30000);
    expect(merged[LocalStorageService.kDanmakuRecordDir], "D:/rec");
  });
}
