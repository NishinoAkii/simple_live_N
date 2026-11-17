// 结果少时的补救搜索和“你是不是要找”（只指向主播），不联网
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/search/search_list_controller.dart';
import 'package:simple_live_app/modules/search/search_merge.dart';
import 'package:simple_live_core/simple_live_core.dart';

LiveRoomItem room(String id, String name) =>
    LiveRoomItem(roomId: id, title: "$name 的直播", cover: "", userName: name);

LiveAnchorItem anchor(String id, String name, {bool live = false}) =>
    LiveAnchorItem(roomId: id, avatar: "", userName: name, liveStatus: live);

SearchEntry entry(String id, String name) =>
    SearchEntry(roomId: id, anchor: anchor(id, name));

/// 原词只搜到不相关的，全拼能搜到本人
class _PinyinSite extends LiveSite {
  final calls = <String>[];
  String? correction;

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword,
      {int page = 1}) async {
    calls.add("rooms:$keyword");
    return LiveSearchRoomResult(
      hasMore: false,
      items: keyword == "老翻茄" ? [room("1", "番茄炒蛋")] : [],
      correction: correction,
    );
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(String keyword,
      {int page = 1}) async {
    calls.add("anchors:$keyword");
    if (keyword == "laofanqie") {
      return LiveSearchAnchorResult(hasMore: false, items: [
        anchor("21852", "老番茄"),
        anchor("1", "番茄炒蛋"),
        anchor("77", "别的主播"),
      ]);
    }
    if (keyword == "张大仙") {
      return LiveSearchAnchorResult(
          hasMore: false, items: [anchor("688", "张大仙")]);
    }
    return LiveSearchAnchorResult(hasMore: false, items: []);
  }
}

/// 一次请求同时给两种结果的平台（像哔哩哔哩）
class _AllSite extends LiveSite implements LiveSearchAllSite {
  final calls = <String>[];
  @override
  Future<LiveSearchAllResult> searchAll(String keyword, {int page = 1}) async {
    calls.add(keyword);
    return LiveSearchAllResult(
      rooms: [],
      anchors: keyword == "zhangdaxian" ? [anchor("688", "张大仙")] : [],
      hasMoreRooms: false,
      hasMoreAnchors: false,
    );
  }
}

SearchListController controllerFor(String id, LiveSite liveSite) {
  var c = SearchListController(
      Site(id: id, name: id, logo: "", liveSite: liveSite));
  c.directResolver = (site, input) async => null;
  return c;
}

