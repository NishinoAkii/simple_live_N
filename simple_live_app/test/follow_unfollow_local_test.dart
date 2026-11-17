import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_controller.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 不读本地存储的设置
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// 记下查了哪些直播间的开播状态
class _FakeLiveSite extends LiveSite {
  final live = <String, bool>{};
  final calls = <String>[];

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    calls.add(roomId);
    return live[roomId] ?? false;
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    calls.add("detail:$roomId");
    return LiveRoomDetail(
      roomId: roomId,
      title: "",
      cover: "",
      userName: "主播$roomId",
      userAvatar: "",
      online: 0,
      status: live[roomId] ?? false,
      url: "",
    );
  }
}

FollowUser follow(String roomId) => FollowUser(
      id: "twitch_$roomId",
      roomId: roomId,
      siteId: "twitch",
      userName: "主播$roomId",
      face: "",
      addTime: DateTime(2026, 11, 14),
    );

/// 关注页取消关注：只在本地拿掉，不重新查开播状态
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _FakeLiveSite fake;
  late LiveSite original;
  late FollowService service;

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() async {
    Get.testMode = true;
    dir = Directory.systemTemp.createTempSync("follow_unfollow_");
    Hive.init(dir.path);
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(FollowUserAdapter());
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(FollowUserTagAdapter());
    }
    var db = DBService()
      ..followBox = await Hive.openBox<FollowUser>("FollowUser")
      ..tagBox = await Hive.openBox<FollowUserTag>("FollowUserTag");
    Get.put(db);
    var settings = Get.put<AppSettingsController>(_TestSettings());
    settings.autoUpdateFollowEnable.value = false;
    settings.updateFollowThreadCount.value = 2;
    fake = _FakeLiveSite();
    original = Sites.allSites["twitch"]!.liveSite;
    Sites.allSites["twitch"]!.liveSite = fake;
    service = Get.put(FollowService());
  });

  tearDown(() async {
    Sites.allSites["twitch"]!.liveSite = original;
    Get.reset();
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  /// a 在播，b、c 没播，b 在分组“朋友”里；状态都查过一遍
  Future<(FollowUserController, FollowUserTag)> prepare() async {
    fake.live["a"] = true;
    var b = follow("b")..tag = "朋友";
    for (var item in [follow("a"), b, follow("c")]) {
      await DBService.instance.addFollow(item);
    }
    var tag = await DBService.instance.addFollowTag("朋友");
    tag.userId.add(b.id);
    await DBService.instance.updateFollowTag(tag);
    await service.loadData();
    await settle();
    expect(service.liveList.map((e) => e.roomId), ["a"]);
    fake.calls.clear();
    var controller = Get.put(FollowUserController());
    controller.updateTagList();
    controller.filterData();
    return (controller, tag);
  }

  test('取消关注：只拿掉这一个，不发请求，其他人的开播状态不变', () async {
    var (controller, tag) = await prepare();
    var b = service.followList.firstWhere((e) => e.roomId == "b");
    await controller.removeConfirmed(b);
    await settle();

    expect(fake.calls, isEmpty);
    expect(service.updating.value, isFalse);
    expect(service.followList.map((e) => e.roomId), ["a", "c"]);
    expect(service.liveList.map((e) => e.roomId), ["a"]);
    expect(service.notLiveList.map((e) => e.roomId), ["c"]);
    expect(
      service.followList.firstWhere((e) => e.roomId == "a").liveStatus.value,
      2,
    );
    expect(controller.list.map((e) => e.roomId), ["a", "c"]);
    expect(DBService.instance.getFollowExist("twitch_b"), isFalse);
    // 分组里的也删掉了（原来的清理照旧）
    expect(DBService.instance.tagBox.get(tag.id)!.userId, isNot(contains("twitch_b")));
    expect(service.followTagList.single.userId, isEmpty);
  });

  test('正在看某个分组时取消关注：分组列表跟着变', () async {
    var (controller, _) = await prepare();
    controller.setFilterMode(controller.tagList.firstWhere((e) => e.tag == "朋友"));
    expect(controller.list.map((e) => e.roomId), ["b"]);
    await controller.removeConfirmed(controller.list.single);
    await settle();
    expect(controller.list, isEmpty);
    expect(fake.calls, isEmpty);
  });
}
