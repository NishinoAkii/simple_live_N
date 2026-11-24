// 已登录时的观看上报：设备号 LIVE_BUVID（平台发的优先）、进房记录、心跳 E。不访问网络
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/bili_web.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/danmaku/bili_web_watch.dart';
import 'package:test/test.dart';

const noticePath = "/news/v1/notice/recom";
const entryPath = "/xlive/web-room/v1/index/roomEntryAction";
const enterPath = "/xlive/data-interface/v1/x25Kn/E";
const own = "AUTO1111111111111111";
const issued = "AUTO2222222222222222";
const login = "SESSDATA=1; bili_jct=jct123; DedeUserID=42; buvid3=B3";
const room = BiliHeartRoom(
  roomId: 100,
  parentAreaId: 9,
  areaId: 371,
  anchorUid: 7,
);

class WatchAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  /// 公告接口的 Set-Cookie、状态码
  List<String> setCookies = const [];
  int noticeStatus = 200;

  /// 心跳 E 返回的 code
  int enterCode = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    var path = options.uri.path;
    var data = path == enterPath && enterCode == 0
        ? {
            "timestamp": 1717921241,
            "heartbeat_interval": 60,
            "secret_key": "key",
            "secret_rule": [2, 5, 1, 4],
          }
        : {};
    return ResponseBody.fromString(
      json.encode({"code": path == enterPath ? enterCode : 0, "data": data}),
      path == noticePath ? noticeStatus : 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        if (path == noticePath && setCookies.isNotEmpty)
          "set-cookie": setCookies,
      },
    );
  }

  @override
  void close({bool force = false}) {}

  Iterable<RequestOptions> of(String path) =>
      requests.where((e) => e.uri.path == path);
}

