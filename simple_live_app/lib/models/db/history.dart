import 'package:hive/hive.dart';
import 'package:simple_live_app/models/db/sync_time.dart';

part 'history.g.dart';

@HiveType(typeId: 2)
class History {
  History({
    required this.id,
    required this.roomId,
    required this.siteId,
    required this.userName,
    required this.face,
    required this.updateTime,
    this.cover,
    this.title,
    this.area,
  });

  ///id=siteId_roomId
  @HiveField(0)
  String id;

  @HiveField(1)
  String roomId;

  @HiveField(2)
  String siteId;

  @HiveField(3)
  String userName;

  @HiveField(4)
  String face;

  @HiveField(5)
  DateTime updateTime;

  /// 进入直播间时的封面和标题，旧记录没有
  @HiveField(6)
  String? cover;

  @HiveField(7)
  String? title;

  /// 进入直播间时的分区（平台的原文，如“主机游戏”）；旧记录、官方版和旧版同步来的记录没有
  @HiveField(8)
  String? area;

  static String? _area(dynamic value) {
    var text = value?.toString().trim() ?? "";
    return text.isEmpty ? null : text;
  }

  factory History.fromJson(Map<String, dynamic> json) => History(
        id: json["id"],
        roomId: json["roomId"],
        siteId: json["siteId"],
        userName: json["userName"],
        face: json["face"],
        updateTime: SyncTime.read(json, "updateTime"),
        cover: json["cover"]?.toString(),
        title: json["title"]?.toString(),
        area: _area(json["area"]),
      );

  Map<String, dynamic> toJson() => {
        "id": id,
        "roomId": roomId,
        "siteId": siteId,
        "userName": userName,
        "face": face,
        ...SyncTime.write("updateTime", updateTime),
        if (cover != null) "cover": cover,
        if (title != null) "title": title,
        if (area != null) "area": area,
      };
}
