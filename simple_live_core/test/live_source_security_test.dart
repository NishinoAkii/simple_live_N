// 直播源的安全加固：发布者签名、权限变化、hls.rewrite 结果校验、辅助函数、源设置。不访问外网
//   dart test test/live_source_security_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/ed25519.dart';
import 'package:simple_live_core/src/common/hls_fix_relay.dart';
import 'package:simple_live_core/src/script/live_source_signing.dart';
import 'package:simple_live_core/src/script/script_host.dart'
    show DecodedTooLarge, decodeLimited;
import 'package:simple_live_core/src/script/script_metadata.dart';
import 'package:test/test.dart';

late Directory tmp;

Future<void> expectCoreError(Future<dynamic> future, dynamic message) async {
  try {
    await future;
  } on CoreError catch (e) {
    expect(e.message, message);
    return;
  }
  fail("应该抛出 CoreError");
}

LiveSourceInfo info(
  List<String> domains, {
  Set<String> caps = const {},
  String? login,
}) => LiveSourceInfo(
  key: "k",
  name: "K",
  version: "1.0.0",
  apiVersion: 1,
  file: "k.live.js",
  domains: domains,
  capabilities: caps,
  login: login == null
      ? null
      : LiveSourceLogin(url: login, cookieUrl: login, cookieNames: ["sid"]),
);

List<int> hex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

