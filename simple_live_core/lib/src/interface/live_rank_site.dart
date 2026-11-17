import 'package:simple_live_core/src/model/live_rank.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';

/// 有榜单的平台（哔哩哔哩、抖音、斗鱼、Kick）。本场礼物榜由 App 按收到的礼物自己算，不在这里
abstract interface class LiveRankSite {
  /// 这个平台有哪些榜单，第一个是默认的
  List<LiveRankBoard> get rankBoards;

  /// 读 [boardId] 这个榜单（[detail] 是进直播间时读到的房间信息）
  Future<LiveRankList> getRank(
    String boardId, {
    required LiveRoomDetail detail,
  });
}
