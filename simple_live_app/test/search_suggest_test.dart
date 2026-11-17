// 搜索联想（只要主播卡片）、本地模糊匹配和搜索历史，不联网
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/search/local_search.dart';
import 'package:simple_live_app/modules/search/search_history.dart';
import 'package:simple_live_app/modules/search/search_suggest_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';

FollowUser follow(String site, String room, String name, {int status = 0}) {
  var f = FollowUser(
    id: "${site}_$room",
    roomId: room,
    siteId: site,
    userName: name,
    face: "",
    addTime: DateTime(2026, 1, 1),
  );
  f.liveStatus.value = status;
  return f;
}

History history(String site, String room, String name, DateTime time) =>
    History(
      id: "${site}_$room",
      roomId: room,
      siteId: site,
      userName: name,
      face: "f$room",
      updateTime: time,
    );

LocalSearchIndex sampleIndex() => LocalSearchIndex.build(
      follows: [
        follow("bilibili", "21852", "老番茄", status: 1),
        follow("huya", "688", "张大仙", status: 2),
        follow("twitch", "shroud", "shroud"),
        follow("bilibili", "100", "番茄炒蛋"),
      ],
      histories: [
        history("bilibili", "8", "東雪蓮Official", DateTime(2026, 10, 1)),
        history("bilibili", "21852", "老番茄", DateTime(2026, 10, 2)),
        history("douyin", "416144012050", "一条小团团OvO", DateTime(2026, 9, 1)),
        history("bilibili", "200", "番茄", DateTime(2026, 10, 3)),
      ],
    );

/// 记下请求，按关键词给联想；可以控制什么时候返回
class _SuggestSite extends LiveSite {
  final calls = <String>[];
  Completer<void>? gate;
  bool fail = false;

  @override
  Future<List<LiveSuggestion>> getSearchSuggestions(String keyword) async {
    calls.add(keyword);
    if (gate != null) await gate!.future;
    if (fail) throw Exception("network");
    return [
      LiveSuggestion(
        text: "老番茄",
        type: LiveSuggestion.kRoom,
        roomId: "21852",
        userName: "老番茄",
        liveStatus: false,
      ),
      LiveSuggestion(
        text: "老番茄的朋友",
        type: LiveSuggestion.kRoom,
        roomId: "999",
        userName: "老番茄的朋友",
        liveStatus: true,
      ),
      LiveSuggestion(text: keyword),
      LiveSuggestion(text: "$keyword 直播"),
      LiveSuggestion(text: "游戏", type: LiveSuggestion.kCategory),
    ];
  }
}

