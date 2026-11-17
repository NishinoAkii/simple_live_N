import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/script/live_source_models.dart';
import 'package:simple_live_core/src/script/live_source_overrides.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 直播源的“权限”：能访问的域名（Http、WebSocket），以及几项敏感功能。
/// 安装时给用户看，更新时比较新旧版本，扩大了要用户确认，见 doc/live_source_api.md §8
///
/// 其它功能（推荐、搜索、弹幕……）只是能不能用，不算权限：脚本能做的事由 domains 决定。
const List<String> kLiveSourceSensitiveCapabilities = [
  "login",
  "hlsRewrite",
  "overrides",
  "useAccount",
];

/// 敏感功能的说明（安装、更新确认里显示）
String liveSourceCapabilityLabel(String capability) {
  switch (capability) {
    case "login":
      return "网页登录（保存这个源的登录 Cookie）".t;
    case "hlsRewrite":
      return "改写播放列表（hls.rewrite）".t;
    case "overrides":
      return "替换内置平台的功能（overrides）".t;
    case "useAccount":
      return "用你在 App 里登录的内置平台帐号（脚本读不到 Cookie）".t;
    default:
      return capability;
  }
}

/// [domains]（"a.com"、"*.a.com"）是否覆盖了 [pattern]：
/// "x.a.com" 被 "x.a.com" 或 "*.a.com" 覆盖；"*.x.a.com" 只被 "*.x.a.com"、"*.a.com" 覆盖
bool liveSourceDomainCovered(List<String> domains, String pattern) {
  var p = pattern.toLowerCase();
  if (domains.contains(p)) return true;
  // "*.a.com" 匹配 a.com 的任意子域名（不含 a.com 本身）
  var host = p.startsWith("*.") ? p.substring(2) : p;
  for (var d in domains) {
    if (!d.startsWith("*.")) continue;
    var suffix = d.substring(1); // ".a.com"
    if (p.startsWith("*.")) {
      if (".$host".endsWith(suffix)) return true;
    } else if (host.endsWith(suffix)) {
      return true;
    }
  }
  return false;
}

/// 登录地址的主机（login.url、login.cookieUrl）
Set<String> _loginHosts(LiveSourceLogin? login) => {
  if (login != null) ...[
    Uri.tryParse(login.url)?.host ?? "",
    Uri.tryParse(login.cookieUrl)?.host ?? "",
  ],
}..remove("");

/// 新旧两个版本的权限差别
class LiveSourcePermissionDiff {
  /// 旧版本没有覆盖的新域名
  final List<String> addedDomains;

  /// 新版本不再需要的域名
  final List<String> removedDomains;

  /// 新增的敏感功能（[kLiveSourceSensitiveCapabilities]）
  final List<String> addedCapabilities;
  final List<String> removedCapabilities;

  /// 登录页、Cookie 地址的主机变了：旧 → 新（都有登录时才算）
  final String? loginChange;

  /// 内置平台的修正（§9）：替换的平台（新版本的，没有时为 null）
  final String? overrideTarget;

  /// 替换的平台变了：旧 → 新（都是修正时才算）
  final String? overrideTargetChange;

  /// 新替换的函数（新装、新加 overrides 时为全部）
  final List<String> addedOverrides;
  final List<String> removedOverrides;

  const LiveSourcePermissionDiff({
    this.addedDomains = const [],
    this.removedDomains = const [],
    this.addedCapabilities = const [],
    this.removedCapabilities = const [],
    this.loginChange,
    this.overrideTarget,
    this.overrideTargetChange,
    this.addedOverrides = const [],
    this.removedOverrides = const [],
  });

  /// 权限扩大了：新的域名、新的敏感功能、登录地址换了主机、替换的平台变了或者多替换了函数
  bool get expanded =>
      addedDomains.isNotEmpty ||
      addedCapabilities.isNotEmpty ||
      loginChange != null ||
      overrideTargetChange != null ||
      addedOverrides.isNotEmpty;

  bool get isEmpty =>
      !expanded &&
      removedDomains.isEmpty &&
      removedCapabilities.isEmpty &&
      removedOverrides.isEmpty;

  static String _functions(List<String> list) =>
      list.map(liveSourceOverrideFunctionLabel).join("、".t);

  String _capability(String c) => c == "useAccount" && overrideTarget != null
      ? "用你在 App 里登录的 {builtInSiteName} 帐号（App 代为加登录信息，脚本读不到 Cookie）".tf({"builtInSiteName": builtInSiteName(overrideTarget!)})
      : liveSourceCapabilityLabel(c);

  /// 给用户看的几行说明。warn：比原来多要了权限的那几行（新增的、登录地址变了）
  List<({String text, bool warn})> lines() => [
    if (addedDomains.isNotEmpty) (text: "新增可访问的域名：{addedDomains}".tf({"addedDomains": addedDomains.join("、".t)}), warn: true),
    for (var c in addedCapabilities)
      if (c != "overrides" || addedOverrides.isEmpty) (text: "新增：{capability}".tf({"capability": _capability(c)}), warn: true),
    if (overrideTargetChange != null) (text: "新增：替换的内置平台变了：{overrideTargetChange}".tf({"overrideTargetChange": overrideTargetChange}), warn: true),
    if (addedOverrides.isNotEmpty && overrideTarget != null)
      (text: "新增：替换内置的 {builtInSiteName} 的：{functions}".tf({"builtInSiteName": builtInSiteName(overrideTarget!), "functions": _functions(addedOverrides)}), warn: true),
    if (loginChange != null) (text: "登录地址变了：{loginChange}".tf({"loginChange": loginChange}), warn: true),
    if (removedDomains.isNotEmpty) (text: "不再访问：{removedDomains}".tf({"removedDomains": removedDomains.join("、".t)}), warn: false),
    for (var c in removedCapabilities) (text: "去掉：{liveSourceCapabilityLabel}".tf({"liveSourceCapabilityLabel": liveSourceCapabilityLabel(c)}), warn: false),
    if (removedOverrides.isNotEmpty) (text: "不再替换：{functions}".tf({"functions": _functions(removedOverrides)}), warn: false),
  ];

