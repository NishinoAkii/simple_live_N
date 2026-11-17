import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/widgets/live_badges.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 深色页面按接近黑算
const darkPage = Color(0xff101010);

/// 两种颜色的对比度（WCAG），越大越看得清，白对黑是 21
double contrast(Color a, Color b) {
  var la = a.computeLuminance(), lb = b.computeLuminance();
  var hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Color textColor(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!.color!;

Future<void> pumpChips(
  WidgetTester tester,
  List<LiveBadge> badges, {
  required bool dark,
}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: dark ? ThemeData.dark() : ThemeData.light(),
        home: Scaffold(body: LiveBadgeChips(badges)),
      ),
    );

void main() {
  // 哔哩哔哩高等级粉丝牌的深紫、深蓝
  const purple = LiveBadge(
    LiveBadgeKind.medal,
    "牌子",
    level: 28,
    color: 0x2d0855,
  );
  const navy = LiveBadge(
    LiveBadgeKind.medal,
    "深蓝",
    level: 24,
    color: 0x06154c,
  );
  const guard = LiveBadge(LiveBadgeKind.guard, "舰长");

  testWidgets("深色主题：深紫、深蓝的粉丝牌自带底色，字是白的，等级在浅色格子里", (tester) async {
    await pumpChips(tester, [purple, navy], dark: true);
    for (var (name, level, fill) in [
      ("牌子", "28", const Color(0xff2d0855)),
      ("深蓝", "24", const Color(0xff06154c)),
    ]) {
      // 牌子名：白字写在牌子颜色的底上
      expect(contrast(textColor(tester, name), fill), greaterThan(7));
      // 等级：写在近白色的格子里
      expect(
        contrast(textColor(tester, level), const Color(0xfff2f2f2)),
        greaterThan(4.5),
      );
    }
  });

  testWidgets("其他身份的字按主题调亮或调暗", (tester) async {
    await pumpChips(tester, [guard], dark: true);
    expect(contrast(textColor(tester, "舰长"), darkPage), greaterThan(4.4));
    await pumpChips(tester, [guard], dark: false);
    // 切换主题有过渡动画
    await tester.pumpAndSettle();
    expect(contrast(textColor(tester, "舰长"), Colors.white), greaterThan(4.4));
  });

  test("聊天栏名字前只放粉丝牌、舰长和有图标的身份，最多 3 个", () {
    const level = LiveBadge(LiveBadgeKind.level, "UL", level: 30);
    const mod = LiveBadge(LiveBadgeKind.admin, "房管", icon: "https://x/mod.png");
    expect(LiveBadgeChips.inlineOf(null), isNull);
    expect(LiveBadgeChips.inlineOf([level]), isNull);
    expect(
      LiveBadgeChips.inlineOf([level, purple, guard, mod, navy]),
      [purple, guard, mod],
    );
  });
}