void main() {
  group("搜索历史", () {
    test("新的在前，规范化后相同的合并，最多 30 条", () {
      var list = addSearchHistory(["老番茄", "张大仙"], " 張大仙 ");
      expect(list, ["張大仙", "老番茄", "张大仙"]);
      list = addSearchHistory(["老番茄", "【老番茄】"], "老番茄");
      expect(list, ["老番茄"]);
      list = addSearchHistory(["xQc"], "XQC");
      expect(list, ["XQC"]);
      var many = [for (var i = 0; i < 40; i++) "k$i"];
      expect(addSearchHistory(many, "new"), hasLength(30));
      expect(addSearchHistory(many, "new").first, "new");
      expect(addSearchHistory(["a"], "  "), ["a"]);
    });

    test("读写、删除、清空", () {
      var stored = "[]";
      var store = SearchHistoryStore(
        read: () => stored,
        write: (v) => stored = v,
      );
      store.add("老番茄");
      store.add("张大仙");
      expect(store.load(), ["张大仙", "老番茄"]);
      store.remove("老番茄");
      expect(store.load(), ["张大仙"]);
      store.clear();
      expect(store.load(), isEmpty);
      stored = "坏掉的数据";
      expect(store.load(), isEmpty);
    });
  });

  group("本地模糊匹配", () {
    test("关注和历史合并，同一个房间只留关注的那条", () {
      var index = sampleIndex();
      var ids = index.items.map((e) => e.id).toList();
      expect(ids.where((e) => e == "bilibili_21852"), hasLength(1));
      var tomato = index.items.firstWhere((e) => e.id == "bilibili_21852");
      expect(tomato.source, LocalSearchSource.follow);
      // 时间取较新的（历史里看过）
      expect(tomato.time, DateTime(2026, 10, 2));
      expect(tomato.liveStatus, isFalse);
      expect(
          index.items.firstWhere((e) => e.id == "huya_688").liveStatus, isTrue);
      expect(index.items.firstWhere((e) => e.id == "twitch_shroud").liveStatus,
          isNull);
    });

    test("默认只看当前平台，按分数排", () {
      var index = sampleIndex();
      var r = index.search("番茄", siteId: "bilibili");
      // 完全相同 > 前缀 > 包含
      expect(r.map((e) => e.item.roomId), ["200", "100", "21852"]);
      expect(r.map((e) => e.score), [100, 80, 60]);
      expect(index.search("番茄", siteId: "huya"), isEmpty);
      // 全部平台
      expect(index.search("zdx").map((e) => e.item.id), ["huya_688"]);
    });

    test("繁简、拼音、首字母、同音错字、拼错字母都能找到", () {
      var index = sampleIndex();
      expect(index.search("东雪莲").first.item.roomId, "8");
      expect(index.search("lfq").first.item.roomId, "21852");
      expect(index.search("laofanqie").first.item.roomId, "21852");
      expect(index.search("老翻茄").first.item.roomId, "21852");
      expect(index.search("一条小团团").first.item.siteId, "douyin");
      expect(index.search("ytxtt").first.item.siteId, "douyin");
      expect(index.search("shrod").first.item.roomId, "shroud");
      expect(index.search("不存在的人"), isEmpty);
    });

    test("同分时关注的在前、在播的在前", () {
      var index = LocalSearchIndex.build(
        follows: [
          follow("a", "1", "小明A", status: 1),
          follow("a", "2", "小明B", status: 2),
        ],
        histories: [history("a", "3", "小明C", DateTime(2026, 10, 28))],
      );
      expect(index.search("小明").map((e) => e.item.roomId), ["2", "1", "3"]);
    });
  });

  group("联想", () {
    late _SuggestSite liveSite;
    late SearchSuggestController suggest;
    late String stored;
    late Site current;
    late Site bili;
    late Site douyin;

    setUp(() {
      liveSite = _SuggestSite();
      stored = '["老番茄的直播","张大仙"]';
      bili = Site(id: "bilibili", name: "哔哩哔哩", logo: "", liveSite: liveSite);
      douyin = Site(id: "douyin", name: "抖音直播", logo: "", liveSite: liveSite);
      current = bili;
      suggest = SearchSuggestController(
        currentSite: () => current,
        buildIndex: sampleIndex,
        historyStore: SearchHistoryStore(
          read: () => stored,
          write: (v) => stored = v,
        ),
        policyOf: (id) => id == "douyin"
            ? SearchSuggestPolicy.none
            : const SearchSuggestPolicy(
                debounce: Duration(milliseconds: 20),
                minInterval: Duration(milliseconds: 150),
              ),
      );
      suggest.loadHistory();
    });

    tearDown(() => suggest.dispose());

    test("中文 1 个字、拉丁字母 2 个起才请求", () {
      expect(SearchSuggestController.shouldFetch("番"), isTrue);
      expect(SearchSuggestController.shouldFetch("x"), isFalse);
      expect(SearchSuggestController.shouldFetch("xq"), isTrue);
      expect(SearchSuggestController.shouldFetch("  "), isFalse);
    });

    test("各平台的节奏：主播搜索的平台停 600 毫秒、每秒最多一次；抖音没有联想", () {
      for (var id in ["bilibili", "huya", "youtube"]) {
        var p = SearchSuggestPolicy.of(id);
        expect(p.enabled, isTrue);
        expect(p.debounce, const Duration(milliseconds: 600));
        expect(p.minInterval, const Duration(seconds: 1));
      }
      expect(SearchSuggestPolicy.of("douyin").enabled, isFalse);
      for (var id in ["douyu", "twitch", "kick", "js:acfun"]) {
        expect(SearchSuggestPolicy.of(id).debounce,
            const Duration(milliseconds: 280));
      }
    });

    test("本地匹配马上显示；防抖后只留主播卡片（词、分类不要），本地已有的不重复", () async {
      suggest.onChanged("老番");
      expect(suggest.localMatches.map((e) => e.item.roomId), ["21852"]);
      expect(liveSite.calls, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(liveSite.calls, ["老番"]);
      // 21852 已经在本地匹配里
      expect(suggest.channels.map((e) => e.roomId), ["999"]);
      // 缓存里也只有主播卡片
      expect(
          suggest.cached(bili, "老番")!.map((e) => e.roomId), ["21852", "999"]);
      expect(suggest.cached(bili, "没请求过"), isNull);
    });

    test("连续输入只请求最后一次，同一个词用缓存", () async {
      suggest.onChanged("老");
      suggest.onChanged("老番");
      suggest.onChanged("老番茄");
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(liveSite.calls, ["老番茄"]);
      suggest.onChanged("老番");
      await Future<void>.delayed(const Duration(milliseconds: 250));
      suggest.onChanged("老番茄");
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(liveSite.calls, ["老番茄", "老番"]);
      expect(suggest.channels, isNotEmpty);
    });

    test("同一个平台同时只有一个请求：请求期间输入变了，回来后再请求最新的", () async {
      liveSite.gate = Completer();
      suggest.onChanged("张大");
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(liveSite.calls, ["张大"]);
      suggest.onChanged("张大仙");
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(liveSite.calls, ["张大"]);
      var gate = liveSite.gate!;
      liveSite.gate = null;
      gate.complete();
      // 旧结果不显示；隔够最短间隔后请求最新的输入
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(suggest.channels, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(liveSite.calls, ["张大", "张大仙"]);
      expect(suggest.channels, isNotEmpty);
    });

    test("两次请求至少隔最短间隔", () async {
      suggest.onChanged("ab");
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(liveSite.calls, ["ab"]);
      suggest.onChanged("abc");
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(liveSite.calls, ["ab"]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(liveSite.calls, ["ab", "abc"]);
    });

    test("失败不提示，卡片清空", () async {
      suggest.onChanged("老番");
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(suggest.channels, isNotEmpty);
      liveSite.fail = true;
      suggest.onChanged("失败");
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(liveSite.calls.last, "失败");
      expect(suggest.channels, isEmpty);
    });

    test("抖音不请求联想，只有本地匹配", () async {
      current = douyin;
      suggest.onChanged("一条小团团");
      expect(suggest.localMatches.map((e) => e.item.siteId), ["douyin"]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(liveSite.calls, isEmpty);
      expect(suggest.channels, isEmpty);
    });

    test("关注和看过里匹配的主播名（“你是不是要找”用）", () {
      expect(suggest.localNames("bilibili", "lfq"), ["老番茄"]);
      expect(suggest.localNames("huya", "lfq"), isEmpty);
      expect(suggest.localNames("bilibili", ""), isEmpty);
    });

    test("输入框为空时没有本地匹配；搜索后记进历史", () {
      suggest.onChanged("老番");
      suggest.onChanged("");
      expect(suggest.localMatches, isEmpty);
      expect(suggest.history, ["老番茄的直播", "张大仙"]);
      suggest.recordSearch("lfq");
      expect(suggest.history.first, "lfq");
      suggest.clearHistory();
      expect(suggest.history, isEmpty);
      expect(stored, "[]");
    });

    test("切换全部平台", () {
      suggest.onChanged("张大仙");
      expect(suggest.localMatches, isEmpty);
      suggest.toggleAllPlatforms();
      expect(suggest.localMatches.map((e) => e.item.siteId), ["huya"]);
    });
  });

  test("LRU 缓存：peek 不算用过", () {
    var cache = SearchLruCache<int>(2);
    cache.put("a", 1);
    cache.put("b", 2);
    expect(cache.peek("a"), 1);
    cache.put("c", 3);
    expect(cache.peek("a"), isNull);
    expect(cache.peek("b"), 2);
  });

  test("LRU 缓存", () {
    var cache = SearchLruCache<int>(2);
    cache.put("a", 1);
    cache.put("b", 2);
    expect(cache.get("a"), 1);
    cache.put("c", 3);
    expect(cache.get("b"), isNull);
    expect(cache.get("a"), 1);
    expect(cache.get("c"), 3);
    expect(cache.length, 2);
  });
}
