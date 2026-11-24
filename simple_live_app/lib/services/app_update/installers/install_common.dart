import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/app_update/release_models.dart';
import 'package:window_manager/window_manager.dart';

/// 安装失败时抛出；[message] 已经翻译好，可以直接显示
class UpdateInstallError implements Exception {
  final String message;

  /// 下载好的安装包：可以打开它所在的文件夹自己装；没有时为 null
  final String? package;
  const UpdateInstallError(this.message, {this.package});

  @override
  String toString() => message;
}

/// 用户没让装（在系统的权限确认里点了否）：提示一句就行，不算失败
class UpdateInstallCancelled extends UpdateInstallError {
  const UpdateInstallCancelled(super.message);
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

  /// 缓存目录下的 app_update：下载的安装包
  static Future<Directory> downloadDir() async => Directory(
        p.join((await getApplicationCacheDirectory()).path, "app_update"),
      );

  /// 缓存目录下的 update：下载的安装包、解压出的文件、更新脚本
  static Future<Directory> updateDir() async {
    var dir = Directory(
      p.join((await getApplicationCacheDirectory()).path, "update"),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// 这一次更新用的文件夹（在 [updateDir] 里）：脚本、状态、进度、窗口里的字、解压出的文件
  static Future<Directory> newRunDir() async {
    var name = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    var dir = Directory(p.join((await updateDir()).path, "run-$name"));
    await dir.create(recursive: true);
    return dir;
  }

  /// 脚本写的状态（[UpdateScriptStatus]）
  static File statusFile(Directory runDir) =>
      File(p.join(runDir.path, "updater.status"));

  /// 更新窗口里的字，脚本读（UTF-8）
  static File textFile(Directory runDir) =>
      File(p.join(runDir.path, "updater.txt"));

  /// 脚本写的进度：在做哪一步、做了多少、一共多少
  static File progressFile(Directory runDir) =>
      File(p.join(runDir.path, "updater.progress"));

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

/// 在 [dir] 里建一个临时文件夹再删掉，看能不能建
Future<bool> canCreateDirIn(String dir) async {
  var name = ".sl_write_test_${pid}_${Random().nextInt(1 << 30)}";
  var folder = Directory(p.join(dir, name));
  try {
    await folder.create();
    await folder.delete();
    return true;
  } catch (_) {
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

/// 更新脚本写的状态：waiting（App 写的）、opening（窗口在打开）、elevating（等用户在 UAC 里点）、
/// preparing（解压）、started（准备好了，App 该退出了）、declined、error:…、done:…、
/// cancelled（App 不等了，或者窗口在开始之前就关了）
class UpdateScriptStatus {
  UpdateScriptStatus._();

  static Future<File> prepare(Directory runDir) async {
    var progress = UpdatePaths.progressFile(runDir);
    if (await progress.exists()) {
      await progress.delete();
    }
    var file = UpdatePaths.statusFile(runDir);
    await file.writeAsString("waiting", flush: true);
    return file;
  }

  /// 等脚本准备好（或者被拒绝、出错）；超时返回空字符串。
  /// 脚本在等用户点 UAC、在解压时多等一会儿（[busy]）
  static Future<String> wait(
    File file,
    Duration timeout, {
    Duration busy = const Duration(minutes: 5),
  }) async {
    var end = DateTime.now().add(timeout);
    var last = "";
    while (DateTime.now().isBefore(end)) {
      try {
        var text = (await file.readAsString()).trim();
        if (text.startsWith("started") ||
            text.startsWith("done") ||
            text.startsWith("declined") ||
            text.startsWith("cancelled") ||
            text.startsWith("error")) {
          return text;
        }
        if (text != last &&
            const ["opening", "elevating", "preparing"].any(text.startsWith)) {
          end = DateTime.now().add(busy);
        }
        last = text;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return "";
  }

  /// App 不等了：脚本看到以后什么都不动就结束
  static Future<void> cancel(File file) async {
    try {
      await file.writeAsString("cancelled", flush: true);
    } catch (e) {
      Log.w("更新状态没写上：$e");
    }
  }

  /// 脚本准备好了（started）就退出 App；取消、出错时抛出。[package] 是下载好的安装包
  static void check(String status, {String logFile = "", String? package}) {
    if (status.startsWith("started")) {
      return;
    }
    if (status.startsWith("declined") || status.startsWith("cancelled")) {
      throw UpdateInstallCancelled("已取消安装".t);
    }
    if (status.isEmpty) {
      throw UpdateInstallError("安装程序没有启动".t, package: package);
    }
    if (status.startsWith("error: package not unpacked") ||
        status.startsWith("error: app not in the package")) {
      throw UpdateInstallError("安装包不完整".t);
    }
    if (status.startsWith("error: another update")) {
      throw UpdateInstallError("另一个更新正在进行".t);
    }
    if (status.startsWith("error: disk full")) {
      throw UpdateInstallError("磁盘空间不足".t, package: package);
    }
    if (status.startsWith("error: access denied")) {
      throw UpdateInstallError("没有写入权限".t, package: package);
    }
    throw UpdateInstallError(
      "请查看日志 {path}".tf({"path": logFile}),
      package: package,
    );
  }
}

/// 以前的更新留下的东西：解压出的文件夹（更新没装成时留下的）、已经装上的版本的安装包
class UpdateLeftovers {
  UpdateLeftovers._();

  /// 脚本这么久没有动静，就当它已经不在了
  static const Duration idle = Duration(minutes: 10);

  /// 安装包文件名里的版本号：SimpleLive-v1.24.2-b48-…、simple_live_N-1.27.4-12704-…
  static final RegExp _version = RegExp(r"-v?(\d+(?:\.\d+)+)-");

  /// [a] 比 [b] 新。按数字一段一段比，1.27.10 比 1.27.9 新
  static bool _newer(String a, String b) {
    var left = a.split(".").map(int.tryParse).toList();
    var right = b.split(".").map(int.tryParse).toList();
    for (var i = 0; i < max(left.length, right.length); i++) {
      var x = i < left.length ? left[i] ?? 0 : 0;
      var y = i < right.length ? right[i] ?? 0 : 0;
      if (x != y) {
        return x > y;
      }
    }
    return false;
  }

  /// 启动时调用。[version] 是现在的版本号，[build] 是这个 App 的编译编号（b53-046a4f5，
  /// 文件名里是其中的提交编号）：比它新的、同一个版本重新编译过的安装包留着（下载了还没装的）
  static Future<void> clean({
    required Directory updateDir,
    required Directory downloadDir,
    required String version,
    String build = "",
    DateTime? now,
  }) async {
    var time = now ?? DateTime.now();
    var commit = build.split("-").last;
    await _each(updateDir, (entry) async {
      if (entry is Directory) {
        return !await _busy(entry, time);
      }
      // 1.27.1 和以前的状态、脚本直接放在这里
      return entry is File &&
          time.difference(await entry.lastModified()) > idle;
    });
    await _each(downloadDir, (entry) async {
      var name = p.basename(entry.path);
      var match = _version.firstMatch(name);
      if (entry is! File || match == null || _newer(match[1]!, version)) {
        return false;
      }
      return _newer(version, match[1]!) ||
          (commit.isNotEmpty && name.contains("-$commit-"));
    });
  }

  /// 更新脚本正在这个文件夹里干活：刚写过状态，还没写完成
  static Future<bool> _busy(Directory runDir, DateTime now) async {
    var file = UpdatePaths.statusFile(runDir);
    try {
      var text = (await file.readAsString()).trim();
      var ended = const ["done", "declined", "error", "cancelled"]
          .any(text.startsWith);
      return !ended && now.difference(await file.lastModified()) < idle;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _each(
    Directory dir,
    Future<bool> Function(FileSystemEntity entry) remove,
  ) async {
    if (!await dir.exists()) {
      return;
    }
    for (var entry in await dir.list(followLinks: false).toList()) {
      try {
        if (await remove(entry)) {
          Log.i("清理以前的更新留下的：${p.basename(entry.path)}");
          await entry.delete(recursive: true);
        }
      } catch (e) {
        Log.w("清理以前的更新留下的文件失败：$e");
      }
    }
  }
}

/// 装更新前退出 App：先在 App 里说一声（[notice]，停约 1 秒，免得像闪退），再和点主窗口的
/// 关闭按钮一样关窗口。拦着关闭时（WebDAV 自动同步、开着多开窗口）
/// 由 WebDavSyncService.onWindowClose 先关多开窗口、传完存档再关窗口
Future<void> quitForUpdate({String notice = ""}) async {
  if (notice.isNotEmpty) {
    unawaited(SmartDialog.showLoading(msg: notice));
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  await windowManager.close();
}
