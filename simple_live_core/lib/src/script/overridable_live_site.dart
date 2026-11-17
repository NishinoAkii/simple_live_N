// 内置平台 + 直播源修正（doc/live_source_api.md §9）
//
// App 用 OverridableBiliBiliSite 之类代替 BiliBiliSite：它们就是原来的类（is BiliBiliSite、
// 账号功能都不变），只是 LiveSite 的每个函数先看有没有生效的修正：
// 修正实现了这个函数就调用脚本，否则走内置代码。脚本出错、超时且“失败时改用内置”开着时，
// 记一条日志，改用内置代码。
//
// 数据怎么在两边之间传：
// - 脚本只拿到内置对象的公开字段（scriptBuiltInRoomArg、scriptBuiltInQualityArg）：
//   内置的 data、danmakuData 里可能有登录的 Cookie、uid，不交给脚本。
// - 内置代码从不拿到脚本的数据：room 被替换时，没有替换的 qualities、playUrls、弹幕用内置
//   room() 的结果（第一次用到时读取一次）；脚本给的清晰度（ScriptQualityData）交给内置代码前
//   按名字换成内置的清晰度。

import 'dart:async';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/script/script_convert.dart';

/// 一个内置平台当前生效的修正
class LiveSourceOverrideBinding {
  final ScriptLiveSite site;

  /// 失败时改用内置（默认开）
  final bool fallback;

  const LiveSourceOverrideBinding(this.site, {this.fallback = true});

  LiveSourceInfo get info => site.info;

  /// 替换的函数（kLiveSourceOverridableFunctions 里脚本实现了的）
  Set<String> get functions => site.info.overrideFunctions;

  bool has(String fn) => functions.contains(fn);
}

/// 按内置平台 id 查当前生效的修正，没有时返回 null（LiveSourceManager.activeOverride）
typedef LiveSourceOverrideLookup =
    LiveSourceOverrideBinding? Function(String builtInId);

/// 内置直播间（没有被替换的 room()）的公开字段，修正的弹幕要用：键为 danmakuData
final Expando<Map<String, dynamic>> _publicRooms = Expando();

/// 脚本给的直播间对应的内置直播间（没有替换的函数要用）：键为 ScriptDanmakuArgs
final Expando<Future<LiveRoomDetail>> _builtInDetails = Expando();

bool _expandable(dynamic v) =>
    v != null && v is! String && v is! num && v is! bool && v is! Record;

String _errorText(Object e) => e is CoreError ? e.message : e.toString();

