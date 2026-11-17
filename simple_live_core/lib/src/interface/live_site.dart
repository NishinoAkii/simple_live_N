import 'package:simple_live_core/src/model/live_anchor_item.dart';

import '../interface/live_danmaku.dart';
import '../model/live_category_result.dart';
import '../model/live_message.dart';
import '../model/live_play_url.dart';
import '../model/live_room_detail.dart';
import '../model/live_search_result.dart';
import '../model/live_suggestion.dart';

import '../model/live_category.dart';
import '../model/live_play_quality.dart';
import '../model/live_room_item.dart';

class LiveSite {
  /// 站点唯一ID
  String id = "";

  /// 站点名称
  String name = "";

  /// 站点名称
  LiveDanmaku getDanmaku() => LiveDanmaku();

  /// 读取网站的分类
  Future<List<LiveCategory>> getCategores() {
    return Future.value(<LiveCategory>[]);
  }

  /// 搜索直播间
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) {
    return Future.value(
        LiveSearchRoomResult(hasMore: false, items: <LiveRoomItem>[]));
  }

  /// 搜索直播间
  Future<LiveSearchAnchorResult> searchAnchors(String keyword, {int page = 1}) {
    return Future.value(
        LiveSearchAnchorResult(hasMore: false, items: <LiveAnchorItem>[]));
  }

  /// 搜索联想（输入时的推测内容）：联想词，以及可以直接打开的频道卡片。
  /// 没有联想接口的平台返回空列表；出错时可以抛出，App 不提示
  Future<List<LiveSuggestion>> getSearchSuggestions(String keyword) {
    return Future.value(<LiveSuggestion>[]);
  }

  /// 读取类目下房间
  Future<LiveCategoryResult> getCategoryRooms(LiveSubCategory category,
      {int page = 1}) {
    return Future.value(
        LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]));
  }

  /// 读取推荐的房间
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) {
    return Future.value(
        LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]));
  }

  /// 读取房间详情
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) {
    return Future.value(LiveRoomDetail(
      cover: '',
      online: 0,
      roomId: '',
      status: false,
      title: '',
      url: '',
      userAvatar: '',
      userName: '',
    ));
  }

  /// 读取房间清晰度
  Future<List<LivePlayQuality>> getPlayQualites(
      {required LiveRoomDetail detail}) {
    return Future.value(<LivePlayQuality>[]);
  }

  /// 读取播放链接
  Future<LivePlayUrl> getPlayUrls(
      {required LiveRoomDetail detail, required LivePlayQuality quality}) {
    return Future.value(LivePlayUrl(urls: []));
  }

  /// 查询直播状态
  Future<bool> getLiveStatus({required String roomId}) {
    return Future.value(false);
  }

  /// 读取指定房间的SC
  Future<List<LiveSuperChatMessage>> getSuperChatMessage(
      {required String roomId}) {
    return Future.value([]);
  }

  /// iOS 系统画中画（AVPlayer）用的播放地址
  ///
  /// AVPlayer 只能播 HLS（m3u8）和 MP4，不能播 FLV：平台平时给 FLV 时，
  /// 在这里另取同一直播间的 HLS 地址。没有可用地址时返回 null，App 改用 mpv 画中画。
  Future<LivePlayUrl?> getAvPlayerUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) {
    return Future.value(null);
  }
}
