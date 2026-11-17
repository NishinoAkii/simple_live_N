import 'dart:async';
import 'dart:collection';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// YouTube 直播 HLS 的本机中转
///
/// 直接把 YouTube 的直播地址交给播放器，实测有三个问题：
/// 1. ANDROID_VR 拿到的地址没有来源验证令牌，同一个地址约 30 秒后分片全部 403，
///    只能断流重连（2 分钟 21 个分片成功、92 个 403）；
/// 2. 低延迟直播每段 1 秒、列表里只有 3 段，播放器刷新列表稍慢就有分片过期被跳过；
/// 3. libmpv 自带的 ffmpeg 一段一段地下载，速度只有 4~5 Mbps，追不上 1080p60 的码率
///    （同一台电脑上 Dart 下载同样的分段有 15~24 Mbps），缓冲慢慢耗尽而卡顿。
///
/// 这里给播放器一个本机的固定地址 `http://127.0.0.1:端口/yt/<编号>/index.m3u8`：
/// - 定期（或遇到 403 时立刻）换新的 YouTube 地址，分段地址都用最新的令牌；
/// - 把见过的分段攒成更长的列表，开播时从稍早的位置开始，留出缓冲余量；
/// - 新分段一出现就并行下载到内存（最近二十来段），播放器从本机读取。
class YouTubeHlsRelay {
  YouTubeHlsRelay._();

  static final YouTubeHlsRelay instance = YouTubeHlsRelay._();

  /// 地址用了这么久就在后台换新的
  static const refreshAfter = Duration(seconds: 15);

  /// 超过这么久还没换成，就等新地址再返回播放列表
  static const maxAge = Duration(seconds: 25);

  /// 播放器多久没来读播放列表就丢掉（关掉直播间、切换清晰度后）
  static const idleTimeout = Duration(minutes: 3);

  /// 同一路直播同时下载的分段数
  static const int maxParallel = 3;

  /// 调试用：每次合并播放列表后回调一行摘要
  static void Function(String message)? debugLog;

  io.HttpServer? _server;
  Future<io.HttpServer>? _starting;
  final Map<String, _RelayStream> _streams = {};
  final io.HttpClient _client = io.HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 15);
  Timer? _cleanup;
  int _seq = 0;

  /// 为一路直播登记中转，返回给播放器的本机地址。
  ///
  /// [key] 相同（同一个视频、同一路码流）时复用；[resolve] 每次返回一个新的
  /// YouTube 播放列表地址，[initial] 是刚取到的地址（可以先用）。
  Future<String> register({
    required String key,
    required String userAgent,
    required Future<String> Function() resolve,
    String? initial,
  }) async {
    var server = await _ensureServer();
    var stream = _streams[key];
    if (stream == null) {
      var id = (++_seq).toString();
      stream = _RelayStream(
        id: id,
        userAgent: userAgent,
        resolve: resolve,
        segmentPrefix: "http://127.0.0.1:${server.port}/yt/$id/seg/",
        client: _client,
      );
      _streams[key] = stream;
    } else {
      stream.resolve = resolve;
      // 重新打开（重连、切回这路码流）：从稍早的位置重新开播
      stream.restart();
    }
    if (initial != null && initial.isNotEmpty) {
      stream.upstream = initial;
      stream.fetchedAt = DateTime.now();
    }
    stream.lastRequest = DateTime.now();
    _cleanup ??= Timer.periodic(const Duration(minutes: 1), (_) => _dropIdle());
    return "http://127.0.0.1:${server.port}/yt/${stream.id}/index.m3u8";
  }

  /// 是否是本机中转的地址
  static bool isRelayUrl(String url) =>
      url.startsWith("http://127.0.0.1:") && url.contains("/yt/");

  Future<io.HttpServer> _ensureServer() {
    var server = _server;
    if (server != null) {
      return Future.value(server);
    }
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
    _streams.removeWhere((_, s) {
      var idle = now.difference(s.lastRequest) > idleTimeout;
      if (idle) {
        s.dispose();
      }
      return idle;
    });
    if (_streams.isEmpty) {
      _cleanup?.cancel();
      _cleanup = null;
    }
  }

  Future<void> _handle(io.HttpRequest request) async {
    var response = request.response;
    try {
      var parts = request.uri.pathSegments;
      var stream = parts.length >= 3 && parts[0] == "yt"
          ? _streams.values.where((s) => s.id == parts[1]).firstOrNull
          : null;
      if (stream == null) {
        response.statusCode = io.HttpStatus.notFound;
        await response.close();
        return;
      }
      stream.lastRequest = DateTime.now();
      if (parts.length == 4 && parts[2] == "seg") {
        var number = int.tryParse(parts[3].split(".").first);
        if (number == null) {
          response.statusCode = io.HttpStatus.notFound;
          await response.close();
          return;
        }
        var bytes = await stream.segment(
          number,
          renew: () => _playlist(stream, forceRefresh: true),
        );
        response.headers
          ..set(io.HttpHeaders.contentTypeHeader, "video/mp2t")
          ..contentLength = bytes.length;
        response.add(bytes);
        await response.close();
        return;
      }
      var body = await _playlist(stream);
      response.headers
        ..set(io.HttpHeaders.contentTypeHeader, "application/vnd.apple.mpegurl")
        ..set(io.HttpHeaders.cacheControlHeader, "no-cache");
      response.write(body);
      await response.close();
    } catch (e) {
      CoreLog.error(e);
      try {
        response.statusCode = io.HttpStatus.badGateway;
        await response.close();
      } catch (_) {}
    }
  }

  Future<String> _playlist(
    _RelayStream stream, {
    bool forceRefresh = false,
  }) async {
    var age = stream.age;
    if (forceRefresh) {
      await stream.refresh(force: true);
    } else if (stream.upstream == null || age > maxAge) {
      await stream.refresh();
    } else if (age > refreshAfter) {
      // 后台换地址，这次先用旧的
      unawaited(stream.refresh().catchError((e) => CoreLog.error(e)));
    }
    var result = await stream.fetchText(stream.upstream!);
    if (result.$1 != io.HttpStatus.ok) {
      // 旧地址已经不能用：马上换新的再试一次
      await stream.refresh(force: true);
      result = await stream.fetchText(stream.upstream!);
      if (result.$1 != io.HttpStatus.ok) {
        throw Exception("YouTube 播放列表 HTTP {p}".tf({"p": result.$1}));
      }
    }
    return stream.merge(result.$2, stream.upstream!);
  }
}

