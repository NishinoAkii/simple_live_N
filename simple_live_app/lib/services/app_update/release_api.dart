import 'dart:io';

import 'package:dio/dio.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';
import 'package:simple_live_app/services/app_update/update_config.dart';

/// 查更新、登录、下载时出的错
enum UpdateErrorKind {
  /// 仓库要登录，还没登录
  needLogin,

  /// 令牌过期或者被撤销了
  loginExpired,

  /// 请求太多，GitHub 限流
  rateLimited,

  /// 账号没有这个仓库的权限
  forbidden,

  /// 没有发布过版本（或者账号看不到这个仓库）
  notFound,

  /// 网络不通、超时
  network,

  /// GitHub 返回的内容不对
  badResponse,
}

class UpdateException implements Exception {
  final UpdateErrorKind kind;

  /// 补充说明（网络错误的原因、状态码等），不翻译
  final String detail;

  /// 限流时什么时候可以再试
  final DateTime? retryAt;

  const UpdateException(this.kind, {this.detail = "", this.retryAt});

  /// 给用户看的一句话
  String get message {
    switch (kind) {
      case UpdateErrorKind.needLogin:
        return "需要先登录 GitHub".t;
      case UpdateErrorKind.loginExpired:
        return "GitHub 登录已失效，请重新登录".t;
      case UpdateErrorKind.rateLimited:
        var at = retryAt;
        if (at == null) {
          return "GitHub 请求太频繁，请稍后再试".t;
        }
        var time =
            "${at.hour.toString().padLeft(2, "0")}:${at.minute.toString().padLeft(2, "0")}";
        return "GitHub 请求太频繁，请在 {time} 以后再试".tf({"time": time});
      case UpdateErrorKind.forbidden:
        return "GitHub 拒绝了请求，请稍后再试".t;
      case UpdateErrorKind.notFound:
        return "没有找到发布的版本".t;
      case UpdateErrorKind.network:
        return detail.isEmpty
            ? "连不上 GitHub".t
            : "连不上 GitHub：{e}".tf({"e": detail});
      case UpdateErrorKind.badResponse:
        return "GitHub 返回的内容不对：{e}".tf({"e": detail});
    }
  }

  @override
  String toString() => message;
}

/// GitHub 接口共用的请求头和错误处理
class GitHubHttp {
  GitHubHttp._();

  static const String jsonAccept = "application/vnd.github+json";

  static Map<String, String> headers(
    String? token, {
    String accept = jsonAccept,
  }) =>
      {
        "Accept": accept,
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "SimpleLive",
        if (token != null && token.isNotEmpty) "Authorization": "Bearer $token",
      };

  /// 不按状态码抛异常，由 [errorFor] 统一处理
  static bool anyStatus(int? status) => true;

  /// 不是 2xx 的回应换成 [UpdateException]。要登录的仓库（[needsLogin]）不登录时
  /// GitHub 也返回 404
  static UpdateException errorFor(
    Response response, {
    required bool hasToken,
    bool needsLogin = false,
  }) {
    var status = response.statusCode ?? 0;
    String? header(String name) => response.headers.value(name);
    switch (status) {
      case 401:
        return UpdateException(
          hasToken ? UpdateErrorKind.loginExpired : UpdateErrorKind.needLogin,
        );
      case 403:
      case 429:
        if (status == 429 ||
            header("x-ratelimit-remaining") == "0" ||
            header("retry-after") != null) {
          return UpdateException(
            UpdateErrorKind.rateLimited,
            retryAt:
                _retryAt(header("x-ratelimit-reset"), header("retry-after")),
          );
        }
        return const UpdateException(UpdateErrorKind.forbidden);
      case 404:
        // 要登录的仓库不登录时 GitHub 也返回 404
        return UpdateException(
          !hasToken && needsLogin
              ? UpdateErrorKind.needLogin
              : UpdateErrorKind.notFound,
        );
    }
    return UpdateException(
      UpdateErrorKind.badResponse,
      detail: "HTTP $status",
    );
  }

  static DateTime? _retryAt(String? reset, String? retryAfter) {
    var seconds = int.tryParse(reset ?? "");
    if (seconds != null) {
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    }
    var wait = int.tryParse(retryAfter ?? "");
    if (wait != null) {
      return DateTime.now().add(Duration(seconds: wait));
    }
    return null;
  }

