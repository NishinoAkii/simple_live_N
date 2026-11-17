import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';

class Sites {
  /// App 自带的平台。用 Overridable… 版本：和原来的类一样（is BiliBiliSite 等都不变），
  /// 只是装了“内置平台修正”的直播源时，修正实现了的函数改由脚本处理（doc/live_source_api.md §9）
  static final Map<String, Site> builtInSites = {
    Constant.kBiliBili: Site(
      id: Constant.kBiliBili,
      logo: "assets/images/bilibili_2.png",
      name: "哔哩哔哩",
      liveSite: OverridableBiliBiliSite(),
    ),
    Constant.kDouyu: Site(
      id: Constant.kDouyu,
      logo: "assets/images/douyu.png",
      name: "斗鱼直播",
      liveSite: OverridableDouyuSite(),
    ),
    Constant.kHuya: Site(
      id: Constant.kHuya,
      logo: "assets/images/huya.png",
      name: "虎牙直播",
      liveSite: OverridableHuyaSite(),
    ),
    Constant.kDouyin: Site(
      id: Constant.kDouyin,
      logo: "assets/images/douyin.png",
      name: "抖音直播",
      liveSite: OverridableDouyinSite(),
    ),
    Constant.kTwitch: Site(
      id: Constant.kTwitch,
      logo: "assets/images/twitch.png",
      name: "Twitch",
      liveSite: OverridableTwitchSite(),
    ),
    Constant.kKick: Site(
      id: Constant.kKick,
      logo: "assets/images/kick.png",
      name: "Kick",
      liveSite: OverridableKickSite(),
    ),
    Constant.kYouTube: Site(
      id: Constant.kYouTube,
      logo: "assets/images/youtube.png",
      name: "YouTube",
      liveSite: OverridableYouTubeSite(),
    ),
  };

  /// 已安装的直播源（脚本平台，id 为 js:<key>），由 LiveSourceService 维护
  static Map<String, Site> _scriptSites = const {};

  /// 删除后再装回来时沿用同一个 Site，页面和控制器里保存的引用不会失效
  static final Map<String, Site> _scriptSiteCache = {};

  static Map<String, Site> _allSites = Map.unmodifiable(builtInSites);

  /// 全部可用的平台：自带平台 + 已安装的直播源。
  /// 关注、历史里可能有已删除的直播源，查不到时返回 null，调用方不能用 `!`
  static Map<String, Site> get allSites => _allSites;

  /// 已安装的直播源
  static Iterable<Site> get scriptSites => _scriptSites.values;

  /// 平台列表变化（安装、更新、删除直播源）时加一，首页、分类页据此刷新标签
  static final RxInt version = 0.obs;

  static bool isScriptSiteId(String id) =>
      id.startsWith(Constant.kScriptSitePrefix);

  /// 没有安装的平台显示的文字
  static String missingSiteText(String id) => "平台未安装（{id}）".tf({"id": id});

  /// 让自带平台查当前生效的修正（LiveSourceService 启动时设置）
  static void bindOverrides(LiveSourceOverrideLookup? lookup) {
    for (var site in builtInSites.values) {
      var liveSite = site.liveSite;
      if (liveSite is OverridableLiveSite) {
        liveSite.overrideLookup = lookup;
      }
    }
  }

  /// 更新已安装的直播源；同一个 id 的 Site 对象保持不变，只替换里面的内容。
  /// 内置平台的修正（overrides）不是单独的平台，跳过
  static void setScriptSites(List<ScriptLiveSite> sources) {
    var list = sources.where((e) => !e.info.isOverride).toList();
    var next = <String, Site>{};
    var changed = list.length != _scriptSites.length;
    for (var liveSite in list) {
      var id = liveSite.id;
      if (!isScriptSiteId(id) || next.containsKey(id)) {
        continue;
      }
      var icon = liveSite.info.icon;
      var site = _scriptSiteCache[id];
      if (site == null) {
        site = Site(
          id: id,
          name: liveSite.info.name,
          logo: "",
          logoUrl: icon,
          liveSite: liveSite,
        );
        _scriptSiteCache[id] = site;
        changed = true;
      } else if (!identical(site.liveSite, liveSite) ||
          site.name != liveSite.info.name ||
          site.logoUrl != icon) {
        site.liveSite = liveSite;
        site.name = liveSite.info.name;
        site.logoUrl = icon;
        changed = true;
      }
      if (!_scriptSites.containsKey(id)) {
        changed = true;
      }
      next[id] = site;
    }
    if (!changed) {
      return;
    }
    _scriptSites = Map.unmodifiable(next);
    _allSites = Map.unmodifiable({...builtInSites, ..._scriptSites});
    version.value++;
  }

