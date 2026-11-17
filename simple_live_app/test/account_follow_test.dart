// 账号关注：开关默认值、“导入/恢复不回写”的规则、三方比对、导入预览、回写队列
// （节流、风控停止、退避，用假的时钟）。全部离线，不访问网络、不用任何真实凭据。
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/account_follow/account_follow_diff.dart';
import 'package:simple_live_app/services/account_follow/account_follow_models.dart';
import 'package:simple_live_app/services/account_follow/account_follow_platforms.dart';
import 'package:simple_live_app/services/account_follow/account_follow_queue.dart';
import 'package:simple_live_app/services/account_follow/account_follow_store.dart';
import 'package:simple_live_app/services/account_follow/account_follow_sync.dart';
import 'package:simple_live_core/simple_live_core.dart';

class FakeClock {
  DateTime time = DateTime(2026, 10, 28, 12);
  final List<Duration> sleeps = [];
  DateTime now() => time;
  Future<void> sleep(Duration d) async {
    sleeps.add(d);
    time = time.add(d);
  }

  void advance(Duration d) => time = time.add(d);
}

/// 假的平台：记录回写，按需抛出错误
class FakeSite implements LiveAccountFollowSite {
  AccountFollowPolicy policy;
  bool canWrite = true;
  String owner = "me";
  final List<String> writes = [];
  final List<String> resolved = [];
  Object? Function(String action, AccountFollowTarget target)? onWrite;

  FakeSite({
    this.policy = const AccountFollowPolicy(
      writeIntervalMin: Duration(seconds: 3),
      writeIntervalMax: Duration(seconds: 6),
      batchLimit: 20,
    ),
  });

  @override
  bool get canReadAccountFollows => true;
  @override
  String get accountFollowOwner => owner;
  @override
  AccountFollowPolicy get accountFollowPolicy => policy;
  @override
  bool get canWriteAccountFollows => canWrite;

  @override
  Future<AccountFollowPage> getAccountFollows({String? cursor}) async =>
      const AccountFollowPage(items: []);

  @override
  Future<AccountFollowTarget> resolveAccountFollowTarget(String roomId) async {
    resolved.add(roomId);
    return AccountFollowTarget(roomId: "real$roomId", accountUid: "uid$roomId");
  }

  Future<void> _write(String action, AccountFollowTarget target) async {
    var error = onWrite?.call(action, target);
    if (error != null) {
      throw error;
    }
    writes.add("$action:${target.accountUid}");
  }

  @override
  Future<void> followOnAccount(AccountFollowTarget target) =>
      _write("follow", target);

  @override
  Future<void> unfollowOnAccount(AccountFollowTarget target) =>
      _write("unfollow", target);
}

AccountFollowItem item(String roomId, {String? uid, String? name}) =>
    AccountFollowItem(
      roomId: roomId,
      accountUid: uid ?? "u$roomId",
      userName: name ?? roomId,
    );

LocalFollowRef local(
  String siteId,
  String roomId, {
  String accountUid = "",
  String accountRoomId = "",
}) =>
    LocalFollowRef(
      siteId: siteId,
      roomId: roomId,
      userName: roomId,
      accountUid: accountUid,
      accountRoomId: accountRoomId,
    );

AccountFollowFetchResult fetched(
  List<AccountFollowItem> items, {
  bool complete = true,
  String? reason,
}) =>
    AccountFollowFetchResult(
      items: items,
      complete: complete,
      incompleteReason: reason,
    );

AccountFollowSnapshot snap(String siteId, List<String> roomIds,
        {String owner = "me"}) =>
    AccountFollowSnapshot(
      siteId: siteId,
      owner: owner,
      entries: roomIds.map((e) => SnapshotEntry(e, "u$e")).toList(),
      time: DateTime(2026),
    );

