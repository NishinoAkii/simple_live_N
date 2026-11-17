import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/widgets/page_grid_view.dart';

/// 首页、分类、搜索的直播间网格：按行排，顺序和列表一致，高一点的卡片不会让后面的卡片
/// 换列、空出位置（原来是瀑布流，标题里有特殊字符的卡片高几个像素就会这样）
class _Grid extends BasePageController<double> {
  @override
  Future<List<double>> getData(int page, int pageSize) async => [];
}

void main() {
  testWidgets("按行排：第 i 个在第 i ~/ 列数 行；每行从上一行最高的卡片下面开始",
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var controller = _Grid();
    // 第 1 个卡片高 5 像素，和标题里有特殊字符的卡片一样
    controller.list.value = [100, 105, 100, 100, 100, 100, 100, 100];
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: PageGridView(
            pageController: controller,
            crossAxisCount: 4,
            itemBuilder: (_, i) => SizedBox(
              key: ValueKey(i),
              height: controller.list[i],
              child: Text("$i"),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Rect at(int i) => tester.getRect(find.byKey(ValueKey(i)));
    for (var i = 0; i < 8; i++) {
      var row = i ~/ 4;
      var col = i % 4;
      expect(at(i).left, closeTo(col * 200.0, 0.5), reason: "第 $i 个的列");
      expect(at(i).top, closeTo(row * 105.0, 0.5), reason: "第 $i 个的行");
    }
    controller.onClose();
  });
}
