import 'package:simple_live_core/src/script/live_source_overrides.dart';

/// 直播源脚本（.live.js）的信息，见 doc/live_source_api.md
class LiveSourceInfo {
  /// ^[a-z0-9_]+$，App 里的平台 id 为 "js:<key>"
  final String key;
  final String name;
  final String version;
  final int apiVersion;

  /// 更新地址（可为空）
  final String? url;

  /// 图标地址（http(s) 或 data: URI，可为空）
  final String? icon;
  final String? description;

  /// 本地脚本文件路径
  final String file;

  /// 脚本声明的可访问域名（"example.com" 或 "*.example.com"）
  final List<String> domains;

  /// 粘贴链接识别的正则（第 1 组为房间号）
  final List<String> links;

  /// 脚本实现的功能：方法名（recommend、categories、room…），有弹幕时含 "danmaku"，
  /// 声明了登录时含 "login"，有 hls.rewrite 时含 "hlsRewrite"，
  /// 声明了设置项时含 "settings"
  final Set<String> capabilities;

  /// 网页登录（脚本的 login 字段），没有时为 null
  final LiveSourceLogin? login;

  /// 脚本声明的设置项（settings 字段），App 在源的详情页里显示
  final List<LiveSourceSetting> settings;

  /// 内置平台的修正：替换的平台 id（如 "bilibili"），普通直播源为 null（§9）
  final String? overrides;

  /// 修正用内置平台在 App 里登录的帐号（App 代为加请求头，脚本读不到）
  final bool useAccount;

  const LiveSourceInfo({
    required this.key,
    required this.name,
    required this.version,
    required this.apiVersion,
    required this.file,
    this.url,
    this.icon,
    this.description,
    this.domains = const [],
    this.links = const [],
    this.capabilities = const {},
    this.login,
    this.settings = const [],
    this.overrides,
    this.useAccount = false,
  });

  String get siteId => "js:$key";

  /// 是内置平台的修正（不是单独的平台）
  bool get isOverride => overrides != null;

  /// 修正替换的函数（kLiveSourceOverridableFunctions 里脚本实现了的），普通直播源为空
  Set<String> get overrideFunctions => overrides == null
      ? const {}
      : {
          for (var f in kLiveSourceOverridableFunctions)
            if (capabilities.contains(f)) f,
        };
}

/// 脚本声明的一个设置项（settings 字段的一项），见 doc/live_source_api.md §7 settings
///
/// [type]：`switch`（开关，bool）、`text`（文字）、`number`（数字，可选 [min] / [max]）、
/// `select`（单选，[options] 里的 value）。值保存在本源的数据目录（settings.json），不同步
class LiveSourceSetting {
  static const List<String> types = ["switch", "text", "number", "select"];

  /// ^[A-Za-z0-9_.-]{1,64}$
  final String key;
  final String type;
  final String label;

  /// 补充说明（可选）
  final String? description;
  final dynamic defaultValue;

  /// select 的选项
  final List<LiveSourceSettingOption> options;
  final num? min;
  final num? max;

  /// text 的输入提示（可选）
  final String? placeholder;

  const LiveSourceSetting({
    required this.key,
    required this.type,
    required this.label,
    required this.defaultValue,
    this.description,
    this.options = const [],
    this.min,
    this.max,
    this.placeholder,
  });

  /// 把保存的（或界面上输入的）值转成这个设置项的类型；不合法时返回 null
  dynamic coerce(dynamic v) {
    switch (type) {
      case "switch":
        if (v is bool) return v;
        if (v == "true" || v == 1) return true;
        if (v == "false" || v == 0) return false;
        return null;
      case "number":
        num? n = v is num ? v : num.tryParse(v?.toString().trim() ?? "");
        if (n == null || n.isNaN || n.isInfinite) return null;
        if (min != null && n < min!) return null;
        if (max != null && n > max!) return null;
        return n;
      case "select":
        for (var o in options) {
          if (o.value == v || o.value.toString() == v?.toString()) {
            return o.value;
          }
        }
        return null;
      default:
        if (v == null) return null;
        var s = v.toString();
        return s.length > 2000 ? s.substring(0, 2000) : s;
    }
  }

