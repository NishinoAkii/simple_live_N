// 直播源接口 v1 之后加的可选功能（App.features）：表情图片、登录、HLS 列表修正。不访问外网
//   dart test test/live_source_extensions_test.dart
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/script/script_convert.dart';
import 'package:simple_live_core/src/script/script_metadata.dart';
import 'package:test/test.dart';

late Directory tmp;
late HttpServer upstream;
late String base;
final Map<String, int> upstreamHits = {};

String steamFixture(String name) =>
    File("test/fixtures/steam/$name").readAsStringSync();

/// 假的上游：/live/master.m3u8（相对地址）、/live/audio.m3u8（时长错误）、/live/video.m3u8、/gone.m3u8（410）
Future<void> _handle(HttpRequest req) async {
  var path = req.uri.path;
  upstreamHits[path] = (upstreamHits[path] ?? 0) + 1;
  var res = req.response;
  res.headers.set("x-seen-ua", req.headers.value("user-agent") ?? "");
  switch (path) {
    case "/live/master.m3u8":
      res.headers.contentType = ContentType("application", "vnd.apple.mpegurl");
      res.write('''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Default",DEFAULT=YES,URI="audio.m3u8?a=1"
#EXT-X-STREAM-INF:BANDWIDTH=3660000,RESOLUTION=1280x720,AUDIO="aac"
video.m3u8?v=1
''');
      break;
    case "/live/audio.m3u8":
      res.write('''#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:3
#EXT-X-MEDIA-SEQUENCE:10
#EXT-X-MAP:URI="seg/audio/init/"
#EXTINF:143.360000,
seg/audio/10/
#EXTINF:2.990000,
seg/audio/11/
''');
      break;
    case "/live/video.m3u8":
      res.write('''#EXTM3U
#EXT-X-TARGETDURATION:3
#EXT-X-MEDIA-SEQUENCE:10
#EXTINF:2.995000,
seg/video/10/
''');
      break;
    case "/gone.m3u8":
      res.statusCode = 410;
      res.write("gone");
      break;
    default:
      res.statusCode = 404;
  }
  await res.close();
}

ScriptLiveSite loadSite(String name, String code) {
  var dir = Directory("${tmp.path}/sources")..createSync(recursive: true);
  var file = File("${dir.path}/$name")..writeAsStringSync(code);
  var meta = parseLiveSourceScript(code, filename: name);
  return ScriptLiveSite(
    meta.toInfo(file.path),
    dataDirectory: "${tmp.path}/data/${meta.key}",
    appVersion: "9.9.9",
  );
}

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

Future<String> httpGet(String url) async {
  var client = HttpClient();
  try {
    var req = await client.getUrl(Uri.parse(url));
    var res = await req.close();
    var text = await res.transform(const SystemEncoding().decoder).join();
    if (res.statusCode != 200) return "HTTP ${res.statusCode}";
    return text;
  } finally {
    client.close();
  }
}

/// 有登录、表情的测试源
String featureSource(String base) =>
    '''
class Ext extends LiveSource {
  key = "ext";
  name = "扩展";
  version = "1.0.0";
  domains = ["127.0.0.1"];
  login = { url: "https://example.com/login", cookieUrl: "https://example.com/", cookieNames: ["auth", "token2"], tip: "登录后能发言" };

  features() { return App.features; }
  cookieHeader() { return Http.getCookies("https://example.com/"); }
  async account() {
    const c = await Http.getCookies("https://example.com/");
    return c.includes("auth=") ? { loggedIn: true, userName: "小明", uid: "42" } : { loggedIn: false };
  }
  async room(id) { return { roomId: id, title: "t", live: true, danmakuData: { id } }; }
  async qualities() { return [{ name: "原画", data: 1 }]; }
  async playUrls(room) {
    if (room.roomId === "fix") return { urls: ["$base/live/master.m3u8", "$base/x.flv"], headers: { "user-agent": "UA-test" }, hlsFix: "durations" };
    if (room.roomId === "unknown") return { urls: ["$base/live/master.m3u8"], hlsFix: ["nope"] };
    return { urls: ["$base/live/master.m3u8"] };
  }

  danmaku = {
    async start(room, session) {
      session.ready();
      session.emit([
        { type: "chat", user: "a", text: "hi :smile: x", emotes: [
          { text: ":smile:", url: "https://cdn.example.com/smile.png", width: 54, height: 54 },
          { text: ":notused:", url: "https://cdn.example.com/n.png" },
          { text: ":bad:", url: "javascript:alert(1)" },
        ] },
        { type: "chat", user: "b", userId: 42, text: "[贴纸] Tag", sticker: { text: "[贴纸] Tag", url: "https://cdn.example.com/s.png", staticUrl: "https://cdn.example.com/s0.png", width: 150, height: 150 } },
        { type: "chat", user: "c", text: "plain", history: true },
      ]);
    },
  };
}
''';

