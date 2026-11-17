import 'package:flutter/material.dart';
import 'package:simple_live_app/app/name_color.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 发言人的身份：粉丝牌、舰长/贵族、房管、订阅等，一行排不下自动换行
class LiveBadgeChips extends StatelessWidget {
  final List<LiveBadge> badges;
  final double fontSize;
  const LiveBadgeChips(this.badges, {this.fontSize = 12, super.key});

  @override
  Widget build(BuildContext context) {
    var dark = Theme.of(context).brightness == Brightness.dark;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [for (var b in badges) chip(b, fontSize: fontSize, dark: dark)],
    );
  }

  /// 聊天消息名字前面的牌子：粉丝牌、舰长等；别的身份只在平台给了图标时显示图标。
  /// 最多 3 个，没有可显示的时返回 null
  static List<LiveBadge>? inlineOf(List<LiveBadge>? badges) {
    if (badges == null || badges.isEmpty) return null;
    var shown = [
      for (var b in badges)
        if (b.kind == LiveBadgeKind.medal ||
            b.kind == LiveBadgeKind.guard ||
            (b.icon?.isNotEmpty ?? false))
          b,
    ];
    return shown.isEmpty ? null : shown.take(3).toList();
  }

  static Color colorOf(LiveBadge b) {
    switch (b.kind) {
      case LiveBadgeKind.medal:
        return b.color != null && b.color! != 0
            ? Color(0xff000000 | b.color!)
            : Colors.blue;
      case LiveBadgeKind.guard:
        return Colors.deepPurple;
      case LiveBadgeKind.noble:
        return Colors.amber.shade800;
      case LiveBadgeKind.admin:
        return Colors.orange.shade800;
      case LiveBadgeKind.broadcaster:
        return Colors.red;
      case LiveBadgeKind.subscriber:
        return Colors.purple;
      case LiveBadgeKind.vip:
        return Colors.pink;
      case LiveBadgeKind.member:
        return Colors.green.shade700;
      case LiveBadgeKind.level:
        return Colors.blueGrey;
      case LiveBadgeKind.title:
        return Colors.teal;
    }
  }

  /// 显示的文字：订阅、会员带月数，等级带数字；粉丝牌的等级另外画在右边
  static String labelOf(LiveBadge b) {
    var level = b.level;
    switch (b.kind) {
      case LiveBadgeKind.subscriber:
      case LiveBadgeKind.member:
        return level != null && level > 0 ? "{text} {level} 个月".tf({"text": "${b.text}##badge".t, "level": level}) : "${b.text}##badge".t;
      case LiveBadgeKind.level:
        return level != null ? "${"${b.text}##badge".t} $level" : "${b.text}##badge".t;
      case LiveBadgeKind.title:
        // 哔哩哔哩只给头衔编号（title-111-1），名字要另外查接口，显示成“头衔”
        return b.text.startsWith("title-") ? "头衔".t : "${b.text}##badge".t;
      default:
        return b.text;
    }
  }

  /// 一个牌子。[iconOnly]：有图标时只显示图标（聊天消息里用，省地方）
  static Widget chip(
    LiveBadge b, {
    required double fontSize,
    required bool dark,
    bool iconOnly = false,
  }) {
    var hasIcon = b.icon != null && b.icon!.isNotEmpty;
    if (iconOnly && hasIcon && b.kind != LiveBadgeKind.medal) {
      return NetImage(
        b.icon!,
        width: fontSize + 4,
        height: fontSize + 4,
        fit: BoxFit.contain,
      );
    }
    return b.kind == LiveBadgeKind.medal
        ? _medal(b, fontSize, dark)
        : _tinted(b, fontSize, dark, hasIcon);
  }

  /// 粉丝牌：和平台上一样用牌子的颜色做底、白字，等级放在右边的浅色格子里。
  /// 自带底色，深色和浅色主题下都看得清（原来是深色的字直接写在页面上，
  /// 高等级的深紫、深蓝牌子在深色主题下几乎看不见）
  static Widget _medal(LiveBadge b, double fontSize, bool dark) {
    var fill = colorOf(b);
    var onFill = fill.computeLuminance() > 0.55 ? Colors.black87 : Colors.white;
    // 很深的牌子在深色页面上和背景混在一起，描一圈提亮的边
    var edge = dark && fill.computeLuminance() < 0.12
        ? readableColor(fill, dark: true, minContrast: 3)
        : fill;
    var level = b.level;
    return Container(
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: edge),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            child: Text(
              labelOf(b),
              style: TextStyle(fontSize: fontSize, color: onFill, height: 1.3),
            ),
          ),
          if (level != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: const BoxDecoration(
                color: Color(0xf2ffffff),
                borderRadius: BorderRadius.horizontal(
                  right: Radius.circular(3),
                ),
              ),
              child: Text(
                "$level",
                style: TextStyle(
                  fontSize: fontSize,
                  // 白底上的字：太浅的牌子颜色压暗
                  color: readableColor(fill, dark: false),
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 其他身份：淡色底、同色的字和边，颜色按主题调到看得清
  static Widget _tinted(LiveBadge b, double fontSize, bool dark, bool hasIcon) {
    var color = readableColor(colorOf(b), dark: dark);
    return Container(
      decoration: BoxDecoration(
        color: color.withAlpha(dark ? 40 : 28),
        border: Border.all(color: color.withAlpha(170)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasIcon)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: NetImage(
                b.icon!,
                width: fontSize + 4,
                height: fontSize + 4,
                fit: BoxFit.contain,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            child: Text(
              labelOf(b),
              style: TextStyle(fontSize: fontSize, color: color, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}
