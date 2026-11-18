import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/app_update/release_api.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';
import 'package:simple_live_app/services/app_update/update_config.dart';
import 'package:simple_live_app/services/app_update/update_settings.dart';

/// 一个下载源：直连 GitHub（[prefix] 为空），或者在下载地址前面加镜像的前缀
class DownloadSource {
  final String id;
  final String label;
  final String prefix;

  const DownloadSource(this.id, this.label, this.prefix);

  bool get isDirect => prefix.isEmpty;

  String wrap(String url) => isDirect ? url : "$prefix$url";

  static DownloadSource get direct =>
      DownloadSource(UpdateSettings.sourceDirect, "直连 GitHub".t, "");

  /// 设置里选的下载源对应哪些源、要不要先测速：
  /// - 自动：直连、内置镜像和填了的自定义前缀，测速后排序；
  /// - 直连：只有直连；
  /// - 某个镜像、自定义：先用它，不行再直连
  static ({List<DownloadSource> sources, bool probe}) forSetting(
    String setting,
    UpdateConfig config,
    String customPrefix, {
    bool tempLinks = false,
  }) {
    DownloadSource mirror(UpdateMirror m) =>
        DownloadSource(m.id, m.name, m.prefix);
    var custom = customPrefix.isEmpty
        ? null
        : DownloadSource(UpdateSettings.sourceCustom, "自定义镜像".t, customPrefix);
    if (setting == UpdateSettings.sourceDirect) {
      return (sources: [direct], probe: false);
    }
    if (setting == UpdateSettings.sourceCustom && custom != null) {
      return (sources: [custom, direct], probe: false);
    }
    for (var m in config.mirrors) {
      if (m.id == setting) {
        return (sources: [mirror(m), direct], probe: false);
      }
    }
    return (
      sources: [
        direct,
        // [tempLinks]：下的是临时下载链接，只用能转发它的镜像
        for (var m in config.mirrors)
          if (!tempLinks || m.tempLinks) mirror(m),
        if (custom != null) custom,
      ],
      probe: true,
    );
  }
}

enum DownloadStage {
  /// 读校验值、换临时下载链接
  preparing,

  /// 测各个源的速度
  probing,

  downloading,

  /// 算 SHA-256
  verifying,
}

class DownloadProgress {
  final DownloadStage stage;

  /// 正在用的源
  final String source;

  final int received;

  /// 总大小；不知道时为 0
  final int total;

  /// 每秒字节数
  final double speed;

  const DownloadProgress(
    this.stage, {
    this.source = "",
    this.received = 0,
    this.total = 0,
    this.speed = 0,
  });

  double? get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

/// 点了取消
class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

/// Release 里没有这个安装包的校验值，不能装
class NoChecksumException implements Exception {
  final String detail;

  const NoChecksumException([this.detail = ""]);

  String get message => detail.isEmpty
      ? "这个版本没有提供 SHA-256 校验值，无法确认安装包完整，不安装".t
      : "读不到校验文件 SHA256SUMS.txt（{e}），无法确认安装包完整，不安装".tf({"e": detail});

  @override
  String toString() => message;
}

/// 每个源都失败了
class DownloadFailed implements Exception {
  /// 每个源失败的原因：“ghfast.top：文件校验不对”
  final List<String> reasons;

  const DownloadFailed(this.reasons);

  String get message =>
      "下载失败，所有下载源都试过了：\n{reasons}".tf({"reasons": reasons.join("\n")});

  @override
  String toString() => message;
}

class UpdateDownloadResult {
  final String path;
  final DownloadSource source;

  /// 在它之前失败的源和原因
  final List<String> skipped;

  /// 上次已经下好、校验也对，没有重新下载（[source] 这时没有用到）
  final bool reused;

  const UpdateDownloadResult(
    this.path,
    this.source, {
    this.skipped = const [],
    this.reused = false,
  });
}

/// 下载安装包：
/// - 要登录的仓库：带着令牌请求安装包的 API 地址（Accept: application/octet-stream），
///   不跟随跳转，取 Location 里几分钟有效的临时下载链接，再直连或者套镜像下载这个链接。
///   令牌只发给 api.github.com，不发给镜像；
/// - 公开仓库：直连或者套镜像下载网页上的下载地址。
///
/// 下完都和 GitHub 给的 SHA-256 比对（没有 digest 时读 Release 里的 SHA256SUMS.txt），
/// 对不上就删掉换下一个源。没有校验值时不下载。上次已经下好、大小和校验值都对的直接用
/// （取消 UAC、安装失败后再点更新不用重下）
class UpdateDownloader {
  final Dio dio;
  final UpdateConfig config;

