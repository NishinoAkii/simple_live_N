import 'package:simple_live_core/src/common/youtube_parser.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/common/core_text.dart';

// YouTube 直播聊天（live_chat 页面与 get_live_chat 接口）的解析

/// 一条聊天消息
class YouTubeChatItem {
  final String id;
  final LiveMessage message;

  /// 发送时间（timestampUsec），没有时为 null
  final DateTime? time;
  YouTubeChatItem({required this.id, required this.message, this.time});

  bool get isSuperChat => message.type == LiveMessageType.superChat;
}

/// 一次 get_live_chat 的结果
class YouTubeChatBatch {
  final List<YouTubeChatItem> items;

  /// 下一次请求用的令牌，为 null 表示聊天已结束
  final String? continuation;

  /// 服务端建议的下次请求间隔
  final int timeoutMs;

  /// 响应中是否有聊天数据（没有时多半是令牌失效）
  final bool valid;
  YouTubeChatBatch({
    required this.items,
    required this.continuation,
    required this.timeoutMs,
    this.valid = true,
  });

  bool get ended => continuation == null;
}

/// live_chat 页面中的信息
class YouTubeLiveChatPage {
  /// “所有聊天”（不经热门筛选）的初始令牌，首次请求会带回最近的历史消息
  final String? allChatContinuation;

  /// 页面默认的“热门聊天”令牌
  final String? defaultContinuation;

  /// 聊天不可用时的提示（关闭了聊天等），可用时为 null
  final String? unavailableReason;

  YouTubeLiveChatPage({
    this.allChatContinuation,
    this.defaultContinuation,
    this.unavailableReason,
  });

  String? get continuation => allChatContinuation ?? defaultContinuation;

  static YouTubeLiveChatPage parse(String html) {
    var data =
        extractYouTubeJson(html, 'window["ytInitialData"]') ??
        extractYouTubeJson(html, 'ytInitialData =');
    var renderer = data?["contents"]?["liveChatRenderer"];
    if (renderer is! Map) {
      var notice = ytFindFirst(data?["contents"], "messageRenderer");
      var message = ytText(notice is Map ? notice["text"] : null);
      return YouTubeLiveChatPage(
        unavailableReason: message.isNotEmpty ? message : "这场直播没有开放聊天".t,
      );
    }
    String? allChat;
    var menu = ytFindFirst(renderer["header"], "subMenuItems");
    if (menu is List && menu.length > 1 && menu[1] is Map) {
      // 第一项是热门聊天，第二项是所有聊天
      var token =
          menu[1]["continuation"]?["reloadContinuationData"]?["continuation"];
      if (token is String && token.isNotEmpty) {
        allChat = token;
      }
    }
    return YouTubeLiveChatPage(
      allChatContinuation: allChat,
      defaultContinuation: _continuationOf(renderer["continuations"]).$1,
    );
  }
}

const _continuationKeys = [
  "invalidationContinuationData",
  "timedContinuationData",
  "reloadContinuationData",
];

(String?, int) _continuationOf(dynamic continuations) {
  if (continuations is! List) {
    return (null, 0);
  }
  for (var item in continuations) {
    if (item is! Map) {
      continue;
    }
    for (var key in _continuationKeys) {
      var data = item[key];
      if (data is Map) {
        var token = data["continuation"]?.toString();
        if (token != null && token.isNotEmpty) {
          return (token, (data["timeoutMs"] as num?)?.toInt() ?? 0);
        }
      }
    }
  }
  return (null, 0);
}

/// 解析 get_live_chat 响应
YouTubeChatBatch parseYouTubeChatResponse(
  dynamic response, {
  DateTime? now,
  bool useTimestamps = false,
}) {
  var chat = response?["continuationContents"]?["liveChatContinuation"];
  if (chat is! Map) {
    return YouTubeChatBatch(
      items: [],
      continuation: null,
      timeoutMs: 0,
      valid: false,
    );
  }
  var (token, timeout) = _continuationOf(chat["continuations"]);
  return YouTubeChatBatch(
    items: parseYouTubeChatActions(
      chat["actions"],
      now: now,
      useTimestamps: useTimestamps,
    ),
    continuation: token,
    timeoutMs: timeout,
  );
}