class _RelayStream {
  _RelayStream({
    required this.id,
    required this.userAgent,
    required this.resolve,
    required this.segmentPrefix,
    required this.client,
  });

  final String id;
  final String userAgent;
  final String segmentPrefix;
  final io.HttpClient client;
  Future<String> Function() resolve;
  String? upstream;
  DateTime fetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime lastRequest = DateTime.now();
  Future<void>? _refreshing;

  Duration get age => DateTime.now().difference(fetchedAt);

  /// 换一个新的 YouTube 地址；同时只换一次
  Future<void> refresh({bool force = false}) {
    if (!force && _refreshing != null) {
      return _refreshing!;
    }
    var future = _refreshing ??= () async {
      try {
        var url = await resolve();
        if (url.isNotEmpty) {
          upstream = url;
          fetchedAt = DateTime.now();
        }
      } finally {
        _refreshing = null;
      }
    }();
    return future;
  }

  /// 播放列表最多保留这么多段
  static const int windowSize = 24;

  /// 低延迟直播开播时往前补的分段数、第一次列表额外往前退的段数
  static const int prefill = 12;
  static const int startBehind = 6;

  /// 最近见过的分段（分段号 → 分段），按分段号排序
  final SplayTreeMap<int, _Segment> _window = SplayTreeMap();
  int _targetDuration = 1;

  /// 最新一段的地址：带着最新的令牌，生成其他分段的地址用
  String? _template;

  /// 还没给播放器返回过列表（刚开播或重新打开）
  bool _first = true;

  /// 已下载或正在下载的分段
  final Map<int, Future<Uint8List>> _cache = {};
  final Queue<int> _pending = Queue();
  int _active = 0;
  bool _disposed = false;

  void restart() {
    _first = true;
  }

  void dispose() {
    _disposed = true;
    _cache.clear();
    _pending.clear();
  }

