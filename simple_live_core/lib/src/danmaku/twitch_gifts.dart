import 'dart:math';

import 'package:simple_live_core/src/danmaku/twitch_danmaku.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// Twitch 的订阅、礼物订阅与 Bits（IRC 的 USERNOTICE、带 bits 标签的 PRIVMSG）
///
/// 一个人一次送出多份订阅（submysterygift）后，Twitch 还会给每个收到的人
/// 各发一条 subgift，两者的 msg-param-community-gift-id 相同。
/// 总数已知时这些 subgift 不再计数；没收到总数（进直播间之前送的）时
/// 按收到的条数累计，comboId 相同，界面上只占一行。
class TwitchGiftParser {
  /// 一次送多份订阅：community-gift-id → 总数，只保留最近的
  final Map<String, int> _mystery = {};

  /// 总数未知时已收到的 subgift 条数
  final Map<String, int> _partial = {};
  static const int _limit = 64;

  /// 匿名送礼、匿名打赏的账号
  static const _anonymous = {"ananonymousgifter", "ananonymouscheerer"};

  /// USERNOTICE → 礼物，不是订阅类的通知时返回 null
  LiveGiftMessage? userNotice(TwitchIrcLine line) {
    var tags = line.tags;
    var msgId = tags["msg-id"] ?? "";
    // 同享聊天里别的直播间的通知（sharedchatnotice）不算这个直播间的
    if (msgId == "sharedchatnotice" || _fromOtherRoom(tags)) {
      return null;
    }
    var tier = twitchTierText(tags["msg-param-sub-plan"]);
    var prime = tags["msg-param-sub-plan"] == "Prime";
    var each = twitchSubPrice(tags["msg-param-sub-plan"]);
    int months(String key) => max(1, int.tryParse(tags[key] ?? "") ?? 1);
    // 一次预付几个月：multimonth-duration 是预付的月数，只在第一个月（tenure 为 0）付；
    // 预付期里后面几个月分享的续订没有新付钱
    int prepaid() =>
        (int.tryParse(tags["msg-param-multimonth-tenure"] ?? "") ?? 0) > 0
        ? 0
        : months("msg-param-multimonth-duration");
    LiveGiftMessage gift({
      required String action,
      String? comboId,
      int count = 1,
      String? priceText,
      int paidMonths = 1,
    }) => LiveGiftMessage(
      comboId: comboId,
      userName: twitchUserName(tags, line.nick),
      action: action,
      giftName: "订阅",
      count: count,
      // Prime 订阅不用观众另外花钱，不飞过视频
      paid: !prime,
      priceText: priceText ?? tier,
      estimate: twitchSubEstimate(each, count * paidMonths),
      time: _time(tags),
      userId: liveUserId(tags["user-id"]),
    );

    switch (msgId) {
      // cumulative-months 是累计的月数，不是这次付的
      case "sub":
        return gift(action: "开通", paidMonths: prepaid());
      case "resub":
        var cumulative = int.tryParse(
          tags["msg-param-cumulative-months"] ?? "",
        );
        return gift(
          action: "续订",
          priceText: _withMonths(tier, cumulative),
          paidMonths: prepaid(),
        );
      case "subgift":
      case "anonsubgift":
        var id = tags["msg-param-community-gift-id"] ?? "";
        if (id.isEmpty) {
          // 没有 community-gift-id 但 origin-id 对得上已知的一次送多份，也不再计数
          if (_mystery.containsKey(tags["msg-param-origin-id"] ?? "")) {
            return null;
          }
          var giftMonths = int.tryParse(tags["msg-param-gift-months"] ?? "");
          return gift(
            action: "赠送",
            priceText: _withMonths(tier, giftMonths),
            paidMonths: months("msg-param-gift-months"),
          );
        }
        if (_mystery.containsKey(id)) {
          return null;
        }
        var count = (_partial[id] ?? 0) + 1;
        _remember(_partial, id, count);
        return gift(action: "赠送", comboId: "twitch:$id", count: count);
      case "submysterygift":
      case "anonsubmysterygift":
        var id =
            tags["msg-param-community-gift-id"] ??
            tags["msg-param-origin-id"] ??
            "";
        var total = int.tryParse(tags["msg-param-mass-gift-count"] ?? "") ?? 0;
        if (total <= 0) {
          return null;
        }
        if (id.isEmpty) {
          return gift(action: "赠送", count: total);
        }
        _remember(_mystery, id, total);
        _partial.remove(id);
        return gift(action: "赠送", comboId: "twitch:$id", count: total);
      case "giftpaidupgrade":
      case "anongiftpaidupgrade":
      case "primepaidupgrade":
        // 别人送的订阅或 Prime 订阅转成自己付费的订阅
        return LiveGiftMessage(
          userName: twitchUserName(tags, line.nick),
          action: "续订",
          giftName: "订阅",
          priceText: tier,
          estimate: twitchSubEstimate(each, 1),
          time: _time(tags),
          userId: liveUserId(tags["user-id"]),
        );
    }
    return null;
  }

