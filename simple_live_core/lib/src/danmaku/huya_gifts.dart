import 'dart:async';
import 'dart:collection';

import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/tars/huya_gift.dart';
import 'package:simple_live_core/src/model/tars/huya_user_id.dart';
import 'package:tars_dart/tars/net/base_tars_http.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 虎牙的礼物。
///
/// 送礼广播（uri 6501）里有礼物 id、数量、连击和送礼人头像，新版还有礼物名称；
/// 图片和价格从直播间的道具列表（PropsUIServer.getPropsList，匿名即可）查。

/// 一个礼物的名称、图片和价格
class HuyaGiftInfo {
  final String name;

  /// 图片地址，没有时为空
  final String icon;

  /// 单价，单位是分（1 虎牙币 = 1 元 = 100）
  final int price;

  const HuyaGiftInfo({required this.name, this.icon = "", this.price = 0});
}

/// 道具图片字段的值形如“地址&md5”，取地址
String _huyaPicUrl(String value) {
  var i = value.indexOf("&");
  return liveEmoteUrl(i < 0 ? value : value.substring(0, i));
}

/// 道具列表 → 礼物 id → [HuyaGiftInfo]。
///
/// 图片优先用 sPropsPic108（png），其次网页端的 sPropsWeb、sPropsPic24
Map<int, HuyaGiftInfo> parseHuyaPropsList(List<HuyaPropsItem> items) {
  var map = <int, HuyaGiftInfo>{};
  for (var item in items) {
    if (item.iPropsId <= 0 || item.sPropsName.isEmpty) {
      continue;
    }
    var icon = "";
    for (var id in item.vPropsIdentity) {
      for (var pic in [id.sPropsPic108, id.sPropsWeb, id.sPropsPic24]) {
        if (icon.isEmpty && pic.isNotEmpty) {
          icon = _huyaPicUrl(pic);
        }
      }
    }
    map.putIfAbsent(
      item.iPropsId,
      () =>
          HuyaGiftInfo(name: item.sPropsName, icon: icon, price: item.iPropsYb),
    );
  }
  return map;
}

