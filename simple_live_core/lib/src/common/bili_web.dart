/// 哔哩哔哩网页端（桌面版 Chrome）的浏览器身份。
///
/// 接口请求、弹幕 WebSocket 和拉流都用这里的同一个 User-Agent 和同一套请求头，
/// 和在 Windows 上用 Chrome 打开 live.bilibili.com 的直播间时一致。
///
/// Chrome 的大版本按发布节奏从日期推算（2026-01-13 发布 144，之后每 4 周一个版本），
/// 再退一个版本，相当于还没自动更新的浏览器；这样旧安装包发出的版本号也不会一直停在某个旧版本。
/// sec-ch-ua 里的占位品牌（GREASE）按 Chromium 的算法由大版本号算出。
///
/// 做不到和浏览器一致的部分：TLS 指纹、HTTP/2（Dart 的 HttpClient 只有 HTTP/1.1）和请求头的顺序。
class BiliWeb {
  BiliWeb._();

  static final DateTime _anchorDate = DateTime.utc(2026, 1, 13);
  static const int _anchorMajor = 144;

  /// 按日期推算的 Chrome 大版本号（[now] 只给测试用）
  static int chromeMajor([DateTime? now]) {
    var days = (now ?? DateTime.now()).toUtc().difference(_anchorDate).inDays;
    var major = _anchorMajor + (days < 0 ? 0 : days ~/ 28) - 1;
    return major < _anchorMajor - 1 ? _anchorMajor - 1 : major;
  }

  static String userAgent([DateTime? now]) =>
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/${chromeMajor(now)}.0.0.0 Safari/537.36";

  /// sec-ch-ua，与 Chromium 的 GetUserAgentBrandList 一致：
  /// 占位品牌 "Not?A?Brand" 的两个字符、版本号和三项的顺序都由大版本号决定
  static String secChUa([DateTime? now]) => secChUaFor(chromeMajor(now));

  static String secChUaFor(int seed) {
    const chars = [" ", "(", ":", "-", ".", "/", ")", ";", "=", "?", "_"];
    const versions = ["8", "99", "24"];
    const orders = [
      [0, 1, 2],
      [0, 2, 1],
      [1, 0, 2],
      [1, 2, 0],
      [2, 0, 1],
      [2, 1, 0],
    ];
    var grease = '"Not${chars[seed % chars.length]}A${chars[(seed + 1) % chars.length]}Brand";'
        'v="${versions[seed % versions.length]}"';
    var chromium = '"Chromium";v="$seed"';
    var chrome = '"Google Chrome";v="$seed"';
    var order = orders[seed % orders.length];
    var list = List<String>.filled(3, "");
    list[order[0]] = grease;
    list[order[1]] = chromium;
    list[order[2]] = chrome;
    return list.join(", ");
  }

  static const String origin = "https://live.bilibili.com";
  static const String acceptLanguage = "zh-CN,zh;q=0.9";

  /// 直播间页面地址，跨源请求的 Referer 按浏览器默认策略只带到源（以 / 结尾）
  static const String referer = "https://live.bilibili.com/";

  /// 直播间页面里发出的接口请求（XHR/fetch）的请求头
  static Map<String, String> apiHeaders({String cookie = ""}) => {
    "accept": "application/json, text/plain, */*",
    "accept-language": acceptLanguage,
    "origin": origin,
    "referer": referer,
    "sec-ch-ua": secChUa(),
    "sec-ch-ua-mobile": "?0",
    "sec-ch-ua-platform": '"Windows"',
    "sec-fetch-dest": "empty",
    "sec-fetch-mode": "cors",
    "sec-fetch-site": "same-site",
    "user-agent": userAgent(),
    if (cookie.isNotEmpty) "cookie": cookie,
  };

  /// 响应头 Set-Cookie（每一项一个 Cookie）里 [name] 的值，没有时为空
  static String setCookieValue(Iterable<String> setCookies, String name) {
    for (var line in setCookies) {
      // 一项是“名字=值; Path=/; Domain=...”，名字和值在第一个分号前
      var first = line.split(";").first;
      var eq = first.indexOf("=");
      if (eq > 0 && first.substring(0, eq).trim() == name) {
        var value = first.substring(eq + 1).trim();
        if (value.isNotEmpty) {
          return value;
        }
      }
    }
    return "";
  }

  /// 打开直播间页面（地址栏导航）的请求头
  static Map<String, String> pageHeaders({String cookie = ""}) => {
    "accept":
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,"
        "image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
    "accept-language": acceptLanguage,
    "sec-ch-ua": secChUa(),
    "sec-ch-ua-mobile": "?0",
    "sec-ch-ua-platform": '"Windows"',
    "sec-fetch-dest": "document",
    "sec-fetch-mode": "navigate",
    "sec-fetch-site": "none",
    "sec-fetch-user": "?1",
    "upgrade-insecure-requests": "1",
    "user-agent": userAgent(),
    if (cookie.isNotEmpty) "cookie": cookie,
  };

  /// 弹幕 WebSocket 握手的请求头（浏览器会带上 Origin、User-Agent 和 .bilibili.com 的 Cookie）
  static Map<String, String> socketHeaders({String cookie = ""}) => {
    "pragma": "no-cache",
    "cache-control": "no-cache",
    "user-agent": userAgent(),
    "origin": origin,
    "accept-language": acceptLanguage,
    if (cookie.isNotEmpty) "cookie": cookie,
  };

  /// 拉流（mpv、AVPlayer）的请求头，网页端的播放器同样带 Origin 和 Referer
  static Map<String, String> playHeaders() => {
    "user-agent": userAgent(),
    "referer": referer,
    "origin": origin,
  };
}
