import 'dart:async';
import 'dart:collection';

import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/search/local_search.dart';
import 'package:simple_live_app/modules/search/search_history.dart';
import 'package:simple_live_app/modules/search/text/search_text.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 最近用过的若干个（最近最少使用的先丢）
class SearchLruCache<V> {
  final int capacity;
  final LinkedHashMap<String, V> _map = LinkedHashMap();
  SearchLruCache(this.capacity);

  V? get(String key) {
    var value = _map.remove(key);
    if (value != null) {
      _map[key] = value;
    }
    return value;
  }

  /// 只看不算“用过”
  V? peek(String key) => _map[key];

  void put(String key, V value) {
    _map.remove(key);
    _map[key] = value;
    while (_map.length > capacity) {
      _map.remove(_map.keys.first);
    }
  }

  int get length => _map.length;
}

/// 各平台联想请求的节奏
class SearchSuggestPolicy {
  /// 这个平台有没有联想
  final bool enabled;

  /// 停止输入多久后请求
  final Duration debounce;

  /// 同一个平台两次请求的最短间隔
  final Duration minInterval;

  const SearchSuggestPolicy({
    this.enabled = true,
    required this.debounce,
    this.minInterval = Duration.zero,
  });

  /// 联想其实是一次主播搜索的平台（哔哩哔哩、虎牙、YouTube）：停久一点再请求，
  /// 每秒最多一次（哔哩哔哩的搜索接口请求太频繁会 -412）
  static const anchorSearch = SearchSuggestPolicy(
    debounce: Duration(milliseconds: 600),
    minInterval: Duration(seconds: 1),
  );

  /// 有直播专用联想接口的平台（斗鱼、Twitch、Kick）和直播源
  static const light = SearchSuggestPolicy(
    debounce: Duration(milliseconds: 280),
    minInterval: Duration(milliseconds: 300),
  );

  /// 没有联想（抖音：联想是视频词，搜主播要登录），只显示本地匹配
  static const none = SearchSuggestPolicy(
    enabled: false,
    debounce: Duration.zero,
  );

  static SearchSuggestPolicy of(String siteId) {
    switch (siteId) {
      case Constant.kBiliBili:
      case Constant.kHuya:
      case Constant.kYouTube:
        return anchorSearch;
      case Constant.kDouyin:
        return none;
    }
    return light;
  }
}

/// 输入时的联想：本地匹配（关注、历史）马上显示，平台的主播卡片防抖后请求
///
/// 只要直播相关的：显示顺序为本地匹配 → 当前平台的主播卡片（点了直接进直播间）；
/// 平台的通用联想词（多是视频、话题词）不要。输入框为空时显示最近搜索
class SearchSuggestController {
  /// 当前标签页的平台
  final Site Function() currentSite;

  /// 生成本地匹配的数据（关注、历史），测试时可以替换
  final LocalSearchIndex Function() buildIndex;

  final SearchHistoryStore historyStore;

  /// 各平台的请求节奏，测试时可以替换
  final SearchSuggestPolicy Function(String siteId) policyOf;

  /// 联想请求的超时，超时、出错都不提示
  final Duration timeout;

  SearchSuggestController({
    required this.currentSite,
    required this.buildIndex,
    required this.historyStore,
    this.policyOf = SearchSuggestPolicy.of,
    this.timeout = const Duration(seconds: 5),
  });

  /// 输入框里的文字
  final query = "".obs;

  /// 关注、历史里匹配的主播
  final localMatches = <LocalSearchMatch>[].obs;

  /// 当前平台的主播卡片（点了直接进直播间）
  final channels = <LiveSuggestion>[].obs;

  /// 最近搜索（输入框为空时显示）
  final history = <String>[].obs;

  /// 本地匹配看全部平台，默认只看当前平台
  final allPlatforms = false.obs;

  LocalSearchIndex? _index;
  Timer? _timer;
  int _generation = 0;

  /// 每个平台每个关键词的主播卡片（最多 50 个）
  final SearchLruCache<List<LiveSuggestion>> _cache = SearchLruCache(50);

  /// 各平台上次请求的时间、正在请求的平台（同一个平台同时只有一个请求）
  final Map<String, DateTime> _lastRequest = {};
  final Set<String> _inFlight = {};

  /// 平台联想请求的次数（测试用）
  int requestCount = 0;

  /// 关注、历史变了，下次重新生成本地匹配的数据
  void invalidateIndex() {
    _index = null;
    if (query.value.trim().isNotEmpty) {
      updateLocal();
    }
  }

  void loadHistory() {
    history.assignAll(historyStore.load());
  }

  /// 记下一次搜索
  void recordSearch(String keyword) {
    history.assignAll(historyStore.add(keyword));
  }

  void removeHistory(String keyword) {
    history.assignAll(historyStore.remove(keyword));
  }

  void clearHistory() {
    historyStore.clear();
    history.clear();
  }