/// 解析聊天动作中新增的消息：普通消息、醒目留言（Super Chat）、付费贴纸，
/// 以及会员、赠送会员、礼物（礼物消息，[LiveMessageType.gift]）
///
/// [useTimestamps] 为 true 时醒目留言按发送时间计算显示时长（用于进入直播间时的历史消息），
/// 否则从 [now] 开始计算。
///
/// 赠送会员时，送的人一条（带总数），收到的人各一条
/// （liveChatSponsorshipsGiftRedemptionAnnouncementRenderer）；
/// 后者不再计数，免得同一次赠送算两遍。
List<YouTubeChatItem> parseYouTubeChatActions(
  dynamic actions, {
  DateTime? now,
  bool useTimestamps = false,
}) {
  var result = <YouTubeChatItem>[];
  if (actions is! List) {
    return result;
  }
  var current = now ?? DateTime.now();
  for (var action in actions) {
    var item = action is Map ? (action["addChatItemAction"]?["item"]) : null;
    if (item is! Map) {
      continue;
    }
    YouTubeChatItem? parsed;
    if (item["liveChatTextMessageRenderer"] is Map) {
      parsed = _parseText(item["liveChatTextMessageRenderer"]);
    } else if (item["liveChatPaidMessageRenderer"] is Map) {
      parsed = _parsePaid(
        item["liveChatPaidMessageRenderer"],
        current,
        useTimestamps,
        sticker: false,
      );
    } else if (item["liveChatPaidStickerRenderer"] is Map) {
      parsed = _parsePaid(
        item["liveChatPaidStickerRenderer"],
        current,
        useTimestamps,
        sticker: true,
      );
    } else if (item["liveChatMembershipItemRenderer"] is Map) {
      parsed = _parseMembership(item["liveChatMembershipItemRenderer"]);
    } else if (item["liveChatSponsorshipsGiftPurchaseAnnouncementRenderer"]
        is Map) {
      parsed = _parseGiftPurchase(
        item["liveChatSponsorshipsGiftPurchaseAnnouncementRenderer"],
      );
    } else if (item["giftMessageViewModel"] is Map) {
      parsed = _parseGiftMessage(item["giftMessageViewModel"]);
    }
    if (parsed != null) {
      result.add(parsed);
    }
  }
  return result;
}

DateTime? _timestamp(Map renderer) {
  var usec = int.tryParse(renderer["timestampUsec"]?.toString() ?? "");
  return usec == null ? null : DateTime.fromMicrosecondsSinceEpoch(usec);
}

String _face(Map renderer) {
  var photo =
      renderer["authorPhoto"] ??
      renderer["authorAvatar"]?["avatarViewModel"]?["image"];
  return ytThumbnail(photo, target: 64);
}

YouTubeChatItem? _parseText(Map renderer) {
  var id = renderer["id"]?.toString() ?? "";
  var text = ytText(renderer["message"]).trim();
  if (id.isEmpty || text.isEmpty) {
    return null;
  }
  var face = _face(renderer);
  return YouTubeChatItem(
    id: id,
    time: _timestamp(renderer),
    message: LiveMessage(
      type: LiveMessageType.chat,
      userName: ytText(renderer["authorName"]),
      message: text,
      color: LiveMessageColor.white,
      face: face.isEmpty ? null : face,
      emotes: ytEmotes(renderer["message"]),
      badges: ytAuthorBadges(renderer["authorBadges"]),
      userId: _authorId(renderer),
    ),
  );
}

/// 发言人的频道 ID（UC 开头），没有时为 null
String? _authorId(Map renderer) =>
    liveUserId(renderer["authorExternalChannelId"]);

