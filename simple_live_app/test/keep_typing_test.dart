import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/follow_user/follow_view_widgets.dart';
import 'package:simple_live_app/modules/live_room/live_chat_search.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/search/search_controller.dart';
import 'package:simple_live_app/modules/search/search_page.dart';
import 'package:simple_live_app/widgets/keep_typing.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'fakes/fake_player.dart';
import 'fakes/memory_storage.dart';

// 搜索以后光标留在输入框里（可以接着输入）；手机上点输入框以外的地方收起键盘

/// 不读 Hive 的设置
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// 直播间：不连弹幕、不读房间信息
class _Room extends LiveRoomController {
  _Room()
      : super(
          pSite: Site(id: "test", liveSite: LiveSite(), logo: "", name: "测试"),
          pRoomId: "1",
        );

  @override
  // ignore: overridden_fields
  final Player player = FakePlayer();

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  // ignore: must_call_super
  void onClose() {}
}

/// 搜索没有结果的平台（不访问网络）
class _EmptySite extends LiveSite {
  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword,
          {int page = 1}) async =>
      LiveSearchRoomResult(hasMore: false, items: []);

  @override
  Future<LiveSearchAnchorResult> searchAnchors(String keyword,
          {int page = 1}) async =>
      LiveSearchAnchorResult(hasMore: false, items: []);
}

Widget _page(Widget child) => GetMaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            // 输入框以外的地方
            const Expanded(child: SizedBox(key: ValueKey("outside"))),
            child,
          ],
        ),
      ),
    );

Future<void> _mouseTap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder, kind: PointerDeviceKind.mouse);
  await tester.pump();
}

void main() {
  test("keepTyping：拼了一半的字先上屏，文字和光标不变", () {
    var text = TextEditingController();
    text.value = const TextEditingValue(
      text: "搜索",
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 1, end: 2),
    );
    keepTyping(text)();
    expect(text.value.composing, TextRange.empty);
    expect(text.text, "搜索");
    expect(text.selection, const TextSelection.collapsed(offset: 2));
    text.dispose();
  });

  group("直播间", () {
    late _Room room;

    setUp(() {
      Get.testMode = true;
      MemoryStorage.install();
      Get.put<AppSettingsController>(_TestSettings());
      room = Get.put<LiveRoomController>(_Room()) as _Room;
    });
    tearDown(() {
      room.chatLog.dispose();
      Get.reset();
    });

    testWidgets("聊天搜索：回车、点内容/用户和搜索按钮以后光标还在，点别处离开",
        (tester) async {
      room.chatSearchOpen.value = true;
      await tester.pumpWidget(_page(LiveChatSearchField(controller: room)));
      var field = find.byType(TextField);
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, "弹幕");
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(room.chatSearchFocusNode.hasFocus, isTrue);

      await _mouseTap(tester, find.text("内容"));
      expect(room.chatSearchByUser.value, isTrue);
      expect(room.chatSearchFocusNode.hasFocus, isTrue);

      await _mouseTap(tester, find.byIcon(Icons.search));
      expect(room.chatSearchFocusNode.hasFocus, isTrue);

      // 手机上点别处收起键盘
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey("outside"))));
      await tester.pump();
      expect(room.chatSearchFocusNode.hasFocus, isFalse);
    });
  });

  testWidgets("关注列表的搜索：回车以后光标还在，点别处离开", (tester) async {
    var changes = <String>[];
    await tester.pumpWidget(_page(FollowSearchField(
      onChanged: changes.add,
      onClose: () {},
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField), "abc");
    await tester.testTextInput.receiveAction(TextInputAction.search);
    bool typing() => tester
        .widget<EditableText>(find.byType(EditableText))
        .focusNode
        .hasFocus;
    await tester.pump();
    expect(changes, ["abc"]);
    expect(typing(), isTrue);

    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey("outside"))));
    await tester.pump();
    expect(typing(), isFalse);
  });

  group("搜索页", () {
    late AppSearchController controller;
    var site = Site(id: "douyu", name: "斗鱼直播", logo: "", liveSite: _EmptySite());

    setUp(() {
      Get.testMode = true;
      MemoryStorage.install();
      controller = Get.put(AppSearchController(searchSites: [site]));
    });
    tearDown(Get.reset);

    testWidgets("回车搜索、点最近搜索以后光标还在；点结果区离开", (tester) async {
      await tester.pumpWidget(const GetMaterialApp(home: SearchPage()));
      await tester.pump();
      expect(controller.focusNode.hasFocus, isTrue);
      await tester.enterText(find.byType(TextField), "abc");
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(controller.focusNode.hasFocus, isTrue);
      expect(controller.panelOpen.value, isFalse);

      // 清空以后联想面板显示最近搜索，点它再搜一次
      await tester.enterText(find.byType(TextField), "");
      await tester.pump();
      expect(controller.panelOpen.value, isTrue);
      await _mouseTap(tester, find.text("abc"));
      await tester.pumpAndSettle();
      expect(controller.searchController.text, "abc");
      expect(controller.panelOpen.value, isFalse);
      expect(controller.focusNode.hasFocus, isTrue);

      // 点下面的结果区（触摸，手机上）：收起键盘
      await tester.tapAt(tester.getCenter(find.byType(TabBarView)));
      await tester.pump();
      expect(controller.focusNode.hasFocus, isFalse);
    });
  });
}
