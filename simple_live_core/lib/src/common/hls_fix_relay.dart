import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/script/script_metadata.dart'
    show liveSourceDomainAllowed;
import 'package:simple_live_core/src/common/core_text.dart';

/// 脚本提供的列表改写（hls.rewrite）：返回改过的列表，null 表示不改
typedef HlsRewriter =
    Future<String?> Function(String text, Map<String, dynamic> info);

/// 直播源的 HLS 列表修正（playUrls 返回 hlsFix 时用，见 doc/live_source_api.md）
///
/// 有的平台给的 HLS 列表本身有错，App 的 libmpv（ffmpeg）播放时会卡住。例如 Steam 客户端直播的
/// 音频列表把每段（约 3 秒）写成 `#EXTINF:143.36`：ffmpeg 按最后一段的时长决定多久刷新一次列表，
/// 于是 140 多秒不刷新音频列表，十几秒后音频断粮、整个播放卡住。
///
/// 这里给播放器一个本机地址 `http://127.0.0.1:端口/hlsfix/<编号>/<序号>.m3u8`：
/// 主列表和各个媒体列表都从这里取（每次都实时向原地址请求、改写后返回），
/// 分段、初始化分段、密钥地址改成原地址的绝对路径，播放器直接从 CDN 下载。
///
/// 支持的修正（[supported]）：
/// - `durations`：媒体列表里比 1.5×TARGETDURATION 还长的 `#EXTINF` 改成 TARGETDURATION。
/// - `rewrite`：先交给脚本的 hls.rewrite（[register] 的 rewriter）改写。脚本的结果要通过
///   [validateHlsRewrite]（只能有 http(s)、域名在 domains 里或原列表的主机上的地址），
///   不通过、出错、超时都用原列表；连续失败 [maxRewriteFailures] 次后这一路不再调用。
class HlsFixRelay {
  HlsFixRelay._();

  static final HlsFixRelay instance = HlsFixRelay._();

  /// 支持的修正名称
  static const Set<String> supported = {"durations", "rewrite"};

  /// 交给 hls.rewrite 的列表、它返回的列表的最大长度
  static const int maxPlaylistLength = 2 * 1024 * 1024;

  /// hls.rewrite 连续失败几次后这一路不再调用
  static const int maxRewriteFailures = 3;

  /// 播放器多久没来读列表就丢掉（关掉直播间、切换清晰度后）
  static const Duration idleTimeout = Duration(minutes: 3);

