import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/search/search_direct.dart';
import 'package:simple_live_app/modules/search/search_merge.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 搜索模式
class SearchMode {
  /// 只搜直播间（在播）
  static const int rooms = 0;

  /// 只搜主播（包括未开播）
  static const int anchors = 1;

  /// 综合：直播间和主播合在一起，按房间号去重（默认）
  static const int all = 2;
}

class SearchListController extends BasePageController {
  String keyword = "";

  /// 搜索模式，见 [SearchMode]
  var searchMode = SearchMode.all.obs;
  final Site site;
  SearchListController(
    this.site,
  );

  /// 平台要求登录后才能搜索（如抖音），页面上显示去登录的提示
  var needLogin = false.obs;

  /// 输入像房间号时的“直达”卡片
  var direct = Rxn<SearchDirectResult>();

  /// 每次重新搜索加一，丢掉旧搜索晚到的结果
  int _generation = 0;

  /// 直播间、主播还有没有下一页
  bool _roomsMore = true;
  bool _anchorsMore = true;

  /// 已经显示过的房间号（综合模式翻页时去重）
  final Set<String> _shown = {};

  /// 综合模式请求到了第几页
  int _allPage = 0;

  /// 试直达用的函数，测试时可以替换
  Future<SearchDirectResult?> Function(Site site, String input) directResolver =
      resolveSearchDirect;

  /// “你是不是要找”：只指向主播（关注和看过的、平台的主播卡片、搜索结果里名字
  /// 全拼、首字母或拼错一两个字母能对上的），见 [searchDidYouMean]
  var correction = RxnString();

  /// 正在按拼音、简体补充搜索
  var rescuing = false.obs;

  /// 第一页里平台给的纠正词
  String? _serverCorrection;

  /// 已经取到的主播卡片（“你是不是要找”用，不发请求），搜索页设置
  List<LiveSuggestion>? Function(Site site, String keyword)? cachedSuggestions;

  /// 关注和看过里匹配的主播名（“你是不是要找”用），搜索页设置
  List<String> Function(String siteId, String keyword)? localNames;

  /// 点了“你是不是要找”的词，搜索页设置
  void Function(String keyword)? onSearchWord;

  @override
  Future refreshData() async {
    if (keyword.isEmpty) {
      return;
    }
    _startDirect();
    return await super.refreshData();
  }

  void _startDirect() {
    var generation = ++_generation;
    var input = keyword;
    direct.value = null;
    directResolver(site, input).then((result) {
      if (generation != _generation || result == null) return;
      direct.value = result;
      // 结果里已经有同一个房间时去掉，只留直达卡片
      list.removeWhere((e) => searchItemRoomId(e) == result.roomId);
    }).catchError((e) {
      Log.logPrint(e);
    });
  }

  /// 刚读到的第一页，显示出来以后交给 [_afterFirstPage]
  List? _firstPage;

  @override
  Future loadData() async {
    await super.loadData();
    var first = _firstPage;
    _firstPage = null;
    if (first != null) {
      _afterFirstPage(first);
    }
  }

  @override
  Future<List> getData(int page, int pageSize) async {
    if (keyword.isEmpty) {
      return [];
    }
    if (page <= 1) {
      _roomsMore = true;
      _anchorsMore = true;
      _shown.clear();
    }
    needLogin.value = false;
    if (page <= 1) {
      _serverCorrection = null;
      correction.value = null;
    }
    try {
      var items = await _search(page);
      var directId = direct.value?.roomId;
      if (directId != null) {
        items.removeWhere((e) => searchItemRoomId(e) == directId);
      }
      if (page <= 1) {
        // 等第一页显示出来以后（loadData 里）再补救、找纠正词
        _firstPage = items;
      }
      // 列表里会混放不同类型（补救结果、直达去重后再插入），不用具体类型的 List
      return List<dynamic>.of(items);
    } on LoginRequiredError catch (e) {
      needLogin.value = true;
      throw Exception(searchLoginHint(e));
    }
  }

