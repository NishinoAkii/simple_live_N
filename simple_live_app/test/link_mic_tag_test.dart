import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/live_room/player/link_mic_tag.dart';
import 'package:simple_live_core/simple_live_core.dart';

const a = LiveLinkMicUser(name: "主播甲");
const b = LiveLinkMicUser(name: "主播乙");
const c = LiveLinkMicUser(name: "观众丙");
const d = LiveLinkMicUser(name: "观众丁");

Future<(Rx<LiveLinkMicState>, RxBool)> pumpTag(WidgetTester tester) async {
  var state = Rx<LiveLinkMicState>(LiveLinkMicState.none);
  var hidden = false.obs;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Stack(children: [
        const Positioned.fill(child: SizedBox.expand(key: Key("video"))),
        Positioned(
          left: 24,
          bottom: 24,
          child: LinkMicTag(
            state: state,
            hidden: hidden,
            onHide: () => hidden.value = true,
          ),
        ),
      ]),
    ),
  ));
  return (state, hidden);
}

void main() {
  testWidgets("没有连麦时什么都不显示；有人连麦时显示方式和名字", (tester) async {
    var (state, _) = await pumpTag(tester);
    expect(find.byType(Text), findsNothing);
    state.value = const LiveLinkMicState(linked: [a, b]);
    await tester.pump();
    expect(find.text("连麦"), findsOneWidget);
    expect(find.text("主播甲、主播乙"), findsOneWidget);
    expect(find.textContaining("排队"), findsNothing);
    state.value = LiveLinkMicState.none;
    await tester.pump();
    expect(find.text("主播甲、主播乙"), findsNothing);
  });

  testWidgets("点一下展开排队名单，点别处收起", (tester) async {
    var (state, _) = await pumpTag(tester);
    state.value = const LiveLinkMicState(
      linked: [a],
      queue: [c, d],
      queueCount: 5,
    );
    await tester.pump();
    expect(find.text("排队 5"), findsOneWidget);
    expect(find.text("观众丙"), findsNothing);
    await tester.tap(find.text("主播甲"));
    await tester.pump();
    expect(find.text("观众丙"), findsOneWidget);
    expect(find.text("观众丁"), findsOneWidget);
    expect(find.text("还有 3 人，平台没给名单"), findsOneWidget);
    // 点视频（标签外面）收起
    await tester.tapAt(const Offset(600, 100));
    await tester.pump();
    expect(find.text("观众丙"), findsNothing);
  });

  testWidgets("平台只给人数时说明没有名单", (tester) async {
    var (state, _) = await pumpTag(tester);
    state.value = const LiveLinkMicState(
      kind: "语音连麦",
      linked: [a],
      queueCount: 3,
    );
    await tester.pump();
    await tester.tap(find.text("排队 3"));
    await tester.pump();
    expect(find.text("3 人在排队，平台没给名单"), findsOneWidget);
  });

  testWidgets("点 × 关掉", (tester) async {
    var (state, hidden) = await pumpTag(tester);
    state.value = const LiveLinkMicState(kind: "PK", linked: [a]);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(hidden.value, isTrue);
    expect(find.text("PK"), findsNothing);
  });

  test("连麦状态：同样的内容算相等，排队人数取大的", () {
    const s1 = LiveLinkMicState(linked: [a], queue: [c], queueCount: 0);
    const s2 = LiveLinkMicState(linked: [a], queue: [c], queueCount: 0);
    expect(s1, s2);
    expect(s1.waiting, 1);
    expect(const LiveLinkMicState(linked: [a], queueCount: 4).waiting, 4);
    expect(LiveLinkMicState.fromJson(s1.toJson()), s1);
    expect(s1.summary, "连麦：主播甲");
    expect(LiveLinkMicState.none.active, isFalse);
  });
}
