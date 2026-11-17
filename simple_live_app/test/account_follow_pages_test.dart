// 导入预览页、同步预览页在手机宽度下能正常显示和勾选（不访问网络，数据是假的）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_import_controller.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_import_page.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_sync_controller.dart';
import 'package:simple_live_app/modules/mine/account/follow/account_follow_sync_page.dart';
import 'package:simple_live_app/services/account_follow/account_follow_diff.dart';
import 'package:simple_live_app/services/account_follow/account_follow_models.dart';
import 'package:simple_live_app/services/account_follow_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _Site implements LiveAccountFollowSite {
  _Site(this.policy);
  final AccountFollowPolicy policy;
  @override
  bool get canReadAccountFollows => true;
  @override
  String get accountFollowOwner => "me";
  @override
  AccountFollowPolicy get accountFollowPolicy => policy;
  @override
  bool get canWriteAccountFollows => true;
  @override
  Future<AccountFollowPage> getAccountFollows({String? cursor}) =>
      throw UnimplementedError();
  @override
  Future<AccountFollowTarget> resolveAccountFollowTarget(String roomId) =>
      throw UnimplementedError();
  @override
  Future<void> followOnAccount(AccountFollowTarget target) =>
      throw UnimplementedError();
  @override
  Future<void> unfollowOnAccount(AccountFollowTarget target) =>
      throw UnimplementedError();
}

AccountFollowItem _item(String id, {bool? live}) => AccountFollowItem(
      roomId: id,
      accountUid: "u$id",
      userName: "主播$id",
      isLive: live,
    );

void main() {
  late Directory dir;

  setUp(() async {
    Get.testMode = true;
    dir = Directory.systemTemp.createTempSync("account_follow_pages");
    Hive.init(dir.path);
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(FollowUserAdapter());
    }
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(HistoryAdapter());
    }
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(FollowUserTagAdapter());
    }
    await Get.put(DBService()).init();
  });

  tearDown(() async {
    Get.reset();
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  testWidgets('import preview: markers, select all/none, live filter',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    var items = [_item("1", live: true), _item("2"), _item("3", live: false)];
    var locals = [
      const LocalFollowRef(siteId: "bilibili", roomId: "3", userName: "主播3"),
    ];
    var c = Get.put(AccountFollowImportController());
    c.siteId.value = "bilibili";
    c.result = AccountFollowLoad(
      siteId: "bilibili",
      site: _Site(const AccountFollowPolicy()),
      owner: "me",
      fetch: AccountFollowFetchResult(
        items: items,
        complete: false,
        incompleteReason: "只读到了前 100 个",
      ),
      locals: locals,
    );
    c.entries.assignAll(
      buildImportPreview(siteId: "bilibili", items: items, locals: locals),
    );
    c.stage.value = AccountFollowStage.loaded;
    await tester.pumpWidget(
      const GetMaterialApp(home: AccountFollowImportPage()),
    );
    await tester.pump();

    expect(find.text("从哔哩哔哩导入关注"), findsOneWidget);
    expect(find.textContaining("只读到了前 100 个"), findsOneWidget);
    expect(find.text("已在关注里"), findsOneWidget);
    expect(find.text("直播中"), findsOneWidget);
    expect(find.text("添加 2 个"), findsOneWidget);

    await tester.tap(find.text("全不选"));
    await tester.pump();
    expect(find.text("添加 0 个"), findsOneWidget);
    await tester.tap(find.text("全选"));
    await tester.pump();
    expect(find.text("添加 2 个"), findsOneWidget);

    await tester.tap(find.text("只看直播中"));
    await tester.pump();
    expect(find.text("主播1"), findsOneWidget);
    expect(find.text("主播2"), findsNothing);

    await tester.tap(find.text("主播1"));
    await tester.pump();
    expect(find.text("添加 1 个"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sync preview: groups, group checkbox, summary', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    var fetch = AccountFollowFetchResult(
      items: [_item("a"), _item("new", live: true)],
      complete: true,
    );
    var locals = [
      const LocalFollowRef(siteId: "kick", roomId: "a", userName: "主播a"),
      const LocalFollowRef(siteId: "kick", roomId: "gone", userName: "主播gone"),
      const LocalFollowRef(siteId: "kick", roomId: "mine", userName: "主播mine"),
    ];
    var site = _Site(const AccountFollowPolicy(
      writeIntervalMin: Duration(seconds: 2),
      writeIntervalMax: Duration(seconds: 2),
      listIsAuthoritative: false,
    ));
    var c = Get.put(AccountFollowSyncController());
    c.siteId.value = "kick";
    c.writeBack = true;
    c.result = AccountFollowLoad(
      siteId: "kick",
      site: site,
      owner: "me",
      fetch: fetch,
      locals: locals,
    );
    c.diff.value = computeAccountFollowDiff(
      siteId: "kick",
      owner: "me",
      fetch: fetch,
      locals: locals,
      snapshot: AccountFollowSnapshot(
        siteId: "kick",
        owner: "me",
        entries: const [
          SnapshotEntry("a", "ua"),
          SnapshotEntry("gone", "ugone")
        ],
        time: DateTime(2026),
      ),
      listIsAuthoritative: false,
      writeBack: true,
    );
    c.stage.value = AccountFollowStage.loaded;
    await tester
        .pumpWidget(const GetMaterialApp(home: AccountFollowSyncPage()));
    await tester.pump();

    expect(find.text("与Kick账号同步"), findsOneWidget);
    expect(find.textContaining("账号新增"), findsOneWidget);
    expect(find.textContaining("从 App 移除"), findsOneWidget);
    expect(find.textContaining("在账号上关注"), findsOneWidget);
    expect(find.textContaining("列表可能不全"), findsOneWidget);
    // 默认只勾“账号新增”
    expect(find.text("执行（1 项）"), findsOneWidget);
    expect(c.summary(), "将在 App 添加 1 个。");

    // 勾上“App 里新增 · 在账号上关注”这一组
    var group = find.ancestor(
      of: find.textContaining("在账号上关注"),
      matching: find.byType(ListTile),
    );
    await tester
        .tap(find.descendant(of: group, matching: find.byType(Checkbox)));
    await tester.pump();
    expect(find.text("执行（2 项）"), findsOneWidget);
    expect(c.summary(), "将在 App 添加 1 个；在Kick账号关注 1 个（约 1 秒）。");
    expect(tester.takeException(), isNull);
  });
}