  /// GitHub 令牌；公开仓库为空
  final String token;

  /// 测速时每个源最多等多久
  final Duration probeTimeout;

  /// 下载中途多久没收到数据算断了
  final Duration receiveTimeout;

  final DateTime Function() now;

  /// 测速下载的字节数（256 KB）
  static const int probeBytes = 262144;

  /// 临时链接用了这么久就重新换一个（GitHub 给的大约 5 分钟有效）
  static const Duration tempUrlMaxAge = Duration(minutes: 4);

  UpdateDownloader(
    this.dio, {
    required this.config,
    this.token = "",
    this.probeTimeout = const Duration(seconds: 5),
    this.receiveTimeout = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  bool get usesTempUrl => config.needsLogin;

  String? _tempUrl;
  String? _tempFor;
  DateTime? _tempAt;

  /// 用令牌把安装包的 API 地址换成临时下载链接（302 的 Location）
  Future<String> resolveTempUrl(ReleaseAsset asset) async {
    Response<ResponseBody> response;
    try {
      response = await dio.get<ResponseBody>(
        asset.apiUrl,
        options: Options(
          headers: GitHubHttp.headers(
            token,
            accept: "application/octet-stream",
          ),
          followRedirects: false,
          responseType: ResponseType.stream,
          validateStatus: GitHubHttp.anyStatus,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
    } on DioException catch (e) {
      throw GitHubHttp.networkError(e);
    }
    // 不读内容
    unawaited(response.data?.stream.listen(null).cancel());
    var status = response.statusCode ?? 0;
    var location = response.headers.value("location") ?? "";
    if (status >= 300 && status < 400 && location.isNotEmpty) {
      return Uri.parse(asset.apiUrl).resolve(location).toString();
    }
    if (status >= 300 && status < 400 || status >= 200 && status < 300) {
      throw UpdateException(
        UpdateErrorKind.badResponse,
        detail: "HTTP $status, no location",
      );
    }
    throw GitHubHttp.errorFor(
      response,
      hasToken: token.isNotEmpty,
      needsLogin: config.needsLogin,
    );
  }

  /// 下载地址：要登录的仓库是临时链接（用久了重新换），别的是网页上的下载地址
  Future<String> downloadUrl(ReleaseAsset asset) async {
    if (!usesTempUrl) {
      return asset.browserUrl;
    }
    var at = _tempAt;
    if (_tempUrl != null &&
        _tempFor == asset.apiUrl &&
        at != null &&
        now().difference(at) < tempUrlMaxAge) {
      return _tempUrl!;
    }
    var url = await resolveTempUrl(asset);
    _tempUrl = url;
    _tempFor = asset.apiUrl;
    _tempAt = now();
    return url;
  }

  /// 交给 iOS 安装工具的临时链接（还有效的）；公开仓库为 null
  Future<String?> tempUrlFor(ReleaseAsset asset) async =>
      usesTempUrl ? await downloadUrl(asset) : null;

  static final RegExp _sumLine = RegExp(r"^([0-9a-fA-F]{64})\s+\*?(.+)$");

  /// SHA256SUMS.txt（sha256sum 的输出）里 [name] 那一行的值
  static String? parseSums(String text, String name) {
    for (var line in text.split("\n")) {
      var match = _sumLine.firstMatch(line.trim());
      if (match != null && match[2]!.trim() == name) {
        return match[1]!.toLowerCase();
      }
    }
    return null;
  }

  static bool _isSumsFile(ReleaseAsset asset) =>
      asset.name.toLowerCase() == "sha256sums.txt";

  /// 安装包应有的 SHA-256。GitHub 给的 digest 优先；没有时读 SHA256SUMS.txt，
  /// 这个文件只从 GitHub 直接下载、不走镜像（镜像能同时改安装包和校验文件）。
  /// 都没有时抛 [NoChecksumException]
  Future<String> expectedSha256(
    ReleaseAsset asset,
    List<ReleaseAsset> assets,
  ) async {
    if (asset.sha256.isNotEmpty) {
      return asset.sha256;
    }
    ReleaseAsset? sums;
    for (var item in assets) {
      if (_isSumsFile(item)) {
        sums = item;
      }
    }
    if (sums == null) {
      throw const NoChecksumException();
    }
    String text;
    try {
      var url = usesTempUrl ? await resolveTempUrl(sums) : sums.browserUrl;
      var response = await dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {"User-Agent": "SimpleLive"},
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      text = response.data ?? "";
    } on DioException catch (e) {
      throw NoChecksumException(e.message ?? e.type.name);
    } on UpdateException catch (e) {
      throw NoChecksumException(e.message);
    }
    var value = parseSums(text, asset.name);
    if (value == null) {
      throw NoChecksumException("里面没有 {name}".tf({"name": asset.name}));
    }
    return value;
  }

  /// 测一个地址前 256 KB 的速度（字节每秒）；失败、超时返回 null
  Future<double?> probe(String url, {CancelToken? cancelToken}) async {
    var token = CancelToken();
    cancelToken?.whenCancel.then((_) => token.cancel());
    var watch = Stopwatch()..start();
    var received = 0;
    Future<double?> run() async {
      var response = await dio.get<ResponseBody>(
        url,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            "Range": "bytes=0-${probeBytes - 1}",
            "User-Agent": "SimpleLive",
          },
          validateStatus: GitHubHttp.anyStatus,
          sendTimeout: probeTimeout,
          receiveTimeout: probeTimeout,
        ),
      );
      var status = response.statusCode ?? 0;
      var body = response.data;
      if ((status != 200 && status != 206) || body == null) {
        return null;
      }
      // 镜像不认 Range 时会整个发过来，读够 256 KB 就停
      await for (var chunk in body.stream) {
        received += chunk.length;
        if (received >= probeBytes) {
          break;
        }
      }
      if (received == 0) {
        return null;
      }
      var ms = watch.elapsedMicroseconds / 1000;
      return received / (ms < 1 ? 1 : ms) * 1000;
    }

    // 超时后请求被取消时还会报错，不当作没处理的错误
    var running = run()..ignore();
    try {
      return await running.timeout(probeTimeout);
    } catch (_) {
      return null;
    } finally {
      token.cancel();
    }
  }

  /// 测速后的顺序：测到速度的按快慢排（一样快时直连在后）；测速失败的镜像不用；
  /// 直连测速失败时也留着，放在最后
  static List<DownloadSource> rank(
    List<DownloadSource> sources,
    Map<String, double?> speeds,
  ) {
    var ok = sources.where((e) => speeds[e.id] != null).toList();
    ok.sort((a, b) {
      var bySpeed = speeds[b.id]!.compareTo(speeds[a.id]!);
      if (bySpeed != 0) {
        return bySpeed;
      }
      if (a.isDirect != b.isDirect) {
        return a.isDirect ? 1 : -1;
      }
      return 0;
    });
    return [
      ...ok,
      ...sources.where((e) => e.isDirect && speeds[e.id] == null),
    ];
  }

  /// 各个源同时测速，返回 id → 速度
  Future<Map<String, double?>> probeAll(
    List<DownloadSource> sources,
    String url, {
    CancelToken? cancelToken,
  }) async {
    var results = await Future.wait(
      sources.map((e) => probe(e.wrap(url), cancelToken: cancelToken)),
    );
    return {
      for (var i = 0; i < sources.length; i++) sources[i].id: results[i],
    };
  }

  static Future<String> sha256OfFile(String path) async =>
      (await crypto.sha256.bind(File(path).openRead()).first).toString();

  /// 下载 [asset] 到 [directory]，校验通过后返回文件路径。
  /// [probe] 为 true 时先测速排序（“自动”），否则按 [sources] 的顺序
  Future<UpdateDownloadResult> download({
    required ReleaseAsset asset,
    required List<ReleaseAsset> assets,
    required List<DownloadSource> sources,
    required bool probe,
    required String directory,
    void Function(DownloadProgress progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    onProgress?.call(const DownloadProgress(DownloadStage.preparing));
    var expected = await expectedSha256(asset, assets);
    return downloadFile(
      name: asset.name,
      size: asset.size,
      sha256: expected,
      url: () => downloadUrl(asset),
      sources: sources,
      probe: probe,
      directory: directory,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// 按 [sources] 的顺序（[probe] 为 true 时先测速排序）下载 [url] 给的地址，存成
  /// [directory] 里的 [name]。给了 [sha256] 时比对校验值；给了 [validate] 时再看内容对不对
  /// （没有校验值的小文件，比如翻译）。不对就删掉换下一个源
  Future<UpdateDownloadResult> downloadFile({
    required String name,
    required Future<String> Function() url,
    required List<DownloadSource> sources,
    required String directory,
    int size = 0,
    String sha256 = "",
    bool probe = false,
    Future<bool> Function(String path)? validate,
    void Function(DownloadProgress progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    void cancelled() {
      if (cancelToken?.isCancelled ?? false) {
        throw const DownloadCancelled();
      }
    }

    cancelled();
    await Directory(directory).create(recursive: true);
    var target = p.join(directory, name);
    // 上次下好的（比如取消了 UAC）：大小和校验值都对就直接用，不对的删掉重下
    if (sha256.isNotEmpty && await File(target).exists()) {
      onProgress?.call(const DownloadProgress(DownloadStage.verifying));
      if (await _complete(target, size, sha256)) {
        return UpdateDownloadResult(target, DownloadSource.direct,
            reused: true);
      }
      await _delete(target);
    }
    var ordered = sources;
    if (probe && sources.length > 1) {
      onProgress?.call(const DownloadProgress(DownloadStage.probing));
      var address = await url();
      cancelled();
      ordered = rank(
        sources,
        await probeAll(sources, address, cancelToken: cancelToken),
      );
      cancelled();
    }
    var part = "$target.part";
    var reasons = <String>[];
    for (var source in ordered) {
      cancelled();
      try {
        var address = source.wrap(await url());
        await _fetch(address, part, source, size, onProgress, cancelToken);
        cancelled();
        onProgress?.call(DownloadProgress(
          DownloadStage.verifying,
          source: source.label,
        ));
        var length = await File(part).length();
        if (size > 0 && length != size) {
          reasons.add("{source}：文件大小不对".tf({"source": source.label}));
          await _delete(part);
          continue;
        }
        if (sha256.isNotEmpty &&
            await sha256OfFile(part) != sha256.toLowerCase()) {
          reasons.add("{source}：文件校验不对".tf({"source": source.label}));
          await _delete(part);
          continue;
        }
        if (validate != null && !await validate(part)) {
          reasons.add("{source}：内容不对".tf({"source": source.label}));
          await _delete(part);
          continue;
        }
        await _delete(target);
        await File(part).rename(target);
        return UpdateDownloadResult(target, source, skipped: reasons);
      } on DioException catch (e) {
        await _delete(part);
        if (CancelToken.isCancel(e)) {
          throw const DownloadCancelled();
        }
        reasons.add("{source}：{e}".tf({
          "source": source.label,
          "e": UpdateErrorText.network(e),
        }));
      } on UpdateException {
        await _delete(part);
        // 换不到临时链接（登录失效等），别的源也用不了
        rethrow;
      } on FileSystemException catch (e) {
        await _delete(part);
        reasons.add("{source}：{e}".tf({
          "source": source.label,
          "e": UpdateErrorText.file(e) ?? e.message,
        }));
      }
    }
    throw DownloadFailed(reasons);
  }

  Future<void> _fetch(
    String url,
    String path,
    DownloadSource source,
    int size,
    void Function(DownloadProgress progress)? onProgress,
    CancelToken? cancelToken,
  ) async {
    var watch = Stopwatch()..start();
    var lastTime = 0;
    var lastBytes = 0;
    var speed = 0.0;
    onProgress?.call(DownloadProgress(
      DownloadStage.downloading,
      source: source.label,
      total: size,
    ));
    await dio.download(
      url,
      path,
      cancelToken: cancelToken,
      deleteOnError: true,
      options: Options(
        headers: {"User-Agent": "SimpleLive"},
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: receiveTimeout,
      ),
      onReceiveProgress: (received, total) {
        var ms = watch.elapsedMilliseconds;
        // 每 0.5 秒算一次速度、报一次进度
        if (ms - lastTime < 500 && received != total) {
          return;
        }
        if (ms > lastTime) {
          speed = (received - lastBytes) * 1000 / (ms - lastTime);
        }
        lastTime = ms;
        lastBytes = received;
        onProgress?.call(DownloadProgress(
          DownloadStage.downloading,
          source: source.label,
          received: received,
          total: total > 0 ? total : size,
          speed: speed,
        ));
      },
    );
  }

  /// [path] 是不是下完整了：大小（知道时）和 SHA-256 都对
  static Future<bool> _complete(String path, int size, String sha256) async {
    try {
      if (size > 0 && await File(path).length() != size) {
        return false;
      }
      return await sha256OfFile(path) == sha256.toLowerCase();
    } catch (_) {
      return false;
    }
  }

  static Future<void> _delete(String path) async {
    try {
      var file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
