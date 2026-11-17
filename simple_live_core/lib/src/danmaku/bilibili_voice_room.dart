import 'package:simple_live_core/src/model/live_voice_room.dart';

/// 哔哩哔哩的语聊房（分区“聊天室”，多人语音）。
///
/// 这类直播间的视频是服务器合成的低清画面，官方 App 用下面的数据自己画房主和麦位。
/// 2026-11-13 在一个真的聊天室里看到的（匿名）：
///
/// - 房间信息（getInfoByRoom 的 data）里的 `multi_voice`：
///   `{"switch_status": 1, "members": [{"uid", "nickname", "avatar", "role", "pos",
///   "is_mute", "price_text", "group_id", ...}], "pk": {"group": [{"group_id",
///   "price_text"}]}, ...}`。`pos` 0 是房主（`role` 2），1–8 是嘉宾麦；
///   空着的麦位不在 `members` 里。`room_info.voice_background` 是背景图。
/// - 弹幕连接里的 `UNIVERSAL_ASR_TEXT`：有人说话时的语音转文字，
///   `{"data": {"uid", "uname", "sentences": [{"text", ...}]}}`。
///
/// 麦位变化在 75 秒里没有看到单独的推送，所以 App 隔一会儿重新读一次房间信息
class BiliVoiceRoom {
  /// 嘉宾麦的数量（官方是 2 排、每排 4 个）
  static const int guestSeats = 8;

  /// 房间信息里的语聊房数据；不是语聊房、或者语聊房没开时返回 null
  static LiveVoiceRoom? fromRoomInfo(dynamic roomInfo) {
    if (roomInfo is! Map) return null;
    var voice = roomInfo["multi_voice"];
    if (voice is! Map || voice["switch_status"] != 1) return null;
    var members = voice["members"];
    if (members is! List || members.isEmpty) return null;
    var seats = <LiveVoiceSeat>[];
    for (var m in members) {
      if (m is! Map) continue;
      var pos = m["pos"];
      var uid = m["uid"];
      if (pos is! num || uid == null) continue;
      var role = m["role"];
      seats.add(
        LiveVoiceSeat(
          position: pos.toInt(),
          uid: uid.toString(),
          name: (m["nickname"] ?? "").toString(),
          avatar: (m["avatar"] ?? "").toString(),
          host: role == 2 || pos == 0,
          muted: m["is_mute"] == 1 || m["is_mute"] == true,
          score: (m["price_text"] ?? "").toString(),
          team: (m["group_id"] ?? "").toString(),
        ),
      );
    }
    if (seats.isEmpty) return null;
    seats.sort((a, b) => a.position.compareTo(b.position));
    var teams = <LiveVoiceTeam>[];
    var pk = voice["pk"];
    if (pk is Map && pk["group"] is List) {
      for (var g in pk["group"] as List) {
        if (g is Map && g["group_id"] != null) {
          teams.add(
            LiveVoiceTeam(
              g["group_id"].toString(),
              (g["price_text"] ?? "").toString(),
            ),
          );
        }
      }
    }
    var room = roomInfo["room_info"];
    var background = room is Map ? (room["voice_background"] ?? "").toString() : "";
    var guests = seats.map((e) => e.position).fold(guestSeats, (a, b) => a > b ? a : b);
    return LiveVoiceRoom(
      seats: seats,
      guestSeats: guests,
      background: background.startsWith("http://")
          ? "https://${background.substring(7)}"
          : background,
      teams: teams,
    );
  }

  static bool handles(String cmd) => cmd == "UNIVERSAL_ASR_TEXT";

  /// 弹幕连接里的一条语音转文字；没有文字时返回 null
  static LiveVoiceCaption? captionOf(dynamic message) {
    if (message is! Map) return null;
    var data = message["data"];
    if (data is! Map) return null;
    var sentences = data["sentences"];
    if (sentences is! List) return null;
    var text = sentences
        .whereType<Map>()
        .map((e) => (e["text"] ?? "").toString().trim())
        .where((e) => e.isNotEmpty)
        .join(" ");
    if (text.isEmpty) return null;
    return LiveVoiceCaption(
      uid: (data["uid"] ?? "").toString(),
      name: (data["uname"] ?? "").toString(),
      text: text,
    );
  }
}
