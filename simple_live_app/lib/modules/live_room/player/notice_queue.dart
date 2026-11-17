import 'package:simple_live_app/modules/live_room/live_gifts.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 视频左下角的一张卡片：SC 或礼物
class NoticeEntry {
  NoticeEntry.superChat(LiveSuperChatMessage this.superChat, this.key)
      : gift = null,
        queuedAt = DateTime.now();
  NoticeEntry.gift(GiftRecord this.gift, this.key, this.queuedAt)
      : superChat = null;

  final String key;
  final LiveSuperChatMessage? superChat;
  final GiftRecord? gift;
  final DateTime queuedAt;

  /// 显示到什么时候；还在排队时为 null
  DateTime? hideAt;

  bool get isGift => gift != null;
}

/// SC 和礼物共用视频左下角的位置：先来先显示，同时最多显示 [maxVisible] 张，
/// 其余排队。礼物显示 [giftDuration]，连击时更新同一张卡片，
/// 每来一次多显示 [comboExtra]，但从那一刻算起不超过 SC 的 [superChatSeconds]。
/// 礼物太多时只留最近的 [maxQueuedGifts] 条排队，排了 [giftStale] 还没轮到的不再显示；
/// SC 不会被挤掉
class NoticeQueue {
  NoticeQueue({
    this.maxVisible = 4,
    this.maxQueuedGifts = 20,
    this.superChatSeconds = 15,
    this.giftDuration = const Duration(seconds: 5),
    this.comboExtra = const Duration(seconds: 1),
    this.giftStale = const Duration(seconds: 30),
  });

  final int maxVisible;
  final int maxQueuedGifts;

  /// SC 最多显示多少秒（不超过它在直播间里剩下的时间）
  final int superChatSeconds;

  /// 礼物显示多久
  final Duration giftDuration;

  /// 连击每来一次多显示多久
  final Duration comboExtra;
  final Duration giftStale;

  final List<NoticeEntry> shown = [];
  final List<NoticeEntry> queued = [];
  final Set<String> _seen = {};
  final Map<GiftRecord, NoticeEntry> _gifts = Map.identity();

  /// 新收到的 SC（同一条只排一次）
  void pushSuperChat(LiveSuperChatMessage sc, String key) {
    if (!_seen.add("sc:$key")) {
      return;
    }
    queued.add(NoticeEntry.superChat(sc, key));
  }

  /// 新的礼物或连击更新
  void pushGift(GiftRecord record, DateTime now) {
    var entry = _gifts[record];
    if (entry != null) {
      var hideAt = entry.hideAt;
      if (hideAt != null) {
        // 正在显示：数量已经更新，多显示一会儿
        var longest = now.add(Duration(seconds: superChatSeconds));
        var next = hideAt.add(comboExtra);
        entry.hideAt = next.isAfter(longest) ? longest : next;
      }
      return;
    }
    entry = NoticeEntry.gift(record, "gift:${identityHashCode(record)}", now);
    _gifts[record] = entry;
    queued.add(entry);
    var gifts = queued.where((e) => e.isGift).toList();
    if (gifts.length > maxQueuedGifts) {
      for (var old in gifts.take(gifts.length - maxQueuedGifts)) {
        queued.remove(old);
        _gifts.remove(old.gift);
      }
    }
  }

  /// 每秒（以及有新内容时）调用：收起到时的，把排队的放上来。
  /// [remaining] 是 SC 在直播间里还剩多少秒。有变化时返回 true
  bool tick(DateTime now, int Function(LiveSuperChatMessage sc) remaining) {
    var changed = false;
    shown.removeWhere((e) {
      var done = !e.hideAt!.isAfter(now);
      if (done) {
        changed = true;
        if (e.isGift) {
          _gifts.remove(e.gift);
        }
      }
      return done;
    });
    queued.removeWhere((e) {
      var stale = e.isGift && now.difference(e.queuedAt) > giftStale;
      if (stale) {
        _gifts.remove(e.gift);
      }
      return stale;
    });
    while (shown.length < maxVisible && queued.isNotEmpty) {
      var entry = queued.removeAt(0);
      if (entry.isGift) {
        entry.hideAt = now.add(giftDuration);
      } else {
        var left = remaining(entry.superChat!);
        if (left <= 0) {
          continue;
        }
        var seconds = left < superChatSeconds ? left : superChatSeconds;
        entry.hideAt = now.add(Duration(seconds: seconds));
      }
      shown.add(entry);
      changed = true;
    }
    return changed;
  }

  /// 关掉了某一类的显示：收起并清掉排队的
  void removeWhere(bool Function(NoticeEntry e) test) {
    for (var e in [...shown, ...queued]) {
      if (test(e) && e.isGift) {
        _gifts.remove(e.gift);
      }
    }
    shown.removeWhere(test);
    queued.removeWhere(test);
  }

  void clear() {
    shown.clear();
    queued.clear();
    _gifts.clear();
  }
}
