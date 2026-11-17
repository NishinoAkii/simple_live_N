import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:image/image.dart' as img;
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/remote_sync_webdav_page.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/live_notify_service.dart';
import 'package:simple_live_app/widgets/follow_actions_sheet.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/shown_in_tab.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 不读本地存储的设置
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// 按直播间返回开没开播；[gate] 不为空时先等它（模拟一轮查到一半）
class _FakeLiveSite extends LiveSite {
  final live = <String, bool>{};
  final calls = <String>[];
  Completer<void>? gate;

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    calls.add(roomId);
    var wait = gate;
    if (wait != null) await wait.future;
    return live[roomId] ?? false;
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    return LiveRoomDetail(
      roomId: roomId,
      title: "标题 $roomId",
      cover: "",
      userName: "主播$roomId",
      userAvatar: "",
      online: 0,
      status: live[roomId] ?? false,
      url: "",
      showTime: "1794640857",
    );
  }
}

/// 旧版的 FollowUser 读法（原样照抄）：用来确认装回旧版时读得了新版写的数据
class _FollowUserAdapter120 extends TypeAdapter<FollowUser> {
  @override
  final int typeId = 1;

  @override
  FollowUser read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return FollowUser(
      id: fields[0] as String,
      roomId: fields[1] as String,
      siteId: fields[2] as String,
      userName: fields[3] as String,
      face: fields[4] as String,
      addTime: fields[5] as DateTime,
      tag: fields[6] ?? "全部",
    );
  }

  @override
  void write(BinaryWriter writer, FollowUser obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.roomId)
      ..writeByte(2)
      ..write(obj.siteId)
      ..writeByte(3)
      ..write(obj.userName)
      ..writeByte(4)
      ..write(obj.face)
      ..writeByte(5)
      ..write(obj.addTime)
      ..writeByte(6)
      ..write(obj.tag);
  }
}

