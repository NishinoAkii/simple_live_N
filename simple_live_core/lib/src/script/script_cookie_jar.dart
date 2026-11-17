import 'dart:async';
import 'dart:convert';
import 'dart:io';

class _StoredCookie {
  final String name;
  String value;
  final String domain;
  final bool hostOnly;
  final String path;
  bool secure;

  /// 过期时间（毫秒），null 为会话 Cookie（同样保存）
  int? expires;

  _StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.hostOnly,
    required this.path,
    this.secure = false,
    this.expires,
  });

  bool get expired =>
      expires != null && expires! <= DateTime.now().millisecondsSinceEpoch;

  bool matches(Uri uri) {
    var host = uri.host.toLowerCase();
    if (hostOnly ? host != domain : !_domainMatch(host, domain)) {
      return false;
    }
    if (secure && uri.scheme != "https" && uri.scheme != "wss") {
      return false;
    }
    var p = uri.path.isEmpty ? "/" : uri.path;
    if (p == path) return true;
    if (!p.startsWith(path)) return false;
    return path.endsWith("/") || p[path.length] == "/";
  }

  Map<String, dynamic> toJson() => {
    "name": name,
    "value": value,
    "domain": domain,
    "hostOnly": hostOnly,
    "path": path,
    "secure": secure,
    if (expires != null) "expires": expires,
  };

  static _StoredCookie? fromJson(dynamic j) {
    if (j is! Map) return null;
    try {
      return _StoredCookie(
        name: j["name"].toString(),
        value: j["value"].toString(),
        domain: j["domain"].toString(),
        hostOnly: j["hostOnly"] == true,
        path: (j["path"] ?? "/").toString(),
        secure: j["secure"] == true,
        expires: (j["expires"] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }
}

bool _domainMatch(String host, String domain) =>
    host == domain || host.endsWith(".$domain");

/// 一个直播源自己的 Cookie 罐，保存在 data/<key>/cookies.json
class LiveSourceCookieJar {
  final File? file;
  final List<_StoredCookie> _cookies = [];
  bool _loaded = false;
  Timer? _saveTimer;

  static const int _maxCookies = 400;

  LiveSourceCookieJar(this.file);

  void _load() {
    if (_loaded) return;
    _loaded = true;
    var f = file;
    if (f == null || !f.existsSync()) return;
    try {
      var list = jsonDecode(f.readAsStringSync());
      if (list is List) {
        for (var item in list) {
          var c = _StoredCookie.fromJson(item);
          if (c != null && !c.expired) _cookies.add(c);
        }
      }
    } catch (_) {}
  }

  /// 请求 [uri] 时带的 Cookie 头（"a=1; b=2"），没有时为空字符串
  String header(Uri uri) {
    _load();
    _cookies.removeWhere((c) => c.expired);
    var list = _cookies.where((c) => c.matches(uri)).toList()
      ..sort((a, b) => b.path.length.compareTo(a.path.length));
    return list.map((c) => "${c.name}=${c.value}").join("; ");
  }

  /// 保存响应里的 Set-Cookie
  void storeResponse(Uri uri, List<String>? setCookies) {
    if (setCookies == null || setCookies.isEmpty) return;
    _load();
    for (var value in setCookies) {
      _storeOne(uri, value);
    }
    _scheduleSave();
  }

  /// 脚本里 Http.setCookies(url, "a=1; b=2")：作为 [uri] 主机的 Cookie 保存，路径为 /
  void setFromHeader(Uri uri, String cookies) {
    _load();
    var host = uri.host.toLowerCase();
    for (var part in cookies.split(";")) {
      var i = part.indexOf("=");
      if (i <= 0) continue;
      var name = part.substring(0, i).trim();
      var value = part.substring(i + 1).trim();
      if (name.isEmpty) continue;
      _put(
        _StoredCookie(
          name: name,
          value: value,
          domain: host,
          hostOnly: true,
          path: "/",
        ),
      );
    }
    _scheduleSave();
  }

  void clear() {
    _load();
    _cookies.clear();
    _scheduleSave();
  }

  /// 删除请求 [uri] 时会带上的全部 Cookie（退出登录用），返回删除的个数
  int removeFor(Uri uri) {
    _load();
    var before = _cookies.length;
    _cookies.removeWhere((c) => c.expired || c.matches(uri));
    var removed = before - _cookies.length;
    if (removed > 0) _scheduleSave();
    return removed;
  }

  void _storeOne(Uri uri, String header) {
    var parts = header.split(";");
    var nv = parts.first;
    var i = nv.indexOf("=");
    if (i <= 0) return;
    var name = nv.substring(0, i).trim();
    var value = nv.substring(i + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (name.isEmpty) return;
    var host = uri.host.toLowerCase();
    String? domain;
    String? path;
    int? expires;
    int? maxAge;
    var secure = false;
    for (var attr in parts.skip(1)) {
      var j = attr.indexOf("=");
      var k = (j < 0 ? attr : attr.substring(0, j)).trim().toLowerCase();
      var v = j < 0 ? "" : attr.substring(j + 1).trim();
      switch (k) {
        case "domain":
          var d = v.toLowerCase();
          while (d.startsWith(".")) {
            d = d.substring(1);
          }
          if (d.isNotEmpty) domain = d;
          break;
        case "path":
          if (v.startsWith("/")) path = v;
          break;
        case "expires":
          expires = _parseDate(v);
          break;
        case "max-age":
          maxAge = int.tryParse(v);
          break;
        case "secure":
          secure = true;
          break;
      }
    }
    if (domain != null && !_domainMatch(host, domain)) {
      // 不能给别的域名设置 Cookie
      return;
    }
    if (path == null) {
      var p = uri.path;
      var last = p.lastIndexOf("/");
      path = last <= 0 ? "/" : p.substring(0, last);
    }
    if (maxAge != null) {
      expires = DateTime.now().millisecondsSinceEpoch + maxAge * 1000;
    }
    var cookie = _StoredCookie(
      name: name,
      value: value,
      domain: domain ?? host,
      hostOnly: domain == null,
      path: path,
      secure: secure,
      expires: expires,
    );
    if (cookie.expired) {
      _cookies.removeWhere(
        (c) =>
            c.name == cookie.name &&
            c.domain == cookie.domain &&
            c.path == cookie.path,
      );
      return;
    }
    _put(cookie);
  }

  void _put(_StoredCookie cookie) {
    _cookies.removeWhere(
      (c) =>
          c.name == cookie.name &&
          c.domain == cookie.domain &&
          c.path == cookie.path,
    );
    _cookies.add(cookie);
    while (_cookies.length > _maxCookies) {
      _cookies.removeAt(0);
    }
  }

  static int? _parseDate(String v) {
    try {
      return HttpDate.parse(v).millisecondsSinceEpoch;
    } catch (_) {}
    try {
      // dart:io 的 Cookie 解析器能认更多 Cookie 日期写法
      return Cookie.fromSetCookieValue(
        "x=y; Expires=$v",
      ).expires?.millisecondsSinceEpoch;
    } catch (_) {}
    return null;
  }

  void _scheduleSave() {
    if (file == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(flush());
    });
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    var f = file;
    if (f == null || !_loaded) return;
    try {
      _cookies.removeWhere((c) => c.expired);
      await f.parent.create(recursive: true);
      await writeFileAtomic(
        f,
        jsonEncode(_cookies.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }
}

/// 先写到旁边的临时文件再改名替换：写到一半进程退出时，原来的文件还是完整的
/// （直接覆盖写会先清空文件，中途退出就只剩空文件，下次读取时 Cookie 全部丢失）
Future<void> writeFileAtomic(File file, String content) async {
  var temp = File("${file.path}.tmp");
  await temp.writeAsString(content, flush: true);
  await temp.rename(file.path);
}
