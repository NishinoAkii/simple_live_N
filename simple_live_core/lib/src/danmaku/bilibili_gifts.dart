import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart';
import 'package:simple_live_core/src/model/live_message.dart';

/// 哔哩哔哩的礼物消息，不是礼物或格式不对时返回 null。
///
/// - SEND_GIFT：JSON 格式的送礼（旧格式）
/// - SEND_GIFT_V2：未登录的连接收到的送礼，data.pb 是 base64 的 protobuf，
///   字段号见 [parseBiliSendGiftV2]
/// - COMBO_SEND：连击结束后的汇总，batch_combo_id 和这次连击的送礼相同，
///   只是更新同一行的数量，不会重复计数
/// - GUARD_BUY：上舰（舰长、提督、总督），分不出开通还是续费
/// - USER_TOAST_MSG、USER_TOAST_MSG_V2：上舰的提示，文字里写着“开通了”还是“续费了”。
///   和 GUARD_BUY 是同一次上舰，用 [BiliGuardMerger] 合成一行
///
/// 价格的单位是金瓜子：1000 金瓜子 = 1 元 = 10 电池；银瓜子礼物是免费的。
/// 连击用 batch_combo_id 合并（同一个人、同一个礼物、同一次连击相同），
/// 没有时用 tid（每次送礼一个，两种格式相同）。
LiveGiftMessage? parseBiliGift(dynamic obj) {
  if (obj is! Map || obj["data"] is! Map) {
    return null;
  }
  var data = obj["data"] as Map;
  var gift = switch (obj["cmd"]?.toString()) {
    "SEND_GIFT" => parseBiliSendGift(data),
    "SEND_GIFT_V2" => parseBiliSendGiftV2(data),
    "COMBO_SEND" => parseBiliComboSend(data),
    "GUARD_BUY" => parseBiliGuardBuy(data),
    "USER_TOAST_MSG" => parseBiliUserToast(data),
    "USER_TOAST_MSG_V2" => parseBiliUserToastV2(data),
    _ => null,
  };
  // 送礼人的 uid：JSON 格式在 data.uid（V2 的提示在 sender_uinfo.uid），
  // SEND_GIFT_V2 在 pb 里，已经取过；没登录时是 0
  return gift?.withUserId(
    liveUserId(data["uid"]) ?? _map(data["sender_uinfo"])["uid"],
  );
}

/// SEND_GIFT（JSON）
LiveGiftMessage? parseBiliSendGift(Map data) {
  var sender = _map(_map(data["sender_uinfo"])["base"]);
  var info = _map(data["gift_info"]);
  return _biliGift(
    batchComboId: _str(data["batch_combo_id"]),
    tid: _str(data["tid"]),
    userName: _str(data["uname"]).isNotEmpty
        ? _str(data["uname"])
        : _str(sender["name"]),
    face: _str(data["face"]).isNotEmpty
        ? _str(data["face"])
        : _str(sender["face"]),
    action: _str(data["action"]),
    giftName: _str(data["giftName"]),
    num: _int(data["num"]),
    clicks: _int(data["super_gift_num"]),
    price: _int(data["price"]),
    coinType: _str(data["coin_type"]),
    imgBasic: _str(info["img_basic"]),
    webp: _str(info["webp"]),
    timestamp: _int(data["timestamp"]),
  );
}

