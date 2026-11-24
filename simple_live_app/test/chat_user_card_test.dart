import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/user_card/chat_user_card.dart';
import 'package:simple_live_app/modules/live_room/user_card/live_user_card.dart';
import 'package:simple_live_app/modules/live_room/user_card/user_block_list.dart';
import 'package:simple_live_app/services/chat_users/chat_user.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/chat_users/room_user_blocks.dart';
import 'package:simple_live_app/services/chat_users/user_block_store.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'fakes/fake_player.dart';

// 用户卡片的三级菜单、备注、本直播间名单（点一点）；粉丝牌是哪个主播的

/// 不读 Hive 的设置
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// 直播间：不连播放器、不读房间信息，只记下要打开哪个直播间
class _Room extends LiveRoomController {
  _Room(String siteId, LiveSite liveSite, {String roomId = "100"})
      : super(
          pSite: Site(id: siteId, liveSite: liveSite, logo: "", name: "测试"),
          pRoomId: roomId,
        );

  final opened = <(Site, String)>[];

  /// 换直播间时卡片还开着
  bool? cardOpen;

  @override
  // ignore: overridden_fields
  final Player player = FakePlayer();

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  // ignore: must_call_super
  void onClose() {}

  @override
  void resetRoom(Site site, String roomId) {
    opened.add((site, roomId));
    cardOpen = Get.key.currentState!.canPop();
  }

  /// 读到的直播间信息
  void loaded(String roomId, dynamic danmakuData) =>
      detail.value = LiveRoomDetail(
        roomId: roomId,
        title: "标题",
        cover: "",
        userName: "主播甲",
        userAvatar: "",
        online: 0,
        status: true,
        url: "",
        danmakuData: danmakuData,
      );
}

/// 斗鱼：查主播名不访问网络，记下查了哪些房间
class _FakeDouyu extends DouyuSite {
  final asked = <String>[];
  Future<String?> Function() reply = () async => "主播乙";

  @override
  Future<String?> getRoomOwnerName({required String roomId}) {
    asked.add(roomId);
    return reply();
  }
}

_Room _biliRoom({String roomId = "30000001", int anchorUid = 20000001}) =>
    _Room(Constant.kBiliBili, BiliBiliSite(), roomId: roomId)
      ..loaded(
        "30000001",
        BiliBiliDanmakuArgs(
          roomId: 30000001,
          token: "",
          serverHost: "",
          buvid: "",
          uid: 0,
          cookie: "",
          anchorUid: anchorUid,
        ),
      );

_Room _huyaRoom() => _Room(Constant.kHuya, HuyaSite())
  ..loaded(
    "100",
    HuyaDanmakuArgs(ayyuid: 1, topSid: 2, subSid: 3, presenterUid: 294636272),
  );

LiveBadge _medal({
  String? name,
  String? room,
  String? uid,
  int? level = 30,
}) =>
    LiveBadge(
      LiveBadgeKind.medal,
      "甜心",
      level: level,
      ownerName: name,
      ownerRoomId: room,
      ownerUid: uid,
    );

LiveMessage _chat(List<LiveBadge>? badges, {String? userId = "1"}) =>
    LiveMessage(
      type: LiveMessageType.chat,
      userName: "小明",
      message: "一条弹幕",
      color: LiveMessageColor.white,
      userId: userId,
      badges: badges,
    );