  /// 网络层的错误（连不上、超时）
  static UpdateException networkError(DioException e) => UpdateException(
        UpdateErrorKind.network,
        detail: UpdateErrorText.network(e),
      );
}

/// 出错的原因写成一句短话（没有写入权限、磁盘空间不足、连接超时……），认不出的原样
class UpdateErrorText {
  UpdateErrorText._();

  /// 读写文件出错：认得的错误码换成短话，认不出时为 null。[windows] 测试时指定
  static String? file(FileSystemException e, {bool? windows}) {
    var code = e.osError?.errorCode;
    if (code == null) {
      return null;
    }
    // Windows：5 拒绝访问；112、39 磁盘满。别的系统：13 EACCES、1 EPERM；28 ENOSPC
    if (windows ?? Platform.isWindows) {
      if (code == 5) return "没有写入权限".t;
      if (code == 112 || code == 39) return "磁盘空间不足".t;
    } else {
      if (code == 13 || code == 1) return "没有写入权限".t;
      if (code == 28) return "磁盘空间不足".t;
    }
    return null;
  }

  /// 网络出错：超时、连不上、证书不对、HTTP 状态码
  static String network(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return "连接超时".t;
      case DioExceptionType.connectionError:
        return "网络连接失败".t;
      case DioExceptionType.badCertificate:
        return "证书校验失败".t;
      case DioExceptionType.badResponse:
        return "HTTP ${e.response?.statusCode ?? 0}";
      default:
        break;
    }
    var inner = e.error;
    if (inner is FileSystemException) {
      return file(inner) ?? inner.message;
    }
    if (inner is SocketException || inner is TlsException) {
      return "网络连接失败".t;
    }
    return e.message ?? e.type.name;
  }

  /// 别的错误：认得的换成短话，其余原样
  static String of(Object? error) {
    if (error is UpdateException) return error.message;
    if (error is DioException) return network(error);
    if (error is FileSystemException) return file(error) ?? error.message;
    return "${error ?? ""}";
  }
}

/// 本机装的是哪个版本
class LocalBuild {
  /// 如 1.24.2
  final String version;

  /// pubspec 里的构建号，如 12402；没有时为 0
  final int build;

  /// CI 的运行编号（FORK_BUILD 的 b48）；本地编译的没有，为 0
  final int run;

  const LocalBuild(this.version, this.build, this.run);

  /// [forkBuild] 形如 b48-6b41418
  factory LocalBuild.from(
      String version, String buildNumber, String forkBuild) {
    var run = RegExp(r"^b(\d+)").firstMatch(forkBuild);
    return LocalBuild(
      version,
      int.tryParse(buildNumber.trim()) ?? 0,
      run == null ? 0 : int.parse(run[1]!),
    );
  }

  @override
  String toString() => "$version+$build${run > 0 ? " b$run" : ""}";
}

/// Release 的内容怎么读：版本号、构建号、CI 运行编号，以及和本机比新旧
class ReleaseParser {
  ReleaseParser._();

