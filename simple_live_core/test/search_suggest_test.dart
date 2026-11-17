// 各平台搜索联想的解析，只用保存的响应，不联网
//
// 联想只要直播相关的：主播、直播间卡片；各平台的通用联想词（多是视频、话题词）不要
import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/search_parser.dart';
import 'package:simple_live_core/src/common/youtube_parser.dart';
import 'package:test/test.dart';

String fixtureText(String name) =>
    File('test/fixtures/search/$name').readAsStringSync();

dynamic fixture(String name) => json.decode(fixtureText(name));

void expectOnlyRooms(List<LiveSuggestion> items) {
  expect(items, isNotEmpty);
  expect(items.every((e) => e.isRoom), isTrue);
  expect(items.length, lessThanOrEqualTo(kMaxSuggestions));
  var ids = items.map((e) => e.roomId).toList();
  expect(ids.toSet(), hasLength(ids.length));
}

void main() {
  test("哔哩哔哩：主播搜索（含未开播、轮播）换成主播卡片，不用全站联想词", () {
    var anchors = parseBiliAnchorSearch(fixture("bili_live_user.json"), 1);
    var items = anchorSuggestions(anchors.items);
    expectOnlyRooms(items);
    expect(items.first.roomId, "21852");
    expect(items.first.text, "老番茄");
    expect(items.first.userName, "老番茄");
    expect(items.first.liveStatus, isFalse);
    expect(items.first.avatar, startsWith("https://"));
    // live_status 2 是轮播
    expect(items[2].isRecord, isTrue);
  });

  test("最多 5 张卡片，同一个房间只留一张", () {
    var anchors = [
      for (var i = 0; i < 8; i++)
        LiveAnchorItem(
          roomId: "${i % 7}",
          avatar: "",
          userName: "主播$i",
          liveStatus: i.isEven,
        ),
    ];
    var items = anchorSuggestions(anchors);
    expect(items.map((e) => e.roomId), ["0", "1", "2", "3", "4"]);
    expect(anchorSuggestions(anchors, limit: 10), hasLength(7));
  });

  test("斗鱼：只用 roomResult 主播卡片，鱼吧用户、分类不要", () {
    var data = fixture("douyu_suggest.json");
    (data["data"] as List).add({
      "kw": "热门游戏",
      "type": 2,
      "cateResult": {"cid": 270, "cateName": "热门游戏"},
    });
    var items = parseDouyuSuggestions(data);
    expectOnlyRooms(items);
    var first = items.first;
    expect(first.roomId, "4615502");
    expect(first.userName, "一条小团团OvO");
    expect(first.avatar, startsWith("https://apic.douyucdn.cn/"));
    // isLive 2 是未开播
    expect(first.liveStatus, isFalse);
    expect(first.subtitle, "热门游戏");
    expect(items.map((e) => e.text), isNot(contains("一条小咸鱼zzZ")));
    expect(items.map((e) => e.text), isNot(contains("热门游戏")));
  });

  test("虎牙：主播搜索（v=1）换成主播卡片，不用 typ=-7 的联想词", () {
    var all = parseHuyaSearch(fixture("huya_search.json"), 1, 20);
    var items = anchorSuggestions(all.anchors);
    expectOnlyRooms(items);
    expect(items.first.roomId, "688");
    expect(items.first.userName, "张大仙");
    expect(items.first.liveStatus, isFalse);
  });

  test("抖音：没有联想（不发请求）", () async {
    expect(await DouyinSite().getSearchSuggestions("一条小"), isEmpty);
  });

  test("Twitch：只用频道卡片（带在播状态，包括未开播），分类和纯词不要", () {
    var data = fixture("twitch_suggest.json")["data"];
    (data["searchSuggestions"]["edges"] as List).add({
      "node": {
        "id": "c",
        "text": "Minecraft",
        "content": {
          "__typename": "SearchSuggestionCategory",
          "game": {"displayName": "Minecraft"},
        },
      },
    });
    var items = parseTwitchSuggestions(
      data,
      (name, login) => name.isEmpty ? login : name,
    );
    expectOnlyRooms(items);
    expect(items.first.roomId, "shrood");
    expect(items.first.liveStatus, isTrue);
    var shroud = items.firstWhere((e) => e.roomId == "shroud");
    expect(shroud.liveStatus, isFalse);
    expect(shroud.avatar, startsWith("https://static-cdn.jtvnw.net/"));
    expect(items.map((e) => e.text), isNot(contains("Minecraft")));
  });

  test("Kick：频道卡片（含未开播）和按标题匹配的直播，分类不要", () {
    var data = fixture("kick_suggest.json");
    (data["data"]["categories"] as List).add({
      "name": "Just Chatting",
      "slug": "just-chatting",
    });
    var items = parseKickSuggestions(data);
    expectOnlyRooms(items);
    expect(items.first.roomId, "xqc");
    expect(items.first.liveStatus, isTrue);
    expect(items.where((e) => e.liveStatus == false), isNotEmpty);
    expect(items.where((e) => e.subtitle != null), isNotEmpty);
    expect(items.map((e) => e.text), isNot(contains("Just Chatting")));
  });

  test("YouTube：频道搜索换成频道卡片，没有在播标记时不显示状态", () {
    var response = json.decode(
      File("test/fixtures/youtube/search_channels.json").readAsStringSync(),
    );
    var items = anchorSuggestions(
      parseYouTubeChannels(response),
      knownStatus: false,
    );
    expectOnlyRooms(items);
    expect(items.first.roomId, "UCaaaaaaaaaaaaaaaaaaaaaa");
    expect(items.first.text, "Test Channel");
    expect(items.first.liveStatus, isNull);
  });

  test("YouTube 搜索结果里的纠正词", () {
    expect(
      parseYouTubeCorrection(fixture("youtube_did_you_mean.json")),
      "hololive pekora",
    );
    expect(
      parseYouTubeCorrection({
        "showingResultsForRenderer": {
          "correctedQuery": {
            "runs": [
              {"text": "minecraft"},
            ],
          },
        },
      }),
      "minecraft",
    );
    expect(parseYouTubeCorrection({"contents": []}), isNull);
  });

  test("默认实现是空的", () async {
    expect(await LiveSite().getSearchSuggestions("x"), isEmpty);
  });
}
