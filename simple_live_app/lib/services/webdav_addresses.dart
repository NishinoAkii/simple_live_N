import 'dart:convert';
import 'dart:math' as math;

import 'package:simple_live_app/modules/sync/remote_sync/webdav/webdav_client.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 用过的一个 WebDAV 服务器地址
class WebDavAddress {
  final String uri;

  /// 备注，比如“家里”“外网”
  final String note;

  /// 加进来、改备注或删掉的时间（毫秒）。两台设备合并时，同一个地址以晚的为准
  final int time;

  /// 最近一次切换到它的时间，列表按它排，最近用的在前
  final int used;

  /// 删掉了：留一条记录，同步到别的设备时那边也删掉
  final bool deleted;

  const WebDavAddress({
    required this.uri,
    this.note = "",
    this.time = 0,
    this.used = 0,
    this.deleted = false,
  });

  String get key => WebDavAddressBook.keyOf(uri);

  /// 显示的名字：有备注用备注
  String get label => note.isEmpty ? uri : note;

  WebDavAddress copyWith({String? note, int? time, int? used, bool? deleted}) =>
      WebDavAddress(
        uri: uri,
        note: note ?? this.note,
        time: time ?? this.time,
        used: used ?? this.used,
        deleted: deleted ?? this.deleted,
      );

  Map<String, dynamic> toJson() => {
        "uri": uri,
        if (note.isNotEmpty) "note": note,
        "t": time,
        if (used > 0) "used": used,
        if (deleted) "del": true,
      };

  static WebDavAddress? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    var uri = json["uri"];
    if (uri is! String || uri.trim().isEmpty) {
      return null;
    }
    int number(Object? value) => value is num ? value.toInt() : 0;
    var note = json["note"];
    return WebDavAddress(
      uri: uri.trim(),
      note: note is String ? note : "",
      time: number(json["t"]),
      used: number(json["used"]),
      deleted: json["del"] == true,
    );
  }
}

/// 换地址的结果
enum WebDavSwitchResult {
  /// 不是 http:// 或 https:// 开头的地址
  invalid,

  /// 连不上（或账号密码在那边不对），没有保存
  offline,

  /// 就是正在用的地址，连得上
  same,

  /// 已经换过去
  switched,
}

/// 用过的 WebDAV 地址和各自的备注。
///
/// 正在用的地址还是 [LocalStorageService.kWebDAVUri]，每台设备只有一个，不同步（各设备
/// 走的路线可能不同，比如本机用 localhost）。这张表放在设置里，随 WebDAV 存档同步，
/// 恢复时两边合并，不是谁盖掉谁（见 SyncCompat）
class WebDavAddressBook {
  static const String kKey = "WebDAVAddressBook";

  /// 删掉的地址记多久：这段时间里同步过的设备都会跟着删掉
  static const int tombstoneMs = 180 * 24 * 3600 * 1000;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  /// 比较用：去掉首尾空格和末尾的斜杠
  static String keyOf(String uri) =>
      uri.trim().replaceFirst(RegExp(r"/+$"), "");

  static bool isValidUri(String uri) {
    var parsed = Uri.tryParse(uri.trim());
    return parsed != null &&
        (parsed.scheme == "http" || parsed.scheme == "https") &&
        parsed.host.isNotEmpty;
  }

  /// 读设置里的值（JSON 文字），格式不对时当作空表
  static List<WebDavAddress> parse(Object? raw) {
    Object? data = raw;
    if (raw is String) {
      if (raw.isEmpty) {
        return [];
      }
      try {
        data = jsonDecode(raw);
      } on FormatException {
        return [];
      }
    }
    if (data is! List) {
      return [];
    }
    var result = <String, WebDavAddress>{};
    for (var item in data) {
      var entry = WebDavAddress.fromJson(item);
      if (entry != null) {
        result[entry.key] = _newer(result[entry.key], entry);
      }
    }
    return result.values.toList();
  }

  /// 写回设置的值；删掉超过 [tombstoneMs] 的记录不再留
  static String encode(Iterable<WebDavAddress> list, {int? now}) {
    var limit = (now ?? _now()) - tombstoneMs;
    return jsonEncode([
      for (var entry in list)
        if (!entry.deleted || entry.time >= limit) entry.toJson(),
    ]);
  }

  /// 同一个地址的两条：备注和删没删以改得晚的为准（一样晚时用 [a]），用过的时间取晚的
  static WebDavAddress _newer(WebDavAddress? a, WebDavAddress b) {
    if (a == null) {
      return b;
    }
    var pick = b.time > a.time ? b : a;
    return pick.copyWith(used: math.max(a.used, b.used));
  }

