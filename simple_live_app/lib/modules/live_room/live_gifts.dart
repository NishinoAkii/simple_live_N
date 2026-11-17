import 'package:simple_live_core/simple_live_core.dart';

/// 礼物页的一行：同一次连击合成一行，数量跟着更新，时间是第一次收到的时间
class GiftRecord {
  GiftRecord(this.gift, this.time);

  /// 这次连击最新的一条（数量最新）
  LiveGiftMessage gift;

  /// 第一次收到的时间（导出 ASS 时用它对时间轴）
  final DateTime time;

  /// 最后一次更新的时间（视频左边的礼物卡片按它计算显示多久）
  late DateTime updatedAt = time;
}

/// 本场收到的礼物，旧的在前。
///
/// 免费礼物也记下来（礼物页能看到），只是不在视频左边弹出。
class GiftBook {
  GiftBook({this.maxCount = 5000});

  final int maxCount;
  final List<GiftRecord> records = [];
  final Map<String, GiftRecord> _byCombo = {};

  /// 记下一条礼物，返回它所在的一行，以及这一行是不是新的
  /// （不是新的就是已有连击的后续，数量已更新）
  (GiftRecord, bool) add(LiveGiftMessage gift, {DateTime? now}) {
    var time = now ?? DateTime.now();
    var key = gift.comboId;
    if (key != null && key.isNotEmpty) {
      var old = _byCombo[key];
      if (old != null) {
        // 数量只增不减：平台偶尔会把较早的一条晚一点发来
        if (gift.count >= old.gift.count) {
          old.gift = gift;
        }
        old.updatedAt = time;
        return (old, false);
      }
    }
    var record = GiftRecord(gift, time);
    records.add(record);
    if (key != null && key.isNotEmpty) {
      _byCombo[key] = record;
    }
    if (records.length > maxCount) {
      var drop = records.length - maxCount + maxCount ~/ 5;
      for (var old in records.take(drop)) {
        var oldKey = old.gift.comboId;
        if (oldKey != null && identical(_byCombo[oldKey], old)) {
          _byCombo.remove(oldKey);
        }
      }
      records.removeRange(0, drop);
    }
    return (record, true);
  }

  void clear() {
    records.clear();
    _byCombo.clear();
  }

  /// 本场礼物榜：按送礼人把付费礼物的价值加起来排（连击已经合成一行，不会重复算）
  List<LiveRankItem> ranking() => rankGiftSenders(records.map((e) => e.gift));
}

