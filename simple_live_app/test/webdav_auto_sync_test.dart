import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/webdav_client.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_backup_format.dart';
import 'package:simple_live_app/services/webdav_archive.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_app/services/sync_vault.dart';
import 'package:simple_live_app/services/webdav_addresses.dart';
import 'package:simple_live_app/services/webdav_auto_sync.dart';
import 'package:simple_live_app/services/webdav_sync_service.dart';

SyncBackupFormat backupWith({int? time, int follows = 1}) => SyncBackupFormat({
      SyncBackupFormat.followsFile: {
        'data': List.generate(follows, (i) => {'id': 'douyu_$i'}),
      },
      SyncBackupFormat.settingsFile: {
        'data': <String, dynamic>{},
        if (time != null) SyncBackupFormat.dataTimeKey: time,
      },
    });

class FakeHost implements WebDavAutoSyncHost {
  @override
  int dataTime;
  @override
  int syncedTime;
  WebDavRemoteArchive? remote;
  Object? remoteError;
  @override
  bool guardFollows = true;
  @override
  int localFollowCount = 3;

  int restored = 0;
  int fetches = 0;
  String? version;
  @override
  String? seenRemoteVersion;
  bool keepsLocal = false;
  int safetyCopies = 0;
  int? uploadedStamp;
  List<String> order = [];

  FakeHost({this.dataTime = 0, this.syncedTime = 0, this.remote});

  @override
  Future<String?> remoteVersion() async {
    if (remoteError != null) throw remoteError!;
    return version;
  }

  @override
  Future<WebDavRemoteArchive?> fetchRemote() async {
    if (remoteError != null) throw remoteError!;
    fetches++;
    return remote;
  }

  @override
  Future<List<int>> buildArchive(int dataTime) async {
    uploadedStamp = dataTime;
    return [1];
  }

  @override
  Future<String?> uploadRemote(List<int> zip) async {
    order.add('upload');
    return version;
  }

  @override
  Future<void> keepSafetyCopy() async {
    safetyCopies++;
    order.add('safety');
  }

  @override
  Future<bool> restoreArchive(SyncBackupFormat backup) async {
    restored++;
    order.add('restore');
    return keepsLocal;
  }
}

/// 只实现用到的 WebDAV 方法，文件放在内存里。和用户的 IIS 一样：
/// 不带账号的请求一律回 401 + Basic，带对账号才处理
Future<HttpServer> fakeWebDav(Map<String, List<int>> files) async {
  var server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    var body = <int>[];
    await request.forEach(body.addAll);
    var path = request.uri.path;
    var response = request.response;
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Basic ${base64.encode(utf8.encode('u:p'))}') {
      response.statusCode = HttpStatus.unauthorized;
      response.headers.set(
        HttpHeaders.wwwAuthenticateHeader,
        'Basic realm="localhost"',
      );
      await response.close();
      return;
    }
    switch (request.method) {
      case 'OPTIONS':
        break;
      case 'MKCOL':
        response.statusCode = HttpStatus.created;
        break;
      case 'PUT':
        files[path] = body;
        response.statusCode = HttpStatus.created;
        break;
      case 'DELETE':
        files.remove(path);
        response.statusCode = HttpStatus.noContent;
        break;
      case 'GET':
        if (files.containsKey(path)) {
          response.add(files[path]!);
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        break;
      case 'PROPFIND':
        // 和严格的服务器一样：文件路径后面多一个斜杠算不存在
        var children = files.keys.where((e) => e.startsWith(path)).toList();
        if (!path.endsWith('/') || children.isEmpty) {
          response.statusCode = HttpStatus.notFound;
          break;
        }
        response.statusCode = 207;
        response.write('''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
<d:response><d:href>$path</d:href><d:propstat><d:prop>
<d:resourcetype><d:collection/></d:resourcetype>
</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
${children.map((e) => '''<d:response><d:href>$e</d:href><d:propstat><d:prop>
<d:getlastmodified>Sat, 07 Nov 2026 01:02:03 GMT</d:getlastmodified>
<d:getcontentlength>${files[e]!.length}</d:getcontentlength><d:resourcetype/>
</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>''').join()}
</d:multistatus>''');
        break;
      default:
        response.statusCode = HttpStatus.methodNotAllowed;
    }
    await response.close();
  });
  return server;
}