void main() {
  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync("live_source_sec_test_");
  });
  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group("Ed25519（RFC 8032 7.1）", () {
    const vectors = [
      (
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        "",
        "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
      ),
      (
        "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
        "72",
        "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
      ),
      (
        "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
        "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
        "af82",
        "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
      ),
    ];

    test("测试向量：公钥、签名、校验", () {
      for (var (seed, pk, msg, sig) in vectors) {
        expect(ed25519PublicKey(hex(seed)), hex(pk));
        expect(ed25519Sign(hex(seed), hex(msg)), hex(sig));
        expect(ed25519Verify(hex(pk), hex(msg), hex(sig)), isTrue);
      }
    });

    test("改过的内容、签名、公钥都不通过", () {
      var (seed, pk, _, _) = vectors[1];
      var msg = utf8.encode("class X extends LiveSource {}");
      var sig = ed25519Sign(hex(seed), msg);
      expect(ed25519Verify(hex(pk), msg, sig), isTrue);
      expect(ed25519Verify(hex(pk), [...msg, 32], sig), isFalse);
      expect(ed25519Verify(hex(pk), msg, [...sig]..[10] ^= 1), isFalse);
      expect(ed25519Verify(hex(pk), msg, [...sig]..[40] ^= 1), isFalse);
      expect(ed25519Verify(hex(vectors[0].$2), msg, sig), isFalse);
      expect(ed25519Verify(hex(pk), msg, sig.sublist(0, 63)), isFalse);
      // S ≥ q（可延展的签名）
      var big = [...sig]..setRange(32, 64, List.filled(32, 0xff));
      expect(ed25519Verify(hex(pk), msg, big), isFalse);
    });

    test("脚本签名：Base64、CRLF 和 LF 一样", () {
      var (seed, pk, _, _) = vectors[0];
      var publicKey = base64.encode(hex(pk));
      var lf = utf8.encode("a\nb\n");
      var sig = liveSourceSign(hex(seed), lf);
      expect(
        liveSourceVerify(publicKey, utf8.encode("a\r\nb\r\n"), sig),
        isTrue,
      );
      expect(liveSourceVerify(publicKey, utf8.encode("a\nb\n "), sig), isFalse);
      expect(liveSourceVerify("not base64", lf, sig), isFalse);
      expect(liveSourceVerify(publicKey, lf, "AAAA"), isFalse);
      expect(
        liveSourceKeyFingerprint(publicKey),
        matches(r"^[0-9a-f]{4}( [0-9a-f]{4}){3}$"),
      );
    });
  });

  group("权限变化", () {
    test("域名、敏感功能、登录地址", () {
      var old = info(["a.com", "*.b.com"], caps: {"room", "danmaku"});
      var same = diffLiveSourcePermissions(
        old,
        info(["a.com", "x.b.com", "*.y.b.com"], caps: {"room", "search"}),
      );
      expect(same.expanded, isFalse);
      expect(same.removedDomains, ["*.b.com"]);
      var more = diffLiveSourcePermissions(
        old,
        info(["a.com", "b.com", "*.c.com"], caps: {"hlsRewrite"}),
      );
      expect(more.expanded, isTrue);
      expect(more.addedDomains, ["b.com", "*.c.com"]);
      expect(more.addedCapabilities, ["hlsRewrite"]);
      expect(more.describe().first, contains("b.com"));
      var login = diffLiveSourcePermissions(
        info(["a.com"], caps: {"login"}, login: "https://a.com/login"),
        info(["a.com"], caps: {"login"}, login: "https://evil.com/login"),
      );
      expect(login.expanded, isTrue);
      expect(login.loginChange, "a.com → evil.com");
      // 新装：全部算新增
      var fresh = diffLiveSourcePermissions(null, old);
      expect(fresh.addedDomains, ["a.com", "*.b.com"]);
    });
  });

  group("安装、更新的确认和签名", () {
    late Directory repo;
    late LiveSourceManager manager;
    var seed = List<int>.generate(32, (i) => i * 7 + 1);
    var otherSeed = List<int>.generate(32, (i) => 255 - i);
    String pk(List<int> s) => base64.encode(ed25519PublicKey(s));
    String indexUrl() => Uri.file("${repo.path}/index.json").toString();

    void publish(
      String version, {
      List<String> domains = const ["127.0.0.1"],
      String extra = "",
      List<int>? signWith,
      bool sigFile = false,
      List<int>? indexKey,
    }) {
      var code =
          'class S extends LiveSource { key = "sig"; name = "签名源"; version = "$version"; '
          'domains = ${jsonEncode(domains)}; $extra async room(id) { return { roomId: id, title: "$version", live: true }; } }';
      var file = File("${repo.path}/sig.live.js")..writeAsStringSync(code);
      var sig = signWith == null
          ? null
          : liveSourceSign(signWith, file.readAsBytesSync());
      if (sigFile) File("${file.path}.sig").writeAsStringSync(sig!);
      File("${repo.path}/index.json").writeAsStringSync(
        jsonEncode({
          "name": "测试",
          if (indexKey != null) "publicKey": pk(indexKey),
          "sources": [
            {
              "key": "sig",
              "version": version,
              "url": "sig.live.js",
              if (sig != null && !sigFile) "signature": sig,
            },
          ],
        }),
      );
    }

    setUp(() async {
      var root = Directory(
        "${tmp.path}/m${DateTime.now().microsecondsSinceEpoch}",
      );
      repo = Directory("${root.path}/repo")..createSync(recursive: true);
      manager = LiveSourceManager(
        directory: "${root.path}/app",
        appVersion: "1.0.0",
      );
      await manager.init();
    });
    tearDown(() => manager.dispose());

    test("权限扩大的更新要确认，没扩大的直接更新", () async {
      publish("1.0.0");
      await manager.addSubscription(indexUrl());
      var entry = (await manager.fetchSubscription(indexUrl())).single;
      expect(entry.signed, isFalse);
      var plan = await manager.prepareInstallFromUrl(entry.url);
      expect(plan.needsConfirmation, isTrue); // 新装：给用户看权限
      expect(plan.diff.addedDomains, ["127.0.0.1"]);
      await manager.applyPlan(plan, confirmed: true);
      expect(manager.publicKeyOf("sig"), isNull);

      publish("1.1.0", domains: ["127.0.0.1", "evil.example"]);
      await manager.checkUpdates();
      try {
        await manager.update("sig");
        fail("应该要确认");
      } on LiveSourceConfirmationRequired catch (e) {
        expect(e.message, contains("evil.example"));
        expect(manager.site("sig")!.info.version, "1.0.0");
        await expectLater(
          manager.applyPlan(e.plan),
          throwsA(isA<LiveSourceConfirmationRequired>()),
        );
        await manager.applyPlan(e.plan, confirmed: true);
      }
      expect(manager.site("sig")!.info.version, "1.1.0");

      publish("1.2.0", domains: ["127.0.0.1"]); // 只是减少
      await manager.checkUpdates();
      expect((await manager.update("sig")).version, "1.2.0");

      publish(
        "1.3.0",
        extra: "hls = { rewrite(t) { return t; } };",
      );
      await manager.checkUpdates();
      await expectLater(
        manager.update("sig"),
        throwsA(isA<LiveSourceConfirmationRequired>()),
      );
      expect(
        (await manager.update("sig", allowExpanded: true)).version,
        "1.3.0",
      );
    });

    test("签名：安装、改过的脚本、.sig 文件、换了公钥", () async {
      publish("1.0.0", signWith: seed, indexKey: seed);
      await manager.addSubscription(indexUrl());
      expect(manager.subscriptionPublicKey(indexUrl()), pk(seed));
      var entry = (await manager.fetchSubscription(indexUrl())).single;
      expect(entry.signed, isTrue);
      var plan = await manager.prepareInstallFromUrl(entry.url);
      expect(plan.signed, isTrue);
      await manager.applyPlan(plan, confirmed: true);
      expect(manager.publicKeyOf("sig"), pk(seed));

      // 脚本被改过（签名还是旧的）
      publish("1.1.0", signWith: seed, indexKey: seed);
      File("${repo.path}/sig.live.js").writeAsStringSync(
        File(
          "${repo.path}/sig.live.js",
        ).readAsStringSync().replaceAll("1.1.0", "1.1.1"),
      );
      await manager.checkUpdates();
      await expectCoreError(manager.update("sig"), contains("签名校验失败"));
      expect(manager.site("sig")!.info.version, "1.0.0");

      // 签名放在 .sig 文件里
      publish("1.2.0", signWith: seed, indexKey: seed, sigFile: true);
      await manager.checkUpdates();
      expect((await manager.update("sig")).version, "1.2.0");

      // 订阅换了公钥：拒绝
      publish("1.3.0", signWith: otherSeed, indexKey: otherSeed);
      var blocked = (await manager.fetchSubscription(indexUrl())).single;
      expect(blocked.blockedReason, contains("公钥变了"));
      expect(manager.subscriptionKeyError(indexUrl()), isNotNull);
      expect(await manager.checkUpdates(), isEmpty);
      await expectCoreError(manager.update("sig"), contains("公钥变了"));
      // 去掉签名也拒绝
      publish("1.3.0");
      await expectCoreError(
        manager.prepareInstallFromUrl(
          (await manager.fetchSubscription(indexUrl())).single.url,
        ),
        contains("去掉了签名"),
      );

      // 删除订阅后重新添加：记下新的公钥；源本身仍按安装时的公钥校验
      publish("1.3.0", signWith: otherSeed, indexKey: otherSeed);
      await manager.removeSubscription(indexUrl());
      await manager.addSubscription(indexUrl());
      await manager.checkUpdates();
      await expectCoreError(manager.update("sig"), contains("按发布者签名安装"));
      // 用户自己重新安装：要确认（换了公钥）
      var again = await manager.prepareInstallFromUrl(
        (await manager.fetchSubscription(indexUrl())).single.url,
      );
      expect(again.losesSignature, isTrue);
      expect(again.needsConfirmation, isTrue);
      await manager.applyPlan(again, confirmed: true);
      expect(manager.publicKeyOf("sig"), pk(otherSeed));
    });
  });

  group("hls.rewrite", () {
    var base = Uri.parse("https://cdn.a.com/live/master.m3u8");
    String? check(String text) => validateHlsRewrite(
      text,
      base: base,
      allowedDomains: ["*.b.com"],
      extraHosts: {"cdn.a.com"},
    );

    test("结果校验：只允许 http(s)、domains 里的或原列表主机上的地址", () {
      expect(
        check(
          '#EXTM3U\n#EXTINF:2,\nseg1.ts\n/abs/seg2.ts\nhttps://x.b.com/s3.ts\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXT-X-MAP:URI="https://y.b.com/init.mp4"\n',
        ),
        isNull,
      );
      for (var bad in [
        "seg.ts",
        "#EXTM3U\nfile:///etc/passwd",
        "#EXTM3U\nFILE:/etc/passwd",
        "#EXTM3U\ndata:video/mp2t;base64,AAAA",
        "#EXTM3U\nconcat:https://cdn.a.com/a.ts|file:///etc/passwd",
        "#EXTM3U\nsubfile:,,start,0,end,0,,:/etc/passwd",
        "#EXTM3U\nC:\\Windows\\win.ini",
        "#EXTM3U\n\\\\server\\share\\a.ts",
        "#EXTM3U\nhttps://evil.com/x.ts",
        "#EXTM3U\n//evil.com/x.ts",
        "#EXTM3U\nhttps://b.com/x.ts",
        '#EXTM3U\n#EXT-X-MAP:URI="file:///etc/passwd"',
        "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=data:text/plain,abc",
        '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,uri="https://evil.com/a.m3u8"',
        "#EXTM3U\nseg\u0000.ts",
      ]) {
        expect(check(bad), isNotNull, reason: bad);
      }
      expect(
        validateHlsRewrite("#EXTM3U\n${"#\n" * 10}", base: base, maxLength: 8),
        contains("太大"),
      );
    });

    late HttpServer upstream;
    setUpAll(() async {
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        var bodies = {
          "/m.m3u8": "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8\n",
          "/v.m3u8":
              "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:9.0,\nseg1.ts\n",
          "/evil.m3u8": "#EXTM3U\n#EXTINF:2,\nseg1.ts\n#evil\n",
          "/loop.m3u8": "#EXTM3U\n#EXTINF:2,\nseg1.ts\n#loop\n",
          "/io.m3u8": "#EXTM3U\n#EXTINF:2,\nseg1.ts\n#io\n",
        };
        var body = bodies[req.uri.path];
        if (body == null) req.response.statusCode = 404;
        req.response.write(body ?? "");
        await req.response.close();
      });
    });
    tearDownAll(() => upstream.close(force: true));

    test("中转调用脚本改写；不安全的结果、超时都用原列表", () async {
      var base = "http://127.0.0.1:${upstream.port}";
      var code =
          '''
class R extends LiveSource {
  key = "rw"; name = "改写"; version = "1.0.0"; domains = ["127.0.0.1"];
  hls = {
    rewrite(text, info) {
      if (text.includes("#loop")) { while (true) {} }
      if (text.includes("#io")) { log("改写"); setTimeout(() => {}, 1); return "#EXTM3U\\n#IO\\n"; }
      if (text.includes("#evil")) return text.replace("seg1.ts", "file:///etc/passwd");
      if (info.kind === "master") return text + "#X-REWRITTEN\\n";
      return text.replace("#EXTINF:9.0", "#EXTINF:2.0") + "#INFO " + info.index + " " + info.variant + "\\n";
    },
  };
  probe() { return "alive"; }
  async room(id) { return { roomId: id, title: "t", live: true }; }
  async qualities() { return [{ name: "原画", data: 1 }]; }
  async playUrls(room) { return { urls: ["$base/" + room.roomId + ".m3u8"], hlsFix: ["rewrite"] }; }
}
''';
      var file = File("${tmp.path}/rw.live.js")..writeAsStringSync(code);
      var site = ScriptLiveSite(
        parseLiveSourceScript(code).toInfo(file.path),
        dataDirectory: "${tmp.path}/data/rw",
      );
      addTearDown(site.dispose);
      expect(site.hasHlsRewrite, isTrue);
      Future<String> play(String id) async {
        var detail = await site.getRoomDetail(roomId: id);
        var q = (await site.getPlayQualites(detail: detail)).first;
        var url = (await site.getPlayUrls(
          detail: detail,
          quality: q,
        )).urls.single;
        expect(HlsFixRelay.isRelayUrl(url), isTrue);
        return url;
      }

      Future<String> get(String url) async {
        var client = HttpClient();
        try {
          var res = await (await client.getUrl(Uri.parse(url))).close();
          return await res.transform(utf8.decoder).join();
        } finally {
          client.close();
        }
      }

      var master = await get(await play("m"));
      expect(master, contains("#X-REWRITTEN"));
      var variant = master.split("\n").firstWhere((l) => l.startsWith("http"));
      var media = await get(variant);
      expect(media, contains("#EXTINF:2.0,"));
      expect(media, contains("$base/seg1.ts"));
      expect(media, contains("#INFO 1 #EXT-X-STREAM-INF:BANDWIDTH=1"));
      // 换成本机文件：不用
      var evil = await get(await play("evil"));
      expect(evil, isNot(contains("file:")));
      expect(evil, contains("$base/seg1.ts"));
      // 死循环：约 200 毫秒后中断，用原列表，源照常能用
      var sw = Stopwatch()..start();
      var loop = await get(await play("loop"));
      expect(loop, contains("$base/seg1.ts"));
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      expect(await site.callScript("probe"), "alive");
      // 改写里不能开定时器、发请求：用原列表
      var io = await get(await play("io"));
      expect(io, isNot(contains("#IO")));
      expect(io, contains("$base/seg1.ts"));
    });
  });

  group("设置项和辅助函数", () {
    test("settings 声明的解析", () {
      var list = validateLiveSourceSettings([
        {"key": "hd", "type": "switch", "label": "高清", "default": true},
        {"key": "name", "type": "text", "label": "名字", "placeholder": "x"},
        {"key": "n", "type": "number", "min": 1, "max": 10, "default": 50},
        {
          "key": "q",
          "type": "select",
          "label": "清晰度",
          "options": [
            {"value": "hd", "label": "高清"},
            "sd",
          ],
          "default": "sd",
        },
      ]);
      expect(list.map((e) => e.defaultValue), [true, "", 1, "sd"]);
      expect(list[2].label, "n");
      expect(list[3].options.map((e) => e.label), ["高清", "sd"]);
      expect(list[2].coerce("5"), 5);
      expect(list[2].coerce(11), isNull);
      expect(list[0].coerce("x"), isNull);
      expect(liveSourceSettingValues(list, {"hd": false, "q": "nope"}), {
        "hd": false,
        "name": "",
        "n": 1,
        "q": "sd",
      });
      for (var bad in [
        "x",
        [
          {"key": "a b", "type": "switch"},
        ],
        [
          {"key": "a", "type": "color"},
        ],
        [
          {"key": "a", "type": "select", "options": []},
        ],
        [
          {"key": "a", "type": "switch"},
          {"key": "a", "type": "text"},
        ],
      ]) {
        expect(
          () => validateLiveSourceSettings(bad),
          throwsA(isA<CoreError>()),
          reason: "$bad",
        );
      }
    });

    test("Settings.get、App 改设置、Hash、Zip", () async {
      const code = '''
class H extends LiveSource {
  key = "helpers"; name = "辅助"; version = "1.0.0";
  settings = [
    { key: "hd", type: "switch", label: "高清", default: true },
    { key: "q", type: "select", label: "Q", options: ["a", "b"], default: "a" },
  ];
  read() { return [Settings.get("hd"), Settings.get("q"), Settings.get("nope")]; }
  async hashes() {
    return [
      Bytes.toHex(await Hash.md5("abc")),
      Bytes.toHex(await Hash.sha256(Bytes.fromUtf8("abc"))),
      Bytes.toHex(await Hash.hmac("SHA256", "key", "The quick brown fox jumps over the lazy dog")),
    ];
  }
  async zip() { return Bytes.toUtf8(await Zip.inflate(await Zip.deflate(Bytes.fromUtf8("你好")))); }
}
''';
      var file = File("${tmp.path}/helpers.live.js")..writeAsStringSync(code);
      var meta = parseLiveSourceScript(code);
      expect(meta.capabilities, contains("settings"));
      var site = ScriptLiveSite(
        meta.toInfo(file.path),
        dataDirectory: "${tmp.path}/data/helpers",
      );
      addTearDown(site.dispose);
      expect(site.settings.map((e) => e.key), ["hd", "q"]);
      expect(await site.callScript("read"), [true, "a", null]);
      expect(await site.setSettings({"hd": false, "q": "b", "unknown": 1}), {
        "hd": false,
        "q": "b",
      });
      expect(await site.callScript("read"), [false, "b", null]);
      await expectLater(
        site.setSettings({"q": "zzz"}),
        throwsA(isA<CoreError>()),
      );
      await site.setSettings({"q": null}); // 恢复默认
      await site.shutdown();
      expect(await site.getSettings(), {"hd": false, "q": "a"});

      expect(await site.callScript("hashes"), [
        "900150983cd24fb0d6963f7d28e17f72",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
      ]);
      expect(await site.callScript("zip"), "你好");
      // 解压炸弹：超过上限就停
      var bomb = gzip.encode(List.filled(1 << 20, 0));
      expect(
        () => decodeLimited(gzip.decoder, bomb, 64 * 1024),
        throwsA(isA<DecodedTooLarge>()),
      );
      expect(decodeLimited(gzip.decoder, bomb, 2 << 20), hasLength(1 << 20));
    });
  });
}