  io.HttpServer? _server;
  Future<io.HttpServer>? _starting;
  final Map<String, _FixStream> _streams = {};
  final io.HttpClient _client = io.HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 15);
  Timer? _cleanup;
  int _seq = 0;

  /// 是否是本机中转的地址
  static bool isRelayUrl(String url) =>
      url.startsWith("http://127.0.0.1:") && url.contains("/hlsfix/");

  /// 是否像 HLS 地址（路径以 .m3u8 结尾）
  static bool isHlsUrl(String url) {
    var path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.endsWith(".m3u8");
  }

  /// 登记一路 HLS，返回给播放器的本机地址。[fixes] 里不认识的修正忽略；没有可用的修正时返回原地址。
  /// [headers] 是请求原地址时带的请求头（如 user-agent、referer）。
  /// `rewrite` 要有 [rewriter]；它的结果里的地址只能在 [allowedDomains]（直播源的 domains）
  /// 或原列表的主机上。[owner] 区分不同的源（同一个地址、不同的改写）
  Future<String> register(
    String url, {
    Map<String, String>? headers,
    required Iterable<String> fixes,
    HlsRewriter? rewriter,
    List<String> allowedDomains = const [],
    String? owner,
  }) async {
    var use = fixes.where(supported.contains).toSet();
    if (rewriter == null) use.remove("rewrite");
    var uri = Uri.tryParse(url);
    if (use.isEmpty || uri == null || !uri.hasScheme) return url;
    var server = await _ensureServer();
    var key = "$url\n${(use.toList()..sort()).join(",")}\n${owner ?? ""}";
    var stream = _streams[key];
    if (stream == null) {
      stream = _FixStream(
        id: (++_seq).toString(),
        root: uri,
        headers: Map.of(headers ?? const {}),
        fixes: use,
        rewriter: use.contains("rewrite") ? rewriter : null,
        allowedDomains: allowedDomains,
      );
      _streams[key] = stream;
    } else if (use.contains("rewrite")) {
      stream.rewriter = rewriter;
      stream.rewriteFailures = 0;
    }
    stream.lastRequest = DateTime.now();
    _cleanup ??= Timer.periodic(const Duration(minutes: 1), (_) => _dropIdle());
    return stream.localUrl(server.port, 0);
  }

  Future<io.HttpServer> _ensureServer() {
    var server = _server;
    if (server != null) return Future.value(server);
    return _starting ??= io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0)
        .then((s) {
          _server = s;
          s.listen(_handle, onError: (e) => CoreLog.error(e));
          return s;
        })
        .whenComplete(() => _starting = null);
  }

  void _dropIdle() {
    var now = DateTime.now();
    _streams.removeWhere((_, s) => now.difference(s.lastRequest) > idleTimeout);
    if (_streams.isEmpty) {
      _cleanup?.cancel();
      _cleanup = null;
    }
  }

  Future<void> _handle(io.HttpRequest request) async {
    var response = request.response;
    try {
      var parts = request.uri.pathSegments;
      var stream = parts.length == 3 && parts[0] == "hlsfix"
          ? _streams.values.where((s) => s.id == parts[1]).firstOrNull
          : null;
      var index = int.tryParse(
        parts.length == 3 ? parts[2].split(".").first : "",
      );
      if (stream == null ||
          index == null ||
          index < 0 ||
          index >= stream.playlists.length) {
        response.statusCode = io.HttpStatus.notFound;
        await response.close();
        return;
      }
      stream.lastRequest = DateTime.now();
      var port = _server!.port;
      var upstream = stream.playlists[index];
      var req = await _client.getUrl(upstream);
      stream.headers.forEach(req.headers.set);
      var res = await req.close().timeout(const Duration(seconds: 15));
      var bytes = await res
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(const Duration(seconds: 20));
      // 跟随重定向后的地址作为相对路径的基准
      var base = upstream;
      for (var r in res.redirects) {
        base = base.resolveUri(r.location);
      }
      var text = res.statusCode == io.HttpStatus.ok ? _tryUtf8(bytes) : null;
      if (text == null || !text.trimLeft().startsWith("#EXTM3U")) {
        // 出错或不是播放列表：原样转发（404、410 之类的状态码播放器自己会处理）
        response.statusCode = res.statusCode;
        var type = res.headers.contentType;
        if (type != null) response.headers.contentType = type;
        response.add(bytes);
        await response.close();
        return;
      }
      if (stream.rewriter != null && text.length <= maxPlaylistLength) {
        text = await _scriptRewrite(stream, text, base, upstream, index);
      }
      if (_isMaster(text)) stream.rememberVariants(text, base);
      var body = rewriteHlsPlaylist(
        text,
        base: base,
        fixes: stream.fixes,
        playlistUri: (u) => stream.localUrl(port, stream.indexOf(u)),
      );
      response.headers
        ..set(io.HttpHeaders.contentTypeHeader, "application/vnd.apple.mpegurl")
        ..set(io.HttpHeaders.cacheControlHeader, "no-cache");
      response.write(body);
      await response.close();
    } catch (e) {
      CoreLog.w("HLS 列表中转出错：${e.runtimeType}");
      try {
        response.statusCode = io.HttpStatus.badGateway;
        await response.close();
      } catch (_) {}
    }
  }

  static bool _isMaster(String text) => const LineSplitter()
      .convert(text)
      .any((l) => l.startsWith("#EXT-X-STREAM-INF"));

  /// 交给脚本的 hls.rewrite；结果不安全、出错、超时都返回原列表 [text]
  Future<String> _scriptRewrite(
    _FixStream stream,
    String text,
    Uri base,
    Uri upstream,
    int index,
  ) async {
    var info = <String, dynamic>{
      "url": base.toString(),
      "kind": _isMaster(text) ? "master" : "media",
      "index": index,
      "variant": stream.variants[upstream],
    };
    String problem;
    try {
      var out = await stream.rewriter!(text, info).timeout(
        const Duration(seconds: 4),
      );
      if (out == null || out == text) {
        stream.rewriteFailures = 0;
        return text;
      }
      var bad = validateHlsRewrite(
        out,
        base: base,
        allowedDomains: stream.allowedDomains,
        extraHosts: {base.host, upstream.host, stream.root.host},
      );
      if (bad == null) {
        stream.rewriteFailures = 0;
        return out;
      }
      problem = "结果不安全：{bad}".tf({"bad": bad});
    } on CoreError catch (e) {
      problem = e.message;
    } on TimeoutException {
      problem = "超时".t;
    } catch (e) {
      problem = e.runtimeType.toString();
    }
    if (++stream.rewriteFailures >= maxRewriteFailures) {
      stream.rewriter = null;
      CoreLog.w("hls.rewrite 连续 $maxRewriteFailures 次没有用上（$problem），这一路改用原列表");
    } else {
      CoreLog.w("hls.rewrite 没有用上（$problem），这次用原列表");
    }
    return text;
  }

  static String? _tryUtf8(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }
}

