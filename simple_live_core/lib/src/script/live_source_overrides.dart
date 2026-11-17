import 'package:simple_live_core/src/common/core_text.dart';

// 内置平台的直播源修正（脚本的 overrides 字段），见 doc/live_source_api.md §9
//
// 脚本写 `overrides = "bilibili"` 时不是一个新平台，而是替换 App 自带平台的一部分功能
// （脚本实现了的那些）。这里是两边（App、后台 isolate）都要用的常量和小类。

/// 可以替换的内置平台：id → 显示的名字
const Map<String, String> kBuiltInSiteNames = {
  "bilibili": "哔哩哔哩",
  "douyu": "斗鱼",
  "huya": "虎牙",
  "douyin": "抖音",
  "twitch": "Twitch",
  "kick": "Kick",
  "youtube": "YouTube",
};

/// 修正可以替换的函数（脚本里的方法名；"danmaku" 为 danmaku.start）
const List<String> kLiveSourceOverridableFunctions = [
  "recommend",
  "categories",
  "categoryRooms",
  "search",
  "searchAnchors",
  "suggest",
  "resolve",
  "room",
  "liveStatus",
  "qualities",
  "playUrls",
  "avPlayerUrls",
  "superChats",
  "danmaku",
];

/// 替换的函数给用户看的名字
String liveSourceOverrideFunctionLabel(String fn) {
  switch (fn) {
    case "recommend":
      return "推荐".t;
    case "categories":
      return "分类".t;
    case "categoryRooms":
      return "分类里的直播间".t;
    case "search":
      return "搜索直播间".t;
    case "searchAnchors":
      return "搜索主播".t;
    case "suggest":
      return "搜索联想".t;
    case "resolve":
      return "房间号识别".t;
    case "room":
      return "直播间信息".t;
    case "liveStatus":
      return "开播状态".t;
    case "qualities":
      return "清晰度".t;
    case "playUrls":
      return "播放地址".t;
    case "avPlayerUrls":
      return "系统画中画的播放地址".t;
    case "superChats":
      return "醒目留言".t;
    case "danmaku":
      return "弹幕".t;
    default:
      return fn;
  }
}

/// 内置平台的显示名字（不认识的原样返回）
String builtInSiteName(String id) => (kBuiltInSiteNames[id] ?? id).t;

/// useAccount：App 只在发往这些主机（同时也要在脚本的 domains 里）、而且是 https / wss 的请求上
/// 带上内置平台的登录信息。写死在 App 里，按内置代码实际用到的接口；脚本改不了。
/// 登录、刷新 Cookie 的主机（passport 之类）故意不在里面。
const Map<String, List<String>> kBuiltInAccountHosts = {
  "bilibili": [
    "api.live.bilibili.com",
    "live.bilibili.com",
    "api.bilibili.com",
    "*.chat.bilibili.com",
  ],
  "douyu": ["www.douyu.com", "m.douyu.com"],
  "douyin": ["live.douyin.com", "www.douyin.com"],
  "twitch": ["gql.twitch.tv"],
  "kick": ["kick.com"],
  "youtube": ["www.youtube.com"],
};

/// 内置平台在 App 里登录的帐号（useAccount 的修正用）。
///
/// 只在主 isolate 和这个源的后台 isolate 之间传，从不放进脚本引擎：脚本的 Http 请求发往
/// [kBuiltInAccountHosts] 里的主机时由 App 加上请求头，脚本读不到。
class LiveSourceAccountAuth {
  /// Cookie 头（"a=1; b=2"），没有时为空
  final String cookie;

  /// Authorization 头（如 "OAuth …"、"Bearer …"），没有时为空
  final String authorization;

  /// YouTube：每次请求按 [cookie] 里的 SAPISID 现算 SAPISIDHASH（Authorization、X-Origin）
  final bool youTube;

  const LiveSourceAccountAuth({
    this.cookie = "",
    this.authorization = "",
    this.youTube = false,
  });

  bool get isEmpty => cookie.isEmpty && authorization.isEmpty;

  Map<String, dynamic> toMessage() => {
    "cookie": cookie,
    "authorization": authorization,
    "youTube": youTube,
  };

  static LiveSourceAccountAuth? fromMessage(dynamic v) {
    if (v is! Map) return null;
    var auth = LiveSourceAccountAuth(
      cookie: v["cookie"]?.toString() ?? "",
      authorization: v["authorization"]?.toString() ?? "",
      youTube: v["youTube"] == true,
    );
    return auth.isEmpty ? null : auth;
  }

  @override
  bool operator ==(Object other) =>
      other is LiveSourceAccountAuth &&
      other.cookie == cookie &&
      other.authorization == authorization &&
      other.youTube == youTube;

  @override
  int get hashCode => Object.hash(cookie, authorization, youTube);

  // 不把 Cookie 写进日志
  @override
  String toString() => "LiveSourceAccountAuth(${isEmpty ? "空".t : "有".t})";
}

/// 一个修正现在的状态（直播源详情页显示）
class LiveSourceOverrideStatus {
  /// 正在替换内置平台
  final bool active;

  /// 给用户看的说明（“生效中”、“已关闭”、为什么没有生效）
  final String text;

  const LiveSourceOverrideStatus(this.active, this.text);
}

/// 把帐号的 Cookie 放在最前面，去掉脚本自己的 Cookie 里同名的（脚本盖不掉、也冒充不了）
String mergeAccountCookie(String account, List<String> others) {
  var names = <String>{};
  var parts = <String>[];
  for (var part in account.split(";")) {
    var p = part.trim();
    if (p.isEmpty) continue;
    var i = p.indexOf("=");
    names.add((i < 0 ? p : p.substring(0, i)).trim());
    parts.add(p);
  }
  for (var header in others) {
    for (var part in header.split(";")) {
      var p = part.trim();
      if (p.isEmpty) continue;
      var i = p.indexOf("=");
      var name = (i < 0 ? p : p.substring(0, i)).trim();
      if (names.contains(name)) continue;
      parts.add(p);
    }
  }
  return parts.join("; ");
}

/// 一个修正对用户的说明：替换了哪个平台的哪些功能、用不用帐号（安装确认、详情页）
List<String> describeLiveSourceOverride(
  String target,
  Iterable<String> functions, {
  bool useAccount = false,
}) {
  var name = builtInSiteName(target);
  var list = [
    for (var f in kLiveSourceOverridableFunctions)
      if (functions.contains(f)) liveSourceOverrideFunctionLabel(f),
  ];
  return [
    "这个直播源会替换内置的 {name} 的：{p}".tf({"name": name, "p": list.isEmpty ? "（无）".t : list.join("、".t)}),
    if (useAccount)
      ("会用你在 App 里登录的 {name} 帐号访问 "
          "{p}"
          "（App 代为加上登录信息，脚本读不到 Cookie 和令牌）").tf({"name": name, "p": (kBuiltInAccountHosts[target] ?? const []).join("、".t)}),
  ];
}
