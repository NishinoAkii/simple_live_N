import 'package:flutter/material.dart';
import 'package:remixicon/remixicon.dart';

class Constant {
  static const String kUpdateFollow = "UpdateFollow";
  static const String kUpdateHistory = "UpdateHistory";

  static final Map<String, HomePageItem> allHomePages = {
    "recommend": HomePageItem(
      iconData: Remix.home_smile_line,
      title: "首页",
      index: 0,
    ),
    "follow": HomePageItem(
      iconData: Remix.heart_line,
      title: "关注",
      index: 1,
    ),
    "category": HomePageItem(
      iconData: Remix.apps_line,
      title: "分类",
      index: 2,
    ),
    "user": HomePageItem(
      iconData: Remix.user_smile_line,
      title: "我的",
      index: 3,
    ),
  };

  static const String kBiliBili = "bilibili";
  static const String kDouyu = "douyu";
  static const String kHuya = "huya";
  static const String kDouyin = "douyin";
  static const String kTwitch = "twitch";
  static const String kKick = "kick";
  static const String kYouTube = "youtube";

  /// 直播源（.live.js 脚本）平台的 id 前缀，如 js:acfun
  static const String kScriptSitePrefix = "js:";

  /// 本版本新增的自带平台：新装时默认不显示（打开“平台排序”里的开关后显示）
  static const List<String> kForkExtraSites = [kTwitch, kKick, kYouTube];
}

class HomePageItem {
  final IconData iconData;
  final String title;
  final int index;
  HomePageItem({
    required this.iconData,
    required this.title,
    required this.index,
  });
}
