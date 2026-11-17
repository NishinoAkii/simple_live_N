import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_chat_search.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_page.dart';
import 'package:simple_live_app/modules/live_room/room_notice.dart';
import 'package:simple_live_app/modules/live_room/room_notice_card.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/widgets/compact_buttons.dart';
import 'package:simple_live_app/widgets/tail_list_view.dart';
import 'package:simple_live_core/simple_live_core.dart';

import '../fakes/fake_player.dart';
import '../fakes/memory_storage.dart';
import 'layout_matrix.dart';

// 聊天区顶上的直播间公告卡片的布局检查。用的是直播间页面真的聊天列表
// （LiveRoomPage.buildChatList：列表、“最新”按钮、浮在上面的卡片），外面按三种放法摆：
// 手机竖屏（播放器下面）、横屏和电脑（右边的侧栏，默认 300、最窄 240，拉宽到 450、500）。
// 标题和公告都写得很长，中文、英文各一份；展开、收起各查一遍，卡片不能盖住消息。
// 带上右上角浮动按钮（LiveChatSearchView）时再查卡片里的字有没有压到按钮

/// 不读 Hive 的设置（改动照样记到 [MemoryStorage] 里）
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _Room extends LiveRoomController {
  _Room()
      : super(
          pSite: Site(id: "test", liveSite: LiveSite(), logo: "", name: "测试"),
          pRoomId: "1",
        );

  @override
  // ignore: overridden_fields
  final Player player = FakePlayer();

  // 不读房间信息、不连弹幕
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  // ignore: must_call_super
  void onClose() {}
}

const _title = "【钢之魂】雾锁王国 标题也写得特别特别长的一场直播，看看两行放不放得下";
const _enTitle =
    "[DROPS ON] UNBANNED goat run, hardcore World of Warcraft day 12 !drops";
const _enBody = "World of Warcraft goat sex bird man. "
    "Streams every night from eight to nine, weekends are long sessions.";
const _body = "直播时间为每晚8~9点开播时令大作为主。午夜以昏睡游戏为主，白天偶尔突击游戏日常。";
final _longBody = [
  for (var i = 1; i <= 12; i++) "第 $i 条：$_body",
  "https://example.com/a/very/long/link/without/any/space/in/it/at/all/0123456789",
].join("\n");
final _longEnBody = [
  for (var i = 1; i <= 8; i++) "$i. $_enBody",
  "https://example.com/a/very/long/link/without/any/space/in/it/at/all/0123456789",
].join("\n");

/// 开播了 1 小时 2 分 3 秒
String _startedAgo() =>
    "${DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3723}";

final _clock = RegExp(r"^\d\d:\d\d:\d\d$");

LiveRoomDetail _detail({
  String title = _title,
  String notice = _body,
  bool live = true,
}) =>
    LiveRoomDetail(
      roomId: "1",
      title: title,
      cover: "",
      userName: "主播",
      userAvatar: "",
      online: 0,
      status: live,
      url: "",
      notice: notice,
      showTime: live ? _startedAgo() : null,
    );

