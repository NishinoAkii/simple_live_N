import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';
import 'package:window_manager/window_manager.dart';

/// 安装失败时抛出；[message] 已经翻译好，可以直接显示
class UpdateInstallError implements Exception {
  final String message;
  const UpdateInstallError(this.message);

  @override
  String toString() => message;
}

/// 按文件名结尾挑安装包：按 [suffixes] 的顺序找，先找到的优先，不分大小写。
/// 同一个版本重新编译过时 Release 里会有几份（文件名的运行编号 -b48- 不同），取编号最大的
ReleaseAsset? pickAssetBySuffix(
  List<ReleaseAsset> assets,
  List<String> suffixes,
) {
  for (var suffix in suffixes) {
    var lower = suffix.toLowerCase();
    ReleaseAsset? best;
    for (var asset in assets) {
      if (!asset.name.toLowerCase().endsWith(lower)) {
        continue;
      }
      if (best == null || runNumberOf(asset.name) > runNumberOf(best.name)) {
        best = asset;
      }
    }
    if (best != null) {
      return best;
    }
  }
  return null;
}

/// 安装包文件名里的运行编号：SimpleLive-v1.24.2-b48-6b41418-… 是 48，没有时为 -1
int runNumberOf(String name) {
  var match = RegExp(r"-b(\d+)-").firstMatch(name);
  return match == null ? -1 : int.parse(match.group(1)!);
}

/// 能当文件夹名的版本号（1.25.0 这类原样保留）
String safeVersionName(String version) {
  var text = version.trim().replaceAll(RegExp(r"[^0-9A-Za-z._+-]"), "_");
  return text.isEmpty ? "unknown" : text;
}

/// 更新用到的文件夹
class UpdatePaths {
  UpdatePaths._();

  /// 缓存目录下的 update：下载的安装包、解压出的文件、更新脚本
  static Future<Directory> updateDir() async {
    var dir = Directory(
      p.join((await getApplicationCacheDirectory()).path, "update"),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 更新脚本的日志，在 App 的数据目录里
  static Future<File> logFile() async {
    var dir = Directory(
      p.join((await getApplicationSupportDirectory()).path, "update"),
    );
    await dir.create(recursive: true);
    return File(p.join(dir.path, "updater.log"));
  }
}

/// 在 [dir] 里建一个临时文件再删掉，看能不能写
Future<bool> canWriteDir(String dir) async {
  var name = ".sl_write_test_${pid}_${Random().nextInt(1 << 30)}";
  var file = File(p.join(dir, name));
  try {
    await file.writeAsString("x", flush: true);
    await file.delete();
    return true;
  } catch (_) {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
    return false;
  }
}

/// 只在正式版的主窗口里更新：调试版的文件夹是编译输出，副窗口关不掉主窗口
void checkDesktopUpdateAllowed() {
  if (!kReleaseMode) {
    throw UpdateInstallError("调试版本不能自动更新".t);
  }
  if (MultiWindow.isSecondary) {
    throw UpdateInstallError("请在主窗口中更新".t);
  }
}

/// 更新脚本写的状态：waiting（App 写的）、elevating、started、declined、error、done:…
class UpdateScriptStatus {
  UpdateScriptStatus._();

  static Future<File> prepare(Directory updateDir) async {
    var file = File(p.join(updateDir.path, "updater.status"));
    await file.writeAsString("waiting", flush: true);
    return file;
  }

  /// 等脚本开始干活（或者被拒绝、出错）；超时返回空字符串
  static Future<String> wait(File file, Duration timeout) async {
    var end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      try {
        var text = (await file.readAsString()).trim();
        if (text.startsWith("started") ||
            text.startsWith("done") ||
            text.startsWith("declined") ||
            text.startsWith("error")) {
          return text;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return "";
  }

  /// 脚本开始了就退出 App；被拒绝或出错时抛出
  static void check(String status) {
    if (status.startsWith("started") || status.startsWith("done")) {
      return;
    }
    if (status.startsWith("declined")) {
      throw UpdateInstallError("已取消安装".t);
    }
    if (status.startsWith("error")) {
      throw UpdateInstallError("安装失败".t);
    }
    throw UpdateInstallError("安装程序没有启动".t);
  }
}

/// 装更新前退出 App：先在 App 里说一声（[notice]，停约 1 秒，免得像闪退），再和点主窗口的
/// 关闭按钮一样关窗口。拦着关闭时（WebDAV 自动同步、开着多开窗口）
/// 由 WebDavSyncService.onWindowClose 先关多开窗口、传完存档再关窗口
Future<void> quitForUpdate({String notice = ""}) async {
  if (notice.isNotEmpty) {
    SmartDialog.showLoading(msg: notice);
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  await windowManager.close();
}
