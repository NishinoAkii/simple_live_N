import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/controller/follow_view_settings.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/follow_user/follow_view.dart';
import 'package:simple_live_app/modules/follow_user/follow_view_widgets.dart';
import 'package:simple_live_app/widgets/floating_header.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/site_logo.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'layout_matrix.dart';

// 关注页的布局检查：组标题、紧凑的一行、卡片、顶栏的搜索框，
// 以及浮动标签条、组标题、第一条内容叠在一起时谁也不盖住谁。名字 20 个字

const longName = "名字特别特别特别特别长的一位主播啊啊啊啊";

/// 新加的文字还没进 en.json（合并时再加），英文布局用 i18n_new.json 里拟的译文
final Map<String, String> _english = () {
  var file = File("../i18n_new.json");
  if (!file.existsSync()) return const <String, String>{};
  return Map<String, String>.from(jsonDecode(file.readAsStringSync()) as Map);
}();

Widget withNewText(Widget Function() build) {
  var base = CoreText.lookup;
  if (base != null && base("复制弹幕") == "Copy danmaku") {
    CoreText.lookup = (key) => base(key) ?? _english[key];
  }
  return build();
}

FollowUser follow(String site, String room,
    {String name = longName, int status = 2}) {
  var item = FollowUser(
    id: "${site}_$room",
    roomId: room,
    siteId: site,
    userName: name,
    face: "",
    addTime: DateTime(2026, 11, 15),
    notify: true,
  );
  item.liveStatus.value = status;
  item.liveStartTime =
      "${DateTime.now().millisecondsSinceEpoch ~/ 1000 - 7200}";
  item.liveOnline = 123456789;
  return item;
}

void main() {
  Future<void> check(
      WidgetTester tester, String name, Widget Function() builder,
      {void Function()? after}) async {
    var problems = <String>[];
    for (var size in layoutSizes) {
      for (var language in layoutLanguages) {
        for (var scale in layoutTextScales) {
          problems.addAll(await layoutMatrix(
            tester,
            () => withNewText(builder),
            sizes: [size],
            languages: [language],
            textScales: [scale],
          ));
          after?.call();
        }
      }
    }
    if (problems.isNotEmpty) {
      // ignore: avoid_print
      print("[layout] $name\n  ${problems.join("\n  ")}");
    }
    // 原来关注行“名字 + 状态”在名字 20 个字、英文 Offline、手机竖屏放大 1.3 倍时
    // 超出 11 像素；现在状态放不下时省略，这里不再有例外
    expect(problems, isEmpty, reason: name);
  }

  testWidgets("组标题：长名字、人数很多、正在刷新", (tester) async {
    await check(
      tester,
      "FollowGroupHeader",
      () => Column(
        children: [
          FollowGroupHeader(
            title: longName,
            count: 12345,
            collapsed: false,
            leading: SiteLogo(Sites.allSites["huya"], width: 18),
            onToggle: () {},
            onRefresh: () {},
          ),
          FollowGroupHeader(
            title: longName,
            count: 9,
            collapsed: true,
            onToggle: () {},
            refreshing: true,
          ),
        ],
      ),
    );
  });

  testWidgets("紧凑的一行：长名字、开了提醒、平台已删除", (tester) async {
    await check(
      tester,
      "FollowCompactRow",
      () => Column(
        children: [
          FollowCompactRow(
              item: follow("huya", "1"), onTap: () {}, onToggleNotify: () {}),
          FollowCompactRow(item: follow("js:gone", "2", status: 0)),
        ],
      ),
    );
  });

  testWidgets("顶栏的搜索框", (tester) async {
    await check(
      tester,
      "FollowSearchField",
      () => AppBar(
        leading: IconButton(onPressed: () {}, icon: const Icon(Icons.refresh)),
        title: FollowSearchField(onChanged: (_) {}, onClose: () {}),
        actions: [
          IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert))
        ],
      ),
    );
  });

  // 浮动的标签条 + 分组的列表，和关注页一样叠起来
  Widget page(String style, {bool headers = true}) {
    var groups = [
      FollowGroup(
          "site:huya",
          "虎牙直播",
          [
            follow("huya", "1"),
            follow("huya", "2", status: 1),
            follow("huya", "3"),
          ],
          siteId: "huya"),
      FollowGroup("site:twitch", "Twitch", [follow("twitch", "4", status: 1)],
          siteId: "twitch"),
    ];
    return LayoutBuilder(builder: (context, box) {
      var columns = box.maxWidth ~/ 500;
      var cards = box.maxWidth ~/ 200;
      return FloatingHeader(
        header: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              key: const ValueKey("chips"),
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var t in ["全部", "直播中", "未开播", "很长很长的自定义标签"]) ...[
                    ChoiceChip(label: Text(t), selected: t == "全部"),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
        ),
        body: (context, top) => CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(top: top),
              sliver: SliverMainAxisGroup(
                slivers: followSectionSlivers(
                  groups: groups,
                  headers: headers,
                  style: style,
                  collapsed: const {},
                  columns: columns < 1 ? 1 : columns,
                  cardColumns: cards < 2 ? 2 : cards,
                  row: (item) => FollowUserItem(
                      item: item, onRemove: () {}, onToggleNotify: () {}),
                  compact: (item) =>
                      FollowCompactRow(item: item, onToggleNotify: () {}),
                  card: (item) => FollowLiveCard(
                    item: item,
                    site: Sites.allSites[item.siteId]!,
                    cover: "",
                    title: "标题也写得很长很长很长很长很长很长很长很长很长",
                  ),
                  header: (g, folded) => FollowGroupHeader(
                    title: g.title,
                    count: g.members.length,
                    collapsed: folded,
                    leading: SiteLogo(Sites.allSites[g.siteId], width: 18),
                    onToggle: () {},
                    onRefresh: () {},
                  ),
                  bottom: 72,
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  for (var (style, first) in [
    (FollowViewSettings.styleList, FollowUserItem),
    (FollowViewSettings.styleCompact, FollowCompactRow),
    (FollowViewSettings.styleCard, FollowLiveCard),
  ]) {
    testWidgets("分组的列表（$style）：标签条不盖组标题，组标题不盖第一条", (tester) async {
      await check(
        tester,
        "sections $style${style == FollowViewSettings.styleCompact ? "" : " + FollowUserItem"}",
        () => page(style),
        after: () {
          expectBelow(tester, find.byKey(const ValueKey("chips")),
              find.byType(FollowGroupHeader),
              reason: style);
          expectBelow(
              tester, find.byType(FollowGroupHeader).first, find.byType(first),
              reason: style);
        },
      );
    });
  }

  testWidgets("不分组的紧凑和卡片：标签条不盖第一条", (tester) async {
    for (var (style, first) in [
      (FollowViewSettings.styleCompact, FollowCompactRow),
      (FollowViewSettings.styleCard, FollowLiveCard),
    ]) {
      await check(
        tester,
        "plain $style${style == FollowViewSettings.styleCompact ? "" : " + FollowUserItem"}",
        () => page(style, headers: false),
        after: () => expectBelow(
            tester, find.byKey(const ValueKey("chips")), find.byType(first),
            reason: style),
      );
    }
  });
}
