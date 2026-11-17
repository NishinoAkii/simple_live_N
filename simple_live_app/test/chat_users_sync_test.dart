import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/models/sync_client_info_model.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/chat_users/chat_user.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/chat_users/user_block_store.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_backup_format.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_app/services/sync_service.dart';
import 'package:simple_live_app/services/webdav_archive.dart';

// 屏蔽的人和备注跟着 WebDAV 同步（blocked_word 文件的 ext），
// 官方版和旧版照常读 data；备份里的关键词是全局的那一份

const room = RoomContext(
  id: "live:1",
  siteId: "douyu",
  siteName: "斗鱼",
  roomId: "100",
  roomLabel: "主播",
);

void main() {
  late Directory temp;
  late ChatUsersService users;
  late AppSettingsController settings;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    temp = await Directory.systemTemp.createTemp('chat_users_sync');
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
    await Get.put(LocalStorageService()).init();
    await Get.put(DBService()).init();
    users = Get.put(
      ChatUsersService(storage: MemoryChatUsersStorage(), purgeInterval: null),
    );
    await users.init();
    settings = Get.put(AppSettingsController());
    Get.put(BiliBiliAccountService());
  });

  tearDown(() async {
    users.onClose();
    Get.reset();
    await Hive.close();
    await temp.delete(recursive: true);
  });

  SyncBackupFormat backup() =>
      SyncBackupFormat(SyncBackupFormat.decodeZipSync(WebDavArchive.build(1)));

  void addPeople() {
    users.blocks.add(UserBlock(siteId: "douyu", userId: "1", name: "永久的"));
    users.blocks.add(
      UserBlock(
        siteId: "douyu",
        userId: "2",
        name: "定时的",
        expireAt:
            DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      ),
    );
    users.remarks.set(const ChatUser("douyu", userId: "1", name: "永久的"), "备注一");
  }

  test("备份：关键词是全局的（开着直播间单独设置也一样）", () async {
    settings.addShieldList("全局词");
    settings.enterRoomContext(room);
    settings.setRoomSpecific(true);
    settings.addShieldList("房间词");
    expect(settings.shieldList, containsAll(["全局词", "房间词"]));
    var words = backup().mainList(SyncBackupFormat.blockedWordFile);
    expect(words, ["全局词"]);
    settings.leaveRoomContext(room.id);
  });

  test("备份：永久屏蔽和备注在 ext 里，定时的不进；旧版只读 data 不受影响", () {
    settings.addShieldList("词");
    addPeople();
    var b = backup();
    // 官方版和旧版：data 还是关键词列表
    expect(b.mainList(SyncBackupFormat.blockedWordFile), ["词"]);
    var people = b.extMap(SyncBackupFormat.blockedWordFile, 'chatUsers')!;
    expect((people["blocks"] as List).map((e) => e["n"]), ["永久的"]);
    expect((people["remarks"] as List).single["r"], "备注一");
  });

  test("手动恢复：合并；自动同步：以云端为准，本机的定时屏蔽留着", () async {
    addPeople();
    // 只看屏蔽词这个文件（设置文件的恢复要用到各平台账号服务，这里不测）
    var b = SyncBackupFormat({
      SyncBackupFormat.blockedWordFile:
          backup().files[SyncBackupFormat.blockedWordFile],
    });
    // 换一台设备：本机有别的永久屏蔽和定时屏蔽
    users.blocks.clear();
    users.remarks.set(const ChatUser("douyu", userId: "1", name: "永久的"), "");
    users.blocks.add(UserBlock(siteId: "huya", userId: "9", name: "本机永久"));
    users.blocks.add(
      UserBlock(
        siteId: "huya",
        userId: "8",
        name: "本机定时",
        expireAt:
            DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      ),
    );
    await WebDavArchive.restore(b);
    expect(
      users.blocks.items.map((e) => e.name).toSet(),
      {"本机永久", "本机定时", "永久的"},
    );
    expect(
        users.remarkOf(const ChatUser("douyu", userId: "1", name: "x")), "备注一");
    await WebDavArchive.restore(b, auto: true);
    expect(users.blocks.items.map((e) => e.name).toSet(), {"本机定时", "永久的"});
  });

  test("旧版或官方版的备份（没有 ext）：本机的屏蔽和备注不动", () async {
    addPeople();
    var old = SyncBackupFormat({
      SyncBackupFormat.blockedWordFile: {
        "data": ["旧词"],
      },
    });
    await WebDavArchive.restore(old, auto: true);
    expect(users.blocks.items, hasLength(2));
    expect(users.remarks.items, hasLength(1));
    expect(settings.globalShieldList, ["旧词"]);
  });

  test("恢复的关键词进全局的那一份（开着直播间单独设置也一样）", () async {
    settings.addShieldList("全局词");
    settings.enterRoomContext(room);
    settings.setRoomSpecific(true);
    settings.addShieldList("房间词");
    var b = SyncBackupFormat({
      SyncBackupFormat.blockedWordFile: {
        "data": ["云端词"],
      },
    });
    await WebDavArchive.restore(b, auto: true);
    expect(settings.globalShieldList, ["云端词"]);
    // 这个直播间自己的那一份不动
    expect(settings.shieldList, containsAll(["全局词", "房间词"]));
    settings.leaveRoomContext(room.id);
    expect(settings.shieldList.toList(), ["云端词"]);
  });

  test("“SC 和礼物也不显示”跟着设置走扩展部分（官方版不收）", () {
    expect(SyncCompat.isExtSetting(ChatUsersService.kHidePaid), isTrue);
  });

  test("局域网：对方声明了 chat_users 才发", () {
    var info = SyncClientInfoModel.fromJson({
      "type": "windows",
      "name": "pc",
      "version": "1.24.0",
      "address": "1.2.3.4",
      "port": 23234,
      "features": [kSyncFeatureLiveSources, kSyncFeatureChatUsers],
    });
    expect(info.features, contains(kSyncFeatureChatUsers));
    var old = SyncClientInfoModel.fromJson({
      "type": "windows",
      "name": "pc",
      "version": "1.11.7",
      "address": "1.2.3.4",
      "port": 23234,
      "features": [kSyncFeatureLiveSources],
    });
    expect(old.features, isNot(contains(kSyncFeatureChatUsers)));
  });
}
