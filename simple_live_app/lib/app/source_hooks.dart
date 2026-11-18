/// 读翻译、直播源订阅时可以换掉的几处：要带登录读的地址（github:用户/仓库/路径）
/// 由别处装上；
/// 没装时全是 null，照常下载
class SourceHooks {
  SourceHooks._();

  /// 读这个地址；不归它管时返回 null，照常下载
  static Future<List<int>?> Function(String url)? fetch;

  /// 输入框里填的地址整理一下（如网页链接换成 github: 写法）；
  /// 不归它管时原样返回
  static String Function(String url)? normalize;

  /// 这个地址是不是 github:用户/仓库/路径 的写法，输入框要认
  static bool Function(String url)? isPrivateUrl;

  static String normalizeUrl(String url) => normalize?.call(url) ?? url;

  static bool isPrivate(String url) => isPrivateUrl?.call(url) ?? false;

  static void reset() {
    fetch = null;
    normalize = null;
    isPrivateUrl = null;
  }
}