  /// 把 YouTube 新返回的播放列表并入窗口，返回给播放器的列表
  ///
  /// YouTube 低延迟直播的列表只有最近 3 段（3 秒），播放器每次刷新列表都比 1 秒稍慢，
  /// 大约每 7 秒就有一段没来得及下载就从列表里消失，只能跳过。这里把见过的分段攒下来，
  /// 列表里的分段都指向本机，由 [segment] 提前下载好。
  String merge(String playlist, String base) {
    var baseUri = Uri.parse(base);
    int? sequence;
    var index = 0;
    var ended = false;
    String? extinf;
    String? programDate;
    var seen = <int, _Segment>{};
    for (var raw in playlist.split("\n")) {
      var line = raw.trim();
      if (line.isEmpty) {
        continue;
      }
      if (line.startsWith("#EXT-X-MEDIA-SEQUENCE:")) {
        sequence = int.tryParse(line.substring(22));
      } else if (line.startsWith("#EXT-X-TARGETDURATION:")) {
        _targetDuration = int.tryParse(line.substring(22)) ?? _targetDuration;
      } else if (line.startsWith("#EXT-X-ENDLIST")) {
        ended = true;
      } else if (line.startsWith("#EXTINF")) {
        extinf = line;
      } else if (line.startsWith("#EXT-X-PROGRAM-DATE-TIME")) {
        programDate = line;
      } else if (!line.startsWith("#")) {
        var url = line.startsWith("http")
            ? line
            : baseUri.resolve(line).toString();
        var number =
            int.tryParse(
              RegExp(r'/sq/(\d+)/').firstMatch(url)?.group(1) ?? "",
            ) ??
            (sequence ?? 0) + index;
        seen[number] = _Segment(
          extinf ?? "#EXTINF:$_targetDuration.0,",
          programDate,
          url,
        );
        index++;
        extinf = null;
        programDate = null;
      }
      // 广告标记（DATERANGE、CUEPOINT）等其他标签不需要转给播放器
    }
    if (seen.isEmpty) {
      return playlist;
    }
    var lowLatency = _targetDuration <= 2;
    // 直播重新开始（分段号大幅回退）时清空
    if (_window.isNotEmpty && seen.keys.last < _window.lastKey()! - 100) {
      _window.clear();
      _cache.clear();
    }
    if (_window.isEmpty && lowLatency) {
      // 开播时 YouTube 的列表只有最近 3 段：用最新的令牌补出前面几段（直播可以回看，
      // 签名不包含分段号），播放器从稍早的位置开播，之后很快就能攒出缓冲
      var newestSeen = seen.keys.reduce((a, b) => a > b ? a : b);
      var sample = seen[newestSeen]!;
      for (var n = newestSeen - prefill; n < newestSeen; n++) {
        if (n >= 0 && !seen.containsKey(n)) {
          _window[n] = _Segment(sample.extinf, null, sample.url);
        }
      }
    }
    _window.addAll(seen);
    // 只保留以最新一段结尾的连续分段：播放器按 MEDIA-SEQUENCE + 位置 编号，中间不能有缺口
    var keep = <int>[];
    var newest = _window.lastKey()!;
    for (
      var n = newest;
      _window.containsKey(n) && keep.length < windowSize;
      n--
    ) {
      keep.add(n);
    }
    _window.removeWhere((key, _) => key < keep.last);
    _cache.removeWhere((key, _) => key < keep.last);
    _template = _window[newest]!.url;
    // 低延迟直播（每段 1–2 秒）列表里最新的一两段还在生成，只能按实时速度边生成边下载，
    // 播放器紧贴着它就永远攒不出缓冲。先不给播放器这两段，播放点晚两三秒
    var holdBack = lowLatency ? 2 : 0;
    // 第一次的列表再往前退几段：播放器默认从列表倒数第 3 段开播
    if (_first && lowLatency) {
      holdBack += startBehind;
    }
    _first = false;
    var shown = keep.length > holdBack ? keep.sublist(holdBack) : keep;
    YouTubeHlsRelay.debugLog?.call(
      "upstream ${seen.keys.first}-${seen.keys.last} window ${keep.last}-$newest "
      "(${keep.length}) shown ${shown.last}-${shown.first} cached ${_cache.length}",
    );
    // 播放器接下来要的分段先下载（从最早的开始）
    for (var n in shown.reversed.skip(
      shown.length > 6 ? shown.length - 6 : 0,
    )) {
      _prefetch(n);
    }
    var out = StringBuffer()
      ..writeln("#EXTM3U")
      ..writeln("#EXT-X-VERSION:3")
      ..writeln("#EXT-X-TARGETDURATION:$_targetDuration")
      ..writeln("#EXT-X-MEDIA-SEQUENCE:${shown.last}");
    for (var n in shown.reversed) {
      var segment = _window[n]!;
      if (segment.programDate != null) {
        out.writeln(segment.programDate);
      }
      out
        ..writeln(segment.extinf)
        ..writeln("$segmentPrefix$n.ts");
    }
    if (ended) {
      out.writeln("#EXT-X-ENDLIST");
    }
    return out.toString();
  }