  Future<List> _search(int page) async {
    switch (searchMode.value) {
      case SearchMode.anchors:
        // 搜索主播（直播源可能没写）
        if (!site.hasSearchAnchors) {
          throw Exception("{name}不支持搜索主播".tf({"name": site.name}));
        }
        if (page > 1 && !_anchorsMore) return [];
        var result = await site.liveSite.searchAnchors(keyword, page: page);
        _anchorsMore = result.hasMore;
        if (page <= 1) _serverCorrection = result.correction;
        return result.items;
      case SearchMode.rooms:
        if (page > 1 && !_roomsMore) return [];
        var result = await site.liveSite.searchRooms(keyword, page: page);
        _roomsMore = result.hasMore;
        if (page <= 1) _serverCorrection = result.correction;
        return result.items;
      default:
        // 一页全是已经显示过的时候多翻一两页（页码自己记）
        if (page <= 1) _allPage = 0;
        for (var i = 0; i < 3; i++) {
          _allPage++;
          var entries = await _searchAll(_allPage);
          if (entries.isNotEmpty || !(_roomsMore || _anchorsMore)) {
            return entries;
          }
        }
        return [];
    }
  }

  /// 综合：直播间和主播并行请求（一次就能拿到两种的平台只请求一次），合并去重
  Future<List<SearchEntry>> _searchAll(int page) async {
    if (page > 1 && !_roomsMore && !_anchorsMore) return [];
    var liveSite = site.liveSite;
    var rooms = <LiveRoomItem>[];
    var anchors = <LiveAnchorItem>[];
    if (liveSite case LiveSearchAllSite all) {
      var result = await all.searchAll(keyword, page: page);
      rooms = result.rooms;
      anchors = result.anchors;
      _roomsMore = result.hasMoreRooms;
      _anchorsMore = result.hasMoreAnchors;
      if (page <= 1) _serverCorrection = result.correction;
    } else {
      Object? roomError;
      Object? anchorError;
      var withRooms = _roomsMore;
      var withAnchors = _anchorsMore && site.hasSearchAnchors;
      await Future.wait([
        if (withRooms)
          Future.sync(() => liveSite.searchRooms(keyword, page: page)).then(
              (r) {
            rooms = r.items;
            _roomsMore = r.hasMore && r.items.isNotEmpty;
            if (page <= 1) _serverCorrection ??= r.correction;
          }, onError: (e) {
            roomError = e;
            _roomsMore = false;
          }),
        if (withAnchors)
          Future.sync(() => liveSite.searchAnchors(keyword, page: page)).then(
              (r) {
            anchors = r.items;
            _anchorsMore = r.hasMore && r.items.isNotEmpty;
            if (page <= 1) _serverCorrection ??= r.correction;
          }, onError: (e) {
            anchorError = e;
            _anchorsMore = false;
          }),
      ]);
      if (!withAnchors) _anchorsMore = false;
      // 请求了的都失败时才报错（抖音不支持搜主播，直播间又要登录：报要登录）；
      // 有一种成功（哪怕是空的）就显示它
      var allFailed = (!withRooms || roomError != null) &&
          (!withAnchors || anchorError != null) &&
          (withRooms || withAnchors);
      if (allFailed) {
        if (roomError is LoginRequiredError) throw roomError!;
        if (anchorError is LoginRequiredError) throw anchorError!;
        throw (roomError ?? anchorError)!;
      } else if (roomError != null || anchorError != null) {
        Log.logPrint(roomError ?? anchorError);
      }
    }
    var entries = mergeSearchEntries(
      keyword: keyword,
      rooms: rooms,
      anchors: anchors,
      exclude: _shown,
    );
    _shown.addAll(entries.map((e) => e.roomId));
    return entries;
  }

  /// 第一页出来以后：显示“你是不是要找”，综合模式下结果少时按拼音、简体补充搜索
  void _afterFirstPage(List items) {
    var generation = _generation;
    var input = keyword;
    _updateCorrection();
    if (searchMode.value == SearchMode.all) {
      rescueDone = _rescue(
        generation,
        input,
        items.whereType<SearchEntry>().toList(),
      );
    }
  }

