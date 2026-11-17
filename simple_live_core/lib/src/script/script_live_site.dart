import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/script/script_convert.dart';
import 'package:simple_live_core/src/script/script_worker.dart';

/// 由 .live.js 脚本实现的平台，见 doc/live_source_api.md
///
/// 每个源在自己的后台 isolate 里运行（第一次调用时启动，空闲 3 分钟后关闭）。
/// 脚本里抛出的错误变成 [CoreError]（message 为脚本给的说明）。
class ScriptLiveSite implements LiveSite {
  final LiveSourceInfo info;

  /// 本源的 Cookie、Storage 保存目录（默认为脚本目录旁边的 ../data/<key>）
  final String dataDirectory;

  /// 脚本里 App.version 读到的值
  final String appVersion;

  late final ScriptSourceWorker _worker;

  ScriptLiveSite(this.info, {String? dataDirectory, this.appVersion = ""})
    : id = info.siteId,
      name = info.name,
      dataDirectory = dataDirectory ?? _defaultDataDirectory(info) {
    _worker = ScriptSourceWorker(
      key: info.key,
      name: info.name,
      scriptPath: info.file,
      dataDirectory: this.dataDirectory,
      appVersion: appVersion,
    );
    linkPatterns = [
      for (var link in info.links)
        if (_tryRegExp(link) case var r?) r,
    ];
  }

  static String _defaultDataDirectory(LiveSourceInfo info) {
    var sources = File(info.file).absolute.parent;
    var sep = Platform.pathSeparator;
    return "${sources.parent.path}${sep}data$sep${info.key}";
  }

  static RegExp? _tryRegExp(String pattern) {
    try {
      return RegExp(pattern);
    } catch (_) {
      return null;
    }
  }

  /// 每次调用的超时（默认 20 秒）
  static Duration get callTimeout => ScriptWorkerSettings.callTimeout;
  static set callTimeout(Duration value) =>
      ScriptWorkerSettings.callTimeout = value;

  /// 空闲多久后关闭后台 isolate（默认 3 分钟）
  static Duration get idleTimeout => ScriptWorkerSettings.idleTimeout;
  static set idleTimeout(Duration value) =>
      ScriptWorkerSettings.idleTimeout = value;

  /// 脚本单次同步执行的期限（默认 10 秒），超过后中断并重启这个源
  static Duration get scriptSliceTimeout => ScriptWorkerSettings.sliceTimeout;
  static set scriptSliceTimeout(Duration value) =>
      ScriptWorkerSettings.sliceTimeout = value;

  /// 内部使用：后台 isolate
  ScriptSourceWorker get worker => _worker;

  @override
  String id;

  @override
  String name;

  /// 粘贴链接识别，第 1 组为房间号
  late final List<RegExp> linkPatterns;

