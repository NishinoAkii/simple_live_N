import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/src/douyin_site.dart';
import 'package:test/test.dart';

void main() {
  // 抖音直播首页（2026-11-13）里分类数据那一段，原样截下：
  // 分类数组后面紧接着别的组件数据，以前按“截到 ]\n”取会截过头而解析失败
  var html =
      File("test/fixtures/douyin_home_category.txt").readAsStringSync();

  test('从首页取出完整的分类数组', () {
    var text = douyinCategoryJson(html);
    expect(text, isNotNull);
    var list = json.decode(text!) as List;
    expect(list.map((e) => e["partition"]["title"]), [
      "聊天",
      "音乐",
      "游戏",
      "二次元",
      "舞蹈",
      "文化",
      "生活",
      "运动",
    ]);
    var game = list.firstWhere((e) => e["partition"]["title"] == "游戏");
    expect((game["sub_partition"] as List).length, 9);
    expect(game["partition"]["id_str"], "103");
    expect(game["partition"]["type"], 4);
  });

  test('没有转义的写法也认', () {
    var plain = '{"pathname":"/","categoryData":[{"partition":'
        '{"id_str":"101","type":4,"title":"聊[天]"},"sub_partition":[]}],'
        '"other":1}';
    var list = json.decode(douyinCategoryJson(plain)!) as List;
    expect(list.single["partition"]["title"], "聊[天]");
  });

  test('找不到分类时返回 null', () {
    expect(douyinCategoryJson("<html></html>"), isNull);
  });
}