/// 手机的流程：真的 Hive、真的打包和恢复、真的 WebDAV 客户端，只有服务器是假的
void mobileFlowTests() {
  const backupPath = '/simple_live_app/backup.zip';
  late Directory temp;
  late HttpServer server;
  late Map<String, List<int>> files;
  late WebDavSyncService service;
  late LocalStorageService storage;
  late List<String> toasts;

  Future<void> waitFor(bool Function() done, String what) async {
    for (var i = 0; i < 200; i++) {
      if (done()) return;
      await Future.delayed(const Duration(milliseconds: 25));
    }
    fail('等不到：$what');
  }

  SyncBackupFormat remote() =>
      SyncBackupFormat(SyncBackupFormat.decodeZipSync(files[backupPath]!));

  FollowUser follow(String id) => FollowUser(
        id: 'douyu_$id',
        roomId: id,
        siteId: 'douyu',
        userName: id,
        face: '',
        addTime: DateTime(2026),
      );

  void lifecycle(AppLifecycleState state) =>
      WidgetsBinding.instance.handleAppLifecycleStateChanged(state);

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // 测试环境默认拦截 HTTP，这里要连本机的假服务器
    HttpOverrides.global = null;
    temp = await Directory.systemTemp.createTemp('webdav_flow');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => temp.path,
    );
    Hive.init(temp.path);
    if (!Hive.isAdapterRegistered(FollowUserAdapter().typeId)) {
      Hive.registerAdapter(FollowUserAdapter());
      Hive.registerAdapter(HistoryAdapter());
      Hive.registerAdapter(FollowUserTagAdapter());
    }
    files = {};
    server = await fakeWebDav(files);
    storage = Get.put(LocalStorageService());
    await storage.init();
    await Get.put(DBService()).init();
    Get.put(AppSettingsController());
    Get.put(BiliBiliAccountService());
    await storage.setValue(
      LocalStorageService.kWebDAVUri,
      'http://127.0.0.1:${server.port}',
    );
    await storage.setValue(LocalStorageService.kWebDAVUser, 'u');
    await storage.setValue(LocalStorageService.kWebDAVPassword, 'p');
    WebDavSyncService.debugIsDesktop = false;
    WebDavSyncService.resumeCheckAfter = Duration.zero;
    WebDavSyncService.uploadDelay = const Duration(hours: 1);
    toasts = [];
    WebDavSyncService.showToastText = toasts.add;
    service = Get.put(WebDavSyncService());
    service.onFirstFrame();
  });

  tearDown(() async {
    service.onClose();
    Get.reset();
    await Hive.close();
    await server.close(force: true);
    await temp.delete(recursive: true);
    WebDavSyncService.debugIsDesktop = null;
  });

  test('开关默认关：切到后台不上传', () async {
    await DBService.instance.addFollow(follow('1'));
    lifecycle(AppLifecycleState.paused);
    await Future.delayed(const Duration(milliseconds: 100));
    expect(service.enabled, isFalse);
    expect(files, isEmpty);
    lifecycle(AppLifecycleState.resumed);
  });

  test('改动 → 切到后台上传；别的设备传了新的 → 回到前台拉取，不算本机改动', () async {
    expect(await service.enable(), WebDavPullResult.noRemote);

    // 本机加关注，时间戳变新；失去焦点就传
    var before = service.dataTime;
    await DBService.instance.addFollow(follow('1'));
    await waitFor(() => service.dataTime > before, '时间戳更新');
    lifecycle(AppLifecycleState.inactive);
    await waitFor(() => files.containsKey(backupPath), '上传');
    await waitFor(() => service.syncedTime == service.dataTime, '对齐');
    expect(remote().dataTime, service.dataTime);
    expect(remote().followCount, 1);

    // 没有新改动：再切后台不会再传
    var uploaded = files[backupPath];
    lifecycle(AppLifecycleState.paused);
    await Future.delayed(const Duration(milliseconds: 100));
    expect(identical(files[backupPath], uploaded), isTrue);

    // 别的设备传了更新的存档：多一个关注，还有屏蔽词
    var newer = service.dataTime + 1000;
    var other = <String, Object>{
      SyncBackupFormat.followsFile: {
        'data': [follow('1').toJson(), follow('2').toJson()],
        'ext': [],
      },
      SyncBackupFormat.blockedWordFile: {
        'data': ['云端屏蔽词'],
      },
      SyncBackupFormat.settingsFile: {
        'data': {LocalStorageService.kDanmuSize: 99.0},
        'ext': <String, dynamic>{},
        'scripts': <String, dynamic>{},
        SyncBackupFormat.liveSourcesKey: <String, dynamic>{},
        SyncBackupFormat.dataTimeKey: newer,
      },
    };
    var archive = Archive();
    other.forEach((name, content) {
      var bytes = utf8.encode(jsonEncode(content));
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    });
    var theirs = ZipEncoder().encode(archive);
    files[backupPath] = theirs;

    lifecycle(AppLifecycleState.resumed);
    await waitFor(() => DBService.instance.followBox.length == 2, '拉取');
    await waitFor(() => service.dataTime == newer, '时间戳对齐');
    await Future.delayed(const Duration(milliseconds: 100));
    expect(toasts, ['已同步云端的存档']);
    expect(AppSettingsController.instance.shieldList, contains('云端屏蔽词'));
    // 拉取写进来的内容不算本机改动：时间戳还是云端的，也不会传回去
    expect(service.dataTime, newer);
    expect(service.syncedTime, newer);
    // 弹幕大小这些设置默认不跟着同步
    expect(storage.getValue(LocalStorageService.kDanmuSize, 0.0), isNot(99.0));
    lifecycle(AppLifecycleState.inactive);
    lifecycle(AppLifecycleState.paused);
    await Future.delayed(const Duration(milliseconds: 100));
    expect(identical(files[backupPath], theirs), isTrue);
    lifecycle(AppLifecycleState.resumed);
    await Future.delayed(const Duration(milliseconds: 100));
    // 覆盖之前留了一份
    expect(
      File('${temp.path}${Platform.pathSeparator}webdav_before_pull.zip')
          .existsSync(),
      isTrue,
    );
  });

  test('上次没传成：下次启动时补上', () async {
    await service.enable();
    await DBService.instance.addFollow(follow('1'));
    await waitFor(() => service.dataTime > 0, '时间戳更新');
    // 这时被系统杀掉，什么都没传。下次启动：
    expect(files, isEmpty);
    await service.pullIfNewer();
    await waitFor(() => files.containsKey(backupPath), '补传');
    await service.pushIfNewer();
    expect(remote().followCount, 1);
  });

  test('看过的不丢：拉取时留下本机刚看的，再传上去', () async {
    await service.enable();
    await DBService.instance.addFollow(follow('1'));
    await waitFor(() => service.dataTime > 0, '时间戳更新');
    lifecycle(AppLifecycleState.inactive);
    await waitFor(() => files.containsKey(backupPath), '上传');
    await waitFor(() => service.syncedTime == service.dataTime, '对齐');

    // 本机看了一个直播间，同时别的设备传了更新的存档（里面没有这条记录）
    var watched = History(
      id: 'douyu_9',
      roomId: '9',
      siteId: 'douyu',
      userName: '刚看的',
      face: '',
      updateTime: DateTime.now(),
    );
    await DBService.instance.addOrUpdateHistory(watched);
    var newer = DateTime.now().millisecondsSinceEpoch + 60000;
    var content = <String, Object>{
      SyncBackupFormat.followsFile: {
        'data': [follow('1').toJson()],
        'ext': [],
      },
      SyncBackupFormat.historiesFile: {'data': [], 'ext': []},
      SyncBackupFormat.settingsFile: {
        'data': <String, dynamic>{},
        'ext': <String, dynamic>{},
        SyncBackupFormat.dataTimeKey: newer,
      },
    };
    var archive = Archive();
    content.forEach((name, value) {
      var bytes = utf8.encode(jsonEncode(value));
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    });
    files[backupPath] = ZipEncoder().encode(archive);

    await service.pullIfNewer();
    await waitFor(() => service.syncedTime == newer, '拉取');
    expect(DBService.instance.historyBox.get('douyu_9')?.userName, '刚看的');
    expect(service.dataTime, greaterThan(newer));

    // 切到后台：合并后的存档传上去，别的设备也能看到这条
    lifecycle(AppLifecycleState.paused);
    await waitFor(() => service.syncedTime == service.dataTime, '上传');
    var names = remote().mainList(SyncBackupFormat.historiesFile);
    expect(names.map((e) => e['id']), contains('douyu_9'));
    lifecycle(AppLifecycleState.resumed);
    // 回到前台会再拉取一次。同步任务按顺序排队，等排在后面的这次做完，
    // 前一次也就做完了，不会在测试收尾、服务清掉之后还在跑
    await service.pullIfNewer();
  });

  test('改动后不等退出就上传，连续改动只传一次', () async {
    await service.enable();
    WebDavSyncService.uploadDelay = const Duration(milliseconds: 200);
    await DBService.instance.addFollow(follow('1'));
    await DBService.instance.addFollow(follow('2'));
    expect(files, isEmpty);
    await waitFor(() => files.containsKey(backupPath), '自动上传');
    await waitFor(() => service.syncedTime == service.dataTime, '对齐');
    expect(remote().followCount, 2);
  });

  test('改动后自动上传连不上：提示，下次再传', () async {
    await service.enable();
    WebDavSyncService.uploadDelay = const Duration(milliseconds: 50);
    await server.close(force: true);
    var before = service.syncedTime;
    await DBService.instance.addFollow(follow('1'));
    await waitFor(() => toasts.contains('连不上 WebDAV'), '提示');
    expect(service.syncedTime, before);
    expect(service.dataTime, greaterThan(before));
  });

  test('连不上：报错，还是已登录，账号密码还在', () async {
    await service.enable();
    await server.close(force: true);
    await service.pullIfNewer(showToast: true);
    expect(toasts.toSet(), {'连不上 WebDAV'});
    expect(service.enabled, isTrue);
    expect(service.status.value, endsWith('连不上 WebDAV'));
    expect(storage.getValue(LocalStorageService.kWebDAVUri, ''), isNotEmpty);
    expect(storage.getValue(LocalStorageService.kWebDAVUser, ''), 'u');
    expect(storage.getValue(LocalStorageService.kWebDAVPassword, ''), 'p');
  });

  group('和官方 1.11.7 互相同步', () {
    FollowUser followOn(String site, String room) => FollowUser(
          id: '${site}_$room',
          roomId: room,
          siteId: site,
          userName: room,
          face: '',
          addTime: DateTime(2026),
        );

    test('传给官方：data 里只有官方平台，官方的读法能读', () async {
      var db = DBService.instance;
      await db.addFollow(followOn('bilibili', '1'));
      await db.addFollow(followOn('twitch', 'xqc'));
      await db.addFollow(followOn('js:steam', '7'));
      await db.addOrUpdateHistory(History(
        id: 'douyu_2',
        roomId: '2',
        siteId: 'douyu',
        userName: 'a',
        face: '',
        updateTime: DateTime(2026),
        cover: 'c',
        title: 't',
      ));
      // 官方的恢复：按完整文件名匹配，只读每个文件的 data
      var vaultKey = await SyncVault.keyFor('u', 'p');
      var archive =
          ZipDecoder().decodeBytes(WebDavArchive.build(123, key: vaultKey));
      var files = {
        for (var file in archive)
          file.name: json.decode(utf8.decode(file.content)) as Map,
      };
      expect(
        files.keys,
        containsAll([
          'SimpleLive_follows.json',
          'SimpleLive_histories.json',
          'SimpleLive_blocked_word.json',
          'SimpleLive_Settings.json',
          'SimpleLive_Tags.json',
        ]),
      );
      // 哔哩哔哩账号和其它账号一起加密进设置文件，不再单独放（官方版找不到时不动本机登录）
      expect(files.containsKey('SimpleLive_bilibili_account.json'), isFalse);
      var follows = files['SimpleLive_follows.json']!['data'] as List;
      expect(follows.map((e) => e['siteId']), ['bilibili']);
      var history =
          (files['SimpleLive_histories.json']!['data'] as List).single;
      // 官方的 History.fromJson 要的字段都在
      expect(
        history.keys,
        containsAll(
            ['id', 'roomId', 'siteId', 'userName', 'face', 'updateTime']),
      );
      DateTime.parse(history['updateTime']);
      // 官方恢复设置时会清空再写入。账号和 WebDAV 连接不写明文，官方版恢复后要重新登录；
      // 自动同步的内部状态也不能在
      var settings = files['SimpleLive_Settings.json']!['data'] as Map;
      for (var key in SyncVault.connectionKeys) {
        expect(settings.containsKey(key), isFalse, reason: key);
      }
      expect(
          files['SimpleLive_Settings.json']![SyncVault.extraKey], isA<Map>());
      for (var key in settings.keys) {
        expect(SyncCompat.isLocalOnlySetting(key.toString()), isFalse,
            reason: key);
      }
    });

    test('拉官方的存档：Twitch、直播源的关注和记录都留着，再传回云端', () async {
      var db = DBService.instance;
      await service.enable();
      await db.addFollow(followOn('twitch', 'xqc'));
      await db.addFollow(followOn('js:steam', '7'));
      await db.addFollow(followOn('bilibili', 'old'));
      await db.addOrUpdateHistory(History(
        id: 'twitch_xqc',
        roomId: 'xqc',
        siteId: 'twitch',
        userName: 'x',
        face: '',
        updateTime: DateTime(2026),
      ));
      // 官方版上传的样子：只有 data，没有时间戳
      var official = <String, Object>{
        SyncBackupFormat.followsFile: {
          'data': [followOn('bilibili', 'new').toJson()],
        },
        SyncBackupFormat.tagsFile: {'data': []},
        SyncBackupFormat.historiesFile: {'data': []},
        SyncBackupFormat.blockedWordFile: {'data': []},
        SyncBackupFormat.bilibiliAccountFile: {
          'data': {'cookie': ''},
        },
        SyncBackupFormat.settingsFile: {
          'data': {LocalStorageService.kDanmuSize: 99.0},
        },
      };
      var archive = Archive();
      official.forEach((name, value) {
        var bytes = utf8.encode(jsonEncode(value));
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      });
      files[backupPath] = ZipEncoder().encode(archive);
      // 文件时间比本机新（假服务器固定回 2026-11-07，先把本机时间戳调回去）
      service.dataTime = 1;
      service.syncedTime = 1;

      await service.pullIfNewer();
      await waitFor(() => db.followBox.containsKey('bilibili_new'), '拉取');
      expect(db.followBox.containsKey('bilibili_old'), isFalse);
      expect(db.followBox.containsKey('twitch_xqc'), isTrue);
      expect(db.followBox.containsKey('js:steam_7'), isTrue);
      expect(db.historyBox.containsKey('twitch_xqc'), isTrue);
      expect(
          storage.getValue(LocalStorageService.kDanmuSize, 0.0), isNot(99.0));

      // 官方的存档里没有这些，要再传回云端
      await waitFor(() => service.dataTime > service.syncedTime, '待上传');
      await service.pushIfNewer();
      var again = remote();
      expect(again.dataTime, isNotNull);
      expect(
        again
            .extList(SyncBackupFormat.followsFile, 'follows')!
            .map((e) => e['id']),
        ['twitch_xqc'],
      );
      expect(
        again
            .extraList(
                SyncBackupFormat.followsFile, SyncBackupFormat.scriptsKey)!
            .map((e) => e['id']),
        ['js:steam_7'],
      );
      expect(
        again.mainList(SyncBackupFormat.followsFile).map((e) => e['id']),
        ['bilibili_new'],
      );
    });

    test('别的版本加的附加项：拉取时记下，再传回云端时原样带上', () async {
      var db = DBService.instance;
      await service.enable();
      await db.addFollow(followOn('douyu', '1'));
      var later = [
        {'id': 'x', 'updateTime': 5},
      ];
      var other = <String, Object>{
        SyncBackupFormat.followsFile: {
          'data': [followOn('douyu', '1').toJson()],
        },
        SyncBackupFormat.historiesFile: {'data': [], 'ext': [], 'later': later},
        SyncBackupFormat.settingsFile: {
          'data': <String, Object>{},
          'ext': <String, Object>{},
          'laterMap': {'a': 1},
        },
      };
      var archive = Archive();
      other.forEach((name, value) {
        var bytes = utf8.encode(jsonEncode(value));
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      });
      files[backupPath] = ZipEncoder().encode(archive);
      service.dataTime = 1;
      service.syncedTime = 1;

      await service.pullIfNewer();
      await waitFor(
        () => storage
            .getValue(LocalStorageService.kWebDAVPassThrough, '')
            .isNotEmpty,
        '拉取',
      );
      await db.addFollow(followOn('douyu', '2'));
      await waitFor(() => service.dataTime > service.syncedTime, '待上传');
      await service.pushIfNewer();
      var again = remote();
      expect(again.extraList(SyncBackupFormat.historiesFile, 'later'), later);
      expect(again.extraMap(SyncBackupFormat.settingsFile, 'laterMap'),
          {'a': 1});
      // 本版本自己写的项不算“不认识的”
      expect(WebDavArchive.unknownExtras(again).keys,
          [SyncBackupFormat.historiesFile, SyncBackupFormat.settingsFile]);
      expect(
          WebDavArchive.unknownExtras(again)[SyncBackupFormat.settingsFile]!
              .keys,
          ['laterMap']);
    });
  });

  group('账号加密', () {
    test('云端文件里看不到账号和 WebDAV 密码，同一 WebDAV 账号的设备能解开', () async {
      await service.enable();
      await storage.setValue(
          LocalStorageService.kTwitchToken, 'twitch-secret-token');
      BiliBiliAccountService.instance.setCookie('SESSDATA=bili-secret-sess');
      await service.uploadNow(DAVClient(
        storage.getValue(LocalStorageService.kWebDAVUri, ''),
        'u',
        'p',
      ));
      var zip = files[backupPath]!;
      var text = ZipDecoder()
          .decodeBytes(zip)
          .map((file) => utf8.decode(file.content))
          .join('\n');
      expect(text, isNot(contains('twitch-secret-token')));
      expect(text, isNot(contains('bili-secret-sess')));
      expect(text, isNot(contains(LocalStorageService.kWebDAVPassword)));
      expect(text, isNot(contains(LocalStorageService.kWebDAVUser)));
      expect(text, isNot(contains('127.0.0.1')));

      // 另一台设备：WebDAV 账号名大小写不同也能解开
      var (opened, ok) = await SyncVault.openBackup(
        remote(),
        user: ' U ',
        password: 'p',
        localSettings: const {},
      );
      expect(ok, isTrue);
      expect(
        opened.extMap(SyncBackupFormat.settingsFile,
            'settings')![LocalStorageService.kTwitchToken],
        'twitch-secret-token',
      );
      expect(
        (opened.main(SyncBackupFormat.settingsFile)
            as Map)[LocalStorageService.kBilibiliCookie],
        'SESSDATA=bili-secret-sess',
      );
    });

    test('密码不同的设备传的存档：解不开就保留本机登录，状态里说明', () async {
      await service.enable();
      // 另一台设备用别的密码加密的存档
      await storage.setValue(LocalStorageService.kTwitchToken, 'other-token');
      var otherKey = await SyncVault.keyFor('u', 'other-password');
      files[backupPath] = WebDavArchive.build(
        DateTime.now().millisecondsSinceEpoch + 60000,
        key: otherKey,
      );
      await storage.setValue(LocalStorageService.kTwitchToken, 'local-token');
      await service.pullIfNewer();
      await waitFor(
        () => service.status.value.endsWith(SyncVault.openFailedText),
        '提示',
      );
      expect(
        storage.getValue(LocalStorageService.kTwitchToken, ''),
        'local-token',
      );
    });

    test('用过的 WebDAV 地址和备注加密进存档；拉取时和本机的合并，不按“同步设置”，正在用的地址不变', () async {
      await service.enable();
      var active = storage.getValue(LocalStorageService.kWebDAVUri, '');
      // 另一台设备传的存档：它用过本机这个地址，还写了一个局域网地址的备注
      await WebDavAddressBook.use(active);
      await WebDavAddressBook.setNote('http://192.168.9.9:8090', '家里的路由器');
      files[backupPath] = WebDavArchive.build(
        DateTime.now().millisecondsSinceEpoch + 60000,
        key: await SyncVault.keyFor('u', 'p'),
      );
      var text = ZipDecoder()
          .decodeBytes(files[backupPath]!)
          .map((file) => utf8.decode(file.content))
          .join('\n');
      expect(text, isNot(contains('127.0.0.1')));
      expect(text, isNot(contains('192.168.9.9')));
      expect(text, isNot(contains('家里的路由器')));
      // 旧版只解开账号那一项：里面没有地址表
      var accounts = await SyncVault.open(
        remote().extraMap(SyncBackupFormat.settingsFile, SyncVault.extraKey)!,
        user: 'u',
        password: 'p',
        context: SyncVault.webDavContext(remote().dataTime!),
      );
      expect(accounts, isNotNull);
      expect(accounts!.containsKey(WebDavAddressBook.kKey), isFalse);

      // 本机：只记着一个外网地址
      await storage.setValue(
        WebDavAddressBook.kKey,
        WebDavAddressBook.encode([
          const WebDavAddress(uri: 'https://dav.example.com', note: '外网', time: 1),
        ]),
      );
      expect(WebDavSyncOptions.autoSettings, isFalse);
      await service.pullIfNewer();
      await waitFor(
        () => WebDavAddressBook.visible().length == 3,
        '地址表合并',
      );
      expect(
        WebDavAddressBook.visible().map((e) => e.label).toSet(),
        {active, '家里的路由器', '外网'},
      );
      expect(storage.getValue(LocalStorageService.kWebDAVUri, ''), active);
    });
  });

  test('关掉开关后不再上传', () async {
    await service.enable();
    await service.disable();
    await DBService.instance.addFollow(follow('1'));
    lifecycle(AppLifecycleState.paused);
    await Future.delayed(const Duration(milliseconds: 100));
    expect(files, isEmpty);
    lifecycle(AppLifecycleState.resumed);
  });
}

