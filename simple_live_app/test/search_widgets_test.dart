// 搜索页新组件的渲染冒烟测试：联想面板、主播卡片、直达卡片（不联网）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/search/local_search.dart';
import 'package:simple_live_app/modules/search/search_controller.dart';
import 'package:simple_live_app/modules/search/search_direct.dart';
import 'package:simple_live_app/modules/search/search_merge.dart';
import 'package:simple_live_app/modules/search/widgets/search_cards.dart';
import 'package:simple_live_app/modules/search/widgets/search_suggest_panel.dart';
import 'package:simple_live_core/simple_live_core.dart';

Widget app(Widget child) => GetMaterialApp(home: Scaffold(body: child));

void main() {
  late AppSearchController controller;
  var site = Site(id: "douyu", name: "斗鱼直播", logo: "", liveSite: LiveSite());

  setUp(() {
    Get.testMode = true;
    controller = Get.put(AppSearchController(searchSites: [site]));
  });

  tearDown(() {
    Get.reset();
  });

  testWidgets("输入框为空：没有最近搜索时显示提示，有时显示可删除的标签", (tester) async {
    await tester.pumpWidget(app(SearchSuggestPanel(controller)));
    expect(find.text("输入主播名字、房间号或链接"), findsOneWidget);
    controller.suggest.history.assignAll(["老番茄", "张大仙"]);
    await tester.pump();
    expect(find.text("最近搜索"), findsOneWidget);
    expect(find.text("清空"), findsOneWidget);
    expect(find.text("老番茄"), findsOneWidget);
  });

  testWidgets("输入时：本地匹配、主播卡片（没有联想词）", (tester) async {
    var follow = FollowUser(
      id: "douyu_4615502",
      roomId: "4615502",
      siteId: "douyu",
      userName: "一条小团团OvO",
      face: "",
      addTime: DateTime(2026),
    )..liveStatus.value = 2;
    var index = LocalSearchIndex.build(follows: [follow], histories: []);
    var suggest = controller.suggest;
    suggest.query.value = "一条";
    suggest.localMatches.assignAll(index.search("一条"));
    suggest.channels.assignAll([
      LiveSuggestion(
        text: "一条小团团Ov0",
        type: LiveSuggestion.kRoom,
        roomId: "6384853",
        userName: "一条小团团Ov0",
        liveStatus: false,
        subtitle: "户外",
      ),
      LiveSuggestion(
        text: "YouTube 频道",
        type: LiveSuggestion.kRoom,
        roomId: "UCaaaaaaaaaaaaaaaaaaaaaa",
        userName: "YouTube 频道",
      ),
    ]);
    await tester.pumpWidget(app(SearchSuggestPanel(controller)));
    expect(find.text("搜索“一条”"), findsOneWidget);
    expect(find.text("关注和看过"), findsOneWidget);
    expect(find.text("当前平台"), findsOneWidget);
    expect(find.text("一条小团团OvO"), findsOneWidget);
    expect(find.text("关注 · 斗鱼直播 · 直播中"), findsOneWidget);
    expect(find.text("斗鱼直播的主播"), findsOneWidget);
    expect(find.text("未开播 · 户外"), findsOneWidget);
    // 没有在播状态的频道卡片只显示名字
    expect(find.text("YouTube 频道"), findsOneWidget);
    // 只放直播相关的：没有联想词
    expect(find.text("猜你想搜"), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets("没有本地匹配时可以切到全部平台", (tester) async {
    controller.suggest.query.value = "abc";
    await tester.pumpWidget(app(SearchSuggestPanel(controller)));
    expect(find.text("在全部平台的关注和看过里找"), findsOneWidget);
  });

  testWidgets("主播卡片、综合结果卡片、直达卡片", (tester) async {
    var offline = LiveAnchorItem(
      roomId: "21852",
      avatar: "",
      userName: "老番茄",
      liveStatus: false,
      followers: 20860654,
      lastTitle: "最烧脑的一集",
      lastLiveTime: DateTime.now().subtract(const Duration(days: 3)),
    );
    var record = LiveAnchorItem(
      roomId: "1",
      avatar: "",
      userName: "轮播的主播",
      liveStatus: false,
      isRecord: true,
    );
    var direct = SearchDirectResult(
      LiveRoomDetail(
        roomId: "21852",
        title: "标题",
        cover: "",
        userName: "老番茄",
        userAvatar: "",
        online: 0,
        status: true,
        url: "",
      ),
      "房间号 21852",
    );
    await tester.pumpWidget(app(SizedBox(
      width: 220,
      child: ListView(
        children: [
          SearchDirectCard(site, direct),
          SearchAnchorCard(site, offline, tag: "按拼音匹配"),
          SearchEntryCard(
            site,
            SearchEntry(roomId: "1", anchor: record),
          ),
          SearchEntryCard(
            site,
            SearchEntry(
              roomId: "2",
              room: LiveRoomItem(
                roomId: "2",
                title: "直播标题",
                cover: "",
                userName: "在播主播",
              ),
              tag: "按简体匹配",
            ),
          ),
        ],
      ),
    )));
    expect(find.text("直达"), findsOneWidget);
    expect(find.text("直播中 · 房间号 21852 · 标题"), findsOneWidget);
    expect(find.text("未开播"), findsOneWidget);
    expect(find.text(" · 粉丝 2086.1万"), findsOneWidget);
    expect(find.text("上次直播 3 天前：最烧脑的一集"), findsOneWidget);
    expect(find.text("按拼音匹配"), findsOneWidget);
    expect(find.text("轮播"), findsOneWidget);
    expect(find.text("按简体匹配"), findsOneWidget);
    expect(find.text("直播标题"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