  static List<WebDavAddress> merge(
    Iterable<WebDavAddress> local,
    Iterable<WebDavAddress> remote,
  ) {
    var result = <String, WebDavAddress>{};
    for (var entry in [...local, ...remote]) {
      result[entry.key] = _newer(result[entry.key], entry);
    }
    return result.values.toList();
  }

  /// 本机的和存档（或导入的配置）里的合并后的值；两边都没有时返回 null
  static String? mergeRaw(Object? local, Object? remote, {int? now}) {
    if (local == null && remote == null) {
      return null;
    }
    return encode(merge(parse(local), parse(remote)), now: now);
  }

  // ---------------------------------------------------------------------
  // 本机的表
  // ---------------------------------------------------------------------

  static LocalStorageService get _storage => LocalStorageService.instance;

  static List<WebDavAddress> load() => parse(_storage.getValue(kKey, ""));

  static Future<void> _save(List<WebDavAddress> list, int now) =>
      _storage.setValue(kKey, encode(list, now: now));

  /// 下拉列表里的：没删掉的地址，加上正在用的 [active]（还没进表时也在），最近用过的在前
  static List<WebDavAddress> visible({String active = ""}) {
    var list = load().where((e) => !e.deleted).toList();
    if (active.trim().isNotEmpty && !list.any((e) => e.key == keyOf(active))) {
      list.add(WebDavAddress(uri: active.trim()));
    }
    list.sort((a, b) {
      var byUsed = b.used.compareTo(a.used);
      if (byUsed != 0) {
        return byUsed;
      }
      var byTime = b.time.compareTo(a.time);
      return byTime != 0 ? byTime : a.uri.compareTo(b.uri);
    });
    return list;
  }

  /// 登录或切换用了这个地址：没有就加进来，删掉过的重新加上
  static Future<void> use(String uri, {int? now}) async {
    var time = now ?? _now();
    var list = load();
    var index = list.indexWhere((e) => e.key == keyOf(uri));
    if (index < 0) {
      list.add(WebDavAddress(uri: uri.trim(), time: time, used: time));
    } else if (list[index].deleted) {
      list[index] = WebDavAddress(uri: uri.trim(), time: time, used: time);
    } else {
      list[index] = list[index].copyWith(used: time);
    }
    await _save(list, time);
  }

  /// 正在用的地址不在表里（这个功能之前登录的，或者别的设备删掉了）：加进来
  static Future<void> ensure(String uri, {int? now}) async {
    if (uri.trim().isEmpty ||
        load().any((e) => !e.deleted && e.key == keyOf(uri))) {
      return;
    }
    await use(uri, now: now);
  }

  /// 改备注，空的就是去掉备注
  static Future<void> setNote(String uri, String note, {int? now}) async {
    var time = now ?? _now();
    var list = load();
    var index = list.indexWhere((e) => e.key == keyOf(uri));
    if (index < 0 || list[index].deleted) {
      list.removeWhere((e) => e.key == keyOf(uri));
      list.add(WebDavAddress(uri: uri.trim(), note: note.trim(), time: time));
    } else {
      list[index] = list[index].copyWith(note: note.trim(), time: time);
    }
    await _save(list, time);
  }

  /// 从列表里删掉（留一条删除记录给别的设备）
  static Future<void> remove(String uri, {int? now}) async {
    var time = now ?? _now();
    var list = load();
    list.removeWhere((e) => e.key == keyOf(uri));
    list.add(WebDavAddress(uri: uri.trim(), time: time, deleted: true));
    await _save(list, time);
  }

  /// 换到 [input]，账号密码不变：先用本机的账号密码连一下，连得上才保存。
  /// 原来的地址留在列表里。换成了返回新的客户端
  static Future<(WebDavSwitchResult, DAVClient?)> switchTo(
    String input, {
    int? now,
  }) async {
    var uri = input.trim();
    if (!isValidUri(uri)) {
      return (WebDavSwitchResult.invalid, null);
    }
    var client = DAVClient(
      uri,
      _storage.getValue(LocalStorageService.kWebDAVUser, ""),
      _storage.getValue(LocalStorageService.kWebDAVPassword, ""),
    );
    if (!await client.pingCompleter.future) {
      return (WebDavSwitchResult.offline, null);
    }
    var time = now ?? _now();
    var old = _storage.getValue(LocalStorageService.kWebDAVUri, "");
    var same = keyOf(old) == keyOf(uri);
    if (!same) {
      // 早一毫秒：列表里新地址排在它前面
      await ensure(old, now: time - 1);
    }
    await _storage.setValue(LocalStorageService.kWebDAVUri, uri);
    await use(uri, now: time);
    return (
      same ? WebDavSwitchResult.same : WebDavSwitchResult.switched,
      client,
    );
  }
}
