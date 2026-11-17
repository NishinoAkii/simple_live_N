import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_controller.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_page.dart';

import 'fakes/follow_fakes.dart';

/// 关注页的硬性要求：默认设置下，页面上看得见的东西和改之前一样。
/// 参照文件 fixtures/follow_page_default.txt 是在改动之前的代码上
/// 用 --dart-define=WRITE_FOLLOW_TREE=true 跑这个测试写出来的
void main() {
  const write = bool.fromEnvironment("WRITE_FOLLOW_TREE");
  const fixture = "test/fixtures/follow_page_default.txt";
  var env = FollowTestEnv();

  setUp(() async {
    await env.setUp();
    await env.addDefaultFollows();
  });
  tearDown(() => env.tearDown());

  Future<List<String>> render(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Get.put(FollowUserController());
    await tester.pumpWidget(const GetMaterialApp(
      debugShowCheckedModeBanner: false,
      home: FollowUserPage(),
    ));
    // 首次刷新：读数据库、查开播状态（假的平台）、下拉头收起
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    var lines = visibleSignature(tester);
    // 菜单：原来的七项还在原来的位置
    await tester.tap(find.byWidgetPredicate((w) => w is PopupMenuButton).first);
    await tester.pump(const Duration(milliseconds: 500));
    var menu = tester
        .widgetList<PopupMenuItem>(
            find.byWidgetPredicate((w) => w is PopupMenuItem))
        .map((e) => e.value.toString())
        .toList();
    lines.add("menu ${menu.take(7).join(",")}");
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox());
    Get.delete<FollowUserController>(force: true);
    return lines;
  }

  testWidgets("默认设置：窄屏和宽屏两列，看得见的东西和改之前一样", (tester) async {
    var lines = [
      "== 400x700",
      ...await render(tester, const Size(400, 700)),
      "== 1100x700",
      ...await render(tester, const Size(1100, 700)),
    ];
    var text = "${lines.join("\n")}\n";
    var file = File(fixture);
    if (write) {
      file.writeAsStringSync(text);
      return;
    }
    // git 在 Windows 上签出时可能换成 CRLF
    expect(text, file.readAsStringSync().replaceAll("\r\n", "\n"));
  });
}
