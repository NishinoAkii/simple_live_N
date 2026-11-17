// 搜索页的逻辑，不联网
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/search/search_direct.dart';
import 'package:simple_live_app/modules/search/search_list_controller.dart';
import 'package:simple_live_app/modules/search/search_merge.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 搜索时抛出要登录的错误（抖音 2483）
class _LoginSite extends LiveSite {
  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) {
    throw LoginRequiredError("抖音要登录后才能搜索", siteId: "douyin");
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(String keyword, {int page = 1}) {
    throw Exception("抖音暂不支持搜索主播，请直接搜索直播间");
  }
}

LiveRoomItem room(String id, String name, {String title = ""}) => LiveRoomItem(
      roomId: id,
      title: title.isEmpty ? "$name 的直播" : title,
      cover: "",
      userName: name,
    );

LiveAnchorItem anchor(String id, String name,
        {bool live = false, bool record = false}) =>
    LiveAnchorItem(
      roomId: id,
      avatar: "a$id",
      userName: name,
      liveStatus: live,
      isRecord: record,
    );

LiveRoomDetail detail(String id, String name, {bool live = true}) =>
    LiveRoomDetail(
      roomId: id,
      title: "标题",
      cover: "",
      userName: name,
      userAvatar: "",
      online: 0,
      status: live,
      url: "",
    );

/// 分页的直播间和主播（两页），记下请求
class _PagedSite extends LiveSite {
  final calls = <String>[];

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword,
      {int page = 1}) async {
    calls.add("rooms$page");
    if (page == 1) {
      return LiveSearchRoomResult(hasMore: true, items: [
        room("1", "路人甲"),
        room("2", "老番茄"),
      ]);
    }
    return LiveSearchRoomResult(hasMore: false, items: [
      room("1", "路人甲"),
      room("3", "路人乙"),
    ]);
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(String keyword,
      {int page = 1}) async {
    calls.add("anchors$page");
    return LiveSearchAnchorResult(hasMore: false, items: [
      anchor("2", "老番茄", live: true),
      anchor("9", "老番茄的粉丝"),
      anchor("8", "老番茄二号", record: true),
    ]);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    calls.add("detail$roomId");
    if (roomId == "21852") return detail("21852", "老番茄", live: false);
    throw Exception("房间不存在");
  }
}

/// 直播间搜索成功但没有结果，主播搜索不支持（像登录后的抖音）
class _EmptyRoomsSite extends LiveSite {
  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword,
          {int page = 1}) async =>
      LiveSearchRoomResult(hasMore: false, items: []);

  @override
  Future<LiveSearchAnchorResult> searchAnchors(String keyword, {int page = 1}) {
    throw Exception("抖音暂不支持搜索主播，请直接搜索直播间");
  }
}

/// 两种都出错
class _FailSite extends LiveSite {
  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword,
          {int page = 1}) async =>
      throw Exception("网络错误");

  @override
  Future<LiveSearchAnchorResult> searchAnchors(String keyword,
          {int page = 1}) async =>
      throw Exception("网络错误");
}

/// 一次请求同时给直播间和主播的平台
class _AllSite extends LiveSite implements LiveSearchAllSite {
  var count = 0;
  @override
  Future<LiveSearchAllResult> searchAll(String keyword, {int page = 1}) async {
    count++;
    return LiveSearchAllResult(
      rooms: [room("5", "张大仙的徒弟")],
      anchors: [
        anchor("688", "张大仙"),
        anchor("5", "张大仙的徒弟", live: true),
        anchor("6", "大仙"),
      ],
      hasMoreRooms: false,
      hasMoreAnchors: false,
    );
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) =>
      throw StateError("综合模式不应该单独搜直播间");
}

/// 哔哩哔哩：房间号打不开时把数字当 UID
class _FakeBili extends BiliBiliSite {
  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    if (roomId == "21852") return detail("21852", "老番茄");
    throw CoreError("房间不存在");
  }

  @override
  Future<String?> getRoomIdByUid(String uid) async =>
      uid == "546195" ? "21852" : null;
}

Site fakeSite(String id, LiveSite liveSite) =>
    Site(id: id, name: id, logo: "", liveSite: liveSite);

