import 'dart:async';
import 'dart:convert';

import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 斗鱼网页端聊天栏的 JS（live-next-player-aside_*.js）里打包的图片：
/// 内置表情、贵族徽章（noble-levelN）、钻粉徽章（diamond-icon）等。
///
/// 图片和 JS 的文件名都带版本号，斗鱼更新网页后会变，新表情、新徽章也只在新版里。
/// 所以进直播间时读一次房间页找到当前的 JS，按名字扫出地址，缓存 12 小时；
/// 读不到时用内置的表（douyu_emotes_table.dart、[kDouyuNobleIcons] 等）。
/// JS 只当文本解析，不执行
class DouyuAside {
  DouyuAside._();

  static const String kImageBase =
      "https://shark2.douyucdn.cn/front-publish/live-next-player-aside-master/assets/images/";
  static const Duration _ttl = Duration(hours: 12);
  static const Duration _retryAfter = Duration(minutes: 10);

  static DouyuAsideData? _data;
  static DateTime? _loadedAt;
  static DateTime? _failedAt;
  static Future<void>? _loading;

  /// 测试用：替换网络请求（房间页、JS）
  static Future<String> Function(String url)? debugFetch;

  /// 扫出来的内容，还没读到时为 null
  static DouyuAsideData? get data => _data;

  /// 内置表情“[名称]”的图片地址（扫出来的），没有时为 null
  static String? emote(String name) => _data?.named[name];

  /// 旧版表情 dyNNN 的图片地址（扫出来的），没有时为 null
  static String? legacyEmote(String code) => _data?.legacy[code];

  /// 按名字取图片地址，如“diamond-icon”“noble-level5”，没有时为 null
  static String? image(String name) => _data?.images[name];

  static Future<String> _fetch(String url) {
    if (debugFetch != null) {
      return debugFetch!(url);
    }
    return HttpClient.instance.getText(
      url,
      queryParameters: {},
      header: {
        "User-Agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
      },
    );
  }

  /// 需要时在后台读一次（[roomId] 只是用来打开一个房间页）。
  /// 读过且没过期、正在读、刚失败过时什么都不做
  static Future<void> ensure(String roomId) {
    var now = DateTime.now();
    if (_loading != null) {
      return _loading!;
    }
    if (_data != null &&
        _loadedAt != null &&
        now.difference(_loadedAt!) < _ttl) {
      return Future.value();
    }
    if (_failedAt != null && now.difference(_failedAt!) < _retryAfter) {
      return Future.value();
    }
    return _loading = _load(roomId).whenComplete(() => _loading = null);
  }

  /// 正在读时等它读完（最多 [timeout]），用于送礼消息要图标时
  static Future<void> wait({Duration timeout = const Duration(seconds: 5)}) {
    var loading = _loading;
    if (loading == null) {
      return Future.value();
    }
    return loading.timeout(timeout, onTimeout: () {});
  }

  static Future<void> _load(String roomId) async {
    try {
      // 房间页 → service-module-declaration_*.js → live-next-player-aside_*.js，
      // 文件名都带版本号，每一步都按名字找
      var html = await _fetch("https://www.douyu.com/$roomId");
      var url = findDouyuAsideUrl(html);
      for (var declaration in findDouyuDeclarationUrls(html)) {
        if (url != null) {
          break;
        }
        url = findDouyuAsideUrl(await _fetch(declaration));
      }
      if (url == null) {
        throw StateError("没有找到 live-next-player-aside 的地址".t);
      }
      var parsed = parseDouyuAside(await _fetch(url));
      if (parsed.images.isEmpty) {
        throw StateError("没有扫出图片".t);
      }
      _data = parsed;
      _loadedAt = DateTime.now();
      _failedAt = null;
    } catch (e) {
      CoreLog.error(e);
      _failedAt = DateTime.now();
    }
  }

  /// 测试用：清空缓存
  static void debugReset() {
    _data = null;
    _loadedAt = null;
    _failedAt = null;
    _loading = null;
  }
}

/// 扫出来的内容（地址都是完整的 https 地址）
class DouyuAsideData {
  /// 内置表情：名称 → 图片
  final Map<String, String> named;

  /// 旧版表情：dyNNN → 图片
  final Map<String, String> legacy;

  /// 打包的图片：不带版本号的名字（如“noble-level5”）→ 地址
  final Map<String, String> images;
  const DouyuAsideData({
    this.named = const {},
    this.legacy = const {},
    this.images = const {},
  });
}

/// 房间页里 live-next-player-aside JS 的地址，没有时为 null
String? findDouyuAsideUrl(String html) {
  var m = RegExp(
    r'(?:https?:)?//shark2\.douyucdn\.cn/front-publish/live-next-player-aside-master/js/live-next-player-aside_[0-9a-f]+\.js',
  ).firstMatch(html);
  if (m == null) {
    return null;
  }
  var url = m.group(0)!;
  return url.startsWith("//") ? "https:$url" : url;
}

/// 房间页里 service-module-declaration 脚本的地址（里面写着各模块 JS 的地址）
List<String> findDouyuDeclarationUrls(String html) {
  return {
    for (var m in RegExp(
      r'(?:https?:)?//shark2?\.douyucdn\.cn/front-publish/[\w-]+/service-module-declaration[\w-]*?_[0-9a-f]+\.js',
    ).allMatches(html))
      _https(m.group(0)!),
  }.toList();
}

