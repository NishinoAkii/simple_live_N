import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/category/detail/category_detail_controller.dart';
import 'package:simple_live_app/modules/category/detail/category_detail_page.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/routes/app_pages.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/widgets/category_icon.dart';
import 'package:simple_live_app/widgets/live_room_card.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'layout/layout_matrix.dart';

/// 不读本地存储的设置
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// 每个分类返回几个房间，记下问了哪些分类
class _FakeSite extends LiveSite {
  final asked = <String>[];
  @override
  Future<LiveCategoryResult> getCategoryRooms(LiveSubCategory category,
      {int page = 1}) async {
    asked.add("${category.id}#$page");
    if (page > 1) {
      return LiveCategoryResult(hasMore: false, items: []);
    }
    return LiveCategoryResult(hasMore: false, items: [
      for (var i = 0; i < 6; i++)
        LiveRoomItem(
          roomId: "$i",
          title: "${category.name}的第 $i 个直播间，标题很长很长很长很长",
          cover: "",
          userName: "主播$i",
          online: 12345,
        ),
    ]);
  }
}

/// 抖音“游戏”那样：一级分类自己那一项，下一层是 9 个游戏（名字取自 2026-11-14 的首页）
LiveSubCategory _games() {
  const names = [
    "三角洲行动",
    "王者荣耀",
    "无畏契约",
    "英雄联盟",
    "和平精英",
    "QQ飞车端游",
    "穿越火线",
    "绝地求生",
    "火影忍者手游",
  ];
  return LiveSubCategory(
    id: "103,4",
    name: "游戏",
    parentId: "103,4",
    pic: "",
    children: [
      for (var (i, name) in names.indexed)
        LiveSubCategory(
          id: "${1010000 + i},1",
          name: name,
          parentId: "103,4",
          pic: "",
          children: name == "王者荣耀"
              ? [LiveSubCategory(id: "9,1", name: "巅峰赛", parentId: "${1010000 + i},1")]
              : const [],
        ),
    ],
  );
}

void main() {
  late _FakeSite fake;
  late Site site;
  setUp(() {
    Get.testMode = true;
    Get.put<AppSettingsController>(_TestSettings());
    fake = _FakeSite();
    site = Site(id: "douyin_test", liveSite: fake, logo: "", name: "测试");
  });
  tearDown(Get.reset);

  group("通用图标", () {
    test("按名字配，名字里没有时按上一级", () {
      expect(CategoryIcon.iconFor("聊天"), Remix.chat_smile_2_line);
      expect(CategoryIcon.iconFor("音乐"), Remix.music_2_line);
      expect(CategoryIcon.iconFor("游戏"), Remix.gamepad_line);
      expect(CategoryIcon.iconFor("火影忍者手游"), Remix.gamepad_line);
      expect(CategoryIcon.iconFor("运动"), Remix.basketball_line);
      // 游戏名字里看不出是游戏
      expect(CategoryIcon.iconFor("王者荣耀", parentName: "游戏"),
          Remix.gamepad_line);
      expect(CategoryIcon.iconFor("王者荣耀"), Remix.apps_2_line);
    });

    testWidgets("给了图片用图片，没给时画图标", (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Row(children: [
          CategoryIcon(pic: "", name: "音乐"),
          CategoryIcon(pic: null, name: "随便"),
        ]),
      ));
      expect(find.byIcon(Remix.music_2_line), findsOneWidget);
      expect(find.byIcon(Remix.apps_2_line), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });

  group("子分类条", () {
    testWidgets("各种尺寸下不溢出，不挡住第一个直播间", (tester) async {
      var controller = Get.put(
        CategoryDetailController(site: site, subCategory: _games()),
        tag: "t1",
      );
      var problems = await layoutMatrix(
        tester,
        () => const CategoryDetailPage(tag: "t1"),
        wrapInScaffold: false,
      );
      expect(problems, isEmpty);
      CoreText.lookup = null;
      expect(controller.list, isNotEmpty);
      expect(find.byType(SubCategoryBar), findsOneWidget);
      expectBelow(tester, find.byType(SubCategoryBar),
          find.byType(LiveRoomCard), reason: "子分类条");

      // 手机竖屏：一排放不下，横着滑
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(const GetMaterialApp(
        home: CategoryDetailPage(tag: "t1"),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      var scrollable = tester.state<ScrollableState>(find.descendant(
        of: find.byType(SubCategoryBar),
        matching: find.byType(Scrollable),
      ));
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
      expect(scrollable.position.axis, Axis.horizontal);
      expect(find.text("全部"), findsOneWidget);
      expectBelow(tester, find.byType(SubCategoryBar),
          find.byType(LiveRoomCard), reason: "手机竖屏的子分类条");
    });

    testWidgets("没有下一层时不显示", (tester) async {
      Get.put(
        CategoryDetailController(
          site: site,
          subCategory: LiveSubCategory(id: "101,4", name: "聊天", parentId: "101,4"),
        ),
        tag: "t2",
      );
      await tester.pumpWidget(const GetMaterialApp(
        home: CategoryDetailPage(tag: "t2"),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(SubCategoryBar), findsNothing);
      expect(find.byType(LiveRoomCard), findsWidgets);
    });

    testWidgets("点下一层：同一个页面叠着打开，各看各的分类，返回后还在", (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(GetMaterialApp(
        initialRoute: "/start",
        getPages: [
          GetPage(name: "/start", page: () => const Scaffold()),
          AppPages.routes.firstWhere((e) => e.name == RoutePath.kCategoryDetail),
        ],
      ));
      AppNavigator.toCategoryDetail(site: site, category: _games());
      await tester.pumpAndSettle();
      expect(find.text("游戏"), findsOneWidget);
      expect(find.byType(SubCategoryBar), findsOneWidget);

      await tester.tap(find.text("王者荣耀"));
      await tester.pumpAndSettle();
      // 王者荣耀下面还有一层
      expect(find.widgetWithText(AppBar, "王者荣耀"), findsOneWidget);
      expect(find.text("巅峰赛"), findsOneWidget);
      await tester.tap(find.text("巅峰赛"));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, "巅峰赛"), findsOneWidget);
      expect(find.byType(SubCategoryBar), findsNothing);
      expect(fake.asked, ["103,4#1", "1010001,1#1", "9,1#1"]);

      Get.back();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, "王者荣耀"), findsOneWidget);
      expect(find.textContaining("王者荣耀的第 0 个"), findsOneWidget);
      Get.back();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, "游戏"), findsOneWidget);
      expect(find.textContaining("游戏的第 0 个"), findsOneWidget);
      // 返回时没有重新读
      expect(fake.asked.length, 3);
    });
  });
}