  /// 从链接或文字里找出房间号，找不到为 null
  String? matchRoomId(String text) {
    for (var pattern in linkPatterns) {
      var m = pattern.firstMatch(text);
      if (m == null) continue;
      var id = m.groupCount >= 1 ? m.group(1) : m.group(0);
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  bool _has(String capability) => info.capabilities.contains(capability);

  // 脚本实现了哪些功能（没实现的 App 不显示）
  bool get hasRecommend => _has("recommend");
  bool get hasCategories => _has("categories") && _has("categoryRooms");
  bool get hasSearch => _has("search");
  bool get hasSearchAnchors => _has("searchAnchors");
  bool get hasSuperChat => _has("superChats");
  bool get hasDanmaku => _has("danmaku");
  bool get hasAvPlayer => _has("avPlayerUrls");
  bool get hasSuggest => _has("suggest");
  bool get hasResolve => _has("resolve");

  /// 声明了网页登录（脚本的 login 字段）
  bool get hasLogin => info.login != null;

  /// 有 hls.rewrite：playUrls 返回的 hlsFix 含 "rewrite" 时，本机中转每次取到列表后用它改写
  bool get hasHlsRewrite => _has("hlsRewrite");

  /// 脚本声明的设置项（App 在源的详情页里显示）
  List<LiveSourceSetting> get settings => info.settings;

  /// 内置平台的修正（§9）：替换的平台 id，普通直播源为 null
  String? get overrides => info.overrides;

  /// 修正用的内置平台帐号（useAccount）：只交给这个源的后台 isolate，请求发往
  /// kBuiltInAccountHosts 里的主机时由 App 加请求头，脚本读不到。null 表示不带
  LiveSourceAccountAuth? get accountAuth => _worker.accountAuth;
  set accountAuth(LiveSourceAccountAuth? value) =>
      _worker.accountAuth = info.useAccount ? value : null;

  /// 设置项的当前值（key → 值，没改过的为默认值）
  Future<Map<String, dynamic>> getSettings() async =>
      settings.isEmpty ? {} : _worker.getSettings();

  /// 改设置项：{key: 值}，值为 null 时恢复默认；不合法的值抛 [CoreError]。返回改后的全部值。
  /// 只保存在本机（本源数据目录的 settings.json），脚本下次读 Settings.get 时生效
  Future<Map<String, dynamic>> setSettings(Map<String, dynamic> values) =>
      _worker.setSettings(values);

  /// 网页登录的设置，没有时为 null
  LiveSourceLogin? get login => info.login;

  /// 本源的 Cookie 罐里有没有登录 Cookie（[LiveSourceLogin.cookieNames]）
  Future<bool> isLoggedIn() async {
    var l = info.login;
    if (l == null) return false;
    return l.loggedInBy(await _worker.getCookies(l.cookieUrl));
  }

  /// 登录：把网页登录后拿到（或用户粘贴）的 Cookie（"a=1; b=2"）写进本源的 Cookie 罐，
  /// 作用于 [LiveSourceLogin.cookieUrl] 的主机。返回写入后是否已登录。Cookie 不写日志
  Future<bool> loginWithCookies(String cookies) async {
    var l = info.login;
    if (l == null) throw CoreError("{name} 不支持登录".tf({"name": name}));
    var text = cookies.trim();
    if (text.isEmpty) return false;
    await _worker.setCookies(l.cookieUrl, text);
    return isLoggedIn();
  }

  /// 退出登录：删除发往 [LiveSourceLogin.cookieUrl] 的全部 Cookie
  Future<void> logout() async {
    var l = info.login;
    if (l == null) return;
    await _worker.clearCookies(l.cookieUrl);
  }

  /// 当前帐号（脚本的 account()，可选）：{ loggedIn, userName?, avatar?, uid? }；
  /// 没有实现时只按 Cookie 判断是否登录
  Future<LiveSourceAccount> account() async {
    if (!_has("account")) {
      return LiveSourceAccount(loggedIn: await isLoggedIn());
    }
    var v = await _call("account", const []);
    if (v is! Map) return LiveSourceAccount(loggedIn: await isLoggedIn());
    String? optional(String key) {
      var s = v[key]?.toString().trim() ?? "";
      return s.isEmpty ? null : s;
    }

    return LiveSourceAccount(
      loggedIn: scriptBool(v["loggedIn"]),
      userName: optional("userName"),
      avatar: optional("avatar"),
      uid: optional("uid"),
    );
  }

  /// 联想调用的超时（输入时调用，比一般调用短）
  static Duration suggestTimeout = const Duration(seconds: 3);

  /// 调用脚本里源对象的任意方法（作者工具和测试用）；返回 JSON 值
  Future<dynamic> callScript(String method, [List<dynamic> args = const []]) =>
      _worker.call(method, args);

  /// 本源 Cookie 罐里发往 [url] 的 Cookie（"a=1; b=2"）
  Future<String> getCookies(String url) => _worker.getCookies(url);

  /// 写入本源的 Cookie（如登录后），格式 "a=1; b=2"，作用于 [url] 的主机
  Future<void> setCookies(String url, String cookies) =>
      _worker.setCookies(url, cookies);

  /// 关闭后台 isolate（之后再调用会重新启动）
  Future<void> shutdown() => _worker.shutdown();

  /// 彻底关闭（删除、更新源之后）
  Future<void> dispose() => _worker.dispose();

  Future<dynamic> _call(
    String method,
    List<dynamic> args, {
    Duration? timeout,
    bool countTimeout = true,
  }) async {
    if (!_has(method)) {
      throw CoreError("{name} 不支持 {method}()".tf({"name": name, "method": method}));
    }
    return _worker.call(
      method,
      args,
      timeout: timeout,
      countTimeout: countTimeout,
    );
  }

  T _convert<T>(String method, T Function() body) {
    try {
      return body();
    } on CoreError {
      rethrow;
    } catch (e) {
      var detail = e is FormatException ? e.message : e.toString();
      throw CoreError("{name}：{method}() 返回的数据格式不对（{detail}）".tf({"name": name, "method": method, "detail": detail}));
    }
  }

  @override
  LiveDanmaku getDanmaku() => ScriptLiveDanmaku(this);

  @override
  Future<List<LiveCategory>> getCategores() async {
    if (!_has("categories")) return [];
    var v = await _call("categories", const []);
    return _convert("categories", () => scriptCategories(v));
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    if (!hasSearch) {
      return LiveSearchRoomResult(hasMore: false, items: []);
    }
    var v = await _call("search", [keyword, page]);
    return _convert("search", () {
      var m = scriptMap(v, "search()");
      return LiveSearchRoomResult(
        hasMore: scriptBool(m["hasMore"]),
        items: scriptRoomItems(m["rooms"]),
      );
    });
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    if (!hasSearchAnchors) {
      return LiveSearchAnchorResult(hasMore: false, items: []);
    }
    var v = await _call("searchAnchors", [keyword, page]);
    return _convert("searchAnchors", () {
      var m = scriptMap(v, "searchAnchors()");
      return LiveSearchAnchorResult(
        hasMore: scriptBool(m["hasMore"]),
        items: scriptList(
          m["anchors"],
          "anchors",
        ).map(scriptAnchorItem).where((e) => e.roomId.isNotEmpty).toList(),
      );
    });
  }

  LiveCategoryResult _categoryResult(String method, dynamic v) {
    return _convert(method, () {
      var m = scriptMap(v, "$method()");
      return LiveCategoryResult(
        hasMore: scriptBool(m["hasMore"]),
        items: scriptRoomItems(m["rooms"]),
      );
    });
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    if (!_has("categoryRooms")) {
      return LiveCategoryResult(hasMore: false, items: []);
    }
    var v = await _call("categoryRooms", [scriptCategoryArg(category), page]);
    return _categoryResult("categoryRooms", v);
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    if (!hasRecommend) {
      return LiveCategoryResult(hasMore: false, items: []);
    }
    var v = await _call("recommend", [page]);
    return _categoryResult("recommend", v);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    var v = await _call("room", [roomId]);
    return _convert("room", () => scriptRoomDetail(v, roomId));
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) => qualitiesFor(scriptRoomArg(detail));

  /// qualities(room)：[room] 为脚本的 RoomDetail（修正用：内置平台的直播间见 scriptBuiltInRoomArg）
  Future<List<LivePlayQuality>> qualitiesFor(Map<String, dynamic> room) async {
    var v = await _call("qualities", [room]);
    return _convert("qualities", () => scriptQualities(v));
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) => playUrlsFor(scriptRoomArg(detail), scriptQualityArg(quality));

  /// playUrls(room, quality)：参数为脚本的 RoomDetail、清晰度（修正用）
  Future<LivePlayUrl> playUrlsFor(
    Map<String, dynamic> room,
    Map<String, dynamic> quality,
  ) async {
    var v = await _call("playUrls", [room, quality]);
    var url = _httpOnly(
      _convert("playUrls", () => scriptPlayUrl(v, "playUrls()")),
    );
    var fixes = scriptHlsFixes(v);
    if (fixes.isEmpty || !useHlsFix) return url;
    // hlsFix 含 "rewrite"：中转取到列表后交给脚本的 hls.rewrite，结果经过校验才用
    var rewriter = fixes.contains("rewrite") && hasHlsRewrite
        ? (String text, Map<String, dynamic> info) =>
              _worker.hlsRewrite(text, info)
        : null;
    // hlsFix：HLS 地址经本机中转改写列表（见 HlsFixRelay），中转失败时用原地址
    var urls = <String>[];
    for (var u in url.urls) {
      if (!HlsFixRelay.isHlsUrl(u)) {
        urls.add(u);
        continue;
      }
      try {
        urls.add(
          await HlsFixRelay.instance.register(
            u,
            headers: url.headers,
            fixes: fixes,
            rewriter: rewriter,
            allowedDomains: info.domains,
            owner: id,
          ),
        );
      } catch (e) {
        CoreLog.w("$name：HLS 列表中转失败，改用原地址（${e.runtimeType}）");
        urls.add(u);
      }
    }
    return LivePlayUrl(urls: urls, headers: url.headers);
  }

  /// playUrls 返回 hlsFix 时是否经本机中转（测试、检查工具可以关掉看原地址）
  static bool useHlsFix = true;

  /// 只把 http(s) 地址交给播放器（file:、data: 之类的地址丢掉）
  LivePlayUrl _httpOnly(LivePlayUrl url) {
    var urls = url.urls.where((u) {
      var scheme = Uri.tryParse(u.trim())?.scheme.toLowerCase();
      return scheme == "http" || scheme == "https";
    }).toList();
    if (urls.length == url.urls.length) return url;
    CoreLog.w("$name：丢掉了 ${url.urls.length - urls.length} 个不是 http(s) 的播放地址");
    return LivePlayUrl(urls: urls, headers: url.headers);
  }

  @override
  Future<LivePlayUrl?> getAvPlayerUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) => avPlayerUrlsFor(scriptRoomArg(detail), scriptQualityArg(quality));

  /// avPlayerUrls(room, quality)：参数为脚本的 RoomDetail、清晰度（修正用）
  Future<LivePlayUrl?> avPlayerUrlsFor(
    Map<String, dynamic> room,
    Map<String, dynamic> quality,
  ) async {
    if (!hasAvPlayer) return null;
    var v = await _call("avPlayerUrls", [room, quality]);
    if (v == null) return null;
    var url = _httpOnly(
      _convert("avPlayerUrls", () => scriptPlayUrl(v, "avPlayerUrls()")),
    );
    return url.urls.isEmpty ? null : url;
  }

  /// 搜索联想，映射到脚本的 suggest(keyword)（可选，超时 [suggestTimeout]）；
  /// 没有实现时为空列表
  @override
  Future<List<LiveSuggestion>> getSearchSuggestions(String keyword) async {
    if (!hasSuggest) return [];
    // 联想超时不算进“连续超时就重启”，免得打断正在看的弹幕
    var v = await _call(
      "suggest",
      [keyword],
      timeout: suggestTimeout,
      countTimeout: false,
    );
    return _convert("suggest", () => scriptSuggestions(v));
  }

  /// 不是链接的输入（数字 ID、用户号、@名称）→ 房间号，映射到脚本的 resolve(input)（可选）；
  /// 没有实现或认不出时返回 null。App 在搜索时用它试“直达”
  Future<String?> resolveRoomId(String input) async {
    if (!hasResolve) return null;
    var v = await _call("resolve", [input]);
    if (v == null || v == false) return null;
    if (v is Map) v = v["roomId"];
    var id = scriptString(v).trim();
    return id.isEmpty ? null : id;
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    if (_has("liveStatus")) {
      var v = await _call("liveStatus", [roomId]);
      return scriptBool(v);
    }
    var detail = await getRoomDetail(roomId: roomId);
    return detail.status;
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) async {
    if (!hasSuperChat) return [];
    var v = await _call("superChats", [roomId]);
    return _convert(
      "superChats",
      () => scriptList(v, "superChats()").map(scriptSuperChat).toList(),
    );
  }
}