  /// [lines] 的文字
  List<String> describe() => [for (var line in lines()) line.text];
}

/// 比较已安装的版本 [old]（新装时为 null）和新版本 [next]
LiveSourcePermissionDiff diffLiveSourcePermissions(
  LiveSourceInfo? old,
  LiveSourceInfo next,
) {
  var oldDomains = old?.domains ?? const <String>[];
  var oldCaps = (old?.capabilities ?? const <String>{}).where(
    kLiveSourceSensitiveCapabilities.contains,
  );
  var nextCaps = next.capabilities.where(
    kLiveSourceSensitiveCapabilities.contains,
  );
  String? loginChange;
  var oldHosts = _loginHosts(old?.login);
  var nextHosts = _loginHosts(next.login);
  if (oldHosts.isNotEmpty &&
      nextHosts.isNotEmpty &&
      !oldHosts.containsAll(nextHosts)) {
    loginChange = "${oldHosts.join("、".t)} → ${nextHosts.join("、".t)}";
  }
  // 修正：换了平台时全部算新替换的
  var target = next.overrides;
  var sameTarget = old?.overrides != null && old!.overrides == target;
  String? targetChange;
  if (target != null && old?.overrides != null && !sameTarget) {
    targetChange =
        "${builtInSiteName(old!.overrides!)} → ${builtInSiteName(target)}";
  }
  var oldFunctions = sameTarget ? old.overrideFunctions : const <String>{};
  var nextFunctions = next.overrideFunctions;
  return LiveSourcePermissionDiff(
    overrideTarget: target,
    overrideTargetChange: targetChange,
    addedOverrides: [
      for (var f in kLiveSourceOverridableFunctions)
        if (nextFunctions.contains(f) && !oldFunctions.contains(f)) f,
    ],
    removedOverrides: [
      for (var f in kLiveSourceOverridableFunctions)
        if (oldFunctions.contains(f) && !nextFunctions.contains(f)) f,
    ],
    addedDomains: [
      for (var d in next.domains)
        if (!liveSourceDomainCovered(oldDomains, d)) d,
    ],
    removedDomains: [
      for (var d in oldDomains)
        if (!liveSourceDomainCovered(next.domains, d)) d,
    ],
    addedCapabilities: [
      for (var c in nextCaps)
        if (!oldCaps.contains(c)) c,
    ],
    removedCapabilities: [
      for (var c in oldCaps)
        if (!nextCaps.contains(c)) c,
    ],
    loginChange: loginChange,
  );
}

/// 准备安装（或更新）的一个源：下载、解析、校验过签名，还没有写进去。
/// App 给用户看 [next] 的权限（更新时看 [diff]），确认后用 LiveSourceManager.applyPlan 安装
class LiveSourcePlan {
  /// 新版本（file 为安装后的路径）
  final LiveSourceInfo next;

  /// 已安装的版本，新装时为 null
  final LiveSourceInfo? current;

  /// 和已安装版本的权限差别（新装时全部算新增）
  final LiveSourcePermissionDiff diff;

  /// 校验过的发布者公钥（Base64），没有签名时为 null
  final String? publicKey;

  /// 已安装的版本有签名（[currentPublicKey]），这一次没有签名或换了公钥
  final String? currentPublicKey;

  /// 来自哪个订阅（index.json 地址），不是从订阅装的为 null
  final String? subscription;

  /// 下载地址（或本机文件的 file:/// 地址）
  final String origin;

  /// 内部：脚本内容
  final String code;

  LiveSourcePlan({
    required this.next,
    required this.current,
    required this.publicKey,
    required this.origin,
    required this.code,
    this.currentPublicKey,
    this.subscription,
  }) : diff = diffLiveSourcePermissions(current, next);

  bool get isUpdate => current != null;
  bool get signed => publicKey != null;

  /// 把签名安装的源换成没签名的、或别的公钥签名的
  bool get losesSignature =>
      currentPublicKey != null && currentPublicKey != publicKey;

  /// 要用户确认：新装；更新扩大了权限；更新去掉了签名或换了公钥
  bool get needsConfirmation => !isUpdate || diff.expanded || losesSignature;
}

/// 更新扩大了权限（或去掉了签名），没有确认就不安装；[plan] 里是准备好的新版本
class LiveSourceConfirmationRequired extends CoreError {
  final LiveSourcePlan plan;
  LiveSourceConfirmationRequired(this.plan) : super(_describe(plan));

  static String _describe(LiveSourcePlan plan) {
    var lines = [
      for (var line in plan.diff.lines())
        if (line.warn) line.text,
    ];
    if (!plan.isUpdate) lines.add("新安装".t);
    if (plan.losesSignature) {
      lines.add(plan.signed ? "发布者公钥变了".t : "新版本没有签名".t);
    }
    return ("{name} {version} 需要你确认后才能安装："
        "{lines}").tf({"name": plan.next.name, "version": plan.next.version, "lines": lines.join("；".t)});
  }
}
