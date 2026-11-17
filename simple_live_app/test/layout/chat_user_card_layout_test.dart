import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/live_room/live_gift_list.dart';
import 'package:simple_live_app/modules/live_room/live_gifts.dart';
import 'package:simple_live_app/modules/live_room/user_card/chat_user_card.dart';
import 'package:simple_live_app/modules/live_room/user_card/user_block_list.dart';
import 'package:simple_live_app/services/chat_users/chat_user.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/chat_users/room_user_blocks.dart';
import 'package:simple_live_app/services/chat_users/user_block_store.dart';
import 'package:simple_live_app/widgets/superchat_card.dart';
import 'package:simple_live_app/widgets/undo_toast.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'layout_matrix.dart';

// 布局检查：用户卡片的每一级、本直播间名单、“弹幕屏蔽”页的用户一栏、
// 带备注的 SC 卡片和礼物行、带撤销的提示。名字 20 个字、备注 30 个字（最长）

const longName = "名字特别特别特别特别长的一位观众啊啊啊啊";
const longRemark = "备注也写得特别特别特别特别特别特别长的一句话啊啊啊啊啊啊啊";

/// 新加的文字还没进 en.json（合并时再加），英文布局用 i18n_new.json 里拟的译文
Map<String, String> _newEnglish() {
  var file = File("../i18n_new.json");
  if (!file.existsSync()) {
    return const {};
  }
  return Map<String, String>.from(jsonDecode(file.readAsStringSync()) as Map);
}

final _english = _newEnglish();

/// layoutMatrix 每次调用 builder 之前已经换好了语言表；英文时补上新文字的译文
Widget withNewText(Widget Function() build) {
  var base = CoreText.lookup;
  if (base != null && base("复制弹幕") == "Copy danmaku") {
    CoreText.lookup = (key) => base(key) ?? _english[key];
  }
  return build();
}

/// 和 showModalBottomSheet 一样：贴着底部，最宽 600，最高九成屏幕
Widget sheet(Widget child) => LayoutBuilder(
      builder: (context, box) => Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 600,
            maxHeight: box.maxHeight * 0.9,
          ),
          child: Material(child: child),
        ),
      ),
    );