  /// 带 bits 标签的 PRIVMSG（Cheer）→ 礼物，不是 Cheer 时返回 null。
  /// 聊天消息照常显示，这里只多出一条礼物
  static LiveGiftMessage? cheer(TwitchIrcLine line) {
    var bits = int.tryParse(line.tags["bits"] ?? "") ?? 0;
    if (bits <= 0 || _fromOtherRoom(line.tags)) {
      return null;
    }
    return LiveGiftMessage(
      userName: twitchUserName(line.tags, line.nick),
      action: "赠送",
      giftName: "Bits",
      icon: bitsIcon(bits),
      count: bits,
      priceText: "$bits Bits",
      time: _time(line.tags),
      userId: liveUserId(line.tags["user-id"]),
    );
  }

  /// Cheer 宝石图（官方 Cheer 表情按数量分档：1、100、1000、5000、10000）
  static LiveEmote bitsIcon(int bits) {
    var tier = bits >= 10000
        ? 10000
        : bits >= 5000
        ? 5000
        : bits >= 1000
        ? 1000
        : bits >= 100
        ? 100
        : 1;
    const base = "https://d3aqoihi2n8ty8.cloudfront.net/actions/cheer/dark";
    return LiveEmote(
      text: "Bits",
      url: "$base/animated/$tier/2.gif",
      staticUrl: "$base/static/$tier/2.png",
      width: 1,
      height: 1,
    );
  }

  /// 订阅档位：1000/2000/3000 → Tier 1/2/3，Prime → Prime
  static String? twitchTierText(String? plan) {
    switch (plan) {
      case "1000":
        return "Tier 1";
      case "2000":
        return "Tier 2";
      case "3000":
        return "Tier 3";
      case "Prime":
        return "Prime";
    }
    return null;
  }

  /// 订阅一个月的标价（美元，美国网页价，2024-07 起），Prime 和不认得的为 null。
  /// 各地区有本地价，手机上买的更贵，只用来排本场礼物榜
  static double? twitchSubPrice(String? plan) => switch (plan) {
    "1000" => 5.99,
    "2000" => 9.99,
    "3000" => 24.99,
    _ => null,
  };

  /// [months] 个月（份数乘月数）的估算价值，如“$17.97”；不知道单价时为 null
  static String? twitchSubEstimate(double? each, int months) {
    if (each == null || months <= 0) {
      return null;
    }
    return "\$${(each * months).toStringAsFixed(2)}";
  }

  /// 显示名称（没有时用登录名），匿名送礼显示“匿名”
  static String twitchUserName(Map<String, String> tags, String nick) {
    var login = tags["login"] ?? nick;
    if (_anonymous.contains(login.toLowerCase())) {
      return "匿名";
    }
    var display = tags["display-name"] ?? "";
    return display.isNotEmpty ? display : login;
  }

  static bool _fromOtherRoom(Map<String, String> tags) {
    var source = tags["source-room-id"] ?? "";
    return source.isNotEmpty && source != (tags["room-id"] ?? "");
  }

  static String? _withMonths(String? tier, int? months) {
    if (months == null || months <= 1) {
      return tier;
    }
    return tier == null ? "{months} 个月".tf({"months": months}) : "{tier} · {months} 个月".tf({"tier": tier, "months": months});
  }

  static DateTime? _time(Map<String, String> tags) {
    var ms = int.tryParse(tags["tmi-sent-ts"] ?? "");
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static void _remember(Map<String, int> map, String key, int value) {
    map.remove(key);
    map[key] = value;
    while (map.length > _limit) {
      map.remove(map.keys.first);
    }
  }
}
