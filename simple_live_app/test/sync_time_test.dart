import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/models/db/sync_time.dart';
import 'package:simple_live_app/services/webdav_auto_sync.dart';

/// 别的时区的设备写出的本机钟点（原字段的写法，不带时区）
String wallClock(DateTime utc, Duration offset) {
  var text = utc.toUtc().add(offset).toString();
  return text.substring(0, text.length - 1); // 去掉 Z
}

Map<String, dynamic> historyJson(String text, {int? ms, String id = "a"}) => {
      "id": id,
      "roomId": "1",
      "siteId": "bilibili",
      "userName": "u",
      "face": "",
      "updateTime": text,
      if (ms != null) "updateTimeMs": ms,
    };

void main() {
  const japan = Duration(hours: 9);
  final watched = DateTime.utc(2026, 11, 8, 10, 14, 5, 123); // 东京 19:14

  test('别的时区写的记录，在这台设备上按真实时刻显示', () {
    // 写的一方和本机差 15 小时（本机是东京就用美中，否则用东京）
    var here = watched.toLocal().timeZoneOffset;
    var writer = here == japan ? const Duration(hours: -6) : japan;
    var text = wallClock(watched, writer);
    var history = History.fromJson(
      historyJson(text, ms: watched.millisecondsSinceEpoch),
    );
    expect(history.updateTime.isUtc, isFalse);
    expect(history.updateTime.millisecondsSinceEpoch,
        watched.millisecondsSinceEpoch);
    expect(history.updateTime.hour, watched.toLocal().hour);
    // 没有时间戳时（原来的做法）钟点照搬，差的正好是两地的时差
    // （本机在日本时是 15 小时，CI 在 UTC 时是 9 小时）
    var naive = History.fromJson(historyJson(text)).updateTime;
    expect(naive.difference(history.updateTime).inHours.abs(),
        (writer - here).inHours.abs());
    String hm(DateTime t) =>
        "${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}";
    // ignore: avoid_print
    print("UTC${writer.inHours >= 0 ? '+' : ''}${writer.inHours} 的设备写 "
        "${text.substring(11, 16)}，本机 UTC+${here.inHours} 显示 "
        "${hm(history.updateTime)}（原来显示 ${hm(naive)}）");
  });

  test('写出时保留原字段（本机钟点），另加时间戳', () {
    var local = DateTime(2026, 11, 8, 19, 14, 5, 123);
    var history = History.fromJson(historyJson(local.toString()));
    var json = history.toJson();
    expect(json["updateTime"], local.toString());
    expect(json["updateTimeMs"], local.millisecondsSinceEpoch);
    // 再读回来是同一时刻
    expect(History.fromJson(json).updateTime, local);
  });

  test('官方版和旧版的记录没有时间戳，照旧按本机时间解析', () {
    var history = History.fromJson(historyJson("2026-11-08 19:14:05.123"));
    expect(history.updateTime, DateTime.parse("2026-11-08 19:14:05.123"));
    expect(history.updateTime.isUtc, isFalse);
  });

  test('原字段带时区时换算成本地时间', () {
    var history =
        History.fromJson(historyJson("2026-11-08T19:14:05.123+09:00"));
    expect(history.updateTime.isUtc, isFalse);
    expect(history.updateTime.millisecondsSinceEpoch,
        watched.millisecondsSinceEpoch);
  });

  test('关注记录也带时间戳', () {
    var follow = FollowUser.fromJson({
      "id": "bilibili_1",
      "roomId": "1",
      "siteId": "bilibili",
      "userName": "u",
      "face": "",
      "addTime": wallClock(watched, japan),
      "addTimeMs": watched.millisecondsSinceEpoch,
    });
    expect(
        follow.addTime.millisecondsSinceEpoch, watched.millisecondsSinceEpoch);
    expect(follow.toJson()["addTimeMs"], watched.millisecondsSinceEpoch);
  });

  test('读不出时间时和原来一样报错', () {
    expect(() => History.fromJson(historyJson("")), throwsFormatException);
    expect(SyncTime.tryRead({}, "updateTime"), isNull);
  });

  group('自动同步合并按真实先后', () {
    test('西边时区刚看的记录不会被当成别的设备删掉的', () {
      // 上次和云端对齐在 1 小时前，UTC-10 的设备 30 分钟前看了一场
      var base = DateTime.utc(2026, 11, 8, 12);
      var seen = base.add(const Duration(minutes: 30));
      var remote = History.fromJson(historyJson(
        wallClock(seen, const Duration(hours: -10)),
        ms: seen.millisecondsSinceEpoch,
      ));
      var merge = mergeWebDavRecords<History>(
        const [],
        [remote],
        id: (e) => e.id,
        time: (e) => e.updateTime,
        base: base.millisecondsSinceEpoch,
      );
      expect(merge.put.map((e) => e.id), ["a"]);
    });

    test('日本设备较早的记录不会盖掉本机较新的', () {
      var mine = History.fromJson(historyJson(
        "",
        ms: watched.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      ));
      var remote = History.fromJson(historyJson(
        wallClock(watched, japan),
        ms: watched.millisecondsSinceEpoch,
      ));
      var merge = mergeWebDavRecords<History>(
        [mine],
        [remote],
        id: (e) => e.id,
        time: (e) => e.updateTime,
        base: 0,
      );
      expect(merge.put, isEmpty);
      expect(merge.localKept, isTrue);
    });
  });
}