  /// 中文 1 个字、拉丁字母 2 个起才请求平台联想
  static bool shouldFetch(String text) {
    var s = text.trim();
    if (s.isEmpty || s.length > 50) return false;
    if (SearchText.hasHan(s)) return true;
    return SearchText.normalize(s).replaceAll(" ", "").length >= 2;
  }

  bool _wantsFetch(Site site, String text) =>
      policyOf(site.id).enabled && shouldFetch(text);

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, fetchNow);
  }

  /// 输入变化：本地匹配马上更新，平台联想防抖（新的输入让旧的请求作废）
  void onChanged(String text) {
    if (text == query.value) return;
    query.value = text;
    _generation++;
    _timer?.cancel();
    updateLocal();
    var site = currentSite();
    if (!_wantsFetch(site, text)) {
      channels.clear();
      return;
    }
    var cached = _cache.get(_cacheKey(site, text));
    if (cached != null) {
      _apply(cached);
      return;
    }
    _schedule(policyOf(site.id).debounce);
  }

  /// 切换了平台（标签页）
  void onSiteChanged() {
    _generation++;
    _timer?.cancel();
    channels.clear();
    updateLocal();
    var site = currentSite();
    if (_wantsFetch(site, query.value)) {
      _schedule(policyOf(site.id).debounce);
    }
  }

  void toggleAllPlatforms() {
    allPlatforms.value = !allPlatforms.value;
    updateLocal();
  }

  /// 搜索了（或关掉了联想）：丢掉还没回来的请求
  void cancel() {
    _generation++;
    _timer?.cancel();
  }

  LocalSearchIndex _ensureIndex() {
    var index = _index;
    if (index != null) return index;
    try {
      return _index = buildIndex();
    } catch (e) {
      Log.logPrint(e);
      return _index = LocalSearchIndex(const []);
    }
  }

  void updateLocal() {
    var text = query.value.trim();
    if (text.isEmpty) {
      localMatches.clear();
      return;
    }
    localMatches.assignAll(_ensureIndex().search(
      text,
      siteId: allPlatforms.value ? null : currentSite().id,
    ));
  }

  /// 某个平台的关注、看过里和 [text] 匹配的主播名（“你是不是要找”用）
  List<String> localNames(String siteId, String text) {
    if (text.trim().isEmpty) return const [];
    return _ensureIndex()
        .search(text, siteId: siteId)
        .map((e) => e.item.userName)
        .toList();
  }

  String _cacheKey(Site site, String text) =>
      "${site.id}\n${text.trim().toLowerCase()}";

  /// 已经取到的主播卡片（不发请求），没有时为 null（“你是不是要找”用）
  List<LiveSuggestion>? cached(Site site, String text) =>
      _cache.peek(_cacheKey(site, text));

  /// 请求当前平台的主播卡片：先看缓存；同一个平台同时只有一个请求，
  /// 两次请求至少隔 [SearchSuggestPolicy.minInterval]，期间输入变了就等它回来再请求最新的
  Future<void> fetchNow() async {
    var text = query.value.trim();
    var site = currentSite();
    if (!_wantsFetch(site, text)) return;
    var policy = policyOf(site.id);
    var key = _cacheKey(site, text);
    var cachedItems = _cache.get(key);
    if (cachedItems != null) {
      _apply(cachedItems);
      return;
    }
    if (_inFlight.contains(site.id)) return;
    var last = _lastRequest[site.id];
    if (last != null) {
      var wait = policy.minInterval - DateTime.now().difference(last);
      if (wait > Duration.zero) {
        _schedule(wait);
        return;
      }
    }
    var generation = _generation;
    _inFlight.add(site.id);
    _lastRequest[site.id] = DateTime.now();
    requestCount++;
    List<LiveSuggestion>? items;
    try {
      var result =
          await site.liveSite.getSearchSuggestions(text).timeout(timeout);
      // 只要能直接打开的主播、直播间卡片
      items = result.where((e) => e.isRoom).toList();
      _cache.put(key, items);
    } catch (e) {
      // 联想失败不提示
      Log.d("搜索联想失败（${site.id}）：$e", false);
    } finally {
      _inFlight.remove(site.id);
    }
    if (currentSite().id != site.id) return;
    if (generation == _generation) {
      if (items != null) {
        _apply(items);
      } else {
        channels.clear();
      }
      return;
    }
    // 请求期间输入变了：按节奏请求最新的输入
    if (_wantsFetch(site, query.value)) {
      var wait = policy.minInterval -
          DateTime.now().difference(_lastRequest[site.id] ?? DateTime(0));
      _schedule(wait > Duration.zero ? wait : Duration.zero);
    }
  }

  void _apply(List<LiveSuggestion> items) {
    var site = currentSite();
    var local = localMatches
        .where((e) => e.item.siteId == site.id)
        .map((e) => e.item.roomId)
        .toSet();
    channels.assignAll(
      items.where((e) => e.isRoom && !local.contains(e.roomId)).take(5),
    );
  }

  void dispose() {
    _timer?.cancel();
  }
}
