import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_text.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_rank.dart';

// 抖音、斗鱼、Kick 的榜单接口解析（哔哩哔哩的在 bilibili_rank.dart）。

int? _int(dynamic value) => switch (value) {
  num n => n.toInt(),
  String s => int.tryParse(s.trim()),
  _ => null,
};

String _str(dynamic value) =>
    value is String || value is num ? value.toString().trim() : "";

Map _map(dynamic value) => value is Map ? value : const {};

List _list(dynamic value) => value is List ? value : const [];

String _firstUrl(dynamic image) {
  for (var url in _list(_map(image)["url_list"])) {
    var value = liveEmoteUrl(url);
    if (value.startsWith("http")) {
      return value;
    }
  }
  return "";
}

// ---------------- 抖音 ----------------

const List<LiveRankBoard> kDouyinRankBoards = [
  LiveRankBoard(
    id: "online",
    title: "在线观众榜",
    shortTitle: "观众榜",
    scoreLabel: "贡献值",
    live: true,
  ),
];

/// 粉丝团的牌子图标：icons 里按 4、3、2、1、0 找第一张
String? _douyinClubIcon(dynamic icons) {
  var map = _map(icons);
  for (var key in const ["4", "3", "2", "1", "0"]) {
    var url = _firstUrl(map[key]);
    if (url.isNotEmpty) return url;
  }
  for (var value in map.values) {
    var url = _firstUrl(value);
    if (url.isNotEmpty) return url;
  }
  return null;
}

/// 抖音在线观众榜（webcast/ranklist/audience，rank_type=30）
LiveRankList parseDouyinAudienceRank(dynamic result) {
  var root = _map(result);
  var code = _int(root["status_code"]) ?? 0;
  if (code != 0) {
    var message = _str(_map(root["data"])["message"]);
    throw CoreError(
      message.isEmpty
          ? "读取榜单失败（{code}）".tf({"code": code})
          : "读取榜单失败：{message}".tf({"message": message}),
    );
  }
  var data = _map(root["data"]);
  var items = <LiveRankItem>[];
  var ranks = _list(data["ranks"]);
  for (var i = 0; i < ranks.length; i++) {
    var item = _map(ranks[i]);
    var user = _map(item["user"]);
    var name = _str(user["nickname"]);
    if (name.isEmpty) continue;
    // 有的回应里每一条的 rank 都是 1：这时按顺序排
    var rank = _int(item["rank"]) ?? 0;
    if (rank <= 0 || (rank == 1 && i > 0)) rank = i + 1;
    var grade = _map(user["pay_grade"]);
    var level = _int(grade["level"]) ?? 0;
    var club = _map(_map(user["fans_club"])["data"]);
    var clubLevel = _int(club["level"]) ?? 0;
    var clubName = _str(club["club_name"]);
    var description = _str(item["score_description"]);
    var exactly = _str(item["exactly_score"]);
    // 没登录时每个人的 score 都是 0（2026-11-15 读到的），这时不显示分数
    var score = _int(item["score"]);
    if (score != null && score <= 0) score = null;
    items.add(
      LiveRankItem(
        rank: rank,
        userName: name,
        userId: liveUserId(
          _str(user["id_str"]).isNotEmpty ? user["id_str"] : user["id"],
        ),
        face: _firstUrl(user["avatar_thumb"]),
        score: score ?? _int(exactly),
        scoreText: description.isNotEmpty
            ? description
            : (score == null && exactly.isNotEmpty ? exactly : null),
        badges: [
          if (clubLevel > 0)
            LiveBadge(
              LiveBadgeKind.medal,
              clubName.isEmpty ? "粉丝团" : clubName,
              level: clubLevel,
              icon: _douyinClubIcon(_map(club["badge"])["icons"]),
            ),
          if (level > 0)
            LiveBadge(
              LiveBadgeKind.level,
              "等级",
              level: level,
              icon: _firstUrl(grade["new_im_icon_with_level"]).isEmpty
                  ? null
                  : _firstUrl(grade["new_im_icon_with_level"]),
            ),
        ],
      ),
    );
  }
  return LiveRankList("online", items, total: _int(data["total"]));
}

// ---------------- 斗鱼 ----------------

const List<LiveRankBoard> kDouyuRankBoards = [
  LiveRankBoard(
    id: "intimacy",
    title: "亲密榜",
    scoreLabel: "亲密度",
    note: "斗鱼没有公开这个接口的文档，数据可能不全，也可能随时无法读取",
  ),
];

/// 斗鱼粉丝亲密榜（japi/interact/comm/fanshome/rank/top10）。
/// 2026-11-15 读到的回应里 intimacyRank 有 50 人，每人有 rank、uid、nickname、avatar、value
LiveRankList parseDouyuIntimacyRank(dynamic result) {
  var root = _map(result);
  var code = _int(root["error"]) ?? 0;
  if (code != 0) {
    var message = _str(root["msg"]);
    throw CoreError(
      message.isEmpty
          ? "读取榜单失败（{code}）".tf({"code": code})
          : "读取榜单失败：{message}".tf({"message": message}),
    );
  }
  var items = <LiveRankItem>[];
  for (var e in _list(_map(root["data"])["intimacyRank"])) {
    var item = _map(e);
    var name = _str(item["nickname"]);
    if (name.isEmpty) continue;
    items.add(
      LiveRankItem(
        rank: _int(item["rank"]) ?? items.length + 1,
        userName: name,
        userId: liveUserId(item["uid"]),
        face: liveEmoteUrl(item["avatar"]),
        score: _int(item["value"]),
      ),
    );
  }
  return LiveRankList("intimacy", items);
}

// ---------------- Kick ----------------

const List<LiveRankBoard> kKickRankBoards = [
  LiveRankBoard(
    id: "gifts",
    title: "送订阅榜",
    shortTitle: "订阅总榜",
    scoreLabel: "送出的订阅",
  ),
  LiveRankBoard(
    id: "gifts_month",
    title: "送订阅榜（本月）",
    shortTitle: "订阅月榜",
    scoreLabel: "送出的订阅",
  ),
  LiveRankBoard(
    id: "gifts_week",
    title: "送订阅榜（本周）",
    shortTitle: "订阅周榜",
    scoreLabel: "送出的订阅",
  ),
];

/// Kick 的送订阅榜（/api/v2/channels/{slug}/leaderboards）。一次回应里有三份：
/// gifts（全部）、gifts_month、gifts_week，每人有 user_id、username、quantity。
/// [boardId] 是其中一份的名字；主播关了这份榜单（*_enabled 为 false）时返回空的
LiveRankList parseKickLeaderboard(dynamic result, String boardId) {
  var root = _map(result);
  if (root[boardId] == null && root["${boardId}_enabled"] == null) {
    throw CoreError("读取榜单失败".t);
  }
  if (root["${boardId}_enabled"] == false) {
    return LiveRankList(boardId, const []);
  }
  var items = <LiveRankItem>[];
  for (var e in _list(root[boardId])) {
    var item = _map(e);
    var name = _str(item["username"]);
    if (name.isEmpty) continue;
    items.add(
      LiveRankItem(
        rank: items.length + 1,
        userName: name,
        userId: liveUserId(item["user_id"]),
        score: _int(item["quantity"]),
      ),
    );
  }
  return LiveRankList(boardId, items);
}