  /// 找“你是不是要找”的主播：关注和看过的 → 平台的主播卡片 → 结果里的（含补救结果）
  void _updateCorrection() {
    var input = keyword;
    var others = <String>[
      ...?cachedSuggestions
          ?.call(site, input)
          ?.map((e) => e.userName ?? e.text),
      for (var item in list) _streamerName(item),
    ];
    correction.value = searchDidYouMean(
      input,
      local: localNames?.call(site.id, input) ?? const [],
      others: others.where((e) => e.isNotEmpty),
      serverCorrection: _serverCorrection,
    );
  }

  static String _streamerName(Object? item) {
    if (item is SearchEntry) return item.userName;
    if (item is LiveAnchorItem) return item.userName;
    if (item is LiveRoomItem) return item.userName;
    return "";
  }

  /// 最近一次补救搜索（测试等它结束）
  Future<void> rescueDone = Future.value();

  /// 补救搜索（每次搜索最多两次额外请求），找到的插进结果里，标“按拼音匹配”等
  Future<void> _rescue(
    int generation,
    String input,
    List<SearchEntry> entries,
  ) async {
    var queries = searchRescueQueries(
      input,
      entries,
      serverHandlesTraditional:
          site.id == Constant.kBiliBili || site.id == Constant.kHuya,
    );
    if (queries.isEmpty) return;
    rescuing.value = true;
    try {
      for (var q in queries) {
        List<SearchEntry> found;
        try {
          found = await _searchFor(q.keyword, q.tag);
        } catch (e) {
          Log.d("补充搜索失败（${site.id}，${q.keyword}）：$e", false);
          continue;
        }
        if (generation != _generation || input != keyword) return;
        var directId = direct.value?.roomId;
        found = found.where((e) => e.roomId != directId).toList();
        var merged = mergeRescuedEntries(
          input,
          list.whereType<Object>().toList(),
          found,
        );
        if (merged.length != list.length) {
          list.value = List<dynamic>.of(merged);
          _shown.addAll(found.map((e) => e.roomId));
          pageEmpty.value = list.isEmpty;
          // 补到的主播（如按全拼找到的本人）也可以是“你是不是要找”
          _updateCorrection();
        }
      }
    } finally {
      if (generation == _generation) rescuing.value = false;
    }
  }

  /// 用别的词搜第一页：一次能拿两种的平台搜一次，其他只搜主播（要找的是名字）
  Future<List<SearchEntry>> _searchFor(String query, String tag) async {
    var liveSite = site.liveSite;
    if (liveSite case LiveSearchAllSite all) {
      var r = await all.searchAll(query);
      return mergeSearchEntries(
        keyword: keyword,
        rooms: r.rooms,
        anchors: r.anchors,
        tag: tag,
      );
    }
    if (site.hasSearchAnchors && site.id != Constant.kDouyin) {
      var r = await liveSite.searchAnchors(query);
      return mergeSearchEntries(
        keyword: keyword,
        rooms: const [],
        anchors: r.items,
        tag: tag,
      );
    }
    var r = await liveSite.searchRooms(query);
    return mergeSearchEntries(
      keyword: keyword,
      rooms: r.items,
      anchors: const [],
      tag: tag,
    );
  }

  void clear() {
    _generation++;
    pageEmpty.value = false;
    needLogin.value = false;
    direct.value = null;
    correction.value = null;
    rescuing.value = false;
    list.clear();
  }
}

/// 要登录才能搜索时显示的说明
String searchLoginHint(LoginRequiredError e) {
  if (e.siteId == "douyin") {
    return "{message}\n到 设置 → 账号 → 抖音直播 填网页版登录后的 Cookie".tf({"message": e.message});
  }
  return "{message}\n请先到 设置 → 账号 登录".tf({"message": e.message});
}