FollowUser follow(String roomId, {bool notify = false}) => FollowUser(
      id: "twitch_$roomId",
      roomId: roomId,
      siteId: "twitch",
      userName: "主播$roomId",
      face: "",
      addTime: DateTime(2026, 11, 14),
      notify: notify,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FollowUser 的开播提醒标记', () {
    test('JSON：订阅了才写，读回来一样；旧备份没有这个字段时是没订阅', () {
      var json = follow("a", notify: true).toJson();
      expect(json["notify"], isTrue);
      expect(FollowUser.fromJson(json).notify, isTrue);
      var plain = follow("b").toJson();
      expect(plain.containsKey("notify"), isFalse);
      expect(FollowUser.fromJson(plain).notify, isFalse);
    });
  });

  group('关注状态和开播提醒', () {
    late Directory dir;
    late _FakeLiveSite fake;
    late LiveSite original;
    late FollowService service;
    late LiveNotifyService notify;
    late List<LiveNotifyMessage> sent;

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    setUp(() async {
      Get.testMode = true;
      dir = Directory.systemTemp.createTempSync("follow_status_");
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
      settings.liveNotifyEnable.value = true;
      fake = _FakeLiveSite();
      original = Sites.allSites["twitch"]!.liveSite;
      Sites.allSites["twitch"]!.liveSite = fake;
      service = Get.put(FollowService());
      sent = [];
      notify = LiveNotifyService()
        ..timers = false
        ..sendOverride = (m) async => sent.add(m);
      Get.put(notify);
    });

    tearDown(() async {
      Sites.allSites["twitch"]!.liveSite = original;
      Get.reset();
      await Hive.close();
      dir.deleteSync(recursive: true);
    });

    test('拉取 WebDAV 后列表换成新对象：查到一半的那一轮换成新列表重查，状态不丢', () async {
      fake.live["a"] = true;
      await DBService.instance.addFollow(follow("a"));
      await DBService.instance.addFollow(follow("b"));
      fake.gate = Completer<void>();
      await service.loadData();
      await settle();
      expect(service.updating.value, isTrue);

      // 同步：数据库清空后放进新的对象（id 一样）
      await DBService.instance.followBox.clear();
      await DBService.instance.addFollow(follow("a"));
      await DBService.instance.addFollow(follow("b"));
      await service.loadData(updateStatus: false);
      fake.gate!.complete();
      fake.gate = null;
      await settle();

      expect(service.updating.value, isFalse);
      var a = service.followList.firstWhere((e) => e.roomId == "a");
      expect(identical(a, DBService.instance.followBox.get("twitch_a")), isTrue);
      expect(a.liveStatus.value, 2);
      expect(a.liveStartTime, "1794640857");
      expect(service.liveList.map((e) => e.roomId), ["a"]);
      expect(service.notLiveList.map((e) => e.roomId), ["b"]);
    });

    test('查完以后再同步：已经知道的状态接着用，只补查新加进来的', () async {
      fake.live["a"] = true;
      await DBService.instance.addFollow(follow("a"));
      await service.loadData();
      await settle();
      expect(service.liveList.length, 1);
      fake.calls.clear();

      await DBService.instance.followBox.clear();
      await DBService.instance.addFollow(follow("a"));
      await DBService.instance.addFollow(follow("c"));
      await service.loadData(updateStatus: false);
      await settle();
      expect(fake.calls, ["c"]);
      expect(service.followList.firstWhere((e) => e.roomId == "a").liveStatus.value, 2);
      expect(service.followList.firstWhere((e) => e.roomId == "c").liveStatus.value, 1);
    });

    test('一次都没查过时，同步来的列表不发请求（和原来一样）', () async {
      await DBService.instance.addFollow(follow("a"));
      await service.loadData(updateStatus: false);
      await settle();
      expect(fake.calls, isEmpty);
    });

    test('切到关注列表：刷新一次；正在查、刚查完都不再查', () async {
      await DBService.instance.addFollow(follow("a"));
      fake.gate = Completer<void>();
      service.refreshOnShow();
      await settle();
      expect(fake.calls, ["a"]);
      service.refreshOnShow();
      await settle();
      expect(fake.calls, ["a"]);
      fake.gate!.complete();
      fake.gate = null;
      await settle();
      expect(service.updating.value, isFalse);
      service.refreshOnShow();
      await settle();
      expect(fake.calls, ["a"]);
    });

    Future<FollowUserTag> group(String name, List<FollowUser> members) async {
      var tag = await DBService.instance.addFollowTag(name);
      tag.userId.addAll(members.map((e) => e.id));
      await DBService.instance.updateFollowTag(tag);
      for (var item in members) {
        item.tag = name;
        await DBService.instance.addFollow(item);
      }
      return tag;
    }

    test('直播间里切到关注：按设置查全部、一个分组、当前主播的分组或者不查', () async {
      var a = follow("a"), b = follow("b"), c = follow("c");
      for (var item in [a, b, c]) {
        await DBService.instance.addFollow(item);
      }
      var lol = await group("LOL", [a, b]);
      var settings = AppSettingsController.instance;

      settings.liveRoomFollowCheck.value = "none";
      expect(await service.refreshForLiveRoom(siteId: "twitch", roomId: "a"), 0);
      await settle();
      expect(fake.calls, isEmpty);

      settings.liveRoomFollowCheck.value = "tag:${lol.id}";
      expect(await service.refreshForLiveRoom(siteId: "twitch", roomId: "c"), 2);
      await settle();
      expect(fake.calls.toSet(), {"a", "b"});
    });

    test('当前主播的分组：正在看的在哪个分组查哪个；没分组时不查', () async {
      var a = follow("a"), b = follow("b"), c = follow("c");
      for (var item in [a, b, c]) {
        await DBService.instance.addFollow(item);
      }
      await group("LOL", [a, b]);
      AppSettingsController.instance.liveRoomFollowCheck.value = "current";
      expect(await service.refreshForLiveRoom(siteId: "twitch", roomId: "c"), 0);
      await settle();
      expect(fake.calls, isEmpty);
      expect(await service.refreshForLiveRoom(siteId: "twitch", roomId: "b"), 2);
      await settle();
      expect(fake.calls.toSet(), {"a", "b"});
    });

    test('选的分组删掉了：查全部；刚查完 15 秒内再切过去不查', () async {
      for (var id in ["a", "b", "c"]) {
        await DBService.instance.addFollow(follow(id));
      }
      AppSettingsController.instance.liveRoomFollowCheck.value = "tag:gone";
      expect(await service.refreshForLiveRoom(siteId: "twitch", roomId: "a"), 3);
      await settle();
      expect(fake.calls.toSet(), {"a", "b", "c"});
      fake.calls.clear();
      expect(await service.refreshForLiveRoom(siteId: "twitch", roomId: "a"), 0);
      await settle();
      expect(fake.calls, isEmpty);
    });

    test('订阅的直播间从没播变成开播：发一条通知；第一次查到在播不提醒', () async {
      await DBService.instance.addFollow(follow("a", notify: true));
      await DBService.instance.addFollow(follow("b", notify: true));
      await DBService.instance.addFollow(follow("c"));
      fake.live["b"] = true;
      await notify.checkSubscribed();
      expect(sent, isEmpty);
      // 只查订阅了的
      expect(fake.calls.toSet(), {"a", "b"});

      fake.live["a"] = true;
      fake.live["c"] = true;
      await notify.checkSubscribed();
      expect(sent.map((e) => e.roomId), ["a"]);
      expect(sent.single.name, "主播a");
      expect(sent.single.title, "标题 a");
      expect(sent.single.payload, "twitch\na");
      // 列表里的状态也跟着变
      expect(service.liveList.map((e) => e.roomId).toSet(), {"a", "b"});

      // 一直在播：不再提醒
      await notify.checkSubscribed();
      expect(sent.length, 1);
    });

    test('整个列表刷新时也会提醒；没订阅、关掉提醒时不提醒', () async {
      await DBService.instance.addFollow(follow("a", notify: true));
      await DBService.instance.addFollow(follow("c"));
      await service.loadData();
      await settle();
      fake.live["a"] = true;
      fake.live["c"] = true;
      AppSettingsController.instance.liveNotifyEnable.value = false;
      await service.loadData();
      await settle();
      expect(sent, isEmpty);

      fake.live["a"] = false;
      await service.loadData();
      await settle();
      AppSettingsController.instance.liveNotifyEnable.value = true;
      fake.live["a"] = true;
      await service.loadData();
      await settle();
      expect(sent.map((e) => e.roomId), ["a"]);
    });

    test('点铃铛：存进数据库；刚订阅时已经在播的不提醒，下次开播才提醒', () async {
      fake.live["a"] = true;
      await DBService.instance.addFollow(follow("a"));
      await service.loadData();
      await settle();
      var item = service.followList.single;
      await service.setNotify(item, true);
      expect(DBService.instance.followBox.get("twitch_a")!.notify, isTrue);
      await notify.checkSubscribed();
      expect(sent, isEmpty);
      fake.live["a"] = false;
      await notify.checkSubscribed();
      fake.live["a"] = true;
      await notify.checkSubscribed();
      expect(sent.length, 1);
    });

    test('装回旧版：旧版读得了新版写的关注（开播提醒那一项被忽略）', () async {
      await DBService.instance.addFollow(follow("a", notify: true));
      await Hive.close();
      Hive.registerAdapter(_FollowUserAdapter120(), override: true);
      try {
        var box = await Hive.openBox<FollowUser>("FollowUser");
        var item = box.get("twitch_a")!;
        expect(item.roomId, "a");
        expect(item.userName, "主播a");
        expect(item.notify, isFalse);
      } finally {
        await Hive.close();
        Hive.registerAdapter(FollowUserAdapter(), override: true);
      }
    });

    test('Hive 里存的订阅关掉再打开还在', () async {
      await DBService.instance.addFollow(follow("a", notify: true));
      await Hive.close();
      var box = await Hive.openBox<FollowUser>("FollowUser");
      expect(box.get("twitch_a")!.notify, isTrue);
    });
  });

  group('开播通知的细节', () {
    test('房间信息读不到时用关注列表里的名字和头像', () {
      var item = follow("a")..face = "https://example.com/a.jpg";
      var message = LiveNotifyMessage.of(item, null);
      expect(message.name, "主播a");
      expect(message.avatar, "https://example.com/a.jpg");
      expect(message.title, "");
      expect(message.id, LiveNotifyMessage.of(item, null).id);
    });

    test('头像转成 192×192 的 PNG；不是图片时不带头像', () {
      var source = img.Image(width: 300, height: 200);
      var png = LiveNotifyService.avatarPng(img.encodeJpg(source));
      var decoded = img.decodePng(png!)!;
      expect(decoded.width, 192);
      expect(decoded.height, 192);
      expect(LiveNotifyService.avatarPng(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('Windows 通知：标题两行、正文三行可以折行，特殊字符转义，带圆形头像和直播间', () {
      var xml = LiveNotifyService.windowsToastXml(
        title: "A&B <主播> 开播了",
        body: "很长很长的\"直播间\"标题'",
        payload: "huya\n518518",
        name: "A&B",
        avatar: r"C:\Temp\live_notify\1.png",
      );
      expect(xml, contains('<text hint-maxLines="2">A&amp;B &lt;主播&gt; 开播了</text>'));
      expect(xml, contains('<text hint-maxLines="3">很长很长的&quot;直播间&quot;标题&apos;</text>'));
      expect(xml, contains('launch="huya&#xA;518518"'));
      expect(xml, contains('placement="appLogoOverride" hint-crop="circle"'));
      expect(xml, contains('src="file:///C:/Temp/live_notify/1.png"'));
      expect(
        LiveNotifyService.windowsToastXml(
            title: "t", body: "b", payload: "p", name: "n"),
        isNot(contains("<image")),
      );
    });

    test('Windows 的应用标识：测试版和正式版分开', () {
      expect(LiveNotifyService.windowsAppId("simple_live_N"),
          "com.xycz.simple_live_N");
      expect(LiveNotifyService.windowsAppId("simple_live_app_r16test"),
          "com.xycz.simple_live_app_r16test");
      expect(LiveNotifyService.windowsGuid("simple_live_N"),
          isNot(LiveNotifyService.windowsGuid("simple_live_app_r16test")));
    });
  });

  group('界面', () {
    testWidgets('切到关注页时调用一次，停在那里不重复', (tester) async {
      var shown = 0;
      await tester.pumpWidget(MaterialApp(
        home: DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              bottom: const TabBar(
                tabs: [Tab(text: "聊天"), Tab(text: "关注"), Tab(text: "设置")],
              ),
            ),
            body: TabBarView(children: [
              const Text("聊天页"),
              ShownInTab(
                index: 1,
                onShown: () => shown++,
                child: const Text("关注页"),
              ),
              const Text("设置页"),
            ]),
          ),
        ),
      ));
      expect(shown, 0);
      await tester.tap(find.text("关注"));
      await tester.pumpAndSettle();
      expect(shown, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(shown, 1);
      await tester.tap(find.text("设置"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("关注"));
      await tester.pumpAndSettle();
      expect(shown, 2);
      await tester.tap(find.text("聊天"));
      await tester.pumpAndSettle();
      expect(shown, 2);
    });

    testWidgets('同步选项放不下时能滚到最后一项，滚动条一直显示', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: SyncOptionsScroll(children: [
              for (var i = 0; i < 9; i++)
                SizedBox(height: 80, child: Text("选项 $i")),
            ]),
          ),
        ),
      ));
      var scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
      expect(scrollbar.thumbVisibility, isTrue);
      expect(find.text("选项 8").hitTestable(), findsNothing);
      await tester.drag(find.text("选项 1"), const Offset(0, -800));
      await tester.pumpAndSettle();
      expect(find.text("选项 8").hitTestable(), findsOneWidget);
    });

    testWidgets('铃铛：打开“所有关注都显示铃铛”时每行都有，关掉时只有开了提醒的有', (tester) async {
      Get.testMode = true;
      var settings = Get.put<AppSettingsController>(_TestSettings());
      addTearDown(Get.reset);
      settings.liveNotifyShowBell.value = true;
      var item = follow("a");
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FollowUserItem(
            item: item,
            onToggleNotify: () {
              taps++;
              item.notify = !item.notify;
            },
            onRemove: () {},
          ),
        ),
      ));
      expect(find.byIcon(Icons.notifications_none), findsOneWidget);
      await tester.tap(find.byIcon(Icons.notifications_none));
      await tester.pump();
      expect(taps, 1);
      expect(find.byIcon(Icons.notifications_active), findsOneWidget);
      expect(find.byTooltip("开播提醒已开启，点击关闭"), findsOneWidget);

      // 关掉显示：开了提醒的还在，没开的消失
      settings.liveNotifyShowBell.value = false;
      await tester.pump();
      expect(find.byIcon(Icons.notifications_active), findsOneWidget);
      item.notify = false;
      await tester.pump();
      expect(find.byIcon(Icons.notifications_none), findsNothing);
      expect(find.byIcon(Icons.notifications_active), findsNothing);
      // 取消关注的按钮不受影响
      expect(find.byType(IconButton), findsOneWidget);
    });

    testWidgets('长按弹出的卡片：主播名、平台和状态，开播提醒、设置标签、取消关注', (tester) async {
      var item = follow("a")..liveStatus.value = 2;
      var unfollowed = 0;
      var tagged = 0;
      await tester.pumpWidget(GetMaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showFollowActions(
                item,
                onUnfollow: () => unfollowed++,
                onSetTag: () => tagged++,
              ),
              child: const Text("open"),
            ),
          ),
        ),
      ));
      await tester.tap(find.text("open"));
      await tester.pumpAndSettle();
      expect(find.text("主播a"), findsOneWidget);
      expect(find.text("${Sites.allSites["twitch"]!.name} · 直播中"), findsOneWidget);
      expect(find.text("开启开播提醒"), findsOneWidget);
      expect(find.text("设置标签"), findsOneWidget);
      await tester.tap(find.text("取消关注"));
      await tester.pumpAndSettle();
      expect(unfollowed, 1);
      expect(find.text("开启开播提醒"), findsNothing);

      // 已经开了提醒：显示“关闭开播提醒”；没传设置标签时没有这一项
      item.notify = true;
      await tester.pumpWidget(GetMaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showFollowActions(item, onUnfollow: () {}),
              child: const Text("open2"),
            ),
          ),
        ),
      ));
      await tester.tap(find.text("open2"));
      await tester.pumpAndSettle();
      expect(find.text("关闭开播提醒"), findsOneWidget);
      expect(find.text("设置标签"), findsNothing);
      expect(tagged, 0);
    });
  });
}