class _FixStream {
  _FixStream({
    required this.id,
    required this.root,
    required this.headers,
    required this.fixes,
    this.rewriter,
    this.allowedDomains = const [],
  }) : playlists = [root];

  final String id;
  final Uri root;
  final Map<String, String> headers;
  final Set<String> fixes;

  /// 脚本的 hls.rewrite；连续失败后置为 null
  HlsRewriter? rewriter;
  final List<String> allowedDomains;
  int rewriteFailures = 0;

  /// 媒体列表的原地址 → 主列表里引用它的那一行（#EXT-X-STREAM-INF / #EXT-X-MEDIA），给 hls.rewrite 的 info.variant
  final Map<Uri, String> variants = {};

  void rememberVariants(String master, Uri base) {
    String? pending;
    for (var line in const LineSplitter().convert(master)) {
      var l = line.trim();
      if (l.isEmpty) continue;
      if (l.startsWith("#EXT-X-STREAM-INF")) {
        pending = l;
      } else if (l.startsWith("#EXT-X-MEDIA:")) {
        var m = _uriAttr.firstMatch(l);
        if (m != null) _remember(base, m[1]!, l);
      } else if (!l.startsWith("#") && pending != null) {
        _remember(base, l, pending);
        pending = null;
      }
    }
  }

  void _remember(Uri base, String uri, String tag) {
    try {
      if (variants.length >= 128) variants.clear();
      variants[base.resolve(uri)] = tag;
    } catch (_) {}
  }

  /// 序号 → 原地址（0 是主列表）
  final List<Uri> playlists;
  DateTime lastRequest = DateTime.now();

  int indexOf(Uri uri) {
    var i = playlists.indexOf(uri);
    if (i >= 0) return i;
    // 列表地址一般固定；防止异常的列表让表无限变长
    if (playlists.length >= 64) playlists.removeRange(1, 33);
    playlists.add(uri);
    return playlists.length - 1;
  }

  String localUrl(int port, int index) =>
      "http://127.0.0.1:$port/hlsfix/$id/$index.m3u8";
}

final RegExp _uriAttr = RegExp(r'URI="([^"]*)"');

/// 改写一份 HLS 列表：
/// - 主列表：变体（#EXT-X-STREAM-INF 的下一行）和 #EXT-X-MEDIA 的 URI 交给 [playlistUri]（换成本机地址）；
/// - 媒体列表：分段地址、#EXT-X-MAP / #EXT-X-KEY 等的 URI 换成绝对地址；
/// - [fixes] 含 `durations` 时，媒体列表里比 1.5×TARGETDURATION 还长的 #EXTINF 改成 TARGETDURATION。
String rewriteHlsPlaylist(
  String text, {
  required Uri base,
  required Set<String> fixes,
  required String Function(Uri uri) playlistUri,
}) {
  var lines = const LineSplitter().convert(text);
  var master = lines.any((l) => l.startsWith("#EXT-X-STREAM-INF"));
  var target = 0.0;
  for (var l in lines) {
    if (l.startsWith("#EXT-X-TARGETDURATION:")) {
      target = double.tryParse(l.substring(22).trim()) ?? 0;
    }
  }
  var fixDurations = fixes.contains("durations") && !master && target > 0;
  var out = <String>[];
  var nextIsVariant = false;
  for (var line in lines) {
    var l = line.trim();
    if (l.isEmpty) {
      out.add(line);
      continue;
    }
    if (l.startsWith("#")) {
      if (master && l.startsWith("#EXT-X-STREAM-INF")) {
        nextIsVariant = true;
        out.add(line);
      } else if (master && l.startsWith("#EXT-X-MEDIA:")) {
        out.add(
          line.replaceAllMapped(
            _uriAttr,
            (m) => 'URI="${playlistUri(base.resolve(m[1]!))}"',
          ),
        );
      } else if (l.contains('URI="')) {
        // #EXT-X-MAP、#EXT-X-KEY、#EXT-X-I-FRAME-STREAM-INF 等：只改成绝对地址
        out.add(
          line.replaceAllMapped(
            _uriAttr,
            (m) => 'URI="${base.resolve(m[1]!)}"',
          ),
        );
      } else if (fixDurations && l.startsWith("#EXTINF:")) {
        out.add(_fixExtinf(l, target));
      } else {
        out.add(line);
      }
      continue;
    }
    // 地址行
    var uri = base.resolve(l);
    if (master && nextIsVariant) {
      out.add(playlistUri(uri));
      nextIsVariant = false;
    } else {
      out.add(uri.toString());
    }
  }
  return "${out.join("\n")}\n";
}