void main() {
  late ChatUsersService service;
  late RoomUserBlocks blocks;
  const user = ChatUser("douyu", userId: "1", name: longName);

  setUp(() async {
    service = Get.put(
      ChatUsersService(storage: MemoryChatUsersStorage(), purgeInterval: null),
    );
    await service.init();
    service.remarks.set(user, longRemark);
    blocks = RoomUserBlocks(
      siteId: () => "douyu",
      roomId: () => "100",
      roomLabel: () => "主播",
    );
  });
  tearDown(() {
    service.onClose();
    Get.reset();
  });

  ChatUserCard card(
    ChatUserCardLevel level, {
    String duration = "",
    ChatUser who = user,
  }) =>
      ChatUserCard(
        user: who,
        blocks: blocks,
        initialLevel: level,
        initialDuration: duration,
        body: (_) => const Text(
          "这是一条很长很长的弹幕，看看卡片里换行是不是正常，"
          "再长一点再长一点再长一点再长一点再长一点再长一点",
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
        ),
        before: [
          ChatUserCardAction(Icons.person_search, "只看这个人的弹幕".t, () {}),
        ],
        after: [
          ChatUserCardAction(Icons.copy, "复制弹幕".t, () {}),
          ChatUserCardAction(Icons.search, "搜索这条弹幕".t, () {}),
        ],
      );

  Future<void> check(
    WidgetTester tester,
    String name,
    Widget Function() builder,
  ) async {
    var problems = await layoutMatrix(tester, () => withNewText(builder));
    if (problems.isNotEmpty) {
      // ignore: avoid_print
      print("[layout] $name\n  ${problems.join("\n  ")}");
    }
    expect(problems, isEmpty, reason: name);
  }

  testWidgets("卡片第一级：没屏蔽", (tester) async {
    await check(tester, "main", () => sheet(card(ChatUserCardLevel.main)));
  });

  testWidgets("卡片第一级：没有用户 ID（不能屏蔽，下面写原因）", (tester) async {
    await check(
        tester,
        "main-no-id",
        () => sheet(card(ChatUserCardLevel.main,
            who: const ChatUser("bilibili", name: longName))));
  });

  testWidgets("卡片第一级：定时屏蔽着（还剩多久）", (tester) async {
    blocks.block(user, duration: const Duration(minutes: 25));
    await check(
        tester, "main-blocked", () => sheet(card(ChatUserCardLevel.main)));
  });

  testWidgets("卡片第二级：屏蔽着（第一项是解除）", (tester) async {
    blocks.block(user);
    await check(tester, "block", () => sheet(card(ChatUserCardLevel.block)));
  });

  testWidgets("卡片第三级：超过 240 小时的提示", (tester) async {
    await check(
      tester,
      "custom",
      () => sheet(card(ChatUserCardLevel.customTime, duration: "99999")),
    );
  });

  testWidgets("卡片：备注", (tester) async {
    await check(tester, "remark", () => sheet(card(ChatUserCardLevel.remark)));
  });

  testWidgets("本直播间屏蔽的人", (tester) async {
    blocks.block(user);
    blocks.block(
      const ChatUser("douyu", userId: "2", name: longName + longName),
      roomOnly: true,
      duration: const Duration(hours: 239),
    );
    blocks.block(const ChatUser("douyu", userId: "3", name: "本次"),
        visitOnly: true);
    await check(
        tester, "room-list", () => sheet(RoomBlockList(blocks: blocks)));
  });

  testWidgets("本直播间屏蔽的人：没有", (tester) async {
    await check(
        tester, "room-list-empty", () => sheet(RoomBlockList(blocks: blocks)));
  });

  testWidgets("“弹幕屏蔽”页的用户一栏", (tester) async {
    blocks.block(user, roomOnly: true);
    blocks.block(
      const ChatUser("twitch", userId: "9", name: longName),
      duration: const Duration(minutes: 30),
    );
    service.blocks.add(
      UserBlock(
        siteId: "bilibili",
        midHash: "1a2b3c4d",
        name: "",
        roomId: "1",
        roomLabel: longName,
      ),
    );
    await check(
      tester,
      "settings",
      () => ListView(
        padding: const EdgeInsets.all(12),
        children: [UserBlockSection(service: service)],
      ),
    );
  });

  testWidgets("带备注的 SC：列表里和视频上弹出的", (tester) async {
    var sc = LiveSuperChatMessage(
      backgroundBottomColor: "#2A60B2",
      backgroundColor: "#EDF5FF",
      endTime: DateTime.now().add(const Duration(minutes: 1)),
      face: "",
      message: "留言" * 30,
      price: 30,
      startTime: DateTime.now(),
      userName: longName,
    );
    await check(
      tester,
      "superchat",
      () => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          SuperChatCard(sc, remaining: 60, remark: longRemark),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 240,
              child: SuperChatCard(
                sc,
                remaining: 60,
                showStatus: false,
                remark: longRemark,
              ),
            ),
          ),
        ],
      ),
    );
  });

  testWidgets("带备注的礼物行", (tester) async {
    var record = GiftRecord(
      LiveGiftMessage(
        userName: longName,
        giftName: "小心心",
        count: 99,
        priceText: "¥9.9",
      ),
      DateTime(2026, 11, 14, 20, 15),
    );
    await check(
      tester,
      "gift",
      () => ListView(
          children: [GiftRow(record, remark: longRemark, onTap: () {})]),
    );
  });

  testWidgets("带撤销的提示", (tester) async {
    await check(
      tester,
      "undo-toast",
      () => Center(
        child: UndoToast(
          text: "已屏蔽 {name}".tf({"name": longName}),
          onUndo: () {},
        ),
      ),
    );
  });
}
