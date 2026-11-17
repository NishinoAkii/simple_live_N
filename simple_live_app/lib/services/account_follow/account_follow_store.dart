import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:simple_live_app/services/account_follow/account_follow_models.dart';

/// 账号关注同步的本地存储：一个 Hive box，值为 JSON 文本
///
/// 不改 FollowUser 的结构，也不进 WebDAV/局域网同步：对应关系、快照、
/// 取关记录和待同步队列都只在本机，避免两台设备重复回写。
abstract class AccountFollowStore {
  Iterable<String> get keys;
  Map<String, dynamic>? read(String key);
  Future<void> write(String key, Map<String, dynamic> value);
  Future<void> delete(String key);
}

/// 测试用的内存存储
class MemoryAccountFollowStore implements AccountFollowStore {
  final Map<String, String> data = {};

  @override
  Iterable<String> get keys => data.keys.toList();

  @override
  Map<String, dynamic>? read(String key) {
    var text = data[key];
    return text == null ? null : (jsonDecode(text) as Map).cast();
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    data[key] = jsonEncode(value);
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

class HiveAccountFollowStore implements AccountFollowStore {
  /// Hive box 名
  static const String kBoxName = "FollowAccountSync";

  final Box box;
  HiveAccountFollowStore(this.box);

  static Future<HiveAccountFollowStore> open() async =>
      HiveAccountFollowStore(await Hive.openBox(kBoxName));

  @override
  Iterable<String> get keys => box.keys.map((e) => e.toString()).toList();

  @override
  Map<String, dynamic>? read(String key) {
    var value = box.get(key);
    if (value is! String) {
      return null;
    }
    try {
      return (jsonDecode(value) as Map).cast();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) =>
      box.put(key, jsonEncode(value));

  @override
  Future<void> delete(String key) => box.delete(key);
}

/// 按类型读写：对应关系（link|关注 id）、快照（snap|平台）、取关记录（gone|关注 id）、
/// 待同步（job|任务 id）、队列状态（site|平台）
class AccountFollowRepository {
  final AccountFollowStore store;
  AccountFollowRepository(this.store);

  static const String _link = "link|";
  static const String _snap = "snap|";
  static const String _gone = "gone|";
  static const String _job = "job|";
  static const String _site = "site|";

  /// 每个平台最多保留的取关记录
  static const int maxTombstonesPerSite = 500;

  Iterable<Map<String, dynamic>> _values(String prefix) => store.keys
      .where((e) => e.startsWith(prefix))
      .map(store.read)
      .whereType<Map<String, dynamic>>();

  // ---- 对应关系 ----

  AccountFollowLink? link(String followId) {
    var json = store.read("$_link$followId");
    return json == null ? null : AccountFollowLink.fromJson(json);
  }

  List<AccountFollowLink> linksForSite(String siteId) => _values(_link)
      .map(AccountFollowLink.fromJson)
      .where((e) => e.siteId == siteId)
      .toList();

  Future<void> putLink(AccountFollowLink link) =>
      store.write("$_link${link.followId}", link.toJson());

  Future<void> deleteLink(String followId) => store.delete("$_link$followId");

  // ---- 快照 ----

  AccountFollowSnapshot? snapshot(String siteId) {
    var json = store.read("$_snap$siteId");
    return json == null ? null : AccountFollowSnapshot.fromJson(json);
  }

  Future<void> putSnapshot(AccountFollowSnapshot snapshot) =>
      store.write("$_snap${snapshot.siteId}", snapshot.toJson());

  // ---- 取关记录 ----

  AccountFollowTombstone? tombstone(String followId) {
    var json = store.read("$_gone$followId");
    return json == null ? null : AccountFollowTombstone.fromJson(json);
  }

  List<AccountFollowTombstone> tombstonesForSite(String siteId) =>
      _values(_gone)
          .map(AccountFollowTombstone.fromJson)
          .where((e) => e.siteId == siteId)
          .toList();

  Future<void> putTombstone(AccountFollowTombstone tombstone) async {
    await store.write("$_gone${tombstone.followId}", tombstone.toJson());
    var all = tombstonesForSite(tombstone.siteId);
    if (all.length > maxTombstonesPerSite) {
      all.sort((a, b) => a.time.compareTo(b.time));
      for (var old in all.take(all.length - maxTombstonesPerSite)) {
        await deleteTombstone(old.followId);
      }
    }
  }

  Future<void> deleteTombstone(String followId) =>
      store.delete("$_gone$followId");

  // ---- 待同步 ----

  List<FollowWriteJob> jobs({String? siteId}) {
    var list = _values(_job)
        .map(FollowWriteJob.fromJson)
        .where((e) => siteId == null || e.siteId == siteId)
        .toList();
    list.sort((a, b) {
      var c = a.createdAt.compareTo(b.createdAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return list;
  }

  FollowWriteJob? job(String id) {
    var json = store.read("$_job$id");
    return json == null ? null : FollowWriteJob.fromJson(json);
  }

  Future<void> putJob(FollowWriteJob job) =>
      store.write("$_job${job.id}", job.toJson());

  Future<void> deleteJob(String id) => store.delete("$_job$id");

  // ---- 队列状态 ----

  AccountFollowSiteState siteState(String siteId) {
    var json = store.read("$_site$siteId");
    return json == null
        ? AccountFollowSiteState(siteId: siteId)
        : AccountFollowSiteState.fromJson(json);
  }

  Future<void> putSiteState(AccountFollowSiteState state) =>
      store.write("$_site${state.siteId}", state.toJson());
}
