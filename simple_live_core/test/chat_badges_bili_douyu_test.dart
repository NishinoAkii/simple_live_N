import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/danmaku/douyu_aside.dart';
import 'package:test/test.dart';

const _guardIcons =
    "https://i0.hdslb.com/bfs/activity-plat/static/20200716/"
    "1d0c5a1b042efb59f46d4ba1286c6727/icon-guard";
const _douyuImages =
    "https://shark2.douyucdn.cn/front-publish/"
    "live-next-player-aside-master/assets/images/";

/// 按 BiliBiliDanmaku.parseMessage 的路径解析，收集发出的消息
List<LiveMessage> runBili(Iterable<Map<String, dynamic>> messages) {
  var out = <LiveMessage>[];
  var danmaku = BiliBiliDanmaku()..onMessage = out.add;
  for (var m in messages) {
    danmaku.parseMessage(json.encode(m));
  }
  return out;
}

List<Map<String, dynamic>> loadBili(String path) =>
    (json.decode(File(path).readAsStringSync())["messages"] as List)
        .cast<Map<String, dynamic>>()
        .where((m) => m["cmd"] == "DANMU_MSG")
        .toList();

/// 只有前几项的 DANMU_MSG，[extra] 按下标放在后面
Map<String, dynamic> shortDanmu(Map<int, dynamic> extra) {
  var length = extra.isEmpty
      ? 3
      : [3, ...extra.keys.map((e) => e + 1)].reduce((a, b) => a > b ? a : b);
  var info = List<dynamic>.filled(length, null);
  info[0] = [];
  info[1] = "测试";
  info[2] = [1, "用户"];
  extra.forEach((k, v) => info[k] = v);
  return {"cmd": "DANMU_MSG", "info": info};
}

/// 按 DouyuDanmaku 收到一帧的路径解析，收集发出的消息
List<LiveMessage> runDouyu(Iterable<String> lines, {String roomId = "24422"}) {
  var out = <LiveMessage>[];
  var danmaku = DouyuDanmaku()
    ..roomId = roomId
    ..onMessage = out.add;
  for (var line in lines) {
    danmaku.decodeMessage(danmaku.serializeDouyu(line));
  }
  return out;
}

List<String> loadDouyu() => File(
  'test/fixtures/badges/douyu_chatmsg.txt',
).readAsLinesSync().where((e) => e.startsWith("type@=")).toList();

/// 样例里哔哩哔哩的粉丝牌：都是主播A 的（主播名、房间号、uid）
LiveBadge biliMedal(int level, int color) => LiveBadge(
  LiveBadgeKind.medal,
  "粉丝牌",
  level: level,
  color: color,
  ownerName: "主播A",
  ownerRoomId: "30000001",
  ownerUid: "20000001",
);

/// 样例里斗鱼的粉丝牌：只有房间号（brid）
LiveBadge douyuMedal(int level, String roomId) =>
    LiveBadge(LiveBadgeKind.medal, "粉丝牌", level: level, ownerRoomId: roomId);

/// 一条弹幕的粉丝牌是谁的（主播名、房间号、uid）
(String?, String?, String?) ownerOf(LiveMessage? message) {
  var medal = message!.badges!.singleWhere(
    (e) => e.kind == LiveBadgeKind.medal,
  );
  return (medal.ownerName, medal.ownerRoomId, medal.ownerUid);
}

