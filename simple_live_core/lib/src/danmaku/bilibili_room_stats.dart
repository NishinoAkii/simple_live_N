import 'package:simple_live_core/src/model/live_message.dart';

/// 哔哩哔哩直播间的房间观众数、“xx 人看过”和点赞数。
///
/// 弹幕长连接里随直播推送：
/// - ONLINE_RANK_COUNT（房间观众数，应用右上角头像旁的数）：
///   `{"data":{"count":996,"count_text":"996","online_count":996,"online_count_text":"996"}}`
///   早先只有 count（高能用户数），有 online_count 时用 online_count
/// - WATCHED_CHANGE：
///   `{"data":{"num":198183,"text_small":"19.8万","text_large":"19.8万人看过"}}`
/// - LIKE_INFO_V3_UPDATE：`{"data":{"click_count":16213}}`
///
/// 进直播间时的初值在房间信息（getInfoByRoom 的 data）里，观众数没有：
/// - `watched_show`：`{"switch":true,"num":198183,...}`
/// - `like_info_v3`：`{"total_likes":16213,"count_block":false,...}`
class BiliRoomStats {
  static bool handles(String cmd) =>
      cmd == "ONLINE_RANK_COUNT" ||
      cmd == "WATCHED_CHANGE" ||
      cmd == "LIKE_INFO_V3_UPDATE";

  /// 长连接的一条消息；不是这几种或没带数字时返回 null
  static LiveRoomStats? fromMessage(dynamic message) {
    if (message is! Map) return null;
    var data = message["data"];
    if (data is! Map) return null;
    var stats = switch (message["cmd"]) {
      "ONLINE_RANK_COUNT" => LiveRoomStats(
        viewers:
            LiveRoomStats.count(data["online_count"]) ??
            LiveRoomStats.count(data["count"]),
      ),
      "WATCHED_CHANGE" => LiveRoomStats(
        watched: LiveRoomStats.count(data["num"]),
      ),
      "LIKE_INFO_V3_UPDATE" => LiveRoomStats(
        likes: LiveRoomStats.count(data["click_count"]),
      ),
      _ => LiveRoomStats.none,
    };
    return stats.isEmpty ? null : stats;
  }

  /// 房间信息里的初值；主播关掉显示（switch、count_block）的那项不取，
  /// 两项都没有时返回 null
  static LiveRoomStats? fromRoomInfo(dynamic roomInfo) {
    if (roomInfo is! Map) return null;
    int? watched;
    var show = roomInfo["watched_show"];
    if (show is Map && show["switch"] != false) {
      watched = LiveRoomStats.count(show["num"]);
    }
    int? likes;
    var like = roomInfo["like_info_v3"];
    if (like is Map && like["count_block"] != true) {
      likes = LiveRoomStats.count(like["total_likes"]);
    }
    var stats = LiveRoomStats(watched: watched, likes: likes);
    return stats.isEmpty ? null : stats;
  }
}
