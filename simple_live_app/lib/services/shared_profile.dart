import 'dart:io';

import 'package:path/path.dart' as p;

/// Windows 数据文件夹的搬迁逻辑。本版本一开始就有自己的数据文件夹（Runner.rc 的 ProductName），
/// ownName 为空，不会搬动官方版的文件夹。
class SharedProfile {
  static const String ownName = "";
  static const String sharedName = "simple_live_app";
  static const String _movedMarker = ".moved_from_shared";

  /// 测试版用别的文件夹名，不碰真实数据
  static const String _testSharedName =
      String.fromEnvironment("SHARED_PROFILE");

  /// 还没搬过时返回旧文件夹，否则返回 null
  static Directory? pendingMove(Directory own) {
    var name = _testSharedName.isNotEmpty
        ? _testSharedName
        : p.basename(own.path) == ownName
            ? sharedName
            : null;
    if (name == null || File(p.join(own.path, _movedMarker)).existsSync()) {
      return null;
    }
    return Directory(p.join(own.parent.path, name));
  }

  /// 失败时旧文件夹还在，下次启动重来
  static Future<void> move(Directory shared, Directory own) async {
    if (!shared.existsSync()) {
      // 新装的，没有旧数据。记下来，以后再装官方版也不会把它的存档搬过来
      await File(p.join(own.path, _movedMarker)).writeAsString("");
      return;
    }
    // 标记写进旧文件夹，随它一起改名，不会搬完了却没记下来
    await File(p.join(shared.path, _movedMarker)).writeAsString("");
    if (own.existsSync()) {
      await own.delete(recursive: true);
    }
    // 上一个进程刚退出时，杀毒软件可能还占着文件
    for (var i = 0;; i++) {
      try {
        await shared.rename(own.path);
        return;
      } on FileSystemException {
        if (i >= 9) {
          rethrow;
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
  }
}
