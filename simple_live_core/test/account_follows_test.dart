// 账号关注：各平台关注列表的解析、翻页、回写请求的拼法和错误分类。
//
// 全部离线：用 AccountFollowHttp.transport 换成假的响应，不访问网络、不用任何真实凭据。
// 样本来源写在 test/fixtures/account_follows/*.json 的 _fixture 字段里：
// - documented：照文档里的响应示例裁剪；
// - built from documented shape：按文档或第三方源码里的字段自己拼的；
// - captured：调研时匿名请求实际拿到的（未登录的错误返回，下面直接写在测试里）。
import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

dynamic fixture(String name) =>
    json.decode(File('test/fixtures/account_follows/$name').readAsStringSync());

typedef FakeRequest = ({
  AccountFollowChannel channel,
  String method,
  Uri url,
  Map<String, String> headers,
  String? body,
});

/// 记录请求，按顺序（或按处理函数）返回预设的响应
class FakeFollowHttp {
  final List<FakeRequest> requests = [];
  final AccountFollowHttpResponse Function(FakeRequest request) handler;
  FakeFollowHttp(this.handler);

  factory FakeFollowHttp.sequence(List<AccountFollowHttpResponse> responses) {
    var queue = [...responses];
    return FakeFollowHttp((request) {
      if (queue.isEmpty) {
        throw StateError('unexpected request ${request.method} ${request.url}');
      }
      return queue.removeAt(0);
    });
  }

  Future<AccountFollowHttpResponse> call(
    AccountFollowChannel channel,
    String method,
    Uri url,
    Map<String, String> headers,
    String? body,
  ) async {
    var request = (
      channel: channel,
      method: method,
      url: url,
      headers: headers,
      body: body,
    );
    requests.add(request);
    return handler(request);
  }

  void install() => AccountFollowHttp.transport = call;
}

AccountFollowHttpResponse ok(Object body) =>
    AccountFollowHttpResponse(200, body is String ? body : json.encode(body));

AccountFollowHttpResponse status(int code, [Object body = ""]) =>
    AccountFollowHttpResponse(code, body is String ? body : json.encode(body));

/// 假的平台：按页返回预设结果，用来测通用的翻页逻辑
class FakePagedSite implements LiveAccountFollowSite {
  final Map<String?, Object> pages;
  final List<String?> requested = [];
  FakePagedSite(this.pages, {this.policy = const AccountFollowPolicy()});
  final AccountFollowPolicy policy;

  @override
  bool get canReadAccountFollows => true;
  @override
  String get accountFollowOwner => "me";
  @override
  AccountFollowPolicy get accountFollowPolicy => policy;
  @override
  bool get canWriteAccountFollows => false;

  @override
  Future<AccountFollowPage> getAccountFollows({String? cursor}) async {
    requested.add(cursor);
    var page = pages[cursor];
    if (page is CoreError) {
      throw page;
    }
    return page as AccountFollowPage;
  }

  @override
  Future<AccountFollowTarget> resolveAccountFollowTarget(String roomId) =>
      throw UnimplementedError();
  @override
  Future<void> followOnAccount(AccountFollowTarget target) =>
      throw UnimplementedError();
  @override
  Future<void> unfollowOnAccount(AccountFollowTarget target) =>
      throw UnimplementedError();
}

AccountFollowItem item(String roomId) =>
    AccountFollowItem(roomId: roomId, accountUid: "u$roomId", userName: roomId);

