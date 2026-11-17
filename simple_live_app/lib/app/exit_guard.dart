import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// 电脑上关主窗口前要先做完的事。
///
/// WebDAV 自动同步（退出前上传）和多开（先关掉副窗口）都要拦住关闭，
/// 这里合在一起管：有一个要拦就拦（[hold]）。真正关窗口的是 WebDavSyncService，
/// 它关之前先跑一遍 [runBeforeClose]
class ExitGuard {
  ExitGuard._();

  static const webdav = "webdav";
  static const multiWindow = "multiWindow";

  static final Set<String> _holds = {};
  static final List<Future<void> Function()> _tasks = [];
  static Future<void>? _running;

  @visibleForTesting
  static bool? debugIsDesktop;

  static bool get _isDesktop =>
      debugIsDesktop ??
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  static bool get holding => _holds.isNotEmpty;

  /// [reason] 要（或不再要）拦住关闭
  static void hold(String reason, bool on) {
    var changed = on ? _holds.add(reason) : _holds.remove(reason);
    if (changed && _isDesktop) {
      unawaited(windowManager.setPreventClose(_holds.isNotEmpty));
    }
  }

  static void addTask(Future<void> Function() task) {
    if (!_tasks.contains(task)) {
      _tasks.add(task);
    }
  }

  static void removeTask(Future<void> Function() task) => _tasks.remove(task);

  /// 关窗口（或定时关闭直接退出）之前调用，只跑一次。每件事最多等 5 秒，出错不影响别的
  static Future<void> runBeforeClose() => _running ??= _run();

  static Future<void> _run() async {
    for (var task in List.of(_tasks)) {
      try {
        await task().timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  @visibleForTesting
  static void reset() {
    _holds.clear();
    _tasks.clear();
    _running = null;
  }
}