void main() {
  late ChatUsersService service;
  late RoomUserBlocks blocks;
  var toasts = <String>[];
  VoidCallback? lastUndo;
  const user = ChatUser("douyu", userId: "1", name: "小明");

  setUp(() async {
    service = Get.put(
      ChatUsersService(storage: MemoryChatUsersStorage(), purgeInterval: null),
    );
    await service.init();
    blocks = RoomUserBlocks(
      siteId: () => "douyu",
      roomId: () => "100",
      roomLabel: () => "主播",
    );
    toasts.clear();
    lastUndo = null;
    ChatUserCard.undoToast = (text, undo) {
      toasts.add(text);
      lastUndo = undo;
    };
    ChatUserCard.toast = toasts.add;
  });
  tearDown(() {
    service.onClose();
    Get.reset();
  });

  var actions = <String>[];

  Future<void> open(WidgetTester tester, {ChatUser who = user}) async {
    actions.clear();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    showChatUserCard(
      user: who,
      blocks: blocks,
      body: (_) => const Text("一条弹幕"),
      before: [
        ChatUserCardAction(
            Icons.person_search, "只看这个人的弹幕", () => actions.add("只看")),
      ],
      after: [
        ChatUserCardAction(Icons.copy, "复制弹幕", () => actions.add("复制")),
      ],
    );
    await tester.pumpAndSettle();
  }

  Finder sheetBox() => find.byType(ChatUserCard);

  testWidgets("第一级：原来的操作照常，下面多了屏蔽和备注", (tester) async {
    await open(tester);
    expect(find.text("小明"), findsOneWidget);
    expect(find.text("屏蔽这个人"), findsOneWidget);
    expect(find.text("备注"), findsOneWidget);
    // 顺序：只看这个人、屏蔽、备注、复制
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y("只看这个人的弹幕"), lessThan(y("屏蔽这个人")));
    expect(y("屏蔽这个人"), lessThan(y("备注")));
    expect(y("备注"), lessThan(y("复制弹幕")));
    await tester.tap(find.text("只看这个人的弹幕"));
    await tester.pumpAndSettle();
    expect(actions, ["只看"]);
    expect(sheetBox(), findsNothing);
  });

  testWidgets("没有用户 ID 的人不能屏蔽和备注：两行都不能点，下面写明原因", (tester) async {
    await open(tester, who: const ChatUser("douyu", name: "小明"));
    expect(find.text("没有用户 ID，无法屏蔽和备注"), findsOneWidget);
    await tester.tap(find.text("屏蔽这个人"));
    await tester.pumpAndSettle();
    expect(find.text("永久屏蔽"), findsNothing);
    expect(service.blocks.isEmpty, isTrue);
    expect(
        tester
            .widget<ListTile>(find.ancestor(
                of: find.text("备注"), matching: find.byType(ListTile)))
            .enabled,
        isFalse);
    expect(ChatUserCard.noIdHint("bilibili"), "未登录时没有用户 ID，无法屏蔽和备注");
  });

  testWidgets("屏蔽 › 永久屏蔽：整个平台；提示里可以撤销", (tester) async {
    await open(tester);
    await tester.tap(find.text("屏蔽这个人"));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text("只在这个直播间"), findsOneWidget);
    expect(find.text("解除屏蔽"), findsNothing);
    // 开关默认关
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse);
    await tester.tap(find.text("永久屏蔽"));
    await tester.pumpAndSettle();
    var block = service.blocks.items.single;
    expect(block.permanent, isTrue);
    expect(block.roomId, isNull);
    expect(toasts, ["已屏蔽 小明"]);
    lastUndo!();
    expect(service.blocks.isEmpty, isTrue);
  });

  testWidgets("返回第一级；切换层级时高度渐变，不跳", (tester) async {
    await open(tester);
    var before = tester.getSize(sheetBox()).height;
    await tester.tap(find.text("屏蔽这个人"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    var middle = tester.getSize(sheetBox()).height;
    await tester.pumpAndSettle();
    var after = tester.getSize(sheetBox()).height;
    expect(after, isNot(before));
    // 动画中间的高度在两头之间
    expect(
        middle,
        inExclusiveRange(
          before < after ? before : after,
          before < after ? after : before,
        ));
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text("屏蔽这个人"), findsOneWidget);
  });

  testWidgets("只在这个直播间", (tester) async {
    await open(tester);
    await tester.tap(find.text("屏蔽这个人"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("只在这个直播间"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("永久屏蔽"));
    await tester.pumpAndSettle();
    expect(service.blocks.items.single.roomId, "100");
    expect(service.blocks.items.single.roomLabel, "主播");
  });

  testWidgets("本次进入：只在内存里", (tester) async {
    await open(tester);
    await tester.tap(find.text("屏蔽这个人"));
    await tester.pumpAndSettle();
    expect(find.text("离开直播间后解除"), findsOneWidget);
    await tester.tap(find.text("本次进入"));
    await tester.pumpAndSettle();
    expect(service.blocks.isEmpty, isTrue);
    expect(blocks.strongest(user)!.kind, UserBlockKind.visit);
  });

  testWidgets("自定义时间：预设，手动输入，最长 240 小时", (tester) async {
    await open(tester);
    await tester.tap(find.text("屏蔽这个人"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("自定义时间"));
    await tester.pumpAndSettle();
    for (var text in ["5 分钟", "10 分钟", "30 分钟", "1 小时"]) {
      expect(find.text(text), findsOneWidget);
    }
    TextButton ok() =>
        tester.widget<TextButton>(find.widgetWithText(TextButton, "确定"));
    // 还没填：不能点，也不提示
    expect(ok().onPressed, isNull);
    await tester.tap(find.text("分钟"));
    await tester.pump();
    expect(find.text("小时"), findsWidgets);
    await tester.enterText(find.byKey(const ValueKey("block_duration")), "241");
    await tester.pump();
    expect(find.text("最长 240 小时"), findsOneWidget);
    expect(ok().onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey("block_duration")), "240");
    await tester.pump();
    expect(find.text("最长 240 小时"), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, "确定"));
    await tester.pumpAndSettle();
    var left = service.blocks.items.single.expireAt! -
        DateTime.now().millisecondsSinceEpoch;
    expect(left, inInclusiveRange(239 * 3600000, 240 * 3600000));
  });

  testWidgets("预设时间", (tester) async {
    await open(tester);
    await tester.tap(find.text("屏蔽这个人"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("自定义时间"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("30 分钟"));
    await tester.pumpAndSettle();
    var left = service.blocks.items.single.expireAt! -
        DateTime.now().millisecondsSinceEpoch;
    expect(left, inInclusiveRange(29 * 60000, 30 * 60000));
  });

  testWidgets("已屏蔽：第一级写还剩多久，第二级第一项是解除屏蔽", (tester) async {
    blocks.block(user, duration: const Duration(minutes: 25));
    await open(tester);
    expect(find.textContaining("已屏蔽（还剩 2"), findsOneWidget);
    await tester.tap(find.textContaining("已屏蔽"));
    await tester.pumpAndSettle();
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y("解除屏蔽"), lessThan(y("只在这个直播间")));
    await tester.tap(find.text("解除屏蔽"));
    await tester.pumpAndSettle();
    expect(service.blocks.isEmpty, isTrue);
    expect(toasts, ["已解除屏蔽"]);
  });

  testWidgets("已永久屏蔽", (tester) async {
    blocks.block(user);
    await open(tester);
    expect(find.text("已永久屏蔽"), findsOneWidget);
  });

  testWidgets("备注：写了以后名字后面显示，可以删除", (tester) async {
    await open(tester);
    await tester.tap(find.text("备注"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey("remark_input")), "老朋友");
    await tester.tap(find.text("保存"));
    await tester.pumpAndSettle();
    expect(service.remarkOf(user), "老朋友");
    // 标题里名字后面灰色的备注，第一级的“备注”那一行右边也有
    expect(find.textContaining("(老朋友)", findRichText: true), findsOneWidget);
    expect(find.text("老朋友"), findsOneWidget);
    await tester.tap(find.text("备注"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("删除备注"));
    await tester.pumpAndSettle();
    expect(service.remarkOf(user), isNull);
  });

  testWidgets("本直播间名单：单个解除、一键解除临时的", (tester) async {
    blocks.block(user);
    blocks.block(
      const ChatUser("douyu", userId: "2", name: "小红"),
      duration: const Duration(minutes: 10),
    );
    blocks.block(const ChatUser("douyu", userId: "3", name: "小刚"),
        visitOnly: true);
    service.remarks.set(user, "常客");
    await tester.pumpWidget(
      GetMaterialApp(home: Scaffold(body: RoomBlockList(blocks: blocks))),
    );
    expect(find.text("本直播间屏蔽的人（3）"), findsOneWidget);
    expect(find.text("全平台 · 永久"), findsOneWidget);
    expect(find.textContaining("(常客)", findRichText: true), findsOneWidget);
    await tester.tap(find.text("解除全部临时屏蔽"));
    await tester.pump();
    expect(find.text("本直播间屏蔽的人（1）"), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text("没有屏蔽的人"), findsOneWidget);
  });

  group("粉丝牌是哪个主播的", () {
    setUp(() => Get.put<AppSettingsController>(_TestSettings()));

    Future<void> show(WidgetTester tester, VoidCallback open) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
      open();
      await tester.pumpAndSettle();
      expect(sheetBox(), findsOneWidget);
    }

    Future<void> showChat(
      WidgetTester tester,
      _Room room,
      List<LiveBadge>? badges, {
      String? userId = "1",
    }) =>
        show(
          tester,
          () => showLiveChatCard(room, _chat(badges, userId: userId)),
        );

    Future<void> closeCard(WidgetTester tester) async {
      Navigator.of(tester.element(sheetBox())).pop();
      await tester.pumpAndSettle();
      expect(sheetBox(), findsNothing);
    }

    ListTile firstRow(WidgetTester tester) => tester.widget<ListTile>(
          find
              .descendant(of: sheetBox(), matching: find.byType(ListTile))
              .first,
        );

    /// 第一行就是粉丝牌，写着 [title]、[owner]，能不能点是 [tappable]，都不灰
    void expectMedal(
      WidgetTester tester,
      String title,
      String owner, {
      required bool tappable,
      String reason = "",
    }) {
      var row = firstRow(tester);
      expect((row.leading as Icon).icon, Icons.loyalty_outlined,
          reason: reason);
      expect((row.title as Text).data, title, reason: reason);
      expect((row.subtitle as Text).data, owner, reason: reason);
      expect(row.onTap != null, tappable, reason: reason);
      expect(row.enabled, isTrue, reason: reason);
      expect(find.byIcon(Icons.loyalty_outlined), findsOneWidget,
          reason: reason);
    }

    void expectNoMedal(WidgetTester tester) {
      expect(find.byIcon(Icons.loyalty_outlined), findsNothing);
      expect(find.textContaining("粉丝牌："), findsNothing);
    }

    testWidgets("别的主播的牌子：第一行写主播名，点了先关卡片，再在这个窗口打开那个直播间", (tester) async {
      var room = _biliRoom();
      await showChat(tester, room, [
        const LiveBadge(LiveBadgeKind.guard, "舰长", level: 3),
        _medal(name: "主播乙", room: "30000002", uid: "20000002"),
        const LiveBadge(LiveBadgeKind.level, "UL", level: 16),
      ]);
      expectMedal(tester, "粉丝牌：甜心 30", "来自 主播乙 的直播间", tappable: true);
      // 在“只看这个人的弹幕”上面；身份那一排牌子还在
      double y(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(y("粉丝牌：甜心 30"), lessThan(y("只看这个人的弹幕")));
      for (var chip in ["舰长", "甜心", "30", "UL 16"]) {
        expect(find.text(chip), findsOneWidget);
      }
      expect(room.opened, isEmpty);
      await tester.tap(find.text("来自 主播乙 的直播间"));
      await tester.pumpAndSettle();
      expect(sheetBox(), findsNothing);
      var (site, roomId) = room.opened.single;
      expect(site, same(room.site));
      expect(roomId, "30000002");
      expect(room.cardOpen, isFalse);
    });

    testWidgets("没有等级时只写牌子名", (tester) async {
      await showChat(tester, _biliRoom(), [
        _medal(name: "主播乙", room: "30000002", level: null),
      ]);
      expectMedal(tester, "粉丝牌：甜心", "来自 主播乙 的直播间", tappable: true);
    });

    testWidgets("就是这个直播间的：主播的 uid 一样，或者房间号和进来的、读到的长号一样", (tester) async {
      var douyu = _FakeDouyu();
      var cases = {
        "哔哩哔哩：uid（房间号是短号）": (
          _biliRoom(),
          _medal(name: "主播甲", room: "6", uid: "20000001"),
        ),
        "哔哩哔哩：读到的长号": (
          _biliRoom(roomId: "6", anchorUid: 0),
          _medal(name: "主播甲", room: "30000001", uid: "20000001"),
        ),
        "哔哩哔哩：进来的短号": (
          _biliRoom(roomId: "6", anchorUid: 0),
          _medal(name: "主播甲", room: "6"),
        ),
        "还没读到直播间信息": (
          _Room(Constant.kBiliBili, BiliBiliSite(), roomId: "6"),
          _medal(name: "主播甲", room: "6"),
        ),
        "虎牙：主播的 uid": (_huyaRoom(), _medal(uid: "294636272")),
        "斗鱼：读到的房间号（靓号进来的）": (
          _Room(Constant.kDouyu, douyu, roomId: "71415")
            ..loaded("24422", "24422"),
          _medal(room: "24422"),
        ),
      };
      for (var MapEntry(key: name, value: (room, medal)) in cases.entries) {
        await showChat(tester, room, [medal]);
        expectMedal(tester, "粉丝牌：甜心 30", "本直播间", tappable: false, reason: name);
        // 点了没反应：卡片还在，不换直播间
        await tester.tap(find.text("本直播间"));
        await tester.pumpAndSettle();
        expect(room.opened, isEmpty, reason: name);
        await closeCard(tester);
      }
      expect(douyu.asked, isEmpty);
    });

    testWidgets("不能点的也看得清：颜色和能点的一样，和灰掉的行不一样", (tester) async {
      Color colorOf(String text) =>
          DefaultTextStyle.of(tester.element(find.text(text))).style.color!;
      var room = _biliRoom();
      await showChat(tester, room, [_medal(name: "主播乙", room: "30000002")]);
      var title = colorOf("粉丝牌：甜心 30");
      var owner = colorOf("来自 主播乙 的直播间");
      await closeCard(tester);
      // 没有用户 ID：备注那一行是灰的
      await showChat(tester, room, [_medal(uid: "20000001")], userId: null);
      expectMedal(tester, "粉丝牌：甜心 30", "本直播间", tappable: false);
      expect(colorOf("粉丝牌：甜心 30"), title);
      expect(colorOf("本直播间"), owner);
      expect(colorOf("备注"), isNot(title));
    });

    testWidgets("没有主播名写房间号；不知道房间号的不能点", (tester) async {
      var bili = _biliRoom();
      // 哔哩哔哩没给主播名：写房间号，不去读
      var badges = [_medal(room: "30000002", uid: "20000002")];
      expect(chatUserMedal(bili, badges)!.loadOwner, isNull);
      await showChat(tester, bili, badges);
      expectMedal(tester, "粉丝牌：甜心 30", "来自直播间 30000002", tappable: true);
      await tester.tap(find.text("粉丝牌：甜心 30"));
      await tester.pumpAndSettle();
      expect(bili.opened.single.$2, "30000002");

      var huya = _huyaRoom();
      for (var (badge, owner) in [
        (_medal(name: "主播丙", uid: "2210112017"), "来自 主播丙 的直播间"),
        (_medal(name: "主播丙"), "来自 主播丙 的直播间"),
        (_medal(uid: "2210112017"), "来自 UID 2210112017 的直播间"),
      ]) {
        expect(chatUserMedal(huya, [badge])!.loadOwner, isNull);
        await showChat(tester, huya, [badge]);
        expectMedal(tester, "粉丝牌：甜心 30", owner, tappable: false);
        await tester.tap(find.text(owner));
        await tester.pumpAndSettle();
        expect(huya.opened, isEmpty);
        await closeCard(tester);
      }
    });

    testWidgets("没戴牌子、不知道是谁的（旧的记录、别的平台）、别的身份：没有这一行", (tester) async {
      var room = _biliRoom();
      for (var badges in <List<LiveBadge>?>[
        null,
        const [],
        [_medal()],
        // 旧的记录里没有主人
        [
          LiveBadge.fromJson({"k": "medal", "t": "甜心", "l": 30})!,
        ],
        // 别的身份不看
        const [
          LiveBadge(LiveBadgeKind.guard, "舰长", ownerName: "主播乙"),
          LiveBadge(LiveBadgeKind.level, "UL", level: 16, ownerUid: "1"),
        ],
      ]) {
        await showChat(tester, room, badges);
        expectNoMedal(tester);
        expect((firstRow(tester).title as Text).data, "只看这个人的弹幕");
        await closeCard(tester);
      }
    });

    testWidgets("斗鱼只有房间号：先写房间号，打开卡片后读一次主播名", (tester) async {
      var site = _FakeDouyu();
      var gate = Completer<String?>();
      site.reply = () => gate.future;
      var room = _Room(Constant.kDouyu, site)..loaded("24422", "24422");
      var badges = [_medal(room: "9263298")];
      // 还没打开卡片：不读
      chatUserMedal(room, badges);
      await tester.pump();
      expect(site.asked, isEmpty);

      await showChat(tester, room, badges);
      expect(site.asked, ["9263298"]);
      expectMedal(tester, "粉丝牌：甜心 30", "来自直播间 9263298", tappable: true);
      gate.complete("主播乙");
      await tester.pumpAndSettle();
      expectMedal(tester, "粉丝牌：甜心 30", "来自 主播乙 的直播间", tappable: true);

      // 到第二级再回来：还是主播名，不再读
      await tester.tap(find.text("屏蔽这个人"));
      await tester.pumpAndSettle();
      expectNoMedal(tester);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expectMedal(tester, "粉丝牌：甜心 30", "来自 主播乙 的直播间", tappable: true);
      expect(site.asked, hasLength(1));

      await tester.tap(find.text("粉丝牌：甜心 30"));
      await tester.pumpAndSettle();
      expect(sheetBox(), findsNothing);
      expect(room.opened.single, (room.site, "9263298"));
    });

    testWidgets("斗鱼读不到主播名：照旧写房间号，不提示；关了卡片以后读到的不用", (tester) async {
      var site = _FakeDouyu();
      var room = _Room(Constant.kDouyu, site)..loaded("24422", "24422");
      var badges = [_medal(room: "9263298")];
      for (var reply in <Future<String?> Function()>[
        () => Future.error(CoreError("读取失败")),
        () => throw StateError("bad"),
        () async => null,
      ]) {
        site
          ..asked.clear()
          ..reply = reply;
        await showChat(tester, room, badges);
        expect(tester.takeException(), isNull);
        expectMedal(tester, "粉丝牌：甜心 30", "来自直播间 9263298", tappable: true);
        // 只读一次，不重试
        expect(site.asked, ["9263298"]);
        await closeCard(tester);
      }
      expect(toasts, isEmpty);

      var late = Completer<String?>();
      site.reply = () => late.future;
      await showChat(tester, room, badges);
      await closeCard(tester);
      late.complete("主播乙");
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets("斗鱼：牌子里有主播名、没有房间号、就是这个直播间的不读", (tester) async {
      var site = _FakeDouyu();
      var room = _Room(Constant.kDouyu, site)..loaded("24422", "24422");
      for (var (badge, owner) in [
        (_medal(name: "主播乙", room: "9263298"), "来自 主播乙 的直播间"),
        (_medal(uid: "7"), "来自 UID 7 的直播间"),
        (_medal(room: "24422"), "本直播间"),
      ]) {
        await showChat(tester, room, [badge]);
        expect(find.text(owner), findsOneWidget);
        await closeCard(tester);
      }
      expect(site.asked, isEmpty);
    });

    testWidgets("榜单上的人一样（只有主播的 uid）；SC、礼物里没有牌子，没有这一行", (tester) async {
      var room = _biliRoom();
      const board = LiveRankBoard(id: "online", title: "在线贡献榜");
      LiveRankItem item(String uid) => LiveRankItem(
            rank: 1,
            userName: "小红",
            userId: "2",
            badges: [_medal(uid: uid)],
          );
      await show(
        tester,
        () => showRankUserCard(room, item("20000001"), board),
      );
      expectMedal(tester, "粉丝牌：甜心 30", "本直播间", tappable: false);
      await closeCard(tester);
      await show(
        tester,
        () => showRankUserCard(room, item("3000000099"), board),
      );
      expectMedal(tester, "粉丝牌：甜心 30", "来自 UID 3000000099 的直播间",
          tappable: false);
      await closeCard(tester);

      await show(
        tester,
        () => showSuperChatUserCard(
          room,
          LiveSuperChatMessage(
            backgroundBottomColor: "#2A60B2",
            backgroundColor: "#EDF5FF",
            endTime: DateTime(2026, 11, 24, 20, 1),
            face: "",
            message: "留言",
            price: 30,
            startTime: DateTime(2026, 11, 24, 20),
            userName: "小明",
            userId: "1",
          ),
        ),
      );
      expectNoMedal(tester);
      await closeCard(tester);
      await show(
        tester,
        () => showGiftUserCard(
          room,
          LiveGiftMessage(userName: "小明", userId: "1", giftName: "小心心"),
        ),
      );
      expectNoMedal(tester);
    });

    test("新的文字都有英文和繁体", () {
      for (var code in ["en", "zh-Hant"]) {
        var table =
            jsonDecode(File("assets/lang/$code.json").readAsStringSync())
                as Map<String, dynamic>;
        for (var key in [
          "粉丝牌：{medal}",
          "来自 {name} 的直播间",
          "来自直播间 {room}",
          "来自 UID {uid} 的直播间",
          "本直播间",
        ]) {
          expect(table[key], isNotNull, reason: "$code $key");
        }
      }
    });
  });
}