/// SEND_GIFT_V2：data.pb 是 base64 的 protobuf，没有公开的 .proto，
/// 字段号按抓到的消息和 SEND_GIFT 的同名字段对出来：
/// - 1 uid（未登录时没有）、2 uname（未登录时打码，如“用***”）、3 face、
///   15 sender_uinfo（2 base：1 name、2 face）
/// - 10 礼物：1 giftId、2 giftName、3 num、5 price、7 total_coin、8 coin_type、
///   9 tid、10 timestamp（秒）、11 super_gift_num（连击到第几下）、
///   12 batch_combo_id、14 combo_total_coin、18 action、
///   35 gift_info（1 img_basic、2 webp、5 gif）
LiveGiftMessage? parseBiliSendGiftV2(Map data) {
  var pb = data["pb"];
  if (pb is! String || pb.isEmpty) {
    return null;
  }
  _PbFields top;
  try {
    top = _PbFields.parse(base64.decode(pb));
  } catch (_) {
    return null;
  }
  var gift = top.message(10);
  var sender = top.message(15).message(2);
  var info = gift.message(35);
  return _biliGift(
    batchComboId: gift.string(12),
    tid: gift.string(9),
    userName: top.string(2).isNotEmpty ? top.string(2) : sender.string(1),
    face: top.string(3).isNotEmpty ? top.string(3) : sender.string(2),
    action: gift.string(18),
    giftName: gift.string(2),
    num: gift.integer(3),
    clicks: gift.integer(11),
    price: gift.integer(5),
    coinType: gift.string(8),
    imgBasic: info.string(1),
    webp: info.string(2),
    timestamp: gift.integer(10),
  )?.withUserId(top.integer(1));
}

/// COMBO_SEND：连击结束，total_num 是这次连击一共送了多少个，
/// combo_total_coin 是总价（没有单价）
LiveGiftMessage? parseBiliComboSend(Map data) {
  var giftName = _str(data["gift_name"]);
  var comboId = _str(data["batch_combo_id"]).isNotEmpty
      ? _str(data["batch_combo_id"])
      : _str(data["combo_id"]);
  if (giftName.isEmpty || comboId.isEmpty) {
    return null;
  }
  var count = _int(data["total_num"]);
  if (count <= 0) {
    count = _int(data["batch_combo_num"]) > 0
        ? _int(data["batch_combo_num"])
        : _int(data["combo_num"]);
  }
  var sender = _map(_map(data["sender_uinfo"])["base"]);
  var info = _map(data["gift_info"]);
  var coin = _int(data["combo_total_coin"]);
  var paid = _str(data["coin_type"]) != "silver" && coin > 0;
  return LiveGiftMessage(
    comboId: comboId,
    userName: _str(data["uname"]).isNotEmpty
        ? _str(data["uname"])
        : _str(sender["name"]),
    face: _biliFace(_str(sender["face"])),
    action: _str(data["action"]).isNotEmpty ? _str(data["action"]) : "投喂",
    giftName: giftName,
    icon: _biliGiftIcon(giftName, _str(info["img_basic"]), _str(info["webp"])),
    count: count > 0 ? count : 1,
    paid: paid,
    priceText: paid ? biliPriceText(coin) : null,
    comboEnd: true,
  );
}

/// GUARD_BUY：guard_level 1 总督、2 提督、3 舰长；num 是月数，price 是每月的金瓜子。
/// 分不出开通还是续费，先写“上舰”，提示消息到了再改（[BiliGuardMerger]）
LiveGiftMessage? parseBiliGuardBuy(Map data) {
  return _biliGuard(
    level: _int(data["guard_level"]),
    name: _str(data["gift_name"]),
    userName: _str(data["username"]),
    num: _int(data["num"]),
    price: _int(data["price"]),
    start: _int(data["start_time"]),
    action: "上舰",
  );
}

/// USER_TOAST_MSG（旧版）：toast_msg 是“…开通了舰长…”“…续费了舰长…”，
/// op_type 1 开通、2 续费、3 自动续费
LiveGiftMessage? parseBiliUserToast(Map data) {
  return _biliGuard(
    level: _int(data["guard_level"]),
    name: _str(data["role_name"]),
    userName: _str(data["username"]),
    num: _int(data["num"]),
    price: _int(data["price"]),
    unit: _str(data["unit"]),
    start: _int(data["start_time"]),
    action: biliGuardAction(_str(data["toast_msg"]), _int(data["op_type"])),
  );
}

