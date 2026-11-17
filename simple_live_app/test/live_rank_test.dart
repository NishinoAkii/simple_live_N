import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/modules/live_room/live_gift_list.dart';
import 'package:simple_live_app/modules/live_room/live_gifts.dart';
import 'package:simple_live_app/modules/live_room/live_room_tabs.dart';
import 'package:simple_live_app/modules/live_room/rank/live_rank_panel.dart';
import 'package:simple_live_app/modules/live_room/rank/live_rank_state.dart';
import 'package:simple_live_app/modules/live_room/room_stats_line.dart';
import 'package:simple_live_app/modules/live_room/user_card/chat_user_card.dart';
import 'package:simple_live_app/modules/live_room/user_card/live_user_card.dart';
import 'package:simple_live_app/services/chat_users/chat_user.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/chat_users/room_user_blocks.dart';
import 'package:simple_live_app/widgets/compact_buttons.dart';
import 'package:simple_live_app/widgets/adaptive_tab_bar.dart';
import 'package:simple_live_core/simple_live_core.dart';

// 直播间的榜单（礼物页里的“礼物 | 榜单”、点在线人数打开、设置开关、
// 刷新和更新时间、筛选、点一行打开用户卡片）

/// 不读本地存储的设置
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

const _online = LiveRankBoard(
  id: "online",
  title: "在线贡献榜",
  shortTitle: "贡献榜",
  scoreLabel: "贡献值",
  live: true,
);

/// 12 个人：单数名次的戴着粉丝牌
List<LiveRankItem> people({String prefix = "观众", int base = 1000}) => [
      for (var i = 1; i <= 12; i++)
        LiveRankItem(
          rank: i,
          userName: "$prefix$i",
          userId: "$i",
          score: base - i,
          badges: [
            if (i.isOdd) LiveBadge(LiveBadgeKind.medal, "牌子", level: i),
          ],
        ),
    ];

class _Fetcher {
  int calls = 0;
  List<LiveRankItem> Function() next = people;
  Object? error;

  Future<LiveRankList> call(String boardId) async {
    calls++;
    if (error != null) throw error!;
    return LiveRankList(boardId, next(), total: 45);
  }
}

