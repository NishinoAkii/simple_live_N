import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// 哔哩哔哩直播的观看时长心跳（网页播放器的 x25Kn）。
///
/// 网页进直播间后先发一次 E，之后按服务器给的间隔（一般 60 秒）发 X。平台用它算
/// “观看时长”：粉丝团的观看任务、活动里的观看时长任务都看这个。只拉视频流不发它，
/// 平台就不算在看。
///
/// 做法和 andywang425/BLTH、mi0e/BiliBiliDropsMiner、lkeme/BiliHelper-personal
/// 一致（2026 年 10 月都还在更新）：
/// - E、X 都是 POST，参数放在地址里并做 WBI 签名，请求体为空；
/// - X 的 s 是把一段 JSON 按 secret_rule 连着做几次 HMAC（密钥是 secret_key），
///   每一步的十六进制小写结果作为下一步的输入；
/// - id 里的序号 E 是 0，之后每发一次 X 加一；ets、secret_key、secret_rule 用上一次返回的。
class BiliWatchHeart {
  BiliWatchHeart._();

  static const String enterUrl =
      "https://live-trace.bilibili.com/xlive/data-interface/v1/x25Kn/E";
  static const String beatUrl =
      "https://live-trace.bilibili.com/xlive/data-interface/v1/x25Kn/X";

  /// secret_rule 里的数字对应的算法
  static Hash? hashOf(int rule) => switch (rule) {
    0 => md5,
    1 => sha1,
    2 => sha256,
    3 => sha224,
    4 => sha512,
    5 => sha384,
    _ => null,
  };

  /// X 心跳的签名 s。[secretRule] 里有不认识的算法时抛 [BiliHeartRuleError]
  static String sign({
    required int parentAreaId,
    required int areaId,
    required int seq,
    required int roomId,
    required String buvid,
    required String uuid,
    required int ets,
    required int time,
    required int ts,
    required String secretKey,
    required List<int> secretRule,
  }) {
    // 键的顺序不能变，服务器按同样的顺序重算
    var text = jsonEncode({
      "platform": "web",
      "parent_id": parentAreaId,
      "area_id": areaId,
      "seq_id": seq,
      "room_id": roomId,
      "buvid": buvid,
      "uuid": uuid,
      "ets": ets,
      "time": time,
      "ts": ts,
    });
    var key = utf8.encode(secretKey);
    for (var rule in secretRule) {
      var hash = hashOf(rule);
      if (hash == null) {
        throw BiliHeartRuleError(rule);
      }
      text = Hmac(hash, key).convert(utf8.encode(text)).toString();
    }
    return text;
  }

  static String _id(BiliHeartRoom room, int seq) =>
      jsonEncode([room.parentAreaId, room.areaId, seq, room.roomId]);

  static String _device(String buvid, String uuid) => jsonEncode([buvid, uuid]);

  /// E（进入直播间）的参数，还没做 WBI 签名
  static Map<String, String> enterParams({
    required BiliHeartRoom room,
    required String buvid,
    required String uuid,
    required int ts,
    required String userAgent,
    required String csrf,
  }) => {
    "id": _id(room, 0),
    "device": _device(buvid, uuid),
    "ruid": "${room.anchorUid}",
    "ts": "$ts",
    "is_patch": "0",
    "heart_beat": "[]",
    "ua": userAgent,
    "web_location": "444.8",
    "csrf": csrf,
  };

  /// X（之后每次心跳）的参数，还没做 WBI 签名。序号是 [state] 的序号加一
  static Map<String, String> beatParams({
    required BiliHeartRoom room,
    required BiliHeartState state,
    required String buvid,
    required String uuid,
    required int ts,
    required String userAgent,
    required String csrf,
  }) {
    var seq = state.seq + 1;
    return {
      "s": sign(
        parentAreaId: room.parentAreaId,
        areaId: room.areaId,
        seq: seq,
        roomId: room.roomId,
        buvid: buvid,
        uuid: uuid,
        ets: state.ets,
        time: state.interval,
        ts: ts,
        secretKey: state.secretKey,
        secretRule: state.secretRule,
      ),
      "id": _id(room, seq),
      "device": _device(buvid, uuid),
      "ruid": "${room.anchorUid}",
      "ets": "${state.ets}",
      "benchmark": state.secretKey,
      "time": "${state.interval}",
      "ts": "$ts",
      "ua": userAgent,
      "trackid": "-99998",
      "web_location": "444.8",
      "csrf": csrf,
    };
  }

  /// 没有 LIVE_BUVID 这个 Cookie 时自己生成一个：AUTO 加 16 位数字，和网页拿到的格式一样
  static String newLiveBuvid([Random? random]) {
    var r = random ?? Random.secure();
    var digits = List.generate(16, (_) => r.nextInt(10)).join();
    return "AUTO$digits";
  }

