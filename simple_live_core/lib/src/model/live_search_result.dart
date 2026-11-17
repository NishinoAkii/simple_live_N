import 'package:simple_live_core/src/model/live_anchor_item.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';

class LiveSearchRoomResult {
  final bool hasMore;
  final List<LiveRoomItem> items;

  /// 平台给的纠正词（如“你是不是要找：xxx”），没有时为 null
  final String? correction;
  LiveSearchRoomResult({
    required this.hasMore,
    required this.items,
    this.correction,
  });
}

class LiveSearchAnchorResult {
  final bool hasMore;
  final List<LiveAnchorItem> items;

  /// 平台给的纠正词（如“你是不是要找：xxx”），没有时为 null
  final String? correction;
  LiveSearchAnchorResult({
    required this.hasMore,
    required this.items,
    this.correction,
  });
}

/// 一次请求同时得到直播间和主播的搜索结果，见 LiveSearchAllSite
class LiveSearchAllResult {
  final List<LiveRoomItem> rooms;
  final List<LiveAnchorItem> anchors;

  /// 直播间是否还有下一页
  final bool hasMoreRooms;

  /// 主播是否还有下一页
  final bool hasMoreAnchors;

  /// 平台给的纠正词，没有时为 null
  final String? correction;

  LiveSearchAllResult({
    required this.rooms,
    required this.anchors,
    required this.hasMoreRooms,
    required this.hasMoreAnchors,
    this.correction,
  });
}