void main() {
  late _Fetcher fetcher;
  late DateTime now;
  late LiveRankState state;
  late GiftBook book;

  setUp(() {
    Get.testMode = true;
    fetcher = _Fetcher();
    now = DateTime(2026, 11, 15, 20, 0, 0);
    book = GiftBook();
    state = LiveRankState(
      platformBoards: () => const [_online],
      fetch: fetcher.call,
      giftRanking: book.ranking,
      now: () => now,
    );
  });
  tearDown(Get.reset);

  Future<void> pumpPanel(
    WidgetTester tester, {
    void Function(LiveRankItem item)? onTap,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: LiveRankPanel(state: state, onTapItem: onTap ?? (_) {}),
        ),
      ),
    );
    // 打开时读一次
    await tester.pump();
    await tester.pump();
  }

  /// 礼物页（礼物 | 榜单），“显示榜单”看 [settings]
  Widget giftPage(AppSettingsController settings, RxBool rankSelected) =>
      GiftPageView(
        showRank: () => settings.liveRankTab.value,
        rankSelected: rankSelected,
        gifts: (leading) => GiftListView(
          book: book,
          version: 0.obs,
          paidOnly: false.obs,
          leading: leading,
        ),
        rank: (leading) => LiveRankPanel(
          state: state,
          leading: leading,
          onTapItem: (_) {},
        ),
      );

  group("礼物页里的榜单", () {
    testWidgets("标签还是“礼物”；左边的“榜单”按钮切到榜单、再点回到礼物；关掉“显示榜单”后没有这个按钮",
        (tester) async {
      var settings = Get.put<AppSettingsController>(_TestSettings());
      var rankSelected = false.obs;
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var tabs = liveRoomTabs(superChat: true, gifts: true);
      // 榜单不再是单独的标签
      expect(LiveRoomTab.values.map((e) => e.name), isNot(contains("rank")));
      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: DefaultTabController(
              length: tabs.length,
              initialIndex: tabs.indexOf(LiveRoomTab.gifts),
              child: Column(
                children: [
                  AdaptiveTabBar(
                    tabs: [for (var t in tabs) liveRoomTabLabel(t)],
                  ),
                  Expanded(child: giftPage(settings, rankSelected)),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // 标签只有“礼物”；礼物页的按钮行：左边“榜单”，右边只看付费、排序
      expect(find.text("礼物"), findsOneWidget);
      expect(find.text("榜单"), findsOneWidget);
      expect(find.byType(GiftListView), findsOneWidget);
      expect(find.text("还没有收到礼物"), findsOneWidget);
      double left(Finder f) => tester.getTopLeft(f).dx;
      expect(left(find.text("榜单")), lessThan(left(find.text("只看付费"))));
      expect(left(find.text("榜单")), lessThan(40));
      var pill = tester.widget<FloatingPill>(
        find.ancestor(of: find.text("榜单"), matching: find.byType(FloatingPill)),
      );
      expect(pill.selected, isFalse);
      expect(fetcher.calls, 0);

      await tester.tap(find.text("榜单"));
      await tester.pump();
      await tester.pump();
      expect(rankSelected.value, isTrue);
      expect(find.byType(LiveRankPanel), findsOneWidget);
      expect(fetcher.calls, 1);
      expect(find.text("观众1"), findsOneWidget);
      // 看榜单时“榜单”高亮，还在最左边；再点一下回到礼物
      pill = tester.widget<FloatingPill>(
        find.ancestor(of: find.text("榜单"), matching: find.byType(FloatingPill)),
      );
      expect(pill.selected, isTrue);
      expect(left(find.text("榜单")), lessThan(40));
      await tester.tap(find.text("榜单"));
      await tester.pump();
      expect(rankSelected.value, isFalse);
      expect(find.byType(GiftListView), findsOneWidget);

      // 关掉“显示榜单”：没有这个按钮，看榜单时也回到礼物
      rankSelected.value = true;
      settings.liveRankTab.value = false;
      await tester.pump();
      expect(find.byType(RankViewButton), findsNothing);
      expect(find.byType(GiftListView), findsOneWidget);
      expect(find.text("榜单"), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets("点在线人数：切到礼物页的榜单；关掉“显示榜单”后点不了", (tester) async {
      var settings = Get.put<AppSettingsController>(_TestSettings());
      var rankSelected = false.obs;
      var jumps = StreamController<LiveRoomTab>.broadcast();
      addTearDown(jumps.close);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var tabs = liveRoomTabs(superChat: false, gifts: true);
      // 和直播间的 openRank 一样：先切到榜单，再切到礼物页
      void openRank() {
        rankSelected.value = true;
        jumps.add(LiveRoomTab.gifts);
      }

      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Obx(
                  () => OnlineCountTap(
                    onTap: settings.liveRankTab.value ? openRank : null,
                    child: const Text("1.2万"),
                  ),
                ),
                Expanded(
                  child: DefaultTabController(
                    length: tabs.length,
                    child: Column(
                      children: [
                        LiveRoomTabJumper(
                          tabs: tabs,
                          jumps: jumps.stream,
                          child: const SizedBox.shrink(),
                        ),
                        AdaptiveTabBar(
                          tabs: [for (var t in tabs) liveRoomTabLabel(t)],
                        ),
                        Expanded(
                          child: TabBarView(
                            children: [
                              for (var t in tabs)
                                t == LiveRoomTab.gifts
                                    ? giftPage(settings, rankSelected)
                                    : Center(child: Text("页面 ${t.name}")),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text("页面 chat"), findsOneWidget);
      await tester.tap(find.text("1.2万"));
      await tester.pumpAndSettle();
      expect(find.text("页面 chat"), findsNothing);
      expect(find.byType(LiveRankPanel), findsOneWidget);
      expect(fetcher.calls, 1);

      // 关掉以后：在线人数只是文字
      settings.liveRankTab.value = false;
      await tester.pump();
      expect(
        find.ancestor(of: find.text("1.2万"), matching: find.byType(InkWell)),
        findsNothing,
      );
    });
  });

  group("刷新和更新时间", () {
    testWidgets("打开时读一次；点刷新再读，更新时间跟着变", (tester) async {
      await pumpPanel(tester);
      expect(fetcher.calls, 1);
      expect(find.textContaining("更新于 20:00:00"), findsOneWidget);
      expect(find.textContaining("共 45 人"), findsOneWidget);
      expect(find.textContaining("前几名实时更新"), findsOneWidget);
      expect(find.text("观众1"), findsOneWidget);

      now = DateTime(2026, 11, 15, 20, 5, 30);
      fetcher.next = () => people(prefix: "新观众");
      await tester.tap(find.byTooltip("刷新榜单"));
      await tester.pump();
      await tester.pump();
      expect(fetcher.calls, 2);
      expect(find.textContaining("更新于 20:05:30"), findsOneWidget);
      expect(find.text("新观众1"), findsOneWidget);
      expect(find.text("观众1"), findsNothing);
    });

    testWidgets("下拉也会刷新；失败时留着上次的榜单并说明", (tester) async {
      await pumpPanel(tester);
      fetcher.error = CoreError("网络不通");
      await tester.fling(
          find.byType(CustomScrollView), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(fetcher.calls, 2);
      expect(find.textContaining("刷新失败"), findsOneWidget);
      expect(find.textContaining("网络不通"), findsOneWidget);
      expect(find.text("观众1"), findsOneWidget);
      expect(find.textContaining("更新于 20:00:00"), findsOneWidget);
    });

    testWidgets("第一次就失败：显示原因和重试", (tester) async {
      fetcher.error = CoreError("房间不存在");
      await pumpPanel(tester);
      expect(find.textContaining("房间不存在"), findsOneWidget);
      // 失败后不会自己一直重试
      await tester.pump();
      expect(fetcher.calls, 1);
      fetcher.error = null;
      await tester.tap(find.text("重试"));
      await tester.pump();
      await tester.pump();
      expect(fetcher.calls, 2);
      expect(find.text("观众1"), findsOneWidget);
    });

    testWidgets("推送的前几名并进去，更新时间不变", (tester) async {
      await pumpPanel(tester);
      state.applyUpdate(
        const LiveRankUpdate("online", [
          LiveRankItem(rank: 1, userName: "观众5", userId: "5", score: 2000),
        ]),
      );
      await tester.pump();
      var first = state.currentData.items.first;
      expect(first.userName, "观众5");
      expect(state.currentData.items[1].userName, "观众1");
      expect(find.textContaining("更新于 20:00:00"), findsOneWidget);
    });

    testWidgets("本场礼物榜按收到的礼物算，换榜单时读一次", (tester) async {
      book.add(LiveGiftMessage(
        userName: "送礼甲",
        userId: "9",
        giftName: "小心心",
        priceText: "¥5",
      ));
      await pumpPanel(tester);
      // 榜单种类是一排小按钮（短名字，提示里是完整的名字）
      expect(find.text("贡献榜"), findsOneWidget);
      await tester.tap(find.byTooltip("本场礼物榜"));
      await tester.pump();
      await tester.pump();
      var gifts = tester.widget<RankSquareButton>(
        find.ancestor(
          of: find.text("礼物榜"),
          matching: find.byType(RankSquareButton),
        ),
      );
      expect(gifts.selected, isTrue);
      expect(find.text("送礼甲"), findsOneWidget);
      expect(find.text("¥5"), findsNothing);
      expect(find.textContaining("按进入直播间后收到的付费礼物计算"), findsOneWidget);
      expect(fetcher.calls, 1);
    });
  });

  testWidgets("静止时榜单从按钮下面再空一点开始", (tester) async {
    await pumpPanel(tester);
    await tester.pump();
    var buttons = tester.getRect(find.byType(LiveRankHeader));
    var info = tester.getRect(find.byType(LiveRankInfo));
    expect(info.top - buttons.bottom, greaterThanOrEqualTo(10));
    // 筛选是小按钮，不是大的 chip：榜单种类是文字按钮，只看前十是“10”，粉丝牌是图标
    expect(find.byType(FilterChip), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    // 两个榜单、10、粉丝牌、刷新：五个一样高的小按钮，没有下拉菜单
    expect(find.byType(RankSquareButton), findsNWidgets(5));
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    for (var tip in ["在线贡献榜", "本场礼物榜", "只看前十", "只看有粉丝牌的", "刷新榜单"]) {
      var box = tester.getRect(
        find.descendant(
          of: find.byTooltip(tip),
          matching: find.byType(Material),
        ),
      );
      expect(box.height, 32, reason: tip);
    }
    expect(
      find.descendant(
        of: find.byType(RankSquareButton),
        matching: find.text("10"),
      ),
      findsOneWidget,
    );
    var square = tester.getRect(
      find.descendant(
        of: find.byTooltip("只看前十"),
        matching: find.byType(Material),
      ),
    );
    expect(square.width, 32);
    expect(square.height, 32);
    expect(find.byTooltip("只看前十"), findsOneWidget);
    expect(find.byTooltip("只看有粉丝牌的"), findsOneWidget);
  });

  group("筛选", () {
    testWidgets("只看前十", (tester) async {
      await pumpPanel(tester);
      expect(state.visible.length, 12);
      await tester.tap(find.byTooltip("只看前十"));
      await tester.pump();
      expect(state.topTen.value, isTrue);
      expect(state.visible.length, 10);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pump();
      expect(find.text("观众10"), findsOneWidget);
      expect(find.text("观众11", skipOffstage: false), findsNothing);
      expect(find.text("观众12", skipOffstage: false), findsNothing);
    });

    testWidgets("只看有粉丝牌的", (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.byTooltip("只看有粉丝牌的"));
      await tester.pump();
      expect(state.visible.every((e) => e.hasMedal), isTrue);
      expect(state.visible.length, 6);
      expect(find.text("观众2"), findsNothing);
      expect(find.text("观众1"), findsOneWidget);
      // 两个一起：前十里戴着牌子的
      await tester.tap(find.byTooltip("只看前十"));
      await tester.pump();
      expect(state.visible.map((e) => e.rank), [1, 3, 5, 7, 9]);
    });

    testWidgets("榜单上没人戴牌子时没有“只看有粉丝牌的”", (tester) async {
      fetcher.next = () => [
            const LiveRankItem(rank: 1, userName: "甲", score: 3),
            const LiveRankItem(rank: 2, userName: "乙", score: 2),
          ];
      await pumpPanel(tester);
      expect(find.byTooltip("只看前十"), findsOneWidget);
      expect(find.byTooltip("只看有粉丝牌的"), findsNothing);
    });
  });

  group("点一行打开用户卡片", () {
    late ChatUsersService service;
    late RoomUserBlocks blocks;

    setUp(() async {
      service = Get.put(
        ChatUsersService(
            storage: MemoryChatUsersStorage(), purgeInterval: null),
      );
      await service.init();
      blocks = RoomUserBlocks(
        siteId: () => "bilibili",
        roomId: () => "100",
        roomLabel: () => "主播",
      );
    });
    tearDown(() => service.onClose());

    void openCard(LiveRankItem item) => showChatUserCard(
          user: ChatUser("bilibili", userId: item.userId, name: item.userName),
          blocks: blocks,
          body: (_) => RankCardBody(item, _online),
        );

    testWidgets("列表里的一行：卡片上是这个人、名次和分数，可以屏蔽", (tester) async {
      var tapped = <LiveRankItem>[];
      await pumpPanel(tester, onTap: (item) {
        tapped.add(item);
        openCard(item);
      });
      await tester.tap(find.text("观众5"));
      await tester.pumpAndSettle();
      expect(tapped.single.userId, "5");
      expect(find.byType(ChatUserCard), findsOneWidget);
      expect(
        find.descendant(
            of: find.byType(ChatUserCard), matching: find.text("观众5")),
        findsOneWidget,
      );
      expect(find.textContaining("在线贡献榜第 5 名"), findsOneWidget);
      expect(find.textContaining("贡献值 995"), findsOneWidget);
      // 有用户 ID：可以屏蔽
      expect(find.text("屏蔽这个人"), findsOneWidget);
      expect(find.text(ChatUserCard.noIdHint("bilibili")), findsNothing);
    });

    testWidgets("领奖台上的人也能点；没有 ID 时说明不能屏蔽", (tester) async {
      fetcher.next = () => [
            const LiveRankItem(rank: 1, userName: "神秘人", score: 30),
            const LiveRankItem(rank: 2, userName: "乙", userId: "2", score: 20),
          ];
      var tapped = <LiveRankItem>[];
      await pumpPanel(tester, onTap: (item) {
        tapped.add(item);
        openCard(item);
      });
      await tester.tap(find.byKey(const ValueKey("rank_podium_0")));
      await tester.pumpAndSettle();
      expect(tapped.single.userName, "神秘人");
      expect(find.text(ChatUserCard.noIdHint("bilibili")), findsOneWidget);
    });
  });
}
