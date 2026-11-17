import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 不读本地存储的设置
class FollowTestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// 开播状态由测试指定，不发请求
class FakeFollowSite extends LiveSite {
  final live = <String, bool>{};
  final calls = <String>[];

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    calls.add(roomId);
    return live[roomId] ?? false;
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    calls.add("detail:$roomId");
    return LiveRoomDetail(
      roomId: roomId,
      title: "标题$roomId",
      cover: "",
      userName: "主播$roomId",
      userAvatar: "",
      online: 1234,
      status: live[roomId] ?? false,
      url: "",
    );
  }
}

FollowUser fakeFollow(
  String siteId,
  String roomId, {
  String? name,
  String tag = "全部",
  DateTime? addTime,
}) =>
    FollowUser(
      id: "${siteId}_$roomId",
      roomId: roomId,
      siteId: siteId,
      userName: name ?? "主播$roomId",
      face: "",
      addTime: addTime ?? DateTime(2026, 11, 14),
      tag: tag,
    );

/// 关注页测试用的环境：Hive 放在临时目录，twitch 和 kick 换成假的平台
class FollowTestEnv {
  late Directory dir;
  final sites = <String, FakeFollowSite>{};
  final _original = <String, LiveSite>{};
  late FollowService service;

  Future<void> setUp() async {
    Get.testMode = true;
    dir = Directory.systemTemp.createTempSync("follow_view_");
    Hive.init(dir.path);
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(FollowUserAdapter());
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(HistoryAdapter());
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(FollowUserTagAdapter());
    }
    var db = DBService()
      ..followBox = await Hive.openBox<FollowUser>("FollowUser")
      ..tagBox = await Hive.openBox<FollowUserTag>("FollowUserTag")
      ..historyBox = await Hive.openBox<History>("History");
    Get.put(db);
    // 设置放在内存里：界面里不等结果的写入（折叠、换样式）在测试的假时钟里开始，
    // 写文件的话永远写不完，Hive.close 会一直等
    var storage = LocalStorageService()
      ..settingsBox = await Hive.openBox("LocalStorage", bytes: Uint8List(0));
    Get.put(storage);
    var settings = Get.put<AppSettingsController>(FollowTestSettings());
    settings.autoUpdateFollowEnable.value = false;
    settings.updateFollowThreadCount.value = 2;
    for (var id in ["twitch", "kick"]) {
      var fake = FakeFollowSite();
      sites[id] = fake;
      _original[id] = Sites.allSites[id]!.liveSite;
      Sites.allSites[id]!.liveSite = fake;
    }
    service = Get.put(FollowService());
  }

  Future<void> tearDown() async {
    for (var e in _original.entries) {
      Sites.allSites[e.key]!.liveSite = e.value;
    }
    Get.reset();
    // 卡住时报错，不要一直等
    await Hive.close().timeout(const Duration(seconds: 20));
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// 默认的一组：twitch 上 a 在播、b 在标签“朋友”里，kick 上 c 没播
  Future<FollowUserTag> addDefaultFollows() async {
    sites["twitch"]!.live["a"] = true;
    var b = fakeFollow("twitch", "b", tag: "朋友");
    for (var item in [fakeFollow("twitch", "a"), b, fakeFollow("kick", "c")]) {
      await DBService.instance.addFollow(item);
    }
    var tag = await DBService.instance.addFollowTag("朋友");
    tag.userId.add(b.id);
    await DBService.instance.updateFollowTag(tag);
    return tag;
  }
}

/// 页面上看得见的东西（文字、图标、关注行、标签按钮、图片）按树的顺序列出来，
/// 每个带上位置和大小。外面多包一层不影响，画出来的东西变了就不一样
List<String> visibleSignature(WidgetTester tester) {
  var lines = <String>[];
  void visit(Element element) {
    var w = element.widget;
    String? desc;
    if (w is Text) {
      desc = "Text ${w.data ?? w.textSpan?.toPlainText()}";
    } else if (w is RichText) {
      desc = "RichText ${w.text.toPlainText()}";
    } else if (w is Icon) {
      desc = "Icon ${w.icon?.codePoint}";
    } else if (w is Image) {
      desc = "Image";
    } else if (w is ChoiceChip ||
        w is ListTile ||
        w is IconButton ||
        w is AppBar ||
        w is Scaffold ||
        w is Material ||
        w is Divider ||
        w is CircularProgressIndicator ||
        w is TextField) {
      desc = "${w.runtimeType}";
    } else {
      var type = w.runtimeType.toString();
      if (type.startsWith("FollowUserItem") ||
          type.startsWith("AlignedGridView") ||
          type.startsWith("PageGridView") ||
          type.startsWith("SliverAlignedGrid") ||
          type.startsWith("FollowGroupHeader") ||
          type.startsWith("FollowCompactRow") ||
          type.startsWith("LiveRoomCard") ||
          type.startsWith("FloatingActionButton")) {
        desc = type;
      }
    }
    if (desc != null) {
      var ro = element.renderObject;
      var rect = "";
      if (ro is RenderBox && ro.hasSize && ro.attached) {
        var o = ro.localToGlobal(Offset.zero);
        rect = " @${o.dx.toStringAsFixed(1)},${o.dy.toStringAsFixed(1)}"
            " ${ro.size.width.toStringAsFixed(1)}x${ro.size.height.toStringAsFixed(1)}";
      }
      lines.add("$desc$rect");
    }
    element.visitChildren(visit);
  }

  tester.binding.rootElement!.visitChildren(visit);
  return lines;
}
