import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 抖音分类不限层数：递归解析、第一项是一级分类自己、房间列表和 444
void main() {
  group('分类树', () {
    // 2026-11-14 抓的抖音直播首页里的分类数组（匿名访问）
    var captured = json.decode(
      File("test/fixtures/douyin_category_20261114.json").readAsStringSync(),
    ) as List;

    test('抓到的分类：一级分类第一项是自己，下一层挂在它下面', () {
      var list = douyinCategories(captured);
      expect(list.map((e) => e.name), [
        "聊天",
        "音乐",
        "游戏",
        "二次元",
        "舞蹈",
        "文化",
        "生活",
        "运动",
      ]);
      var game = list.firstWhere((e) => e.name == "游戏");
      expect(game.id, "103,4");
      // 自己 + 9 个游戏
      expect(game.children.length, 10);
      var self = game.children.first;
      expect(self.id, "103,4");
      expect(self.name, "游戏");
      expect(self.hasChildren, isTrue);
      expect(self.children.map((e) => e.name).take(2), ["三角洲行动", "王者荣耀"]);
      expect(self.children.length, 9);
      var wzry = game.children.firstWhere((e) => e.name == "王者荣耀");
      expect(wzry.id, "1010045,1");
      expect(wzry.parentId, "103,4");
      expect(wzry.hasChildren, isFalse);
      // 网页数据里没有图标：留空，App 按名字配
      expect(wzry.pic, "");

      var chat = list.first;
      expect(chat.children.length, 1);
      expect(chat.children.single.hasChildren, isFalse);
    });

    test('以前抓的首页（2026-11-13）解析结果一样', () {
      var html =
          File("test/fixtures/douyin_home_category.txt").readAsStringSync();
      var old = douyinCategories(json.decode(douyinCategoryJson(html)!));
      var now = douyinCategories(captured);
      expect(old.map((e) => e.toString()), now.map((e) => e.toString()));
    });

    test('三层：每一层都解析出来，父分类号一层层对上', () {
      // 分类页的推荐分类里写着这条路径：游戏 → 射击游戏 → 和平精英（2026-11-14）
      var data = json.decode('''[{"partition":{"id_str":"103","type":4,"title":"游戏"},
        "sub_partition":[{"partition":{"id_str":"1","type":1,"title":"射击游戏"},
          "sub_partition":[{"partition":{"id_str":"1010032","type":1,"title":"和平精英",
            "icon":{"url_list":["https://p3.douyinpic.com/hpjy.png"]}},"sub_partition":[]},
            {"partition":{"id_str":"1010017","type":1,"title":"无畏契约"}}]},
          {"partition":{"id_str":"2","type":1,"title":"竞技游戏"},"sub_partition":[]}]}]''')
          as List;
      var game = douyinCategories(data).single;
      expect(game.children.map((e) => e.name), ["游戏", "射击游戏", "竞技游戏"]);
      var shooter = game.children[1];
      expect(shooter.id, "1,1");
      expect(shooter.children.map((e) => e.name), ["和平精英", "无畏契约"]);
      var hpjy = shooter.children.first;
      expect(hpjy.parentId, "1,1");
      expect(hpjy.pic, "https://p3.douyinpic.com/hpjy.png");
      // 没写 sub_partition 的当作没有下一层
      expect(shooter.children[1].children, isEmpty);
      // 一级分类自己那一项的下一层就是它下面的各项
      expect(game.children.first.children.map((e) => e.name), ["射击游戏", "竞技游戏"]);
    });

    test('格式不对的项跳过，不报错', () {
      var list = douyinCategories([
        "x",
        {"partition": null},
        {
          "partition": {"id_str": "101", "type": 4, "title": "聊天"},
          "sub_partition": "坏的",
        },
      ]);
      expect(list.single.name, "聊天");
      expect(list.single.children.single.children, isEmpty);
    });
  });

  group('房间列表', () {
    test('抓到的房间列表（裁剪过）', () {
      var data = json.decode(
        File("test/fixtures/douyin_category_rooms.json").readAsStringSync(),
      );
      var result = douyinCategoryRooms(data);
      expect(result.items.length, 2);
      expect(result.hasMore, isFalse);
      var first = result.items.first;
      expect(first.roomId, "240694364757");
      expect(first.userName, "王者荣耀皓楠");
      expect(first.online, 30931);
      expect(first.cover, startsWith("https://"));
    });

    test('接口回 444：报 444，提示过一会儿再试', () {
      expect(
        () => douyinCategoryRooms({"status_code": 444, "data": {}}),
        throwsA(isA<CoreError>()
            .having((e) => e.statusCode, "statusCode", 444)
            .having((e) => e.toString(), "提示", contains("444"))),
      );
      // HTTP 444（HttpClient 报的）也是同一句
      expect(CoreError("", statusCode: 444).toString(), contains("请稍后再试"));
    });
  });

  test('LiveSubCategory 没有下一层时和以前一样', () {
    var item = LiveSubCategory(id: "1", name: "a", parentId: "0");
    expect(item.hasChildren, isFalse);
    expect(json.decode(item.toString()).containsKey("children"), isFalse);
    var tree = LiveSubCategory(
      id: "1",
      name: "a",
      parentId: "0",
      children: [LiveSubCategory(id: "2", name: "b", parentId: "1")],
    );
    expect(json.decode(tree.toString())["children"][0]["name"], "b");
  });
}
