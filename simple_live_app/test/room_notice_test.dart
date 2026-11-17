import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/modules/live_room/room_notice.dart';
import 'package:simple_live_app/modules/live_room/room_notice_card.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_app/widgets/tail_list_view.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'fakes/memory_storage.dart';

// 聊天区顶上的直播间公告卡片：显示什么、开播时长怎么写、卡片放哪里、设置只存本机。
// 卡片的样子和各种尺寸下的布局在 layout/room_notice_layout_test.dart

LiveRoomDetail detail({
  String title = "【钢之魂】雾锁王国",
  String? notice,
  String? introduction,
  bool status = true,
  bool isRecord = false,
  String? showTime,
}) =>
    LiveRoomDetail(
      roomId: "1",
      title: title,
      cover: "",
      userName: "主播",
      userAvatar: "",
      online: 0,
      status: status,
      isRecord: isRecord,
      url: "",
      notice: notice,
      introduction: introduction,
      showTime: showTime,
    );

/// 不读 Hive 的设置（改动照样记到 [MemoryStorage] 里）
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  group("显示什么", () {
    test("哔哩哔哩：有公告用公告，简介不显示", () {
      var notice = RoomNotice.of(detail(
        notice: "每天晚上21:00开播 除了周一是24:00开播！",
        introduction: "<p>简介</p>",
      ));
      expect(notice.title, "【钢之魂】雾锁王国");
      expect(notice.body, "每天晚上21:00开播 除了周一是24:00开播！");
      expect(notice.isEmpty, isFalse);
    });

    test("哔哩哔哩：没写公告时用简介（HTML 变成纯文字）", () {
      var notice = RoomNotice.of(detail(
        notice: "",
        introduction: "<p>这里是哔哩哔哩官方音乐台喔！</p><p>一起来听音乐吧</p>\n",
      ));
      expect(notice.body, "这里是哔哩哔哩官方音乐台喔！\n一起来听音乐吧");
    });

    test("斗鱼、抖音、Twitch、Kick、YouTube：公告是空的，用简介", () {
      expect(
        RoomNotice.of(detail(notice: "", introduction: "每天下午两点开播\n\n周一休息"))
            .body,
        "每天下午两点开播\n周一休息",
      );
      expect(
        RoomNotice.of(detail(notice: "", introduction: "Just Chatting\nbio"))
            .body,
        "Just Chatting\nbio",
      );
    });

    test("虎牙：简介就是标题，不重复；公告是 \"null\" 时当作没有", () {
      var notice = RoomNotice.of(detail(
        title: "王者荣耀 巅峰赛",
        introduction: "王者荣耀 巅峰赛",
        notice: "null",
      ));
      expect(notice.title, "王者荣耀 巅峰赛");
      expect(notice.body, "");
      expect(notice.isEmpty, isFalse);
      expect(
        RoomNotice.of(detail(
          title: "王者荣耀 巅峰赛",
          introduction: "王者荣耀 巅峰赛",
          notice: "欢迎来到直播间",
        )).body,
        "欢迎来到直播间",
      );
    });

    test("直播源没给公告和简介（null）；标题也没有时不显示卡片", () {
      expect(RoomNotice.of(detail()).body, "");
      var empty = RoomNotice.of(detail(title: " ", notice: null));
      expect(empty.isEmpty, isTrue);
      expect(RoomNotice.of(detail(title: "null")).isEmpty, isTrue);
    });

    test("内容一样算同一条（刷新直播间不会重画）", () {
      expect(RoomNotice.of(detail(notice: "a")),
          RoomNotice.of(detail(notice: "a")));
      expect(
        RoomNotice.of(detail(notice: "a")) ==
            RoomNotice.of(detail(notice: "b")),
        isFalse,
      );
    });
  });

  group("开播时长", () {
    test("在播、平台给了开播时间（秒）：记下开播时间", () {
      var notice = RoomNotice.of(detail(showTime: "1794640857"));
      expect(
        notice.liveStart,
        DateTime.fromMillisecondsSinceEpoch(1794640857 * 1000),
      );
    });

    test("没开播、放轮播录像、平台没给开播时间：没有时间", () {
      expect(
        RoomNotice.of(detail(status: false, showTime: "1794640857")).liveStart,
        isNull,
      );
      expect(
        RoomNotice.of(
          detail(status: false, isRecord: true, showTime: "1794640857"),
        ).liveStart,
        isNull,
      );
      for (var showTime in [null, "", "0", "abc", "-5"]) {
        expect(
          RoomNotice.of(detail(showTime: showTime)).liveStart,
          isNull,
          reason: "$showTime",
        );
      }
    });

    test("写成 HH:mm:ss，超过一天接着往上加", () {
      var start = DateTime(2026, 11, 16, 20, 30);
      String at(DateTime now) => roomLiveDurationText(start, now: now);
      expect(at(DateTime(2026, 11, 17, 5, 16, 3)), "08:46:03");
      expect(at(DateTime(2026, 11, 17, 5, 17, 49)), "08:47:49");
      expect(at(start), "00:00:00");
      expect(at(DateTime(2026, 11, 16, 20, 30, 59)), "00:00:59");
      expect(at(DateTime(2026, 11, 21, 0, 30, 1)), "100:00:01");
      // 本机的钟比平台慢时不出现负数
      expect(at(DateTime(2026, 11, 16, 20, 29)), "00:00:00");
    });
  });

  group("一个直播间里的状态", () {
    test("读到房间信息后有内容；换直播间：先清掉，关掉的重新显示", () {
      var state = RoomNoticeState();
      expect(state.notice.value, isNull);
      state.update(detail(notice: "公告"));
      expect(state.notice.value!.body, "公告");
      state.closed.value = true;
      state.enterRoom();
      expect(state.notice.value, isNull);
      expect(state.closed.value, isFalse);
      // 还没读到新直播间的信息
      state.update(null);
      expect(state.notice.value, isNull);
    });
  });

  group("卡片放哪里", () {
    const phone = Size(390, 300);
    // 浮动按钮的圆（再空 6）从卡片右边伸进来多宽；圆的下边离卡片上边多远
    const float = kChatFloatButtonsWidth - 6;
    const band = kChatFloatButtonsBottom - 8;
    double topOf(double width, {bool folded = false, double scale = 1}) =>
        RoomNoticeLayout.of(
          Size(width, 500),
          folded: folded,
          textScale: scale,
        )!
            .top;

    test("够宽：和右上角的浮动按钮并排，展开的卡片占满一行，挨着按钮的那几行字让开", () {
      var layout = RoomNoticeLayout.of(phone, folded: false)!;
      expect(layout.top, 4);
      expect(layout.maxWidth, 390 - 16);
      expect(layout.floatWidth, float);
      expect(layout.floatHeight, band);
      // 最多占六成
      expect(layout.maxHeight, closeTo((300 - 4) * 0.6, 0.01));
    });

    test("够宽：收起的小条在浮动按钮左边", () {
      var layout = RoomNoticeLayout.of(phone, folded: true)!;
      expect(layout.top, 4);
      expect(layout.maxWidth, 390 - 16 - float);
      expect(layout.floatWidth, 0);
      expect(layout.floatHeight, 0);
    });

    test("按钮左边空出的地方不到 124（三个按钮那么宽）：整张卡片排到浮动按钮下面，占满一行", () {
      // 最窄的侧栏
      for (var folded in [true, false]) {
        var layout = RoomNoticeLayout.of(const Size(240, 500), folded: folded)!;
        expect(layout.top, kChatFloatButtonsBottom);
        expect(layout.maxWidth, 240 - 16);
        expect(layout.floatWidth, 0);
        expect(layout.floatHeight, 0);
      }
      // 按钮左边空出的 = 聊天区宽 - 两边的 16 - 让给按钮的；正好 124 时还并排。
      // 不看标题多长，收起、展开一个规矩
      expect(270 - 16 - float, RoomNoticeLayout.minBesideRoom);
      for (var folded in [true, false]) {
        expect(topOf(270, folded: folded), 4);
        expect(topOf(269, folded: folded), kChatFloatButtonsBottom);
        // 默认的 300、用户的 320 都并排
        expect(topOf(300, folded: folded), 4);
        expect(topOf(320, folded: folded), 4);
        // 字放大 1.3 倍，要的地方也大 1.3 倍（161）
        expect(topOf(310, folded: folded, scale: 1.3), 4);
        expect(topOf(305, folded: folded, scale: 1.3), kChatFloatButtonsBottom);
      }
    });

    test("320 的侧栏：收起的小条在按钮左边，最宽到按钮为止；展开的卡片占满一行，挨着按钮的字让开", () {
      var pill = RoomNoticeLayout.of(const Size(320, 500), folded: true)!;
      expect(pill.top, 4);
      expect(pill.maxWidth, 320 - 16 - float);
      expect(pill.floatWidth, 0);
      var card = RoomNoticeLayout.of(const Size(320, 500), folded: false)!;
      expect(card.top, 4);
      expect(card.maxWidth, 320 - 16);
      expect(card.floatWidth, float);
      expect(card.floatHeight, band);
    });

    test("最宽 560，靠左放；聊天区很宽时浮动按钮碰不到卡片", () {
      var wide = RoomNoticeLayout.of(const Size(1000, 500), folded: false)!;
      expect(wide.top, 4);
      expect(wide.maxWidth, RoomNoticeLayout.maxCardWidth);
      expect(wide.floatWidth, 0);
      expect(wide.floatHeight, 0);
      expect(
        RoomNoticeLayout.of(const Size(1000, 500), folded: true)!.maxWidth,
        RoomNoticeLayout.maxCardWidth,
      );
      // 差一点碰到：只让出伸进来的那一截
      var near = RoomNoticeLayout.of(const Size(650, 500), folded: false)!;
      expect(near.maxWidth, RoomNoticeLayout.maxCardWidth);
      expect(
          near.floatWidth, float - (650 - 16 - RoomNoticeLayout.maxCardWidth));
      expect(near.floatHeight, band);
    });

    test("搜索栏展开时没有浮动按钮：卡片在最上面，占满一行", () {
      var layout = RoomNoticeLayout.of(
        const Size(240, 500),
        folded: false,
        buttonsWidth: 0,
      )!;
      expect(layout.top, 4);
      expect(layout.floatWidth, 0);
      expect(layout.maxWidth, 240 - 16);
    });

    test("地方太小不显示（弹出键盘时聊天区很矮）", () {
      expect(RoomNoticeLayout.of(const Size(390, 100), folded: true), isNull);
      expect(RoomNoticeLayout.of(const Size(150, 500), folded: true), isNull);
      // 卡片下面要给消息留地方：展开的放不下时不显示，收起的小条还能放
      expect(RoomNoticeLayout.of(const Size(240, 180), folded: false), isNull);
      expect(
          RoomNoticeLayout.of(const Size(240, 180), folded: true), isNotNull);
      expect(RoomNoticeLayout.of(const Size(240, 150), folded: true), isNull);
      // 字放大以后要的地方更多
      expect(
          RoomNoticeLayout.of(const Size(390, 180), folded: false), isNotNull);
      expect(
        RoomNoticeLayout.of(const Size(390, 180), folded: false, textScale: 2),
        isNull,
      );
    });

    test("再矮也留得下标题和时长，下面留得下消息", () {
      var layout = RoomNoticeLayout.of(const Size(390, 170), folded: false)!;
      expect(layout.maxHeight, greaterThanOrEqualTo(100));
      expect(
        layout.maxHeight,
        lessThanOrEqualTo(170 - 4 - RoomNoticeLayout.minMessageRoom),
      );
    });
  });

  group("自己收起", () {
    late AppSettingsController settings;
    setUp(() {
      Get.testMode = true;
      MemoryStorage.install();
      settings = Get.put<AppSettingsController>(_TestSettings());
    });
    tearDown(Get.reset);

    test("聊天列表滚起来后收成小条，不记到设置里；点开的只在用户自己滑时才收；换直播间重来", () {
      var state = RoomNoticeState();
      expect(state.autoFolded.value, isFalse);
      // 新消息把列表顶上去了
      state.chatScrolled(byUser: false);
      expect(state.autoFolded.value, isTrue);
      expect(settings.chatNoticeFolded.value, isFalse);
      // 点开：新消息再多也不收
      state.foldByHand(false);
      expect(state.autoFolded.value, isFalse);
      expect(state.keepOpen, isTrue);
      expect(settings.chatNoticeFolded.value, isFalse);
      state.chatScrolled(byUser: false);
      expect(state.autoFolded.value, isFalse);
      // 用户自己滑：收起
      state.chatScrolled(byUser: true);
      expect(state.autoFolded.value, isTrue);
      expect(state.keepOpen, isFalse);
      // 点开以后又收起：这是用户自己收的，记到设置里
      state.foldByHand(false);
      state.foldByHand(true);
      expect(settings.chatNoticeFolded.value, isTrue);
      expect(state.keepOpen, isFalse);
      // 换直播间：自己收起的状态清掉，设置里的留着
      state.chatScrolled(byUser: true);
      state.enterRoom();
      expect(state.autoFolded.value, isFalse);
      expect(state.keepOpen, isFalse);
      expect(settings.chatNoticeFolded.value, isTrue);
    });
  });

  group("设置", () {
    late MemoryStorage storage;
    late AppSettingsController settings;
    setUp(() {
      Get.testMode = true;
      storage = MemoryStorage.install();
      settings = Get.put<AppSettingsController>(_TestSettings());
    });
    tearDown(Get.reset);

    test("默认显示、展开；改了以后记在本机", () {
      expect(settings.chatNoticeCard.value, isTrue);
      expect(settings.chatNoticeFolded.value, isFalse);
      settings.setChatNoticeFolded(true);
      settings.setChatNoticeCard(false);
      expect(settings.chatNoticeFolded.value, isTrue);
      expect(settings.chatNoticeCard.value, isFalse);
      // 存的是布尔值，旧版本不认识这两个键，读到也不会出错
      expect(storage.values[LocalStorageService.kChatNoticeFolded], true);
      expect(storage.values[LocalStorageService.kChatNoticeCard], false);
      expect(LocalStorageService.kChatNoticeCard, "ChatNoticeCard");
      expect(LocalStorageService.kChatNoticeFolded, "ChatNoticeFolded");
    });

    test("两项都只存本机：不进备份，恢复备份时保留本机的值", () {
      var keys = [
        LocalStorageService.kChatNoticeCard,
        LocalStorageService.kChatNoticeFolded,
      ];
      for (var key in keys) {
        expect(SyncCompat.isLocalOnlySetting(key), isTrue);
        expect(
            SyncCompat.isAutoSyncedSetting(key, syncSettings: true), isFalse);
      }
      var local = {for (var key in keys) key: true, "DanmuSize": 16.0};
      expect(SyncCompat.upstreamSettings(local).keys, ["DanmuSize"]);
      expect(SyncCompat.extSettings(local), isEmpty);
      var restored = SyncCompat.mergeRestoredSettings(
        local,
        {for (var key in keys) key: false, "DanmuSize": 20.0},
        {for (var key in keys) key: false},
      );
      for (var key in keys) {
        expect(restored[key], true);
      }
      expect(restored["DanmuSize"], 20.0);
    });
  });

  group("最新在上的列表，顶部留出卡片的高度", () {
    late List<String> items;
    late TailListController list;

    Future<void> pumpList(WidgetTester tester, {double top = 100}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                height: 300,
                width: 200,
                child: TailListView(
                  controller: list,
                  newestFirst: true,
                  padding: EdgeInsets.only(top: top),
                  itemBuilder: (_, i) =>
                      SizedBox(height: 20, child: Text(items[i])),
                ),
              ),
            ),
          ),
        ),
      );
    }

    void append(int n) {
      var start = items.length;
      items.addAll(List.generate(n, (i) => "item ${start + i}"));
      list.setLength(items.length);
    }

    setUp(() {
      items = [];
      list = TailListController();
    });

    const platforms = TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.windows,
      TargetPlatform.android,
    });

    testWidgets("最新的一条在留白下面；往下翻时不跳，新来的接在上面，留白还在最上面", (tester) async {
      await pumpList(tester);
      append(100);
      await tester.pump();
      expect(tester.getTopLeft(find.text("item 99")).dy, 100);
      expect(tester.getTopLeft(find.text("item 98")).dy, 120);

      // 往上拖（看更早的）：一次拖动里从一段变成两段，内容跟着手指走
      var gesture = await tester.startGesture(const Offset(100, 250));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      expect(list.following.value, isFalse);
      var y = tester.getTopLeft(find.text("item 98")).dy;
      expect(y, lessThan(120));
      expect(y, greaterThan(40));
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      expect(tester.getTopLeft(find.text("item 98")).dy, closeTo(y - 20, 0.01));
      await gesture.up();
      await tester.pumpAndSettle();

      // 新来的不挪动正在看的内容
      y = tester.getTopLeft(find.text("item 95")).dy;
      append(3);
      await tester.pump();
      expect(tester.getTopLeft(find.text("item 95")).dy, y);

      // 翻回最上面：最新的一条还是在留白下面，接着跟随
      await tester.drag(find.byType(TailListView), const Offset(0, 2000));
      await tester.pumpAndSettle();
      expect(list.following.value, isTrue);
      expect(tester.getTopLeft(find.text("item 102")).dy, 100);
      expect(tester.getTopLeft(find.text("item 101")).dy, 120);
      append(1);
      await tester.pump();
      expect(tester.getTopLeft(find.text("item 103")).dy, 100);
    }, variant: platforms);

    testWidgets("翻看时留白变了（卡片收起）：正在看的内容不动", (tester) async {
      await pumpList(tester);
      append(100);
      await tester.pump();
      await tester.drag(find.byType(TailListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(list.following.value, isFalse);
      var y = tester.getTopLeft(find.text("item 85")).dy;
      await pumpList(tester, top: 40);
      await tester.pump();
      expect(tester.getTopLeft(find.text("item 85")).dy, y);
    }, variant: platforms);
  });
}
