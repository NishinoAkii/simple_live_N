import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/models/db/sync_time.dart';

part 'follow_user.g.dart';

@HiveType(typeId: 1)
class FollowUser {
  FollowUser({
    required this.id,
    required this.roomId,
    required this.siteId,
    required this.userName,
    required this.face,
    required this.addTime,
    this.tag = "全部",
    bool notify = false,
  }) : notifyRx = notify.obs;

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
  DateTime addTime;

  @HiveField(6)
  String tag;

  /// 订阅了开播提醒：开播时发通知。跟着关注列表一起同步
  @HiveField(7)
  bool get notify => notifyRx.value;
  set notify(bool value) => notifyRx.value = value;

  /// 界面上的铃铛跟着它变
  final RxBool notifyRx;

  /// 直播状态
  /// 0=未知(加载中) 1=未开播 2=直播中
  Rx<int> liveStatus = 0.obs;

  /// 开播时间戳
  String? liveStartTime;

  /// 在播时读房间信息拿到的封面、标题和人气。只在内存里，关注页的卡片样式用
  String? liveCover;
  String? liveTitle;
  int liveOnline = 0;

  factory FollowUser.fromJson(Map<String, dynamic> json) => FollowUser(
        id: json['id'],
        roomId: json['roomId'],
        siteId: json['siteId'],
        userName: json['userName'],
        face: json['face'],
        addTime: SyncTime.read(json, 'addTime'),
        tag: json["tag"]??"全部",
        notify: json["notify"] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'roomId': roomId,
        'siteId': siteId,
        'userName': userName,
        'face': face,
        ...SyncTime.write('addTime', addTime),
        'tag':tag,
        // 没订阅时不写，和旧版的备份一样
        if (notify) 'notify': true,
      };
}