  /// 第 [number] 段的数据：已经下载好的直接返回，否则马上下载
  Future<Uint8List> segment(
    int number, {
    required Future<void> Function() renew,
  }) async {
    var cached = _cache[number];
    if (cached != null) {
      try {
        return await cached;
      } catch (_) {
        _cache.remove(number);
      }
    }
    var result = await _download(number);
    if (result.$1 == io.HttpStatus.ok) {
      return result.$2;
    }
    // 令牌失效：换新地址后再试一次
    await renew();
    result = await _download(number);
    if (result.$1 != io.HttpStatus.ok) {
      throw Exception("YouTube 分段 {number} HTTP {p}".tf({"number": number, "p": result.$1}));
    }
    return result.$2;
  }

  /// 后台下载一段（同时最多 [YouTubeHlsRelay.maxParallel] 段）
  void _prefetch(int number) {
    if (_disposed || _cache.containsKey(number) || _pending.contains(number)) {
      return;
    }
    _pending.add(number);
    _pump();
  }

  void _pump() {
    while (_active < YouTubeHlsRelay.maxParallel && _pending.isNotEmpty) {
      var number = _pending.removeFirst();
      if (_cache.containsKey(number) || !_window.containsKey(number)) {
        continue;
      }
      _active++;
      var completer = Completer<Uint8List>();
      _cache[number] = completer.future;
      // 没人等的下载失败时不要变成未处理的错误
      completer.future.catchError((_) => Uint8List(0));
      _download(number)
          .then(
            (result) {
              if (result.$1 == io.HttpStatus.ok) {
                completer.complete(result.$2);
              } else {
                _cache.remove(number);
                completer.completeError(Exception("HTTP ${result.$1}"));
              }
            },
            onError: (Object e) {
              _cache.remove(number);
              completer.completeError(e);
            },
          )
          .whenComplete(() {
            _active--;
            _pump();
          });
    }
  }

  Future<(int, Uint8List)> _download(int number) async {
    var template = _template;
    var original = _window[number]?.url;
    if (template == null) {
      throw Exception("还没有分段地址".t);
    }
    var url = _withToken(template, original ?? template, number);
    var request = await client.getUrl(Uri.parse(url));
    request.headers.set(io.HttpHeaders.userAgentHeader, userAgent);
    var response = await request.close().timeout(const Duration(seconds: 15));
    var builder = BytesBuilder(copy: false);
    await response.forEach(builder.add).timeout(const Duration(seconds: 20));
    return (response.statusCode, builder.takeBytes());
  }

  Future<(int, String)> fetchText(String url) async {
    var request = await client.getUrl(Uri.parse(url));
    request.headers.set(io.HttpHeaders.userAgentHeader, userAgent);
    var response = await request.close().timeout(const Duration(seconds: 15));
    var text = await response
        .transform(const io.SystemEncoding().decoder)
        .join()
        .timeout(const Duration(seconds: 15));
    return (response.statusCode, text);
  }

  static final _sqPattern = RegExp(r'/sq/\d+/');
  static final _durPattern = RegExp(r'/dur/[\d.]+/');

  /// 用 [template]（最新令牌）生成第 [number] 段的地址，时长取原地址里的；
  /// YouTube 分段地址的签名不包含分段号（sq）和时长（dur）。地址格式不认识时保留原地址
  static String _withToken(String template, String original, int number) {
    if (!_sqPattern.hasMatch(template)) {
      return original;
    }
    var url = template.replaceFirst(_sqPattern, "/sq/$number/");
    var dur = _durPattern.firstMatch(original)?.group(0);
    if (dur != null && _durPattern.hasMatch(url)) {
      url = url.replaceFirst(_durPattern, dur);
    }
    return url;
  }
}

class _Segment {
  _Segment(this.extinf, this.programDate, this.url);

  final String extinf;
  final String? programDate;
  final String url;
}
