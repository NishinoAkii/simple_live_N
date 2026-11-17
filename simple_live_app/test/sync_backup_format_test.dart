import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/sync_backup_format.dart';

List<int> zipOf(Map<String, Object> files) {
  var archive = Archive();
  files.forEach((name, content) {
    var bytes = utf8.encode(jsonEncode(content));
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive);
}

const follows = 'SimpleLive_follows.json';
const settings = 'SimpleLive_Settings.json';
const histories = 'SimpleLive_histories.json';

void main() {
  test('official backups have no ext: local new-platform data is kept', () {
    var backup = SyncBackupFormat(SyncBackupFormat.decodeZipSync(zipOf({
      follows: {
        'data': [
          {'id': 'douyu_1', 'siteId': 'douyu'}
        ]
      },
    })));
    expect(backup.mainList(follows).length, 1);
    expect(backup.extList(follows, 'follows'), isNull);
  });

  test('same-file ext is read, official readers only see data', () {
    var files = SyncBackupFormat.decodeZipSync(zipOf({
      follows: SyncBackupFormat.pack(
        [
          {'id': 'douyu_1', 'siteId': 'douyu'}
        ],
        [
          {'id': 'twitch_xqc', 'siteId': 'twitch'}
        ],
      ),
      settings: SyncBackupFormat.pack(
        {'SiteSort': 'bilibili,douyu,huya,douyin'},
        {'SiteSort': 'bilibili,douyu,huya,douyin,twitch,kick'},
      ),
    }));
    var backup = SyncBackupFormat(files);
    expect(backup.extList(follows, 'follows')!.single['siteId'], 'twitch');
    expect(backup.extMap(settings, 'settings')!['SiteSort'],
        endsWith('twitch,kick'));
    // 官方版的读取方式：json['data']
    var officialView = (files[follows] as Map)['data'] as List;
    expect(officialView.map((e) => e['siteId']), ['douyu']);
  });

  test('an empty ext list still marks the backup as ours', () {
    var backup = SyncBackupFormat(SyncBackupFormat.decodeZipSync(zipOf({
      follows: SyncBackupFormat.pack([], []),
    })));
    expect(backup.extList(follows, 'follows'), isEmpty);
  });

  test('legacy separate SimpleLive_ext.json is still understood', () {
    var backup = SyncBackupFormat(SyncBackupFormat.decodeZipSync(zipOf({
      follows: {'data': []},
      SyncBackupFormat.legacyExtFile: {
        'data': {
          'follows': [
            {'id': 'kick_abc', 'siteId': 'kick'}
          ],
          'settings': {'TwitchToken': 't'},
        }
      },
    })));
    expect(backup.extList(follows, 'follows')!.single['id'], 'kick_abc');
    expect(backup.extMap(settings, 'settings'), {'TwitchToken': 't'});
  });

  test('decoding runs in an isolate without capturing callers', () async {
    var files = await SyncBackupFormat.decodeZip(zipOf({
      'sub/SimpleLive_Tags.json': {'data': []},
      'readme.txt': 'x',
    }));
    expect(files.keys, ['SimpleLive_Tags.json']);
  });

  test('live-source items: scripts key (now) or inside ext (older backups)', () {
    // 现在：ext 里没有 js:，直播源平台的关注在 scripts 里，旧版只读 data/ext
    var now = SyncBackupFormat(SyncBackupFormat.decodeZipSync(zipOf({
      follows: SyncBackupFormat.pack(
        [
          {'id': 'douyu_1'},
        ],
        [
          {'id': 'twitch_x'},
        ],
        {
          SyncBackupFormat.scriptsKey: [
            {'id': 'js:acfun_1'},
          ],
        },
      ),
    })));
    expect(now.extList(follows, 'follows')!.map((e) => e['id']), ['twitch_x']);
    expect(
      [
        ...now.mainList(follows),
        ...?now.extList(follows, 'follows'),
        ...?now.extraList(follows, SyncBackupFormat.scriptsKey),
      ].map((e) => e['id']),
      ['douyu_1', 'twitch_x', 'js:acfun_1'],
    );
    // 旧版本写的备份：js: 在 ext 里，没有 scripts，合起来同样完整
    var r14 = SyncBackupFormat(SyncBackupFormat.decodeZipSync(zipOf({
      follows: SyncBackupFormat.pack(
        [],
        [
          {'id': 'twitch_x'},
          {'id': 'js:acfun_1'},
        ],
      ),
    })));
    expect(r14.extraList(follows, SyncBackupFormat.scriptsKey), isNull);
    expect(r14.extList(follows, 'follows'), hasLength(2));
  });
}