void main() {
  group('手机的流程', mobileFlowTests);

  group('启动时比较', () {
    test('云端更新：先留一份再拉取，时间戳对齐，退出时不重复上传', () async {
      var host = FakeHost(
        dataTime: 100,
        syncedTime: 100,
        remote: WebDavRemoteArchive(backupWith(), 200),
      );
      var sync = WebDavAutoSync(host);
      expect(await sync.pullIfNewer(), WebDavPullResult.pulled);
      expect(host.order, ['safety', 'restore']);
      expect(host.dataTime, 200);
      expect(host.syncedTime, 200);
      expect(await sync.pushIfNewer(), WebDavPushResult.nothingNew);
    });

    test('拉取后本机还有云端没有的观看记录：退出时传上去', () async {
      var host = FakeHost(
        dataTime: 100,
        syncedTime: 100,
        remote: WebDavRemoteArchive(backupWith(), 200),
      )..keepsLocal = true;
      var sync = WebDavAutoSync(host);
      expect(await sync.pullIfNewer(), WebDavPullResult.pulled);
      expect(host.syncedTime, 200);
      expect(host.dataTime, greaterThan(200));
      expect(await sync.pushIfNewer(), WebDavPushResult.uploaded);
      expect(host.syncedTime, host.dataTime);
    });

    test('本机更新：不拉取，退出时上传', () async {
      var host = FakeHost(
        dataTime: 300,
        remote: WebDavRemoteArchive(backupWith(), 200),
      );
      var sync = WebDavAutoSync(host);
      expect(await sync.pullIfNewer(), WebDavPullResult.localNewer);
      expect(host.restored, 0);
      expect(host.dataTime, 300);
      expect(await sync.pushIfNewer(), WebDavPushResult.uploaded);
      expect(host.uploadedStamp, 300);
      expect(host.syncedTime, 300);
    });

    test('一样新：什么都不做', () async {
      var host = FakeHost(
        dataTime: 200,
        remote: WebDavRemoteArchive(backupWith(), 200),
      );
      var sync = WebDavAutoSync(host);
      expect(await sync.pullIfNewer(), WebDavPullResult.same);
      expect(await sync.pushIfNewer(), WebDavPushResult.nothingNew);
    });

    test('新装的设备时间戳是 0，会拉取', () async {
      var host = FakeHost(
        remote: WebDavRemoteArchive(backupWith(), 1),
      )..localFollowCount = 0;
      expect(await WebDavAutoSync(host).pullIfNewer(), WebDavPullResult.pulled);
    });

    test('本机关注是空的、云端有：就算本机时间戳新也拉取，不会盖掉云端', () async {
      var host = FakeHost(
        dataTime: 300,
        remote: WebDavRemoteArchive(backupWith(follows: 2), 200),
      )
        ..localFollowCount = 0
        ..keepsLocal = true
        ..version = 'v1';
      var sync = WebDavAutoSync(host);
      expect(await sync.pullIfNewer(), WebDavPullResult.pulled);
      expect(host.restored, 1);
      expect(host.seenRemoteVersion, 'v1');
      expect(host.syncedTime, 200);
      // 留下了刚看的记录，要传上去：这时本机已经有关注了
      host.localFollowCount = 2;
      expect(host.dataTime, greaterThan(200));
      expect(await sync.pushIfNewer(), WebDavPushResult.uploaded);
    });

    test('云端没有存档：退出时上传；本机也什么都没有时不传', () async {
      var host = FakeHost(dataTime: 100, syncedTime: 100);
      var sync = WebDavAutoSync(host);
      expect(await sync.pullIfNewer(), WebDavPullResult.noRemote);
      expect(await sync.pushIfNewer(), WebDavPushResult.uploaded);

      var empty = WebDavAutoSync(FakeHost());
      expect(await empty.pullIfNewer(), WebDavPullResult.noRemote);
      expect(await empty.pushIfNewer(), WebDavPushResult.nothingNew);
    });

    test('云端更新但关注列表是空的：不覆盖本机', () async {
      var host = FakeHost(
        dataTime: 100,
        remote: WebDavRemoteArchive(backupWith(follows: 0), 200),
      );
      expect(
        await WebDavAutoSync(host).pullIfNewer(),
        WebDavPullResult.remoteEmpty,
      );
      expect(host.restored, 0);
      expect(host.dataTime, 100);
    });

    test('连不上：抛出异常，时间戳不变', () async {
      var host = FakeHost(dataTime: 100, syncedTime: 50)
        ..remoteError = 'offline';
      await expectLater(WebDavAutoSync(host).pullIfNewer(), throwsA('offline'));
      expect(host.dataTime, 100);
      expect(host.syncedTime, 50);
    });
  });

  group('先看文件版本再下载', () {
    test('版本没变：启动和退出都不下载', () async {
      var host = FakeHost(
        dataTime: 200,
        syncedTime: 200,
        remote: WebDavRemoteArchive(backupWith(), 200),
      )
        ..version = 'v1'
        ..seenRemoteVersion = 'v1';
      var sync = WebDavAutoSync(host);
      expect(await sync.pullIfNewer(), WebDavPullResult.same);
      expect(host.fetches, 0);

      host.dataTime = 300;
      expect(await sync.pullIfNewer(), WebDavPullResult.localNewer);
      expect(await sync.pushIfNewer(), WebDavPushResult.uploaded);
      expect(host.fetches, 0);
    });

    test('版本变了才下载，下载后记下来', () async {
      var host = FakeHost(
        dataTime: 100,
        syncedTime: 100,
        remote: WebDavRemoteArchive(backupWith(), 200),
      )
        ..version = 'v2'
        ..seenRemoteVersion = 'v1';
      var sync = WebDavAutoSync(host);
      expect(await sync.pullIfNewer(), WebDavPullResult.pulled);
      expect(host.fetches, 1);
      expect(host.seenRemoteVersion, 'v2');
      expect(await sync.pullIfNewer(), WebDavPullResult.same);
      expect(host.fetches, 1);
    });

    test('上传后记下新版本', () async {
      var host = FakeHost(dataTime: 300, syncedTime: 200)..version = 'v3';
      expect(
        await WebDavAutoSync(host).pushIfNewer(),
        WebDavPushResult.uploaded,
      );
      expect(host.seenRemoteVersion, 'v3');
    });

    test('服务器不给版本：照常下载比较', () async {
      var host = FakeHost(
        dataTime: 100,
        syncedTime: 100,
        remote: WebDavRemoteArchive(backupWith(), 100),
      );
      expect(await WebDavAutoSync(host).pullIfNewer(), WebDavPullResult.same);
      expect(host.fetches, 1);
    });
  });

  group('退出时上传', () {
    test('别的设备传了更新的：不覆盖', () async {
      var host = FakeHost(
        dataTime: 300,
        syncedTime: 200,
        remote: WebDavRemoteArchive(backupWith(), 400),
      );
      expect(
        await WebDavAutoSync(host).pushIfNewer(),
        WebDavPushResult.remoteNewer,
      );
      expect(host.order, isEmpty);
      expect(host.syncedTime, 200);
    });

    test('本机的关注列表是空的、云端不是：不覆盖', () async {
      var host = FakeHost(
        dataTime: 300,
        syncedTime: 200,
        remote: WebDavRemoteArchive(backupWith(), 200),
      )..localFollowCount = 0;
      expect(
        await WebDavAutoSync(host).pushIfNewer(),
        WebDavPushResult.localEmpty,
      );
      expect(host.order, isEmpty);
    });

    test('没开关注同步的设备不做这个检查', () async {
      var host = FakeHost(
        dataTime: 300,
        syncedTime: 200,
        remote: WebDavRemoteArchive(backupWith(), 200),
      )
        ..localFollowCount = 0
        ..guardFollows = false;
      expect(
        await WebDavAutoSync(host).pushIfNewer(),
        WebDavPushResult.uploaded,
      );
    });

    test('上传失败：下次还会再传', () async {
      var host = FakeHost(dataTime: 300, syncedTime: 200)
        ..remoteError = 'offline';
      var sync = WebDavAutoSync(host);
      await expectLater(sync.pushIfNewer(), throwsA('offline'));
      expect(host.syncedTime, 200);
      host.remoteError = null;
      expect(await sync.pushIfNewer(), WebDavPushResult.uploaded);
    });
  });

  group('观看记录合并', () {
    // base 之前的时间是 100，之后是 300
    WebDavRecordMerge<(String, int)> merge(
      List<(String, int)> local,
      List<(String, int)> remote,
    ) =>
        mergeWebDavRecords<(String, int)>(
          local,
          remote,
          id: (e) => e.$1,
          time: (e) => DateTime.fromMillisecondsSinceEpoch(e.$2),
          base: 200,
        );

    test('两边都有：用新的', () {
      var older = merge([('a', 100)], [('a', 300)]);
      expect(older.put, [('a', 300)]);
      expect(older.localKept, isFalse);
      var newer = merge([('a', 300)], [('a', 100)]);
      expect(newer.put, isEmpty);
      expect(newer.localKept, isTrue);
      var same = merge([('a', 100)], [('a', 100)]);
      expect(same.put, isEmpty);
      expect(same.localKept, isFalse);
    });

    test('别的设备刚看的收下，本机刚看的留着', () {
      var merged = merge([('mine', 300)], [('theirs', 300)]);
      expect(merged.put, [('theirs', 300)]);
      expect(merged.delete, isEmpty);
      expect(merged.localKept, isTrue);
    });

    test('别的设备删掉的跟着删', () {
      var merged = merge([('gone', 100)], const []);
      expect(merged.delete, ['gone']);
      expect(merged.localKept, isFalse);
    });

    test('本机删掉的不再收回来，还要传上去', () {
      var merged = merge(const [], [('gone', 100)]);
      expect(merged.put, isEmpty);
      expect(merged.localKept, isTrue);
    });

    test('第一次同步（base 是 0）：两边的都留下', () {
      var merged = mergeWebDavRecords<(String, int)>(
        [('mine', 100)],
        [('theirs', 100)],
        id: (e) => e.$1,
        time: (e) => DateTime.fromMillisecondsSinceEpoch(e.$2),
        base: 0,
      );
      expect(merged.put, [('theirs', 100)]);
      expect(merged.delete, isEmpty);
    });
  });

  test('错误提示：连不上和服务器报错分开', () {
    var options = RequestOptions(path: '/');
    expect(
      WebDavSyncService.errorText(DioException(requestOptions: options)),
      '连不上 WebDAV',
    );
    expect(
      WebDavSyncService.errorText(
        DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 401),
        ),
      ),
      'WebDAV 出错（401）',
    );
  });

  test('观看记录的封面和标题：旧记录没有，新记录能存能读', () {
    var old = History.fromJson({
      'id': 'douyu_1',
      'roomId': '1',
      'siteId': 'douyu',
      'userName': 'a',
      'face': 'f',
      'updateTime': '2026-11-07 01:02:03.000',
    });
    expect(old.cover, isNull);
    expect(old.title, isNull);
    expect(old.toJson().containsKey('cover'), isFalse);
    old
      ..cover = 'c'
      ..title = 't';
    var again = History.fromJson(old.toJson());
    expect(again.cover, 'c');
    expect(again.title, 't');
  });

  test('时间戳：设备时钟慢时也比之前的大', () {
    expect(nextWebDavDataTime(100, 200), 200);
    expect(nextWebDavDataTime(300, 200), 301);
  });

  test('备份里的时间戳和关注数：旧版的备份没有时间戳', () {
    expect(backupWith(time: 123).dataTime, 123);
    expect(backupWith().dataTime, isNull);
    var backup = SyncBackupFormat({
      SyncBackupFormat.followsFile: {
        'data': [{}],
        'ext': [{}, {}],
        SyncBackupFormat.scriptsKey: [{}],
      },
    });
    expect(backup.followCount, 4);
  });

  group('自动同步的设置', () {
    Map<String, dynamic> merge(
      Map local,
      Map<String, dynamic> main,
      Map<String, dynamic>? ext, {
      bool syncSettings = false,
      bool syncAccounts = true,
      bool syncBilibili = true,
    }) =>
        SyncCompat.mergeAutoSettings(
          local,
          main,
          ext,
          syncSettings: syncSettings,
          syncAccounts: syncAccounts,
          syncBilibili: syncBilibili,
        );

    test('默认不动本机的设置，账号照常同步', () {
      var result = merge(
        {
          LocalStorageService.kDanmuSize: 20,
          LocalStorageService.kWebDAVUri: "local",
        },
        {
          LocalStorageService.kDanmuSize: 40,
          LocalStorageService.kWebDAVUri: "other",
        },
        {
          LocalStorageService.kTwitchToken: "remote",
        },
      );
      expect(result[LocalStorageService.kDanmuSize], 20);
      expect(result[LocalStorageService.kWebDAVUri], "local");
      expect(result[LocalStorageService.kTwitchToken], "remote");
    });

    test('打开同步设置后用云端的', () {
      var result = merge(
        {LocalStorageService.kDanmuSize: 20},
        {LocalStorageService.kDanmuSize: 40},
        {},
        syncSettings: true,
      );
      expect(result[LocalStorageService.kDanmuSize], 40);
    });

    test('别的设备没登录：这台不退出', () {
      for (var syncSettings in [false, true]) {
        var result = merge(
          {
            LocalStorageService.kTwitchToken: "mine",
            LocalStorageService.kBilibiliCookie: "bili",
            LocalStorageService.kDouyinCookie: "douyin",
          },
          {
            LocalStorageService.kBilibiliCookie: "",
            LocalStorageService.kDouyinCookie: "",
          },
          {},
          syncSettings: syncSettings,
        );
        expect(result[LocalStorageService.kTwitchToken], "mine");
        expect(result[LocalStorageService.kBilibiliCookie], "bili");
        expect(result[LocalStorageService.kDouyinCookie], "douyin");
      }
    });

    test('关掉账号同步：保留本机的账号，云端的不写进来', () {
      for (var syncSettings in [false, true]) {
        var result = merge(
          {LocalStorageService.kTwitchToken: "mine"},
          {LocalStorageService.kBilibiliCookie: "remote"},
          {
            LocalStorageService.kTwitchToken: "remote",
            LocalStorageService.kKickToken: "remote",
          },
          syncSettings: syncSettings,
          syncAccounts: false,
          syncBilibili: false,
        );
        expect(result[LocalStorageService.kTwitchToken], "mine");
        expect(result.containsKey(LocalStorageService.kKickToken), isFalse);
        expect(
          result.containsKey(LocalStorageService.kBilibiliCookie),
          isFalse,
        );
      }
    });

    test('本机专用的项不算存档变化，账号算', () {
      bool tracked(String key, {bool syncSettings = false}) =>
          SyncCompat.isAutoSyncedSetting(key, syncSettings: syncSettings);
      for (var key in [
        LocalStorageService.kWebDAVDataTime,
        LocalStorageService.kWebDAVSyncedTime,
        LocalStorageService.kWebDAVAutoSync,
        LocalStorageService.kWebDAVAutoSyncStatus,
        LocalStorageService.kWebDAVLastUploadTime,
        LocalStorageService.kLiveSourceLastCheck,
        "LiveSidePanelWidth",
      ]) {
        expect(tracked(key, syncSettings: true), isFalse, reason: key);
      }
      expect(tracked(LocalStorageService.kTwitchToken), isTrue);
      expect(tracked(LocalStorageService.kBilibiliCookie), isTrue);
      expect(tracked(LocalStorageService.kDanmuSize), isFalse);
      expect(
          tracked(LocalStorageService.kDanmuSize, syncSettings: true), isTrue);
    });

    test('自动同步的状态不进备份', () {
      var settings = {
        LocalStorageService.kWebDAVAutoSync: true,
        LocalStorageService.kWebDAVDataTime: 1,
        LocalStorageService.kWebDAVSyncedTime: 1,
        LocalStorageService.kWebDAVSyncOff: "follows",
        LocalStorageService.kWebDAVAutoSyncSettings: true,
        LocalStorageService.kWebDAVAutoSyncStatus: "x",
      };
      expect(SyncCompat.upstreamSettings(settings), isEmpty);
      expect(SyncCompat.extSettings(settings), isEmpty);
    });
  });

  group('WebDAV 读写', () {
    late HttpServer server;
    late Map<String, List<int>> files;
    late DAVClient client;

    setUp(() async {
      files = {};
      server = await fakeWebDav(files);
      client = DAVClient("http://127.0.0.1:${server.port}", "u", "p");
    });
    tearDown(() => server.close(force: true));

    test('刚建好的客户端马上读：不会和 ping 抢着认证而报 401', () async {
      for (var i = 0; i < 20; i++) {
        var fresh = DAVClient("http://127.0.0.1:${server.port}", "u", "p");
        expect(await fresh.readBackup(), isNull);
      }
      var data = Uint8List.fromList([1, 2, 3]);
      await DAVClient("http://127.0.0.1:${server.port}", "u", "p").backup(data);
      expect(
        await DAVClient("http://127.0.0.1:${server.port}", "u", "p")
            .backupVersion(),
        isNotNull,
      );
    });

    test('账号不对：报错，不是当作云端没有', () async {
      var wrong = DAVClient("http://127.0.0.1:${server.port}", "u", "wrong");
      await expectLater(wrong.readBackup(), throwsA(isA<DioException>()));
      await expectLater(wrong.backupVersion(), throwsA(isA<DioException>()));
    });

    test('文件版本：没有备份时为 null，内容变了就变', () async {
      expect(await client.backupVersion(), isNull);
      await client.backup(Uint8List.fromList([1, 2, 3]));
      var first = await client.backupVersion();
      expect(first, isNotNull);
      expect(await client.backupVersion(), first);
      await client.backup(Uint8List.fromList([1, 2, 3, 4]));
      expect(await client.backupVersion(), isNot(first));
    });

    test('每日存档：当天的覆盖，最多留 10 份，不碰 backup.zip', () async {
      var data = Uint8List.fromList([1, 2, 3]);
      await client.backup(data);
      for (var i = 1; i <= 12; i++) {
        await client.keepDailyCopy(data, DateTime(2026, 11, i));
      }
      await client.keepDailyCopy(
          Uint8List.fromList([9]), DateTime(2026, 11, 12));
      var names = files.keys
          .where((e) => e.contains('backup-'))
          .map((e) => e.split('/').last)
          .toList()
        ..sort();
      expect(names.length, 10);
      expect(names.first, 'backup-20261103.zip');
      expect(names.last, 'backup-20261112.zip');
      expect(files['/simple_live_app/backup-20261112.zip'], [9]);
      expect(files['/simple_live_app/backup.zip'], [1, 2, 3]);
      expect(await client.backupVersion(), endsWith('|3'));
    });

    test('云端没有备份时返回 null', () async {
      expect(await client.readBackup(), isNull);
      expect(await client.backupTime(), isNull);
    });

    test('传上去再读回来，带时间戳；旧版备份按文件修改时间', () async {
      var content = utf8.encode(jsonEncode({
        'data': <String, dynamic>{},
        SyncBackupFormat.dataTimeKey: 1234,
      }));
      var archive = Archive()
        ..addFile(ArchiveFile(
          SyncBackupFormat.settingsFile,
          content.length,
          content,
        ));
      await client.backup(Uint8List.fromList(ZipEncoder().encode(archive)));
      var data = await client.readBackup();
      expect(SyncBackupFormat(await SyncBackupFormat.decodeZip(data!)).dataTime,
          1234);
      var time = await client.backupTime();
      expect(time?.toUtc(), DateTime.utc(2026, 11, 7, 1, 2, 3));
    });
  });
}
