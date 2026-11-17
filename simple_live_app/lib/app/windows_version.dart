import 'dart:io';

/// Windows 版本。
///
/// Windows 7 没有 WinRT，系统通知和系统分享在那里用不了：Windows 7 的安装包里，
/// 这些插件靠附带的替代 DLL 才能加载，真正调用时会失败，所以在 App 里先关掉。
abstract final class WindowsVersion {
  /// 当前是 Windows 7（或更早）
  static final bool isWindows7 =
      Platform.isWindows && isWindows7Text(Platform.operatingSystemVersion);

  /// [text] 是 Platform.operatingSystemVersion，形如
  /// `"Windows 10 Pro" 10.0 (Build 19045)`、`"Windows 7 Ultimate" 6.1 (Build 7601: Service Pack 1)`。
  /// 版本号取引号后面的数字（产品名里也可能有数字，比如 Windows 8.1）
  static bool isWindows7Text(String text) {
    var match = RegExp(r'^\s*(?:"[^"]*")?\s*(\d+)\.(\d+)').firstMatch(text);
    if (match == null) {
      return false;
    }
    var major = int.parse(match.group(1)!);
    var minor = int.parse(match.group(2)!);
    return major < 6 || (major == 6 && minor <= 1);
  }
}