/// 内置平台的 LiveSite 函数先看修正（用法见文件开头）
mixin OverridableLiveSite on LiveSite {
  /// App 设置：查这个平台当前生效的修正。每次调用都查，开关、安装、删除后马上生效
  LiveSourceOverrideLookup? overrideLookup;

  /// 这个平台在 App 里登录的帐号（声明了 useAccount 的修正用）；没登录时为 null。
  /// 只交给修正的后台 isolate，脚本读不到
  LiveSourceAccountAuth? overrideAccountAuth() => null;

  /// 当前生效的修正，没有时为 null
  LiveSourceOverrideBinding? get activeOverride {
    try {
      return overrideLookup?.call(id);
    } catch (_) {
      return null;
    }
  }

  /// 函数 [fn]（脚本里的名字，如 "playUrls"）现在由修正处理
  bool isOverridden(String fn) => activeOverride?.has(fn) ?? false;

  LiveSourceOverrideBinding? _binding(String fn) {
    var b = activeOverride;
    return b != null && b.has(fn) ? b : null;
  }

  /// 调用脚本之前：声明了 useAccount 的修正拿到当前的帐号（只到后台 isolate）
  ScriptLiveSite _prepare(LiveSourceOverrideBinding b) {
    var site = b.site;
    site.accountAuth = b.info.useAccount ? overrideAccountAuth() : null;
    return site;
  }

  void _logFallback(LiveSourceOverrideBinding b, String fn, Object e) {
    CoreLog.w(
      "[$name] 直播源修正 ${b.info.name} ${b.info.version} 的 $fn() 出错，"
      "改用内置：${_errorText(e)}",
    );
  }

  /// 修正实现了 [fn] 时调用脚本（出错、超时且允许时改用内置），否则走内置
  Future<T> _run<T>(
    String fn,
    Future<T> Function(ScriptLiveSite script) viaScript,
    Future<T> Function() builtIn,
  ) async {
    var b = _binding(fn);
    if (b == null) return builtIn();
    try {
      return await viaScript(_prepare(b));
    } catch (e) {
      if (!b.fallback) rethrow;
      _logFallback(b, fn, e);
      return builtIn();
    }
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) => _run(
    "recommend",
    (s) => s.getRecommendRooms(page: page),
    () => super.getRecommendRooms(page: page),
  );

  @override
  Future<List<LiveCategory>> getCategores() =>
      _run("categories", (s) => s.getCategores(), () => super.getCategores());

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) => _run(
    "categoryRooms",
    (s) => s.getCategoryRooms(category, page: page),
    () => super.getCategoryRooms(category, page: page),
  );

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) =>
      _run(
        "search",
        (s) => s.searchRooms(keyword, page: page),
        () => super.searchRooms(keyword, page: page),
      );

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) => _run(
    "searchAnchors",
    (s) => s.searchAnchors(keyword, page: page),
    () => super.searchAnchors(keyword, page: page),
  );

  @override
  Future<List<LiveSuggestion>> getSearchSuggestions(String keyword) => _run(
    "suggest",
    (s) => s.getSearchSuggestions(keyword),
    () => super.getSearchSuggestions(keyword),
  );

  @override
  Future<bool> getLiveStatus({required String roomId}) => _run(
    "liveStatus",
    (s) => s.getLiveStatus(roomId: roomId),
    () => super.getLiveStatus(roomId: roomId),
  );

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) => _run(
    "superChats",
    (s) => s.getSuperChatMessage(roomId: roomId),
    () => super.getSuperChatMessage(roomId: roomId),
  );

  /// 修正替换了 resolve 时用脚本把输入换成房间号；没有替换（或失败改用内置）时用 [builtIn]
  Future<String?> overrideResolveRoomId(
    String input,
    Future<String?> Function(String input) builtIn,
  ) => _run("resolve", (s) => s.resolveRoomId(input), () => builtIn(input));

  /// 一次就能搜到直播间和主播的平台（哔哩哔哩、虎牙）的 searchAll：修正替换了 search 或
  /// searchAnchors 时分开走（各自看有没有替换），否则用 [builtIn]
  Future<LiveSearchAllResult> overrideSearchAll(
    String keyword,
    int page,
    Future<LiveSearchAllResult> Function() builtIn,
  ) async {
    var b = activeOverride;
    if (b == null || !(b.has("search") || b.has("searchAnchors"))) {
      return builtIn();
    }
    LiveSearchRoomResult? rooms;
    LiveSearchAnchorResult? anchors;
    Object? error;
    await Future.wait([
      searchRooms(keyword, page: page).then(
        (r) {
          rooms = r;
        },
        onError: (Object e) {
          error ??= e;
        },
      ),
      searchAnchors(keyword, page: page).then(
        (r) {
          anchors = r;
        },
        onError: (Object e) {
          error ??= e;
        },
      ),
    ]);
    if (rooms == null && anchors == null) throw error!;
    return LiveSearchAllResult(
      rooms: rooms?.items ?? [],
      anchors: anchors?.items ?? [],
      hasMoreRooms: rooms?.hasMore ?? false,
      hasMoreAnchors: anchors?.hasMore ?? false,
      correction: rooms?.correction,
    );
  }

  // ---- 直播间、清晰度、播放地址：数据只在各自那边用 ----

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    var detail = await _run(
      "room",
      (s) => s.getRoomDetail(roomId: roomId),
      () => super.getRoomDetail(roomId: roomId),
    );
    _remember(detail);
    return detail;
  }

  /// 记下内置直播间的公开字段（修正的弹幕拿到的 room）
  void _remember(LiveRoomDetail detail) {
    var args = detail.danmakuData;
    if (args is ScriptDanmakuArgs || !_expandable(args)) return;
    _publicRooms[args] = scriptBuiltInRoomArg(detail);
  }

  /// 交给内置代码的直播间：脚本给的（room 被替换了）换成内置 room() 的结果
  Future<LiveRoomDetail> _builtInDetail(LiveRoomDetail detail) {
    var args = detail.danmakuData;
    if (args is! ScriptDanmakuArgs) return Future.value(detail);
    return _builtInDetailOf(args);
  }

  /// 第一次用到时读取，之后复用；失败了下次重新读
  Future<LiveRoomDetail> _builtInDetailOf(ScriptDanmakuArgs args) {
    var cached = _builtInDetails[args];
    if (cached != null) return cached;
    var future = super.getRoomDetail(roomId: scriptString(args.room["roomId"]));
    _builtInDetails[args] = future;
    future.then(
      (d) {
        _remember(d);
      },
      onError: (_) {
        _builtInDetails[args] = null;
      },
    );
    return future;
  }

  /// 修正处理这个清晰度：是这个修正给的；或者修正没有替换 qualities（清晰度都是内置的）
  bool _scriptTakes(LiveSourceOverrideBinding b, LivePlayQuality quality) {
    var data = quality.data;
    if (data is ScriptQualityData) return data.source == b.site.id;
    return !b.has("qualities");
  }

  /// 交给修正脚本的直播间：脚本给的原样；内置的只有公开字段（不带 data、danmakuData）
  Map<String, dynamic> _roomArg(LiveRoomDetail detail) =>
      detail.danmakuData is ScriptDanmakuArgs
      ? scriptRoomArg(detail)
      : scriptBuiltInRoomArg(detail);

  Map<String, dynamic> _qualityArg(LivePlayQuality quality) =>
      quality.data is ScriptQualityData
      ? scriptQualityArg(quality)
      : scriptBuiltInQualityArg(quality);

  /// 交给内置代码的清晰度：脚本给的按名字换成内置的（没有同名的用第一个）
  Future<LivePlayQuality> _builtInQuality(
    LiveRoomDetail builtInDetail,
    LivePlayQuality quality,
  ) async {
    if (quality.data is! ScriptQualityData) return quality;
    var list = await super.getPlayQualites(detail: builtInDetail);
    if (list.isEmpty) throw CoreError("{name}：没有可用的清晰度".tf({"name": name}));
    return list.firstWhere(
      (e) => e.quality == quality.quality,
      orElse: () => list.first,
    );
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    var b = _binding("qualities");
    if (b != null) {
      try {
        var list = await _prepare(b).qualitiesFor(_roomArg(detail));
        return [
          for (var q in list)
            LivePlayQuality(
              quality: q.quality,
              sort: q.sort,
              data: ScriptQualityData(q.data, b.site.id),
            ),
        ];
      } catch (e) {
        if (!b.fallback) rethrow;
        _logFallback(b, "qualities", e);
      }
    }
    return super.getPlayQualites(detail: await _builtInDetail(detail));
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    var b = _binding("playUrls");
    if (b != null && _scriptTakes(b, quality)) {
      try {
        return await _prepare(
          b,
        ).playUrlsFor(_roomArg(detail), _qualityArg(quality));
      } catch (e) {
        if (!b.fallback) rethrow;
        _logFallback(b, "playUrls", e);
      }
    }
    var d = await _builtInDetail(detail);
    return super.getPlayUrls(
      detail: d,
      quality: await _builtInQuality(d, quality),
    );
  }

  @override
  Future<LivePlayUrl?> getAvPlayerUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    var b = _binding("avPlayerUrls");
    if (b != null && _scriptTakes(b, quality)) {
      try {
        return await _prepare(
          b,
        ).avPlayerUrlsFor(_roomArg(detail), _qualityArg(quality));
      } catch (e) {
        if (!b.fallback) rethrow;
        _logFallback(b, "avPlayerUrls", e);
      }
    }
    if (detail.danmakuData is! ScriptDanmakuArgs &&
        quality.data is! ScriptQualityData) {
      return super.getAvPlayerUrls(detail: detail, quality: quality);
    }
    // 直播间或清晰度是脚本给的：换成内置的；换不了时没有系统画中画的地址（App 用 mpv 画中画）
    try {
      var d = await _builtInDetail(detail);
      var q = await _builtInQuality(d, quality);
      return await super.getAvPlayerUrls(detail: d, quality: q);
    } catch (e) {
      CoreLog.w("[$name] 系统画中画的地址读取失败：${_errorText(e)}");
      return null;
    }
  }

  // ---- 弹幕 ----

  @override
  LiveDanmaku getDanmaku() {
    var builtIn = super.getDanmaku();
    var b = activeOverride;
    if (b == null || !(b.has("danmaku") || b.has("room"))) return builtIn;
    var script = b.has("danmaku") ? b : null;
    return _OverrideDanmaku(this, builtIn, script);
  }

  /// 修正的弹幕拿到的 room：脚本给的直播间原样，内置的只有公开字段
  Map<String, dynamic> _danmakuRoom(dynamic args) {
    if (args is ScriptDanmakuArgs) return Map<String, dynamic>.from(args.room);
    if (_expandable(args)) {
      var room = _publicRooms[args];
      if (room != null) return Map<String, dynamic>.from(room);
    }
    // 斗鱼的弹幕参数就是房间号
    var roomId = args is String || args is num ? "$args" : "";
    return {"roomId": roomId, "builtIn": true};
  }

  /// 交给内置弹幕的参数：脚本给的直播间换成内置 room() 的弹幕参数
  Future<dynamic> _builtInDanmakuArgs(dynamic args) async {
    if (args is! ScriptDanmakuArgs) return args;
    return (await _builtInDetailOf(args)).danmakuData;
  }
}

