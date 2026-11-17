import 'package:simple_live_core/src/common/core_text.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_rank.dart';

/// 本场礼物榜（所有平台都有，App 按收到的礼物自己算）
const LiveRankBoard kGiftRankBoard = LiveRankBoard(
  id: "gifts_local",
  title: "本场礼物榜",
  shortTitle: "礼物榜",
  scoreLabel: "礼物价值",
  note: "按进入直播间后收到的付费礼物计算",
);

/// 礼物价格的单位
enum LiveGiftUnit {
  /// 人民币（哔哩哔哩、斗鱼、虎牙）
  yuan,

  /// 抖音的钻（10 钻 = 1 元）
  diamond,

  /// Twitch 的 Bits
  bits,

  /// Kick 的 Kicks
  kicks,
}

/// 哔哩哔哩上舰的价格后面带着时长（“¥414 · 季”），只看前面的金额
final RegExp _yuan = RegExp(r'^[¥￥]\s*([\d.,]+)(?:\s*·.*)?$');
final RegExp _bits = RegExp(r'^([\d,]+)\s*Bits$');
final RegExp _kicks = RegExp(r'^([\d,]+)\s*Kicks$');

/// 抖音的价格是“{p} 钻”，会跟着界面语言翻译：按当前语言的写法认
RegExp? _diamondPattern() {
  var parts = "{p} 钻".t.split("{p}");
  if (parts.length != 2) {
    return null;
  }
  return RegExp(
    "^${RegExp.escape(parts[0].trim())}\\s*([\\d,]+)\\s*"
    "${RegExp.escape(parts[1].trim())}\$",
  );
}

double? _number(String? text) =>
    text == null ? null : double.tryParse(text.replaceAll(",", ""));

/// 一次送礼值多少：价格写成“¥5”“520 钻”“100 Bits”“50 Kicks”时返回数和单位；
/// 免费礼物、订阅和会员这类没有价格的返回 null
({double amount, LiveGiftUnit unit})? liveGiftValue(LiveGiftMessage gift) {
  var text = gift.priceText?.trim() ?? "";
  if (!gift.paid || text.isEmpty) {
    return null;
  }
  ({double amount, LiveGiftUnit unit})? value(RegExp? re, LiveGiftUnit unit) {
    var amount = _number(re?.firstMatch(text)?.group(1));
    return amount == null || amount <= 0 ? null : (amount: amount, unit: unit);
  }

  return value(_yuan, LiveGiftUnit.yuan) ??
      value(_diamondPattern(), LiveGiftUnit.diamond) ??
      value(_bits, LiveGiftUnit.bits) ??
      value(_kicks, LiveGiftUnit.kicks);
}

/// 换算成大致的人民币，只用来排名次（Bits、Kicks 按 1 个 = 1 美分，不管汇率）
double _rankValue(LiveGiftUnit unit, double amount) => switch (unit) {
  LiveGiftUnit.yuan => amount,
  LiveGiftUnit.diamond => amount / 10,
  LiveGiftUnit.bits || LiveGiftUnit.kicks => amount / 100,
};

String _money(double value) {
  var rounded = (value * 10).round() / 10;
  return rounded == rounded.truncateToDouble()
      ? rounded.toInt().toString()
      : rounded.toStringAsFixed(1);
}

class _Sender {
  _Sender(this.order, this.gift);
  final int order;
  LiveGiftMessage gift;
  String face = "";
  final Map<LiveGiftUnit, double> amounts = {};
  int count = 0;

  double get value =>
      amounts.entries.fold(0, (sum, e) => sum + _rankValue(e.key, e.value));

  /// “¥12.5”“5200 钻”“500 Bits”，几种单位都有时用“ · ”连起来
  String? get valueText {
    var parts = <String>[
      if (amounts[LiveGiftUnit.yuan] case var v?) "¥${_money(v)}",
      if (amounts[LiveGiftUnit.diamond] case var v?)
        "{p} 钻".tf({"p": v.round()}),
      if (amounts[LiveGiftUnit.bits] case var v?) "${v.round()} Bits",
      if (amounts[LiveGiftUnit.kicks] case var v?) "${v.round()} Kicks",
    ];
    return parts.isEmpty ? null : parts.join(" · ");
  }
}

/// 本场礼物榜：按送礼人把付费礼物的价值加起来排。同一次连击只能传最新的那一条
/// （App 的 GiftBook 已经合好了）。价值一样时比礼物个数，再比谁先送。
/// 订阅、会员这类没有价格的也算上，价值按 0，排在有价值的后面
List<LiveRankItem> rankGiftSenders(Iterable<LiveGiftMessage> gifts) {
  var senders = <String, _Sender>{};
  for (var gift in gifts) {
    if (!gift.paid || (gift.userName.trim().isEmpty && gift.userId == null)) {
      continue;
    }
    var key = gift.userId != null ? "id:${gift.userId}" : "n:${gift.userName}";
    var sender = senders.putIfAbsent(key, () => _Sender(senders.length, gift));
    sender.gift = gift;
    if (gift.face.isNotEmpty) {
      sender.face = gift.face;
    }
    sender.count += gift.count > 0 ? gift.count : 1;
    var value = liveGiftValue(gift);
    if (value != null) {
      sender.amounts.update(
        value.unit,
        (v) => v + value.amount,
        ifAbsent: () => value.amount,
      );
    }
  }
  var list = senders.values.toList()
    ..sort((a, b) {
      var byValue = b.value.compareTo(a.value);
      if (byValue != 0) return byValue;
      var byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      return a.order.compareTo(b.order);
    });
  return [
    for (var i = 0; i < list.length; i++)
      LiveRankItem(
        rank: i + 1,
        userName: list[i].gift.userName,
        userId: list[i].gift.userId,
        face: list[i].face,
        detail: "{n} 个礼物".tf({"n": list[i].count}),
      ),
  ];
}