/// 一套内存里的队列和规则
class Harness {
  final clock = FakeClock();
  final store = MemoryAccountFollowStore();
  late final repo = AccountFollowRepository(store);
  final sites = <String, FakeSite>{};
  final enabled = <String, bool>{};
  final finished = <(String, Object?)>[];
  late final queue = AccountFollowQueue(
    repo: repo,
    siteOf: (id) => sites[id],
    isEnabled: (id) => enabled[id] ?? false,
    now: clock.now,
    sleep: clock.sleep,
    random: Random(1),
    onJobFinished: (job, error) => finished.add((job.roomId, error)),
  );
  late final sync = AccountFollowSync(
    repo: repo,
    queue: queue,
    writeBackOn: (id) => enabled[id] ?? false,
    now: clock.now,
  );

  FakeSite site(String id) => sites.putIfAbsent(id, () => FakeSite());

  Future<void> enqueue(
    String siteId,
    String roomId, {
    FollowWriteAction action = FollowWriteAction.follow,
  }) async {
    clock.advance(const Duration(milliseconds: 1));
    await sync.onLocalChange(
      siteId: siteId,
      roomId: roomId,
      userName: roomId,
      action: action,
      origin: FollowChangeOrigin.user,
    );
  }
}

void main() {
  test('every platform is import-only', () {
  for (var platform in AccountFollowPlatforms.all) {
  expect(platform.canWriteBack, isFalse, reason: platform.siteId);
  expect(platform.writeBackKey, isNull, reason: platform.siteId);
  }
  expect(AccountFollowPlatforms.writeBackKeys, isEmpty);
  });

  group('only user actions write back', () {
    test('rule table', () {
      for (var origin in FollowChangeOrigin.values) {
        expect(
          AccountFollowSync.shouldWriteBack(
            origin: origin,
            enabled: true,
            supported: true,
          ),
          origin == FollowChangeOrigin.user,
          reason: origin.name,
        );
      }
      expect(
        AccountFollowSync.shouldWriteBack(
          origin: FollowChangeOrigin.user,
          enabled: false,
          supported: true,
        ),
        isFalse,
      );
      expect(
        AccountFollowSync.shouldWriteBack(
          origin: FollowChangeOrigin.user,
          enabled: true,
          supported: false,
        ),
        isFalse,
      );
      expect(
        AccountFollowSync.shouldWriteBack(
          origin: FollowChangeOrigin.user,
          enabled: true,
          supported: true,
          localOnly: true,
        ),
        isFalse,
      );
    });

    test('imports, restores, migrations and sync never queue writes', () async {
      var h = Harness()..enabled["bilibili"] = true;
      for (var origin in FollowChangeOrigin.values.where(
        (e) => e != FollowChangeOrigin.user,
      )) {
        for (var action in FollowWriteAction.values) {
          var result = await h.sync.onLocalChange(
            siteId: "bilibili",
            roomId: "1",
            userName: "a",
            action: action,
            origin: origin,
          );
          expect(result, isNull, reason: "${origin.name} ${action.name}");
        }
      }
      expect(h.repo.jobs(), isEmpty);
      // 非用户操作的取关不留取关记录
      expect(h.repo.tombstonesForSite("bilibili"), isEmpty);
    });




    test('import adds with the import origin and never queues', () async {
      var h = Harness()..enabled["bilibili"] = true;
      var added = <FollowUser>[];
      var preview = buildImportPreview(
        siteId: "bilibili",
        items: [item("100"), item("200"), item("300")],
        locals: [local("bilibili", "100")],
      );
      preview.firstWhere((e) => e.item.roomId == "300").selected = false;
      var count = await h.sync.applyImport(
        siteId: "bilibili",
        owner: "me",
        fetch: fetched([item("100"), item("200"), item("300")]),
        entries: preview,
        tag: "B站导入",
        addLocal: (user) async {
          added.add(user);
          // 应用里 FollowService.follow(origin: import) 就是这样转过来的
          await h.sync.onLocalChange(
            siteId: user.siteId,
            roomId: user.roomId,
            userName: user.userName,
            action: FollowWriteAction.follow,
            origin: FollowChangeOrigin.import,
          );
        },
      );
      expect(count, 1);
      expect(added.single.id, "bilibili_200");
      expect(added.single.tag, "B站导入");
      expect(h.repo.jobs(), isEmpty);
      // 已在关注里的和新加的都记下对应关系，基准为这次读到的全部
      expect(h.repo.link("bilibili_100")?.accountUid, "u100");
      expect(h.repo.link("bilibili_200")?.accountUid, "u200");
      expect(h.repo.link("bilibili_300"), isNull);
      expect(h.repo.snapshot("bilibili")?.entries.length, 3);
    });

  });

  group('three-way diff', () {
    test('first sync: new on account checked, nothing removed', () {
      var diff = computeAccountFollowDiff(
        siteId: "bilibili",
        owner: "me",
        fetch: fetched([item("1"), item("2")]),
        locals: [local("bilibili", "2"), local("bilibili", "9")],
        writeBack: true,
      );
      expect(diff.firstSync, isTrue);
      expect(diff.inSync, 1);
      var add = diff.of(SyncChangeKind.addToApp).single;
      expect(add.roomId, "1");
      expect(add.selected, isTrue);
      expect(diff.of(SyncChangeKind.removeFromApp), isEmpty);
      // App 有、账号没有：只在打开同步开关时，默认不勾
      var follow = diff.of(SyncChangeKind.followOnAccount).single;
      expect(follow.roomId, "9");
      expect(follow.selected, isFalse);

      var noWriteBack = computeAccountFollowDiff(
        siteId: "bilibili",
        owner: "me",
        fetch: fetched([item("1"), item("2")]),
        locals: [local("bilibili", "2"), local("bilibili", "9")],
      );
      expect(noWriteBack.of(SyncChangeKind.followOnAccount), isEmpty);
    });

    test('with a snapshot: removed on account, known but missing in app', () {
      var diff = computeAccountFollowDiff(
        siteId: "bilibili",
        owner: "me",
        // 账号：1、3（2 在账号上取关了，4 是新关注的）
        fetch: fetched([item("1"), item("3"), item("4")]),
        locals: [local("bilibili", "1"), local("bilibili", "2")],
        snapshot: snap("bilibili", ["1", "2", "3"]),
      );
      expect(diff.firstSync, isFalse);
      expect(diff.removalsAllowed, isTrue);
      var removal = diff.of(SyncChangeKind.removeFromApp).single;
      expect(removal.roomId, "2");
      expect(removal.selected, isFalse);
      expect(removal.note, isNull);
      var restore = diff.of(SyncChangeKind.restoreToApp).single;
      expect(restore.roomId, "3");
      expect(restore.selected, isFalse);
      var add = diff.of(SyncChangeKind.addToApp).single;
      expect(add.roomId, "4");
      expect(add.selected, isTrue);
    });

    test('a partial or empty fetch is not evidence of unfollowing', () {
      var partial = computeAccountFollowDiff(
        siteId: "twitch",
        owner: "me",
        fetch: fetched([item("a")], complete: false, reason: "只读到前 100 个"),
        locals: [
          local("twitch", "a"),
          local("twitch", "b"),
          local("twitch", "c")
        ],
        snapshot: snap("twitch", ["a", "b"]),
        writeBack: true,
      );
      expect(partial.removalsAllowed, isFalse);
      expect(partial.of(SyncChangeKind.removeFromApp), isEmpty);
      expect(partial.of(SyncChangeKind.followOnAccount), isEmpty);
      expect(partial.warning, contains("只读到前 100 个"));

      var empty = computeAccountFollowDiff(
        siteId: "bilibili",
        owner: "me",
        fetch: fetched([]),
        locals: [local("bilibili", "1")],
        snapshot: snap("bilibili", ["1"]),
      );
      expect(empty.removalsAllowed, isFalse);
      expect(empty.of(SyncChangeKind.removeFromApp), isEmpty);
      expect(empty.warning, isNotNull);
    });

    test('another account means a first sync', () {
      var diff = computeAccountFollowDiff(
        siteId: "bilibili",
        owner: "someone-else",
        fetch: fetched([item("1")]),
        locals: [local("bilibili", "2")],
        snapshot: snap("bilibili", ["1", "2"]),
      );
      expect(diff.firstSync, isTrue);
      expect(diff.of(SyncChangeKind.removeFromApp), isEmpty);
      expect(diff.of(SyncChangeKind.addToApp).single.selected, isTrue);
    });

    test('Kick removals come with a note', () {
      var diff = computeAccountFollowDiff(
        siteId: "kick",
        owner: "me",
        fetch: fetched([item("a")]),
        locals: [local("kick", "a"), local("kick", "b")],
        snapshot: snap("kick", ["a", "b"]),
        listIsAuthoritative: false,
      );
      var removal = diff.of(SyncChangeKind.removeFromApp).single;
      expect(removal.note, isNotNull);
      expect(removal.selected, isFalse);
    });

    test(
        'tombstones: unfollow on account only with write-back, local-only ignored',
        () {
      var tombstones = [
        AccountFollowTombstone(
          siteId: "bilibili",
          roomId: "6",
          accountUid: "u7",
          localOnly: false,
          time: DateTime(2026),
        ),
        AccountFollowTombstone(
          siteId: "bilibili",
          roomId: "8",
          accountUid: "",
          localOnly: true,
          time: DateTime(2026),
        ),
      ];
      var on = computeAccountFollowDiff(
        siteId: "bilibili",
        owner: "me",
        fetch: fetched([item("7"), item("8")]),
        locals: const [],
        snapshot: snap("bilibili", ["7", "8"]),
        tombstones: tombstones,
        writeBack: true,
      );
      var unfollow = on.of(SyncChangeKind.unfollowOnAccount).single;
      expect(unfollow.item!.roomId, "7");
      // 回写用取关记录里的本地房间号（B站短号）
      expect(unfollow.roomId, "6");
      expect(unfollow.selected, isFalse);
      expect(on.ignored, 1);
      expect(on.of(SyncChangeKind.restoreToApp), isEmpty);

      var off = computeAccountFollowDiff(
        siteId: "bilibili",
        owner: "me",
        fetch: fetched([item("7"), item("8")]),
        locals: const [],
        snapshot: snap("bilibili", ["7", "8"]),
        tombstones: tombstones,
      );
      expect(off.changes, isEmpty);
      expect(off.ignored, 2);
    });

    test('matching uses links (short room ids) and ignores case on Kick/Twitch',
        () {
      var diff = computeAccountFollowDiff(
        siteId: "bilibili",
        owner: "me",
        fetch: fetched([item("7734200", uid: "50329118")]),
        locals: [local("bilibili", "6", accountUid: "50329118")],
        snapshot: snap("bilibili", ["7734200"]),
      );
      expect(diff.inSync, 1);
      expect(diff.changes, isEmpty);

      var kick = computeAccountFollowDiff(
        siteId: "kick",
        owner: "me",
        fetch: fetched([item("xqc")]),
        locals: [local("kick", "XQC")],
      );
      expect(kick.inSync, 1);
    });

    test('next snapshot: complete replaces, partial only adds', () {
      var previous = snap("twitch", ["a", "b"]);
      var replaced = nextAccountFollowSnapshot(
        siteId: "twitch",
        owner: "me",
        fetch: fetched([item("c")]),
        previous: previous,
        now: DateTime(2026, 11),
      );
      expect(replaced.entries.map((e) => e.roomId), ["c"]);
      var merged = nextAccountFollowSnapshot(
        siteId: "twitch",
        owner: "me",
        fetch: fetched([item("c")], complete: false),
        previous: previous,
        now: DateTime(2026, 11),
      );
      expect(merged.entries.map((e) => e.roomId), ["a", "b", "c"]);

      // 读到空列表（即使标记为完整）不覆盖原来的基准
      var empty = nextAccountFollowSnapshot(
        siteId: "twitch",
        owner: "me",
        fetch: fetched([]),
        previous: previous,
        now: DateTime(2026, 11),
      );
      expect(empty.entries.map((e) => e.roomId), ["a", "b"]);
      // 换了账号时照常替换
      var other = nextAccountFollowSnapshot(
        siteId: "twitch",
        owner: "other",
        fetch: fetched([]),
        previous: previous,
        now: DateTime(2026, 11),
      );
      expect(other.owner, "other");
      expect(other.entries, isEmpty);
    });
  });

  test('import preview marks follows already in the app', () {
    var preview = buildImportPreview(
      siteId: "bilibili",
      items: [
        item("7734200", uid: "50329118"),
        item("2"),
        item("3"),
      ],
      locals: [local("bilibili", "6", accountUid: "50329118")],
      tombstones: [
        AccountFollowTombstone(
          siteId: "bilibili",
          roomId: "3",
          accountUid: "",
          localOnly: true,
          time: DateTime(2026),
        ),
      ],
    );
    expect(preview[0].alreadyFollowed, isTrue);
    expect(preview[0].existing!.roomId, "6");
    expect(preview[0].selected, isFalse);
    expect(preview[1].alreadyFollowed, isFalse);
    expect(preview[1].selected, isTrue);
    // 以前在 App 里取消过的默认不选
    expect(preview[2].removedBefore, isTrue);
    expect(preview[2].selected, isFalse);
  });

  test('resolveUnmatched looks up short ids once and remembers them', () async {
    var h = Harness();
    var site = FakeSite(
      policy: const AccountFollowPolicy(needsRoomResolve: true),
    );
    var count = await h.sync.resolveUnmatched(
      siteId: "bilibili",
      site: site,
      locals: [
        local("bilibili", "1"),
        local("bilibili", "6"),
        local("bilibili", "8", accountUid: "known"),
      ],
      items: [item("1")],
      sleep: h.clock.sleep,
    );
    expect(count, 1);
    expect(site.resolved, ["6"]);
    expect(h.repo.link("bilibili_6")?.accountUid, "uid6");
    expect(h.repo.link("bilibili_6")?.accountRoomId, "real6");
    var noResolve = FakeSite();
    expect(
      await h.sync.resolveUnmatched(
        siteId: "kick",
        site: noResolve,
        locals: [local("kick", "a")],
        items: const [],
      ),
      0,
    );
  });


  test('Hive store keeps JSON values', () async {
    var dir = Directory.systemTemp.createTempSync("account_follow_test");
    Hive.init(dir.path);
    try {
      var store = await HiveAccountFollowStore.open();
      var repo = AccountFollowRepository(store);
      await repo.putJob(FollowWriteJob(
        id: "j1",
        siteId: "kick",
        roomId: "abc",
        userName: "Abc",
        face: "",
        action: FollowWriteAction.unfollow,
        origin: FollowChangeOrigin.sync,
        createdAt: DateTime(2026, 10, 28),
        nextAttemptAt: DateTime(2026, 10, 28, 1),
      ));
      await repo.putLink(AccountFollowLink(
        siteId: "youtube",
        roomId: "UC1",
        accountUid: "UC1",
        accountRoomId: "UC1",
        extra: {"subscriptionId": "s1"},
        linkedAt: DateTime(2026),
      ));
      await store.box.close();
      var reopened =
          AccountFollowRepository(await HiveAccountFollowStore.open());
      var job = reopened.jobs().single;
      expect(job.action, FollowWriteAction.unfollow);
      expect(job.origin, FollowChangeOrigin.sync);
      expect(job.nextAttemptAt, DateTime(2026, 10, 28, 1));
      expect(reopened.link("youtube_UC1")?.extra["subscriptionId"], "s1");
      await Hive.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