void main() {
  group("抖音要登录才能搜索", () {
    test("显示说明和去哪里登录，不当成没有结果", () async {
      var site = fakeSite("douyin", _LoginSite());
      for (var mode in [SearchMode.all, SearchMode.rooms]) {
        var controller = SearchListController(site);
        controller.searchMode.value = mode;
        controller.keyword = "一条小团团";
        Object? error;
        try {
          await controller.getData(1, 20);
        } catch (e) {
          error = e;
        }
        expect(error, isNotNull);
        expect(error.toString(), contains("抖音要登录后才能搜索"));
        expect(error.toString(), contains("设置 → 账号 → 抖音直播"));
        expect(controller.needLogin.value, isTrue);
      }
    });

    test("其他平台的提示", () {
      var text = searchLoginHint(LoginRequiredError("要登录", siteId: "x"));
      expect(text, contains("设置 → 账号"));
    });
  });

  group("直达", () {
    test("各平台的房间号格式", () {
      expect(searchDirectInput("bilibili", "21852"), "21852");
      expect(searchDirectInput("bilibili", "老番茄"), isNull);
      expect(searchDirectInput("bilibili", "abc"), isNull);
      expect(searchDirectInput("douyu", "4615502"), "4615502");
      expect(searchDirectInput("douyu", "xiaozhi"), "xiaozhi");
      expect(searchDirectInput("huya", "688"), "688");
      expect(searchDirectInput("huya", "haddis"), "haddis");
      expect(searchDirectInput("huya", "张大仙"), isNull);
      expect(searchDirectInput("douyin", "416144012050"), "416144012050");
      expect(searchDirectInput("douyin", "7376429659866598196"),
          "7376429659866598196");
      expect(searchDirectInput("douyin", "12345"), isNull);
      expect(searchDirectInput("twitch", "Shroud"), "shroud");
      expect(searchDirectInput("twitch", "ab"), isNull);
      expect(searchDirectInput("twitch", "with space"), isNull);
      expect(searchDirectInput("kick", "xqcow-waiting-room-x"),
          "xqcow-waiting-room-x");
      // YouTube 的 @名称、频道 ID 在搜索前已经直接打开
      expect(searchDirectInput("youtube", "@pekora"), isNull);
      expect(searchDirectInput("js:acfun", "123"), isNull);
    });

    test("能打开时给卡片，打不开时静默", () async {
      var site = fakeSite("douyu", _PagedSite());
      var ok = await resolveSearchDirect(site, "21852");
      expect(ok?.roomId, "21852");
      expect(ok?.label, "房间号 21852");
      expect(await resolveSearchDirect(site, "12345"), isNull);
      // 不像房间号的不请求
      expect(await resolveSearchDirect(site, "老番茄"), isNull);
      expect(
          (site.liveSite as _PagedSite).calls, ["detail21852", "detail12345"]);
    });

    test("直播源用脚本的 resolve 换房间号，没有 resolve 时不试", () async {
      var liveSite = _PagedSite();
      var site = fakeSite("js:acfun", liveSite);
      var ok = await resolveSearchDirect(site, " ac21852 ",
          resolve: (input) async => input == "ac21852" ? "21852" : null);
      expect(ok?.roomId, "21852");
      expect(await resolveSearchDirect(site, "x", resolve: (_) async => null),
          isNull);
      expect(
          await resolveSearchDirect(site, "y",
              resolve: (_) async => throw Exception("脚本出错")),
          isNull);
      // 不是直播源、也没有 resolve：直播源格式一律不试
      expect(await resolveSearchDirect(site, "21852"), isNull);
      expect(liveSite.calls, ["detail21852"]);
    });

    test("哔哩哔哩的数字也可能是 UID", () async {
      var site = fakeSite("bilibili", _FakeBili());
      var byRoom = await resolveSearchDirect(site, "21852");
      expect(byRoom?.label, "房间号 21852");
      var byUid = await resolveSearchDirect(site, "546195");
      expect(byUid?.roomId, "21852");
      expect(byUid?.label, "UID 546195 的直播间");
      expect(await resolveSearchDirect(site, "1"), isNull);
    });
  });

  group("综合", () {
    test("同一房间号合并，名字相同的在前，在播的直播间、再是未开播的主播", () {
      var entries = mergeSearchEntries(
        keyword: "老番茄",
        rooms: [room("1", "路人甲"), room("2", "老番茄"), room("1", "路人甲")],
        anchors: [
          anchor("9", "老番茄的粉丝"),
          anchor("2", "老番茄", live: true),
          anchor("7", "老番茄小号", live: true),
          anchor("8", "老番茄二号", record: true),
        ],
      );
      expect(entries.map((e) => e.roomId), ["2", "1", "7", "9", "8"]);
      // 直播间带上主播信息
      expect(entries.first.room, isNotNull);
      expect(entries.first.anchor?.avatar, "a2");
      expect(entries[3].live, isFalse);
      expect(entries[4].isRecord, isTrue);
    });

    test("名字相同但没开播的也排在最前（在播的同名在它前面）", () {
      var entries = mergeSearchEntries(
        keyword: "【張大仙】",
        rooms: [room("5", "大仙粉丝")],
        anchors: [anchor("688", "张大仙"), anchor("6", "張大仙", live: true)],
      );
      expect(entries.map((e) => e.roomId), ["6", "688", "5"]);
      expect(
          mergeSearchEntries(
            keyword: "zhangdaxian",
            rooms: [],
            anchors: [anchor("1", "某人"), anchor("688", "张大仙")],
          ).first.roomId,
          "688");
      // Twitch 的“显示名(login)”
      expect(
          mergeSearchEntries(
            keyword: "shroud",
            rooms: [room("a", "a")],
            anchors: [anchor("shroud", "某某(shroud)")],
          ).first.roomId,
          "shroud");
    });

    test("跳过已经显示过的", () {
      var entries = mergeSearchEntries(
        keyword: "x",
        rooms: [room("1", "a"), room("2", "b")],
        anchors: [anchor("3", "c")],
        exclude: {"1", "3"},
        tag: "按拼音匹配",
      );
      expect(entries.map((e) => e.roomId), ["2"]);
      expect(entries.first.tag, "按拼音匹配");
    });

    test("并行搜直播间和主播，翻页去重，直达的房间不重复", () async {
      var liveSite = _PagedSite();
      var site = fakeSite("douyu", liveSite);
      var controller = SearchListController(site);
      controller.directResolver = (site, input) async =>
          SearchDirectResult(detail("9", "老番茄的粉丝"), "房间号 9");
      controller.keyword = "老番茄";
      await controller.refreshData();
      await Future<void>.delayed(Duration.zero);
      var ids = controller.list.map((e) => searchItemRoomId(e)).toList();
      expect(ids, ["2", "1", "8"]);
      expect(controller.direct.value?.roomId, "9");
      // 第二页：直播间还有，主播没有了；1 已经显示过
      var page2 = await controller.getData(2, 20);
      expect(page2.map((e) => searchItemRoomId(e)), ["3"]);
      expect(
          liveSite.calls.where((e) => e.startsWith("anchors")), ["anchors1"]);
      // 都没有下一页了
      expect(await controller.getData(3, 20), isEmpty);
    });

    test("一种成功（哪怕是空的）、另一种出错时显示成功的那种，不报错", () async {
      var controller =
          SearchListController(fakeSite("douyin", _EmptyRoomsSite()));
      controller.directResolver = (site, input) async => null;
      controller.keyword = "没有结果";
      expect(await controller.getData(1, 20), isEmpty);
      // 都失败时才报错
      var failing = SearchListController(fakeSite("x", _FailSite()));
      failing.keyword = "a";
      expect(() => failing.getData(1, 20), throwsException);
    });

    test("一次请求就有两种结果的平台只请求一次", () async {
      var liveSite = _AllSite();
      var controller = SearchListController(fakeSite("huya", liveSite));
      controller.directResolver = (site, input) async => null;
      controller.keyword = "张大仙";
      var items = await controller.getData(1, 20);
      expect(items.map((e) => searchItemRoomId(e)), ["688", "5", "6"]);
      expect(liveSite.count, 1);
    });

    test("房间、主播模式按平台给的 hasMore 停止翻页", () async {
      var liveSite = _PagedSite();
      var controller = SearchListController(fakeSite("douyu", liveSite));
      controller.searchMode.value = SearchMode.anchors;
      controller.keyword = "老番茄";
      expect(await controller.getData(1, 20), hasLength(3));
      expect(await controller.getData(2, 20), isEmpty);
      expect(liveSite.calls, ["anchors1"]);
    });
  });

  group("主播卡片的文字", () {
    test("状态和上次直播", () {
      var now = DateTime(2026, 10, 28, 12);
      expect(searchStatusText(true, false), "直播中");
      expect(searchStatusText(false, true), "轮播");
      expect(searchStatusText(false, false), "未开播");
      expect(
          searchTimeAgo(now.subtract(const Duration(seconds: 10)), now), "刚刚");
      expect(searchTimeAgo(now.subtract(const Duration(minutes: 5)), now),
          "5 分钟前");
      expect(
          searchTimeAgo(now.subtract(const Duration(hours: 3)), now), "3 小时前");
      expect(searchTimeAgo(now.subtract(const Duration(days: 2)), now), "2 天前");
      expect(searchTimeAgo(DateTime(2026, 7, 1), now), "07-01");
      expect(searchTimeAgo(DateTime(2023, 8, 14), now), "2023-08-14");
      var item = LiveAnchorItem(
        roomId: "1",
        avatar: "",
        userName: "a",
        liveStatus: false,
        lastTitle: "WOW NAME DAY",
        lastLiveTime: now.subtract(const Duration(hours: 1)),
      );
      expect(searchLastLiveText(item, now), "上次直播 1 小时前：WOW NAME DAY");
      expect(searchLastLiveText(anchor("1", "a"), now), isNull);
      expect(searchLastLiveText(anchor("1", "a", live: true), now), isNull);
    });
  });
}
