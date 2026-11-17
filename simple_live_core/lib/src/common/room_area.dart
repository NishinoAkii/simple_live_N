/// 直播间所在的分区。都从进直播间时已经读到的房间信息里取，不另外请求；
/// 取平台显示的最细一级，没有或者是空的时返回 null。分区名是平台的数据，不翻译
class LiveRoomArea {
  /// 去掉首尾空白；不是文字或者是空的算没有
  static String? clean(dynamic value) {
    if (value is! String) return null;
    var text = value.trim();
    return text.isEmpty ? null : text;
  }

  /// 哔哩哔哩 getInfoByRoom 的 data：`room_info.area_name`（如“点唱”），
  /// 没有时用上一级的 `parent_area_name`（如“聊天室”）
  static String? bilibili(dynamic roomInfo) {
    var info = roomInfo is Map ? roomInfo["room_info"] : null;
    if (info is! Map) return null;
    return clean(info["area_name"]) ?? clean(info["parent_area_name"]);
  }

  /// 斗鱼 betard 的 `room.second_lvl_name`（如“主机其他游戏”，没开播时也有）；
  /// [h5Room] 是 swf_api/h5room 的 data，里面的 `game_name` 是同一个值
  static String? douyu(dynamic room, [dynamic h5Room]) =>
      clean(room is Map ? room["second_lvl_name"] : null) ??
      clean(h5Room is Map ? h5Room["game_name"] : null);

  /// 虎牙 HNF_GLOBAL_INIT.roomInfo：在播时是 `tLiveInfo.sGameFullName`；
  /// 没开播时 tLiveInfo 是空的，用 `tRecentLive`（上一场）的
  static String? huya(dynamic roomInfo) {
    if (roomInfo is! Map) return null;
    String? of(dynamic info) =>
        clean(info is Map ? info["sGameFullName"] : null);
    return of(roomInfo["tLiveInfo"]) ?? of(roomInfo["tRecentLive"]);
  }

  /// 抖音 webcast/room/web/enter 的 `data.partition_road_map`：
  /// `{partition: {title: "竞技游戏"}, sub_partition: {partition: {title: "王者荣耀"}}}`。
  /// 有子分区用子分区的（没开播时它的 title 是空的），没有时用上一级的；
  /// 不分区的直播间（如带货）这个字段是 `{}` 或者没有
  static String? douyin(dynamic roadMap) {
    if (roadMap is! Map) return null;
    String? title(dynamic item) {
      var partition = item is Map ? item["partition"] : null;
      return clean(partition is Map ? partition["title"] : null);
    }

    return title(roadMap["sub_partition"]) ?? title(roadMap);
  }

  /// Kick /api/v2/channels 的 `livestream.categories[0].name`；没开播时没有 livestream
  static String? kick(dynamic livestream) {
    var categories = livestream is Map ? livestream["categories"] : null;
    if (categories is! List || categories.isEmpty) return null;
    var first = categories.first;
    return clean(first is Map ? first["name"] : null);
  }
}
