import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/live_room/player/voice_room_view.dart';
import 'package:simple_live_app/widgets/floating_header.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'layout_matrix.dart';

/// 基线：现有的几个组件在所有尺寸、语言、文字缩放下跑一遍。
/// 已知的问题写在 [known] 里（只记录，不在这里修）；出现新的问题就算失败
void main() {
  // 原有的问题（基线）
  const known = <String>{
    // 语聊房：手机竖屏、文字放大 1.3 倍时一行麦位分数超出 14 像素
    "VoiceRoomView 360x640 zh-Hans x1.3: A RenderFlex overflowed by 14 pixels on the right.",
  };

  Future<void> check(WidgetTester tester, String name, Widget Function() builder,
      {Iterable<Size> sizes = layoutSizes}) async {
    var problems = await layoutMatrix(tester, builder, sizes: sizes);
    var fresh = problems.where((p) => !known.contains("$name $p")).toList();
    if (problems.isNotEmpty) {
      // 写进测试输出，基线报告从这里抄
      // ignore: avoid_print
      print("[baseline] $name\n  ${problems.join("\n  ")}");
    }
    expect(fresh, isEmpty, reason: name);
  }

  testWidgets("关注列表的一行：名字很长、开了提醒", (tester) async {
    var item = FollowUser(
      id: "huya_1",
      roomId: "1",
      siteId: "huya",
      userName: "名字特别特别特别特别长的一位主播啊啊啊啊",
      face: "",
      addTime: DateTime(2026, 11, 14),
      notify: true,
    );
    item.liveStatus.value = 2;
    item.liveStartTime = "${DateTime.now().millisecondsSinceEpoch ~/ 1000 - 7200}";
    await check(
      tester,
      "FollowUserItem",
      () => Align(
        alignment: Alignment.topLeft,
        child: FollowUserItem(item: item, onToggleNotify: () {}, onRemove: () {}),
      ),
    );
  });

  testWidgets("浮动标签条盖不住第一条", (tester) async {
    await check(
      tester,
      "FloatingHeader",
      () => FloatingHeader(
        header: Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(spacing: 8, children: [
            for (var t in ["全部", "直播中", "未开播", "很长很长的自定义标签"])
              ChoiceChip(label: Text(t), selected: t == "全部"),
          ]),
        ),
        body: (context, top) => ListView(
          padding: EdgeInsets.only(top: top),
          children: [for (var i = 0; i < 20; i++) ListTile(title: Text("第 $i 条"))],
        ),
      ),
    );
    expectBelow(tester, find.byType(Wrap), find.text("第 0 条"));
  });

  testWidgets("语聊房画面", (tester) async {
    var room = LiveVoiceRoom(
      seats: const [
        LiveVoiceSeat(position: 0, uid: "1", name: "房主名字比较长的一位", host: true, score: "12345"),
        LiveVoiceSeat(position: 1, uid: "2", name: "嘉宾", score: "1"),
      ],
      teams: const [LiveVoiceTeam("1", "1"), LiveVoiceTeam("2", "2")],
    );
    await check(tester, "VoiceRoomView", () => VoiceRoomView(room: room));
  });
}
