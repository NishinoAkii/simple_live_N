// 搜索接口的解析，只用保存的响应，不联网
import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/search_parser.dart';
import 'package:test/test.dart';

dynamic fixture(String name) =>
    json.decode(File('test/fixtures/search/$name').readAsStringSync());

String twitchName(String displayName, String login) =>
    displayName.isEmpty ? login : displayName;

void main() {
  group("哔哩哔哩", () {
    test("主播搜索每页 30 个，按 numPages 翻页，包括未开播和轮播", () {
      var result = parseBiliAnchorSearch(fixture("bili_live_user.json"), 1);
      expect(result.items, hasLength(4));
      var first = result.items.first;
      expect(first.roomId, "21852");
      expect(first.userName, "老番茄");
      expect(first.liveStatus, isFalse);
      expect(first.isRecord, isFalse);
      expect(first.followers, 20860654);
      expect(first.avatar, startsWith("https://i0.hdslb.com/"));
      // live_status 2 是轮播
      expect(result.items[2].isRecord, isTrue);
      expect(result.items[2].liveStatus, isFalse);
      // numPages = 7：以前用 items.length >= 40 判断，永远只有第一页
      expect(result.hasMore, isTrue);
      expect(
        parseBiliAnchorSearch(fixture("bili_live_user.json"), 7).hasMore,
        isFalse,
      );
    });

    test("翻页判断", () {
      expect(biliSearchHasMore(1, 7), isTrue);
      expect(biliSearchHasMore(6, "7"), isTrue);
      expect(biliSearchHasMore(7, 7), isFalse);
      expect(biliSearchHasMore(1, null), isFalse);
    });

    test("search_type=live：房间看 pageinfo.live_room，同一响应里还有主播", () {
      var data = fixture("bili_live.json");
      var rooms = parseBiliRoomSearch(data, 1);
      expect(rooms.items, hasLength(3));
      expect(rooms.items.first.roomId, "4602773");
      expect(rooms.items.first.title, isNot(contains("<em")));
      expect(rooms.items.first.cover, startsWith("https://"));
      // live_room 只有 1 页（live_user 有 35 页）
      expect(rooms.hasMore, isFalse);
      expect(rooms.correction, isNull);

      var all = parseBiliLiveSearch(data, 1);
      expect(all.rooms, hasLength(3));
      expect(all.anchors.map((e) => e.roomId), contains("21852"));
      expect(all.hasMoreRooms, isFalse);
      expect(all.hasMoreAnchors, isTrue);
    });

    test("纠正词和错误码", () {
      var data = fixture("bili_live_user.json");
      data["data"]["suggest_keyword"] = "<em class=\"keyword\">老番茄</em>";
      expect(parseBiliAnchorSearch(data, 1).correction, "老番茄");
      expect(
        () => parseBiliAnchorSearch({
          "code": -412,
          "message": "request was banned",
        }, 1),
        throwsA(
          isA<CoreError>().having(
            (e) => e.message,
            "message",
            contains("-412"),
          ),
        ),
      );
    });

    test("UID 换直播间号", () {
      expect(parseBiliRoomIdByUid(fixture("bili_mid2room.json")), "21852");
      expect(
        parseBiliRoomIdByUid({
          "code": 0,
          "data": {"roomid": 0},
        }),
        isNull,
      );
      expect(parseBiliRoomIdByUid({"code": -400}), isNull);
    });
  });

  group("斗鱼", () {
    test("在播判断和网页一致：isLoop 为 1 是轮播，否则看 isLive", () {
      expect(douyuLiveState(1, 0), (live: true, record: false));
      expect(douyuLiveState(1, 1), (live: false, record: true));
      expect(douyuLiveState("1", "0", 1), (live: false, record: true));
      expect(douyuLiveState(2, 0), (live: false, record: false));
      expect(douyuLiveState(null, null), (live: false, record: false));
    });

    test("主播搜索跳过没有 anchorInfo 的项，带粉丝数和上次直播时间", () {
      var result = parseDouyuAnchorSearch(
        fixture("douyu_search_user.json"),
        1,
        20,
      );
      expect(result.items, hasLength(2));
      var first = result.items.first;
      expect(first.roomId, "4615502");
      expect(first.userName, "一条小团团OvO");
      expect(first.liveStatus, isFalse);
      expect(first.followers, 26359918);
      expect(
        first.lastLiveTime,
        DateTime.fromMillisecondsSinceEpoch(1784285960 * 1000),
      );
      // total 13 < 20
      expect(result.hasMore, isFalse);
    });

    test("roomType 不是 0 的在播主播也是直播中", () {
      var result = parseDouyuAnchorSearch(
        {
          "error": 0,
          "data": {
            "total": 45,
            "relateUser": [
              {
                "type": 1,
                "anchorInfo": {
                  "rid": 1,
                  "nickName": "a",
                  "isLive": 1,
                  "isLoop": 0,
                  "roomType": 1,
                },
              },
              {
                "type": 1,
                "anchorInfo": {
                  "rid": 2,
                  "nickName": "b",
                  "isLive": 1,
                  "isLoop": 1,
                  "roomType": 0,
                },
              },
              {
                "type": 2,
                "upInfo": {"nickName": "c"},
              },
            ],
          },
        },
        2,
        20,
      );
      expect(result.items.map((e) => e.liveStatus), [true, false]);
      expect(result.items.map((e) => e.isRecord), [false, true]);
      expect(result.hasMore, isTrue);
    });
  });

  group("抖音", () {
    test("2483 请先登录：抛 LoginRequiredError，不当成没有结果", () {
      expect(
        () => parseDouyinLiveSearch(fixture("douyin_live_search_2483.json")),
        throwsA(
          isA<LoginRequiredError>()
              .having((e) => e.siteId, "siteId", "douyin")
              .having((e) => e.toString(), "text", contains("登录")),
        ),
      );
      expect(() => checkDouyinSearchResult(""), throwsA(isA<CoreError>()));
      expect(
        () => checkDouyinSearchResult({"status_code": 8, "status_msg": "参数错误"}),
        throwsA(
          isA<CoreError>().having(
            (e) => e.message,
            "message",
            contains("参数错误"),
          ),
        ),
      );
    });

    test("正常结果：rawdata 是 JSON 文本", () {
      var items = parseDouyinLiveSearch({
        "status_code": 0,
        "data": [
          {
            "lives": {
              "rawdata": json.encode({
                "title": "标题",
                "owner": {"web_rid": "416144012050", "nickname": "主播"},
                "cover": {
                  "url_list": ["https://p3.douyinpic.com/a.jpg"],
                },
                "stats": {"total_user": 1234},
              }),
            },
          },
          {
            "lives": {"rawdata": "{}"},
          },
        ],
      });
      expect(items, hasLength(1));
      expect(items.first.roomId, "416144012050");
      expect(items.first.online, 1234);
    });
  });

  group("Twitch", () {
    test("频道搜索带游标翻页，包括未开播，带上次直播", () {
      var page1 = parseTwitchSearchChannels(
        fixture("twitch_searchfor.json")["data"],
        twitchName,
      );
      expect(page1.cursor, "MTU=");
      expect(page1.items.first.roomId, "shroud");
      expect(page1.items.first.liveStatus, isFalse);
      expect(page1.items.first.lastTitle, "WOW NAME DAY. FOR THE HORDE!");
      expect(page1.items.first.lastLiveTime, isNotNull);
      expect(page1.items.first.followers, 11291836);
      expect(page1.items[1].liveStatus, isTrue);

      var page2 = parseTwitchSearchChannels(
        fixture("twitch_searchfor_p2.json")["data"],
        twitchName,
      );
      expect(page2.cursor, "MzA=");
      expect(page2.items.first.roomId, "shroudys1");
    });
  });

  group("Kick", () {
    test("enriched 的直播有标题和截图，房间号是频道 slug", () {
      var data = fixture("kick_search_enriched.json");
      var rooms = parseKickSearchLivestreams(data);
      expect(rooms, isNotEmpty);
      expect(rooms.first.roomId, "xqc");
      expect(rooms.first.title, isNotEmpty);
      expect(rooms.first.title, isNot("xQc"));
      expect(rooms.first.cover, startsWith("https://images.kick.com/"));
      expect(rooms.first.online, greaterThan(0));
      var channels = parseKickSearchChannels(data);
      expect(channels.first.roomId, "xqc");
      expect(channels.first.liveStatus, isTrue);
    });

    test("/channels/search 包括未开播的频道", () {
      var channels = parseKickSearchChannels(
        fixture("kick_channels_search.json"),
      );
      expect(channels, hasLength(4));
      expect(channels.where((e) => !e.liveStatus), isNotEmpty);
      expect(channels.first.followers, greaterThan(1000000));
    });
  });

  group("虎牙", () {
    test("一次请求同时有主播（含未开播）和直播间", () {
      var all = parseHuyaSearch(fixture("huya_search.json"), 1, 20);
      expect(all.anchors.first.roomId, "688");
      expect(all.anchors.first.userName, "张大仙");
      expect(all.anchors.first.liveStatus, isFalse);
      expect(all.anchors.first.followers, 28153479);
      expect(all.rooms, hasLength(2));
      expect(all.rooms.first.cover, contains("x-oss-process"));
      // 主播 39 个，每页 20；直播间 5 个
      expect(all.hasMoreAnchors, isTrue);
      expect(all.hasMoreRooms, isFalse);
      expect(
        parseHuyaSearch(fixture("huya_search.json"), 2, 20).hasMoreAnchors,
        isFalse,
      );
      // 接口返回 JSON 文本时也能解析
      var text = File(
        "test/fixtures/search/huya_search.json",
      ).readAsStringSync();
      expect(parseHuyaSearch(text, 1, 20).anchors, hasLength(3));
    });
  });
}