void main() {
  group("补救搜索用的词", () {
    test("中文关键词结果少时用全拼，有繁体时再用简体，最多两个", () {
      expect(
        searchRescueQueries("老翻茄", []),
        [(keyword: "laofanqie", tag: "按拼音匹配")],
      );
      expect(
        searchRescueQueries("張大仙", [entry("1", "a")]),
        [
          (keyword: "zhangdaxian", tag: "按拼音匹配"),
          (keyword: "张大仙", tag: "按简体匹配"),
        ],
      );
      // 哔哩哔哩、虎牙自己会繁简互换
      expect(
        searchRescueQueries("張大仙", [], serverHandlesTraditional: true),
        [(keyword: "zhangdaxian", tag: "按拼音匹配")],
      );
    });

    test("结果够多又有名字接近的不补救；拉丁字母不补救", () {
      var enough = [
        entry("1", "老番茄"),
        entry("2", "b"),
        entry("3", "c"),
      ];
      expect(searchRescueQueries("老番茄", enough), isEmpty);
      // 够多但名字都不接近：还是补救
      expect(
        searchRescueQueries("老翻茄", [
          entry("1", "a"),
          entry("2", "b"),
          entry("3", "c"),
        ]),
        hasLength(1),
      );
      // 同音（全拼一样）也算接近
      expect(
        searchRescueQueries("老翻茄", [
          entry("1", "老番茄"),
          entry("2", "b"),
          entry("3", "c"),
        ]),
        isEmpty,
      );
      expect(searchRescueQueries("shroud", []), isEmpty);
    });

    test("补救结果的位置：同名原结果 > 名字接近的补救结果 > 其他原结果 > 其他补救结果", () {
      var current = <Object>[entry("1", "番茄炒蛋"), entry("9", "老翻茄")];
      var rescued = [
        SearchEntry(
            roomId: "21852", anchor: anchor("21852", "老番茄"), tag: "按拼音匹配"),
        SearchEntry(roomId: "1", anchor: anchor("1", "番茄炒蛋"), tag: "按拼音匹配"),
        SearchEntry(roomId: "77", anchor: anchor("77", "别人"), tag: "按拼音匹配"),
      ];
      var merged = mergeRescuedEntries("老翻茄", current, rescued);
      expect(merged.map(searchItemRoomId), ["9", "21852", "1", "77"]);
      expect((merged[1] as SearchEntry).tag, "按拼音匹配");
      // 没有新的时原样返回
      expect(mergeRescuedEntries("x", current, []), same(current));
    });
  });

  group("你是不是要找（只指向主播）", () {
    test("字面对不上、全拼或首字母能对上的主播名", () {
      expect(searchDidYouMean("lfq", others: ["老番茄", "LFQ电影"]), "老番茄");
      expect(searchDidYouMean("LFQ", local: ["老番茄"]), "老番茄");
      expect(searchDidYouMean("老翻茄", others: ["番茄炒蛋", "老番茄"]), "老番茄");
      // 关注和看过的先
      expect(
        searchDidYouMean("zdx", local: ["张大侠"], others: ["张大仙"]),
        "张大侠",
      );
      // 字面能对上（前缀、包含）的说明找对了方向，不提示
      expect(searchDidYouMean("lfq", others: ["LFQ电影"]), isNull);
      expect(searchDidYouMean("老番", others: ["老番茄"]), isNull);
      // 已经有同名的结果
      expect(searchDidYouMean("老番茄", others: ["老番茄的粉丝", "老番茄"]), isNull);
      expect(searchDidYouMean("lfq"), isNull);
      expect(searchDidYouMean("", local: ["老番茄"]), isNull);
    });

    test("拼错一两个字母只认关注和看过的，搜索结果里的不算", () {
      expect(searchDidYouMean("shrod", local: ["shroud"]), "shroud");
      expect(searchDidYouMean("minecraft", others: ["minecraf7"]), isNull);
    });

    test("平台给的纠正词只有正好是某个主播的名字时才用", () {
      expect(
        searchDidYouMean("hololive pekoraa",
            others: ["Pekora Ch. 兔田ぺこら"], serverCorrection: "hololive pekora"),
        isNull,
      );
      expect(
        searchDidYouMean("老番", others: ["别人", "老番茄"], serverCorrection: "老番茄"),
        "老番茄",
      );
    });
  });

  group("搜索页", () {
    test("结果少时按全拼补搜（只多一次请求），找到的标“按拼音匹配”排在前面", () async {
      var liveSite = _PinyinSite();
      var c = controllerFor("douyu", liveSite);
      c.keyword = "老翻茄";
      await c.refreshData();
      await c.rescueDone;
      var ids = c.list.map((e) => searchItemRoomId(e)).toList();
      expect(ids, ["21852", "1", "77"]);
      expect((c.list.first as SearchEntry).tag, "按拼音匹配");
      expect(liveSite.calls, ["rooms:老翻茄", "anchors:老翻茄", "anchors:laofanqie"]);
      expect(c.rescuing.value, isFalse);
    });

    test("繁体关键词：全拼和简体各补一次", () async {
      var liveSite = _PinyinSite();
      var c = controllerFor("douyu", liveSite);
      c.keyword = "張大仙";
      await c.refreshData();
      await c.rescueDone;
      expect(c.list.map((e) => searchItemRoomId(e)), ["688"]);
      expect((c.list.first as SearchEntry).tag, "按简体匹配");
      expect(liveSite.calls.where((e) => e.startsWith("anchors:")),
          ["anchors:張大仙", "anchors:zhangdaxian", "anchors:张大仙"]);
    });

    test("一次就有两种结果的平台：补搜也只请求一次，没有结果时不再显示为空", () async {
      var liveSite = _AllSite();
      var c = controllerFor("bilibili", liveSite);
      c.keyword = "張大仙";
      await c.refreshData();
      expect(c.pageEmpty.value, isTrue);
      await c.rescueDone;
      expect(liveSite.calls, ["張大仙", "zhangdaxian"]);
      expect(c.list.map((e) => searchItemRoomId(e)), ["688"]);
      expect(c.pageEmpty.value, isFalse);
    });

    test("房间模式不补救", () async {
      var liveSite = _PinyinSite();
      var c = controllerFor("douyu", liveSite);
      c.searchMode.value = SearchMode.rooms;
      c.keyword = "老翻茄";
      await c.refreshData();
      await c.rescueDone;
      expect(liveSite.calls, ["rooms:老翻茄"]);
    });

    test("按全拼补到的本人可以是“你是不是要找”", () async {
      var c = controllerFor("douyu", _PinyinSite());
      c.keyword = "老翻茄";
      await c.refreshData();
      await c.rescueDone;
      expect(c.correction.value, "老番茄");
    });

    test("关注和看过的、已经取到的主播卡片；不是主播的纠正词不用", () async {
      var c = controllerFor("douyu", _PinyinSite()..correction = "老番茄的视频");
      c.localNames = (siteId, keyword) => siteId == "douyu" ? ["老番茄"] : [];
      c.keyword = "lfq";
      await c.refreshData();
      expect(c.correction.value, "老番茄");
      String? searched;
      c.onSearchWord = (k) => searched = k;
      c.onSearchWord?.call(c.correction.value!);
      expect(searched, "老番茄");

      var c2 = controllerFor("douyu", _PinyinSite());
      c2.cachedSuggestions = (site, keyword) => [
            LiveSuggestion(
              text: "张大仙",
              type: LiveSuggestion.kRoom,
              roomId: "688",
              userName: "张大仙",
            ),
          ];
      c2.keyword = "zdx";
      await c2.refreshData();
      expect(c2.correction.value, "张大仙");

      // 没有对得上的主播：不提示（平台的纠正词不是主播名）
      var c3 = controllerFor("douyu", _PinyinSite()..correction = "老番茄的视频");
      c3.keyword = "lfq";
      await c3.refreshData();
      expect(c3.correction.value, isNull);
    });
  });
}
