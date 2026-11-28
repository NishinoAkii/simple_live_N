import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/danmaku/douyu_aside.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 斗鱼的礼物。
///
/// 送礼消息（dgb）里有礼物 id（gfid）、名称（gfn）和数量，没有图片和价格：
/// - 直接用鱼翅、鱼丸买的礼物（from=1）查房间的礼物列表 [DouyuRoomGifts]；
/// - 背包里的道具（from=2，荧光棒这类）按道具 id（pid）查 [DouyuPropGifts]，
///   gfid 可能是 0。

const String _browserUserAgent =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

/// 一个礼物的名称、图片和价格
class DouyuGiftInfo {
  final String name;

  /// 图片地址，没有时为空
  final String icon;

  /// 单价：鱼翅礼物是分（1 鱼翅 = 1 元 = 100），鱼丸礼物是鱼丸数
  final int price;

  /// 鱼丸礼物（免费的）
  final bool yuwan;

  /// 付费礼物：鱼翅礼物、背包里的贵重道具
  final bool paid;

  const DouyuGiftInfo({
    required this.name,
    this.icon = "",
    this.price = 0,
    this.yuwan = false,
    this.paid = true,
  });
}

String _picUrl(dynamic prefix, dynamic path) {
  var p = path?.toString() ?? "";
  if (p.isEmpty) {
    return "";
  }
  if (p.startsWith("http") || p.startsWith("//")) {
    return liveEmoteUrl(p);
  }
  var base = prefix?.toString() ?? "";
  if (base.isEmpty) {
    base = "https://gfs-op.douyucdn.cn/dygift";
  }
  return liveEmoteUrl("$base$p");
}

dynamic _decode(dynamic result) =>
    result is String ? json.decode(result) : result;

/// 房间的礼物列表（gift/v3/web/list）→ 礼物 id → [DouyuGiftInfo]。
/// priceInfo.priceType 是 YUCHI（鱼翅，付费）或 YUWAN（鱼丸，免费）
Map<String, DouyuGiftInfo> parseDouyuRoomGiftList(dynamic result) {
  var map = <String, DouyuGiftInfo>{};
  var list = _decode(result)?["data"]?["giftList"];
  if (list is! List) {
    return map;
  }
  for (var item in list) {
    if (item is! Map) {
      continue;
    }
    var id = item["id"]?.toString() ?? "";
    var name = item["name"]?.toString() ?? "";
    if (id.isEmpty || name.isEmpty) {
      continue;
    }
    var priceInfo = item["priceInfo"];
    var yuwan = priceInfo is Map && priceInfo["priceType"] == "YUWAN";
    var basic = item["basicInfo"];
    map[id] = DouyuGiftInfo(
      name: name,
      icon: _picUrl(
        item["picUrlPrefix"],
        basic is Map ? basic["giftPic"] : null,
      ),
      price: int.tryParse("${priceInfo is Map ? priceInfo["price"] : ""}") ?? 0,
      yuwan: yuwan,
      paid: !yuwan,
    );
  }
  return map;
}

/// 背包道具（prop/v1/web/single）→ [DouyuGiftInfo]。
/// isValuable=1 是贵重道具（用钱买的），0 是荧光棒这类做任务送的，算免费
DouyuGiftInfo? parseDouyuPropSingle(dynamic result) {
  var data = _decode(result)?["data"];
  if (data is! Map) {
    return null;
  }
  var name = data["name"]?.toString() ?? "";
  if (name.isEmpty) {
    return null;
  }
  var valuable = "${data["isValuable"]}" == "1";
  return DouyuGiftInfo(
    name: name,
    icon: _picUrl(data["picUrlPrefix"], data["propPic"]),
    price: int.tryParse("${data["price"]}") ?? 0,
    paid: valuable,
  );
}

