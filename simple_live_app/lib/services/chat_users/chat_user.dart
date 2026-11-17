import 'dart:convert';

import 'package:archive/archive.dart' show getCrc32;
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 弹幕里的一个人：平台、用户 ID（有的话）和名字。
///
/// 备注、“只看这个人”按 [sameAs] 认人（规则见 [sameLiveUser]）：
/// 两边都有 ID 时只比 ID，改名也认得出；有一边没有 ID 时比名字，必须完全一致。
/// 屏蔽只按 ID 认人，见 [sameChatUserId]。
///
/// 哔哩哔哩有的记录只有 uid 的 crc32（[midHash]），没有 uid 和名字：
/// 一边只有 [midHash]、另一边有 uid 时，把 uid 算成 crc32 再比
class ChatUser {
  final String siteId;
  final String? userId;
  final String name;

  /// 哔哩哔哩：uid 的 crc32（十六进制），只有这一项时 [userId] 为空
  final String? midHash;

  const ChatUser(this.siteId, {this.userId, required this.name, this.midHash});

  /// 一条直播弹幕的发言人；SC、礼物的送出人见 [ofSuperChat]、[ofGift]
  factory ChatUser.ofMessage(String siteId, LiveMessage message) {
    var data = message.data;
    if (data is LiveSuperChatMessage) {
      return ChatUser.ofSuperChat(siteId, data, fallbackId: message.userId);
    }
    if (data is LiveGiftMessage) {
      return ChatUser.ofGift(siteId, data);
    }
    return ChatUser(siteId, userId: message.userId, name: message.userName);
  }

  factory ChatUser.ofSuperChat(
    String siteId,
    LiveSuperChatMessage sc, {
    String? fallbackId,
  }) =>
      ChatUser(siteId, userId: sc.userId ?? fallbackId, name: sc.userName);

  factory ChatUser.ofGift(String siteId, LiveGiftMessage gift) =>
      ChatUser(siteId, userId: gift.userId, name: gift.userName);

  /// 有能认人的信息（名字、ID 或 crc32）
  bool get isKnown =>
      name.isNotEmpty || userId != null || (midHash?.isNotEmpty ?? false);

  /// 有用户 ID（或哔哩哔哩的 crc32），可以屏蔽
  bool get hasId => userId != null || (midHash?.isNotEmpty ?? false);

  /// 哔哩哔哩：按 uid 算出的 crc32，别的平台为 null
  String? get hashKey {
    if (midHash != null) {
      return midHash;
    }
    if (siteId != Constant.kBiliBili || userId == null) {
      return null;
    }
    return getCrc32(utf8.encode(userId!.trim())).toRadixString(16);
  }

  bool sameAs(ChatUser other) {
    if (siteId != other.siteId) {
      return false;
    }
    if (userId != null && other.userId != null) {
      return userId == other.userId;
    }
    if (midHash != null || other.midHash != null) {
      var a = hashKey;
      var b = other.hashKey;
      if (a != null && b != null) {
        return a == b;
      }
    }
    return sameLiveUser(userId, name, other.userId, other.name);
  }

  @override
  String toString() => "ChatUser($siteId, $userId, $name"
      "${midHash == null ? "" : ", $midHash"})";
}

/// 屏蔽用的认人规则：只比用户 ID；哔哩哔哩只有 uid 的 crc32 时按 crc32 比。
/// 不比名字：同名的人、哔哩哔哩没登录时打码的名字（比如“用***”）都不会被误屏蔽
bool sameChatUserId(ChatUser a, ChatUser b) {
  if (a.siteId != b.siteId) {
    return false;
  }
  if (a.userId != null && b.userId != null) {
    return a.userId == b.userId;
  }
  var x = a.hashKey;
  var y = b.hashKey;
  return x != null && y != null && x == y;
}

/// 名单、提示里显示的名字：名字；没有名字时是 ID；
/// 哔哩哔哩只有 crc32 的写成 crc32
String chatUserLabel(String name, {String? userId, String? midHash}) {
  if (name.isNotEmpty) {
    return name;
  }
  if (userId != null) {
    return userId;
  }
  return midHash ?? "";
}

/// 剩下的时间写成“25 分钟”“3 小时 5 分钟”“2 天 4 小时”（不到一分钟算一分钟）
String chatUserRemainingText(Duration left) {
  var minutes = (left.inSeconds + 59) ~/ 60;
  if (minutes < 1) {
    minutes = 1;
  }
  if (minutes < 60) {
    return "{n} 分钟".tf({"n": minutes});
  }
  var hours = minutes ~/ 60;
  var rest = minutes % 60;
  if (hours < 48) {
    return rest == 0
        ? "{n} 小时".tf({"n": hours})
        : "{h} 小时 {m} 分钟".tf({"h": hours, "m": rest});
  }
  var days = hours ~/ 24;
  var restHours = hours % 24;
  return restHours == 0
      ? "{n} 天".tf({"n": days})
      : "{d} 天 {h} 小时".tf({"d": days, "h": restHours});
}