  static AppRelease parse(Map json, {required String tagPrefix}) {
    var tag = json["tag_name"]?.toString() ?? "";
    var title = json["name"]?.toString() ?? "";
    var body = json["body"]?.toString() ?? "";
    var version = versionFromTag(tag, tagPrefix);
    if (version.isEmpty) {
      version = versionFromTag(title, "");
    }
    var assets = <ReleaseAsset>[];
    var list = json["assets"];
    if (list is List) {
      for (var item in list) {
        if (item is Map) {
          assets.add(ReleaseAsset.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return AppRelease(
      tag: tag,
      version: version,
      build: changelogBuild(title, body),
      body: body,
      publishedAt: DateTime.tryParse(json["published_at"]?.toString() ?? ""),
      htmlUrl: json["html_url"]?.toString() ?? "",
      assets: assets,
    );
  }

  static final RegExp _version = RegExp(r"^v?(\d+(?:\.\d+)*)");

  /// v1.24.2 → 1.24.2；读不出来时为空
  static String versionFromTag(String tag, String prefix) {
    var text = tag.trim();
    if (prefix.isNotEmpty && text.startsWith(prefix)) {
      text = text.substring(prefix.length);
    }
    return _version.firstMatch(text)?.group(1) ?? "";
  }

  // 标题“1.24.2（12402）”，或者正文第一个标题“## 1.24.2（12402）”
  static final RegExp _titleBuild = RegExp(r"[（(]\s*(\d+)\s*[）)]");
  static final RegExp _heading =
      RegExp(r"^#{1,6}\s*v?[\d.]+\s*[（(]\s*(\d+)\s*[）)]");

  /// CHANGELOG 里的构建号（12402）；读不到时为 0
  static int changelogBuild(String title, String body) {
    var match = _titleBuild.firstMatch(title);
    if (match != null) {
      return int.parse(match[1]!);
    }
    for (var line in body.split("\n")) {
      var text = line.trim();
      if (!text.startsWith("#")) {
        continue;
      }
      // 只看第一个标题
      var heading = _heading.firstMatch(text);
      return heading == null ? 0 : int.parse(heading[1]!);
    }
    return 0;
  }

  static final RegExp _run = RegExp(r"-b(\d+)-");

  /// 安装包文件名里的 CI 运行编号（SimpleLive-v1.24.2-b48-6b41418-…）。
  /// 同一个版本重新编译过时 Release 上会有几份，取最大的；没有时为 0
  static int runNumber(Iterable<ReleaseAsset> assets) {
    var best = 0;
    for (var asset in assets) {
      var match = _run.firstMatch(asset.name);
      if (match != null) {
        var value = int.parse(match[1]!);
        if (value > best) {
          best = value;
        }
      }
    }
    return best;
  }

  /// 比较两个版本号：1.24.10 比 1.24.9 新；缺的段当作 0
  static int compareVersions(String a, String b) {
    List<int> parts(String text) => text
        .split(".")
        .map((e) => int.tryParse(RegExp(r"^\d+").stringMatch(e) ?? "") ?? 0)
        .toList();
    var x = parts(a);
    var y = parts(b);
    for (var i = 0; i < x.length || i < y.length; i++) {
      var p = i < x.length ? x[i] : 0;
      var q = i < y.length ? y[i] : 0;
      if (p != q) {
        return p.compareTo(q);
      }
    }
    return 0;
  }

  /// Release 比本机新：版本号更高；版本号一样时构建号更高；
  /// 构建号也一样（或者一边没有）时，CI 运行编号更高（同一个版本重新编译过）
  static bool isNewer(AppRelease release, LocalBuild local) {
    if (release.version.isEmpty) {
      return false;
    }
    var byVersion = compareVersions(release.version, local.version);
    if (byVersion != 0) {
      return byVersion > 0;
    }
    if (release.build > 0 && local.build > 0 && release.build != local.build) {
      return release.build > local.build;
    }
    var run = runNumber(release.assets);
    if (run > 0 && local.run > 0) {
      return run > local.run;
    }
    return false;
  }

  /// “跳过这个版本”记的值：版本号、构建号和运行编号，重新编译过的算新的一版
  static String skipId(AppRelease release) =>
      "${release.version}+${release.build}+b${runNumber(release.assets)}";

  /// 显示用的版本：1.24.2（12402）
  static String displayVersion(AppRelease release) => release.build > 0
      ? "${release.version}（${release.build}）"
      : release.version;
}

/// 读 GitHub 上最新的 Release
class ReleaseApi {
  final Dio dio;
  final UpdateConfig config;

  ReleaseApi(this.dio, this.config);

  Future<AppRelease> latest({String? token}) async {
    var hasToken = token != null && token.isNotEmpty;
    Response response;
    try {
      response = await dio.get(
        config.latestReleaseUrl,
        options: Options(
          headers: GitHubHttp.headers(token),
          responseType: ResponseType.json,
          validateStatus: GitHubHttp.anyStatus,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
    } on DioException catch (e) {
      throw GitHubHttp.networkError(e);
    }
    var status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw GitHubHttp.errorFor(
        response,
        hasToken: hasToken,
        needsLogin: config.needsLogin,
      );
    }
    var data = response.data;
    if (data is! Map || data["tag_name"] == null) {
      throw const UpdateException(
        UpdateErrorKind.badResponse,
        detail: "release",
      );
    }
    return ReleaseParser.parse(data, tagPrefix: config.tagPrefix);
  }
}