/// 价值的文字：鱼翅（分）→“¥1.5”
String douyuYuanText(int cents) {
  var yuan = cents ~/ 100;
  var rest = cents % 100;
  if (rest == 0) {
    return "¥$yuan";
  }
  var text = rest.toString().padLeft(2, "0");
  if (text.endsWith("0")) {
    text = text.substring(0, 1);
  }
  return "¥$yuan.$text";
}

/// 用户头像：ic 形如“avatar_v3/202310/c42e…”（STT 里的 @S 已还原为 /）
String douyuAvatarUrl(String ic) {
  if (ic.isEmpty) {
    return "";
  }
  if (ic.startsWith("http") || ic.startsWith("//")) {
    return liveEmoteUrl(ic);
  }
  return "https://apic.douyucdn.cn/upload/${ic}_middle.jpg";
}

/// 连击的记录：同一个人连着送同一个礼物，hits 递增
class DouyuGiftCombos {
  /// 超过这么久没有新的一条，下一条算新的连击
  static const Duration kWindow = Duration(minutes: 2);

  final Map<String, (int, int, DateTime)> _combos = {};
  int _next = 0;

  /// 返回这一条的连击 id：hits 比上一条大且没有隔太久时沿用，否则开新的
  String comboId(String key, int hits, DateTime time) {
    var last = _combos[key];
    int seq;
    if (last != null && hits > last.$2 && time.difference(last.$3) < kWindow) {
      seq = last.$1;
    } else {
      seq = _next++;
    }
    _combos[key] = (seq, hits, time);
    if (_combos.length > 500) {
      // 只留最近的
      var old = _combos.entries
          .where((e) => time.difference(e.value.$3) >= kWindow)
          .map((e) => e.key)
          .toList();
      for (var k in old) {
        _combos.remove(k);
      }
    }
    return "$key:$seq";
  }
}

/// 把一条 dgb 消息解析成 [LiveGiftMessage]。
///
/// - [info]：查到的礼物信息，没查到时用消息里的 gfn，没有图片；
///   没查到的背包道具按免费算，其他按付费算；
/// - 数量用 hits：连击到目前为止的总数（gfcnt 是这一下送的个数，
///   匿名连接收到的连击消息有缺，按 gfcnt 累加会少）；
/// - [combos] 给出连击 id，没有时每条单独算
LiveGiftMessage? parseDouyuGift(
  Map msg, {
  DouyuGiftInfo? info,
  DouyuGiftCombos? combos,
  DateTime? now,
}) {
  var gfid = msg["gfid"]?.toString() ?? "";
  var pid = msg["pid"]?.toString() ?? "";
  if ((gfid.isEmpty || gfid == "0") && pid.isEmpty) {
    return null;
  }
  var time = now ?? DateTime.now();
  var gfcnt = int.tryParse("${msg["gfcnt"]}") ?? 1;
  var hits = int.tryParse("${msg["hits"]}") ?? 0;
  var count = hits > 0 ? hits : (gfcnt > 0 ? gfcnt : 1);
  var backpack = "${msg["from"]}" == "2" && pid.isNotEmpty;
  var name = msg["gfn"]?.toString() ?? "";
  if (name.isEmpty) {
    name = info?.name ?? "";
  }
  if (name.isEmpty) {
    name = "礼物";
  }
  var paid = info?.paid ?? !backpack;
  String? priceText;
  if (info != null && info.price > 0) {
    if (info.yuwan) {
      priceText = "{p} 鱼丸".tf({"p": info.price * count});
    } else if (paid) {
      priceText = douyuYuanText(info.price * count);
    }
  }
  var uid = msg["uid"]?.toString() ?? "";
  var key = "douyu:${msg["rid"] ?? ""}:$uid:$gfid:${backpack ? pid : ""}";
  return LiveGiftMessage(
    comboId: combos?.comboId(key, count, time),
    userName: msg["nn"]?.toString() ?? "",
    face: douyuAvatarUrl(msg["ic"]?.toString() ?? ""),
    action: "赠送",
    giftName: name,
    icon: info == null || info.icon.isEmpty
        ? null
        : LiveEmote(text: name, url: info.icon),
    count: count,
    paid: paid,
    priceText: priceText,
    time: time,
    userId: liveUserId(uid),
  );
}

