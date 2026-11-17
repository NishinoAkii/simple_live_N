import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
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
        const LiveBadge(LiveBadgeKind.medal, "粉丝牌", level: 21, color: 1725515),
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
        const LiveBadge(LiveBadgeKind.medal, "粉丝牌", level: 15, color: 6067854),
        const LiveBadge(LiveBadgeKind.level, "荣耀", level: 9),
      ]);
    });

    test('实抓的弹幕（fixtures/gifts）：粉丝牌、UL、荣耀', () {
      var real = runBili(loadBili('test/fixtures/gifts/bilibili_gifts.json'));
      expect(real, hasLength(2));
      expect(real[0].badges, [
        const LiveBadge(LiveBadgeKind.medal, "粉丝牌", level: 21, color: 1725515),
        const LiveBadge(LiveBadgeKind.level, "荣耀", level: 7),
      ]);
      expect(real[1].badges, [
        const LiveBadge(LiveBadgeKind.medal, "粉丝牌", level: 27, color: 398668),
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
        const LiveBadge(LiveBadgeKind.medal, "粉丝牌", level: 20),
        const LiveBadge(LiveBadgeKind.level, "等级", level: 61),
      ]);
      expect(out[1].badges, [
        const LiveBadge(LiveBadgeKind.admin, "房管"),
        const LiveBadge(LiveBadgeKind.medal, "粉丝牌", level: 26),
        const LiveBadge(LiveBadgeKind.level, "等级", level: 35),
      ]);
      expect(out[2].badges, [
        LiveBadge(
          LiveBadgeKind.vip,
          "钻粉",
          icon: "${_douyuImages}diamond-icon_0531e5c.png",
        ),
        const LiveBadge(LiveBadgeKind.medal, "粉丝牌", level: 28),
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
        const LiveBadge(LiveBadgeKind.medal, "粉丝牌", level: 20),
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

    test('没有 dms 的机器人弹幕照旧不发', () {
      var bot = loadDouyu().first.replaceFirst("/dms@=4/", "/");
      expect(runDouyu([bot]), isEmpty);
    });
  });
}
