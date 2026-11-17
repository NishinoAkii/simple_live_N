import 'package:flutter/material.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/widgets/net_image.dart';

/// 分类的图标：平台给了图片时用图片，没给时（抖音）按分类名配一个通用图标
class CategoryIcon extends StatelessWidget {
  final String? pic;
  final String name;

  /// 上一级分类的名字：游戏下面的各个游戏名字里不一定带“游戏”，按上一级配
  final String? parentName;
  final double size;
  const CategoryIcon({
    required this.pic,
    required this.name,
    this.parentName,
    this.size = 40,
    super.key,
  });

  /// 名字里带这些字的分类用对应的图标，从上往下找第一个对上的
  static const List<(List<String>, IconData)> _table = [
    (["游戏", "电竞", "手游", "网游", "单机", "竞技", "射击", "MOBA", "棋牌"], Remix.gamepad_line),
    (["音乐", "唱", "歌", "乐器", "电台"], Remix.music_2_line),
    (["聊天", "交友", "颜值", "星秀", "情感"], Remix.chat_smile_2_line),
    (["二次元", "动漫", "虚拟", "漫画"], Remix.sparkling_2_line),
    (["舞蹈", "跳舞"], Remix.user_heart_line),
    (["文化", "知识", "教育", "学习", "读书", "科技", "科普"], Remix.book_open_line),
    (["美食", "吃"], Remix.restaurant_line),
    (["旅行", "户外", "风景"], Remix.landscape_line),
    (["生活", "日常"], Remix.home_smile_line),
    (["体育", "运动", "球", "健身", "赛事"], Remix.basketball_line),
    (["购物", "带货", "电商"], Remix.shopping_bag_line),
    (["影视", "电影", "电视", "放映"], Remix.movie_2_line),
  ];

  /// 按名字（找不到再按上一级的名字）选图标，都对不上时用通用的分类图标
  static IconData iconFor(String name, {String? parentName}) {
    for (var text in [name, parentName ?? ""]) {
      if (text.isEmpty) continue;
      var lower = text.toLowerCase();
      for (var (words, icon) in _table) {
        if (words.any((w) => lower.contains(w.toLowerCase()))) {
          return icon;
        }
      }
    }
    return Remix.apps_2_line;
  }

  @override
  Widget build(BuildContext context) {
    var url = pic ?? "";
    if (url.isNotEmpty) {
      return NetImage(url, width: size, height: size, borderRadius: 8);
    }
    var theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        iconFor(name, parentName: parentName),
        size: size * 0.6,
        color: theme.colorScheme.onPrimaryContainer,
      ),
    );
  }
}