/// 贵族等级（nl）
const Map<String, String> kDouyuNobleLevels = {
  "1": "骑士",
  "2": "子爵",
  "3": "伯爵",
  "4": "公爵",
  "5": "国王",
  "6": "皇帝",
  "7": "游侠",
};

/// 网页端聊天栏用的贵族徽章（live-next-player-aside 的图片，按 nl 等级）。
/// 文件名带版本号：优先用 [DouyuAside] 从当前网页扫到的“noble-levelN”，
/// 扫不到时才用这里（2026-11-13 的版本）
const Map<String, String> kDouyuNobleIcons = {
  "1": "noble-level1_1b45cf2.png",
  "2": "noble-level2_a54f50c.png",
  "3": "noble-level3_ad8828c.png",
  "4": "noble-level4_9887096.png",
  "5": "noble-level5_098f64b.png",
  "6": "noble-level6_fd2b69e.gif",
  "7": "noble-level7_93e7f66.png",
  "8": "noble-level8_d3b246c.png",
  "9": "noble-level9_e1a95f1.png",
};

const String _douyuAsideImages =
    "https://shark2.douyucdn.cn/front-publish/live-next-player-aside-master/assets/images/";

/// 钻粉徽章（网页端聊天栏的钻石图标）：当前网页扫到的“diamond-icon”，扫不到时用内置的
LiveEmote douyuDiamondFansIcon() => LiveEmote(
  text: "钻粉",
  url:
      DouyuAside.image("diamond-icon") ??
      "${_douyuAsideImages}diamond-icon_0531e5c.png",
  width: 1,
  height: 1,
);

/// 贵族徽章：当前网页扫到的“noble-levelN”（新等级也有），扫不到时用 [kDouyuNobleIcons]
String? douyuNobleIconUrl(String? level) {
  if (level == null || level.isEmpty) {
    return null;
  }
  var file = kDouyuNobleIcons[level];
  return DouyuAside.image("noble-level$level") ??
      (file == null ? null : "$_douyuAsideImages$file");
}

/// 开通贵族（anbc）、续费贵族（rnewbc）→ 付费礼物。
/// 这两种是全站广播，只认在本房间（drid）开通的；价格不知道
LiveGiftMessage? parseDouyuNoble(Map msg, String roomId, {DateTime? now}) {
  var type = msg["type"]?.toString();
  if (type != "anbc" && type != "rnewbc") {
    return null;
  }
  var drid = msg["drid"]?.toString() ?? msg["rid"]?.toString() ?? "";
  if (drid != roomId) {
    return null;
  }
  var nl = msg["nl"]?.toString();
  var level = kDouyuNobleLevels[nl];
  var icon = douyuNobleIconUrl(nl);
  var userName = msg["unk"]?.toString() ?? msg["nn"]?.toString() ?? "";
  if (userName.isEmpty) {
    return null;
  }
  return LiveGiftMessage(
    userName: userName,
    action: type == "anbc" ? "开通" : "续费",
    // 等级的名字（骑士、子爵…）是表里的简体中文，这里拼进名字时翻译
    giftName: level == null ? "贵族" : "贵族{level}".tf({"level": level.t}),
    icon: icon == null
        ? null
        : LiveEmote(text: level ?? "贵族", url: icon, width: 1, height: 1),
    paid: true,
    estimate: douyuNobleEstimate(nl, renew: type == "rnewbc"),
    time: now,
    userId: liveUserId(msg["uid"]),
  );
}

