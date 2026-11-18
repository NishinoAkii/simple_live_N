/// 一个下载镜像：把它的前缀加在 GitHub 下载地址前面，如
/// https://ghfast.top/ + https://github.com/…/releases/download/…
class UpdateMirror {
  /// 存进设置的值
  final String id;

  /// 显示的名字
  final String name;

  final String prefix;

  /// 能不能转发 GitHub 的临时下载链接（release-assets.githubusercontent.com）
  final bool tempLinks;

  const UpdateMirror(this.id, this.name, this.prefix, {this.tempLinks = false});
}

/// 应用内更新用哪个仓库、要不要登录、有哪些内置镜像
class UpdateConfig {
  /// 仓库的主人和名字
  final String owner;
  final String repo;

  /// Release 标签的前缀，如 v1.25.0 的 v
  final String tagPrefix;

  /// 要登录才能读 Release、下载安装包
  final bool needsLogin;

  /// 内置的下载镜像
  final List<UpdateMirror> mirrors;

  /// 默认的翻译源：翻译清单（{"languages": [{"code", "name", "url"}]}）的地址。
  /// 设置里可以换成别的
  final String translationSource;

  /// 默认的直播源订阅（index.json 的地址），直播源订阅页还没有订阅时可以一键添加
  final String liveSourceSubscription;

  const UpdateConfig({
    required this.owner,
    required this.repo,
    required this.tagPrefix,
    required this.needsLogin,
    this.mirrors = const [],
    this.translationSource = "",
    this.liveSourceSubscription = "",
  });

  static const String apiBase = "https://api.github.com";

  /// 最新的正式版（不含草稿和预发布）
  String get latestReleaseUrl => "$apiBase/repos/$owner/$repo/releases/latest";

  /// 网页上的 Release 列表
  String get releasesPage => "https://github.com/$owner/$repo/releases";

  /// simple_live_N 的公开 Release，不用登录
  static const UpdateConfig current = UpdateConfig(
    owner: "NishinoAkii",
    repo: "simple_live_N",
    tagPrefix: "v",
    needsLogin: false,
    // 2026-11-19 实测：这四个都能下载 GitHub 上公开的安装包。
    // gh.llkk.cc、github.moeyy.xyz、gh.ddlc.top、ghproxy.cc 当时不能用，没放进来
    mirrors: [
      UpdateMirror("gh-proxy-org", "gh-proxy.org", "https://gh-proxy.org/"),
      UpdateMirror("gh-proxy", "gh-proxy.com", "https://gh-proxy.com/"),
      UpdateMirror("ghfast", "ghfast.top", "https://ghfast.top/"),
      UpdateMirror("ghproxy-net", "ghproxy.net", "https://ghproxy.net/"),
    ],
    // 翻译清单（simple_live_N-sources）
    translationSource:
        "https://gist.githubusercontent.com/NishinoAkii/7ef617aacd2b81be3a337db6ae33cdaa/raw/translations.json",
    // 直播源订阅（simple_live_N-sources）
    liveSourceSubscription:
        "https://gist.githubusercontent.com/NishinoAkii/7ef617aacd2b81be3a337db6ae33cdaa/raw/index.json",
  );
}
