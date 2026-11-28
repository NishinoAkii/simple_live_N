import 'dart:convert';

import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// Kick 的订阅、礼物订阅与 Kicks 礼物（Pusher 事件）
///
/// 和网页端订阅的频道、事件一致：
/// - chatrooms.{聊天室 id}.v2：App\Events\SubscriptionEvent（开通、续订）
/// - chatroom_{聊天室 id}：GiftedSubscriptionsEvent（送订阅）
/// - channel_{频道 id}：KicksGifted（Kicks 礼物）
///
/// 一次送很多份订阅时，GiftedSubscriptionsEvent 会分成几块发
/// （chunk_details 的 correlation_id 相同），每块都带总数，只按第一块计数。
class KickGiftParser {
  /// 正在分块接收的送订阅，最后一块到了就移除
  final Set<String> _chunks = {};
  static const int _limit = 64;

  /// Pusher 事件 → 礼物；[data] 是事件里的 data（JSON 字符串或已解析的 Map）。
  /// 不是礼物类事件、或者是同一次送订阅的后续分块时返回 null
  LiveGiftMessage? parse(String event, dynamic data) {
    LiveGiftMessage? Function(Map data)? handler = switch (event) {
      r"App\Events\SubscriptionEvent" => subscription,
      "GiftedSubscriptionsEvent" ||
      r"App\Events\GiftedSubscriptionsEvent" => giftedSubscriptions,
      "KicksGifted" => kicksGifted,
      _ => null,
    };
    if (handler == null) {
      return null;
    }
    try {
      return handler(data is String ? json.decode(data) : data as Map);
    } catch (_) {
      return null;
    }
  }

  /// GiftedSubscriptionsEvent → 礼物；同一次送订阅的后续分块返回 null
  LiveGiftMessage? giftedSubscriptions(Map data) {
    var names = data["gifted_usernames"];
    var total =
        (data["gifted_total"] as num?)?.toInt() ??
        (names is List ? names.length : 0);
    if (total <= 0) {
      return null;
    }
    // 不分块时 chunk_details 为 null，correlation_id 在外层
    var chunk = data["chunk_details"];
    var id =
        (chunk is Map ? chunk["correlation_id"] : null)?.toString() ??
        data["correlation_id"]?.toString() ??
        "";
    if (chunk is Map && id.isNotEmpty) {
      var index = (chunk["chunk_index"] as num?)?.toInt() ?? 0;
      var chunks = (chunk["total_chunks"] as num?)?.toInt() ?? 1;
      var seen = _chunks.contains(id);
      if (index >= chunks - 1) {
        _chunks.remove(id);
      } else if (!seen) {
        _chunks.add(id);
        if (_chunks.length > _limit) {
          _chunks.remove(_chunks.first);
        }
      }
      if (seen) {
        return null;
      }
    }
    var gifter = data["gifter_username"]?.toString() ?? "";
    return LiveGiftMessage(
      comboId: id.isEmpty ? null : "kick:$id",
      userName: gifter.isEmpty ? "匿名" : gifter,
      action: "赠送",
      giftName: "订阅",
      count: total,
      estimate: kickSubEstimate(total),
    );
  }

  /// [count] 份一个月订阅的价值：Kick 的订阅全球统一每月 5 美元，如“$25”
  static String? kickSubEstimate(int count) =>
      count > 0 ? "\$${5 * count}" : null;

  /// App\Events\SubscriptionEvent（{username, months}）→ 礼物
  static LiveGiftMessage? subscription(Map data) {
    var name = data["username"]?.toString() ?? "";
    if (name.isEmpty) {
      return null;
    }
    var months = (data["months"] as num?)?.toInt() ?? 1;
    return LiveGiftMessage(
      userName: name,
      action: months > 1 ? "续订" : "开通",
      giftName: "订阅",
      priceText: months > 1 ? "{months} 个月".tf({"months": months}) : null,
      // months 是累计的月数，这次付的是一个月
      estimate: kickSubEstimate(1),
    );
  }

  /// KicksGifted → 礼物
  static LiveGiftMessage? kicksGifted(Map data) {
    var gift = data["gift"];
    var sender = data["sender"];
    if (gift is! Map) {
      return null;
    }
    var id = gift["gift_id"]?.toString() ?? "";
    var name = gift["name"]?.toString() ?? "";
    if (name.isEmpty) {
      name = id;
    }
    if (name.isEmpty) {
      return null;
    }
    var amount = (gift["amount"] as num?)?.toInt() ?? 0;
    var transaction = data["gift_transaction_id"]?.toString() ?? "";
    var user = sender is Map ? sender["username"]?.toString() ?? "" : "";
    return LiveGiftMessage(
      // 同一笔交易重复推送时只占一行
      comboId: transaction.isEmpty ? null : "kick:$transaction",
      userName: user.isEmpty ? "匿名" : user,
      face: sender is Map ? sender["profile_picture"]?.toString() ?? "" : "",
      action: "赠送",
      giftName: name,
      icon: kicksGiftIcon(id, name),
      priceText: amount > 0 ? "$amount Kicks" : null,
      time: DateTime.tryParse(data["created_at"]?.toString() ?? "")?.toLocal(),
      userId: sender is Map ? liveUserId(sender["id"]) : null,
    );
  }

  /// 网页端的礼物图片表（gift_id → 静态图、动图）
  static const Map<String, (String, String?)> _giftImages = {
    "hell_yeah": ("hell-yeah.webp", null),
    "hype": ("hype.webp", null),
    "skull_emoji": ("skull-emoji.webp", null),
    "full_send": ("full-send.webp", null),
    "rage_quit": ("rage-quit-static.webp", "rage-quit.webp"),
    "pack_it_up": ("pack-it-up-static.webp", "pack-it-up.webp"),
    "yap": ("yap-static.webp", "yap.webp"),
    "stomp": ("stomp-static.webp", "stomp.webp"),
    "flex": ("flex-static.webp", "flex.webp"),
    "boooom": ("boom-static.webp", "boom.webp"),
  };

  /// Kicks 礼物图片；表里没有的按网页端的命名规则（下划线换成连字符）
  static LiveEmote? kicksGiftIcon(String id, String name) {
    if (id.isEmpty) {
      return null;
    }
    const base = "https://files.kick.com/kicks/gifts";
    var known = _giftImages[id];
    if (known == null) {
      return LiveEmote(
        text: name,
        url: "$base/${id.replaceAll('_', '-')}.webp",
        width: 1,
        height: 1,
      );
    }
    var (still, animated) = known;
    return LiveEmote(
      text: name,
      url: "$base/${animated ?? still}",
      staticUrl: animated == null ? null : "$base/$still",
      width: 1,
      height: 1,
    );
  }
}
