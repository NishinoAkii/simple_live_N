import 'package:collection/collection.dart';
import 'package:simple_live_app/app/controller/follow_view_settings.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/modules/search/text/search_text.dart';

/// 关注页的分组、排序和搜索。只处理列表，不碰界面和存储

/// 关注页里的一组
class FollowGroup {
  /// 记折叠状态用的键：site:<平台 id>、tag:<标签 id>（未分组是 tag:）、status:<状态>
  final String key;
  final String title;

  /// 按直播源分组时是这一组的平台，标题前面画它的图标
  final String? siteId;
  final List<FollowUser> members;
  const FollowGroup(this.key, this.title, this.members, {this.siteId});
}

/// 名字的拼音、首字母等，同一个名字只算一次
class FollowNameKeys {
  final _keys = <String, SearchKey>{};
  SearchKey of(String name) => _keys.putIfAbsent(name, () => SearchKey(name));

  /// 关注很多、名字改过很多次时别一直涨
  void trim() {
    if (_keys.length > 20000) _keys.clear();
  }
}

/// 名字对不对得上搜索词：名字、全拼、拼音首字母都可以
bool followNameMatches(SearchKey query, SearchKey name) {
  if (query.isEmpty) return true;
  if (searchScore(query, name) > 0) return true;
  if (!query.isLatin || !name.hasHan) return false;
  var q = query.compact;
  // 搜一个字母也能按首字母找到：“l”找到“老番茄”；两个以上的字母可以在中间：“fq”
  return name.initials.startsWith(q) ||
      (q.length >= 2 && name.initials.contains(q));
}

/// 按名字或拼音首字母搜，顺序不变
List<FollowUser> searchFollows(
  List<FollowUser> list,
  String keyword,
  FollowNameKeys keys,
) {
  var query = SearchKey(keyword);
  if (query.isEmpty) return list;
  return list
      .where((e) => followNameMatches(query, keys.of(e.userName)))
      .toList();
}

/// 开播时间（秒），没有或者不是数字时为 null
int? _startedAt(FollowUser item) {
  var t = item.liveStartTime;
  if (t == null || t.isEmpty || t == "0") return null;
  return int.tryParse(t);
}

/// 排序。[FollowViewSettings.sortLive] 原样返回（关注列表本来就是直播中的在前）；
/// 其他的排法排不出先后的保持原来的顺序。
///
/// - 最近看过：用观看记录的时间（[watchedAt]），没看过的放后面；
/// - 最近开播：直播中的按开播时间，刚开播的在前；不知道开播时间的直播中排在后面，再后面是没开播的；
/// - 最近关注：关注时间新的在前；
/// - 按名字：拼音（复用搜索的拼音表），名字里没有字母、数字、汉字的放最后
List<FollowUser> sortFollows(
  List<FollowUser> list,
  String mode, {
  DateTime? Function(FollowUser item)? watchedAt,
  FollowNameKeys? keys,
}) {
  if (mode == FollowViewSettings.sortLive || list.length < 2) return list;
  var result = List<FollowUser>.of(list);
  int Function(FollowUser a, FollowUser b) compare;
  switch (mode) {
    case FollowViewSettings.sortWatched:
      var times = {
        for (var e in result) e.id: watchedAt?.call(e)?.millisecondsSinceEpoch,
      };
      compare = (a, b) => _desc(times[a.id], times[b.id]);
      break;
    case FollowViewSettings.sortStarted:
      int rank(FollowUser e) =>
          e.liveStatus.value != 2 ? 2 : (_startedAt(e) == null ? 1 : 0);
      compare = (a, b) {
        var r = rank(a).compareTo(rank(b));
        if (r != 0) return r;
        return _desc(_startedAt(a), _startedAt(b));
      };
      break;
    case FollowViewSettings.sortAdded:
      compare = (a, b) => b.addTime.compareTo(a.addTime);
      break;
    case FollowViewSettings.sortName:
      var k = keys ?? FollowNameKeys();
      compare = (a, b) {
        var ka = k.of(a.userName);
        var kb = k.of(b.userName);
        var ea = ka.pinyin.isEmpty;
        var eb = kb.pinyin.isEmpty;
        if (ea != eb) return ea ? 1 : -1;
        var r = ka.pinyin.compareTo(kb.pinyin);
        return r != 0 ? r : ka.text.compareTo(kb.text);
      };
      break;
    default:
      return list;
  }
  // 稳定排序：比不出先后的保持原来的顺序
  mergeSort(result, compare: compare);
  return result;
}

/// 大的在前，没有的放最后
int _desc(int? a, int? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}

/// 分组。空的组不列出来；组里的顺序和 [list] 一样。
///
/// - 按直播源：顺序同 [siteOrder]（首页的平台排序），不在里面的（已删除的直播源）放最后；
/// - 按标签：顺序同 [tags]，没有标签、或者标签已经删了的放在最后的“未分组”；
/// - 按状态：直播中、未开播、状态未知
List<FollowGroup> groupFollows(
  List<FollowUser> list,
  String mode, {
  List<String> siteOrder = const [],
  List<FollowUserTag> tags = const [],
  String Function(String siteId)? siteName,
}) {
  switch (mode) {
    case FollowViewSettings.groupTag:
      var byName = <String, List<FollowUser>>{};
      var none = <FollowUser>[];
      var names = {for (var t in tags) t.tag};
      for (var e in list) {
        if (names.contains(e.tag)) {
          byName.putIfAbsent(e.tag, () => []).add(e);
        } else {
          none.add(e);
        }
      }
      return [
        for (var t in tags)
          if (byName.containsKey(t.tag))
            FollowGroup("tag:${t.id}", t.tag, byName.remove(t.tag)!),
        if (none.isNotEmpty) FollowGroup("tag:", "未分组".t, none),
      ];
    case FollowViewSettings.groupStatus:
      var byStatus = <int, List<FollowUser>>{};
      for (var e in list) {
        var s = e.liveStatus.value;
        byStatus.putIfAbsent(s == 2 || s == 1 ? s : 0, () => []).add(e);
      }
      String title(int s) => switch (s) {
            2 => "直播中".t,
            1 => "未开播".t,
            _ => "状态未知".t,
          };
      return [
        for (var s in const [2, 1, 0])
          if (byStatus[s] != null)
            FollowGroup("status:$s", title(s), byStatus[s]!),
      ];
    default:
      var bySite = <String, List<FollowUser>>{};
      for (var e in list) {
        bySite.putIfAbsent(e.siteId, () => []).add(e);
      }
      var order = [
        for (var id in siteOrder)
          if (bySite.containsKey(id)) id,
      ];
      var rest = bySite.keys.where((e) => !order.contains(e)).toList()..sort();
      return [
        for (var id in [...order, ...rest])
          FollowGroup(
            "site:$id",
            siteName?.call(id) ?? id,
            bySite[id]!,
            siteId: id,
          ),
      ];
  }
}