/// 价值的文字：分 →“¥1.5”
String huyaYuanText(int cents) {
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

/// 没有连击 id（lComboSeqId 为 0）的消息自己合并：同一个人送同一个礼物，
/// 和上一条隔不到 [kWindow] 就算同一个连击，数量累加。
/// 实测盲盒送出的虎粮是这样：每次 ×6、组号都是 1、内容完全相同，
/// 一个人一分钟能送几十次，不合并会刷屏
class HuyaGiftCombos {
  static const Duration kWindow = Duration(seconds: 30);

  /// key → (连击序号, 累计数量, 上一条的组号, 上一条的时间)
  final Map<String, (int, int, int, DateTime)> _combos = {};
  int _next = 0;

  /// 记下这一条，返回连击 id 和到目前为止的总数。
  /// 组号比上一条大时只加多出来的组（中间缺的消息也算上），否则是又送了一次
  (String, int) add(String key, int each, int group, DateTime time) {
    var last = _combos[key];
    (int, int, int, DateTime) next;
    if (last == null || time.difference(last.$4) >= kWindow) {
      next = (_next++, each * group, group, time);
    } else {
      var groups = group > last.$3 ? group - last.$3 : group;
      next = (last.$1, last.$2 + each * groups, group, time);
    }
    _combos[key] = next;
    if (_combos.length > 500) {
      var old = _combos.entries
          .where((e) => time.difference(e.value.$4) >= kWindow)
          .map((e) => e.key)
          .toList();
      for (var k in old) {
        _combos.remove(k);
      }
    }
    return ("$key:s${next.$1}", next.$2);
  }
}

/// 把送礼广播解析成 [LiveGiftMessage]。
///
/// - 有连击 id（lComboSeqId）时：数量是这一组的个数 × 组号（连送的第几组），
///   即到目前为止的总数（匿名连接收到的连送消息有缺，按条累加会少）；
/// - 没有连击 id 时由 [combos] 合并、累加；没给 [combos] 时每条单独算；
/// - 付费：看消息里的实付金额（lPayTotal）。同一个虎粮用银豆送是 0，
///   用虎牙币买的是 10；超粉虎粮、贵族的热火这类免费礼物也是 0；
/// - 价值：单价（道具列表，没查到时用实付金额 ÷ 这一组的个数）× 总数；
/// - 名称：消息里的 sPropsName，其次道具列表，都没有时为“礼物”
LiveGiftMessage? parseHuyaGift(
  HuyaSendItemPacket packet, {
  HuyaGiftInfo? info,
  HuyaGiftCombos? combos,
  DateTime? now,
}) {
  if (packet.iItemType <= 0 || packet.sSenderNick.isEmpty) {
    return null;
  }
  var time = now ?? DateTime.now();
  var each = packet.iItemCount > 0
      ? packet.iItemCount
      : (packet.iItemCountByGroup > 0 ? packet.iItemCountByGroup : 1);
  var group = packet.iItemGroup > 0 ? packet.iItemGroup : 1;
  var key =
      "huya:${packet.lPresenterUid}:${packet.lSenderUid}:${packet.iItemType}";
  var count = each * group;
  String? comboId;
  if (packet.lComboSeqId > 0) {
    comboId = "$key:${packet.lComboSeqId}";
  } else if (combos != null) {
    (comboId, count) = combos.add(key, each, group, time);
  }
  var name = packet.sPropsName.isNotEmpty
      ? packet.sPropsName
      : (info?.name ?? "");
  if (name.isEmpty) {
    name = "礼物";
  }
  var paid = packet.lPayTotal > 0;
  String? priceText;
  if (paid) {
    var unit = info != null && info.price > 0
        ? info.price
        : packet.lPayTotal ~/ each;
    if (unit > 0) {
      priceText = huyaYuanText(unit * count);
    }
  }
  return LiveGiftMessage(
    comboId: comboId,
    userName: packet.sSenderNick,
    face: liveEmoteUrl(packet.sSenderIcon),
    action: "送出",
    giftName: name,
    icon: info == null || info.icon.isEmpty
        ? null
        : LiveEmote(text: name, url: info.icon),
    count: count,
    paid: paid,
    priceText: priceText,
    time: time,
    userId: liveUserId(packet.lSenderUid),
  );
}

/// 虎牙直播间的道具列表，按主播 uid 缓存：每个直播间读一次（约 1 MB），
/// 1 小时后过期，失败后 10 分钟内不再请求；最多缓存 [kMaxRooms] 个直播间
class HuyaRoomGifts {
  HuyaRoomGifts._();

  static const int kMaxRooms = 20;
  static const Duration _ttl = Duration(hours: 1);
  static const Duration _retryAfter = Duration(minutes: 10);

  static final LinkedHashMap<int, (DateTime, Map<int, HuyaGiftInfo>)> _rooms =
      LinkedHashMap();
  static final Map<int, Future<void>> _loading = {};
  static final Map<int, DateTime> _failedAt = {};

  /// 测试用：替换网络请求
  static Future<List<HuyaPropsItem>> Function(int presenterUid)? debugFetch;

  static BaseTarsHttp? _client;

  /// 和网页端一样匿名请求 PropsUIServer.getPropsList（PC 模板）
  static Future<List<HuyaPropsItem>> _fetch(int presenterUid) async {
    if (debugFetch != null) {
      return debugFetch!(presenterUid);
    }
    var client = _client ??= BaseTarsHttp(
      "https://wup.huya.com",
      "PropsUIServer",
      headers: {
        "Origin": "https://www.huya.com",
        "Referer": "https://www.huya.com/",
        "User-Agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
      },
    );
    var req = HuyaGetPropsListReq()
      ..tUserId = (HuyaUserId()..sHuYaUA = "webh5&2610260926&websocket")
      ..iTemplateType = 64
      ..lPresenterUid = presenterUid;
    var resp = await client.tupRequest(
      "getPropsList",
      req,
      HuyaGetPropsListRsp(),
    );
    return resp.vPropsItemList;
  }

  /// 读取直播间的道具列表（已读到、正在读或刚失败过时不重复请求）
  static Future<void> load(int presenterUid) {
    if (presenterUid <= 0) {
      return Future.value();
    }
    var cached = _rooms[presenterUid];
    if (cached != null && DateTime.now().difference(cached.$1) < _ttl) {
      return Future.value();
    }
    var failed = _failedAt[presenterUid];
    if (failed != null && DateTime.now().difference(failed) < _retryAfter) {
      return Future.value();
    }
    return _loading[presenterUid] ??= () async {
      try {
        var gifts = parseHuyaPropsList(await _fetch(presenterUid));
        if (gifts.isEmpty) {
          throw StateError("虎牙道具列表是空的".t);
        }
        _rooms.remove(presenterUid);
        _rooms[presenterUid] = (DateTime.now(), gifts);
        _failedAt.remove(presenterUid);
        while (_rooms.length > kMaxRooms) {
          _rooms.remove(_rooms.keys.first);
        }
      } catch (e) {
        CoreLog.error(e);
        _failedAt[presenterUid] = DateTime.now();
      } finally {
        _loading.remove(presenterUid);
      }
    }();
  }

  /// 直播间的道具列表，还没读到时为 null
  static Map<int, HuyaGiftInfo>? of(int presenterUid) =>
      _rooms[presenterUid]?.$2;

  /// 测试用：直接设置直播间的道具列表
  static void debugSet(int presenterUid, Map<int, HuyaGiftInfo> gifts) {
    _rooms[presenterUid] = (DateTime.now(), gifts);
  }

  /// 测试用：清空缓存和请求替换
  static void debugReset() {
    _rooms.clear();
    _loading.clear();
    _failedAt.clear();
    debugFetch = null;
  }
}
