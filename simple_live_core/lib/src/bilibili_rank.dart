import 'dart:convert';

import 'package:protobuf/protobuf.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_text.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/danmaku/bilibili_danmaku.dart';
import 'package:simple_live_core/src/danmaku/bilibili_gifts.dart';
import 'package:simple_live_core/src/interface/live_rank_site.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_rank.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';

// 哔哩哔哩直播间的榜单。接口按 bilibili-API-collect（pskdje 镜像）的 docs/live/user.md、
// guard.md、message_stream.md 写。
// 这台电脑不向哔哩哔哩发请求，测试只用照着文档做的样例，还没在真的直播间里试过

const List<LiveRankBoard> kBiliRankBoards = [
  LiveRankBoard(
    id: "online",
    title: "在线贡献榜",
    shortTitle: "贡献榜",
    scoreLabel: "贡献值",
    live: true,
  ),
  LiveRankBoard(id: "guard", title: "大航海", scoreLabel: "陪伴天数"),
  LiveRankBoard(id: "fans", title: "粉丝团", scoreLabel: "亲密度"),
];

/// 在线贡献榜最多读多少人（每页 50 人）
const int kBiliOnlineRankMax = 100;

/// 大航海、粉丝团最多读多少人（每页 30 人）
const int kBiliMemberRankMax = 100;

const Map<int, String> _guardNames = {1: "总督", 2: "提督", 3: "舰长"};

int? _int(dynamic value) => switch (value) {
  num n => n.toInt(),
  String s => int.tryParse(s.trim()),
  _ => null,
};

String _str(dynamic value) =>
    value is String || value is num ? value.toString().trim() : "";

Map _map(dynamic value) => value is Map ? value : const {};

List _list(dynamic value) => value is List ? value : const [];

/// 大航海的牌子（1 总督、2 提督、3 舰长），不是时为 null
LiveBadge? _guardBadge(dynamic level) {
  var value = _int(level) ?? 0;
  var name = _guardNames[value];
  if (name == null) {
    return null;
  }
  return LiveBadge(
    LiveBadgeKind.guard,
    name,
    level: value,
    icon: biliGuardIcon(value, name)?.url,
  );
}

/// 粉丝牌：新格式（uinfo.medal：name、level、color_start）或旧格式
/// （medalInfo：medalName、level、medalColorStart），没有牌子时为 null。
/// 是谁的牌子只有主播的 uid：ruid（旧格式 targetId、target_id）
LiveBadge? _medalBadge(dynamic medal) {
  var m = _map(medal);
  var name = _str(m["name"] ?? m["medalName"] ?? m["medal_name"]);
  if (name.isEmpty) {
    return null;
  }
  var level = _int(m["level"] ?? m["medal_level"]) ?? 0;
  var color =
      (_int(m["color_start"] ?? m["medalColorStart"] ?? m["color"]) ?? 0) &
      0xffffff;
  return LiveBadge(
    LiveBadgeKind.medal,
    name,
    level: level > 0 ? level : null,
    color: color != 0 ? color : null,
    ownerUid:
        liveNumericId(m["ruid"]) ??
        liveNumericId(m["targetId"]) ??
        liveNumericId(m["target_id"]),
  );
}

LiveBadge? _wealthBadge(dynamic level) {
  var value = _int(level) ?? 0;
  return value > 0 ? LiveBadge(LiveBadgeKind.level, "荣耀", level: value) : null;
}

/// 接口的 code 不是 0 时报错（带上平台的说明）
void _check(dynamic result) {
  var code = _int(_map(result)["code"]) ?? -1;
  if (code != 0) {
    var message = _str(_map(result)["message"]);
    throw CoreError(
      message.isEmpty
          ? "读取榜单失败（{code}）".tf({"code": code})
          : "读取榜单失败：{message}".tf({"message": message}),
    );
  }
}

/// 在线贡献榜（getOnlineGoldRank）的一页。神秘人没有 uid（是 0），只按名字认
LiveRankList parseBiliOnlineRank(dynamic result) {
  _check(result);
  var data = _map(_map(result)["data"]);
  var items = <LiveRankItem>[];
  for (var e in _list(data["OnlineRankItem"])) {
    var item = _map(e);
    var uinfo = _map(item["uinfo"]);
    var base = _map(uinfo["base"]);
    var name = _str(item["name"]);
    if (name.isEmpty) name = _str(base["name"]);
    var face = _str(item["face"]);
    if (face.isEmpty) face = _str(base["face"]);
    items.add(
      LiveRankItem(
        rank: _int(item["userRank"]) ?? items.length + 1,
        userName: name,
        userId: liveUserId(item["uid"] ?? uinfo["uid"]),
        face: liveEmoteUrl(face),
        score: _int(item["score"]),
        badges: [
          ?_guardBadge(item["guard_level"] ?? _map(uinfo["guard"])["level"]),
          ?_medalBadge(uinfo["medal"] ?? item["medalInfo"]),
          ?_wealthBadge(item["wealth_level"] ?? _map(uinfo["wealth"])["level"]),
        ],
      ),
    );
  }
  return LiveRankList("online", items, total: _int(data["onlineNum"]));
}

