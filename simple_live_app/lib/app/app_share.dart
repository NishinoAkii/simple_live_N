import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/windows_version.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 分享。Windows 7 没有系统的分享面板，改为复制链接或文字，文件则在资源管理器里选中
abstract final class AppShare {
  static Future<void> share(ShareParams params) async {
    if (!WindowsVersion.isWindows7) {
      await SharePlus.instance.share(params);
      return;
    }
    var files = params.files;
    if (files != null && files.isNotEmpty) {
      await Process.run("explorer.exe", ["/select,", files.first.path]);
      return;
    }
    var text = params.uri?.toString() ?? params.text ?? "";
    if (text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      SmartDialog.showToast("Windows 7 不支持系统分享，已复制到剪贴板".t);
    }
  }
}
