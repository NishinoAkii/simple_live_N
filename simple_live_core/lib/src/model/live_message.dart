import 'dart:convert';

import 'package:simple_live_core/src/model/live_voice_room.dart';
import 'package:simple_live_core/src/common/core_text.dart';

enum LiveMessageType {
  /// 聊天
  chat,

  /// 礼物，data 为 [LiveGiftMessage]
  gift,

  /// 在线人数
  online,

  /// 醒目留言
  superChat,

  /// 连麦状态有变化，data 为 [LiveLinkMicState]（每次都是完整的一份）
  linkMic,

  /// 在线人数、贵宾数、多少人看过、点赞数有变化，data 为 [LiveRoomStats]
  /// （只带变了的那几项）
  stats,

  /// 语聊房的麦位变了，data 为 [LiveVoiceRoom]（整份新的）
  voiceRoom,

  /// 语聊房里有人在说话（语音转文字），data 为 [LiveVoiceCaption]
  voiceCaption,

  /// 榜单前几名有变化（哔哩哔哩的高能榜、抖音的在线观众前三），
  /// data 为 [LiveRankUpdate]
  rank,
}

/// 直播间随直播更新的几个数：在线人数、贵宾数、多少人看过、多少点赞。
/// 平台没给的那项为 null。热度（人气）不在这里，走 [LiveMessageType.online]
class LiveRoomStats {
  /// 在线人数：平台自己的应用在直播间右上角显示的那个数
  /// （斗鱼的在线人数、哔哩哔哩的房间观众数）
  final int? viewers;

  /// 贵宾数（斗鱼、虎牙的贵宾席人数）
  final int? nobles;

  /// 看过的人数（哔哩哔哩的“xx 人看过”、抖音的累计观看）
  final int? watched;

  /// 点赞数
  final int? likes;

  const LiveRoomStats({this.viewers, this.nobles, this.watched, this.likes});

  static const LiveRoomStats none = LiveRoomStats();

  bool get isEmpty =>
      viewers == null && nobles == null && watched == null && likes == null;

  /// 用新收到的那几项盖掉原来的，新的没带的保持不变
  LiveRoomStats merge(LiveRoomStats? newer) => newer == null
      ? this
      : LiveRoomStats(
          viewers: newer.viewers ?? viewers,
          nobles: newer.nobles ?? nobles,
          watched: newer.watched ?? watched,
          likes: newer.likes ?? likes,
        );

  /// 平台给的数字：整数、小数、数字字符串都认；其余（包括负数）算没给
  static int? count(dynamic value) {
    var number = switch (value) {
      num n => n.toInt(),
      String s => int.tryParse(s.trim()),
      _ => null,
    };
    return number == null || number < 0 ? null : number;
  }

  /// 发给直播间的一条消息（不进聊天区）
  LiveMessage toMessage() => LiveMessage(
    type: LiveMessageType.stats,
    userName: "",
    message: "",
    color: LiveMessageColor.white,
    data: this,
  );

  @override
  bool operator ==(Object other) =>
      other is LiveRoomStats &&
      other.viewers == viewers &&
      other.nobles == nobles &&
      other.watched == watched &&
      other.likes == likes;

  @override
  int get hashCode => Object.hash(viewers, nobles, watched, likes);

  @override
  String toString() =>
      "LiveRoomStats(viewers: $viewers, nobles: $nobles, watched: $watched, "
      "likes: $likes)";
}

/// 连麦中（或排队等着连麦）的一个人：别的主播或观众
class LiveLinkMicUser {
  final String name;

  /// 头像，没有时为空
  final String face;

  /// 对方是主播时的直播间号，没有时为空
  final String roomId;

  const LiveLinkMicUser({required this.name, this.face = "", this.roomId = ""});

  Map<String, dynamic> toJson() => {
    "name": name,
    if (face.isNotEmpty) "face": face,
    if (roomId.isNotEmpty) "roomId": roomId,
  };

