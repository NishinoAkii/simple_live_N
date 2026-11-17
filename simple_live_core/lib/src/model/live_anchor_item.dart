import 'dart:convert';

class LiveAnchorItem {
  /// 房间ID
  final String roomId;

  /// 封面
  final String avatar;

  /// 用户名
  final String userName;

  /// 直播中
  final bool liveStatus;

  /// 正在轮播（重播以前的直播，不算直播中），平台给出时才有
  final bool isRecord;

  /// 粉丝/关注人数，平台给出时才有
  final int? followers;

  /// 上次直播的标题，平台给出时才有
  final String? lastTitle;

  /// 上次开播的时间，平台给出时才有
  final DateTime? lastLiveTime;

  LiveAnchorItem({
    required this.roomId,
    required this.avatar,
    required this.userName,
    required this.liveStatus,
    this.isRecord = false,
    this.followers,
    this.lastTitle,
    this.lastLiveTime,
  });

  @override
  String toString() {
    return json.encode({
      "roomId": roomId,
      "avatar": avatar,
      "userName": userName,
      "liveStatus": liveStatus,
      if (isRecord) "isRecord": isRecord,
      if (followers != null) "followers": followers,
      if (lastTitle != null) "lastTitle": lastTitle,
      if (lastLiveTime != null) "lastLiveTime": lastLiveTime!.toIso8601String(),
    });
  }
}