  /// 随机的 UUID（第 4 版），每次进直播间新生成一个
  static String newUuid([Random? random]) {
    var r = random ?? Random.secure();
    var bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    var hex = bytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
    return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-"
        "${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}";
  }
}

/// 心跳里要的直播间信息：真实房间号、分区和主播的 uid
class BiliHeartRoom {
  final int roomId;
  final int parentAreaId;
  final int areaId;
  final int anchorUid;
  const BiliHeartRoom({
    required this.roomId,
    required this.parentAreaId,
    required this.areaId,
    required this.anchorUid,
  });

  /// 没设分区的直播间心跳不算数
  bool get valid => roomId > 0 && parentAreaId > 0 && areaId > 0;
}

/// E、X 返回的东西，下一次 X 要用
class BiliHeartState {
  /// 已经发到第几次（E 是 0）
  final int seq;

  /// 服务器的时间戳（秒），下一次 X 的 ets
  final int ets;

  /// 多少秒后发下一次，也是下一次 X 的 time
  final int interval;
  final String secretKey;
  final List<int> secretRule;

  const BiliHeartState({
    required this.seq,
    required this.ets,
    required this.interval,
    required this.secretKey,
    required this.secretRule,
  });

  static int _int(dynamic value) =>
      value is num ? value.toInt() : int.tryParse("$value") ?? 0;

  static List<int>? _rule(dynamic value) =>
      value is List && value.isNotEmpty ? value.map(_int).toList() : null;

  /// E 的返回（整个 JSON）。code 不是 0 或缺东西时抛 [BiliHeartError]
  factory BiliHeartState.fromEnter(dynamic json) {
    var data = _check(json);
    var key = data["secret_key"]?.toString() ?? "";
    var rule = _rule(data["secret_rule"]);
    var ets = _int(data["timestamp"]);
    if (key.isEmpty || rule == null || ets <= 0) {
      throw const BiliHeartError(0, "心跳返回的内容不完整");
    }
    var interval = _int(data["heartbeat_interval"]);
    return BiliHeartState(
      seq: 0,
      ets: ets,
      interval: interval > 0 ? interval : 60,
      secretKey: key,
      secretRule: rule,
    );
  }

  /// X 的返回（整个 JSON）：序号加一，返回里有的换成新的
  BiliHeartState next(dynamic json) {
    var data = _check(json);
    var key = data["secret_key"]?.toString() ?? "";
    var ets = _int(data["timestamp"]);
    var interval = _int(data["heartbeat_interval"]);
    return BiliHeartState(
      seq: seq + 1,
      ets: ets > 0 ? ets : this.ets,
      interval: interval > 0 ? interval : this.interval,
      secretKey: key.isNotEmpty ? key : secretKey,
      secretRule: _rule(data["secret_rule"]) ?? secretRule,
    );
  }

  static Map _check(dynamic json) {
    if (json is! Map) {
      throw const BiliHeartError(0, "心跳返回的内容不完整");
    }
    var code = _int(json["code"]);
    if (code != 0) {
      throw BiliHeartError(
        code,
        (json["message"] ?? json["msg"] ?? "").toString(),
      );
    }
    var data = json["data"];
    return data is Map ? data : const {};
  }
}

/// secret_rule 里有不认识的算法
class BiliHeartRuleError implements Exception {
  final int rule;
  const BiliHeartRuleError(this.rule);

  @override
  String toString() => "secret_rule $rule";
}

/// 心跳接口返回了错误
class BiliHeartError implements Exception {
  final int code;
  final String message;
  const BiliHeartError(this.code, this.message);

  /// -101：账号未登录
  bool get notLoggedIn => code == -101;

  @override
  String toString() => "$message($code)";
}

/// WBI 签名：加上 wts，按键排序，值里去掉 !'()* 后拼成地址参数，接上 [mixinKey] 取 MD5。
///
/// 返回去掉了那几个字符的参数加 w_rid、wts（网页也是这样发的）。和
/// BiliBiliSite.getWbiSign 的差别：空格编成 %20。这里的 ua 里有空格，编成加号的话签名对不上
Map<String, String> biliWbiSigned(
  Map<String, String> params, {
  required String mixinKey,
  required int wts,
}) {
  var filter = RegExp(r"[!'()*]");
  var clean = {
    for (var entry in params.entries)
      entry.key: entry.value.replaceAll(filter, ""),
  };
  var all = {...clean, "wts": "$wts"};
  var keys = all.keys.toList()..sort();
  var query = keys
      .map(
        (key) =>
            "${Uri.encodeComponent(key)}=${Uri.encodeComponent(all[key]!)}",
      )
      .join("&");
  return {
    ...clean,
    "w_rid": md5.convert(utf8.encode("$query$mixinKey")).toString(),
    "wts": "$wts",
  };
}
