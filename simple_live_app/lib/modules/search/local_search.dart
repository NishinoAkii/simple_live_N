import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/search/text/search_text.dart';

/// 本地匹配的来源
enum LocalSearchSource {
  /// 关注
  follow,

  /// 观看历史
  history,
}

/// 本地可以匹配的一个主播（关注或看过的），名字预先算好各种形式
class LocalSearchItem {
  final String siteId;
  final String roomId;
  final String userName;
  final String face;
  final LocalSearchSource source;

  /// 关注列表里的对象，在播状态跟着它变（0 未知、1 未开播、2 直播中）
  final FollowUser? follow;

  /// 最后看的时间（历史）或关注的时间
  final DateTime time;

  final SearchKey key;

  LocalSearchItem({
    required this.siteId,
    required this.roomId,
    required this.userName,
    required this.face,
    required this.source,
    required this.time,
    this.follow,
  }) : key = SearchKey(userName);

  String get id => "${siteId}_$roomId";

  /// 关注的主播是否在播；不知道（没关注、还没刷新）时为 null
  bool? get liveStatus {
    var status = follow?.liveStatus.value ?? 0;
    if (status == 0) return null;
    return status == 2;
  }
}

class LocalSearchMatch {
  final LocalSearchItem item;
  final int score;
  LocalSearchMatch(this.item, this.score);
}

/// 关注和观看历史的本地模糊匹配（不联网，输入时马上显示）
class LocalSearchIndex {
  final List<LocalSearchItem> items;

  LocalSearchIndex(this.items);

  /// 关注和历史里同一个房间只留一条（关注优先，时间取较新的）
  factory LocalSearchIndex.build({
    required Iterable<FollowUser> follows,
    required Iterable<History> histories,
  }) {
    var map = <String, LocalSearchItem>{};
    for (var f in follows) {
      if (f.roomId.isEmpty) continue;
      var item = LocalSearchItem(
        siteId: f.siteId,
        roomId: f.roomId,
        userName: f.userName,
        face: f.face,
        source: LocalSearchSource.follow,
        time: f.addTime,
        follow: f,
      );
      map[item.id] = item;
    }
    for (var h in histories) {
      if (h.roomId.isEmpty) continue;
      var id = "${h.siteId}_${h.roomId}";
      var old = map[id];
      if (old != null) {
        if (h.updateTime.isAfter(old.time)) {
          map[id] = LocalSearchItem(
            siteId: old.siteId,
            roomId: old.roomId,
            userName: old.userName,
            face: old.face.isNotEmpty ? old.face : h.face,
            source: old.source,
            time: h.updateTime,
            follow: old.follow,
          );
        }
        continue;
      }
      map[id] = LocalSearchItem(
        siteId: h.siteId,
        roomId: h.roomId,
        userName: h.userName,
        face: h.face,
        source: LocalSearchSource.history,
        time: h.updateTime,
      );
    }
    return LocalSearchIndex(map.values.toList());
  }

  /// 按分数排序（见 [searchScore]），同分时关注的在前、在播的在前、最近的在前；
  /// [siteId] 为 null 时匹配全部平台
  List<LocalSearchMatch> search(
    String query, {
    String? siteId,
    int limit = 6,
  }) {
    var key = SearchKey(query);
    if (key.isEmpty) return [];
    var matches = <LocalSearchMatch>[];
    for (var item in items) {
      if (siteId != null && item.siteId != siteId) continue;
      var score = searchScore(key, item.key);
      if (score > 0) {
        matches.add(LocalSearchMatch(item, score));
      }
    }
    matches.sort((a, b) {
      var d = b.score - a.score;
      if (d != 0) return d;
      d = a.item.source.index - b.item.source.index;
      if (d != 0) return d;
      d = (b.item.liveStatus == true ? 1 : 0) -
          (a.item.liveStatus == true ? 1 : 0);
      if (d != 0) return d;
      return b.item.time.compareTo(a.item.time);
    });
    return matches.length > limit ? matches.sublist(0, limit) : matches;
  }
}
