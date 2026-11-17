import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/modules/live_room/live_gift_list.dart';
import 'package:simple_live_app/modules/live_room/live_gifts.dart';
import 'package:simple_live_app/modules/live_room/rank/live_rank_panel.dart';
import 'package:simple_live_app/modules/live_room/rank/live_rank_state.dart';
import 'package:simple_live_app/widgets/compact_buttons.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'layout_matrix.dart';

// 布局检查：礼物页（左边的“榜单”按钮，礼物和榜单两个视图）的浮动按钮，领奖台在窄屏下不超出，
// 静止时浮动按钮不盖住第一行。名字 20 个字，分数很大

const longName = "名字特别特别特别特别长的一位观众啊啊啊啊";

/// 改过的文字还没进 en.json，英文布局用 i18n_new.json 里拟的译文
final Map<String, String> _english = () {
  var file = File("../i18n_new.json");
  if (!file.existsSync()) {
    return <String, String>{};
  }
  return Map<String, String>.from(jsonDecode(file.readAsStringSync()) as Map);
}();

Widget withNewText(Widget Function() build) {
  var base = CoreText.lookup;
  if (base != null && base("复制弹幕") == "Copy danmaku") {
    CoreText.lookup = (key) => base(key) ?? _english[key];
  }
  return build();
}

const _second = LiveRankBoard(id: "fans", title: "粉丝团", scoreLabel: "亲密度");

const _douyu = LiveRankBoard(
  id: "intimacy",
  title: "亲密榜",
  scoreLabel: "亲密度",
  note: "斗鱼没有公开这个接口的文档，数据可能不全，也可能随时无法读取",
  live: true,
);

List<LiveRankItem> _items() => [
      for (var i = 1; i <= 12; i++)
        LiveRankItem(
          rank: i,
          userName: i.isEven ? longName : "观众$i",
          userId: "$i",
          score: 1234567890 ~/ i,
          detail: i % 3 == 0 ? "陪伴 1234 天" : null,
          badges: [
            const LiveBadge(LiveBadgeKind.guard, "总督", level: 1),
            LiveBadge(LiveBadgeKind.medal, "很长的粉丝牌名字", level: 40 - i),
            const LiveBadge(LiveBadgeKind.level, "荣耀", level: 60),
          ],
        ),
    ];

/// 不读本地存储的设置
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

GiftBook _gifts() {
  var book = GiftBook();
  for (var i = 1; i <= 30; i++) {
    book.add(
      LiveGiftMessage(
        userName: i.isEven ? longName : "送礼的人$i",
        userId: "$i",
        action: "投喂",
        giftName: "很长名字的礼物$i",
        count: i * 7,
        priceText: "¥${i * 13}",
      ),
      now: DateTime(2026, 11, 15, 20, 0, i),
    );
  }
  return book;
}

void main() {
  late AppSettingsController settings;

  setUp(() {
    Get.testMode = true;
    settings = Get.put<AppSettingsController>(_TestSettings());
    // 最新的在上面：第一行在最上面，看得出浮动按钮有没有盖住它
    settings.noticeNewestAtBottom.value = false;
  });
  tearDown(Get.reset);

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

  Future<LiveRankState> loaded() async {
    var state = LiveRankState(
      platformBoards: () => const [_douyu, _second],
      fetch: (id) async => LiveRankList(id, _items(), total: 123456),
      giftRanking: () => const [],
      now: () => DateTime(2026, 11, 15, 20, 15, 32),
    );
    await state.refresh();
    return state;
  }

  /// 礼物页：礼物 | 榜单，浮动按钮和直播间里一样
  Widget page(GiftBook book, LiveRankState state, RxBool rankSelected) =>
      GiftPageView(
        showRank: () => true,
        rankSelected: rankSelected,
        gifts: (leading) => GiftListView(
          book: book,
          version: 0.obs,
          paidOnly: false.obs,
          leading: leading,
          remarkOf: (_) => "备注也写得很长很长",
        ),
        rank: (leading) => LiveRankPanel(
          state: state,
          leading: leading,
          onTapItem: (_) {},
        ),
      );

  testWidgets("礼物页：切换按钮和浮动按钮，礼物和榜单两个视图", (tester) async {
    var book = _gifts();
    var state = await loaded();
    var rankSelected = false.obs;
    await check(tester, "礼物页（礼物）", () => page(book, state, rankSelected));
    rankSelected.value = true;
    await check(tester, "礼物页（榜单）", () => page(book, state, rankSelected));
  });

  testWidgets("浮动按钮不盖住第一行（静止时）", (tester) async {
    var book = _gifts();
    var state = await loaded();
    var rankSelected = false.obs;
    for (var size in const [
      Size(360, 640),
      Size(300, 640), // 侧栏最窄
      Size(844, 390),
      Size(400, 225),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      for (var rank in [false, true]) {
        rankSelected.value = rank;
        await tester.pumpWidget(
          GetMaterialApp(
            home: Scaffold(body: page(book, state, rankSelected)),
          ),
        );
        // 浮动按钮的高度在下一帧量出来
        await tester.pump();
        await tester.pump();
        if (rank) {
          expectBelow(
            tester,
            find.byType(LiveRankHeader),
            find.byType(LiveRankInfo),
            reason: "$size 榜单",
          );
          expectBelow(
            tester,
            find.byType(LiveRankHeader),
            find.byType(RankPodium),
            reason: "$size 榜单",
          );
        } else {
          expectBelow(
            tester,
            find.byType(RankViewButton),
            find.byType(GiftRow),
            reason: "$size 礼物",
          );
          expectBelow(
            tester,
            find.byType(FloatingPill).last,
            find.byType(GiftRow),
            reason: "$size 礼物",
          );
        }
      }
    }
    tester.view.reset();
  });
}
