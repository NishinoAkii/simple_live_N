import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/mine/history/history_controller.dart';
import 'package:simple_live_app/modules/mine/history/history_page.dart';
import 'package:simple_live_app/widgets/net_image.dart';

class _FakeLive extends HistoryController {
  var refreshed = 0;
  @override
  Future refreshData() async => refreshed++;
}

void main() {
  Future<void> show(
    WidgetTester tester, {
    String? cover,
    String? title,
    String? area,
    DateTime? time,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveHistoryItem(
            item: History(
              id: 'douyu_1',
              roomId: '1',
              siteId: 'douyu',
              userName: '主播',
              face: '',
              updateTime: time ?? DateTime(2026),
              cover: cover,
              title: title,
              area: area,
            ),
            onRemove: () {},
          ),
        ),
      ),
    );
  }

  final coverSlot = find.byType(AspectRatio);
  final avatarOf = find.byType(ListTile);

  testWidgets('没封面的行和老版本一样高，时间位置相同；有封面的行时间也对齐', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<Map<String, double>> measure(String? cover, String? title) async {
      await show(tester, cover: cover, title: title);
      var tile = tester.getRect(avatarOf);
      var name = tester.getRect(find.textContaining('主播'));
      var time = tester.getRect(find.textContaining('01-01'));
      return {
        'height': tile.height,
        'timeTop': time.top - tile.top,
        'right': 1200 - time.right,
        'top': name.top - tile.top,
        'bottom': tile.bottom - time.bottom,
      };
    }

    var old = await measure(null, null);
    var noCover = await measure('', '直播间标题');
    var withCover = await measure('http://127.0.0.1:1/a.png', '直播间标题');
    expect(old['height'], 72);
    expect(old['right'], 32);
    // 没封面的行：布局和老版本一样，只有主播名往上挪
    expect(noCover['top'], closeTo(old['top']! - 7.33, 0.01));
    for (var key in ['height', 'timeTop', 'right', 'bottom']) {
      expect(noCover[key], old[key]);
    }
    // 没封面的行：三行都在格子里（笔画之间的间距要看真实字体，截图量）
    await show(tester, cover: '', title: '直播间标题');
    var tile = tester.getRect(avatarOf);
    expect(tester.getRect(find.text('主播')).top, greaterThanOrEqualTo(tile.top));
    // 标题在这一行的正中（测试字体和真实字体略有差别，留 3 的余量）
    expect(
      tester.getCenter(find.text('直播间标题')).dy,
      closeTo(tile.center.dy, 3),
    );
    expect(
      tester.getRect(find.text('斗鱼直播')).bottom,
      lessThanOrEqualTo(tile.bottom + 1),
    );
    expect(withCover['right'], old['right']);
    expect(withCover['top'], 13);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('封面的左边和没有封面时头像的左边对齐', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await show(tester, cover: '', title: '直播间标题');
    var avatarLeft = tester.getTopLeft(find.byType(NetImage).first).dx;
    await show(tester, cover: 'http://127.0.0.1:1/b.png');
    expect(tester.getTopLeft(coverSlot).dx, avatarLeft);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('没有封面：不留封面的位置，主播名和标题照常显示', (tester) async {
    await show(tester, cover: '', title: '直播间标题');
    expect(coverSlot, findsNothing);
    expect(find.textContaining('主播'), findsOneWidget);
    expect(find.textContaining('直播间标题'), findsOneWidget);
  });

  testWidgets('旧记录：没有封面也没有标题', (tester) async {
    await show(tester);
    expect(coverSlot, findsNothing);
    expect(find.text('主播'), findsOneWidget);
  });

  testWidgets('分区：宽的行排在平台名后面，行高和时间的位置不变', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (var cover in ['', 'http://127.0.0.1:1/c.png']) {
      await show(tester, cover: cover, title: '直播间标题');
      var plain = tester.getRect(avatarOf);
      var plainTime = tester.getRect(find.textContaining('01-01'));
      await show(tester, cover: cover, title: '直播间标题', area: '主机游戏');
      expect(tester.takeException(), isNull);
      expect(tester.getRect(avatarOf), plain);
      expect(tester.getRect(find.textContaining('01-01')), plainTime);
      var site = tester.getRect(find.text('斗鱼直播'));
      var area = tester.getRect(find.text('主机游戏'));
      expect(area.left, greaterThan(site.right));
      expect(area.center.dy, closeTo(site.center.dy, 0.01));
      expect(area.right, lessThan(plainTime.left));
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('分区：手机上有封面的行放不下平台名，只留图标和分区，太长时省略', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const cover = 'http://127.0.0.1:1/d.png';
    // 今天看的：时间只有时和分
    var today = DateTime.now();
    await show(tester, cover: cover, title: '直播间标题', time: today);
    var plain = tester.getRect(avatarOf);
    var plainTime = tester.getRect(find.textContaining(':'));
    expect(find.text('斗鱼直播'), findsOneWidget);

    await show(tester, cover: cover, title: '直播间标题', area: '主机游戏', time: today);
    expect(tester.takeException(), isNull);
    expect(coverSlot, findsOneWidget);
    expect(find.text('斗鱼直播'), findsNothing);
    expect(tester.getRect(avatarOf), plain);
    var time = tester.getRect(find.textContaining(':'));
    expect(time, plainTime);
    expect(390 - time.right, 32);
    var area = tester.getRect(find.text('主机游戏'));
    // 测试字体每个字 12 宽（加字距 0.25）：四个字完整显示
    expect(area.width, closeTo(49, 0.01));
    expect(area.right, lessThanOrEqualTo(time.left - 4 + 0.01));

    const long = 'Grand Theft Auto V (GTA) Online Roleplay';
    await show(tester, cover: cover, title: '直播间标题', area: long, time: today);
    expect(tester.takeException(), isNull);
    area = tester.getRect(find.text(long));
    expect(area.width, lessThan(long.length * 12));
    expect(area.right, lessThanOrEqualTo(time.left - 4 + 0.01));
    expect(tester.getRect(find.textContaining(':')), plainTime);

    // 窄到连分区也放不下：不报溢出
    tester.view.physicalSize = const Size(320, 844);
    await show(tester, cover: cover, title: '直播间标题', area: long, time: today);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('封面加载不出来：位置也收回去', (tester) async {
    await show(tester, cover: 'http://127.0.0.1:1/none.png', title: '直播间标题');
    expect(coverSlot, findsOneWidget);
    // 测试环境没有网络，图片一定会失败
    for (var i = 0; i < 40 && coverSlot.evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(coverSlot, findsNothing);
    expect(find.textContaining('直播间标题'), findsOneWidget);
  });

  testWidgets('只有直播的观看记录：没有标签栏，右上角刷新这一页', (tester) async {
    var live = Get.put<HistoryController>(_FakeLive()) as _FakeLive;
    addTearDown(Get.reset);
    await tester.pumpWidget(const GetMaterialApp(home: HistoryPage()));
    await tester.pump(const Duration(seconds: 1));
    
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('观看记录'), findsOneWidget);
    expect(find.text('清空'), findsOneWidget);
    // 返回键还在默认的位置，刷新按钮在它右边，不重叠
    var back = tester.getRect(find.byType(BackButton));
    var refresh = tester.getRect(find.byTooltip('刷新'));
    expect(back.center.dx, 28);
    expect(refresh.left, greaterThanOrEqualTo(back.right));
    var before = live.refreshed;
    await tester.tap(find.byTooltip('刷新'));
    await tester.pump();
    expect(live.refreshed, before + 1);
    
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