/// authorBadges → 发言人身份，按平台给出的顺序。
///
/// 每项是 liveChatAuthorBadgeRenderer：系统徽章是 icon.iconType
/// （OWNER 主播、MODERATOR 房管、VERIFIED 认证），
/// 频道会员徽章是 customThumbnail（图片）加 tooltip（“会员（6 个月）”
/// “Member (1 year)”“新会员”，会员等级名由频道自定），月数从 tooltip 里读。
/// 没有认得的时返回 null
List<LiveBadge>? ytAuthorBadges(dynamic authorBadges) {
  if (authorBadges is! List) {
    return null;
  }
  var result = <LiveBadge>[];
  for (var item in authorBadges) {
    var badge = _ytAuthorBadge(
      item is Map ? item["liveChatAuthorBadgeRenderer"] : null,
    );
    if (badge != null &&
        !result.any((e) => e.kind == badge.kind && e.text == badge.text)) {
      result.add(badge);
    }
  }
  return result.isEmpty ? null : result;
}

LiveBadge? _ytAuthorBadge(dynamic badge) {
  if (badge is! Map) {
    return null;
  }
  if (badge["customThumbnail"] is Map) {
    var tooltip = ytText(badge["tooltip"]).trim();
    if (tooltip.isEmpty) {
      var a11y = badge["accessibility"];
      var data = a11y is Map ? a11y["accessibilityData"] : null;
      tooltip = ytText(data is Map ? data["label"] : null).trim();
    }
    var url = "";
    try {
      url = ytThumbnail(badge["customThumbnail"], target: 32);
    } catch (_) {
      // 宽度不是数字之类的坏数据：不要图标
    }
    return LiveBadge(
      LiveBadgeKind.member,
      "会员",
      level: ytMemberMonths(tooltip),
      icon: url.isEmpty ? null : url,
    );
  }
  var icon = badge["icon"];
  return switch (icon is Map ? icon["iconType"] : null) {
    "OWNER" => const LiveBadge(LiveBadgeKind.broadcaster, "主播"),
    "MODERATOR" => const LiveBadge(LiveBadgeKind.admin, "房管"),
    "VERIFIED" => const LiveBadge(LiveBadgeKind.title, "认证"),
    _ => null,
  };
}

/// 会员徽章 tooltip 里的会龄（月）：“会员（6 个月）”“Member (6 months)”→ 6，
/// “会员（1 年）”“Member (2 years)”→ 12、24；“新会员”“New member”没有数字，为 null。
/// 会员等级名可能带数字（“Tier 2 (6 months)”），有括号时只看最后一对括号里的
int? ytMemberMonths(String tooltip) {
  var text = tooltip.trim();
  var paren = RegExp(r'[(（]([^()（）]*)[)）][^()（）]*$').firstMatch(text);
  var part = paren?.group(1) ?? text;
  var match = RegExp(r'(\d+)\s*([^\d\s)）]*)').firstMatch(part);
  var n = int.tryParse(match?.group(1) ?? "");
  if (n == null || n <= 0) {
    return null;
  }
  return _yearUnit.hasMatch(match!.group(2)!) ? n * 12 : n;
}

/// 各语言里“年”的单位（数字后面紧跟的词），其余按月算
final RegExp _yearUnit = RegExp(
  r'^(?:year|yr|年|년|jahr|año|ano|an|år|jaar|rok|lat|let|yıl|év|vuo|'
  r'год|лет|рік|рок|tahun|ปี|năm|साल|वर्ष|سن|عام|שנ|έτ|χρόν)',
  caseSensitive: false,
);

