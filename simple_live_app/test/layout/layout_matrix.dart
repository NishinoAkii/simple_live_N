import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 布局检查：把一个组件放在各种尺寸、语言、文字缩放下各渲染一次，
/// 有 overflow 或者异常就记下来。浮在上面的东西用 [expectBelow] 比矩形，确认没挡住第一条内容。
class LayoutCase {
  final Size size;
  final String language;
  final double textScale;
  const LayoutCase(this.size, this.language, this.textScale);

  @override
  String toString() =>
      "${size.width.toInt()}x${size.height.toInt()} $language x$textScale";
}

const layoutSizes = [
  Size(360, 640), // 手机竖屏
  Size(390, 844),
  Size(844, 390), // 手机横屏
  Size(1024, 768), // 平板
  Size(1280, 720), // 电脑
  Size(1920, 1080),
  Size(400, 225), // 小窗
];
const layoutLanguages = ["zh-Hans", "zh-Hant", "en"];
const layoutTextScales = [1.0, 1.3];

final _tables = <String, Map<String, String>>{};

/// 语言表直接从 assets/lang 读，和 App 里的一样
Map<String, String>? _table(String language) {
  if (language == "zh-Hans") {
    return null;
  }
  return _tables.putIfAbsent(language, () {
    var file = File("assets/lang/$language.json");
    var map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return {
      for (var e in map.entries)
        if (!e.key.startsWith("@@")) e.key: e.value.toString(),
    };
  });
}

/// 在 [cases]（默认全部组合）下各渲染一次 [builder]，返回问题列表：“组合: 错误第一行”。
/// [builder] 每次都重新调用；它返回的组件放在一个占满窗口的 Scaffold 里
Future<List<String>> layoutMatrix(
  WidgetTester tester,
  Widget Function() builder, {
  Iterable<Size> sizes = layoutSizes,
  Iterable<String> languages = layoutLanguages,
  Iterable<double> textScales = layoutTextScales,
  bool wrapInScaffold = true,
}) async {
  var problems = <String>[];
  var previous = FlutterError.onError;
  addTearDown(() {
    FlutterError.onError = previous;
    CoreText.lookup = null;
    tester.view.reset();
  });
  for (var language in languages) {
    var table = _table(language);
    CoreText.lookup = table == null ? null : (key) => table[key];
    for (var size in sizes) {
      for (var scale in textScales) {
        var name = LayoutCase(size, language, scale).toString();
        var errors = <String>[];
        FlutterError.onError = (details) =>
            errors.add(details.exceptionAsString().split("\n").first);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        var child = builder();
        await tester.pumpWidget(GetMaterialApp(
          debugShowCheckedModeBanner: false,
          builder: (context, widget) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: widget!,
          ),
          home: wrapInScaffold ? Scaffold(body: child) : child,
        ));
        await tester.pump(const Duration(milliseconds: 50));
        var exception = tester.takeException();
        if (exception != null) {
          errors.add(exception.toString().split("\n").first);
        }
        for (var e in errors.toSet()) {
          problems.add("$name: $e");
        }
      }
    }
  }
  FlutterError.onError = previous;
  return problems;
}

/// 浮在上面的东西（[overlay]）的下边不能压到下面第一条内容（[content]）的上边
void expectBelow(WidgetTester tester, Finder overlay, Finder content,
    {String reason = ""}) {
  var over = tester.getRect(overlay);
  var first = tester.getRect(content.first);
  expect(first.top, greaterThanOrEqualTo(over.bottom - 0.5),
      reason: "$reason 浮层 $over 盖住了第一条内容 $first");
}