void main() {
  late _Room room;
  late MemoryStorage storage;
  late AppSettingsController settings;

  setUp(() {
    Get.testMode = true;
    storage = MemoryStorage.install();
    settings = Get.put<AppSettingsController>(_TestSettings());
    room = Get.put<LiveRoomController>(_Room()) as _Room;
    // 在播，卡片上有开播时长那一行
    room.liveStatus.value = true;
    room.roomNotice.update(_detail());
  });
  tearDown(() {
    room.chatLog.dispose();
    Get.reset();
  });

  void addMessages(int n) {
    for (var i = 0; i < n; i++) {
      room.addSysMsg("消息 ${room.chatLog.length}");
    }
  }

  /// 直播间页面真的聊天列表
  Widget chat() => const LiveRoomPage().buildChatList();

  /// 手机竖屏：播放器、主播信息和标签栏、聊天区、输入栏
  Widget portrait() => Column(
        children: [
          const AspectRatio(
              aspectRatio: 16 / 9, child: ColoredBox(color: Colors.black)),
          const SizedBox(height: 110),
          Expanded(child: chat()),
          const SizedBox(height: 56),
        ],
      );

  /// 横屏、平板、电脑：右边的侧栏
  Widget side(double width) => Row(
        children: [
          const Expanded(child: ColoredBox(color: Colors.black)),
          SizedBox(
            width: width,
            child: Column(
              children: [
                const SizedBox(height: 100),
                Expanded(child: chat()),
              ],
            ),
          ),
        ],
      );

  /// 卡片显示着时没盖住消息：一屏放得下时所有消息都在卡片下面；
  /// 放不下时（聊天区很矮）更早的从卡片下面滚过，最新的一条在卡片下面看得到
  void expectClear(WidgetTester tester, {String reason = ""}) {
    var card = find.byType(RoomNoticeCard);
    if (card.evaluate().isEmpty) {
      return;
    }
    var fits = room.chatList.scrollController.position.maxScrollExtent < 0.5;
    var first = fits ? "消息 0" : "消息 ${room.chatLog.length - 1}";
    expectBelow(tester, card, find.text(first), reason: reason);
    // 卡片在聊天区里面，没伸出去
    var area = tester.getRect(find.byType(TailListView));
    var rect = tester.getRect(card);
    expect(rect.left, greaterThanOrEqualTo(area.left), reason: reason);
    expect(rect.right, lessThanOrEqualTo(area.right + 0.5), reason: reason);
    expect(rect.bottom, lessThanOrEqualTo(area.bottom + 0.5), reason: reason);
  }

  Future<void> pumpAt(
    WidgetTester tester,
    Size size,
    Widget child, {
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(GetMaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(body: child),
    ));
    // 卡片量出高度后列表再排一次
    await tester.pump();
    await tester.pump();
  }

  // 在播（有开播时长那一行）和没开播（没有那一行）各查一遍；公告中文、英文各一份
  for (var live in [true, false]) {
    for (var folded in [false, true]) {
      for (var latin in [false, true]) {
        var state = "${live ? "在播" : "没开播"}，${folded ? "收起" : "展开"}，"
            "${latin ? "英文" : "中文"}";
        LiveRoomDetail detail() => latin
            ? _detail(title: _enTitle, notice: _longEnBody, live: live)
            : _detail(notice: _longBody, live: live);

        testWidgets("$state：手机竖屏，各种尺寸、语言、缩放都放得下", (tester) async {
          settings.chatNoticeFolded.value = folded;
          room.liveStatus.value = live;
          room.roomNotice.update(detail());
          // 当作用户点开的：新消息不让展开的卡片自己收起
          room.roomNotice.keepOpen = true;
          addMessages(3);
          var problems = await layoutMatrix(
            tester,
            portrait,
            sizes: layoutSizes.where((s) => s.height > s.width),
          );
          expect(problems, isEmpty);
          var card = find.byType(RoomNoticeCard);
          expect(card, findsOneWidget);
          expect(
            find.descendant(of: card, matching: find.textContaining(_clock)),
            live ? findsOneWidget : findsNothing,
          );
          expectClear(tester, reason: state);
        });

        testWidgets("$state：横屏、平板、电脑的侧栏（最窄的 240、默认的 300、拉宽的 450 和 500）",
            (tester) async {
          settings.chatNoticeFolded.value = folded;
          room.liveStatus.value = live;
          room.roomNotice.update(detail());
          // 当作用户点开的：新消息不让展开的卡片自己收起
          room.roomNotice.keepOpen = true;
          addMessages(3);
          for (var width in [300.0, 240.0, 450.0, 500.0]) {
            var problems = await layoutMatrix(
              tester,
              () => side(width),
              // 窗口比侧栏宽才放得下
              sizes: layoutSizes
                  .where((s) => s.width > s.height && s.width > width + 100),
            );
            expect(problems, isEmpty, reason: "侧栏 $width");
            expectClear(tester, reason: "$state 侧栏 $width");
          }
        });
      }
    }
  }

  testWidgets("只有标题、没有公告也显示；深色主题", (tester) async {
    room.roomNotice.update(_detail(title: "只有标题", notice: ""));
    addMessages(2);
    await pumpAt(tester, const Size(390, 844), portrait(),
        theme: ThemeData.dark());
    expect(tester.takeException(), isNull);
    expect(find.text("只有标题"), findsOneWidget);
    expect(find.text("显示全部"), findsNothing);
    expectClear(tester);
  });

  testWidgets("展开：标题、公告、开播时长；左边的按钮收起成小条，点小条再展开，状态记在本机", (tester) async {
    addMessages(3);
    await pumpAt(tester, const Size(1280, 720), side(450));
    var card = find.byType(RoomNoticeCard);
    expect(find.text(_title), findsOneWidget);
    expect(find.text(_body), findsOneWidget);
    // 开播了 1 小时 2 分多
    var time = find.descendant(of: card, matching: find.textContaining(_clock));
    expect(time, findsOneWidget);
    expect(tester.widget<Text>(time).data, startsWith("01:02:0"));
    var expanded = tester.getRect(card);
    // 占满侧栏的宽度，在聊天区最上面
    var area = tester.getRect(find.byType(TailListView));
    expect(expanded.top, area.top + 4);
    expect(expanded.width, 450 - 16);
    // 收起按钮在卡片左边
    var fold = find.byIcon(Icons.keyboard_arrow_up);
    expect(tester.getCenter(fold).dx, lessThan(expanded.left + 40));
    expectClear(tester);
    var firstMessage = tester.getTopLeft(find.text("消息 0")).dy;

    await tester.tap(fold);
    await tester.pump();
    await tester.pump();
    expect(settings.chatNoticeFolded.value, isTrue);
    expect(storage.values[LocalStorageService.kChatNoticeFolded], true);
    expect(find.text(_body), findsNothing);
    expect(find.text(_title), findsOneWidget);
    var pill = tester.getRect(card);
    expect(pill.height, lessThan(70));
    // 小条在右上角的浮动按钮左边
    expect(pill.right,
        lessThanOrEqualTo(area.right - kChatFloatButtonsWidth + 0.5));
    // 第一行标题，第二行开播时长
    var pillTime =
        find.descendant(of: card, matching: find.textContaining(_clock));
    expect(pillTime, findsOneWidget);
    expect(tester.getTopLeft(pillTime).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.text(_title)).dy));
    // 展开的箭头在右下角，关闭在它上面
    var down = tester.getCenter(find.byIcon(Icons.keyboard_arrow_down));
    expect(down.dx, greaterThan(pill.center.dx));
    expect(down.dy, greaterThan(pill.center.dy));
    expect(tester.getCenter(find.byIcon(Icons.close)).dy, lessThan(down.dy));
    // 消息跟着上移，仍然在小条下面
    expectClear(tester);
    expect(tester.getTopLeft(find.text("消息 0")).dy, lessThan(firstMessage));

    // 点小条（不只是箭头）展开
    await tester.tap(find.text(_title));
    await tester.pump();
    await tester.pump();
    expect(settings.chatNoticeFolded.value, isFalse);
    expect(find.text(_body), findsOneWidget);
    expectClear(tester);
  });

  testWidgets("关闭：这次进直播间不再显示，消息回到最上面；换直播间后再显示", (tester) async {
    addMessages(3);
    await pumpAt(tester, const Size(1280, 720), side(300));
    expect(find.byType(RoomNoticeCard), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.pump();
    expect(find.byType(RoomNoticeCard), findsNothing);
    expect(room.roomNotice.closed.value, isTrue);
    expect(room.roomNotice.inset.value, 0);
    var area = tester.getRect(find.byType(TailListView));
    expect(tester.getTopLeft(find.text("消息 0")).dy, area.top + 12);
    // 刷新直播间（同一个直播间）还是关着
    room.roomNotice.update(_detail(notice: "新公告"));
    await tester.pump();
    await tester.pump();
    expect(find.byType(RoomNoticeCard), findsNothing);
    // 没有记到设置里
    expect(settings.chatNoticeCard.value, isTrue);

    // 换直播间：读到新信息之前不显示，读到后显示新的
    room.roomNotice.enterRoom();
    await tester.pump();
    expect(find.byType(RoomNoticeCard), findsNothing);
    room.roomNotice.update(_detail(title: "另一个直播间", notice: "新公告"));
    await tester.pump();
    await tester.pump();
    expect(find.text("另一个直播间"), findsOneWidget);
    expect(find.text("新公告"), findsOneWidget);
    expectClear(tester);
  });

  testWidgets("设置里关掉后不显示", (tester) async {
    addMessages(3);
    await pumpAt(tester, const Size(1280, 720), side(300));
    expect(find.byType(RoomNoticeCard), findsOneWidget);
    settings.setChatNoticeCard(false);
    await tester.pump();
    await tester.pump();
    expect(find.byType(RoomNoticeCard), findsNothing);
    expect(room.roomNotice.inset.value, 0);
    settings.setChatNoticeCard(true);
    await tester.pump();
    await tester.pump();
    expect(find.byType(RoomNoticeCard), findsOneWidget);
    expectClear(tester);
  });

  testWidgets("公告很长：先显示几行，点“显示全部”后在卡片里滚动，卡片最多占聊天区六成", (tester) async {
    room.roomNotice.update(_detail(notice: _longBody));
    addMessages(3);
    await pumpAt(tester, const Size(1280, 720), side(300));
    var card = find.byType(RoomNoticeCard);
    var area = tester.getRect(find.byType(TailListView));
    expect(find.text("显示全部"), findsOneWidget);
    expect(
        tester.widget<Text>(find.text(_longBody)).maxLines, kRoomNoticeLines);
    expect(tester.getRect(card).height, lessThanOrEqualTo(area.height * 0.6));
    await tester.tap(find.text("显示全部"));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(settings.chatNoticeFolded.value, isFalse);
    expect(find.text("显示全部"), findsNothing);
    expect(tester.widget<Text>(find.text(_longBody)).maxLines, isNull);
    expect(tester.getRect(card).height, lessThanOrEqualTo(area.height * 0.6));
    expectClear(tester);
    // 短的公告没有“显示全部”
    room.roomNotice.update(_detail());
    await tester.pump();
    await tester.pump();
    expect(find.text("显示全部"), findsNothing);
  });

  testWidgets("消息很多时卡片浮在上面，最新的消息在底下看得到", (tester) async {
    addMessages(200);
    await pumpAt(tester, const Size(1280, 720), side(450));
    var card = tester.getRect(find.byType(RoomNoticeCard));
    var area = tester.getRect(find.byType(TailListView));
    var newest = tester.getRect(find.text("消息 199"));
    expect(newest.bottom, closeTo(area.bottom - 12, 0.5));
    expect(newest.top, greaterThan(card.bottom));
    // 列表占满整个聊天区，卡片盖在它上面
    expect(card.top, area.top + 4);
    expect(find.text("消息 0"), findsNothing);
  });

  testWidgets("最新在上：最新的一条和“最新”按钮都在卡片下面", (tester) async {
    settings.chatNewestAtBottom.value = false;
    addMessages(200);
    await pumpAt(tester, const Size(1280, 720), side(300));
    var card = find.byType(RoomNoticeCard);
    expectBelow(tester, card, find.text("消息 199"));
    // 往下翻看更早的：出现“最新”按钮，在卡片下面
    await tester.drag(find.byType(TailListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(room.chatList.following.value, isFalse);
    expectBelow(tester, card, find.text("最新"));
    // 消息从卡片下面滚过去
    var covered = tester.getRect(find.text("消息 199", skipOffstage: false));
    expect(covered.top, lessThan(tester.getRect(card).bottom));
  });

  testWidgets("聊天区太矮（弹出键盘）时不显示卡片", (tester) async {
    addMessages(2);
    await pumpAt(
      tester,
      const Size(390, 844),
      Column(
        children: [
          const Expanded(child: SizedBox()),
          SizedBox(height: 100, child: chat()),
        ],
      ),
    );
    expect(find.byType(RoomNoticeCard), findsNothing);
    expect(room.roomNotice.inset.value, 0);
  });

  testWidgets("搜索栏展开时右上角没有浮动按钮，标题用整行", (tester) async {
    addMessages(2);
    await pumpAt(tester, const Size(1280, 720), side(450));
    var narrow = tester.getSize(find.text(_title)).width;
    room.chatSearchOpen.value = true;
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(find.text(_title)).width, greaterThan(narrow + 100));
    room.chatSearchOpen.value = false;
  });

  testWidgets("没开播：没有时间那一行，收起的小条只有标题", (tester) async {
    room.liveStatus.value = false;
    room.roomNotice.update(_detail(live: false));
    addMessages(3);
    await pumpAt(tester, const Size(1280, 720), side(300));
    var card = find.byType(RoomNoticeCard);
    var clock =
        find.descendant(of: card, matching: find.textContaining(_clock));
    expect(find.text(_body), findsOneWidget);
    expect(clock, findsNothing);
    // 关闭按钮还在
    expect(find.byIcon(Icons.close), findsOneWidget);
    expectClear(tester);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(clock, findsNothing);
    expect(find.text(_title), findsOneWidget);
    // 只有一行：比带时长的小条矮，关闭和展开并排在标题右边
    var pill = tester.getRect(card);
    expect(pill.height, lessThan(40));
    var title = tester.getRect(find.text(_title));
    var close = tester.getCenter(find.byIcon(Icons.close));
    var down = tester.getCenter(find.byIcon(Icons.keyboard_arrow_down));
    expect(close.dx, greaterThan(title.right));
    expect(down.dx, greaterThan(close.dx));
    expect(close.dy, closeTo(down.dy, 0.5));
    expectClear(tester);
    // 点小条展开，点 × 关闭
    await tester.tap(find.text(_title));
    await tester.pump();
    await tester.pump();
    expect(find.text(_body), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.pump();
    expect(card, findsNothing);
  });

  testWidgets("在播但平台没给开播时间（抖音）、放轮播录像：也没有时间那一行", (tester) async {
    // 平台说在播，没有开播时间
    room.roomNotice.update(LiveRoomDetail(
      roomId: "1",
      title: _title,
      cover: "",
      userName: "主播",
      userAvatar: "",
      online: 0,
      status: true,
      url: "",
      notice: _body,
    ));
    addMessages(2);
    await pumpAt(tester, const Size(1280, 720), side(300));
    var clock = find.descendant(
      of: find.byType(RoomNoticeCard),
      matching: find.textContaining(_clock),
    );
    expect(find.byType(RoomNoticeCard), findsOneWidget);
    expect(clock, findsNothing);
    // 轮播录像：播放器在播（liveStatus），但不算开播
    room.roomNotice.update(LiveRoomDetail(
      roomId: "1",
      title: _title,
      cover: "",
      userName: "主播",
      userAvatar: "",
      online: 0,
      status: false,
      isRecord: true,
      url: "",
      notice: _body,
      showTime: _startedAgo(),
    ));
    await tester.pump();
    await tester.pump();
    expect(clock, findsNothing);
  });

  testWidgets("开播时长每秒跟着走；主播下播后那一行消失", (tester) async {
    addMessages(3);
    await pumpAt(tester, const Size(1280, 720), side(300));
    var card = find.byType(RoomNoticeCard);
    var clock =
        find.descendant(of: card, matching: find.textContaining(_clock));
    var before = tester.widget<Text>(clock).data!;
    var height = tester.getRect(card).height;
    // 真的过一秒多，播放器上的开播时长跳了一下（卡片跟着它刷新）
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1100)),
    );
    room.liveDuration.value = "01:02:05";
    await tester.pump();
    var after = tester.widget<Text>(clock).data!;
    expect(after, isNot(before));
    expect(after.compareTo(before), greaterThan(0));
    expect(after, startsWith("01:02:0"));

    room.liveStatus.value = false;
    await tester.pump();
    await tester.pump();
    expect(clock, findsNothing);
    expect(card, findsOneWidget);
    expect(tester.getRect(card).height, lessThanOrEqualTo(height));
    expectClear(tester);
  });

  // ---- 带上右上角的浮动按钮（导出、排序、搜索）：卡片里的字绕开按钮 ----

  /// 聊天页：实时聊天列表和右上角那排浮动按钮
  Widget chatView() => LiveChatSearchView(controller: room, chatList: chat());

  Widget sideView(double width) => Row(
        children: [
          const Expanded(child: ColoredBox(color: Colors.black)),
          SizedBox(
            width: width,
            child: Column(
              children: [
                const SizedBox(height: 100),
                Expanded(child: chatView()),
              ],
            ),
          ),
        ],
      );

  Widget phoneView() => Column(
        children: [
          const AspectRatio(
              aspectRatio: 16 / 9, child: ColoredBox(color: Colors.black)),
          const SizedBox(height: 110),
          Expanded(child: chatView()),
          const SizedBox(height: 56),
        ],
      );

  Future<void> pumpView(
    WidgetTester tester,
    Size window,
    Widget child, {
    double scale = 1,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(GetMaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (context, widget) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: widget!,
      ),
      home: Scaffold(body: child),
    ));
    await tester.pump();
    await tester.pump();
  }

  void show(String title, String notice, {bool live = true}) {
    room.liveStatus.value = live;
    room.roomNotice.closed.value = false;
    // 当作用户点开的：新消息不让展开的卡片自己收起
    room.roomNotice.autoFolded.value = false;
    room.roomNotice.keepOpen = true;
    room.roomNotice.update(_detail(title: title, notice: notice, live: live));
  }

  /// 浮动按钮看得见的圆（44 的格子里 36 的圆）
  List<Rect> circles(WidgetTester tester) {
    var buttons = find.byType(FloatingRoundButton);
    return [
      for (var i = 0; i < buttons.evaluate().length; i++)
        tester.getRect(buttons.at(i)).deflate(4),
    ];
  }

  /// 按钮的圆的左边、下边
  double circlesLeft(WidgetTester tester) =>
      circles(tester).map((r) => r.left).reduce((a, b) => a < b ? a : b);
  double circlesBottom(WidgetTester tester) =>
      circles(tester).map((r) => r.bottom).reduce((a, b) => a > b ? a : b);

  /// 卡片里的字：每个 Text 的内容和位置，从上到下
  List<(String, Rect)> cardTexts(WidgetTester tester) {
    var texts = find.descendant(
      of: find.byType(RoomNoticeCard),
      matching: find.byType(Text),
    );
    return [
      for (var i = 0; i < texts.evaluate().length; i++)
        (
          tester.widget<Text>(texts.at(i)).data ?? "",
          tester.getRect(texts.at(i))
        ),
    ];
  }

  Rect closeRect(WidgetTester tester) => tester.getRect(find.descendant(
        of: find.byType(RoomNoticeCard),
        matching: find.byIcon(Icons.close),
      ));

  /// 卡片里的字和 × 都不压到浮动按钮的圆；收起的小条整个都在按钮外面；
  /// 卡片在聊天区里、靠左；列表和身份提示用的高度就是卡片的下边
  void expectAroundButtons(WidgetTester tester, {String reason = ""}) {
    var card = find.byType(RoomNoticeCard);
    if (card.evaluate().isEmpty) {
      return;
    }
    var area = tester.getRect(find.byType(TailListView));
    var rect = tester.getRect(card);
    expect(rect.left, area.left + RoomNoticeLayout.side, reason: reason);
    expect(
        rect.right, lessThanOrEqualTo(area.right - RoomNoticeLayout.side + 0.5),
        reason: reason);
    expect(rect.width, lessThanOrEqualTo(RoomNoticeLayout.maxCardWidth + 0.5),
        reason: reason);
    expect(room.roomNotice.inset.value, closeTo(rect.bottom - area.top, 0.5),
        reason: reason);
    var items = [...cardTexts(tester), ("×", closeRect(tester))];
    var folded = settings.chatNoticeFolded.value;
    for (var circle in circles(tester)) {
      for (var (text, r) in items) {
        expect(r.deflate(0.5).overlaps(circle), isFalse,
            reason: "$reason：“$text” $r 压到了浮动按钮 $circle");
      }
      if (folded) {
        expect(rect.deflate(0.5).overlaps(circle), isFalse,
            reason: "$reason：小条 $rect 伸到了浮动按钮 $circle 下面");
      }
    }
  }

  testWidgets("带浮动按钮：各种宽度、缩放、中英文、在播没开播、展开收起，字都不压到按钮，也不溢出", (tester) async {
    addMessages(3);
    var contents = {
      "中文长": (_title, _longBody),
      "中文短": ("【钢之魂】雾锁王国", _body),
      "英文": (_enTitle, _longEnBody),
      "只有标题": ("【钢之魂】雾锁王国", ""),
    };
    var views = <String, (Size, Widget Function())>{
      "手机 360": (const Size(360, 640), phoneView),
      "手机 390": (const Size(390, 844), phoneView),
      for (var w in [
        240.0,
        269.0,
        270.0,
        300.0,
        320.0,
        360.0,
        450.0,
        500.0,
        640.0,
        900.0,
      ])
        "侧栏 ${w.toInt()}": (const Size(1280, 720), () => sideView(w)),
    };
    for (var MapEntry(key: view, value: (window, build)) in views.entries) {
      for (var scale in [1.0, 1.3]) {
        for (var MapEntry(key: name, value: (title, notice))
            in contents.entries) {
          for (var live in [true, false]) {
            for (var folded in [false, true]) {
              var reason = "$view x$scale $name ${live ? "在播" : "没开播"} "
                  "${folded ? "收起" : "展开"}";
              settings.chatNoticeFolded.value = folded;
              show(title, notice, live: live);
              await pumpView(tester, window, build(), scale: scale);
              expect(tester.takeException(), isNull, reason: reason);
              expect(find.byType(RoomNoticeCard), findsOneWidget,
                  reason: reason);
              expectAroundButtons(tester, reason: reason);
            }
          }
        }
      }
    }
  });

  testWidgets("并排时公告绕开按钮：挨着按钮的那行折得短，按钮下面的行用整行（中文）", (tester) async {
    var body = "$_body$_body$_body";
    show("【钢之魂】雾锁王国", body);
    addMessages(2);
    await pumpView(tester, const Size(1280, 720), sideView(450));
    var area = tester.getRect(find.byType(TailListView));
    var card = tester.getRect(find.byType(RoomNoticeCard));
    expect(card.top, area.top + 4);
    expect(card.width, 450 - 16);
    var texts = cardTexts(tester);
    // 标题、挨着按钮的一行、下面的几行、时长
    expect(texts.map((t) => t.$1).toList(),
        ["【钢之魂】雾锁王国", startsWith("直播"), anything, matches(_clock)]);
    var (head, headRect) = texts[1];
    var (tail, tailRect) = texts[2];
    expect(head + tail, body);
    var left = circlesLeft(tester);
    // 挨着按钮的那一行：一行，离按钮的圆至少 6
    expect(headRect.height, closeTo(12.5 * 1.3, 1));
    expect(headRect.right, lessThanOrEqualTo(left - 6 + 0.5));
    // 下面的从按钮的圆下面开始，用到按钮下面那一截
    expect(tailRect.top, greaterThanOrEqualTo(circlesBottom(tester)));
    expect(tailRect.right, greaterThan(left + 60));
    expect(tailRect.right, lessThanOrEqualTo(card.right - 10 + 0.5));
    expect(tailRect.height, greaterThan(12.5 * 1.3 * 2));
    expectAroundButtons(tester);
  });

  testWidgets("并排时公告绕开按钮：英文按词折行，不拆开单词", (tester) async {
    var body = _enBody;
    show("Goat run day 12", body, live: false);
    addMessages(2);
    await pumpView(tester, const Size(1280, 720), sideView(500));
    var texts = cardTexts(tester);
    expect(texts, hasLength(3));
    var (head, headRect) = texts[1];
    var (tail, tailRect) = texts[2];
    expect(head + tail, body);
    // 上一段在词后面断开（末尾是空格），下一段从一个词开始
    expect(head, endsWith(" "));
    expect(tail, matches(RegExp(r"^\w")));
    expect(headRect.right, lessThanOrEqualTo(circlesLeft(tester) - 6 + 0.5));
    expect(tailRect.top, greaterThanOrEqualTo(circlesBottom(tester)));
    expect(tailRect.right, greaterThan(circlesLeft(tester) + 60));
    expectAroundButtons(tester);
  });

  testWidgets("标题两行时公告整个在按钮下面，用整行宽（不再挤在左边）", (tester) async {
    // 用户截图里的样子：标题很长，公告一句英文（测试字体每个字一样宽，侧栏放宽一点才一行放下）
    show(_enTitle, "World of Warcraft goat sex bird man");
    addMessages(2);
    await pumpView(tester, const Size(1280, 720), sideView(560));
    var texts = cardTexts(tester);
    var title = texts.first.$2;
    var body = texts.firstWhere((t) => t.$1.startsWith("World")).$2;
    // 标题两行，在按钮左边
    expect(title.height, closeTo(14 * 1.3 * 2, 1));
    expect(title.right, lessThanOrEqualTo(circlesLeft(tester) - 6 + 0.5));
    // 公告一行放下，伸到按钮下面那一截
    expect(body.height, closeTo(12.5 * 1.3, 1));
    expect(body.top, greaterThanOrEqualTo(circlesBottom(tester)));
    expect(body.right, greaterThan(circlesLeft(tester)));
    expectAroundButtons(tester);
  });

  testWidgets("× 不单独占一行：没开播时跟在最后一行字后面，在播时在时长那一行右边", (tester) async {
    addMessages(2);
    // 没开播，公告一行（挨着按钮）：× 在那一行右端，按钮左边
    show("【钢之魂】雾锁王国", "直播时间为每晚8~9点", live: false);
    await pumpView(tester, const Size(1280, 720), sideView(450));
    var card = tester.getRect(find.byType(RoomNoticeCard));
    var line = cardTexts(tester).last.$2;
    var close = closeRect(tester);
    expect(close.center.dy, closeTo(line.center.dy, 0.5));
    expect(close.left, greaterThan(line.right));
    expect(close.right, lessThanOrEqualTo(circlesLeft(tester) - 6 + 0.5));
    expect(card.bottom - line.bottom, lessThan(12));
    expectAroundButtons(tester);

    // 没开播，公告在按钮下面：× 在最后一行的最右边
    show(_title, _body, live: false);
    await tester.pump();
    await tester.pump();
    card = tester.getRect(find.byType(RoomNoticeCard));
    line = cardTexts(tester).last.$2;
    close = closeRect(tester);
    expect(close.center.dy, closeTo(line.bottom - 12.5 * 1.3 / 2, 0.5));
    expect(close.right, closeTo(card.right - 10, 0.5));
    expect(card.bottom - line.bottom, lessThan(12));
    expectAroundButtons(tester);

    // 在播：× 在时长那一行右边
    show(_title, _body);
    await tester.pump();
    await tester.pump();
    var time = cardTexts(tester).last;
    expect(time.$1, matches(_clock));
    close = closeRect(tester);
    expect(close.center.dy, closeTo(time.$2.center.dy, 0.5));
    expect(close.right, closeTo(card.right - 10, 0.5));
    expectAroundButtons(tester);
  });

  testWidgets("没有公告：展开的卡片只有标题那么宽，靠左，不伸到按钮下面", (tester) async {
    addMessages(2);
    for (var live in [false, true]) {
      show("【钢之魂】雾锁王国", "", live: live);
      await pumpView(tester, const Size(390, 844), phoneView());
      var area = tester.getRect(find.byType(TailListView));
      var card = tester.getRect(find.byType(RoomNoticeCard));
      expect(card.top, area.top + 4);
      expect(card.left, area.left + 8);
      expect(card.width, lessThan(260));
      expect(card.right, lessThanOrEqualTo(circlesLeft(tester) - 6 + 0.5));
      // 收起按钮、标题、×：没开播时 × 跟在标题后面，在播时在时长那一行右边
      var title = tester.getRect(find.text("【钢之魂】雾锁王国"));
      // 标题量出来多宽卡片就多宽，一行放下
      expect(title.height, closeTo(14 * 1.3, 1));
      var close = closeRect(tester);
      if (live) {
        var time = cardTexts(tester).last;
        expect(time.$1, matches(_clock));
        expect(close.center.dy, closeTo(time.$2.center.dy, 0.5));
        expect(close.left, greaterThan(time.$2.right));
      } else {
        expect(close.center.dy, closeTo(title.center.dy, 0.5));
        expect(close.left, greaterThan(title.right));
      }
      expect(close.right, closeTo(card.right - 10, 0.5));
      expectAroundButtons(tester, reason: live ? "在播" : "没开播");
    }
  });

  testWidgets("收起的小条：靠左，只有内容那么宽；挨着按钮时不伸到按钮下面，排到按钮下面时也不占满一行", (tester) async {
    settings.chatNoticeFolded.value = true;
    addMessages(2);
    for (var live in [true, false]) {
      var state = live ? "在播" : "没开播";
      // 并排（450）：短标题只有那么宽，长标题到按钮左边为止
      show("只有标题", _body, live: live);
      await pumpView(tester, const Size(1280, 720), sideView(450));
      var area = tester.getRect(find.byType(TailListView));
      var pill = tester.getRect(find.byType(RoomNoticeCard));
      expect(pill.top, area.top + 4, reason: state);
      expect(pill.left, area.left + 8, reason: state);
      expect(pill.width, lessThan(180), reason: state);
      show(_title, _body, live: live);
      await tester.pump();
      await tester.pump();
      pill = tester.getRect(find.byType(RoomNoticeCard));
      expect(pill.right, lessThanOrEqualTo(circlesLeft(tester) - 6 + 0.5),
          reason: state);
      expectAroundButtons(tester, reason: state);

      // 最窄的侧栏（240）：在按钮下面，靠左，短标题也只有那么宽
      show("只有标题", _body, live: live);
      await pumpView(tester, const Size(1280, 720), sideView(240));
      area = tester.getRect(find.byType(TailListView));
      pill = tester.getRect(find.byType(RoomNoticeCard));
      expect(pill.top, area.top + kChatFloatButtonsBottom, reason: state);
      expect(pill.left, area.left + 8, reason: state);
      expect(pill.width, lessThan(180), reason: state);
      expectAroundButtons(tester, reason: state);

      // 很宽的侧栏：长标题最宽 560
      show(_enTitle * 3, _body, live: live);
      await pumpView(tester, const Size(1280, 720), sideView(900));
      pill = tester.getRect(find.byType(RoomNoticeCard));
      expect(pill.width, RoomNoticeLayout.maxCardWidth, reason: state);
      expectAroundButtons(tester, reason: state);
    }
  });

  testWidgets("侧栏太窄（最窄的 240）：展开的卡片排到按钮下面，占满一行", (tester) async {
    show(_title, _body);
    addMessages(2);
    await pumpView(tester, const Size(1280, 720), sideView(240));
    var area = tester.getRect(find.byType(TailListView));
    var card = tester.getRect(find.byType(RoomNoticeCard));
    expect(card.top, area.top + kChatFloatButtonsBottom);
    expect(card.width, 240 - 16);
    expect(card.top, greaterThanOrEqualTo(circlesBottom(tester)));
    // 不拆开，公告整段用整行
    expect(find.text(_body), findsOneWidget);
    expectAroundButtons(tester);
  });

  testWidgets("标题也绕开按钮：只有第一行挨着按钮时，第二行用整行，加起来还是最多两行", (tester) async {
    // 卡片本身：按钮只挡住第一行的高度
    var title = "$_enTitle $_enTitle";
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 450,
            child: RoomNoticeCard(
              notice: RoomNotice(title: title, body: _body),
              time: null,
              folded: false,
              floatWidth: 130,
              floatHeight: 20,
              onFold: (_) {},
              onClose: () {},
            ),
          ),
        ),
      ),
    ));
    var texts = cardTexts(tester);
    var (head, headRect) = texts[0];
    var (tail, tailRect) = texts[1];
    expect(title, startsWith(head));
    expect(head, endsWith(" "));
    // 第一行按窄的宽度（450 - 左边 34 - 让出的 130），第二行整行（450 - 34 - 右边 10），末尾省略号
    expect(headRect.height, closeTo(14 * 1.3, 1));
    expect(headRect.width, lessThanOrEqualTo(450 - 34 - 130 + 0.5));
    expect(tailRect.height, closeTo(14 * 1.3, 1));
    expect(tailRect.width, greaterThan(450 - 34 - 130 + 20));
    expect(tailRect.width, lessThanOrEqualTo(450 - 34 - 10 + 0.5));
    expect(tester.widget<Text>(find.text(tail)).maxLines, 1);
    expect(
        tester.widget<Text>(find.text(tail)).overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  testWidgets("320 的侧栏（用户的）：收起的小条和展开的卡片都和按钮并排", (tester) async {
    addMessages(2);
    // 展开：占满一行，挨着按钮的字让开
    show(_title, _body);
    await pumpView(tester, const Size(1280, 720), sideView(320));
    var area = tester.getRect(find.byType(TailListView));
    var card = tester.getRect(find.byType(RoomNoticeCard));
    expect(card.top, area.top + 4);
    expect(card.width, 320 - 16);
    expectAroundButtons(tester, reason: "展开");

    // 收起：短标题只有那么宽，在按钮左边
    settings.chatNoticeFolded.value = true;
    show("德云色", _body);
    await pumpView(tester, const Size(1280, 720), sideView(320));
    var pill = tester.getRect(find.byType(RoomNoticeCard));
    expect(pill.top, area.top + 4);
    expect(pill.left, area.left + 8);
    expect(pill.right, lessThanOrEqualTo(circlesLeft(tester) - 6 + 0.5));
    expect(pill.width, lessThan(320 - 16 - (kChatFloatButtonsWidth - 6)));
    expect(
      find.descendant(
        of: find.byType(RoomNoticeCard),
        matching: find.textContaining(_clock),
      ),
      findsOneWidget,
    );
    expectAroundButtons(tester, reason: "收起");
    // 长标题：到按钮左边为止，末尾省略
    show(_title, _body);
    await tester.pump();
    await tester.pump();
    pill = tester.getRect(find.byType(RoomNoticeCard));
    expect(pill.top, area.top + 4);
    expect(pill.width, 320 - 16 - (kChatFloatButtonsWidth - 6));
    expectAroundButtons(tester, reason: "收起，长标题");
  });

  // ---- 聊天列表滚起来后自己收起 ----

  Future<void> settle(WidgetTester tester) async {
    // 列表量出新的高度、卡片收起、列表再按卡片的新高度留白
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  /// 进一个新直播间（和换直播间一样）
  void enter(String title) {
    room.roomNotice.enterRoom();
    room.roomNotice.update(_detail(title: title));
  }

  /// 展开着（左上角有收起按钮）
  bool expanded() => find.byIcon(Icons.keyboard_arrow_up).evaluate().isNotEmpty;

  testWidgets("进直播间时展开；新消息多到一屏放不下、列表滚起来时自己收成小条，不记到设置里", (tester) async {
    enter(_title);
    addMessages(3);
    await pumpView(tester, const Size(1280, 720), sideView(450));
    expect(expanded(), isTrue);
    // 还放得下：不收
    addMessages(3);
    await settle(tester);
    expect(
        room.chatList.scrollController.position.maxScrollExtent, lessThan(0.5));
    expect(expanded(), isTrue);
    // 放不下了，最早的消息开始从卡片下面滚过去：收成小条
    addMessages(60);
    await settle(tester);
    expect(expanded(), isFalse);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    expect(room.roomNotice.autoFolded.value, isTrue);
    expect(settings.chatNoticeFolded.value, isFalse);
    expect(storage.values[LocalStorageService.kChatNoticeFolded], isNull);
    expectAroundButtons(tester);
  });

  testWidgets("最新在上时也一样：列表滚起来后收起", (tester) async {
    settings.chatNewestAtBottom.value = false;
    enter(_title);
    addMessages(3);
    await pumpView(tester, const Size(1280, 720), sideView(450));
    expect(expanded(), isTrue);
    addMessages(60);
    await settle(tester);
    expect(expanded(), isFalse);
    expectBelow(tester, find.byType(RoomNoticeCard), find.text("消息 62"));
  });

  testWidgets("点开的卡片：新消息再多也不收；用户自己滑聊天列表时收起", (tester) async {
    enter(_title);
    addMessages(60);
    await pumpView(tester, const Size(1280, 720), sideView(450));
    await settle(tester);
    expect(expanded(), isFalse);
    // 点小条展开
    await tester.tap(find.text(_title));
    await settle(tester);
    expect(expanded(), isTrue);
    expect(settings.chatNoticeFolded.value, isFalse);
    // 新消息接着来，还是展开着
    addMessages(30);
    await settle(tester);
    expect(expanded(), isTrue);
    expectClear(tester);
    // 用户自己往上翻看：收起
    await tester.drag(find.byType(TailListView), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(room.chatList.following.value, isFalse);
    expect(expanded(), isFalse);
    expect(settings.chatNoticeFolded.value, isFalse);
    // 再点开，又能看到公告
    await tester.tap(find.text(_title));
    await settle(tester);
    expect(expanded(), isTrue);
  });

  testWidgets("用户自己收起的，下次进直播间还是收起；点开以后下次进来展开", (tester) async {
    enter(_title);
    addMessages(3);
    await pumpView(tester, const Size(1280, 720), sideView(450));
    expect(expanded(), isTrue);
    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await settle(tester);
    expect(settings.chatNoticeFolded.value, isTrue);
    expect(storage.values[LocalStorageService.kChatNoticeFolded], true);

    enter("另一个直播间");
    await settle(tester);
    expect(expanded(), isFalse);
    expect(find.text("另一个直播间"), findsOneWidget);
    await tester.tap(find.text("另一个直播间"));
    await settle(tester);
    expect(expanded(), isTrue);
    expect(settings.chatNoticeFolded.value, isFalse);

    enter("第三个直播间");
    await settle(tester);
    expect(expanded(), isTrue);
  });
}
