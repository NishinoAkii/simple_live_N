import 'package:simple_live_core/src/model/live_search_result.dart';

/// 一次请求就能同时搜到直播间和主播的平台（哔哩哔哩、虎牙）
///
/// App 的“综合”搜索优先用它，少发一次请求；没有实现的平台并行调用
/// searchRooms 和 searchAnchors。
abstract interface class LiveSearchAllSite {
  /// 第 [page] 页的直播间（在播）和主播（包括未开播的）
  Future<LiveSearchAllResult> searchAll(String keyword, {int page = 1});
}