void main() {
  tearDown(() => AccountFollowHttp.transport = null);

  group('fetchAllAccountFollows', () {
    test('reads every page, waits between pages, removes duplicates', () async {
      var site = FakePagedSite(
        {
          null: AccountFollowPage(
            items: [item("1"), item("2")],
            nextCursor: "b",
          ),
          "b": AccountFollowPage(
            items: [item("2"), item("3")],
            nextCursor: "c",
          ),
          "c": AccountFollowPage(items: [item("4")], total: 4),
        },
        policy: const AccountFollowPolicy(
          pageInterval: Duration(milliseconds: 250),
        ),
      );
      var waits = <Duration>[];
      var progress = <int>[];
      var result = await fetchAllAccountFollows(
        site,
        sleep: (d) async => waits.add(d),
        onProgress: (page, count, total) => progress.add(count),
      );
      expect(result.complete, isTrue);
      expect(result.items.map((e) => e.roomId), ["1", "2", "3", "4"]);
      expect(result.pages, 3);
      expect(result.total, 4);
      expect(site.requested, [null, "b", "c"]);
      expect(waits, [
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 250),
      ]);
      expect(progress, [2, 3, 4]);
    });

    test(
      'first page error is thrown, later errors give a partial list',
      () async {
        var failing = FakePagedSite({null: AccountFollowAuthError("登录失效")});
        expect(
          () => fetchAllAccountFollows(failing, sleep: (_) async {}),
          throwsA(isA<AccountFollowAuthError>()),
        );

        var partial = FakePagedSite({
          null: AccountFollowPage(items: [item("1")], nextCursor: "2"),
          "2": CoreError("服务器出错"),
        });
        var result = await fetchAllAccountFollows(partial, sleep: (_) async {});
        expect(result.complete, isFalse);
        expect(result.items.map((e) => e.roomId), ["1"]);
        expect(result.incompleteReason, contains("第 2 页"));
      },
    );

    test(
      'truncation, repeated cursors and the page limit are incomplete',
      () async {
        var truncated = FakePagedSite({
          null: AccountFollowPage(items: [item("1")], nextCursor: "2"),
          "2": const AccountFollowPage(
            items: [],
            truncatedReason: "只读到前 100 个",
          ),
        });
        var r1 = await fetchAllAccountFollows(truncated, sleep: (_) async {});
        expect(r1.complete, isFalse);
        expect(r1.incompleteReason, "只读到前 100 个");

        var loop = FakePagedSite({
          null: AccountFollowPage(items: [item("1")], nextCursor: "x"),
          "x": AccountFollowPage(items: [item("2")], nextCursor: "x"),
        });
        var r2 = await fetchAllAccountFollows(loop, sleep: (_) async {});
        expect(r2.complete, isFalse);
        expect(r2.items.length, 2);

        var many = FakePagedSite({
          null: AccountFollowPage(items: [item("1")], nextCursor: "2"),
          "2": AccountFollowPage(items: [item("2")], nextCursor: "3"),
          "3": AccountFollowPage(items: [item("3")]),
        }, policy: const AccountFollowPolicy(maxPages: 2));
        var r3 = await fetchAllAccountFollows(many, sleep: (_) async {});
        expect(r3.complete, isFalse);
        expect(r3.pages, 2);
      },
    );

    test('cancel stops reading', () async {
      var site = FakePagedSite({
        null: AccountFollowPage(items: [item("1")], nextCursor: "2"),
        "2": AccountFollowPage(items: [item("2")]),
      });
      var cancelled = false;
      expect(
        () => fetchAllAccountFollows(
          site,
          sleep: (_) async => cancelled = true,
          isCancelled: () => cancelled,
        ),
        throwsA(isA<AccountFollowCancelled>()),
      );
    });
  });

  group('哔哩哔哩', () {
    test('parses the live following list (documented sample)', () {
      var page = parseBiliLiveFollowings(
        fixture('bili_following_page1.json'),
        1,
      );
      expect(page.items.map((e) => e.roomId), ["544853", "21686237"]);
      expect(page.items.first.accountUid, "686127");
      expect(page.items.first.userName, "籽岷");
      expect(page.items.first.face, endsWith("@100w.jpg"));
      expect(page.items.map((e) => e.isLive), [false, true]);
      expect(page.nextCursor, "2");
      expect(page.total, 3);

      var last = parseBiliLiveFollowings(
        fixture('bili_following_page2.json'),
        2,
      );
      expect(last.nextCursor, isNull);
      expect(last.items.last.face, "");
    });

    test('an empty page before the last one is not the end of the list', () {
      var page = parseBiliLiveFollowings({
        "code": 0,
        "data": {"totalPage": 5, "list": [], "count": 50},
      }, 3);
      expect(page.nextCursor, isNull);
      expect(page.truncatedReason, contains("第 3 页"));
      var douyu = parseDouyuFollowList({
        "error": 0,
        "data": {"pageCount": 4, "list": [], "total": 70},
      }, 2);
      expect(douyu.truncatedReason, isNotNull);
      // 本来就没有关注：完整的空列表
      var none = parseBiliLiveFollowings({
        "code": 0,
        "data": {"totalPage": 0, "list": [], "count": 0},
      }, 1);
      expect(none.truncatedReason, isNull);
    });

    test('error codes are classified', () {
      // captured：匿名请求 xlive/web-ucenter/user/following 的返回
      expect(
        () => parseBiliLiveFollowings({
          "code": -101,
          "message": "账号未登录",
          "ttl": 1,
        }, 1),
        throwsA(isA<AccountFollowAuthError>()),
      );
      expect(
        () => parseBiliLiveFollowings({"code": -352, "message": "风控校验失败"}, 1),
        throwsA(isA<AccountFollowRiskError>()),
      );
      // 文档：22014 已经关注 → 关注成功
      checkBiliRelationModify({
        "code": 22014,
        "message": "已经关注用户",
      }, follow: true);
      checkBiliRelationModify({"code": 0, "message": "0"}, follow: false);
      expect(
        () => checkBiliRelationModify({
          "code": 22009,
          "message": "已达关注上限",
        }, follow: true),
        throwsA(isA<AccountFollowRiskError>()),
      );
      expect(
        () => checkBiliRelationModify({
          "code": 22002,
          "message": "隐私设置",
        }, follow: true),
        throwsA(isA<AccountFollowRejectedError>()),
      );
      expect(
        () => checkBiliRelationModify({
          "code": -111,
          "message": "csrf 校验失败",
        }, follow: false),
        throwsA(isA<AccountFollowAuthError>()),
      );
      expect(
        () => checkBiliRelationModify({
          "code": -400,
          "message": "请求错误",
        }, follow: true),
        throwsA(
          predicate(
            (e) =>
                e is CoreError &&
                e is! AccountFollowRiskError &&
                e is! AccountFollowAuthError &&
                e is! AccountFollowRejectedError,
          ),
        ),
      );
    });

    test('reads pages and writes with csrf through the transport', () async {
      var fake = FakeFollowHttp((request) {
        if (request.url.path.endsWith("/user/following")) {
          var page = request.url.queryParameters["page"];
          return ok(fixture('bili_following_page$page.json'));
        }
        if (request.url.path.endsWith("/Room/get_info")) {
          // built from documented shape：room/v1/Room/get_info 的 data.uid / room_id
          return ok({
            "code": 0,
            "data": {"uid": 50329118, "room_id": 7734200, "short_id": 6},
          });
        }
        return ok({"code": 0, "message": "0", "ttl": 1});
      })..install();
      var site = BiliBiliSite()
        ..cookie = "SESSDATA=s; bili_jct=csrf123; DedeUserID=42; buvid3=b3;"
        ..userId = 42;
      expect(site.canReadAccountFollows, isTrue);
      expect(site.canWriteAccountFollows, isTrue);
      expect(site.accountFollowOwner, "42");

      var result = await fetchAllAccountFollows(site, sleep: (_) async {});
      expect(result.complete, isTrue);
      expect(result.items.map((e) => e.roomId), [
        "544853",
        "21686237",
        "7734200",
      ]);
      var listRequest = fake.requests.first;
      expect(listRequest.method, "GET");
      expect(listRequest.url.queryParameters["page_size"], "10");
      // 读关注和直播间其他请求用同一套网页端请求头（BiliWeb，小写键名）
      expect(listRequest.headers["cookie"], contains("SESSDATA=s"));
      expect(listRequest.headers["origin"], "https://live.bilibili.com");

      var target = await site.resolveAccountFollowTarget("6");
      expect(target.accountUid, "50329118");
      expect(target.roomId, "7734200");

      await site.followOnAccount(target);
      var write = fake.requests.last;
      expect(write.method, "POST");
      expect(write.url.host, "api.bilibili.com");
      expect(write.url.path, "/x/relation/modify");
      var form = Uri.splitQueryString(write.body!);
      expect(form["fid"], "50329118");
      expect(form["act"], "1");
      expect(form["re_src"], "11");
      expect(form["csrf"], "csrf123");
      expect(
        write.headers["Referer"],
        "https://space.bilibili.com/50329118/dynamic",
      );

      await site.unfollowOnAccount(target);
      expect(Uri.splitQueryString(fake.requests.last.body!)["act"], "2");
    });

    test('without login nothing is sent', () async {
      var fake = FakeFollowHttp((_) => ok({}))..install();
      var site = BiliBiliSite();
      expect(site.canReadAccountFollows, isFalse);
      expect(site.accountFollowOwner, "");
      expect(
        () => site.followOnAccount(
          const AccountFollowTarget(roomId: "1", accountUid: "2"),
        ),
        throwsA(isA<AccountFollowAuthError>()),
      );
      expect(fake.requests, isEmpty);
    });
  });

  group('斗鱼', () {
    test('parses the follow list (built from documented shape)', () {
      var page = parseDouyuFollowList(
        fixture('douyu_follow_list_page1.json'),
        1,
      );
      expect(page.items.map((e) => e.roomId), ["9999", "288016"]);
      expect(page.items.first.userName, "主播甲");
      // 录播轮播（videoLoop=1）不算直播中
      expect(page.items.map((e) => e.isLive), [true, false]);
      expect(page.nextCursor, "2");
      expect(page.total, 3);
      var last = parseDouyuFollowList(
        fixture('douyu_follow_list_page2.json'),
        2,
      );
      expect(last.nextCursor, isNull);
      expect(last.items.single.isLive, isFalse);
    });

    test('not logged in (captured) and unknown write errors', () {
      // captured：匿名请求 follow/list 的返回
      var notLogin = {"code": -1, "error": -1, "msg": "用户未登陆或token已过期"};
      expect(isDouyuNotLogin(notLogin), isTrue);
      expect(
        () => parseDouyuFollowList(notLogin, 1),
        throwsA(isA<AccountFollowAuthError>()),
      );
      checkDouyuFollowWrite({"error": 0, "msg": "", "data": []}, follow: true);
      // 没有资料的错误码一律停止
      expect(
        () => checkDouyuFollowWrite({
          "error": 1001,
          "msg": "操作太频繁",
        }, follow: true),
        throwsA(isA<AccountFollowRiskError>()),
      );
    });

    test('write sends ctn equal to the acf_ccn cookie', () async {
      var fake = FakeFollowHttp((_) => ok({"error": 0, "msg": ""}))..install();
      var site = DouyuSite()..cookie = "acf_uid=777; acf_auth=x";
      expect(site.accountFollowOwner, "777");
      await site.followOnAccount(
        const AccountFollowTarget(roomId: "9999", accountUid: "9999"),
      );
      var request = fake.requests.single;
      expect(request.url.path, "/wgapi/livenc/liveweb/follow/add");
      var form = Uri.splitQueryString(request.body!);
      expect(form["rid"], "9999");
      var ccn = form["ctn"]!;
      expect(ccn, isNotEmpty);
      expect(request.headers["Cookie"], contains("acf_ccn=$ccn"));
      expect(request.headers["Cookie"], contains("acf_uid=777"));

      // Cookie 里已有 acf_ccn 时用它
      site.cookie = "acf_uid=777; acf_ccn=abc";
      await site.unfollowOnAccount(
        const AccountFollowTarget(roomId: "9999", accountUid: "9999"),
      );
      expect(fake.requests.last.url.path, endsWith("/follow/rm"));
      expect(Uri.splitQueryString(fake.requests.last.body!)["ctn"], "abc");
    });

    test('-1 renews the cookie once and retries', () async {
      var fake = FakeFollowHttp.sequence([
        ok({"code": -1, "error": -1, "msg": "用户未登陆或token已过期"}),
        ok(fixture('douyu_follow_list_page2.json')),
      ])..install();
      var renewCalls = 0;
      // 没过期的 acf_jwt_token（exp 为 2100 年），请求前不会先续期
      var payload = base64Url.encode(utf8.encode('{"exp":4102444800}'));
      var jwt = "acf_jwt_token=h.$payload.s";
      late DouyuSite site;
      site = DouyuSite()
        ..cookie = "acf_uid=1; old=1; $jwt"
        ..onCookieExpired = () async {
          renewCalls++;
          site.cookie = "acf_uid=1; new=1; $jwt";
          return site.cookie;
        };
      var page = await site.getAccountFollows();
      expect(renewCalls, 1);
      expect(page.items.single.roomId, "74751");
      expect(fake.requests.last.headers["Cookie"], contains("new=1"));
    });
  });

  test('斗鱼 only renewal credentials left: renew first, then read', () async {
    var fake = FakeFollowHttp.sequence([
      ok(fixture('douyu_follow_list_page2.json')),
    ])..install();
    late DouyuSite site;
    var renewCalls = 0;
    site = DouyuSite()
      ..onCookieExpired = () async {
        renewCalls++;
        site.cookie = "acf_uid=1; fresh=1";
        return site.cookie;
      };
    var page = await site.getAccountFollows();
    expect(renewCalls, 1);
    expect(page.items.single.roomId, "74751");
    expect(fake.requests.single.headers["Cookie"], contains("fresh=1"));

    // 续期也没拿到 Cookie 时不发请求
    var empty = DouyuSite()..onCookieExpired = () async => null;
    expect(
      () => empty.getAccountFollows(),
      throwsA(isA<AccountFollowAuthError>()),
    );
    expect(fake.requests.length, 1);
  });

  group('Kick', () {
    test('parses both follow lists and walks followed → followed-page', () {
      var page = parseKickFollowedPage(fixture('kick_followed.json'));
      expect(page.items.map((e) => e.roomId), ["xqc", "adinross"]);
      expect(page.items.first.userName, "xQc");
      expect(page.items[1].userName, "adinross");
      expect(page.items.map((e) => e.isLive), [true, false]);
      expect(page.nextCursor, "f:25");
      // followed 读完后读 followed-page
      expect(
        parseKickFollowedPage({"channels": [], "nextCursor": 0}).nextCursor,
        "p:0",
      );
      expect(
        parseKickFollowedPage({
          "channels": [],
          "nextCursor": 0,
        }, list: "p").nextCursor,
        isNull,
      );
      expect(parseKickFollowCursor(null), ("f", "0"));
      expect(parseKickFollowCursor("p:25"), ("p", "25"));
    });

    test('status codes: 401 auth, 429/403/challenge risk, 422 write ok', () {
      // captured：匿名请求两个列表接口都是 401 {"message":"Unauthenticated."}
      expect(
        () => checkKickFollowStatus(401, '{"message":"Unauthenticated."}'),
        throwsA(isA<AccountFollowAuthError>()),
      );
      expect(
        () => checkKickFollowStatus(429, ''),
        throwsA(isA<AccountFollowRiskError>()),
      );
      expect(
        () => checkKickFollowStatus(
          200,
          '<!DOCTYPE html><title>Just a moment</title>',
        ),
        throwsA(isA<AccountFollowRiskError>()),
      );
      checkKickFollowWrite(200, '{}');
      checkKickFollowWrite(204, '');
      checkKickFollowWrite(422, '{"message":"already"}');
      expect(
        () => checkKickFollowWrite(404, ''),
        throwsA(isA<AccountFollowRejectedError>()),
      );
      expect(
        () => checkKickFollowWrite(403, 'blocked'),
        throwsA(isA<AccountFollowRiskError>()),
      );
    });

    test('union of the two lists, writes with bearer and cookie', () async {
      var fake = FakeFollowHttp((request) {
        var cursor = request.url.queryParameters["cursor"];
        if (request.method != "GET") {
          return status(request.method == "DELETE" ? 422 : 200, "{}");
        }
        if (request.url.path.endsWith("/followed")) {
          return cursor == "0"
              ? ok(fixture('kick_followed.json'))
              : ok({
                  "channels": [
                    {"channel_slug": "third"},
                  ],
                  "nextCursor": 0,
                });
        }
        // followed-page 多出一个，重复的去掉
        return ok({
          "channels": [
            {"channel_slug": "xqc", "user_username": "xQc"},
            {"channel_slug": "only_in_page", "user_username": "Only"},
          ],
          "nextCursor": 0,
        });
      })..install();
      var site = KickSite()
        ..token = "123|abc"
        ..userName = "Me";
      expect(site.accountFollowOwner, "me");
      expect(site.accountFollowPolicy.listIsAuthoritative, isFalse);
      var result = await fetchAllAccountFollows(site, sleep: (_) async {});
      expect(result.complete, isTrue);
      expect(result.items.map((e) => e.roomId), [
        "xqc",
        "adinross",
        "third",
        "only_in_page",
      ]);
      expect(
        fake.requests.every((e) => e.channel == AccountFollowChannel.kick),
        isTrue,
      );

      await site.followOnAccount(
        const AccountFollowTarget(roomId: "XQC", accountUid: ""),
      );
      var write = fake.requests.last;
      expect(write.method, "POST");
      expect(write.url.path, "/api/v2/channels/xqc/follow");
      expect(write.headers["Authorization"], "Bearer 123|abc");
      expect(write.headers["Cookie"], "session_token=123%7Cabc");
      // 取关时 422（已经不是关注）按成功处理
      await site.unfollowOnAccount(
        const AccountFollowTarget(roomId: "xqc", accountUid: "xqc"),
      );
      expect(fake.requests.last.method, "DELETE");
    });
  });

  group('Twitch', () {
    test('parses the first page of currentUser.follows', () {
      var page = parseTwitchAccountFollows(
        fixture('twitch_follows_page1.json'),
        firstPage: true,
      );
      expect(page.items.map((e) => e.roomId), [
        "xqc",
        "some_streamer",
        "kr_streamer",
      ]);
      expect(page.items.first.accountUid, "71092938");
      expect(page.items.first.userName, "xQcOW(xqc)");
      expect(page.items[1].userName, "some_streamer");
      expect(page.items[2].userName, "한국어(kr_streamer)");
      expect(page.items.map((e) => e.isLive), [true, false, false]);
      expect(page.nextCursor, "c3");
      expect(page.total, 150);
    });

    test(
      'integrity check on the next page truncates, on the first page fails',
      () {
        // 调研时匿名请求带游标的 streams 第二页实际拿到的返回，路径改成 follows
        var integrity = {
          "errors": [
            {
              "message": "failed integrity check",
              "path": ["currentUser", "follows"],
              "extensions": {"code": "IntegrityCheckFailed"},
            },
          ],
          "data": {
            "currentUser": {"follows": null},
          },
          "extensions": {
            "challenge": {"type": "integrity"},
          },
        };
        var page = parseTwitchAccountFollows(integrity, firstPage: false);
        expect(page.items, isEmpty);
        expect(page.truncatedReason, kTwitchFollowsTruncated);
        expect(
          () => parseTwitchAccountFollows(integrity, firstPage: true),
          throwsA(isA<CoreError>()),
        );
        // captured：匿名请求 currentUser.follows 的返回
        expect(
          () => parseTwitchAccountFollows({
            "data": {"currentUser": null},
            "extensions": {},
          }, firstPage: true),
          throwsA(isA<AccountFollowAuthError>()),
        );
      },
    );

    test('import keeps the first 100 and says so; no write-back', () async {
      var integrity = {
        "errors": [
          {
            "message": "failed integrity check",
            "extensions": {"code": "IntegrityCheckFailed"},
          },
        ],
        "data": {
          "currentUser": {"follows": null},
        },
      };
      var fake = FakeFollowHttp.sequence([
        ok(fixture('twitch_follows_page1.json')),
        ok(integrity),
      ])..install();
      var site = TwitchSite()
        ..token = "tok"
        ..login = "Me";
      var result = await fetchAllAccountFollows(site, sleep: (_) async {});
      expect(result.complete, isFalse);
      expect(result.incompleteReason, kTwitchFollowsTruncated);
      expect(result.items.length, 3);
      var second = jsonDecode(fake.requests.last.body!);
      expect(second["variables"]["after"], "c3");
      expect(fake.requests.first.headers["Authorization"], "OAuth tok");
      expect(site.canWriteAccountFollows, isFalse);
    });
  });

  group('YouTube', () {
    YouTubeSite oauthSite() => YouTubeSite()
      ..credentials = YouTubeCredentials(
        oauthConfig: const YouTubeOAuthConfig(clientId: "c", clientSecret: "s"),
        oauthToken: YouTubeOAuthToken(
          accessToken: "at",
          refreshToken: "rt",
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
      )
      ..followOAuthChannelId = "UCme";

    test('parses subscriptions.list (documented shape)', () {
      var page = parseYouTubeSubscriptions(
        fixture('youtube_subscriptions.json'),
      );
      expect(page.items.map((e) => e.roomId), [
        "UCSJ4gkVC6NrvII8umztf0Ow",
        "UCLA_DiR1FfKNvjuUpBHmylQ",
      ]);
      expect(page.items.first.extra["subscriptionId"], "sub-aaa");
      expect(page.items.first.face, "https://yt3.ggpht.com/lofi=s240");
      expect(page.items.first.isLive, isNull);
      expect(page.nextCursor, "CDIQAA");
      expect(page.total, 52);
    });

    test('parses the FEchannels feed (built from YouTube.js shapes)', () {
      var page = parseYouTubeChannelsFeed(
        fixture('youtube_channels_feed.json'),
      );
      expect(page.items.map((e) => e.userName), ["Lofi Girl", "NASA"]);
      expect(page.items.first.face, "https://yt3.ggpht.com/lofi=s88");
      expect(page.nextCursor, "4qmFsgNEXT");
    });

    test(
      'OAuth: reads with bearer, follow duplicate is ok, unfollow looks up the id',
      () async {
        var fake = FakeFollowHttp((request) {
          var q = request.url.queryParameters;
          if (request.method == "GET" && q["forChannelId"] != null) {
            return ok({
              "items": [
                {"id": "sub-found"},
              ],
            });
          }
          if (request.method == "GET") {
            return ok(
              q["pageToken"] == null
                  ? fixture('youtube_subscriptions.json')
                  : {
                      "items": [],
                      "pageInfo": {"totalResults": 52},
                    },
            );
          }
          if (request.method == "POST") {
            // documented：subscriptions.insert 已订阅时的错误
            return status(400, {
              "error": {
                "code": 400,
                "message":
                    "The subscription that you are trying to create already exists.",
                "errors": [
                  {"reason": "subscriptionDuplicate"},
                ],
              },
            });
          }
          return status(204);
        })..install();
        var site = oauthSite();
        expect(site.accountFollowOwner, "oauth:UCme");
        expect(site.accountFollowPolicy.writeQuotaCost, 50);
        var result = await fetchAllAccountFollows(site, sleep: (_) async {});
        expect(result.complete, isTrue);
        expect(result.items.length, 2);
        expect(fake.requests.first.headers["Authorization"], "Bearer at");
        expect(fake.requests.first.url.queryParameters["mine"], "true");
        expect(fake.requests.first.channel, AccountFollowChannel.youtube);

        var target = const AccountFollowTarget(
          roomId: "UCSJ4gkVC6NrvII8umztf0Ow",
          accountUid: "UCSJ4gkVC6NrvII8umztf0Ow",
        );
        await site.followOnAccount(target);
        expect(
          jsonDecode(
            fake.requests.last.body!,
          )["snippet"]["resourceId"]["channelId"],
          "UCSJ4gkVC6NrvII8umztf0Ow",
        );

        await site.unfollowOnAccount(target);
        expect(
          fake
              .requests[fake.requests.length - 2]
              .url
              .queryParameters["forChannelId"],
          "UCSJ4gkVC6NrvII8umztf0Ow",
        );
        expect(fake.requests.last.method, "DELETE");
        expect(fake.requests.last.url.queryParameters["id"], "sub-found");

        // 已知订阅 ID 时直接删除
        var before = fake.requests.length;
        await site.unfollowOnAccount(
          const AccountFollowTarget(
            roomId: "UCSJ4gkVC6NrvII8umztf0Ow",
            accountUid: "UCSJ4gkVC6NrvII8umztf0Ow",
            extra: {"subscriptionId": "sub-aaa"},
          ),
        );
        expect(fake.requests.length, before + 1);
        expect(fake.requests.last.url.queryParameters["id"], "sub-aaa");
      },
    );

    test(
      'OAuth unfollow with a stale subscription id looks it up again',
      () async {
        var fake = FakeFollowHttp((request) {
          var q = request.url.queryParameters;
          if (request.method == "DELETE") {
            return q["id"] == "sub-old"
                ? status(404, {
                    "error": {
                      "errors": [
                        {"reason": "subscriptionNotFound"},
                      ],
                    },
                  })
                : status(204);
          }
          return ok({
            "items": [
              {"id": "sub-new"},
            ],
          });
        })..install();
        await oauthSite().unfollowOnAccount(
          const AccountFollowTarget(
            roomId: "UCSJ4gkVC6NrvII8umztf0Ow",
            accountUid: "UCSJ4gkVC6NrvII8umztf0Ow",
            extra: {"subscriptionId": "sub-old"},
          ),
        );
        expect(fake.requests.map((e) => e.method), ["DELETE", "GET", "DELETE"]);
        expect(fake.requests.last.url.queryParameters["id"], "sub-new");
      },
    );

    test(
      'OAuth errors: forbidden and quota stop, not found counts as done',
      () {
        expect(
          () => checkYouTubeFollowResponse(400, {
            "error": {
              "errors": [
                {"reason": "subscriptionForbidden"},
              ],
              "message": "Too many recent subscriptions.",
            },
          }),
          throwsA(isA<AccountFollowRiskError>()),
        );
        expect(
          () => checkYouTubeFollowResponse(403, {
            "error": {
              "errors": [
                {"reason": "quotaExceeded"},
              ],
            },
          }),
          throwsA(isA<AccountFollowRiskError>()),
        );
        expect(
          () => checkYouTubeFollowResponse(401, {
            "error": {"message": "Invalid Credentials"},
          }),
          throwsA(isA<AccountFollowAuthError>()),
        );
        expect(parseYouTubeSubscriptionId({"items": []}), isNull);
      },
    );

    test(
      'cookie: browse FEchannels and continuation, subscribe endpoint',
      () async {
        var fake = FakeFollowHttp((request) {
          if (request.url.path.endsWith("/browse")) {
            var body = jsonDecode(request.body!);
            return body["browseId"] == "FEchannels"
                ? ok(fixture('youtube_channels_feed.json'))
                : ok({"onResponseReceivedActions": []});
          }
          return ok({"responseContext": {}});
        })..install();
        var site = YouTubeSite()
          ..credentials = YouTubeCredentials(cookie: "SAPISID=abc; SID=x")
          ..followCookieChannelId = "UCme";
        expect(site.accountFollowOwner, "cookie:UCme");
        var result = await fetchAllAccountFollows(site, sleep: (_) async {});
        expect(result.complete, isTrue);
        expect(result.items.length, 2);
        expect(
          jsonDecode(fake.requests[1].body!)["continuation"],
          "4qmFsgNEXT",
        );
        expect(
          fake.requests.first.headers["Authorization"],
          startsWith("SAPISIDHASH "),
        );

        await site.followOnAccount(
          const AccountFollowTarget(
            roomId: "UCLA_DiR1FfKNvjuUpBHmylQ",
            accountUid: "UCLA_DiR1FfKNvjuUpBHmylQ",
          ),
        );
        var write = fake.requests.last;
        expect(write.url.path, "/youtubei/v1/subscription/subscribe");
        var body = jsonDecode(write.body!);
        expect(body["channelIds"], ["UCLA_DiR1FfKNvjuUpBHmylQ"]);
        expect(body["params"], "EgIIAhgA");
      },
    );
  });
}