/// 贵族的价格（元），开通和续费：斗鱼没有公布，用网上流传的价格
/// （2024 年前后的说法），只用来排本场礼物榜
const Map<String, (int, int)> kDouyuNoblePrices = {
  "7": (76, 50), // 游侠
  "1": (500, 300), // 骑士
  "2": (1500, 1000), // 子爵
  "3": (5000, 3000), // 伯爵
  "4": (15000, 10000), // 公爵
  "5": (60000, 50000), // 国王
  "6": (120000, 100000), // 皇帝
};

/// 开通或续费贵族 [nl] 的估算价值，如“¥500”；不认得的等级为 null
String? douyuNobleEstimate(String? nl, {required bool renew}) {
  var price = kDouyuNoblePrices[nl];
  if (price == null) {
    return null;
  }
  return "¥${renew ? price.$2 : price.$1}";
}

/// 开通钻粉（dfobc）、续费钻粉（dfrbc）→ 礼物页标出“开通/续费 钻粉”。
/// 钻粉是一个月里给主播送够礼物得到的，不另外花钱，所以不带价格。
/// 带了房间号（rid、drid）且不是本房间的不要
LiveGiftMessage? parseDouyuDiamondFans(
  Map msg,
  String roomId, {
  DateTime? now,
}) {
  var type = msg["type"]?.toString();
  if (type != "dfobc" && type != "dfrbc") {
    return null;
  }
  var rid = msg["rid"]?.toString() ?? msg["drid"]?.toString() ?? "";
  if (rid.isNotEmpty && rid != roomId) {
    return null;
  }
  var userName = [msg["nn"], msg["nick"], msg["nk"], msg["unk"]]
      .map((e) => e?.toString() ?? "")
      .firstWhere((e) => e.isNotEmpty, orElse: () => "");
  if (userName.isEmpty) {
    return null;
  }
  var ic = msg["ic"]?.toString() ?? "";
  return LiveGiftMessage(
    userName: userName,
    face: ic.isEmpty ? "" : douyuAvatarUrl(ic),
    action: type == "dfobc" ? "开通" : "续费",
    giftName: "钻粉",
    icon: douyuDiamondFansIcon(),
    paid: true,
    time: now,
    userId: liveUserId(msg["uid"]),
  );
}

/// 斗鱼房间的礼物列表，按房间号缓存：每个房间读一次，1 小时后过期，
/// 失败后 10 分钟内不再请求；最多缓存 [kMaxRooms] 个房间
class DouyuRoomGifts {
  DouyuRoomGifts._();

  static const String kUrl = "https://gift.douyucdn.cn/api/gift/v3/web/list";
  static const int kMaxRooms = 20;
  static const Duration _ttl = Duration(hours: 1);
  static const Duration _retryAfter = Duration(minutes: 10);

  static final LinkedHashMap<String, (DateTime, Map<String, DouyuGiftInfo>)>
  _rooms = LinkedHashMap();
  static final Map<String, Future<void>> _loading = {};
  static final Map<String, DateTime> _failedAt = {};

  /// 测试用：替换网络请求
  static Future<dynamic> Function(String roomId)? debugFetch;

  static Future<dynamic> _fetch(String roomId) async {
    if (debugFetch != null) {
      return debugFetch!(roomId);
    }
    return HttpClient.instance.getJson(
      kUrl,
      queryParameters: {"rid": roomId},
      header: {
        "Referer": "https://www.douyu.com/$roomId",
        "User-Agent": _browserUserAgent,
      },
    );
  }

  /// 读取房间的礼物列表（已读到、正在读或刚失败过时不重复请求）
  static Future<void> load(String roomId) {
    if (roomId.isEmpty) {
      return Future.value();
    }
    var cached = _rooms[roomId];
    if (cached != null && DateTime.now().difference(cached.$1) < _ttl) {
      return Future.value();
    }
    var failed = _failedAt[roomId];
    if (failed != null && DateTime.now().difference(failed) < _retryAfter) {
      return Future.value();
    }
    return _loading[roomId] ??= () async {
      try {
        var result = _decode(await _fetch(roomId));
        if (result is Map && result["error"] != null && result["error"] != 0) {
          throw StateError("斗鱼礼物列表读取失败：{result}".tf({"result": result["error"]}));
        }
        _rooms.remove(roomId);
        _rooms[roomId] = (DateTime.now(), parseDouyuRoomGiftList(result));
        _failedAt.remove(roomId);
        while (_rooms.length > kMaxRooms) {
          _rooms.remove(_rooms.keys.first);
        }
      } catch (e) {
        CoreLog.error(e);
        _failedAt[roomId] = DateTime.now();
      } finally {
        _loading.remove(roomId);
      }
    }();
  }