/// 网页端合并内置表情的顺序（[].concat(douyu, shayuniang, …)），同名时前面的优先
const List<String> _emoteSetOrder = [
  "douyu",
  "shayuniang",
  "yuwan",
  "ruoji",
  "huojian",
  "danmujun",
  "dingzhi",
  "tes",
];

/// 把 aside JS 当文本解析：打包的图片（名字 → 地址），以及模块 e6b57 里的内置表情
DouyuAsideData parseDouyuAside(String t) {
  var images = <String, String>{};
  for (var m in RegExp(
    r'(?:https?:)?//shark2\.douyucdn\.cn/front-publish/live-next-player-aside-master/assets/images/([\w-]+?)_([0-9a-f]{6,})\.(png|gif|webp|jpg)',
  ).allMatches(t)) {
    var url = m.group(0)!;
    images.putIfAbsent(
      m.group(1)!,
      () => url.startsWith("//") ? "https:$url" : url,
    );
  }
  var (named, legacy) = _parseEmotes(t);
  return DouyuAsideData(named: named, legacy: legacy, images: images);
}

String _https(String url) => url.startsWith("//") ? "https:$url" : url;

/// 模块 e6b57：每组是“拼音 → 中文名”的表，图片经 require.context
/// （模块里的 var r={"./拼音.png": 模块 id}）指到 {e.exports="地址"} 的模块
(Map<String, String>, Map<String, String>) _parseEmotes(String t) {
  String? moduleBody(String id) {
    for (var key in ['"$id":function', '$id:function']) {
      var i = t.indexOf(key);
      if (i >= 0) {
        return t.substring(i, (i + 60000).clamp(0, t.length));
      }
    }
    return null;
  }

  String? moduleUrl(String? id) {
    if (id == null) {
      return null;
    }
    var body = moduleBody(id);
    if (body == null) {
      return null;
    }
    var url = RegExp(
      r'^[^{]*\{e\.exports="([^"]+)"\}',
    ).firstMatch(body)?.group(1);
    return url == null ? null : _https(url);
  }

  Map<String, String> contextMap(String id) {
    var body = moduleBody(id);
    var m = body == null ? null : RegExp(r'var r=(\{[^}]*\})').firstMatch(body);
    if (m == null) {
      return {};
    }
    try {
      return Map<String, String>.from(
        (json.decode(m.group(1)!) as Map).map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ),
      );
    } catch (_) {
      return {};
    }
  }

  var start = t.indexOf("e6b57:function");
  if (start < 0) {
    start = t.indexOf('"e6b57":function');
  }
  if (start < 0) {
    return ({}, {});
  }
  var seg = t.substring(start, (start + 20000).clamp(0, t.length));
  var setPattern = RegExp(
    r'(\w+)=\{((?:\w+:"[^"]*",?)+)\},\w+=\[\],\w+=Object\.keys\(\1\)\.map\('
    r'function\(e,t\)\{var \w+="(\w+)"\+\(t\+1\),\w+=\{id:\w+,'
    r'url:n\("(\w+)"\)\("\./"\+e\+"\.png"\),url1:n\("(\w+)"\)',
  );
  var sets = <String, List<(String, String)>>{};
  for (var m in setPattern.allMatches(seg)) {
    var prefix = m.group(3)!;
    var context = contextMap(m.group(4)!);
    var list = <(String, String)>[];
    for (var pair in RegExp(r'(\w+):"([^"]*)"').allMatches(m.group(2)!)) {
      var url = moduleUrl(context["./${pair.group(1)}.png"]);
      if (url != null && pair.group(2)!.isNotEmpty) {
        list.add((pair.group(2)!, url));
      }
    }
    sets[prefix] = list;
  }
  var named = <String, String>{};
  for (var prefix in [
    ..._emoteSetOrder,
    ...sets.keys.where((e) => !_emoteSetOrder.contains(e)),
  ]) {
    for (var (title, url) in sets[prefix] ?? const <(String, String)>[]) {
      named.putIfAbsent(title, () => url);
    }
  }
  // 旧版 dyNNN：{dy001:N.a,…}，N=n.n(X)，X=n("模块 id")
  var assign = {
    for (var m in RegExp(
      r'([\w$]+)=n\("(\w+)"\),[\w$]+=n\.n\(\1\)',
    ).allMatches(seg))
      m.group(1)!: m.group(2)!,
  };
  var interop = {
    for (var m in RegExp(r'([\w$]+)=n\.n\(([\w$]+)\)').allMatches(seg))
      m.group(1)!: m.group(2)!,
  };
  var legacy = <String, String>{};
  for (var obj in RegExp(r'\{((?:dy\d{3}:[\w$]+\.a,?)+)\}').allMatches(seg)) {
    for (var m in RegExp(r'(dy\d{3}):([\w$]+)\.a').allMatches(obj.group(1)!)) {
      var url = moduleUrl(assign[interop[m.group(2)!]]);
      if (url != null) {
        legacy[m.group(1)!] = url;
      }
    }
  }
  return (named, legacy);
}
