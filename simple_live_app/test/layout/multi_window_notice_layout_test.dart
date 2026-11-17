import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/multi_window_widgets.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'layout_matrix.dart';

// 多开的布局检查：副窗口顶上的“主窗口已关闭”提示、
// 设置页底下的“只能查看”提示。两条都推开内容，不盖住第一条

/// 新加的文字还没进 en.json（合并时再加），英文布局用 i18n_new.json 里拟的译文
Map<String, String> _newEnglish() {
  var file = File("../i18n_new.json");
  if (!file.existsSync()) {
    return const {};
  }
  return Map<String, String>.from(jsonDecode(file.readAsStringSync()) as Map);
}

final _english = _newEnglish();

Widget withNewText(Widget Function() build) {
  var base = CoreText.lookup;
  if (base != null && base("知道了") == "Got it") {
    CoreText.lookup = (key) => base(key) ?? _english[key];
  }
  return build();
}

/// 一个像设置页的页面：标题栏加一列开关
Widget _settingsPage() => Scaffold(
      appBar: AppBar(title: const Text("播放设置")),
      body: ListView(
        children: [
          for (var i = 0; i < 12; i++)
            SwitchListTile(
              key: i == 0 ? const Key("first") : null,
              title: Text("设置项 $i"),
              value: i.isEven,
              onChanged: (_) {},
            ),
        ],
      ),
    );

void main() {
  setUp(() {
    MultiWindow.launch = SecondaryLaunch(
      port: 1,
      token: WindowToken.generate(),
      dataDir: "/tmp/multi_window/w1-1",
      slot: 1,
      siteId: "douyu",
      roomId: "1",
    );
    MultiWindow.mainGone.value = true;
    MultiWindow.noticeDismissed.value = false;
  });

  tearDown(() {
    MultiWindow.launch = null;
    MultiWindow.mainGone.value = false;
    MultiWindow.noticeDismissed.value = false;
  });

  testWidgets("主窗口已关闭的提示：各种尺寸、语言、缩放都放得下", (tester) async {
    var problems = await layoutMatrix(
      tester,
      () => withNewText(() => MultiWindowFrame(child: _settingsPage())),
      wrapInScaffold: false,
    );
    expect(problems, isEmpty);
    // 提示在上面，内容被推下去，没有被盖住
    expectBelow(tester, find.byType(MainGoneNotice), find.byType(AppBar));
    // 点“知道了”以后收起
    await tester.tap(find.byType(TextButton));
    await tester.pump();
    expect(find.byType(MainGoneNotice), findsNothing);
  });

  testWidgets("设置页只能查看：底下的提示放得下，不盖住内容", (tester) async {
    var problems = await layoutMatrix(
      tester,
      () => withNewText(() => ReadOnlySettings(child: _settingsPage())),
      wrapInScaffold: false,
    );
    expect(problems, isEmpty);
    var list = tester.getRect(find.byType(ListView));
    var hint = tester.getRect(find.byType(ReadOnlySettingsHint));
    expect(list.bottom, lessThanOrEqualTo(hint.top + 0.5));
  });

  testWidgets("设置页只能查看：开关点不动，返回按钮能点", (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var changed = 0;
    var backs = 0;
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [FlutterSmartDialog.observer],
      builder: FlutterSmartDialog.init(),
      home: ReadOnlySettings(
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => backs++,
            ),
          ),
          body: ListView(
            children: [
              SwitchListTile(
                title: const Text("开关"),
                value: false,
                onChanged: (_) => changed++,
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect(changed, 0);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    expect(backs, 1);
    // 吐司两秒后收起
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
  });
}
