import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/services/shared_profile.dart';

void main() {
  late Directory root;
  late Directory shared;
  late Directory own;

  File fileIn(Directory dir, String name) => File(p.join(dir.path, name));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('shared_profile');
    shared = Directory(p.join(root.path, SharedProfile.sharedName))
      ..createSync();
    own = Directory(p.join(root.path, 'simple_live_N'))..createSync();
    fileIn(shared, 'followuser.hive').writeAsStringSync('old');
    Directory(p.join(shared.path, 'live_sources')).createSync();
    fileIn(shared, p.join('live_sources', 'a.live.js')).writeAsStringSync('x');
  });

  tearDown(() => root.delete(recursive: true));

  test('本版本从来没和官方版共用文件夹：什么都不搬', () {
    expect(SharedProfile.pendingMove(own), isNull);
    var other = Directory(p.join(root.path, 'simple_live_app_r16test'));
    expect(SharedProfile.pendingMove(other), isNull);
  });

  test('整个搬过来，旧文件夹不留，不再搬第二次', () async {
    fileIn(own, 'half.hive').writeAsStringSync('上次失败时留下的');

    await SharedProfile.move(shared, own);

    expect(shared.existsSync(), isFalse);
    expect(fileIn(own, 'followuser.hive').readAsStringSync(), 'old');
    expect(
        fileIn(own, p.join('live_sources', 'a.live.js')).existsSync(), isTrue);
    expect(fileIn(own, 'half.hive').existsSync(), isFalse);
    expect(SharedProfile.pendingMove(own), isNull);
  });

  test('官方版之后新建的存档不会被搬过来', () async {
    await SharedProfile.move(shared, own);
    shared.createSync();
    fileIn(shared, 'followuser.hive').writeAsStringSync('official');

    expect(SharedProfile.pendingMove(own), isNull);
    expect(fileIn(own, 'followuser.hive').readAsStringSync(), 'old');
  });

  test('新装的：没有旧文件夹，已有的不动，以后也不搬', () async {
    shared.deleteSync(recursive: true);
    fileIn(own, 'followuser.hive').writeAsStringSync('mine');

    await SharedProfile.move(shared, own);

    expect(fileIn(own, 'followuser.hive').readAsStringSync(), 'mine');
    shared.createSync();
    expect(SharedProfile.pendingMove(own), isNull);
  });

  test('搬不了：旧文件夹还在，下次重来', () async {
    own.deleteSync(recursive: true);
    File(own.path).writeAsStringSync('挡住改名');

    await expectLater(
      SharedProfile.move(shared, own),
      throwsA(isA<FileSystemException>()),
    );

    expect(fileIn(shared, 'followuser.hive').readAsStringSync(), 'old');
  });
}