  /// 按用户的平台排序；排序里没有的（新装的直播源）放在最后，
  /// 排序里已经删除的直播源跳过
  static List<Site> get supportSites =>
      sortSites(AppSettingsController.instance.siteSort, allSites);

  static List<Site> sortSites(Iterable<String> sort, Map<String, Site> all) {
    var result = <Site>[];
    var added = <String>{};
    for (var id in sort) {
      var site = all[id];
      if (site != null && added.add(id)) {
        result.add(site);
      }
    }
    for (var site in all.values) {
      if (added.add(site.id)) {
        result.add(site);
      }
    }
    return result;
  }

  /// 显示的平台：去掉“平台排序”里关掉的（新装默认只显示最初的四个）
  static List<Site> get visibleSites {
    var hidden = AppSettingsController.instance.hiddenSites;
    return supportSites.where((e) => !hidden.contains(e.id)).toList();
  }

  /// 首页显示的平台（直播源要有推荐）
  static List<Site> get recommendSites =>
      visibleSites.where((e) => e.hasRecommend).toList();

  /// 分类页显示的平台（直播源要有分类）
  static List<Site> get categorySites =>
      visibleSites.where((e) => e.hasCategories).toList();

  /// 搜索页显示的平台（直播源要有搜索）
  static List<Site> get searchSites =>
      visibleSites.where((e) => e.hasSearch).toList();

  /// 用已安装直播源的链接规则识别 [text]，返回 (房间号, 平台)
  static (String, Site)? matchScriptLink(String text) {
    for (var site in scriptSites) {
      var script = site.script;
      if (script == null) {
        continue;
      }
      List<RegExp> patterns;
      try {
        patterns = script.linkPatterns;
      } catch (_) {
        continue;
      }
      for (var pattern in patterns) {
        var match = pattern.firstMatch(text);
        if (match == null) {
          continue;
        }
        var id = match.groupCount >= 1 ? match.group(1) ?? "" : "";
        if (id.isNotEmpty) {
          return (id, site);
        }
      }
    }
    return null;
  }
}

class Site {
  final String id;

  /// 平台的名字。自带平台的名字按界面语言给；直播源的名字不在翻译表里，原样
  String get name => _name.t;
  set name(String value) => _name = value;
  String _name;

  /// 自带平台的图标（assets 路径）；直播源为空，用 [logoUrl]
  String logo;

  /// 直播源的图标：http(s) 地址或 data: URI，可为空
  String? logoUrl;
  LiveSite liveSite;
  Site({
    required this.id,
    required this.liveSite,
    required this.logo,
    required String name,
    this.logoUrl,
  }) : _name = name;

  /// 由 .live.js 脚本实现的平台
  ScriptLiveSite? get script {
    var site = liveSite;
    return site is ScriptLiveSite ? site : null;
  }

  bool get isScript => script != null;

  /// 自带平台当前生效的修正（直播源），没有时为 null
  LiveSourceOverrideBinding? get activeOverride {
    var site = liveSite;
    return site is OverridableLiveSite ? site.activeOverride : null;
  }

  // 自带平台都有这些功能；直播源按脚本实现了哪些
  bool get hasRecommend => script?.hasRecommend ?? true;
  bool get hasCategories => script?.hasCategories ?? true;
  bool get hasSearch => script?.hasSearch ?? true;
  bool get hasSearchAnchors => script?.hasSearchAnchors ?? true;
  bool get hasDanmaku => script?.hasDanmaku ?? true;
}