  /// 房间的礼物列表，还没读到时为 null
  static Map<String, DouyuGiftInfo>? of(String roomId) => _rooms[roomId]?.$2;

  /// 测试用：直接设置房间的礼物列表
  static void debugSet(String roomId, Map<String, DouyuGiftInfo> gifts) {
    _rooms[roomId] = (DateTime.now(), gifts);
  }

  /// 测试用：清空缓存和请求替换
  static void debugReset() {
    _rooms.clear();
    _loading.clear();
    _failedAt.clear();
    debugFetch = null;
  }
}

/// 背包道具，按道具 id 缓存（各房间通用）：第一次见到时读一次，
/// 失败后 10 分钟内不再请求；最多缓存 [kMaxProps] 个
class DouyuPropGifts {
  DouyuPropGifts._();

  static const String kUrl = "https://gift.douyucdn.cn/api/prop/v1/web/single";
  static const int kMaxProps = 500;
  static const Duration _retryAfter = Duration(minutes: 10);

  static final LinkedHashMap<String, DouyuGiftInfo> _props = LinkedHashMap();
  static final Map<String, Future<DouyuGiftInfo?>> _loading = {};
  static final Map<String, DateTime> _failedAt = {};

  /// 测试用：替换网络请求
  static Future<dynamic> Function(String pid)? debugFetch;

  static Future<dynamic> _fetch(String pid) async {
    if (debugFetch != null) {
      return debugFetch!(pid);
    }
    return HttpClient.instance.getJson(
      kUrl,
      queryParameters: {"pid": pid},
      header: {
        "Referer": "https://www.douyu.com/",
        "User-Agent": _browserUserAgent,
      },
    );
  }

  /// 已读到的道具，没有时为 null
  static DouyuGiftInfo? of(String pid) => _props[pid];

  /// 读取道具（已读到时直接返回，正在读时等同一个请求，刚失败过时返回 null）
  static Future<DouyuGiftInfo?> load(String pid) {
    if (pid.isEmpty) {
      return Future.value(null);
    }
    var cached = _props[pid];
    if (cached != null) {
      return Future.value(cached);
    }
    var failed = _failedAt[pid];
    if (failed != null && DateTime.now().difference(failed) < _retryAfter) {
      return Future.value(null);
    }
    return _loading[pid] ??= () async {
      try {
        var result = _decode(await _fetch(pid));
        if (result is Map && result["error"] != null && result["error"] != 0) {
          throw StateError("斗鱼道具读取失败：{result}".tf({"result": result["error"]}));
        }
        var info = parseDouyuPropSingle(result);
        if (info == null) {
          throw StateError("斗鱼道具读取失败：{pid}".tf({"pid": pid}));
        }
        _props[pid] = info;
        _failedAt.remove(pid);
        while (_props.length > kMaxProps) {
          _props.remove(_props.keys.first);
        }
        return info;
      } catch (e) {
        CoreLog.error(e);
        _failedAt[pid] = DateTime.now();
        return null;
      } finally {
        _loading.remove(pid);
      }
    }();
  }

  /// 测试用：直接设置道具
  static void debugSet(String pid, DouyuGiftInfo info) {
    _props[pid] = info;
  }

  /// 测试用：清空缓存和请求替换
  static void debugReset() {
    _props.clear();
    _loading.clear();
    _failedAt.clear();
    debugFetch = null;
  }
}
