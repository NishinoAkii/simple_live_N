import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_compat.dart';

/// 不读本地存储的设置（各项从测试里的存储读）
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

const RoomContext roomA = RoomContext(
  id: "live:1",
  siteId: "bilibili",
  siteName: "哔哩哔哩",
  roomId: "100",
  roomLabel: "主播A",
);
const RoomContext roomB = RoomContext(
  id: "live:2",
  siteId: "bilibili",
  siteName: "哔哩哔哩",
  roomId: "200",
  roomLabel: "主播B",
);
const RoomContext douyu = RoomContext(
  id: "live:3",
  siteId: "douyu",
  siteName: "斗鱼直播",
  roomId: "100",
);

void main() {
  late Directory dir;
  late Box box;
  late Box<String> shieldBox;
  late _TestSettings settings;
  var roomKey = "${LocalStorageService.kRoomSettingsPrefix}room:bilibili_100";
  var siteKey = "${LocalStorageService.kRoomSettingsPrefix}site:bilibili";

  setUp(() async {
    Get.testMode = true;
    dir = Directory.systemTemp.createTempSync("room_specific_");
    Hive.init(dir.path);
    box = await Hive.openBox("settings");
    shieldBox = await Hive.openBox<String>("shield");
    await shieldBox.put("全局词", "全局词");
    Get.put(LocalStorageService()
      ..settingsBox = box
      ..shieldBox = shieldBox);
    // 全局：弹幕大小 16、速度 10，聊天文字 14，画面尺寸 0
    await box.put(LocalStorageService.kDanmuSize, 16.0);
    await box.put(LocalStorageService.kDanmuSpeed, 10.0);
    settings = Get.put<AppSettingsController>(_TestSettings()) as _TestSettings;
    settings.danmuSize.value = 16;
    settings.danmuSpeed.value = 10;
    settings.shieldList.assignAll(["全局词"]);
  });
  tearDown(() async {
    await box.close();
    await shieldBox.close();
    Get.reset();
    dir.deleteSync(recursive: true);
  });

  test('开关都关着：调的是全局', () {
    settings.enterRoomContext(roomA);
    expect(settings.specificRoomLabel.value, "主播A");
    expect(settings.specificSiteLabel.value, "哔哩哔哩");
    settings.setDanmuSize(20);
    settings.setChatTextSize(18);
    expect(box.get(LocalStorageService.kDanmuSize), 20);
    expect(box.get(LocalStorageService.kChatTextSize), 18);
  });

  test('打开“这个直播间单独设置”：弹幕、聊天区、画面尺寸、追帧都只记到这个直播间', () {
    settings.enterRoomContext(roomA);
    settings.setRoomSpecific(true);
    settings.setDanmuSize(24);
    settings.setChatTextSize(20);
    settings.setScaleMode(2);
    settings.setLiveCatchUp(true);
    expect(box.get(LocalStorageService.kDanmuSize), 16, reason: "全局不变");
    expect(box.containsKey(LocalStorageService.kChatTextSize), isFalse);
    var saved = json.decode(box.get(roomKey)) as Map;
    expect(saved["enabled"], isTrue);
    expect(saved[LocalStorageService.kChatTextSize], 20.0);
    expect(saved[LocalStorageService.kPlayerScaleMode], 2);
    expect(saved[LocalStorageService.kLiveCatchUp], isTrue);

    // 同平台的别的直播间不受影响
    settings.leaveRoomContext(roomA.id);
    settings.enterRoomContext(roomB);
    expect(settings.danmuSize.value, 16);
    expect(settings.chatTextSize.value, 14);
    expect(settings.scaleMode.value, 0);
    expect(settings.liveCatchUp.value, isFalse);

    settings.leaveRoomContext(roomB.id);
    expect(settings.danmuSize.value, 16);
    expect(settings.specificRoomLabel.value, "");
  });

  test('关键词屏蔽：第一次改时从当前生效的复制一份，全局的不变', () {
    settings.enterRoomContext(roomA);
    settings.setRoomSpecific(true);
    settings.addShieldList("直播间词");
    expect(settings.shieldList, {"全局词", "直播间词"});
    expect(shieldBox.values.toSet(), {"全局词"});
    settings.leaveRoomContext(roomA.id);
    expect(settings.shieldList, {"全局词"});
    settings.enterRoomContext(roomA);
    expect(settings.shieldList, {"全局词", "直播间词"});
    settings.removeShieldList("全局词");
    expect(settings.shieldList, {"直播间词"});
    expect(shieldBox.values.toSet(), {"全局词"});
  });

  test('平台单独设置：同平台都用它，直播间的优先，没调过的项依次沿用', () {
    settings.enterRoomContext(roomA);
    settings.setSiteSpecific(true);
    settings.setDanmuSize(20);
    settings.setDanmuSpeed(6);
    settings.leaveRoomContext(roomA.id);
    settings.enterRoomContext(roomB);
    expect(settings.danmuSize.value, 20);
    settings.setRoomSpecific(true);
    settings.setDanmuSize(30);
    expect(settings.danmuSize.value, 30);
    expect(settings.danmuSpeed.value, 6);
    expect(json.decode(box.get(siteKey))[LocalStorageService.kDanmuSize], 20);
    settings.leaveRoomContext(roomB.id);
    settings.enterRoomContext(douyu);
    expect(settings.danmuSize.value, 16);
    expect(settings.danmuSpeed.value, 10);
  });

  test('定时关闭：单独设置里记住，全局不记', () {
    settings.enterRoomContext(roomA);
    settings.setRoomAutoExitEnable(true);
    expect(box.containsKey(LocalStorageService.kRoomAutoExitEnable), isFalse);
    settings.setRoomSpecific(true);
    settings.setRoomAutoExitEnable(true);
    settings.setRoomAutoExitDuration(30);
    settings.leaveRoomContext(roomA.id);
    expect(settings.roomAutoExitEnable.value, isFalse);
    settings.enterRoomContext(roomA);
    expect(settings.roomAutoExitEnable.value, isTrue);
    expect(settings.roomAutoExitDuration.value, 30);
  });

  test('关掉开关保留记下的值，再打开就回来；清除才删掉', () {
    settings.enterRoomContext(roomA);
    settings.setRoomSpecific(true);
    settings.setDanmuSize(24);
    settings.setRoomSpecific(false);
    expect(settings.danmuSize.value, 16);
    settings.setRoomSpecific(true);
    expect(settings.danmuSize.value, 24);
    expect(settings.roomSpecificHasValues.value, isTrue);
    settings.clearRoomSpecific();
    expect(box.containsKey(roomKey), isFalse);
    expect(settings.roomSpecific.value, isFalse);
    expect(settings.danmuSize.value, 16);
  });

  test('设置页（全局）打开时调的是全局，关掉后回到直播间的', () {
    settings.enterRoomContext(roomA);
    settings.setRoomSpecific(true);
    settings.setDanmuSize(24);
    settings.enterRoomContext(const RoomContext.global("settings:danmu"));
    expect(settings.danmuSize.value, 16);
    expect(settings.specificRoomLabel.value, "", reason: "设置页里不显示开关");
    settings.setDanmuSize(18);
    expect(box.get(LocalStorageService.kDanmuSize), 18);
    settings.leaveRoomContext("settings:danmu");
    expect(settings.danmuSize.value, 24);
  });

  test('单独设置只进备份的扩展部分（官方版不读）', () {
    expect(SyncCompat.isExtSetting(roomKey), isTrue);
    expect(SyncCompat.isExtSetting(siteKey), isTrue);
  });
}