void main() {
  late HttpClientAdapter original;
  late WatchAdapter fake;
  late BiliBiliSite site;
  late List<String> saved;
  var watches = <BiliWebWatch>[];

  setUp(() {
    original = HttpClient.instance.dio.httpClientAdapter;
    fake = WatchAdapter();
    HttpClient.instance.dio.httpClientAdapter = fake;
    BiliBiliSite.kImgKey = "7cd084941338484aae1ad9425b84077c";
    BiliBiliSite.kSubKey = "4932caff0ff746eab6f01bf08b70ac45";
    saved = [];
    site = BiliBiliSite()
      ..cookie = login
      ..buvid3 = "B3"
      ..buvid4 = "B4"
      ..savedLiveBuvid = own
      ..onLiveBuvidIssued = saved.add;
  });

  tearDown(() {
    for (var watch in watches) {
      watch.close();
    }
    watches.clear();
    HttpClient.instance.dio.httpClientAdapter = original;
    BiliBiliSite.kImgKey = "";
    BiliBiliSite.kSubKey = "";
    BiliWatchHeart.md5Twice = false;
  });

  /// 进直播间，等到发出心跳 E
  Future<RequestOptions> enter() async {
    var before = fake.of(enterPath).length;
    var watch = BiliWebWatch(site, room);
    watches.add(watch);
    watch.run();
    for (var i = 0; i < 400 && fake.of(enterPath).length == before; i++) {
      await Future.delayed(const Duration(milliseconds: 5));
    }
    expect(fake.of(enterPath).length, before + 1);
    return fake.of(enterPath).last;
  }

  List deviceOf(RequestOptions options) =>
      json.decode(options.uri.queryParameters["device"]!);

  test("带登录 Cookie、不带自己生成的去要；进房记录和心跳都用平台发的，并交给 App 存下", () async {
    fake.setCookies = [
      "PVID=1; Path=/; Domain=bilibili.com",
      "LIVE_BUVID=$issued; Path=/; Domain=bilibili.com",
    ];
    var beat = await enter();
    var notice = fake.requests.first;
    expect(notice.method, "GET");
    expect(
      notice.uri.toString(),
      "https://api.live.bilibili.com$noticePath?product=live",
    );
    expect(notice.headers["cookie"], login);
    expect(notice.headers["origin"], "https://live.bilibili.com");
    expect(notice.headers["referer"], "https://live.bilibili.com/");

    expect(fake.requests.map((e) => e.uri.path), [
      noticePath,
      entryPath,
      enterPath,
    ]);
    for (var options in [fake.of(entryPath).single, beat]) {
      expect(options.headers["cookie"], "$login;LIVE_BUVID=$issued;");
    }
    expect(deviceOf(beat).first, issued);
    expect(site.liveBuvid, issued);
    expect(site.liveBuvidIssued, isTrue);
    expect(saved, [issued]);

    // 已经有了：不再要
    await enter();
    expect(fake.of(noticePath), hasLength(1));
  });

  test("没给、服务器出错：照旧用自己生成的，过几分钟再要", () async {
    var beat = await enter();
    expect(deviceOf(beat).first, own);
    expect(beat.headers["cookie"], "$login;LIVE_BUVID=$own;");
    expect(site.liveBuvidIssued, isFalse);
    expect(saved, isEmpty);

    fake.noticeStatus = 500;
    var now = DateTime.now();
    await site.loadLiveBuvid(now: now);
    expect(fake.of(noticePath), hasLength(1));
    await site.loadLiveBuvid(
      now: now.add(BiliBiliSite.liveBuvidRetry + const Duration(minutes: 1)),
    );
    expect(fake.of(noticePath), hasLength(2));
    expect(site.liveBuvid, own);

    // 钟被往回拨过也会再要
    fake
      ..noticeStatus = 200
      ..setCookies = ["LIVE_BUVID=$issued; Path=/"];
    await site.loadLiveBuvid(now: now.subtract(const Duration(hours: 1)));
    expect(site.liveBuvid, issued);
    expect(saved, [issued]);
  });

  test("登录 Cookie 里有、已经存了平台发的：不去要", () async {
    site.cookie = "$login; LIVE_BUVID=AUTO3";
    expect(deviceOf(await enter()).first, "AUTO3");
    site
      ..cookie = login
      ..liveBuvidIssued = true;
    expect(deviceOf(await enter()).first, own);
    expect(fake.of(noticePath), isEmpty);
  });

  test("没登录、直播间没有分区：什么都不发", () async {
    site.cookie = "";
    await BiliWebWatch(site, room).run();
    await site.loadLiveBuvid();
    site.cookie = login;
    await BiliWebWatch(
      site,
      const BiliHeartRoom(
        roomId: 100,
        parentAreaId: 0,
        areaId: 0,
        anchorUid: 7,
      ),
    ).run();
    expect(fake.requests, isEmpty);
  });

  test("同时进两个直播间只要一次；要的时候离开了就不再往下发", () async {
    fake.setCookies = ["LIVE_BUVID=$issued"];
    var first = BiliWebWatch(site, room);
    watches.add(first);
    var done = first.run();
    first.close();
    var beat = await enter();
    await done;
    expect(fake.of(noticePath), hasLength(1));
    expect(fake.of(entryPath), hasLength(1));
    expect(deviceOf(beat).first, issued);
  });

  test("平台说签名不对时换一种算法，别的错误不换", () async {
    fake.enterCode = -400;
    await BiliWebWatch(site, room).run();
    expect(BiliWatchHeart.md5Twice, isFalse);
    fake.enterCode = BiliHeartError.signFailed;
    await BiliWebWatch(site, room).run();
    expect(BiliWatchHeart.md5Twice, isTrue);
    await BiliWebWatch(site, room).run();
    expect(BiliWatchHeart.md5Twice, isFalse);
  });

  test("Set-Cookie 里找某一项", () {
    expect(
      BiliWeb.setCookieValue([
        "a=1; Path=/",
        "LIVE_BUVID=AUTO1; Domain=bilibili.com",
      ], "LIVE_BUVID"),
      "AUTO1",
    );
    expect(BiliWeb.setCookieValue(["LIVE_BUVID=; Path=/"], "LIVE_BUVID"), "");
    expect(BiliWeb.setCookieValue(["XLIVE_BUVID=AUTO2"], "LIVE_BUVID"), "");
    expect(
      BiliWeb.setCookieValue([" LIVE_BUVID = AUTO3 "], "LIVE_BUVID"),
      "AUTO3",
    );
    expect(BiliWeb.setCookieValue(const [], "LIVE_BUVID"), "");
  });
}
