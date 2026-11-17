import 'dart:convert';

/// 搜索联想（输入时的“搜索推测内容”）
///
/// - [kWord]：联想词，点了填进搜索框并搜索
/// - [kRoom]：频道/主播卡片（有 [roomId]），点了直接进直播间
/// - [kCategory]：分类，当成词处理
class LiveSuggestion {
  static const String kWord = "word";
  static const String kRoom = "room";
  static const String kCategory = "category";

  /// 联想词；频道卡片为主播名
  final String text;

  /// [kWord]、[kRoom] 或 [kCategory]
  final String type;

  /// 频道卡片的房间号
  final String? roomId;

  /// 频道卡片的主播名
  final String? userName;

  /// 频道卡片的头像
  final String? avatar;

  /// 频道卡片是否在播，平台没给时为 null
  final bool? liveStatus;

  /// 频道卡片是否在轮播
  final bool isRecord;

  /// 补充说明（分类名、直播标题等）
  final String? subtitle;

  LiveSuggestion({
    required this.text,
    this.type = kWord,
    this.roomId,
    this.userName,
    this.avatar,
    this.liveStatus,
    this.isRecord = false,
    this.subtitle,
  });

  /// 有房间号、可以直接打开的频道卡片
  bool get isRoom => type == kRoom && (roomId?.isNotEmpty ?? false);

  @override
  String toString() {
    return json.encode({
      "text": text,
      "type": type,
      if (roomId != null) "roomId": roomId,
      if (userName != null) "userName": userName,
      if (avatar != null) "avatar": avatar,
      if (liveStatus != null) "liveStatus": liveStatus,
      if (isRecord) "isRecord": isRecord,
      if (subtitle != null) "subtitle": subtitle,
    });
  }
}
