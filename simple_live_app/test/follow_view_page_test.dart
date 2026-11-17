import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/follow_view_settings.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_controller.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_page.dart';
import 'package:simple_live_app/modules/follow_user/follow_view_widgets.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';

import 'fakes/follow_fakes.dart';

/// 关注页打开分组、换样式以后
void main() {
  var env = FollowTestEnv();
  setUp(() => env.setUp());
  tearDown(() => env.tearDown());

  Future<FollowUserController> open(WidgetTester tester,
      {Size size = const Size(400, 700)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var c = Get.put(FollowUserController());
    await tester.pumpWidget(const GetMaterialApp(
      debugShowCheckedModeBanner: false,
      home: FollowUserPage(),
    ));
    await settle(tester);
    return c;
  }

  testWidgets("分组：标题带人数，点标题折叠并记住，每组可以单独刷新", (tester) async {
    await tester.runAsync(() async {
      await env.addDefaultFollows();
      await LocalStorageService.instance
          .setValue(FollowViewSettings.kGrouped, true);
    });
    await open(tester);

    var headers = tester
        .widgetList<FollowGroupHeader>(find.byType(FollowGroupHeader))
        .toList();
    expect(headers.map((e) => "${e.title} ${e.count}"), ["Twitch 2", "Kick 1"]);
    expect(find.byType(FollowUserItem), findsNWidgets(3));
    // 组标题不盖住组里第一个
    expect(
        tester.getRect(find.byType(FollowUserItem).first).top,
        greaterThanOrEqualTo(
            tester.getRect(find.byType(FollowGroupHeader).first).bottom));

    await tester.tap(find.byType(FollowGroupHeader).first);
    await settle(tester);
    expect(find.byType(FollowUserItem), findsOneWidget);
    expect(
      LocalStorageService.instance
          .getValue<List>(FollowViewSettings.kCollapsed, []),
      ["site:twitch"],
    );

    env.sites["kick"]!.calls.clear();
    env.sites["twitch"]!.calls.clear();
    await tester.tap(find.byTooltip("刷新这一组").last);
    await settle(tester);
    expect(env.sites["kick"]!.calls, ["c"]);
    expect(env.sites["twitch"]!.calls, isEmpty);
  });

  testWidgets("几千个关注：三种样式分组和不分组都排得出来，滚动、折叠、回到顶部都正常", (tester) async {
    var items = <String, FollowUser>{};
    for (var i = 0; i < 3000; i++) {
      var site = i % 3 == 0 ? "kick" : "twitch";
      var room = "r$i";
      if (i % 7 == 0) env.sites[site]!.live[room] = true;
      items["${site}_$room"] = fakeFollow(site, room, name: "主播$i号");
    }
    await tester.runAsync(() => DBService.instance.followBox.putAll(items));
    var c = await open(tester, size: const Size(1100, 800));
    expect(c.list.length, 3000);

    var scrollable = find.byType(Scrollable).first;
    for (var grouped in [true, false]) {
      c.setGrouped(grouped);
      for (var style in FollowViewSettings.styles) {
        c.setStyle(style);
        await settle(tester);
        expect(tester.takeException(), isNull, reason: "$style $grouped");
        await tester.drag(scrollable, const Offset(0, -3000));
        await settle(tester);
        await tester.drag(scrollable, const Offset(0, -20000));
        await settle(tester);
        expect(tester.takeException(), isNull, reason: "$style $grouped 滚动");
        if (grouped) {
          // 往下滚了一屏以上：出现回到顶部，点了回到最上面
          expect(find.byTooltip("回到顶部"), findsOneWidget);
          await tester.tap(find.byTooltip("回到顶部"));
          await settle(tester);
          expect(c.scrollController.offset, 0);
          // 折叠第一组再展开
          await tester.tap(find.byType(FollowGroupHeader).first);
          await settle(tester);
          await tester.tap(find.byType(FollowGroupHeader).first);
          await settle(tester);
          expect(tester.takeException(), isNull, reason: "$style 折叠");
        } else {
          expect(find.byTooltip("回到顶部"), findsNothing);
          c.scrollController.jumpTo(0);
          await settle(tester);
        }
      }
    }
    // 卡片样式下直播中的画成卡片
    c.setGrouped(true);
    c.setStyle(FollowViewSettings.styleCard);
    await settle(tester);
    expect(find.byType(FollowLiveCard), findsWidgets);
  });

  testWidgets("搜索：顶栏换成搜索框，搜不到时有提示，关掉回到原样", (tester) async {
    await tester.runAsync(() => env.addDefaultFollows());
    var c = await open(tester);
    c.startSearch();
    await settle(tester);
    expect(find.byType(FollowSearchField), findsOneWidget);
    expect(find.text("关注用户"), findsNothing);
    await tester.enterText(find.byType(TextField), "zba");
    await settle(tester);
    expect(find.byType(FollowUserItem), findsOneWidget);
    await tester.enterText(find.byType(TextField), "没有这个人");
    await settle(tester);
    expect(find.byType(FollowUserItem), findsNothing);
    expect(find.text("没有符合条件的"), findsOneWidget);
    await tester.tap(find.byTooltip("关闭搜索"));
    await settle(tester);
    expect(find.text("关注用户"), findsOneWidget);
    expect(find.byType(FollowUserItem), findsNWidgets(3));
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}