/// 替换了弹幕（[binding] 不为空）或者 room 的平台的弹幕：
/// - 替换了弹幕：用修正的 danmaku.start；第一次就连不上且允许改用内置时换成内置弹幕；
/// - 只替换了 room：内置弹幕，参数换成内置 room() 的
class _OverrideDanmaku extends LiveDanmaku {
  final OverridableLiveSite site;
  final LiveDanmaku builtIn;
  final LiveSourceOverrideBinding? binding;

  _OverrideDanmaku(this.site, this.builtIn, [this.binding]);

  LiveDanmaku? _active;
  int _generation = 0;

  void _wire(LiveDanmaku inner) {
    inner.onMessage = (m) => onMessage?.call(m);
    inner.onClose = (m) => onClose?.call(m);
    inner.onReady = () => onReady?.call();
  }

  @override
  Future start(dynamic args) async {
    await stop();
    var gen = ++_generation;
    var b = binding;
    if (b == null) {
      await _startBuiltIn(args, gen);
      return;
    }
    var script = ScriptLiveDanmaku(site._prepare(b));
    _wire(script);
    script.onFirstFailure = (reason) {
      if (!b.fallback || gen != _generation) return false;
      site._logFallback(b, "danmaku", CoreError(reason));
      onClose?.call("直播源修正的弹幕没有连上（{reason}），改用内置弹幕".tf({"reason": reason}));
      unawaited(_startBuiltIn(args, gen));
      return true;
    };
    _active = script;
    await script.start(site._danmakuRoom(args));
  }

