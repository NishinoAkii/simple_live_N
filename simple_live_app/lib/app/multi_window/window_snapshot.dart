import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/multi_window/window_args.dart';

/// 副窗口用的数据快照：Hive 同一时间只能有一个进程写，
/// 所以副窗口启动前把主窗口的数据库文件复制一份给它。副窗口在快照里的改动窗口一关就没了，
/// 要留下的改动另外交给主窗口保存（见 WindowChange）
class WindowSnapshot {
  WindowSnapshot._();

  /// 快照的上一级目录：应用数据目录下的 multi_window
  static Directory root(String supportDir) =>
      Directory(p.join(supportDir, SecondaryLaunch.snapshotFolder));

  /// 给第 [slot] 个副窗口新建一个空目录
  static Future<Directory> create(String supportDir, int slot,
      {DateTime? now}) {
    var time = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return Directory(p.join(root(supportDir).path, "w$slot-$time"))
        .create(recursive: true);
  }

  /// 只复制 Hive 的数据文件（.hive、.hivec），锁文件和别的文件夹不复制。返回复制了几个
  static Future<int> copy(Directory from, Directory to) async {
    if (!await from.exists()) {
      return 0;
    }
    await to.create(recursive: true);
    var count = 0;
    await for (var entity in from.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      var name = p.basename(entity.path);
      var lower = name.toLowerCase();
      if (!lower.endsWith(".hive") && !lower.endsWith(".hivec")) {
        continue;
      }
      await entity.copy(p.join(to.path, name));
      count++;
    }
    return count;
  }

  /// 删掉没在用的快照（上次没删掉的、主窗口崩了留下的）。[keep] 里的不删；
  /// 还被副窗口占着的（锁文件锁着）跳过。返回删了几个
  static Future<int> cleanup(Directory rootDir,
      {Set<String> keep = const {}}) async {
    if (!await rootDir.exists()) {
      return 0;
    }
    var keepPaths = keep.map(p.normalize).toSet();
    var count = 0;
    await for (var entity in rootDir.list(followLinks: false)) {
      if (entity is! Directory ||
          keepPaths.contains(p.normalize(entity.path))) {
        continue;
      }
      if (await inUse(entity)) {
        continue;
      }
      try {
        await entity.delete(recursive: true);
        count++;
      } on FileSystemException {
        // Windows 上文件还开着时删不掉，下次再删
      }
    }
    return count;
  }

  /// 有锁文件锁着（副窗口的 Hive 还开着）
  static Future<bool> inUse(Directory dir) async {
    await for (var entity in dir.list(followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith(".lock")) {
        continue;
      }
      RandomAccessFile? file;
      try {
        file = await entity.open(mode: FileMode.append);
        await file.lock();
        await file.unlock();
      } on FileSystemException {
        return true;
      } finally {
        await file?.close();
      }
    }
    return false;
  }
}