/// USER_TOAST_MSG_V2：sender_uinfo、guard_info、pay_info、option 分开放；
/// option.source 为 2 的是紧跟着的赠送提示（官方评论栏也不显示），不要
LiveGiftMessage? parseBiliUserToastV2(Map data) {
  if (_int(_map(data["option"])["source"]) == 2) {
    return null;
  }
  var sender = _map(data["sender_uinfo"]);
  var guard = _map(data["guard_info"]);
  var pay = _map(data["pay_info"]);
  return _biliGuard(
    level: _int(guard["guard_level"]),
    name: _str(guard["role_name"]),
    userName: _str(_map(sender["base"])["name"]),
    face: _str(_map(sender["base"])["face"]),
    num: _int(pay["num"]),
    price: _int(pay["price"]),
    unit: _str(pay["unit"]),
    start: _int(guard["start_time"]),
    action: biliGuardAction(
      _str(data["toast_msg"]),
      _int(_map(data["option"])["op_type"]),
    ),
  );
}

/// 提示文字里的动作：自动续费、续费、开通；都没有时按 op_type，再没有就是“上舰”
String biliGuardAction(String toast, int opType) {
  if (toast.contains("自动续费")) {
    return "自动续费";
  }
  if (toast.contains("续费")) {
    return "续费";
  }
  if (toast.contains("开通")) {
    return "开通";
  }
  return switch (opType) {
    1 => "开通",
    2 => "续费",
    3 => "自动续费",
    _ => "上舰",
  };
}

LiveGiftMessage? _biliGuard({
  required int level,
  required String name,
  required String userName,
  String face = "",
  required int num,
  required int price,
  String unit = "",
  required int start,
  required String action,
}) {
  if (name.isEmpty) {
    name = const {1: "总督", 2: "提督", 3: "舰长"}[level] ?? "";
  }
  if (name.isEmpty) {
    return null;
  }
  var months = num > 0 ? num : 1;
  return LiveGiftMessage(
    // 同一次上舰的 GUARD_BUY 和提示消息开始时间相同
    comboId: start > 0 ? "guard:$level:$start" : null,
    userName: userName,
    face: face.isEmpty ? "" : "$face@100w.jpg",
    action: action,
    giftName: name,
    icon: biliGuardIcon(level, name),
    count: months,
    paid: true,
    priceText: price > 0
        ? "${biliPriceText(price * months)}"
              "${unit.isNotEmpty && unit != "月" ? " · $unit" : ""}"
        : null,
    time: start > 0 ? DateTime.fromMillisecondsSinceEpoch(start * 1000) : null,
  );
}

/// 大航海的徽章（直播间里舰长、提督、总督用的同一套）：1 总督、2 提督、3 舰长
LiveEmote? biliGuardIcon(int level, String name) {
  if (level < 1 || level > 3) {
    return null;
  }
  return LiveEmote(
    text: name,
    url:
        "https://i0.hdslb.com/bfs/activity-plat/static/20200716/"
        "1d0c5a1b042efb59f46d4ba1286c6727/icon-guard$level.png",
    width: 1,
    height: 1,
  );
}

/// 同一次上舰会来两条：GUARD_BUY（分不出开通、续费）和提示消息（分得出），先后不定。
/// 提示先到时，后来的 GUARD_BUY 不再发；GUARD_BUY 先到时先发“上舰”，
/// 提示到了再发一次同一个 comboId 的“开通/续费”，界面上替换成这一条
class BiliGuardMerger {
  final Map<String, String> _actions = {};

  /// 返回要发出的消息，不用发时返回 null
  LiveGiftMessage? merge(LiveGiftMessage gift, {required bool fromToast}) {
    var key = gift.comboId;
    if (key == null) {
      return gift;
    }
    var known = _actions[key];
    if (fromToast) {
      _remember(key, gift.action);
      return known == gift.action ? null : gift;
    }
    if (known != null) {
      return null;
    }
    _remember(key, gift.action);
    return gift;
  }

  void _remember(String key, String action) {
    _actions.remove(key);
    _actions[key] = action;
    while (_actions.length > 100) {
      _actions.remove(_actions.keys.first);
    }
  }
}