YouTubeChatItem? _parsePaid(
  Map renderer,
  DateTime now,
  bool useTimestamps, {
  required bool sticker,
}) {
  var id = renderer["id"]?.toString() ?? "";
  if (id.isEmpty) {
    return null;
  }
  var userName = ytText(renderer["authorName"]);
  var face = _face(renderer);
  var amount = ytText(renderer["purchaseAmountText"]).trim();
  String message;
  int? top;
  int? bottom;
  List<LiveEmote>? emotes;
  LiveEmote? stickerImage;
  if (sticker) {
    message =
        renderer["sticker"]?["accessibility"]?["accessibilityData"]?["label"]
            ?.toString() ??
        "";
    top = (renderer["backgroundColor"] as num?)?.toInt();
    bottom = (renderer["moneyChipBackgroundColor"] as num?)?.toInt();
    var url = ytThumbnail(renderer["sticker"], target: 80);
    if (url.isNotEmpty) {
      stickerImage = LiveEmote(text: message, url: url, width: 1, height: 1);
    }
  } else {
    message = ytText(renderer["message"]).trim();
    top = (renderer["headerBackgroundColor"] as num?)?.toInt();
    bottom = (renderer["bodyBackgroundColor"] as num?)?.toInt();
    emotes = ytEmotes(renderer["message"]);
  }
  var time = _timestamp(renderer);
  var start = useTimestamps && time != null && time.isBefore(now) ? time : now;
  var sc = LiveSuperChatMessage(
    id: id,
    userName: userName,
    face: face,
    message: message,
    price: ytParsePrice(amount),
    priceText: amount.isEmpty ? null : amount,
    backgroundColor: ytArgbToHex(top ?? bottom, fallback: "#1565C0"),
    backgroundBottomColor: ytArgbToHex(bottom ?? top, fallback: "#1565C0"),
    startTime: start,
    endTime: start.add(ytSuperChatDuration(top, bottom)),
    emotes: emotes,
    sticker: stickerImage,
    userId: _authorId(renderer),
  );
  return YouTubeChatItem(
    id: id,
    time: time,
    message: LiveMessage(
      type: LiveMessageType.superChat,
      userName: userName,
      message: message,
      color: LiveMessageColor.white,
      face: face.isEmpty ? null : face,
      data: sc,
      emotes: emotes,
      sticker: stickerImage,
      badges: ytAuthorBadges(renderer["authorBadges"]),
      userId: sc.userId,
    ),
  );
}

/// 礼物消息，[badges] 是送礼人的身份
YouTubeChatItem _giftItem(
  String id,
  Map renderer,
  LiveGiftMessage gift, {
  List<LiveBadge>? badges,
}) {
  var message = gift.withUserId(_authorId(renderer)).toMessage();
  return YouTubeChatItem(
    id: id,
    time: _timestamp(renderer),
    message: badges == null
        ? message
        : LiveMessage(
            type: message.type,
            userName: message.userName,
            message: message.message,
            data: message.data,
            color: message.color,
            face: message.face,
            emotes: message.emotes,
            sticker: message.sticker,
            history: message.history,
            badges: badges,
            userId: message.userId,
          ),
  );
}

/// 会员：新会员（只有 headerSubtext，如“欢迎加入 xxx！”），
/// 或会员里程碑（headerPrimaryText 如“会龄：9 个月”，headerSubtext 是会员等级名称）
YouTubeChatItem? _parseMembership(Map renderer) {
  var id = renderer["id"]?.toString() ?? "";
  var userName = ytText(renderer["authorName"]).trim();
  if (id.isEmpty || userName.isEmpty) {
    return null;
  }
  var primary = renderer["headerPrimaryText"];
  var milestone = ytText(primary).trim().isNotEmpty;
  String? priceText;
  if (milestone) {
    var level = ytText(renderer["headerSubtext"]).trim();
    var months = _numberIn(primary);
    var parts = [if (level.isNotEmpty) level, if (months != null) "{months} 个月".tf({"months": months})];
    priceText = parts.isEmpty ? null : parts.join(" · ");
  }
  return _giftItem(
    id,
    renderer,
    LiveGiftMessage(
      userName: userName,
      face: _face(renderer),
      action: milestone ? "续订" : "加入",
      giftName: "会员",
      priceText: priceText,
      time: _timestamp(renderer),
    ),
    badges: ytAuthorBadges(renderer["authorBadges"]),
  );
}