LiveRankItem? _guardItem(dynamic e) {
  var item = _map(e);
  var uinfo = _map(item["uinfo"]);
  var base = _map(uinfo["base"]);
  var name = _str(base["name"]);
  if (name.isEmpty) {
    return null;
  }
  var days = _int(item["accompany"]);
  var guard =
      _guardBadge(_map(uinfo["guard"])["level"]) ??
      _guardBadge(_map(uinfo["medal"])["guard_level"]);
  return LiveRankItem(
    rank: _int(item["rank"]) ?? 0,
    userName: name,
    userId: liveUserId(uinfo["uid"]),
    face: liveEmoteUrl(base["face"]),
    score: days,
    scoreText: days == null ? null : "{n} 天".tf({"n": days}),
    badges: [?guard, ?_medalBadge(uinfo["medal"])],
  );
}

/// 大航海（guardTab/topListNew）的一页：第 1 页的 top3 是前三名，list 从第 4 名开始。
/// 返回这一页的人和接口说的总页数
({LiveRankList list, int pages}) parseBiliGuardRank(dynamic result) {
  _check(result);
  var data = _map(_map(result)["data"]);
  var info = _map(data["info"]);
  var items = <LiveRankItem>[
    for (var e in [..._list(data["top3"]), ..._list(data["list"])])
      ?_guardItem(e),
  ];
  return (
    list: LiveRankList("guard", items, total: _int(info["num"])),
    pages: _int(info["page"]) ?? 1,
  );
}

/// 粉丝团（getFansMembersRank）的一页
LiveRankList parseBiliFansRank(dynamic result) {
  _check(result);
  var data = _map(_map(result)["data"]);
  var items = <LiveRankItem>[];
  for (var e in _list(data["item"])) {
    var item = _map(e);
    var name = _str(item["name"]);
    if (name.isEmpty) {
      continue;
    }
    var medal = item["uinfo_medal"] ?? item;
    items.add(
      LiveRankItem(
        rank: _int(item["user_rank"]) ?? items.length + 1,
        userName: name,
        userId: liveUserId(item["uid"]),
        face: liveEmoteUrl(item["face"]),
        score: _int(item["score"]),
        badges: [?_guardBadge(item["guard_level"]), ?_medalBadge(medal)],
      ),
    );
  }
  return LiveRankList("fans", items, total: _int(data["num"]));
}

/// 弹幕连接推送的高能榜前几名：ONLINE_RANK_V2（JSON）或 ONLINE_RANK_V3
/// （data.pb 是 base64 的 protobuf，字段号对着文档里的样例解出来：
/// 1 rank_type，3 list；list 里 1 uid、2 face、3 score、4 uname、5 rank、6 guard_level）。
/// 不是这两种消息或解析不了时返回 null
LiveRankUpdate? parseBiliOnlineRankPush(dynamic obj) {
  var cmd = _str(_map(obj)["cmd"]);
  var data = _map(_map(obj)["data"]);
  List<Map> list;
  if (cmd == "ONLINE_RANK_V2") {
    list = [for (var e in _list(data["list"])) _map(e)];
  } else if (cmd == "ONLINE_RANK_V3") {
    var pb = _str(data["pb"]);
    if (pb.isEmpty) return null;
    list = _decodeOnlineRankV3(base64.decode(pb));
  } else {
    return null;
  }
  var items = <LiveRankItem>[];
  for (var item in list) {
    var name = _str(item["uname"]);
    if (name.isEmpty) continue;
    items.add(
      LiveRankItem(
        rank: _int(item["rank"]) ?? items.length + 1,
        userName: name,
        userId: liveUserId(item["uid"]),
        face: liveEmoteUrl(item["face"]),
        score: _int(item["score"]),
        badges: [?_guardBadge(item["guard_level"])],
      ),
    );
  }
  return items.isEmpty ? null : LiveRankUpdate("online", items);
}

