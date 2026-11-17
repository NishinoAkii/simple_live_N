import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/multi_window/window_snapshot.dart';

// 多开：副窗口的数据快照

void main() {
  late Directory support;

  setUp(() {
    support = Directory.systemTemp.createTempSync("mw_snapshot_");
  });

  tearDown(() {
    if (support.existsSync()) {
      support.deleteSync(recursive: true);
    }
  });

  void file(String name, String content) =>
      File(p.join(support.path, name)).writeAsStringSync(content);

  test("只复制 Hive 的数据文件，锁文件、日志、直播源、语言文件夹不复制", () async {
    file("followuser.hive", "follows");
    file("history.hive", "history");
    file("localstorage.hive", "settings");
    file("Secret.hivec", "encrypted");
    file("followuser.lock", "");
    file("localstorage.lock", "");
    file("notes.txt", "x");
    Directory(p.join(support.path, "log")).createSync();
    File(p.join(support.path, "log", "a.log")).writeAsStringSync("log");
    Directory(p.join(support.path, "live_sources")).createSync();

    var dir = await WindowSnapshot.create(support.path, 2,
        now: DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(dir.path, p.join(support.path, "multi_window", "w2-1700000000000"));
    var count = await WindowSnapshot.copy(support, dir);
    expect(count, 4);
    var names = dir.listSync().map((e) => p.basename(e.path)).toSet();
    expect(names, {
      "followuser.hive",
      "history.hive",
      "localstorage.hive",
      "Secret.hivec",
    });
    expect(
        File(p.join(dir.path, "history.hive")).readAsStringSync(), "history");
    // 快照里改动不影响原来的
    File(p.join(dir.path, "history.hive")).writeAsStringSync("changed");
    expect(File(p.join(support.path, "history.hive")).readAsStringSync(),
        "history");
  });

  test("快照目录本身不会被复制进下一份快照", () async {
    file("a.hive", "1");
    var first = await WindowSnapshot.create(support.path, 1);
    await WindowSnapshot.copy(support, first);
    var second = await WindowSnapshot.create(support.path, 2);
    expect(await WindowSnapshot.copy(support, second), 1);
    expect(second.listSync().map((e) => p.basename(e.path)), ["a.hive"]);
  });

  test("没有数据时什么都不复制", () async {
    var dir = await WindowSnapshot.create(support.path, 1);
    expect(
        await WindowSnapshot.copy(Directory(p.join(support.path, "none")), dir),
        0);
  });

  test("清理：不用的删掉，正在用的和要留的不删", () async {
    var root = WindowSnapshot.root(support.path);
    var stale = await WindowSnapshot.create(support.path, 1,
        now: DateTime.fromMillisecondsSinceEpoch(1));
    File(p.join(stale.path, "a.hive")).writeAsStringSync("x");
    var kept = await WindowSnapshot.create(support.path, 2,
        now: DateTime.fromMillisecondsSinceEpoch(2));
    var busy = await WindowSnapshot.create(support.path, 3,
        now: DateTime.fromMillisecondsSinceEpoch(3));
    // 副窗口的 Hive 开着：锁文件锁着
    var lock = await File(p.join(busy.path, "localstorage.lock"))
        .open(mode: FileMode.write);
    await lock.lock();
    try {
      var deleted = await WindowSnapshot.cleanup(root, keep: {kept.path});
      if (Platform.isWindows) {
        // Windows 上同一个进程里另开的文件也锁不上
        expect(deleted, 1);
        expect(busy.existsSync(), isTrue);
      }
      expect(stale.existsSync(), isFalse);
      expect(kept.existsSync(), isTrue);
    } finally {
      await lock.unlock();
      await lock.close();
    }
    expect(await WindowSnapshot.cleanup(root, keep: {kept.path}),
        Platform.isWindows ? 1 : 0);
    expect(busy.existsSync(), isFalse);
  });
}