  /// [stored] 里这个设置项的值，没有或不合法时为默认值
  dynamic valueIn(Map<String, dynamic> stored) =>
      coerce(stored[key]) ?? defaultValue;
}

class LiveSourceSettingOption {
  /// 字符串、数字或 bool
  final dynamic value;
  final String label;
  const LiveSourceSettingOption(this.value, this.label);
}

/// 直播源声明的网页登录：App 打开 [url] 让用户登录，出现 [cookieNames] 里的 Cookie 后
/// 把 [cookieUrl] 下的全部 Cookie 写进这个源自己的 Cookie 罐（也可以手动粘贴 Cookie）
class LiveSourceLogin {
  /// 登录页（https）
  final String url;

  /// 读取、保存 Cookie 的地址（https，默认同 [url]）
  final String cookieUrl;

  /// 登录后才有的 Cookie 名称，出现任意一个（值不为空）就算已登录
  final List<String> cookieNames;

  /// 登录页上方的提示
  final String? tip;

  const LiveSourceLogin({
    required this.url,
    required this.cookieUrl,
    required this.cookieNames,
    this.tip,
  });

  /// [cookieHeader]（"a=1; b=2"）里有没有登录 Cookie
  bool loggedInBy(String cookieHeader) =>
      liveSourceLoggedIn(cookieHeader, cookieNames);
}

/// 直播源的当前帐号（脚本的 account()；没有实现时只有 [loggedIn]）
class LiveSourceAccount {
  final bool loggedIn;
  final String? userName;
  final String? avatar;
  final String? uid;
  const LiveSourceAccount({
    required this.loggedIn,
    this.userName,
    this.avatar,
    this.uid,
  });
}

/// Cookie 头（"a=1; b=2"）里是否有 [names] 中任意一个、且值不为空的 Cookie
bool liveSourceLoggedIn(String cookieHeader, List<String> names) {
  for (var part in cookieHeader.split(";")) {
    var i = part.indexOf("=");
    if (i <= 0) continue;
    var name = part.substring(0, i).trim();
    var value = part.substring(i + 1).trim();
    if (value.isNotEmpty && value != '""' && names.contains(name)) return true;
  }
  return false;
}

/// 订阅（index.json）里的一项
class LiveSourceIndexEntry {
  final String key;
  final String name;
  final String version;

  /// 已解析为绝对地址
  final String url;
  final String? description;

  /// 已安装的版本，未安装为 null
  final String? installedVersion;

  /// 来自哪个订阅
  final String subscription;

  /// 订阅的发布者公钥（Base64，第一次添加订阅时记下的），没有签名的订阅为 null
  final String? publicKey;

  /// index.json 里这一项的签名（Base64），没有时安装、更新时读 `<url>.sig`
  final String? signature;

  /// 不能从这个订阅安装、更新的原因（如订阅的公钥变了），没有问题时为 null
  final String? blockedReason;

  const LiveSourceIndexEntry({
    required this.key,
    required this.name,
    required this.version,
    required this.url,
    required this.subscription,
    this.description,
    this.installedVersion,
    this.publicKey,
    this.signature,
    this.blockedReason,
  });

  /// 订阅有签名（安装、更新时要校验）
  bool get signed => publicKey != null;

  bool get installed => installedVersion != null;

  /// 订阅里的版本比已安装的高
  bool get hasUpdate =>
      installedVersion != null &&
      compareLiveSourceVersion(version, installedVersion!) > 0;
}

/// 比较语义化版本（1.2.10 > 1.2.9），无法解析的部分按 0 处理
int compareLiveSourceVersion(String a, String b) {
  List<int> parts(String v) => v
      .split(RegExp(r'[.+-]'))
      .take(3)
      .map((e) => int.tryParse(e) ?? 0)
      .toList();
  var x = parts(a);
  var y = parts(b);
  for (var i = 0; i < 3; i++) {
    var l = i < x.length ? x[i] : 0;
    var r = i < y.length ? y[i] : 0;
    if (l != r) {
      return l.compareTo(r);
    }
  }
  return 0;
}
