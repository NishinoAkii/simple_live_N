import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/player/voice_room_view.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 房主 + 嘉宾麦 1、2、3、7、8（4、5、6 空着），和抓到的真直播间一样
LiveVoiceRoom room({bool pk = true}) => LiveVoiceRoom(
  seats: const [
    LiveVoiceSeat(position: 0, uid: "10", name: "房主甲", host: true, muted: true, score: "1455"),
    LiveVoiceSeat(position: 1, uid: "11", name: "嘉宾乙", score: "1", team: "1"),
    LiveVoiceSeat(position: 2, uid: "12", name: "名字很长很长很长的嘉宾丙", score: "91", team: "1"),
    LiveVoiceSeat(position: 3, uid: "13", name: "嘉宾丁", score: "161", team: "2"),
    LiveVoiceSeat(position: 7, uid: "17", name: "嘉宾戊", muted: true, score: "160", team: "2"),
    LiveVoiceSeat(position: 8, uid: "18", name: "嘉宾己", score: "164", team: "2"),
  ],
  teams: pk ? const [LiveVoiceTeam("1", "92"), LiveVoiceTeam("2", "321")] : const [],
);

Future<void> pumpView(
  WidgetTester tester,
  Size size, {
  LiveVoiceRoom? data,
  (LiveVoiceCaption, DateTime)? caption,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox.fromSize(
            size: size,
            child: VoiceRoomView(room: data ?? room(), caption: caption),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets("房主、8 个嘉宾麦（空的写“空麦位”）、PK 分数", (tester) async {
    await pumpView(tester, const Size(1280, 720));
    expect(tester.takeException(), isNull);
    expect(find.text("房主甲"), findsOneWidget);
    expect(find.text("房主"), findsOneWidget);
    expect(find.text("嘉宾乙"), findsOneWidget);
    expect(find.text("空麦位"), findsNWidgets(3));
    for (var n in ["4", "5", "6"]) {
      expect(find.text(n), findsOneWidget);
    }
    expect(find.text("92"), findsOneWidget);
    expect(find.text("321"), findsOneWidget);
    // 闭麦的两个人头像上有标记
    expect(find.byIcon(Icons.mic_off), findsNWidgets(2));
  });

  testWidgets("没有 PK 时不显示分数", (tester) async {
    await pumpView(tester, const Size(1280, 720), data: room(pk: false));
    expect(find.text("PK"), findsNothing);
  });

  for (var size in const [Size(360, 203), Size(640, 360), Size(1920, 1080), Size(400, 700)]) {
    testWidgets("${size.width.toInt()}×${size.height.toInt()} 放得下，不溢出", (tester) async {
      await pumpView(tester, size);
      expect(tester.takeException(), isNull);
      var body = tester.getRect(find.byType(FittedBox));
      expect(body.width <= size.width + 0.01, isTrue);
      expect(body.height <= size.height + 0.01, isTrue);
    });
  }

  testWidgets("最近一句话显示在底部，8 秒后消失", (tester) async {
    var caption = (
      const LiveVoiceCaption(uid: "11", name: "嘉宾乙", text: "能不能给我一个"),
      DateTime.now(),
    );
    await pumpView(tester, const Size(1280, 720), caption: caption);
    expect(find.textContaining("能不能给我一个", findRichText: true), findsOneWidget);
    var old = (caption.$1, DateTime.now().subtract(const Duration(seconds: 9)));
    await pumpView(tester, const Size(1280, 720), caption: old);
    expect(find.textContaining("能不能给我一个", findRichText: true), findsNothing);
  });
}
