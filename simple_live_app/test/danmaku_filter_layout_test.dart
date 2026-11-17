import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/widgets/settings/danmaku_filter_settings.dart';

import 'layout/layout_matrix.dart';

/// 不读本地存储的设置
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// 新加的句子的英文（还没写进 en.json 时从 i18n_new.json 读），
/// 英文最长，布局检查要按英文来
final Map<String, String> _newEnglish = () {
  var file = File("../i18n_new.json");
  if (!file.existsSync()) {
    return <String, String>{};
  }
  var map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return {for (var e in map.entries) e.key: e.value.toString()};
}();

String? Function(String)? _wrapped;

/// 英文表里还没有的新句子用 [_newEnglish] 补上
void _withNewEnglish() {
  var base = CoreText.lookup;
  if (base == null || identical(base, _wrapped) || _newEnglish.isEmpty) {
    return;
  }
  var english = base("设置") == "Settings";
  _wrapped = (key) => base(key) ?? (english ? _newEnglish[key] : null);
  CoreText.lookup = _wrapped;
}

const _liveRoom = RoomContext(
  id: "live:layout",
  siteId: "huya",
  siteName: "虎牙直播",
  roomId: "1",
  roomLabel: "名字特别特别特别特别长的一位主播啊啊啊啊",
);

void main() {
  late _TestSettings settings;
  late Directory dir;
  late Box box;
  late Box<String> shieldBox;

  setUp(() async {
    Get.testMode = true;
    dir = Directory.systemTemp.createTempSync("danmaku_filter_layout_");
    Hive.init(dir.path);
    box = await Hive.openBox("settings");
    shieldBox = await Hive.openBox<String>("shield");
    Get.put(LocalStorageService()
      ..settingsBox = box
      ..shieldBox = shieldBox);
    settings = Get.put<AppSettingsController>(_TestSettings()) as _TestSettings;
    // 打开过滤，下面几行都显示出来（存进全局，进直播间时也是开着的）；几个平台有延迟
    await box.put("DanmuDedupe", true);
    await box.put("DanmuDedupeChat", true);
    settings.danmuDedupe.value = true;
    settings.danmuDedupeChat.value = true;
    settings.danmuDelayBySite.assignAll({"huya": 15, "twitch": 50});
  });
  tearDown(() async {
    await box.close();
    await shieldBox.close();
    Get.reset();
    dir.deleteSync(recursive: true);
  });

  Future<void> check(WidgetTester tester, Widget Function() builder) async {
    var problems = await layoutMatrix(tester, () {
      _withNewEnglish();
      return builder();
    });
    if (problems.isNotEmpty) {
      // ignore: avoid_print
      print(problems.join("\n"));
    }
    expect(problems, isEmpty);
  }

  test("布局检查的英文里有新句子（en.json 里还没有时从 i18n_new.json 补）", () {
    var en = jsonDecode(File("assets/lang/en.json").readAsStringSync())
        as Map<String, dynamic>;
    CoreText.lookup = (key) => en[key]?.toString();
    _withNewEnglish();
    expect("设置".t, "Settings");
    expect("过滤重复弹幕".t, "Filter repeated danmaku");
    expect("{seconds} 秒".tf({"seconds": "1.5"}), "1.5 s");
    CoreText.lookup = null;
  });

  testWidgets("设置页：重复弹幕过滤和全部平台的弹幕延迟", (tester) async {
    await check(
      tester,
      () => ListView(
        padding: const EdgeInsets.all(12),
        children: const [DanmuSettingsView()],
      ),
    );
    CoreText.lookup = null;
    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(
        body: ListView(children: const [DanmuSettingsView()]),
      ),
    ));
    expect(find.text("过滤重复弹幕"), findsOneWidget);
    expect(find.text("10 秒"), findsOneWidget);
    expect(find.text("1 次"), findsOneWidget);
    expect(find.text("同一个人"), findsOneWidget);
    expect(find.byType(DanmakuDelaySection), findsOneWidget);
    expect(find.text("1.5 秒"), findsOneWidget);
    expect(find.text("5.0 秒"), findsOneWidget);
    expect(find.textContaining("弹幕延迟（"), findsNothing);
  });

  testWidgets("直播间：右侧弹窗宽 400 和全宽，只有当前平台的一行", (tester) async {
    settings.enterRoomContext(_liveRoom);
    await check(
      tester,
      () => Align(
        alignment: Alignment.topRight,
        child: SizedBox(
          width: 400,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: const [DanmuSettingsView()],
          ),
        ),
      ),
    );
    await check(
      tester,
      () => ListView(
        padding: const EdgeInsets.all(12),
        children: const [DanmuSettingsView()],
      ),
    );
    CoreText.lookup = null;
    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(
        body: ListView(children: const [DanmuSettingsView()]),
      ),
    ));
    expect(find.text("弹幕延迟（虎牙直播）"), findsOneWidget);
    expect(find.text("1.5 秒"), findsOneWidget);
    expect(find.text("5.0 秒"), findsNothing);
    settings.leaveRoomContext(_liveRoom.id);
  });

  testWidgets("滑块弹窗里也按秒显示，各种尺寸、文字放大下不超出", (tester) async {
    settings.enterRoomContext(_liveRoom);
    for (var size in layoutSizes) {
      for (var scale in layoutTextScales) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(GetMaterialApp(
          builder: (context, widget) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: widget!,
          ),
          home: Scaffold(
            body: ListView(children: const [DanmuSettingsView()]),
          ),
        ));
        var row = find.text("弹幕延迟（虎牙直播）");
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.byType(Slider), findsOneWidget);
        expect(find.text("1.5 秒"), findsNWidgets(2));
        expect(tester.takeException(), isNull, reason: "$size x$scale");
        Navigator.of(tester.element(find.byType(Slider))).pop();
        await tester.pumpAndSettle();
      }
    }
    tester.view.reset();
    settings.leaveRoomContext(_liveRoom.id);
  });
}
