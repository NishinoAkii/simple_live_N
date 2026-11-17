import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/modules/live_room/room_stats_line.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 和直播间里一样：主播名下面的一行，左边平台、右边那几个数
Future<void> pumpRow(
  WidgetTester tester,
  LiveRoomStats stats, {
  double width = 400,
  String name = "哔哩哔哩",
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: RoomStatsRow(
              logo: const SizedBox(width: 20, height: 20),
              name: name,
              stats: RoomStatsLine(stats),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets("三项都有：在线、看过、点赞，过万写成 x.x万", (tester) async {
    await pumpRow(
      tester,
      const LiveRoomStats(viewers: 996, watched: 198183, likes: 16213),
    );
    expect(tester.takeException(), isNull);
    expect(find.text("996"), findsOneWidget);
    expect(find.text("19.8万"), findsOneWidget);
    expect(find.text("1.6万"), findsOneWidget);
    // 从左到右：在线、看过、点赞，靠右
    var x = [
      for (var icon in [Remix.user_line, Remix.eye_line, Remix.thumb_up_line])
        tester.getCenter(find.byIcon(icon)).dx,
    ];
    expect(x[0] < x[1] && x[1] < x[2], isTrue);
    expect(
      tester.getTopRight(find.byType(RoomStatsLine)).dx,
      tester.getTopRight(find.byType(RoomStatsRow)).dx,
    );
    // 放得下时不缩小
    expect(tester.getSize(find.byIcon(Remix.eye_line)).width, 14);
    // 完整的数字在提示里
    expect(find.byTooltip("198183 人看过"), findsOneWidget);
    expect(find.byTooltip("996 人在线"), findsOneWidget);
    expect(find.byTooltip("16213 次点赞"), findsOneWidget);
  });

  testWidgets("平台给哪几项就显示哪几项（斗鱼：在线人数和贵宾数）", (tester) async {
    await pumpRow(
      tester,
      const LiveRoomStats(viewers: 213, nobles: 116),
      name: "斗鱼直播",
    );
    expect(find.text("213"), findsOneWidget);
    expect(find.text("116"), findsOneWidget);
    expect(find.text("斗鱼直播"), findsOneWidget);
    expect(find.byTooltip("116 位贵宾"), findsOneWidget);
    // 在线在前，贵宾在后
    expect(
      tester.getCenter(find.byIcon(Remix.user_line)).dx <
          tester.getCenter(find.byIcon(Remix.vip_crown_line)).dx,
      isTrue,
    );
    expect(find.byIcon(Remix.eye_line), findsNothing);
    expect(find.byIcon(Remix.thumb_up_line), findsNothing);
  });

  testWidgets("只有贵宾数（虎牙）", (tester) async {
    await pumpRow(tester, const LiveRoomStats(nobles: 7991), name: "虎牙直播");
    expect(find.text("7991"), findsOneWidget);
    expect(find.byIcon(Remix.vip_crown_line), findsOneWidget);
    expect(find.byIcon(Remix.user_line), findsNothing);
  });

  testWidgets("都没有时不占地方，平台名照常显示", (tester) async {
    await pumpRow(tester, LiveRoomStats.none);
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(RoomStatsLine)), Size.zero);
    expect(find.byType(Icon), findsNothing);
    expect(find.text("哔哩哔哩"), findsOneWidget);
  });

  testWidgets("放不下时整体缩小，不溢出", (tester) async {
    // 头像右边剩下的宽度，按 360 宽的手机算大约 264；测试字体每个字 12 宽，
    // 这三个数排开要 300 多
    await pumpRow(
      tester,
      const LiveRoomStats(viewers: 123456, watched: 12345678, likes: 1234567),
      width: 264,
      name: "名字很长很长很长的直播源",
    );
    expect(tester.takeException(), isNull);
    var row = tester.getRect(find.byType(RoomStatsRow));
    var line = tester.getRect(find.byType(FittedBox));
    expect(line.right, moreOrLessEquals(row.right, epsilon: 0.01));
    expect(line.left >= row.left + 32 - 0.01, isTrue);
  });
}
