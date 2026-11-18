/// 应用内更新共用的数据：一个 GitHub Release 和它的安装包。
///
/// 两部分代码都用它：查更新、下载、镜像（update_service / downloader）
/// 和各平台的安装（installers/）。字段名照 GitHub REST API 的 release / asset。
class ReleaseAsset {
  /// 文件名，如 SimpleLive-v1.24.2-b48-6b41418-windows-x64.zip
  final String name;

  /// 字节数
  final int size;

  /// GitHub 给的校验值，形如 "sha256:<hex>"；没有时为空
  final String digest;

  /// API 地址（/repos/{owner}/{repo}/releases/assets/{id}）。要登录的仓库带着令牌、
  /// 请求时加 Accept: application/octet-stream，GitHub 会跳到一个几分钟有效的临时下载链接
  final String apiUrl;

  /// 网页上的下载地址（公开仓库可以直接下载，也是镜像要套的地址）
  final String browserUrl;

  const ReleaseAsset({
    required this.name,
    required this.size,
    required this.digest,
    required this.apiUrl,
    required this.browserUrl,
  });

  /// 去掉 "sha256:" 前缀的十六进制校验值；没有时为空
  String get sha256 =>
      digest.startsWith("sha256:") ? digest.substring(7).toLowerCase() : "";

  factory ReleaseAsset.fromJson(Map<String, dynamic> json) => ReleaseAsset(
        name: json["name"]?.toString() ?? "",
        size: (json["size"] as num?)?.toInt() ?? 0,
        digest: json["digest"]?.toString() ?? "",
        apiUrl: json["url"]?.toString() ?? "",
        browserUrl: json["browser_download_url"]?.toString() ?? "",
      );
}

class AppRelease {
  /// 标签，如 v1.24.2
  final String tag;

  /// 版本号，如 1.24.2（从标签或标题里取）
  final String version;

  /// 构建号，如 12402；读不到时为 0
  final int build;

  /// 更新内容（Release 正文，就是 CHANGELOG 里这个版本的一节）
  final String body;

  final DateTime? publishedAt;

  /// Release 的网页地址
  final String htmlUrl;

  final List<ReleaseAsset> assets;

  const AppRelease({
    required this.tag,
    required this.version,
    required this.build,
    required this.body,
    required this.publishedAt,
    required this.htmlUrl,
    required this.assets,
  });
}

/// 某个平台怎么装下载好的安装包。各平台的实现在 installers/ 下面，
/// 用 [UpdateInstaller.current] 拿当前平台的。
abstract class UpdateInstaller {
  /// 这个平台能不能在 App 里直接装（Windows、安卓能；macOS 打开 dmg 由用户拖，
  /// iOS 交给别的工具）
  bool get canInstallInApp;

  /// 更新对话框里说明下载以后会怎样的一句话
  String get installNote;

  /// 从 Release 的安装包里挑这台设备要的那个；没有合适的返回 null
  ReleaseAsset? pickAsset(List<ReleaseAsset> assets);

  /// 安装下载好、校验过的文件。Windows 会退出 App，安装完成后重新打开；macOS 打开 dmg；
  /// 安卓调起系统安装界面；iOS 交给 TrollStore 等工具（[tempUrl] 是临时下载链接，没有时为 null）
  Future<void> install(
    String filePath,
    ReleaseAsset asset, {
    required String version,
    String? tempUrl,
  });
}