void main() {
  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync("live_source_ext_test_");
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = "http://127.0.0.1:${upstream.port}";
    upstream.listen((r) => _handle(r).catchError((Object _) {}));
  });

  tearDownAll(() async {
    await upstream.close(force: true);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group("表情（emotes / sticker）", () {
    test("转换：只留文字里出现的、地址是 http(s) 的", () {
      var list = scriptEmotes([
        {"text": ":a:", "url": "https://x/a.png", "width": 54, "height": 54},
        {"text": ":a:", "url": "https://x/dup.png"},
        {"text": ":b:", "url": "https://x/b.png"},
        {"text": ":c:", "url": "file:///etc/passwd"},
        "not a map",
      ], "x :a: :c:");
      expect(list, hasLength(1));
      expect(list!.first.url, "https://x/a.png");
      expect(list.first.width, 54);
      expect(scriptEmotes([], "x"), isNull);
      expect(scriptEmotes(null, "x"), isNull);
      var s = scriptEmote({
        "text": "贴纸",
        "url": "https://x/s.png",
        "staticUrl": "https://x/s0.png",
        "spaced": true,
        "cacheKey": "k",
      })!;
      expect(s.staticUrl, "https://x/s0.png");
      expect(s.spaced, isTrue);
      expect(s.cacheKey, "k");
      expect(scriptEmote({"text": "", "url": "https://x"}), isNull);
    });
  });

  group("登录", () {
    test("按 Cookie 判断是否登录", () {
      expect(liveSourceLoggedIn("a=1; auth=xyz", ["auth"]), isTrue);
      expect(liveSourceLoggedIn("a=1; auth=", ["auth"]), isFalse);
      expect(liveSourceLoggedIn('auth=""', ["auth"]), isFalse);
      expect(liveSourceLoggedIn("authx=1; xauth=2", ["auth"]), isFalse);
      expect(liveSourceLoggedIn("", ["auth"]), isFalse);
      expect(liveSourceLoggedIn("s=1;token2=abc", ["auth", "token2"]), isTrue);
    });

    test("login 字段校验", () {
      String src(String login) =>
          'class X extends LiveSource { key = "x"; name = "X"; version = "1.0.0"; login = $login; }';
      var meta = parseLiveSourceScript(
        src('{ url: "https://a.com/login", cookieNames: "sid" }'),
      );
      expect(meta.login!.cookieUrl, "https://a.com/login");
      expect(meta.login!.cookieNames, ["sid"]);
      expect(meta.capabilities, contains("login"));
      for (var bad in [
        '"x"',
        '{ url: "http://a.com/", cookieNames: ["sid"] }',
        '{ url: "https://a.com/", cookieNames: [] }',
        '{ url: "https://a.com/", cookieUrl: "ftp://a.com", cookieNames: ["s"] }',
      ]) {
        expect(
          () => parseLiveSourceScript(src(bad)),
          throwsA(isA<CoreError>()),
          reason: bad,
        );
      }
      // 没写 login 的源
      var plain = parseLiveSourceScript(
        'class X extends LiveSource { key = "x"; name = "X"; version = "1.0.0"; }',
      );
      expect(plain.login, isNull);
      expect(plain.capabilities, isNot(contains("login")));
    });

    test("写入 Cookie、读帐号、退出登录", () async {
      var site = loadSite("ext.live.js", featureSource(base));
      addTearDown(site.dispose);
      expect(site.hasLogin, isTrue);
      expect(site.login!.tip, "登录后能发言");
      expect(await site.isLoggedIn(), isFalse);
      expect((await site.account()).loggedIn, isFalse);
      expect(await site.loginWithCookies("  "), isFalse);
      expect(await site.loginWithCookies("auth=abc%7C%7Cjwt; other=1"), isTrue);
      expect(
        await site.callScript("cookieHeader"),
        contains("auth=abc%7C%7Cjwt"),
      );
      var account = await site.account();
      expect(account.loggedIn, isTrue);
      expect(account.userName, "小明");
      expect(account.uid, "42");
      await site.logout();
      expect(await site.isLoggedIn(), isFalse);
      expect(await site.callScript("cookieHeader"), "");
      expect(
        (await site.callScript("features") as List),
        containsAll(kLiveSourceFeatures),
      );
    });
  });

  group("脚本弹幕会话", () {
    test("会话里的表情", () async {
      var site = loadSite("ext.live.js", featureSource(base));
      addTearDown(site.dispose);
      var danmaku = site.getDanmaku();
      var sender = danmaku;
      var messages = <LiveMessage>[];
      sender.onMessage = messages.add;
      var detail = await site.getRoomDetail(roomId: "r1");
      await sender.start(detail.danmakuData);
      addTearDown(sender.stop);
      await waitFor(() => messages.length >= 3);
      // 表情：只保留文字里出现的、地址合法的
      expect(messages[0].emotes!.map((e) => e.text), [":smile:"]);
      expect(messages[0].emotes!.first.width, 54);
      expect(messages[1].sticker!.staticUrl, "https://cdn.example.com/s0.png");
      expect(messages[1].hasEmotes, isTrue);
      expect(messages[2].hasEmotes, isFalse);
      // history: true 的是之前的聊天（App 只放进聊天区）
      expect(messages.map((m) => m.history), [false, false, true]);
      // userId 选填：数字也认，没写的是 null
      expect(messages.map((m) => m.userId), [null, "42", null]);
    });
  });

  group("HLS 列表修正（hlsFix）", () {
    String local(Uri u) => "LOCAL<$u>";

    test("改写抓到的 Steam 客户端直播列表", () {
      var masterBase = Uri.parse(
        "https://cache11-ord1.steamcontent.com/broadcast/1/2/hls_manifest/0/cache11-ord1.steamcontent.com/master.m3u8?broadcast_origin=x",
      );
      var master = rewriteHlsPlaylist(
        steamFixture("client_master.m3u8"),
        base: masterBase,
        fixes: {"durations"},
        playlistUri: local,
      );
      expect(master, contains('URI="LOCAL<https://'));
      expect(master, contains('audio.m3u8'));
      var variant = master
          .split("\n")
          .firstWhere((l) => l.startsWith("LOCAL<"));
      expect(variant, contains("video.m3u8"));
      expect(master, isNot(contains("\nhttps://")));

      var audioText = steamFixture("client_audio.m3u8");
      expect(audioText, matches(RegExp(r"#EXTINF:1[34]\d\.")));
      var audio = rewriteHlsPlaylist(
        audioText,
        base: masterBase,
        fixes: {"durations"},
        playlistUri: local,
      );
      var durations = RegExp(
        r"#EXTINF:([\d.]+)",
      ).allMatches(audio).map((m) => double.parse(m[1]!)).toList();
      expect(durations, isNotEmpty);
      expect(durations.every((d) => d <= 3.0), isTrue, reason: audio);
      expect(audio, contains("#EXT-X-TARGETDURATION:3"));
      expect(audio, contains('#EXT-X-MAP:URI="https://'));
      // 分段地址不变（播放器直接下载）
      var segments = audio
          .split("\n")
          .where((l) => l.startsWith("https://"))
          .toList();
      expect(segments, isNotEmpty);
      expect(segments.every((l) => l.contains("/segment/audio/")), isTrue);

      // 视频列表的时长本来就对：不改
      var videoText = steamFixture("client_video.m3u8");
      var video = rewriteHlsPlaylist(
        videoText,
        base: masterBase,
        fixes: {"durations"},
        playlistUri: local,
      );
      expect(
        RegExp(r"#EXTINF:[\d.]+").allMatches(video).map((m) => m[0]).toList(),
        RegExp(
          r"#EXTINF:[\d.]+",
        ).allMatches(videoText).map((m) => m[0]).toList(),
      );
      // 没有 durations 时只换地址
      var untouched = rewriteHlsPlaylist(
        audioText,
        base: masterBase,
        fixes: {},
        playlistUri: local,
      );
      expect(untouched, matches(RegExp(r"#EXTINF:1[34]\d\.")));
    });

    test("相对地址、标题、没有 TARGETDURATION", () {
      var out = rewriteHlsPlaylist(
        "#EXTM3U\n#EXTINF:500.0,title here\nseg1.ts\n",
        base: Uri.parse("https://h/a/b.m3u8"),
        fixes: {"durations"},
        playlistUri: local,
      );
      // 没有 TARGETDURATION 时不改时长
      expect(out, contains("#EXTINF:500.0,title here"));
      expect(out, contains("https://h/a/seg1.ts"));
      var fixed = rewriteHlsPlaylist(
        "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:500.0,title here\nseg1.ts\n#EXTINF:5.9,\nseg2.ts\n",
        base: Uri.parse("https://h/a/b.m3u8"),
        fixes: {"durations"},
        playlistUri: local,
      );
      expect(fixed, contains("#EXTINF:4.000,title here"));
      expect(fixed, contains("#EXTINF:5.9,"));
    });

    test("本机中转：主列表、媒体列表、出错原样转发", () async {
      var url = await HlsFixRelay.instance.register(
        "$base/live/master.m3u8",
        headers: {"user-agent": "UA-test"},
        fixes: ["durations", "unknown"],
      );
      expect(HlsFixRelay.isRelayUrl(url), isTrue);
      expect(url, endsWith(".m3u8"));
      // 同一个地址复用
      expect(
        await HlsFixRelay.instance.register(
          "$base/live/master.m3u8",
          fixes: ["durations"],
        ),
        url,
      );
      var master = await httpGet(url);
      var lines = master.split("\n");
      var audioUrl = RegExp(r'URI="([^"]+)"').firstMatch(master)![1]!;
      var videoUrl = lines.firstWhere((l) => l.startsWith("http"));
      expect(HlsFixRelay.isRelayUrl(audioUrl), isTrue);
      expect(HlsFixRelay.isRelayUrl(videoUrl), isTrue);
      var audio = await httpGet(audioUrl);
      expect(audio, contains("#EXTINF:3.000,"));
      expect(audio, contains("#EXTINF:2.990000,"));
      expect(audio, contains('#EXT-X-MAP:URI="$base/live/seg/audio/init/"'));
      expect(audio, contains("$base/live/seg/audio/10/"));
      var video = await httpGet(videoUrl);
      expect(video, contains("#EXTINF:2.995000,"));
      expect(video, contains("$base/live/seg/video/10/"));
      expect(upstreamHits["/live/audio.m3u8"], greaterThanOrEqualTo(1));
      // 上游 410：原样返回状态码
      var gone = await HlsFixRelay.instance.register(
        "$base/gone.m3u8",
        fixes: ["durations"],
      );
      expect(await httpGet(gone), "HTTP 410");
      // 不认识的修正：返回原地址
      expect(
        await HlsFixRelay.instance.register(
          "$base/live/master.m3u8",
          fixes: ["nope"],
        ),
        "$base/live/master.m3u8",
      );
      // 不存在的编号
      var port = Uri.parse(url).port;
      expect(
        await httpGet("http://127.0.0.1:$port/hlsfix/999/0.m3u8"),
        "HTTP 404",
      );
    });

    test("playUrls 的 hlsFix", () async {
      var site = loadSite("ext.live.js", featureSource(base));
      addTearDown(site.dispose);
      Future<LivePlayUrl> play(String id) async {
        var detail = await site.getRoomDetail(roomId: id);
        var q = (await site.getPlayQualites(detail: detail)).first;
        return site.getPlayUrls(detail: detail, quality: q);
      }

      var fixed = await play("fix");
      expect(HlsFixRelay.isRelayUrl(fixed.urls[0]), isTrue);
      expect(fixed.urls[1], "$base/x.flv"); // 不是 m3u8 的不经中转
      expect(fixed.headers, {"user-agent": "UA-test"});
      var audioUrl = RegExp(
        r'URI="([^"]+)"',
      ).firstMatch(await httpGet(fixed.urls[0]))![1]!;
      expect(await httpGet(audioUrl), contains("#EXTINF:3.000,"));
      expect((await play("plain")).urls, ["$base/live/master.m3u8"]);
      expect((await play("unknown")).urls, ["$base/live/master.m3u8"]);
      ScriptLiveSite.useHlsFix = false;
      try {
        expect((await play("fix")).urls.first, "$base/live/master.m3u8");
      } finally {
        ScriptLiveSite.useHlsFix = true;
      }
    });
  });

  test('asHistory 只多一个历史标记（YouTube 进直播间的那批聊天）', () {
    var emote = LiveEmote(text: ":a:", url: "https://e/a.png");
    var msg = LiveMessage(
      type: LiveMessageType.chat,
      userName: "u",
      message: "hi :a:",
      color: LiveMessageColor.white,
      face: "https://f",
      emotes: [emote],
    );
    var h = msg.asHistory();
    expect(h.history, isTrue);
    expect(msg.history, isFalse);
    expect(h.message, "hi :a:");
    expect(h.userName, "u");
    expect(h.face, "https://f");
    expect(h.emotes, [emote]);
  });
}