  static LiveLinkMicUser? fromJson(dynamic json) {
    if (json is! Map || json["name"] == null) return null;
    return LiveLinkMicUser(
      name: json["name"].toString(),
      face: json["face"]?.toString() ?? "",
      roomId: json["roomId"]?.toString() ?? "",
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LiveLinkMicUser &&
      other.name == name &&
      other.face == face &&
      other.roomId == roomId;

  @override
  int get hashCode => Object.hash(name, face, roomId);

  @override
  String toString() =>
      "LiveLinkMicUser($name${roomId.isEmpty ? "" : ", $roomId"})";
}

/// 直播间的连麦状态。平台每次推送都整理成完整的一份，
/// 没有在连麦时 [linked] 为空
class LiveLinkMicState {
  /// 连麦的方式，如“连麦”“PK”“多人连线”“语音连麦”“视频连线”“共享聊天”
  final String kind;

  /// 正在连麦的人（不含本直播间的主播）
  final List<LiveLinkMicUser> linked;

  /// 排队等着连麦的人；平台只给人数时为空，人数见 [waiting]
  final List<LiveLinkMicUser> queue;

  /// 平台给的排队人数（只给名单时为 0）
  final int queueCount;

  const LiveLinkMicState({
    this.kind = "连麦",
    this.linked = const [],
    this.queue = const [],
    this.queueCount = 0,
  });

  static const LiveLinkMicState none = LiveLinkMicState();

  /// 正在连麦
  bool get active => linked.isNotEmpty;

  /// 排队人数（名单和平台给的人数取大的）
  int get waiting => queueCount > queue.length ? queueCount : queue.length;

  /// 一句话说明，如“连麦：甲、乙”
  String get summary =>
      active
      ? "${kind.t}：${linked.map((e) => e.name).join("、".t)}"
      : "连麦结束".t;

  /// 发给直播间的一条消息（不进聊天区）
  LiveMessage toMessage() => LiveMessage(
    type: LiveMessageType.linkMic,
    userName: "",
    message: summary,
    color: LiveMessageColor.white,
    data: this,
  );

  Map<String, dynamic> toJson() => {
    "kind": kind,
    "linked": linked.map((e) => e.toJson()).toList(),
    if (queue.isNotEmpty) "queue": queue.map((e) => e.toJson()).toList(),
    if (queueCount > 0) "queueCount": queueCount,
  };

  static LiveLinkMicState fromJson(dynamic json) {
    if (json is! Map) return none;
    List<LiveLinkMicUser> users(dynamic list) => list is List
        ? [
            for (var e in list)
              if (LiveLinkMicUser.fromJson(e) case var u?) u,
          ]
        : const [];
    return LiveLinkMicState(
      kind: json["kind"]?.toString() ?? "连麦",
      linked: users(json["linked"]),
      queue: users(json["queue"]),
      queueCount: json["queueCount"] is num
          ? (json["queueCount"] as num).toInt()
          : 0,
    );
  }

  static bool _same(List<LiveLinkMicUser> a, List<LiveLinkMicUser> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is LiveLinkMicState &&
      other.kind == kind &&
      other.queueCount == queueCount &&
      _same(other.linked, linked) &&
      _same(other.queue, queue);

  @override
  int get hashCode => Object.hash(
    kind,
    queueCount,
    Object.hashAll(linked),
    Object.hashAll(queue),
  );

  @override
  String toString() =>
      "LiveLinkMicState($kind, linked: $linked, "
      "queue: ${queue.length}/$waiting)";
}

class LiveMessage {
  /// 消息类型
  final LiveMessageType type;

  /// 用户名
  final String userName;

  /// 信息
  final String message;

  /// 数据
  /// 单Type=Online时，Data为人气值(long)
  final dynamic data;

  /// 弹幕颜色
  final LiveMessageColor color;

  /// 发送者头像（部分平台提供，如 YouTube），没有时为空
  final String? face;

  /// 消息里的表情图片：[message] 中出现的 [LiveEmote.text] 可以显示为图片。
  /// 平台没有给出图片时为空，[message] 照常是纯文字
  final List<LiveEmote>? emotes;

  /// 整条消息是一张大表情（如哔哩哔哩的表情包弹幕）时的图片，
  /// [message] 是它的文字说明
  final LiveEmote? sticker;

  /// 历史消息：进直播间（或重连）时平台补发的之前的聊天。
  /// 只显示在聊天区，不上视频弹幕（不然会一起飞过视频）
  final bool history;

  /// 发言人的身份：粉丝牌、舰长/贵族、房管、订阅、会员、等级等，
  /// 按平台给出的顺序；平台没给或解析不了时为空
  final List<LiveBadge>? badges;

  /// 发言人名字的颜色（Twitch、Kick 每个用户自己选的颜色）；平台没有时为空。
  /// 这两个平台的 [color] 也是这个颜色（原来就这样，弹幕跟着用）
  final LiveMessageColor? nameColor;

  /// 发言人在这个平台上的用户 ID（所有直播间都一样，改名也不变）；
  /// 平台没给（如哔哩哔哩没登录时是 0）时为 null，见 [liveUserId]
  final String? userId;
  LiveMessage({
    required this.type,
    required this.userName,
    required this.message,
    this.data,
    required this.color,
    this.face,
    this.emotes,
    this.sticker,
    this.history = false,
    this.badges,
    this.nameColor,
    this.userId,
  });

  /// 同一条消息标成历史消息（只进聊天区，不上视频弹幕）
  LiveMessage asHistory() => LiveMessage(
    type: type,
    userName: userName,
    message: message,
    data: data,
    color: color,
    face: face,
    emotes: emotes,
    sticker: sticker,
    history: true,
    badges: badges,
    nameColor: nameColor,
    userId: userId,
  );

  /// 有可以显示为图片的表情
  bool get hasEmotes => sticker != null || (emotes?.isNotEmpty ?? false);

  @override
  String toString() {
    return json.encode({
      "type": type.index,
      "userName": userName,
      "message": message,
      "data": data.toString(),
      "color": color.toString(),
      "face": face,
      if (emotes != null) "emotes": emotes!.map((e) => e.toJson()).toList(),
      if (sticker != null) "sticker": sticker!.toJson(),
      if (history) "history": true,
      if (badges != null) "badges": badges!.map((e) => e.toJson()).toList(),
      if (nameColor != null) "nameColor": nameColor.toString(),
      if (userId != null) "userId": userId,
    });
  }
}

/// 平台给的用户 ID 统一成字符串：数字、数字字符串都认；
/// 没给、空的、0（哔哩哔哩没登录时、抖音有时是 0）算没有，返回 null
String? liveUserId(dynamic value) {
  var text = switch (value) {
    null => "",
    num n => n == n.truncate() ? n.toInt().toString() : n.toString(),
    _ => value.toString().trim(),
  };
  return text.isEmpty || text == "0" ? null : text;
}

/// 平台给的数字 ID（粉丝牌主人的房间号、uid）统一成字符串：正整数、写成字符串的正整数都认；
/// 没给、空的、0、不是数字的算没有，返回 null
String? liveNumericId(dynamic value) {
  var id = switch (value) {
    int n => n,
    String s => int.tryParse(s.trim(), radix: 10),
    _ => null,
  };
  return id == null || id <= 0 ? null : "$id";
}

/// 同一个平台上两个人是不是同一个人（屏蔽、备注、只看这个人、重复弹幕过滤共用）：
/// 两边都有用户 ID 时只比 ID，改名也认得出；有一边没有时比用户名，必须完全一致。
/// 比较前由调用方确认是同一个平台
bool sameLiveUser(String? idA, String nameA, String? idB, String nameB) {
  if (idA != null && idA.isNotEmpty && idB != null && idB.isNotEmpty) {
    return idA == idB;
  }
  return nameA.isNotEmpty && nameA == nameB;
}

/// 发言人身份的种类
enum LiveBadgeKind {
  /// 粉丝牌（直播间的牌子），[LiveBadge.text] 为牌子名，[LiveBadge.level] 为等级
  medal,

  /// 舰长、提督、总督等大航海身份
  guard,

  /// 贵族（斗鱼、虎牙等）
  noble,

  /// 房管
  admin,

  /// 主播本人
  broadcaster,

  /// 订阅（Twitch、Kick），[LiveBadge.level] 为订阅月数
  subscriber,

  /// VIP、钻粉等平台特权
  vip,

  /// 频道会员（YouTube），[LiveBadge.level] 为月数
  member,

  /// 用户等级、财富等级
  level,

  /// 头衔、称号等其他标识
  title,
}

/// 发言人的一个身份标识
class LiveBadge {
  final LiveBadgeKind kind;

  /// 显示的文字：牌子名、“舰长”、“房管”、“订阅”、头衔名等
  final String text;

  /// 等级或月数，没有为 null
  final int? level;

  /// 平台给的图标地址，没有为 null
  final String? icon;

  /// 平台给的颜色 0xRRGGBB，没有为 null
  final int? color;

  /// 粉丝牌是哪个主播的：主播名、房间号、uid，平台没给（空的、0）的为 null。
  /// 哔哩哔哩、斗鱼、虎牙可以戴别的直播间的牌子，消息里带着；别的平台、别的身份都是 null
  final String? ownerName;
  final String? ownerRoomId;
  final String? ownerUid;

  const LiveBadge(
    this.kind,
    this.text, {
    this.level,
    this.icon,
    this.color,
    this.ownerName,
    this.ownerRoomId,
    this.ownerUid,
  });

  /// 知道是哪个主播的牌子
  bool get hasOwner =>
      ownerName != null || ownerRoomId != null || ownerUid != null;

  Map<String, dynamic> toJson() => {
    "k": kind.name,
    "t": text,
    if (level != null) "l": level,
    if (icon != null) "i": icon,
    if (color != null) "c": color,
    if (ownerName != null) "n": ownerName,
    if (ownerRoomId != null) "r": ownerRoomId,
    if (ownerUid != null) "u": ownerUid,
  };

  static LiveBadge? fromJson(dynamic json) {
    if (json is! Map) return null;
    var kind = LiveBadgeKind.values.where((e) => e.name == json["k"]);
    if (kind.isEmpty) return null;
    return LiveBadge(
      kind.first,
      json["t"]?.toString() ?? "",
      level: json["l"] is num ? (json["l"] as num).toInt() : null,
      icon: json["i"]?.toString(),
      color: json["c"] is num ? (json["c"] as num).toInt() : null,
      ownerName: _ownerText(json["n"]),
      ownerRoomId: _ownerText(json["r"]),
      ownerUid: _ownerText(json["u"]),
    );
  }

  /// 文字或数字，空的、别的类型都算没有
  static String? _ownerText(dynamic value) {
    var text = value is String || value is num ? "$value".trim() : "";
    return text.isEmpty ? null : text;
  }

  @override
  bool operator ==(Object other) =>
      other is LiveBadge &&
      other.kind == kind &&
      other.text == text &&
      other.level == level &&
      other.icon == icon &&
      other.color == color &&
      other.ownerName == ownerName &&
      other.ownerRoomId == ownerRoomId &&
      other.ownerUid == ownerUid;

  @override
  int get hashCode => Object.hash(
    kind,
    text,
    level,
    icon,
    color,
    ownerName,
    ownerRoomId,
    ownerUid,
  );

  @override
  String toString() =>
      "LiveBadge(${kind.name}, $text"
      "${level == null ? "" : ", $level"}"
      "${hasOwner ? ", owner: $ownerName/$ownerRoomId/$ownerUid" : ""})";
}

/// 消息中的一个表情图片
class LiveEmote {
  /// 消息文字里代表这个表情的文字，如“[doge]”“:_lucubPat:”“Kappa”；
  /// 大表情时是消息本身
  final String text;

  /// 图片地址（动图时是动图，聊天栏里会动）
  final String url;

  /// 动图的静态版本（第一帧），视频弹幕只画一帧时用它；为空时和 [url] 一样。
  /// 有的动图第一帧是空白的，平台有静态图时最好给出
  final String? staticUrl;

  /// 图片的宽高（平台给出时，否则为 0），用于图片加载出来之前占位
  final int width;
  final int height;

  /// 只在前后是空白（或消息的开头、结尾）时才算表情。
  /// Twitch 的第三方表情（7TV、BTTV、FFZ）是按空格分开的整个词，
  /// 名字里可能有标点（“???”“D:”），“what???”里的“???”不算
  final bool spaced;

  /// 图片的缓存键：地址每次都变（如抖音带签名的地址）但图片不变时，
  /// 按它缓存，不用每次重新下载；为空时按地址缓存
  final String? cacheKey;

  const LiveEmote({
    required this.text,
    required this.url,
    this.staticUrl,
    this.width = 0,
    this.height = 0,
    this.spaced = false,
    this.cacheKey,
  });

  /// 宽高比，平台没有给出宽高时为 null
  double? get aspectRatio => width > 0 && height > 0 ? width / height : null;

  /// 新增的字段只在有值时输出，和旧版的格式兼容
  Map<String, dynamic> toJson() => {
    "text": text,
    "url": url,
    if (staticUrl != null) "staticUrl": staticUrl,
    if (width > 0) "width": width,
    if (height > 0) "height": height,
    if (spaced) "spaced": true,
    if (cacheKey != null) "cacheKey": cacheKey,
  };

  @override
  String toString() => json.encode(toJson());
}

/// 消息文字按表情切开后的一段：文字，或一个表情
class LiveMessagePart {
  final String text;

  /// 这一段是表情时为表情，否则为 null
  final LiveEmote? emote;
  const LiveMessagePart(this.text, [this.emote]);

  bool get isEmote => emote != null;
}

bool _isWordUnit(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f;

/// 空白，或看不见的字符（零宽空格、U+034F 等，聊天客户端用它们绕过重复消息检查）
bool isLiveEmoteSpace(int c) =>
    c <= 0x20 ||
    c == 0xa0 ||
    c == 0x034f ||
    (c >= 0x2000 && c <= 0x200d) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202f ||
    c == 0x205f ||
    c == 0x2060 ||
    c == 0x3000 ||
    c == 0xfeff;

/// [i] 之前是开头、空白或看不见的字符（含 U+E0000 这类标签字符）
bool _spaceBefore(String text, int i) {
  if (i <= 0) {
    return true;
  }
  var c = text.codeUnitAt(i - 1);
  if (c >= 0xdc00 && c <= 0xdfff && i >= 2) {
    // U+E0000～U+E007F 的低位代理
    return text.codeUnitAt(i - 2) == 0xdb40;
  }
  return isLiveEmoteSpace(c);
}

/// [end] 处是结尾、空白或看不见的字符
bool _spaceAfter(String text, int end) {
  if (end >= text.length) {
    return true;
  }
  var c = text.codeUnitAt(end);
  return c == 0xdb40 || isLiveEmoteSpace(c);
}

/// 把 [text] 按 [emotes] 切成文字和表情。
///
/// 表情按文字匹配，长的优先；“Kappa”这种由字母数字组成的表情名
/// 前后不能紧挨着字母数字（“KappaPride”里的“Kappa”不算），
/// “[doge]”“:_lucubPat:”这种带括号或冒号的不受限制；
/// [LiveEmote.spaced] 的表情前后必须是空白或开头结尾。
/// 没有表情时返回只有一段文字的列表。
List<LiveMessagePart> splitLiveEmotes(String text, List<LiveEmote>? emotes) {
  if (emotes == null || emotes.isEmpty || text.isEmpty) {
    return [LiveMessagePart(text)];
  }
  var byText = <String, LiveEmote>{};
  for (var emote in emotes) {
    if (emote.text.isNotEmpty && emote.url.isNotEmpty) {
      byText.putIfAbsent(emote.text, () => emote);
    }
  }
  if (byText.isEmpty) {
    return [LiveMessagePart(text)];
  }
  var codes = byText.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  var firstUnits = codes.map((e) => e.codeUnitAt(0)).toSet();
  var parts = <LiveMessagePart>[];
  var buffer = StringBuffer();
  var i = 0;
  while (i < text.length) {
    String? matched;
    if (firstUnits.contains(text.codeUnitAt(i))) {
      for (var code in codes) {
        if (!text.startsWith(code, i)) {
          continue;
        }
        var end = i + code.length;
        if (byText[code]!.spaced) {
          if (!_spaceBefore(text, i) || !_spaceAfter(text, end)) {
            continue;
          }
          matched = code;
          break;
        }
        if (_isWordUnit(code.codeUnitAt(0)) &&
            i > 0 &&
            _isWordUnit(text.codeUnitAt(i - 1))) {
          continue;
        }
        if (_isWordUnit(code.codeUnitAt(code.length - 1)) &&
            end < text.length &&
            _isWordUnit(text.codeUnitAt(end))) {
          continue;
        }
        matched = code;
        break;
      }
    }
    if (matched == null) {
      buffer.writeCharCode(text.codeUnitAt(i));
      i++;
      continue;
    }
    if (buffer.isNotEmpty) {
      parts.add(LiveMessagePart(buffer.toString()));
      buffer.clear();
    }
    parts.add(LiveMessagePart(matched, byText[matched]));
    i += matched.length;
  }
  if (buffer.isNotEmpty) {
    parts.add(LiveMessagePart(buffer.toString()));
  }
  return parts;
}

/// 平台给出的图片地址补全为 https（哔哩哔哩的表情地址是 http:// 或 //）
String liveEmoteUrl(dynamic url) {
  var value = url?.toString().trim() ?? "";
  if (value.startsWith("//")) {
    return "https:$value";
  }
  if (value.startsWith("http://")) {
    return "https://${value.substring(7)}";
  }
  return value;
}

class LiveMessageColor {
  final int r, g, b;
  LiveMessageColor(this.r, this.g, this.b);
  static LiveMessageColor get white => LiveMessageColor(255, 255, 255);
  static LiveMessageColor numberToColor(int intColor) {
    var obj = intColor.toRadixString(16);

    LiveMessageColor color = LiveMessageColor.white;
    if (obj.length == 4) {
      obj = "00$obj";
    }
    if (obj.length == 6) {
      var R = int.parse(obj.substring(0, 2), radix: 16);
      var G = int.parse(obj.substring(2, 4), radix: 16);
      var B = int.parse(obj.substring(4, 6), radix: 16);

      color = LiveMessageColor(R, G, B);
    }
    if (obj.length == 8) {
      var R = int.parse(obj.substring(2, 4), radix: 16);
      var G = int.parse(obj.substring(4, 6), radix: 16);
      var B = int.parse(obj.substring(6, 8), radix: 16);
      //var A = int.parse(obj.substring(0, 2), radix: 16);
      color = LiveMessageColor(R, G, B);
    }

    return color;
  }

  @override
  String toString() {
    return "#${r.toRadixString(16).padLeft(2, '0')}${g.toRadixString(16).padLeft(2, '0')}${b.toRadixString(16).padLeft(2, '0')}";
  }

  @override
  bool operator ==(Object other) =>
      other is LiveMessageColor && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);
}

/// 一次送礼（[LiveMessageType.gift] 消息的 data）。
///
/// 同一次连击平台会连着发好几条，[comboId] 相同的后一条代替前一条（数量更新），
/// 界面上只占一行、只飞一次。
class LiveGiftMessage {
  /// 连击的标识，同一次连击的几条消息相同；为空时每条单独算
  final String? comboId;

  /// 送礼的人
  final String userName;

  /// 送礼人的头像，没有时为空
  final String face;

  /// 动作，如“投喂”“送出”“赠送”
  final String action;

  /// 礼物名称，如“小心心”“Bits”“赠送订阅”
  final String giftName;

  /// 礼物图片，和表情用同一套显示；平台没有给出时为 null
  final LiveEmote? icon;

  /// 数量（连击时为到目前为止的累计数量）
  final int count;

  /// 付费礼物；免费礼物（B 站辣条、抖音 0 钻的礼物等）不飞过视频
  final bool paid;

  /// 价值，带单位，如“¥5”“520 钻”“100 Bits”；不知道时为空
  final String? priceText;

  /// 送礼时间：平台给出时用平台的，否则为收到的时间
  final DateTime time;

  /// 平台说这次连击已经结束
  final bool comboEnd;

  /// 送礼人的用户 ID，同 [LiveMessage.userId]
  final String? userId;

  LiveGiftMessage({
    this.comboId,
    required this.userName,
    this.face = "",
    this.action = "送出",
    required this.giftName,
    this.icon,
    this.count = 1,
    this.paid = true,
    this.priceText,
    DateTime? time,
    this.comboEnd = false,
    this.userId,
  }) : time = time ?? DateTime.now();

  /// 同一条礼物换上送礼人的用户 ID（[id] 按 [liveUserId] 整理，没有时原样返回）
  LiveGiftMessage withUserId(dynamic id) {
    var value = liveUserId(id);
    if (value == null || value == userId) {
      return this;
    }
    return LiveGiftMessage(
      comboId: comboId,
      userName: userName,
      face: face,
      action: action,
      giftName: giftName,
      icon: icon,
      count: count,
      paid: paid,
      priceText: priceText,
      time: time,
      comboEnd: comboEnd,
      userId: value,
    );
  }

  /// 纯文字的说明，如“投喂 小心心 ×3”（数量为 1 时不写数量）
  String get text => "$action $giftName${count > 1 ? " ×$count" : ""}";

  /// 包成一条礼物消息，[LiveMessage.message] 是 [text]
  LiveMessage toMessage() => LiveMessage(
    type: LiveMessageType.gift,
    userName: userName,
    message: text,
    color: LiveMessageColor.white,
    face: face.isEmpty ? null : face,
    data: this,
    userId: userId,
  );

  @override
  String toString() => json.encode({
    "comboId": comboId,
    "userName": userName,
    "face": face,
    "action": action,
    "giftName": giftName,
    if (icon != null) "icon": icon!.toJson(),
    "count": count,
    "paid": paid,
    "priceText": priceText,
    "time": time.toIso8601String(),
    if (comboEnd) "comboEnd": true,
    if (userId != null) "userId": userId,
  });
}

class LiveSuperChatMessage {
  /// 平台的 SC id（用于去重），没有时为空
  final String? id;
  final String userName;
  final String face;
  final String message;
  final int price;
  final DateTime startTime;
  final DateTime endTime;
  final String backgroundColor;
  final String backgroundBottomColor;

  /// 带币种的金额（如 YouTube 的“$5.00”“€2.00”），为空时按人民币显示 [price]
  final String? priceText;

  /// 留言里的表情图片（同 [LiveMessage.emotes]）
  final List<LiveEmote>? emotes;

  /// 付费贴纸（如 YouTube 的 Super Sticker）的图片，[message] 是它的文字说明
  final LiveEmote? sticker;

  /// 发送人的用户 ID，同 [LiveMessage.userId]
  final String? userId;
  LiveSuperChatMessage({
    this.id,
    required this.backgroundBottomColor,
    required this.backgroundColor,
    required this.endTime,
    required this.face,
    required this.message,
    required this.price,
    required this.startTime,
    required this.userName,
    this.priceText,
    this.emotes,
    this.sticker,
    this.userId,
  });

  @override
  String toString() {
    return json.encode({
      "id": id,
      "userName": userName,
      "face": face,
      "message": message,
      "price": price,
      "startTime": startTime,
      "endTime": endTime,
      "backgroundColor": backgroundColor,
      "backgroundBottomColor": backgroundBottomColor,
      "priceText": priceText,
      if (emotes != null) "emotes": emotes!.map((e) => e.toJson()).toList(),
      if (sticker != null) "sticker": sticker!.toJson(),
      if (userId != null) "userId": userId,
    });
  }
}
