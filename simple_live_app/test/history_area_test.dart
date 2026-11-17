import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/multi_window/window_changes.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';

/// 1.23.x 的适配器：8 个字段，没有分区。用来确认升级后读得了旧记录，退回旧版也读得了新记录
class _OldHistoryAdapter extends TypeAdapter<History> {
  @override
  final int typeId = 2;

  @override
  History read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return History(
      id: fields[0] as String,
      roomId: fields[1] as String,
      siteId: fields[2] as String,
      userName: fields[3] as String,
      face: fields[4] as String,
      updateTime: fields[5] as DateTime,
      cover: fields[6] as String?,
      title: fields[7] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, History obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.roomId)
      ..writeByte(2)
      ..write(obj.siteId)
      ..writeByte(3)
      ..write(obj.userName)
      ..writeByte(4)
      ..write(obj.face)
      ..writeByte(5)
      ..write(obj.updateTime)
      ..writeByte(6)
      ..write(obj.cover)
      ..writeByte(7)
      ..write(obj.title);
  }
}

History record({String? area, DateTime? time}) => History(
      id: "douyu_1",
      roomId: "1",
      siteId: "douyu",
      userName: "主播",
      face: "f",
      updateTime: time ?? DateTime(2026, 11, 17, 15, 16),
      cover: "c",
      title: "标题",
      area: area,
    );

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync("history_area_");
    Hive.init(dir.path);
  });

  tearDown(() async {
    Get.reset();
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  Future<Box<History>> open(TypeAdapter<History> adapter) {
    Hive.registerAdapter(adapter, override: true);
    return Hive.openBox<History>("History");
  }

  test("Hive：旧记录读出来没有分区；写了分区以后，1.23.x 的适配器照样读得了", () async {
    var box = await open(_OldHistoryAdapter());
    await box.put("douyu_1", record());
    await box.close();

    // 升级：旧记录没有 8 号字段
    box = await open(HistoryAdapter());
    var item = box.get("douyu_1")!;
    expect(item.area, isNull);
    expect(item.title, "标题");
    item.area = "主机游戏";
    await box.put(item.id, item);
    await box.close();
    box = await open(HistoryAdapter());
    expect(box.get("douyu_1")!.area, "主机游戏");
    await box.close();

    // 退回 1.23.x：不认识的字段跳过，别的都在
    box = await open(_OldHistoryAdapter());
    var back = box.get("douyu_1")!;
    expect(back.userName, "主播");
    expect(back.cover, "c");
    expect(back.title, "标题");
    expect(back.updateTime, DateTime(2026, 11, 17, 15, 16));
    expect(back.area, isNull);
    await box.close();
  });

  test("同步的 JSON：有分区才写 area；没有这个键（官方版、旧版）读出来是 null", () {
    var plain = record().toJson();
    expect(plain.containsKey("area"), isFalse);
    expect(History.fromJson(plain).area, isNull);

    var json = record(area: "主机游戏").toJson();
    expect(json["area"], "主机游戏");
    var again = History.fromJson(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(json))),
    );
    expect(again.area, "主机游戏");
    expect(again.title, "标题");
    expect(again.updateTime, DateTime(2026, 11, 17, 15, 16));
    // 官方版只读这几个键，多出来的不影响
    expect(DateTime.parse(json["updateTime"]), DateTime(2026, 11, 17, 15, 16));
    for (var key in ["id", "roomId", "siteId", "userName", "face"]) {
      expect(json[key], isA<String>());
    }
    // 空的当没有
    expect(History.fromJson({...json, "area": " "}).area, isNull);
  });

  test("多开窗口之间传的记录带着分区", () {
    var change = HistoryPut(record(area: "主机游戏"));
    var decoded = WindowChange.decode(
      change.op,
      jsonDecode(jsonEncode(change.data)),
    );
    expect((decoded as HistoryPut).history.area, "主机游戏");
  });

  test("合并：同步来的记录没有分区时留着本机的，有就用它的", () async {
    var db = DBService()..historyBox = await open(HistoryAdapter());
    Get.put(db);
    await db.addOrUpdateHistory(record(area: "主机游戏"));

    // 官方版、旧版看过以后同步过来：更新时间新，没有分区
    var official = History.fromJson(
      record(time: DateTime(2026, 11, 18)).toJson()..remove("area"),
    );
    expect(official.area, isNull);
    await db.addOrUpdateHistory(official);
    var saved = db.getHistory("douyu_1")!;
    expect(saved.updateTime, DateTime(2026, 11, 18));
    expect(saved.area, "主机游戏");

    // 本版本的设备同步过来：换了分区
    await db.addOrUpdateHistory(
      History.fromJson(
        record(area: "颜值", time: DateTime(2026, 11, 19)).toJson(),
      ),
    );
    expect(db.getHistory("douyu_1")!.area, "颜值");

    // 没记过分区的房间还是没有
    await db.historyBox.clear();
    await db.addOrUpdateHistory(record());
    expect(db.getHistory("douyu_1")!.area, isNull);
  });
}