/// 赠送会员（送的人一条，primaryText 如“Gifted 5 xxx memberships”）。
/// 没有头像和名字的是匿名赠送
YouTubeChatItem? _parseGiftPurchase(Map renderer) {
  var id = renderer["id"]?.toString() ?? "";
  var header = renderer["header"]?["liveChatSponsorshipsHeaderRenderer"];
  if (id.isEmpty || header is! Map) {
    return null;
  }
  var userName = ytText(header["authorName"]).trim();
  var image = ytThumbnail(header["image"], target: 48);
  return _giftItem(
    id,
    renderer,
    LiveGiftMessage(
      userName: userName.isEmpty ? "匿名" : userName,
      face: ytThumbnail(header["authorPhoto"], target: 64),
      action: "赠送",
      giftName: "会员",
      icon: image.isEmpty
          ? null
          : LiveEmote(text: "会员", url: image, width: 1, height: 1),
      count: _numberIn(header["primaryText"]) ?? 1,
      estimate: ytGiftMembershipEstimate(_numberIn(header["primaryText"]) ?? 1),
      time: _timestamp(renderer),
      userId: _authorId(header),
    ),
    badges: ytAuthorBadges(header["authorBadges"]),
  );
}

/// 礼物（观众用 Jewels 买的礼物）：
/// {id, authorName, authorAvatar, text: “已发送：爱心”, giftImage}，没有价值和时间
YouTubeChatItem? _parseGiftMessage(Map model) {
  var id = model["id"]?.toString() ?? "";
  var userName = ytText(model["authorName"]).trim();
  var text = ytText(model["text"]).trim();
  if (id.isEmpty || userName.isEmpty || text.isEmpty) {
    return null;
  }
  var (name, count) = ytGiftNameAndCount(text);
  // 礼物图默认 480px，gstatic 的图可以按 =wN-hN 取小图
  var image = ytThumbnail(
    model["giftImage"] ?? model["image"],
    target: 48,
  ).replaceFirst(RegExp(r'=w\d+-h\d+$'), "=w96-h96");
  return _giftItem(
    id,
    model,
    LiveGiftMessage(
      userName: userName,
      face: _face(model),
      action: "赠送",
      giftName: name,
      icon: image.isEmpty
          ? null
          : LiveEmote(text: name, url: image, width: 1, height: 1),
      count: count,
      time: _timestamp(model),
    ),
  );
}

/// 礼物消息文字里的礼物名称和数量：“已发送：爱心”“Sent: Heart”取冒号后面的，
/// “sent Heart x3”→（Heart, 3）；认不出时整段文字当名称
(String, int) ytGiftNameAndCount(String text) {
  var name = text.trim();
  var count = 1;
  var tail = RegExp(r'(?:\s+[xX]|\s*×)\s*(\d+)$').firstMatch(name);
  if (tail != null) {
    count = int.tryParse(tail.group(1)!) ?? 1;
    name = name.substring(0, tail.start).trim();
  }
  var colon = name.lastIndexOf(RegExp(r'[:：]'));
  if (colon >= 0) {
    name = name.substring(colon + 1);
  } else {
    name = name.replaceFirst(
      RegExp(
        r'^(?:(?:sent|gifted)\s+|(?:送出了|赠送了|送出|赠送|送了)\s*)',
        caseSensitive: false,
      ),
      "",
    );
  }
  name = name.replaceAll(RegExp(r'^[「“"\s]+|[」”"\s]+$'), "");
  return (name.isEmpty ? text.trim() : name, count < 1 ? 1 : count);
}

/// 赠送 [count] 份会员的估算价值：送的会员按主播不超过 5 美元的最高一档定价，
/// 消息里没有价格，按每份 4.99 美元估，如“$24.95”
String? ytGiftMembershipEstimate(int count) =>
    count > 0 ? "\$${(4.99 * count).toStringAsFixed(2)}" : null;