  Future<void> _startBuiltIn(dynamic args, int gen) async {
    dynamic builtInArgs;
    try {
      builtInArgs = await site._builtInDanmakuArgs(args);
    } catch (e) {
      if (gen == _generation) onClose?.call("读取弹幕参数失败：{errorText}".tf({"errorText": _errorText(e)}));
      return;
    }
    if (gen != _generation) return;
    _wire(builtIn);
    _active = builtIn;
    await builtIn.start(builtInArgs);
  }

  @override
  void heartbeat() => _active?.heartbeat();

  @override
  Future stop() async {
    _generation++;
    var active = _active;
    _active = null;
    await active?.stop();
  }
}

// ---------------------------------------------------------------------------
// App 用的内置平台（和原来的类一样，只是先看修正）
// ---------------------------------------------------------------------------

class OverridableBiliBiliSite extends BiliBiliSite with OverridableLiveSite {
  @override
  LiveSourceAccountAuth? overrideAccountAuth() =>
      cookie.isEmpty ? null : LiveSourceAccountAuth(cookie: cookie);

  @override
  Future<LiveSearchAllResult> searchAll(String keyword, {int page = 1}) =>
      overrideSearchAll(
        keyword,
        page,
        () => super.searchAll(keyword, page: page),
      );
}

class OverridableDouyuSite extends DouyuSite with OverridableLiveSite {
  @override
  LiveSourceAccountAuth? overrideAccountAuth() =>
      cookie.isEmpty ? null : LiveSourceAccountAuth(cookie: cookie);
}

class OverridableHuyaSite extends HuyaSite with OverridableLiveSite {
  @override
  Future<LiveSearchAllResult> searchAll(String keyword, {int page = 1}) =>
      overrideSearchAll(
        keyword,
        page,
        () => super.searchAll(keyword, page: page),
      );
}

class OverridableDouyinSite extends DouyinSite with OverridableLiveSite {
  /// 只有用户自己设置的 Cookie（默认的 ttwid 脚本自己能拿到）
  @override
  LiveSourceAccountAuth? overrideAccountAuth() =>
      cookie.isEmpty ? null : LiveSourceAccountAuth(cookie: cookie);
}

class OverridableTwitchSite extends TwitchSite with OverridableLiveSite {
  @override
  LiveSourceAccountAuth? overrideAccountAuth() => token.isEmpty
      ? null
      : LiveSourceAccountAuth(authorization: "OAuth $token");
}

class OverridableKickSite extends KickSite with OverridableLiveSite {
  @override
  LiveSourceAccountAuth? overrideAccountAuth() => token.isEmpty
      ? null
      : LiveSourceAccountAuth(
          authorization: "Bearer $token",
          cookie: "session_token=${Uri.encodeComponent(token)}",
        );
}

class OverridableYouTubeSite extends YouTubeSite with OverridableLiveSite {
  /// 只用网页 Cookie（官方授权的令牌能做的事太多，不交给修正）
  @override
  LiveSourceAccountAuth? overrideAccountAuth() {
    var cookie = credentials.cookie;
    return cookie.isEmpty
        ? null
        : LiveSourceAccountAuth(cookie: cookie, youTube: true);
  }
}
