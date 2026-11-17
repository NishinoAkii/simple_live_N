import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/room_area.dart';
import 'package:simple_live_core/src/common/youtube_parser.dart';
import 'package:test/test.dart';

/// 直播分区：从进直播间时已经读到的房间信息里取（不另外请求）。
/// 斗鱼、虎牙、抖音的字段是 2026-11-17 匿名看真实响应记下的
void main() {
  test("哔哩哔哩：room_info.area_name，没有时用上一级", () {
    Map<String, dynamic> fixture() => jsonDecode(
      File("test/fixtures/bili_voice_room.json").readAsStringSync(),
    );
    expect(LiveRoomArea.bilibili(fixture()), "点唱");
    var data = fixture();
    (data["room_info"] as Map)["area_name"] = "";
    expect(LiveRoomArea.bilibili(data), "聊天室");
    (data["room_info"] as Map).remove("parent_area_name");
    expect(LiveRoomArea.bilibili(data), isNull);
    expect(LiveRoomArea.bilibili({}), isNull);
    expect(LiveRoomArea.bilibili(null), isNull);
  });

  test("斗鱼：betard 的 room.second_lvl_name，没有时用 h5room 的 game_name", () {
    // 74751 没开播时也有
    var room = {
      "cate_id": 1282,
      "cate2_id": "1282",
      "second_lvl_name": "主机其他游戏",
    };
    var h5 = {"cate_id": "1282", "game_name": "主机其他游戏"};
    expect(LiveRoomArea.douyu(room, h5), "主机其他游戏");
    expect(LiveRoomArea.douyu({"cate_id": 1282}, {"game_name": "颜值"}), "颜值");
    expect(LiveRoomArea.douyu({"second_lvl_name": " "}, null), isNull);
    // h5room 出错时 data 不是对象
    expect(LiveRoomArea.douyu({}, "error"), isNull);
  });

  test("虎牙：在播看 tLiveInfo，没开播看上一场 tRecentLive", () {
    var live = {
      "eLiveStatus": 2,
      "tLiveInfo": {"iGid": 1, "sGameFullName": "英雄联盟", "sGameHostName": "lol"},
      "tRecentLive": {"iGid": 0, "sGameFullName": ""},
    };
    var offline = {
      "eLiveStatus": 1,
      "tLiveInfo": {"iGid": 0, "sGameFullName": ""},
      "tRecentLive": {"iGid": 1, "sGameFullName": "英雄联盟"},
    };
    expect(LiveRoomArea.huya(live), "英雄联盟");
    expect(LiveRoomArea.huya(offline), "英雄联盟");
    expect(LiveRoomArea.huya({"tLiveInfo": {}}), isNull);
    expect(LiveRoomArea.huya(null), isNull);
  });

  test("抖音：partition_road_map 里子分区优先，子分区没名字时用上一级", () {
    Map<String, dynamic> roadMap(String parent, String? sub) => {
      "partition": {"id_str": "2", "type": 1, "title": parent},
      if (sub != null)
        "sub_partition": {
          "partition": {"id_str": "1010045", "type": 1, "title": sub},
        },
    };
    expect(LiveRoomArea.douyin(roadMap("竞技游戏", "王者荣耀")), "王者荣耀");
    // 没开播的直播间：子分区只有 id
    expect(LiveRoomArea.douyin(roadMap("竞技游戏", "")), "竞技游戏");
    expect(LiveRoomArea.douyin(roadMap("聊天", null)), "聊天");
    // 不分区的（带货）：{} 或者没有这个字段
    expect(LiveRoomArea.douyin({}), isNull);
    expect(LiveRoomArea.douyin(null), isNull);
  });

  test("Kick：livestream.categories 的第一个；没开播没有", () {
    var livestream = {
      "is_live": true,
      "categories": [
        {"id": 15, "name": "Just Chatting", "slug": "just-chatting"},
      ],
    };
    expect(LiveRoomArea.kick(livestream), "Just Chatting");
    expect(LiveRoomArea.kick({"categories": []}), isNull);
    expect(LiveRoomArea.kick(null), isNull);
  });

  test("Twitch、YouTube：已有的文字，空的算没有", () {
    expect(LiveRoomArea.clean("Just Chatting"), "Just Chatting");
    expect(LiveRoomArea.clean(""), isNull);
    expect(LiveRoomArea.clean(null), isNull);
    expect(LiveRoomArea.clean(12), isNull);
    var info = YouTubePlayerInfo.fromJson(
      json.decode(
        File("test/fixtures/youtube/player_web_live.json").readAsStringSync(),
      ),
    );
    expect(LiveRoomArea.clean(info.category), "Gaming");
  });

  test("直播间信息：分区不写就是 null", () {
    LiveRoomDetail detail({String? area}) => LiveRoomDetail(
      roomId: "1",
      title: "t",
      cover: "",
      userName: "u",
      userAvatar: "",
      online: 0,
      status: true,
      url: "",
      area: area,
    );
    expect(detail().area, isNull);
    expect(detail(area: "主机游戏").area, "主机游戏");
  });
}
