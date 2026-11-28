import 'dart:convert';

import 'package:simple_live_core/src/danmaku/bilibili_danmaku.dart';
import 'package:simple_live_core/src/model/live_message.dart';

/// 哔哩哔哩进直播间时的最近聊天（xlive/web-room/v1/dM/gethistory 的返回，
/// 网页进直播间时显示的那些）→ 历史消息，旧的在前。
///
/// 房管的（admin）和观众的（room）各十来条，合在一起按发送时间（check_info.ts）排，
/// 同一条（id_str）只留一次。每条的字段和 DANMU_MSG 的 info 对得上，拼成 info 交给
/// [BiliBiliDanmaku.parseBiliDanmuMsg]，身份、表情都按实时弹幕的规则认。
/// 历史里没有弹幕颜色，都是白色；可能有几天前的（直播间没开播时）。
/// 格式不对、code 不是 0 时返回空的
List<LiveMessage> parseBiliChatHistory(dynamic json) {
  if (json is! Map || "${json["code"]}" != "0") {
    return const [];
  }
  var data = json["data"];
  if (data is! Map) {
    return const [];
  }
  var items = <(int, int, Map)>[];
  for (var key in const ["admin", "room"]) {
    var list = data[key];
    if (list is! List) {
      continue;
    }
    for (var item in list) {
      if (item is Map) {
        items.add((_sentAt(item), items.length, item));
      }
    }
  }
  items.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  var seen = <String>{};
  var messages = <LiveMessage>[];
  for (var (sentAt, _, item) in items) {
    var id = item["id_str"]?.toString() ?? "";
    var key = id.isNotEmpty ? id : "${item["uid"]}|$sentAt|${item["text"]}";
    if (!seen.add(key)) {
      continue;
    }
    var message = BiliBiliDanmaku.parseBiliDanmuMsg(_asDanmuMsg(item));
    if (message != null) {
      messages.add(message.asHistory());
    }
  }
  return messages;
}

/// 发送时间（秒）：check_info.ts，没有时为 0（排在最前，顺序不变）
int _sentAt(Map item) {
  var check = item["check_info"];
  var ts = check is Map ? check["ts"] : null;
  return ts is num ? ts.toInt() : int.tryParse("${ts ?? ""}") ?? 0;
}

/// 一条历史 → DANMU_MSG 的样子（下标见 [BiliBiliDanmaku.parseBiliDanmuMsg]、
/// [BiliBiliDanmaku.parseBiliDanmuBadges]）
Map _asDanmuMsg(Map item) {
  var emoticon = item["emoticon"];
  // 不是大表情时 url 是空的，parseBiliDanmuMsg 不当大表情
  var sticker = emoticon is Map
      ? {
          "url": emoticon["url"],
          "width": emoticon["width"],
          "height": emoticon["height"],
        }
      : "{}";
  var extra = jsonEncode({
    if (item["id_str"] != null) "id_str": item["id_str"].toString(),
    if (item["emots"] is Map) "emots": item["emots"],
  });
  var user = item["user"];
  var meta = List<dynamic>.filled(16, 0);
  meta[13] = sticker;
  meta[15] = {"extra": extra, if (user is Map) "user": user};
  var base = user is Map ? user["base"] : null;
  var name = item["nickname"]?.toString() ?? "";
  if (name.isEmpty && base is Map) {
    name = base["name"]?.toString() ?? "";
  }
  var title = item["title"];
  var info = List<dynamic>.filled(17, 0);
  info[0] = meta;
  info[1] = item["text"]?.toString() ?? "";
  info[2] = [
    item["uid"] ?? 0,
    name,
    item["isadmin"] ?? 0,
    item["vip"] ?? 0,
    item["svip"] ?? 0,
  ];
  info[3] = item["medal"] is List ? item["medal"] : const [];
  info[4] = item["user_level"] is List ? item["user_level"] : const [];
  info[5] = title is List ? title : const ["", ""];
  info[7] = item["guard_level"] ?? 0;
  info[16] = [item["wealth_level"] ?? 0];
  return {"cmd": "DANMU_MSG", "info": info};
}
