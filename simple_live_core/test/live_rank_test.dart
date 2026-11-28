import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/proto/douyin.pb.dart';
import 'package:test/test.dart';

// 榜单。抖音、斗鱼、Kick 的样例来自 2026-11-15 匿名读到的回应（名字和 ID 换掉了，结构没动）；
// 哔哩哔哩的样例照着 bilibili-API-collect 的文档手写，没有在真的直播间里试过

dynamic fixture(String name) =>
    json.decode(File("test/fixtures/rank/$name").readAsStringSync());

LiveGiftMessage gift(
  String user, {
  String? id,
  String? price,
  int count = 1,
  bool paid = true,
  String face = "",
  String? estimate,
}) => LiveGiftMessage(
  userName: user,
  userId: id,
  giftName: "礼物",
  count: count,
  paid: paid,
  priceText: price,
  estimate: estimate,
  face: face,
);

void main() {
  tearDown(() => CoreText.lookup = null);

  group("哔哩哔哩", () {
    test("在线贡献榜：名次、uid、分数、牌子；神秘人没有 uid", () {
      var list = parseBiliOnlineRank(fixture("bili_online_rank.json"));
      expect(list.boardId, "online");
      expect(list.total, 45);
      expect(list.items.map((e) => e.rank), [1, 2, 3, 4]);
      var first = list.items.first;
      expect(first.userName, "B站观众一");
      expect(first.userId, "11");
      expect(first.score, 3768);
      expect(first.badges.map((e) => e.kind), [
        LiveBadgeKind.guard,
        LiveBadgeKind.medal,
        LiveBadgeKind.level,
      ]);
      expect(first.badges[0].text, "舰长");
      expect(first.badges[1].text, "测试牌");
      expect(first.badges[1].level, 29);
      expect(first.hasMedal, isTrue);
      // http 的头像换成 https；没戴牌子的
      expect(list.items[1].face, startsWith("https://"));
      expect(list.items[1].hasMedal, isFalse);
      expect(list.items[2].userId, isNull);
      expect(list.items[2].userName, "神秘人");
      // 戴着别家的牌子也算有粉丝牌
      expect(list.items[3].hasMedal, isTrue);
    });

    test("粉丝牌是谁的：榜单里只有主播的 uid（ruid，旧格式 targetId、target_id）", () {
      String? owner(LiveRankItem item) {
        var medal = item.badges.singleWhere(
          (e) => e.kind == LiveBadgeKind.medal,
        );
        expect((medal.ownerName, medal.ownerRoomId), (null, null));
        return medal.ownerUid;
      }

      var online = parseBiliOnlineRank(fixture("bili_online_rank.json"));
      expect(owner(online.items[0]), "3000000001");
      expect(owner(online.items[3]), "3000000099");
      var guards = parseBiliGuardRank(fixture("bili_guard_rank.json"));
      expect(owner(guards.list.items.first), "3000000001");
      var fans = parseBiliFansRank(fixture("bili_fans_rank.json"));
      expect(owner(fans.items.first), "3000000001");

      // 旧格式：没有 uinfo.medal、uinfo_medal
      var data = fixture("bili_online_rank.json");
      for (var item in data["data"]["OnlineRankItem"]) {
        item.remove("uinfo");
      }
      var old = parseBiliOnlineRank(data);
      expect(owner(old.items[3]), "3000000099");
      data = fixture("bili_fans_rank.json");
      for (var item in data["data"]["item"]) {
        item.remove("uinfo_medal");
      }
      expect(owner(parseBiliFansRank(data).items.first), "3000000001");

      // 没给、0、不是数字：没有，牌子照常
      for (var bad in <dynamic>[
        null,
        0,
        "",
        "x",
        -1,
        [1],
      ]) {
        data = fixture("bili_fans_rank.json");
        for (var item in data["data"]["item"]) {
          item["uinfo_medal"]["ruid"] = bad;
        }
        var item = parseBiliFansRank(data).items.first;
        expect(owner(item), isNull, reason: "$bad");
        expect(item.badges.last.text, "测试牌");
      }
    });

    test("大航海：top3 在前，list 从第 4 名接着；陪伴天数是分数", () {
      var result = parseBiliGuardRank(fixture("bili_guard_rank.json"));
      expect(result.pages, 1);
      expect(result.list.total, 5);
      var items = result.list.items;
      expect(items.map((e) => e.rank), [1, 2, 3, 4, 5]);
      expect(items.map((e) => e.badges.first.text), [
        "总督",
        "提督",
        "舰长",
        "舰长",
        "舰长",
      ]);
      expect(items.first.userId, "21");
      expect(items.first.score, 306);
      expect(items.first.scoreText, "306 天");
    });

    test("粉丝团：亲密度、牌子和舰长", () {
      var list = parseBiliFansRank(fixture("bili_fans_rank.json"));
      expect(list.total, 89);
      expect(list.items.length, 2);
      expect(list.items.first.score, 50990540);
      expect(list.items.first.badges.map((e) => e.kind), [
        LiveBadgeKind.guard,
        LiveBadgeKind.medal,
      ]);
      expect(list.items[1].badges.single.level, 21);
    });

    test("接口报错时带上平台的说明", () {
      expect(
        () => parseBiliOnlineRank({"code": -400, "message": "请求错误"}),
        throwsA(
          isA<CoreError>().having(
            (e) => e.message,
            "message",
            contains("请求错误"),
          ),
        ),
      );
    });

    test("推送：ONLINE_RANK_V2 和 V3（protobuf）都认", () {
      var v2 = parseBiliOnlineRankPush(fixture("bili_online_rank_v2.json"))!;
      expect(v2.boardId, "online");
      expect(v2.items.map((e) => e.userName), ["B站观众二", "B站观众一", "B站观众五"]);
      expect(v2.items[1].badges.single.text, "舰长");
      expect(v2.items.first.score, 20);

      var v3 = parseBiliOnlineRankPush(fixture("bili_online_rank_v3.json"))!;
      expect(v3.items.length, 2);
      expect(v3.items.first.userId, "3493118494116797");
      expect(v3.items.first.userName, "高能一号");
      expect(v3.items.first.score, 12);
      expect(v3.items.first.badges.single.text, "总督");
      expect(v3.items[1].rank, 2);
      expect(v3.items[1].badges, isEmpty);

      expect(parseBiliOnlineRankPush({"cmd": "DANMU_MSG"}), isNull);
    });

    test("弹幕连接收到 ONLINE_RANK_V2 时发一条榜单消息", () {
      var danmaku = BiliBiliDanmaku();
      var got = <LiveMessage>[];
      danmaku.onMessage = got.add;
      danmaku.parseMessage(
        File("test/fixtures/rank/bili_online_rank_v2.json").readAsStringSync(),
      );
      expect(got.single.type, LiveMessageType.rank);
      expect((got.single.data as LiveRankUpdate).items.length, 3);
    });
  });

  group("抖音", () {
    test("在线观众榜：没登录时分数是 0，不显示；粉丝团和等级", () {
      var list = parseDouyinAudienceRank(fixture("douyin_audience_rank.json"));
      expect(list.items.length, 4);
      expect(list.items.map((e) => e.rank), [1, 2, 3, 4]);
      var first = list.items.first;
      expect(first.userName, "抖音观众甲🏅");
      expect(first.userId, "9000000000000001");
      expect(first.face, startsWith("https://"));
      expect(first.score, isNull);
      expect(first.scoreText, isNull);
      expect(first.hasMedal, isTrue);
      expect(first.badges.first.text, "粉丝团");
      expect(first.badges.first.icon, contains("fansclub"));
      expect(first.badges.last.kind, LiveBadgeKind.level);
      expect(list.items.last.badges, isEmpty);
    });

    test("登录后有分数时显示平台的写法", () {
      var data = fixture("douyin_audience_rank.json");
      data["data"]["ranks"][0]["score"] = 52000;
      data["data"]["ranks"][0]["score_description"] = "5.2万";
      var first = parseDouyinAudienceRank(data).items.first;
      expect(first.score, 52000);
      expect(first.scoreText, "5.2万");
    });

    test("状态码不是 0 时报错", () {
      expect(
        () => parseDouyinAudienceRank({
          "status_code": 10011,
          "data": {"message": "参数错误"},
        }),
        throwsA(isA<CoreError>()),
      );
    });

    test("RoomUserSeqMessage 里的前三名", () {
      User user(int id, String name, {int club = 0}) {
        var u = User()
          ..id = Int64(id)
          ..nickName = name
          ..avatarThumb = (Image()
            ..urlListList.add("https://p3.douyinpic.com/a$id.jpg"));
        if (club > 0) {
          u.fansClub = FansClub()
            ..data = (FansClubData()
              ..level = club
              ..userFansClubStatus = 1);
        }
        return u;
      }

      var message = RoomUserSeqMessage()
        ..ranksList.addAll([
          RoomUserSeqMessageContributor()
            ..rank = Int64(1)
            ..score = Int64(300)
            ..user = user(1, "甲", club: 5),
          RoomUserSeqMessageContributor()
            ..rank = Int64(2)
            ..isHidden = true
            ..user = user(2, ""),
          RoomUserSeqMessageContributor()
            ..rank = Int64(3)
            ..user = user(3, "丙"),
        ]);
      var top = DouyinDanmaku.douyinSeqRankTop(message)!;
      expect(top.boardId, "online");
      expect(top.items.map((e) => e.userName), ["甲", "丙"]);
      expect(top.items.first.userId, "1");
      expect(top.items.first.score, 300);
      expect(top.items.first.hasMedal, isTrue);
      expect(top.items[1].score, isNull);
      expect(DouyinDanmaku.douyinSeqRankTop(RoomUserSeqMessage()), isNull);
    });
  });

  group("斗鱼", () {
    test("亲密榜：名次、uid、亲密度", () {
      var list = parseDouyuIntimacyRank(fixture("douyu_intimacy_rank.json"));
      expect(list.boardId, "intimacy");
      expect(list.items.length, 12);
      expect(list.items.first.rank, 1);
      expect(list.items.first.userId, "10000");
      expect(list.items.first.score, 23363300);
      expect(list.items.first.face, startsWith("https://apic.douyucdn.cn"));
      // 接口没有公开文档，榜单上要写明
      expect(kDouyuRankBoards.single.note, contains("没有公开"));
    });

    test("error 不是 0 时报错", () {
      expect(
        () => parseDouyuIntimacyRank({"error": 1, "msg": "房间不存在"}),
        throwsA(isA<CoreError>()),
      );
    });
  });

  group("Kick", () {
    test("送订阅榜：全部、本月、本周三份", () {
      var data = fixture("kick_leaderboards.json");
      var all = parseKickLeaderboard(data, "gifts");
      expect(all.items.length, 5);
      expect(all.items.first.rank, 1);
      expect(all.items.first.userName, "kick_viewer_1");
      expect(all.items.first.userId, "501");
      expect(all.items.first.score, 5434);
      expect(parseKickLeaderboard(data, "gifts_week").items.length, 4);
      expect(parseKickLeaderboard(data, "gifts_month").items.length, 4);
    });

    test("主播关了某一份时是空的；回应不对时报错", () {
      var data = fixture("kick_leaderboards.json");
      data["gifts_week_enabled"] = false;
      expect(parseKickLeaderboard(data, "gifts_week").items, isEmpty);
      expect(
        () => parseKickLeaderboard({"message": "x"}, "gifts"),
        throwsA(isA<CoreError>()),
      );
    });
  });

  group("推送的前几名并进榜单", () {
    LiveRankItem item(int rank, String name, {String? id}) =>
        LiveRankItem(rank: rank, userName: name, userId: id);

    test("前面换成推送的，后面去掉重复的人、名次接着排", () {
      var list = [
        item(1, "甲", id: "1"),
        item(2, "乙", id: "2"),
        item(3, "丙", id: "3"),
        item(4, "丁", id: "4"),
      ];
      var merged = mergeRankTop(list, [
        item(2, "甲", id: "1"),
        item(1, "丙改名", id: "3"),
      ]);
      expect(merged.map((e) => e.userName), ["丙改名", "甲", "乙", "丁"]);
      expect(merged.map((e) => e.rank), [1, 2, 3, 4]);
      expect(mergeRankTop(list, const []), same(list));
    });
  });

  group("本场礼物榜", () {
    test("按人加起来排：价值、个数、谁先送", () {
      var ranks = rankGiftSenders([
        gift("甲", id: "1", price: "¥1", face: "https://a/1.jpg"),
        gift("乙", id: "2", price: "¥30"),
        gift("甲改名", id: "1", price: "¥0.5", count: 5),
        gift("丙", price: "¥30"),
        gift("丁", price: null), // 订阅、会员这类没有价格的
        gift("戊", paid: false, price: null), // 免费礼物不算
        gift("乙", id: "2", price: "¥414 · 季"),
      ]);
      expect(ranks.map((e) => e.userName), ["乙", "丙", "甲改名", "丁"]);
      expect(ranks.map((e) => e.rank), [1, 2, 3, 4]);
      expect(ranks.first.scoreText, isNull); // 不显示金额
      expect(ranks.first.detail, "2 个礼物");
      // 同一个 ID 改了名合成一行，用最新的名字，头像留着
      expect(ranks[2].userId, "1");
      expect(ranks[2].scoreText, isNull);
      expect(ranks[2].detail, "6 个礼物");
      expect(ranks[2].face, "https://a/1.jpg");
      expect(ranks[3].scoreText, isNull);
      expect(ranks[3].score, isNull);
    });

    test("抖音的钻、Twitch 的 Bits、Kick 的 Kicks", () {
      var ranks = rankGiftSenders([
        gift("甲", price: "{p} 钻".tf({"p": 520})),
        gift("乙", price: "100 Bits"),
        gift("甲", price: "{p} 钻".tf({"p": 1000})),
      ]);
      expect(ranks.first.userName, "甲");
      expect(ranks.first.scoreText, isNull);
      expect(ranks[1].scoreText, isNull);
      expect(
        liveGiftValue(gift("x", price: "50 Kicks"))!.unit,
        LiveGiftUnit.kicks,
      );
    });

    test("订阅、贵族按标价估的也算上；有价格时用价格", () {
      var ranks = rankGiftSenders([
        gift("甲", price: "Tier 1", estimate: r"$5.99"),
        gift("乙", price: "100 Bits"),
        gift("甲", price: "Tier 1", estimate: r"$5.99"),
        gift("丙", price: "¥30", estimate: r"$99"),
        gift("丁", estimate: "¥76"),
        gift("戊", paid: false, estimate: r"$5.99"),
      ]);
      // 免费的（戊）不进榜
      expect(ranks.map((e) => e.userName), ["丁", "丙", "甲", "乙"]);
      // 不显示金额，只按估的价值排
      expect(ranks.map((e) => e.scoreText), everyElement(isNull));
      expect(liveGiftEstimate(gift("x", estimate: r"$5")), (
        amount: 5.0,
        unit: LiveGiftUnit.usd,
      ));
      expect(liveGiftEstimate(gift("x", price: "¥1", estimate: r"$5")), isNull);
      expect(liveGiftEstimate(gift("x", estimate: "免费")), isNull);
      expect(liveGiftEstimate(gift("x")), isNull);
    });

    test("钻按当前界面语言的写法认", () {
      CoreText.lookup = (key) => const {"{p} 钻": "{p} diamonds"}[key];
      var value = liveGiftValue(gift("x", price: "{p} 钻".tf({"p": 30})))!;
      expect(value.unit, LiveGiftUnit.diamond);
      expect(value.amount, 30);
      expect(rankGiftSenders([gift("x", price: "30 diamonds")]).single.scoreText, isNull);
    });

    test("没有礼物时是空的", () {
      expect(rankGiftSenders(const []), isEmpty);
      expect(kGiftRankBoard.id, "gifts_local");
    });
  });
}
