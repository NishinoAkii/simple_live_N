/// 同步、导出用的时间。
///
/// 原来的字段是本机钟点、不带时区（"2026-11-08 19:14:05.000"），
/// 官方版和旧版照旧读它；另加一个 `<字段>Ms`（UTC 毫秒），
/// 本版优先用它，换算成这台设备的时区。
class SyncTime {
  static String msKey(String key) => "${key}Ms";

  /// [text] 是原字段的写法，默认 `toString()`
  static Map<String, dynamic> write(
    String key,
    DateTime time, {
    String Function(DateTime local)? text,
  }) {
    var local = time.toLocal();
    return {
      key: text == null ? local.toString() : text(local),
      msKey(key): time.millisecondsSinceEpoch,
    };
  }

  /// 有时间戳用时间戳；没有（官方版、旧版）按原字段解析，带时区的也转成本地时间
  static DateTime? tryRead(Map json, String key) {
    var ms = json[msKey(key)];
    var value = ms is num ? ms.toInt() : int.tryParse(ms?.toString() ?? "");
    if (value != null) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    return DateTime.tryParse(json[key]?.toString() ?? "")?.toLocal();
  }

  /// 同 [tryRead]，读不出时抛错（和原来的 DateTime.parse 一样）
  static DateTime read(Map json, String key) =>
      tryRead(json, key) ?? DateTime.parse(json[key].toString());
}