/// 文字（runs）里的第一个整数：优先取单独一段的数字（“Gifted ”“5”“ xxx memberships”），
/// 频道名里的数字不算；没有时为 null
int? _numberIn(dynamic node) {
  var runs = node is Map ? node["runs"] : null;
  if (runs is List) {
    for (var run in runs) {
      var text = ytRunText(run).trim().replaceAll(RegExp(r'[,.\s]'), '');
      if (text.isNotEmpty && RegExp(r'^\d+$').hasMatch(text)) {
        return int.tryParse(text);
      }
    }
  }
  var match = RegExp(r'\d+').firstMatch(ytText(node));
  return match == null ? null : int.tryParse(match.group(0)!);
}

/// 金额中的数字，取整；无法识别时为 0
///
/// 小数点与千位分隔符因币种和语言而异：两种符号都有时靠后的是小数点；
/// 只有一种时，后面恰好 1–2 位数字视为小数（“2,50 €”“$5.00”），否则是千位分隔（“¥1,000”“₫20.000”）。
int ytParsePrice(String text) {
  var match = RegExp(r'\d[\d.,\s  ]*').firstMatch(text);
  if (match == null) {
    return 0;
  }
  var s = match
      .group(0)!
      .replaceAll(RegExp(r'[\s  ]'), '')
      .replaceAll(RegExp(r'[.,]+$'), '');
  var lastDot = s.lastIndexOf('.');
  var lastComma = s.lastIndexOf(',');
  String normalized;
  if (lastDot >= 0 && lastComma >= 0) {
    normalized = lastDot > lastComma
        ? s.replaceAll(',', '')
        : s.replaceAll('.', '').replaceAll(',', '.');
  } else if (lastDot >= 0 || lastComma >= 0) {
    var sep = lastDot >= 0 ? '.' : ',';
    var last = lastDot >= 0 ? lastDot : lastComma;
    var tail = s.length - last - 1;
    var single = s.indexOf(sep) == last;
    normalized = single && (tail == 1 || tail == 2)
        ? s.replaceAll(sep, '.')
        : s.replaceAll(sep, '');
  } else {
    normalized = s;
  }
  return double.tryParse(normalized)?.round() ?? 0;
}

/// ARGB 整数转“#RRGGBB”
String ytArgbToHex(int? argb, {String fallback = "#FFFFFF"}) {
  if (argb == null) {
    return fallback;
  }
  return "#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}";
}

/// 醒目留言的颜色档位（RGB → 档位），各币种共用同一套颜色
const Map<int, int> _superChatTiers = {
  0x1565C0: 1, // 蓝（约 $1–1.99）
  0x00B8D4: 2, 0x00E5FF: 2, // 浅蓝（$2–4.99）
  0x00BFA5: 3, 0x1DE9B6: 3, // 绿（$5–9.99）
  0xFFB300: 4, 0xFFCA28: 4, // 黄（$10–19.99）
  0xE65100: 5, 0xF57C00: 5, // 橙（$20–49.99）
  0xC2185B: 6, 0xE91E63: 6, // 品红（$50–99.99）
  0xD00000: 7, 0xE62117: 7, // 红（$100 以上）
};

/// 醒目留言的显示时长
///
/// 按颜色档位而不是金额：金额的币种各不相同，颜色档位则是 YouTube 按等值金额统一划分的。
/// 时长取 1–5 分钟（YouTube 置顶时长从 0 到数小时不等，这里压缩到适合 SC 栏的范围）；
/// 颜色无法识别时按 2 分钟。
Duration ytSuperChatDuration(int? top, int? bottom) {
  var tier =
      _superChatTiers[(top ?? 0) & 0xFFFFFF] ??
      _superChatTiers[(bottom ?? 0) & 0xFFFFFF] ??
      0;
  const minutes = [2, 1, 1, 2, 3, 4, 5, 5];
  return Duration(minutes: minutes[tier]);
}