/// ONLINE_RANK_V3 的 protobuf 解成和 V2 一样的 Map 列表
List<Map> _decodeOnlineRankV3(List<int> bytes) {
  var list = <Map>[];
  var reader = CodedBufferReader(bytes);
  while (!reader.isAtEnd()) {
    var tag = reader.readTag();
    if (tag == 0) break;
    if (tag >> 3 == 3 && tag & 7 == 2) {
      list.add(_decodeOnlineRankV3Item(reader.readBytes()));
    } else {
      reader.skipField(tag);
    }
  }
  return list;
}

Map _decodeOnlineRankV3Item(List<int> bytes) {
  var item = <String, dynamic>{};
  var reader = CodedBufferReader(bytes);
  while (!reader.isAtEnd()) {
    var tag = reader.readTag();
    if (tag == 0) break;
    var field = tag >> 3;
    var wire = tag & 7;
    if (wire == 0 && (field == 1 || field == 5 || field == 6)) {
      var value = reader.readInt64().toInt();
      item[switch (field) {
            1 => "uid",
            5 => "rank",
            _ => "guard_level",
          }] =
          value;
    } else if (wire == 2 && field >= 2 && field <= 4) {
      item[switch (field) {
        2 => "face",
        3 => "score",
        _ => "uname",
      }] = reader
          .readString();
    } else {
      reader.skipField(tag);
    }
  }
  return item;
}

/// 哔哩哔哩直播间的榜单（[LiveRankSite]）
mixin BiliBiliRank implements LiveRankSite {
  Future<Map<String, String>> getHeader();
  Future<Map<String, dynamic>> getRoomInfo({required String roomId});

  @override
  List<LiveRankBoard> get rankBoards => kBiliRankBoards;

  /// 真实房间号和主播的 uid：进直播间时已经存在弹幕参数里，没有时再读一次房间信息
  Future<(String, String)> _rankIds(LiveRoomDetail detail) async {
    var args = detail.danmakuData;
    if (args is BiliBiliDanmakuArgs && args.anchorUid > 0 && args.roomId > 0) {
      return (args.roomId.toString(), args.anchorUid.toString());
    }
    var info = await getRoomInfo(roomId: detail.roomId);
    var room = _map(info["room_info"]);
    var uid = _str(room["uid"]);
    if (uid.isEmpty || uid == "0") {
      throw CoreError("没有读取到主播的 UID".t);
    }
    var roomId = _str(room["room_id"]);
    return (roomId.isEmpty ? detail.roomId : roomId, uid);
  }

  @override
  Future<LiveRankList> getRank(
    String boardId, {
    required LiveRoomDetail detail,
  }) async {
    var (roomId, ruid) = await _rankIds(detail);
    var header = await getHeader();
    Future<dynamic> get(String url, Map<String, dynamic> query) => HttpClient
        .instance
        .getJson(url, queryParameters: query, header: header);
    var items = <LiveRankItem>[];
    int? total;
    switch (boardId) {
      case "online":
        for (var page = 1; items.length < kBiliOnlineRankMax; page++) {
          var list = parseBiliOnlineRank(
            await get(
              "https://api.live.bilibili.com/xlive/general-interface/v1/rank/getOnlineGoldRank",
              {"roomId": roomId, "ruid": ruid, "page": page, "pageSize": 50},
            ),
          );
          total ??= list.total;
          items.addAll(list.items);
          if (list.items.length < 50) break;
        }
        break;
      case "guard":
        for (var page = 1; items.length < kBiliMemberRankMax; page++) {
          var result = parseBiliGuardRank(
            await get(
              "https://api.live.bilibili.com/xlive/app-room/v2/guardTab/topListNew",
              {"roomid": roomId, "ruid": ruid, "page": page, "page_size": 30},
            ),
          );
          total ??= result.list.total;
          items.addAll(result.list.items);
          if (result.list.items.isEmpty || page >= result.pages) break;
        }
        break;
      case "fans":
        for (var page = 1; items.length < kBiliMemberRankMax; page++) {
          var list = parseBiliFansRank(
            await get(
              "https://api.live.bilibili.com/xlive/general-interface/v1/rank/getFansMembersRank",
              {"ruid": ruid, "page": page, "page_size": 30, "rank_type": 1},
            ),
          );
          total ??= list.total;
          items.addAll(list.items);
          if (list.items.length < 30) break;
        }
        break;
      default:
        throw CoreError("不支持这个榜单".t);
    }
    // 分页之间名单在变，同一个人可能出现两次：留前面的那次（神秘人没有 uid，都留着）
    var seen = <String>{};
    var unique = [
      for (var item in items)
        if (item.userId == null || seen.add(item.userId!)) item,
    ];
    var limit = boardId == "online" ? kBiliOnlineRankMax : kBiliMemberRankMax;
    return LiveRankList(boardId, unique.take(limit).toList(), total: total);
  }
}
