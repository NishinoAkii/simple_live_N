import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/controller/follow_view_settings.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_controller.dart';
import 'package:simple_live_app/modules/follow_user/follow_view.dart';
import 'package:simple_live_app/modules/search/text/search_text.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:get/get.dart';

import 'fakes/follow_fakes.dart';

FollowUser f(String site, String room,
    {String? name,
    int status = 0,
    String tag = "全部",
    String? started,
    DateTime? added}) {
  var e = fakeFollow(site, room, name: name, tag: tag, addTime: added);
  e.liveStatus.value = status;
  e.liveStartTime = started;
  return e;
}

List<String> rooms(Iterable<FollowUser> list) =>
    list.map((e) => e.roomId).toList();

/// 关注页的分组、排序和搜索
void main() {
  group("分组", () {
    test("按直播源：按平台排序排，不认识的平台放最后，组里顺序不变", () {
      var list = [
        f("kick", "1"),
        f("js:gone", "2"),
        f("twitch", "3"),
        f("kick", "4"),
        f("huya", "5"),
      ];
      var groups = groupFollows(
        list,
        FollowViewSettings.groupSite,
        siteOrder: ["twitch", "kick", "huya"],
        siteName: (id) => "名字$id",
      );
      expect(groups.map((e) => e.key),
          ["site:twitch", "site:kick", "site:huya", "site:js:gone"]);
      expect(rooms(groups[1].members), ["1", "4"]);
      expect(groups[1].title, "名字kick");
      expect(groups[1].siteId, "kick");
    });

    test("按标签：标签的顺序，没标签和标签已删的放进最后的“未分组”，空的组不列", () {
      var tags = [
        FollowUserTag(id: "t1", tag: "朋友", userId: []),
        FollowUserTag(id: "t2", tag: "游戏", userId: []),
        FollowUserTag(id: "t3", tag: "空的", userId: []),
      ];
      var list = [
        f("twitch", "1", tag: "游戏"),
        f("twitch", "2"),
        f("twitch", "3", tag: "朋友"),
        f("twitch", "4", tag: "删掉的标签"),
        f("twitch", "5", tag: "游戏"),
      ];
      var groups = groupFollows(list, FollowViewSettings.groupTag, tags: tags);
      expect(groups.map((e) => e.key), ["tag:t1", "tag:t2", "tag:"]);
      expect(groups.map((e) => e.title), ["朋友", "游戏", "未分组"]);
      expect(rooms(groups[1].members), ["1", "5"]);
      expect(rooms(groups[2].members), ["2", "4"]);
    });

    test("按状态：直播中、未开播、状态未知", () {
      var list = [
        f("twitch", "1", status: 1),
        f("twitch", "2", status: 0),
        f("twitch", "3", status: 2)
      ];
      var groups = groupFollows(list, FollowViewSettings.groupStatus);
      expect(groups.map((e) => e.key), ["status:2", "status:1", "status:0"]);
      expect(groups.map((e) => e.title), ["直播中", "未开播", "状态未知"]);
      var onlyLive = groupFollows([list[2]], FollowViewSettings.groupStatus);
      expect(onlyLive.single.key, "status:2");
    });
  });

  group("排序", () {
    test("默认（直播中在前）原样返回同一个列表", () {
      var list = [f("twitch", "1"), f("twitch", "2")];
      expect(identical(sortFollows(list, FollowViewSettings.sortLive), list),
          isTrue);
    });

    test("最近看过：观看记录新的在前，没看过的按原来的顺序放后面", () {
      var list = [
        f("twitch", "a"),
        f("twitch", "b"),
        f("twitch", "c"),
        f("twitch", "d")
      ];
      var watched = {
        "twitch_c": DateTime(2026, 11, 10),
        "twitch_b": DateTime(2026, 11, 12),
      };
      var sorted = sortFollows(list, FollowViewSettings.sortWatched,
          watchedAt: (e) => watched[e.id]);
      expect(rooms(sorted), ["b", "c", "a", "d"]);
      expect(rooms(list), ["a", "b", "c", "d"], reason: "原列表不动");
    });

    test("最近开播：刚开播的在前，不知道时间的直播中其次，没开播的最后", () {
      var list = [
        f("twitch", "off", status: 1),
        f("twitch", "old", status: 2, started: "1000"),
        f("twitch", "notime", status: 2),
        f("twitch", "new", status: 2, started: "2000"),
        f("twitch", "zero", status: 2, started: "0"),
      ];
      expect(rooms(sortFollows(list, FollowViewSettings.sortStarted)),
          ["new", "old", "notime", "zero", "off"]);
    });

    test("最近关注：关注时间新的在前", () {
      var list = [
        f("twitch", "1", added: DateTime(2025)),
        f("twitch", "2", added: DateTime(2026)),
        f("twitch", "3", added: DateTime(2024)),
      ];
      expect(rooms(sortFollows(list, FollowViewSettings.sortAdded)),
          ["2", "1", "3"]);
    });

    test("按名字：按拼音，中英文混排，没有字母汉字的放最后", () {
      var list = [
        f("twitch", "1", name: "陈一"),
        f("twitch", "2", name: "🎮"),
        f("twitch", "3", name: "Bob"),
        f("twitch", "4", name: "阿狸"),
        f("twitch", "5", name: "老番茄"),
        f("twitch", "6", name: "xqc"),
      ];
      expect(rooms(sortFollows(list, FollowViewSettings.sortName)),
          ["4", "3", "1", "5", "6", "2"]);
    });
  });

  group("搜索", () {
    bool match(String query, String name) =>
        followNameMatches(SearchKey(query), SearchKey(name));

    test("名字、全拼、拼音首字母都能找到", () {
      expect(match("番茄", "老番茄"), isTrue);
      expect(match("laofanqie", "老番茄"), isTrue);
      expect(match("fanqie", "老番茄"), isTrue);
      expect(match("lfq", "老番茄"), isTrue);
      expect(match("l", "老番茄"), isTrue, reason: "一个字母按首字母的开头");
      expect(match("fq", "老番茄"), isTrue, reason: "两个以上字母可以在中间");
      expect(match("q", "老番茄"), isFalse);
      expect(match("XQ", "xQc"), isTrue);
      expect(match("老番茄", "老番茄"), isTrue);
      expect(match("abc", "老番茄"), isFalse);
    });

    test("繁体也能找到", () {
      expect(match("貓", "小猫"), isTrue);
    });

    test("搜索不改顺序；空关键词原样返回", () {
      var list = [
        f("twitch", "1", name: "老番茄"),
        f("twitch", "2", name: "B"),
        f("twitch", "3", name: "老师")
      ];
      var keys = FollowNameKeys();
      expect(rooms(searchFollows(list, "l", keys)), ["1", "3"]);
      expect(identical(searchFollows(list, "  ", keys), list), isTrue);
    });
  });

  group("关注页控制器", () {
    var env = FollowTestEnv();
    setUp(() async {
      await env.setUp();
      await env.addDefaultFollows();
      await env.service.loadData();
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    tearDown(() => env.tearDown());

    test("默认：列表就是关注服务里的那个列表，顺序是直播中的在前", () {
      var c = Get.put(FollowUserController());
      var source = env.service.followList.toList();
      expect(identical(c.present(source), source), isTrue);
      c.filterData();
      // 数据库里按键排（kick_c、twitch_a、twitch_b），直播中的 a 提到最前
      expect(rooms(c.list), ["a", "c", "b"]);
      expect(rooms(c.list), rooms(env.service.followList));
    });

    test("搜索和排序一起用；关掉搜索回到全部", () async {
      var c = Get.put(FollowUserController());
      await DBService.instance.addOrUpdateHistory(History(
        id: "kick_c",
        roomId: "c",
        siteId: "kick",
        userName: "主播c",
        face: "",
        updateTime: DateTime(2026, 11, 15),
      ));
      c.setSortMode(FollowViewSettings.sortWatched);
      expect(rooms(c.list), ["c", "a", "b"]);
      c.startSearch();
      c.setKeyword("zbb");
      expect(rooms(c.list), ["b"]);
      c.stopSearch();
      expect(rooms(c.list), ["c", "a", "b"]);
    });

    test("选择存在本机，重开还在；不进备份", () async {
      var c = Get.put(FollowUserController());
      c.setGrouped(true);
      c.setGroupMode(FollowViewSettings.groupTag);
      c.setStyle(FollowViewSettings.styleCompact);
      c.setSortMode(FollowViewSettings.sortName);
      c.toggleGroup("tag:x");
      var again = FollowViewSettings()..load();
      expect(again.grouped.value, isTrue);
      expect(again.groupMode.value, FollowViewSettings.groupTag);
      expect(again.style.value, FollowViewSettings.styleCompact);
      expect(again.sortMode.value, FollowViewSettings.sortName);
      expect(again.collapsed, {"tag:x"});
      c.toggleGroup("tag:x");
      expect((FollowViewSettings()..load()).collapsed, isEmpty);
      // 认不出的值回到默认
      await LocalStorageService.instance
          .setValue(FollowViewSettings.kStyle, "huh");
      expect((FollowViewSettings()..load()).style.value,
          FollowViewSettings.styleList);
      for (var key in FollowViewSettings.storageKeys) {
        expect(SyncCompat.isLocalOnlySetting(key), isTrue, reason: key);
      }
    });

    test("刷新一组：只查这一组的人（不管上面选了什么），别的组不动", () async {
      var c = Get.put(FollowUserController());
      c.setGrouped(true);
      c.setGroupMode(FollowViewSettings.groupSite);
      // 上面选“直播中”时这一组只看得到 a，刷新还是查 a 和 b
      c.setFilterMode(c.tagList[1]);
      env.sites["twitch"]!.calls.clear();
      env.sites["kick"]!.calls.clear();
      await c.refreshFollowGroup("site:twitch");
      expect(
          env.sites["twitch"]!.calls
              .where((e) => !e.startsWith("detail:"))
              .toSet(),
          {"a", "b"});
      expect(env.sites["kick"]!.calls, isEmpty);
      expect(c.refreshingGroup.value, isNull);
      expect(env.service.updating.value, isFalse);
    });

    test("查到的封面、标题、人气记在内存里，重读数据库后还在", () async {
      var a = env.service.followList.firstWhere((e) => e.roomId == "a");
      expect(a.liveTitle, "标题a");
      expect(a.liveOnline, 1234);
      // 同步、导入以后数据库里是新的对象
      await DBService.instance.addFollow(fakeFollow("twitch", "a"));
      await env.service.loadData(updateStatus: false);
      var again = env.service.followList.firstWhere((e) => e.roomId == "a");
      expect(identical(again, a), isFalse);
      expect(again.liveTitle, "标题a");
      expect(again.liveOnline, 1234);
    });
  });
}