/// 假的 HTTP：记录每个请求，按路径返回编好的结果，不访问网络
class OwnerNameAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final routes = <String, Object?>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (!routes.containsKey(options.uri.path)) {
      return ResponseBody.fromString("not found", 404);
    }
    return ResponseBody.fromString(
      json.encode(routes[options.uri.path]),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('哔哩哔哩 DANMU_MSG 的身份', () {
    late List<LiveMessage> out;
    setUpAll(() {
      out = runBili(loadBili('test/fixtures/badges/bilibili_danmu_msg.json'));
    });

    test('舰长 + 房管 + 粉丝牌 + UL + 荣耀 + 头衔，按顺序', () {
      var msg = out[0];
      expect(msg.type, LiveMessageType.chat);
      expect(msg.userName, "用户A");
      expect(msg.message, "晚上好");
      expect(msg.badges, [
        const LiveBadge(
          LiveBadgeKind.guard,
          "舰长",
          level: 3,
          icon: "${_guardIcons}3.png",
        ),
        const LiveBadge(LiveBadgeKind.admin, "房管"),
        biliMedal(21, 1725515),
        const LiveBadge(LiveBadgeKind.level, "UL", level: 12),
        const LiveBadge(LiveBadgeKind.level, "荣耀", level: 16),
        const LiveBadge(LiveBadgeKind.title, "title-111-1"),
      ]);
      // 写进 toString（历史记录用的格式）后还能读回来
      var saved = json.decode(msg.toString())["badges"] as List;
      expect(saved.map(LiveBadge.fromJson).toList(), msg.badges);
    });

    test('没戴粉丝牌（info[3] 是 []）', () {
      var msg = out[1];
      expect(msg.userName, "用户B");
      expect(msg.badges, [
        const LiveBadge(LiveBadgeKind.level, "荣耀", level: 7),
      ]);
    });

    test('什么都没有时为 null', () {
      expect(out[2].userName, "用户C");
      expect(out[2].badges, isNull);
      expect(json.decode(out[2].toString()).containsKey("badges"), isFalse);
    });

    test('数字是字符串也认：总督、粉丝牌、荣耀', () {
      expect(out[3].badges, [
        const LiveBadge(
          LiveBadgeKind.guard,
          "总督",
          level: 1,
          icon: "${_guardIcons}1.png",
        ),
        // 房间号也是字符串
        biliMedal(15, 6067854),
        const LiveBadge(LiveBadgeKind.level, "荣耀", level: 9),
      ]);
    });

    test('实抓的弹幕（fixtures/gifts）：粉丝牌、UL、荣耀', () {
      var real = runBili(loadBili('test/fixtures/gifts/bilibili_gifts.json'));
      expect(real, hasLength(2));
      expect(real[0].badges, [
        biliMedal(21, 1725515),
        const LiveBadge(LiveBadgeKind.level, "荣耀", level: 7),
      ]);
      expect(real[1].badges, [
        biliMedal(27, 398668),
        const LiveBadge(LiveBadgeKind.level, "UL", level: 5),
        const LiveBadge(LiveBadgeKind.level, "荣耀", level: 16),
      ]);
    });

    test('数组太短或类型不对：不算，弹幕照常', () {
      // 只有前三项（表情测试里的写法）
      var msg = BiliBiliDanmaku.parseBiliDanmuMsg(shortDanmu({}))!;
      expect(msg.message, "测试");
      expect(msg.badges, isNull);

      // info[2] 只有 uid 和名字、info[3] 缺名字、info[4] 是 null、
      // info[5] 不是字符串、info[7] 不是数字
      msg = BiliBiliDanmaku.parseBiliDanmuMsg(
        shortDanmu({
          3: [5],
          4: null,
          5: [
            null,
            {"a": 1},
          ],
          7: "abc",
        }),
      )!;
      expect(msg.badges, isNull);

      // 房管是字符串 "1"，粉丝牌整个是字符串，大航海超出范围，荣耀直接是数字
      msg = BiliBiliDanmaku.parseBiliDanmuMsg(
        shortDanmu({
          2: [1, "用户", "1"],
          3: "粉丝牌",
          4: "12",
          5: "title-1",
          7: 4,
          16: 5,
        }),
      )!;
      expect(msg.userName, "用户");
      expect(msg.badges, [
        const LiveBadge(LiveBadgeKind.admin, "房管"),
        const LiveBadge(LiveBadgeKind.level, "荣耀", level: 5),
      ]);

      // 粉丝牌等级 0、颜色 0：有名字就显示，不带等级和颜色；名字为空时不算
      msg = BiliBiliDanmaku.parseBiliDanmuMsg(
        shortDanmu({
          3: [0, "牌子", "", 0, 0],
          16: [0],
        }),
      )!;
      expect(msg.badges, [const LiveBadge(LiveBadgeKind.medal, "牌子")]);
      msg = BiliBiliDanmaku.parseBiliDanmuMsg(
        shortDanmu({
          3: [10, "", "", 0, 0],
        }),
      )!;
      expect(msg.badges, isNull);

      expect(BiliBiliDanmaku.parseBiliDanmuBadges(null), isNull);
      expect(BiliBiliDanmaku.parseBiliDanmuBadges("info"), isNull);
      expect(BiliBiliDanmaku.parseBiliDanmuBadges([]), isNull);
      // 原来就解析不了的照旧返回 null
      expect(BiliBiliDanmaku.parseBiliDanmuMsg({"info": []}), isNull);
    });

    test('粉丝牌是谁的：别的主播的牌子照平台给的写', () {
      LiveMessage? parse(List<dynamic> medal, {dynamic meta}) =>
          BiliBiliDanmaku.parseBiliDanmuMsg(
            shortDanmu({0: meta ?? [], 3: medal}),
          );
      // 第 12 项是主播的 uid
      var medal = [30, "牌子", "主播乙", 30000002, 0, "", 0, 0, 0, 0, 0, 1];
      expect(ownerOf(parse([...medal, 20000002])), (
        "主播乙",
        "30000002",
        "20000002",
      ));
      // 旧的没有第 12 项；新格式里有 user.medal.ruid 时用它
      expect(ownerOf(parse(medal)), ("主播乙", "30000002", null));
      List<dynamic> meta(dynamic user) => [
        ...List<dynamic>.filled(15, 0),
        {"user": user},
      ];
      var ruid = {
        "medal": {"name": "牌子", "ruid": 20000003},
      };
      expect(ownerOf(parse(medal, meta: meta(ruid))).$3, "20000003");
      // 两个都有时用第 12 项，它是 0 时用另一个
      expect(
        ownerOf(parse([...medal, 20000002], meta: meta(ruid))).$3,
        "20000002",
      );
      expect(ownerOf(parse([...medal, 0], meta: meta(ruid))).$3, "20000003");
      // 主播名是空的、房间号是 0：那一项没有，别的照留
      expect(ownerOf(parse([1, "牌子", "", 30000002])), (null, "30000002", null));
      expect(ownerOf(parse([1, "牌子", " 主播乙 ", 0])), ("主播乙", null, null));
      var none = parse([1, "牌子", "", 0, 0, "", 0, 0, 0, 0, 0, 1, 0])!;
      expect(ownerOf(none), (null, null, null));
      expect(none.badges!.single.hasOwner, isFalse);
    });

    test('粉丝牌主人的几项类型不对：算没有，弹幕和别的身份照常', () {
      for (var bad in <dynamic>[
        null,
        true,
        -5,
        "abc",
        "0x10",
        "",
        1.5,
        double.infinity,
        double.nan,
        [1],
        {"a": 1},
      ]) {
        var medal = [3, "牌子", bad, bad, 0, "", 0, 0, 0, 0, 0, 1, bad];
        var metas = <dynamic>[
          bad,
          [...List<dynamic>.filled(15, 0), bad],
          [
            ...List<dynamic>.filled(15, 0),
            {"user": bad},
          ],
          [
            ...List<dynamic>.filled(15, 0),
            {
              "user": {"medal": bad},
            },
          ],
          [
            ...List<dynamic>.filled(15, 0),
            {
              "user": {
                "medal": {"ruid": bad},
              },
            },
          ],
        ];
        for (var meta in metas) {
          var msg = BiliBiliDanmaku.parseBiliDanmuMsg(
            shortDanmu({
              0: meta,
              3: medal,
              16: [5],
            }),
          )!;
          expect(msg.message, "测试", reason: "$bad $meta");
          expect(msg.badges!.map((e) => (e.text, e.level)), [
            ("牌子", 3),
            ("荣耀", 5),
          ], reason: "$bad $meta");
          var (_, room, uid) = ownerOf(msg);
          expect((room, uid), (null, null), reason: "$bad $meta");
        }
      }
    });
  });

  group('斗鱼 chatmsg 的身份', () {
    setUp(DouyuAside.debugReset);
    tearDown(DouyuAside.debugReset);

    test('实抓的消息：贵族、房管、钻粉、没戴粉丝牌', () {
      var out = runDouyu(loadDouyu());
      expect(out, hasLength(4));
      expect(out.map((e) => e.userName), ["用户A", "用户B", "用户C", "用户D"]);
      expect(out[0].message, "内存会降价吗");
      expect(out[0].badges, [
        LiveBadge(
          LiveBadgeKind.noble,
          "骑士",
          level: 1,
          icon: "${_douyuImages}noble-level1_1b45cf2.png",
        ),
        douyuMedal(20, "24422"),
        const LiveBadge(LiveBadgeKind.level, "等级", level: 61),
      ]);
      expect(out[1].badges, [
        const LiveBadge(LiveBadgeKind.admin, "房管"),
        douyuMedal(26, "24422"),
        const LiveBadge(LiveBadgeKind.level, "等级", level: 35),
      ]);
      expect(out[2].badges, [
        LiveBadge(
          LiveBadgeKind.vip,
          "钻粉",
          icon: "${_douyuImages}diamond-icon_0531e5c.png",
        ),
        douyuMedal(28, "9263298"),
        const LiveBadge(LiveBadgeKind.level, "等级", level: 47),
      ]);
      expect(out[3].badges, [
        const LiveBadge(LiveBadgeKind.level, "等级", level: 5),
      ]);
    });

    test('粉丝牌 + 贵族 + 房管/主播 + 钻粉，按顺序', () {
      // 实抓的第一条（贵族）加上 rg、diaf
      var line = loadDouyu().first.replaceFirst(
        "/nl@=1/",
        "/nl@=6/rg@=4/diaf@=1/",
      );
      var badges = runDouyu([line]).single.badges;
      expect(badges, [
        LiveBadge(
          LiveBadgeKind.noble,
          "皇帝",
          level: 6,
          icon: "${_douyuImages}noble-level6_fd2b69e.gif",
        ),
        const LiveBadge(LiveBadgeKind.admin, "房管"),
        LiveBadge(
          LiveBadgeKind.vip,
          "钻粉",
          icon: "${_douyuImages}diamond-icon_0531e5c.png",
        ),
        douyuMedal(20, "24422"),
        const LiveBadge(LiveBadgeKind.level, "等级", level: 61),
      ]);
      var host = runDouyu([line.replaceFirst("/rg@=4/", "/rg@=5/")]);
      expect(
        host.single.badges![1],
        const LiveBadge(LiveBadgeKind.broadcaster, "主播"),
      );
    });

    test('什么都没有时为 null；数字不对的不算', () {
      var plain = loadDouyu().last.replaceFirst("/level@=5/", "/level@=0/");
      var out = runDouyu([plain]);
      expect(out.single.message, "主播为什么又开心了");
      expect(out.single.badges, isNull);

      var odd = plain
          .replaceFirst("/level@=0/", "/level@=/nl@=abc/rg@=1/diaf@=0/")
          .replaceFirst("/bnn@=/bl@=0/", "/bnn@=牌子/bl@=x/");
      expect(runDouyu([odd]).single.badges, [
        const LiveBadge(LiveBadgeKind.medal, "牌子"),
      ]);

      // 不认识名字的贵族等级：叫“贵族”，图标有就给
      var badges = DouyuDanmaku.parseChatBadges({"nl": "9"})!;
      expect(badges.single.text, "贵族");
      expect(badges.single.level, 9);
      expect(badges.single.icon, "${_douyuImages}noble-level9_e1a95f1.png");
      expect(DouyuDanmaku.parseChatBadges({}), isNull);
    });

    test('粉丝牌是谁的：只有房间号（brid），没给、0、不是数字时没有', () {
      var line = loadDouyu().first;
      (String?, String?, String?) owner(String brid) =>
          ownerOf(runDouyu([line.replaceFirst("/brid@=24422/", brid)]).single);
      // 别的房间的牌子
      expect(owner("/brid@=9263298/"), (null, "9263298", null));
      for (var bad in [
        "/",
        "/brid@=/",
        "/brid@=0/",
        "/brid@=-1/",
        "/brid@=abc/",
        // 里面又是一层
        "/brid@=a@A=1@S/",
        "/brid@=1@S@S2/",
      ]) {
        expect(owner(bad), (null, null, null), reason: bad);
      }
    });

    test('按房间号查主播名：只读一次 betard，不登录、不用签名', () async {
      CoreLog.enableLog = false;
      var original = HttpClient.instance.dio.httpClientAdapter;
      var fake = OwnerNameAdapter();
      HttpClient.instance.dio.httpClientAdapter = fake;
      addTearDown(() => HttpClient.instance.dio.httpClientAdapter = original);
      var site = DouyuSite()..cookie = "acf_uid=1; acf_stk=fake";
      fake.routes["/betard/9263298"] = {
        "room": {"room_id": 9263298, "owner_name": " 主播乙 "},
      };
      expect(await site.getRoomOwnerName(roomId: "9263298"), "主播乙");
      var request = fake.requests.single;
      expect(request.method, "GET");
      expect(request.uri.toString(), "https://www.douyu.com/betard/9263298");
      expect(
        request.headers.keys.map((e) => e.toLowerCase()),
        isNot(contains("cookie")),
      );
      // 没有名字：null；没有这个房间、读不到：报错（界面上不提示）
      fake.routes["/betard/1"] = {
        "room": {"room_id": 1, "owner_name": ""},
      };
      expect(await site.getRoomOwnerName(roomId: "1"), isNull);
      fake.routes["/betard/2"] = {"room": null};
      await expectLater(site.getRoomOwnerName(roomId: "2"), throwsA(anything));
      await expectLater(site.getRoomOwnerName(roomId: "3"), throwsA(anything));
      expect(fake.requests, hasLength(4));
    });

    test('没有 dms 的机器人弹幕照旧不发', () {
      var bot = loadDouyu().first.replaceFirst("/dms@=4/", "/");
      expect(runDouyu([bot]), isEmpty);
    });
  });

  group('粉丝牌的主人存进历史记录', () {
    const medal = LiveBadge(
      LiveBadgeKind.medal,
      "牌子",
      level: 30,
      color: 0x2d0855,
      ownerName: "主播乙",
      ownerRoomId: "30000002",
      ownerUid: "20000002",
    );

    test('写出去、读回来一样；原来的键不变，旧版不认识新的键', () {
      var saved = json.decode(json.encode(medal.toJson())) as Map;
      expect(saved, {
        "k": "medal",
        "t": "牌子",
        "l": 30,
        "c": 0x2d0855,
        "n": "主播乙",
        "r": "30000002",
        "u": "20000002",
      });
      expect(LiveBadge.fromJson(saved), medal);
      // 以前的 fromJson：只读原来的那几个键
      LiveBadge old(Map json) => LiveBadge(
        LiveBadgeKind.values.byName(json["k"]),
        json["t"]?.toString() ?? "",
        level: json["l"] is num ? (json["l"] as num).toInt() : null,
        icon: json["i"]?.toString(),
        color: json["c"] is num ? (json["c"] as num).toInt() : null,
      );
      expect(
        old(saved),
        const LiveBadge(LiveBadgeKind.medal, "牌子", level: 30, color: 0x2d0855),
      );
    });

    test('没有的不写；旧的记录（没有这几个键）照样读', () {
      const plain = LiveBadge(LiveBadgeKind.medal, "牌子", level: 30);
      expect(plain.toJson(), {"k": "medal", "t": "牌子", "l": 30});
      var old = LiveBadge.fromJson({"k": "medal", "t": "牌子", "l": 30})!;
      expect(old, plain);
      expect(old.hasOwner, isFalse);
    });

    test('类型不对、空的当作没有；数字当文字读', () {
      for (var bad in <dynamic>[
        null,
        "",
        "  ",
        true,
        [1],
        {"a": 1},
      ]) {
        var badge = LiveBadge.fromJson({
          "k": "medal",
          "t": "牌子",
          "n": bad,
          "r": bad,
          "u": bad,
        })!;
        expect(badge.hasOwner, isFalse, reason: "$bad");
        expect(badge.text, "牌子");
      }
      var number = LiveBadge.fromJson({
        "k": "medal",
        "t": "牌子",
        "r": 30000002,
      })!;
      expect(number.ownerRoomId, "30000002");
    });

    test('主人不一样就不是同一个牌子', () {
      LiveBadge badge({String? name, String? room, String? uid}) => LiveBadge(
        LiveBadgeKind.medal,
        "牌子",
        ownerName: name,
        ownerRoomId: room,
        ownerUid: uid,
      );
      var all = [
        badge(),
        badge(name: "主播乙"),
        badge(room: "1"),
        badge(uid: "1"),
        badge(name: "主播乙", room: "1", uid: "1"),
      ];
      for (var i = 0; i < all.length; i++) {
        for (var j = 0; j < all.length; j++) {
          expect(all[i] == all[j], i == j, reason: "${all[i]} ${all[j]}");
        }
      }
      expect(all.toSet(), hasLength(all.length));
      expect(all.skip(1).every((e) => e.hasOwner), isTrue);
      expect(
        badge(name: "主播乙", room: "1", uid: "1"),
        badge(name: "主播乙", room: "1", uid: "1"),
      );
      expect(
        badge(name: "主播乙", uid: "1").hashCode,
        badge(name: "主播乙", uid: "1").hashCode,
      );
    });

    test('数字 ID：正整数和它的字符串，别的都没有', () {
      expect(liveNumericId(30000002), "30000002");
      expect(liveNumericId(" 30000002 "), "30000002");
      expect(liveNumericId(3546569288714792), "3546569288714792");
      for (var bad in <dynamic>[
        null,
        0,
        "0",
        -1,
        "-1",
        "",
        "abc",
        "0x1f",
        "99999999999999999999",
        1.5,
        double.nan,
        double.infinity,
        true,
        [1],
        {"a": 1},
      ]) {
        expect(liveNumericId(bad), isNull, reason: "$bad");
      }
    });
  });
}