final RegExp _anyUriAttr = RegExp(r'URI\s*=\s*', caseSensitive: false);
final RegExp _scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.\-]*):');
final RegExp _controlChars = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]');

/// 检查脚本 hls.rewrite 返回的列表，没有问题时返回 null，否则返回原因：
/// - 以 #EXTM3U 开头，不超过 [maxLength]，没有控制字符；
/// - 每个地址行和每个 URI 属性（任何标签里的 `URI=`，必须加引号）按 [base] 解析后是 http(s)，
///   主机在 [allowedDomains]（直播源的 domains）里或是 [extraHosts]（原列表的主机）之一；
/// - 不能有 file:、data:、concat:、subfile: 之类的其它协议，不能有反斜杠（Windows 路径）。
String? validateHlsRewrite(
  String text, {
  required Uri base,
  List<String> allowedDomains = const [],
  Set<String> extraHosts = const {},
  int maxLength = HlsFixRelay.maxPlaylistLength,
}) {
  if (text.length > maxLength) return "太大（超过 {p} KB）".tf({"p": maxLength ~/ 1024});
  if (!text.trimLeft().startsWith("#EXTM3U")) return "不是 HLS 列表（没有 #EXTM3U）".t;
  if (_controlChars.hasMatch(text)) return "含有控制字符".t;
  var hosts = extraHosts.map((e) => e.toLowerCase()).toSet();
  String? checkUri(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return "空地址".t;
    if (s.contains("\\")) return "地址里有反斜杠：{s}".tf({"s": s});
    var m = _scheme.firstMatch(s);
    if (m != null) {
      var scheme = m[1]!.toLowerCase();
      if (scheme != "http" && scheme != "https") return "不允许的地址：{s}".tf({"s": s});
    }
    Uri uri;
    try {
      uri = base.resolve(s);
    } catch (_) {
      return "地址无效：{s}".tf({"s": s});
    }
    if (uri.scheme != "http" && uri.scheme != "https") return "不允许的地址：{s}".tf({"s": s});
    var host = uri.host.toLowerCase();
    if (host.isEmpty ||
        (!hosts.contains(host) &&
            !liveSourceDomainAllowed(allowedDomains, host))) {
      return "域名不在 domains 里：{host}".tf({"host": host});
    }
    return null;
  }

  for (var line in const LineSplitter().convert(text)) {
    var l = line.trim();
    if (l.isEmpty) continue;
    if (!l.startsWith("#")) {
      var problem = checkUri(l);
      if (problem != null) return problem;
      continue;
    }
    for (var m in _anyUriAttr.allMatches(l)) {
      var rest = l.substring(m.end);
      if (!rest.startsWith('"')) return "URI 属性必须加引号：{l}".tf({"l": l});
      var end = rest.indexOf('"', 1);
      if (end < 0) return "URI 属性缺少右引号：{l}".tf({"l": l});
      var problem = checkUri(rest.substring(1, end));
      if (problem != null) return problem;
    }
  }
  return null;
}

String _fixExtinf(String line, double target) {
  var body = line.substring(8);
  var comma = body.indexOf(",");
  var number = comma >= 0 ? body.substring(0, comma) : body;
  var rest = comma >= 0 ? body.substring(comma) : ",";
  var d = double.tryParse(number.trim());
  if (d == null || d <= target * 1.5) return line;
  return "#EXTINF:${target.toStringAsFixed(3)}$rest";
}
