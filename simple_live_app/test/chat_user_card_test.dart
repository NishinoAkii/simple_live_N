import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/live_room/user_card/chat_user_card.dart';
import 'package:simple_live_app/modules/live_room/user_card/user_block_list.dart';
import 'package:simple_live_app/services/chat_users/chat_user.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/chat_users/room_user_blocks.dart';
import 'package:simple_live_app/services/chat_users/user_block_store.dart';

// 用户卡片的三级菜单、备注、本直播间名单（点一点）

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
}