/// 金瓜子换成人民币文字：100 → “¥0.1”，52000 → “¥52”
String biliPriceText(int gold) {
  var yuan = gold / 1000;
  if (yuan == yuan.truncateToDouble()) {
    return "¥${yuan.toInt()}";
  }
  var text = yuan.toStringAsFixed(yuan < 0.01 ? 3 : 2);
  return "¥${text.replaceFirst(RegExp(r'0+$'), '')}";
}

LiveGiftMessage? _biliGift({
  required String batchComboId,
  required String tid,
  required String userName,
  required String face,
  required String action,
  required String giftName,
  required int num,
  required int clicks,
  required int price,
  required String coinType,
  required String imgBasic,
  required String webp,
  required int timestamp,
}) {
  if (giftName.isEmpty) {
    return null;
  }
  // 连击时 num 是每下的个数，super_gift_num 是连击到第几下
  var count = (num > 0 ? num : 1) * (clicks > 0 ? clicks : 1);
  var paid = coinType != "silver" && price > 0;
  return LiveGiftMessage(
    comboId: batchComboId.isNotEmpty
        ? batchComboId
        : (tid.isNotEmpty ? "tid:$tid" : null),
    userName: userName,
    face: _biliFace(face),
    action: action.isNotEmpty ? action : "投喂",
    giftName: giftName,
    icon: _biliGiftIcon(giftName, imgBasic, webp),
    count: count,
    paid: paid,
    priceText: paid ? biliPriceText(price * count) : null,
    time: timestamp > 0
        ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000)
        : null,
  );
}

/// 礼物图片：webp 是动图，img_basic 是静态的 png（都是正方形）
LiveEmote? _biliGiftIcon(String name, String imgBasic, String webp) {
  var animated = liveEmoteUrl(webp);
  var still = liveEmoteUrl(imgBasic);
  if (animated.isEmpty && still.isEmpty) {
    return null;
  }
  return LiveEmote(
    text: name,
    url: animated.isNotEmpty ? animated : still,
    staticUrl: animated.isNotEmpty && still.isNotEmpty ? still : null,
    width: 1,
    height: 1,
  );
}

/// 头像加上缩略图后缀（原图可能很大）
String _biliFace(String face) {
  var url = liveEmoteUrl(face);
  if (url.isEmpty || url.contains("@")) {
    return url;
  }
  return "$url@100w.jpg";
}

Map _map(dynamic value) => value is Map ? value : const {};

String _str(dynamic value) => value?.toString() ?? "";

int _int(dynamic value) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? "") ?? 0;
}

/// protobuf 的一层字段（没有 .proto 时按字段号读）：
/// varint 为 Int64，长度分隔的为字节，fixed32/fixed64 保留原值
class _PbFields {
  final Map<int, List<Object>> _fields;
  const _PbFields._(this._fields);

  static const _PbFields empty = _PbFields._({});

  factory _PbFields.parse(List<int> bytes) {
    var fields = <int, List<Object>>{};
    var reader = CodedBufferReader(bytes);
    while (!reader.isAtEnd()) {
      var tag = reader.readTag();
      Object value = switch (tag & 7) {
        0 => reader.readUint64(),
        1 => reader.readFixed64(),
        2 => reader.readBytes(),
        5 => reader.readFixed32(),
        _ => throw FormatException("protobuf wire type ${tag & 7}"),
      };
      fields.putIfAbsent(tag >> 3, () => []).add(value);
    }
    return _PbFields._(fields);
  }

  Object? _first(int field) => _fields[field]?.first;

  int integer(int field) {
    var value = _first(field);
    return value is Int64 ? value.toInt() : (value is int ? value : 0);
  }

  String string(int field) {
    var value = _first(field);
    return value is List<int> ? utf8.decode(value, allowMalformed: true) : "";
  }

  /// 嵌套的消息，没有或解析失败时为空
  _PbFields message(int field) {
    var value = _first(field);
    if (value is! List<int>) {
      return empty;
    }
    try {
      return _PbFields.parse(value);
    } catch (_) {
      return empty;
    }
  }
}
