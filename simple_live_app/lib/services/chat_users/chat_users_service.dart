import 'dart:async';
import 'dart:convert';

import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/window_changes.dart';
import 'package:simple_live_app/services/chat_users/chat_user.dart';
import 'package:simple_live_app/services/chat_users/user_block_store.dart';
import 'package:simple_live_app/services/chat_users/user_remark_store.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 存屏蔽和备注的地方（App 里是 Hive，测试里是内存）
abstract class ChatUsersStorage {
  String? read(String key);
  Future<void> write(String key, String value);
}

class MemoryChatUsersStorage implements ChatUsersStorage {
  final Map<String, String> values = {};

  @override
  String? read(String key) => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _HiveChatUsersStorage implements ChatUsersStorage {
  _HiveChatUsersStorage(this.box);
  final Box<String> box;

  @override
  String? read(String key) => box.get(key);

  @override
  Future<void> write(String key, String value) => box.put(key, value);
}

/// 弹幕里的人：屏蔽名单（永久、定时）和备注，存在本机。
///
/// 永久屏蔽和备注跟着 WebDAV、局域网同步（[exportSync]、[importSync]）；
/// 定时的只在本机，到期自动解除；“本次进入”在直播间自己那里（[UserBlockStore]），不在这里
class ChatUsersService extends GetxService {
  ChatUsersService({
    ChatUsersStorage? storage,
    this.purgeInterval = const Duration(seconds: 30),
  }) : _storage = storage;

  /// 多久检查一次到期的屏蔽（测试里为 null，不开计时器）
  final Duration? purgeInterval;

  static ChatUsersService get instance => Get.find<ChatUsersService>();

  /// 没有注册时（测试里）为 null
  static ChatUsersService? get maybeInstance =>
      Get.isRegistered<ChatUsersService>()
          ? Get.find<ChatUsersService>()
          : null;

  static const String boxName = "ChatUsers";
  static const String kBlocks = "blocks";
  static const String kRemarks = "remarks";

  /// 设置：被屏蔽的人发的 SC 和礼物也不显示（默认开启），跟着设置同步
  static const String kHidePaid = "UserBlockHidePaid";

  ChatUsersStorage? _storage;

  /// 屏蔽或备注有变化时加一，界面据此刷新
  final version = 0.obs;

  final hidePaid = true.obs;

  late final UserBlockStore blocks = UserBlockStore(
    onChanged: ({required bool persistent}) {
      _save(kBlocks, blocks.toJson());
      _changed(synced: persistent);
    },
  );

  late final UserRemarkStore remarks = UserRemarkStore(
    onChanged: () {
      _save(kRemarks, remarks.toJson());
      _changed(synced: true);
    },
  );

  final StreamController<void> _syncedChanges =
      StreamController<void>.broadcast();

  /// 永久屏蔽或备注变了（WebDAV 自动同步据此记下本机有新内容）
  Stream<void> get syncedChanges => _syncedChanges.stream;

  Timer? _purgeTimer;

  Future<ChatUsersService> init() async {
    if (_storage == null) {
      try {
        _storage = _HiveChatUsersStorage(await Hive.openBox<String>(boxName));
      } catch (e) {
        Log.logPrint("屏蔽名单读取失败：$e");
        _storage = MemoryChatUsersStorage();
      }
    }
    _load();
    if (Get.isRegistered<LocalStorageService>()) {
      hidePaid.value =
          LocalStorageService.instance.getValue<bool>(kHidePaid, true);
    }
    if (purgeInterval != null) {
      _purgeTimer = Timer.periodic(purgeInterval!, (_) {
        blocks.purgeExpired();
      });
    }
    blocks.purgeExpired();
    return this;
  }

  void _load() {
    blocks
        .load(_decode(kBlocks).map(UserBlock.fromJson).whereType<UserBlock>());
    remarks.load(
      _decode(kRemarks).map(UserRemark.fromJson).whereType<UserRemark>(),
    );
    _saved[kBlocks] = _encodeEach(blocks.toJson());
    _saved[kRemarks] = _encodeEach(remarks.toJson());
  }

  List _decode(String key) {
    var raw = _storage?.read(key);
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    try {
      var value = json.decode(raw);
      return value is List ? value : const [];
    } catch (e) {
      Log.logPrint("屏蔽名单格式不对：$e");
      return const [];
    }
  }

  void _save(String key, Object value) {
    unawaited(_storage?.write(key, json.encode(value)));
    _forwardChange(key, value);
  }

  // ---------------- 多开 ----------------

  /// 上次存下的每一条（JSON 文本），多开的副窗口据此算出改了哪几条
  final Map<String, Set<String>> _saved = {};

  static Set<String> _encodeEach(List list) =>
      {for (var e in list) json.encode(e)};

  /// 副窗口：把这次改动（去掉了哪几条、加了哪几条）交给主窗口
  void _forwardChange(String key, Object value) {
    if (value is! List) {
      return;
    }
    var now = _encodeEach(value);
    var before = _saved[key] ?? const <String>{};
    _saved[key] = now;
    if (!MultiWindow.isSecondary) {
      return;
    }
    var added = now.difference(before);
    var removed = before.difference(now);
    if (added.isEmpty && removed.isEmpty) {
      return;
    }
    Map<String, dynamic> decode(String e) =>
        Map<String, dynamic>.from(json.decode(e) as Map);
    MultiWindow.forward(ChatUsersChanged(
      key,
      add: added.map(decode).toList(),
      remove: removed.map(decode).toList(),
    ));
  }

  /// 主窗口：收到副窗口的改动。先去掉 [ChatUsersChanged.remove] 里的（同一个人、
  /// 同一个范围、同一次屏蔽或同一次写的备注；之后在这边又改过的不动），再加上新的
  void applyWindowChange(ChatUsersChanged change) {
    if (change.key == kBlocks) {
      var removed =
          change.remove.map(UserBlock.fromJson).whereType<UserBlock>().toList();
      var added =
          change.add.map(UserBlock.fromJson).whereType<UserBlock>().toList();
      var items = blocks.items
          .where((e) => !removed
              .any((r) => r.sameTarget(e) && r.createdAt == e.createdAt))
          .toList();
      for (var a in added) {
        items.removeWhere(a.sameTarget);
        items.add(a);
      }
      if (!_sameBlocks(blocks.items, items)) {
        blocks.load(items);
        _save(kBlocks, blocks.toJson());
        _changed(synced: true);
      }
    } else if (change.key == kRemarks) {
      var removed = change.remove
          .map(UserRemark.fromJson)
          .whereType<UserRemark>()
          .toList();
      var added =
          change.add.map(UserRemark.fromJson).whereType<UserRemark>().toList();
      var items = remarks.items
          .where((e) => !removed.any((r) =>
              sameChatUserId(r.user, e.user) && r.updatedAt == e.updatedAt))
          .toList();
      for (var a in added) {
        items.removeWhere((e) => sameChatUserId(e.user, a.user));
        items.add(a);
      }
      var before = json.encode(remarks.toJson());
      remarks.load(items);
      if (json.encode(remarks.toJson()) != before) {
        _save(kRemarks, remarks.toJson());
        _changed(synced: true);
      }
    }
  }

  void _changed({required bool synced}) {
    version.value++;
    if (synced && !_syncedChanges.isClosed) {
      _syncedChanges.add(null);
    }
  }

  void setHidePaid(bool value) {
    hidePaid.value = value;
    if (Get.isRegistered<LocalStorageService>()) {
      LocalStorageService.instance.setValue(kHidePaid, value);
    }
  }

  /// 收到这个人的消息：补 ID、跟着改名（屏蔽和备注都是）
  void observe(ChatUser user) {
    if (user.userId == null) {
      return;
    }
    blocks.observe(user);
    remarks.observe(user);
  }

  String? remarkOf(ChatUser user) => remarks.remarkOf(user);

  /// 聊天区、SC、礼物页显示的备注；没有注册服务（测试里）时为 null。
  /// 在 Obx 里调用时，备注改了会跟着刷新
  static String? remarkFor(
    String siteId, {
    String? userId,
    required String name,
  }) {
    var service = maybeInstance;
    if (service == null) {
      return null;
    }
    service.version.value;
    return service.remarks.remarkOf(
      ChatUser(siteId, userId: userId, name: name),
    );
  }

  // ---------------- 同步 ----------------

  /// 同步的内容：永久屏蔽和备注（定时的不同步）
  Map<String, dynamic> exportSync() => {
        "blocks": blocks.toJson(permanentOnly: true),
        "remarks": remarks.toJson(),
      };

  /// 收到同步的内容。[replace] 为 true 时（自动同步、局域网覆盖）
  /// 永久屏蔽和备注都以对方为准，本机的定时屏蔽留着；否则合并
  void importSync(
    Map data, {
    required bool replace,
    bool includeBlocks = true,
    bool includeRemarks = true,
  }) {
    if (includeBlocks && data["blocks"] is List) {
      var incoming = (data["blocks"] as List)
          .map(UserBlock.fromJson)
          .whereType<UserBlock>()
          .where((e) => e.permanent)
          .toList();
      var local = blocks.items;
      var kept = replace ? local.where((e) => !e.permanent).toList() : local;
      var merged = [
        ...kept,
        for (var e in incoming)
          if (!kept.any(e.sameTarget)) e,
      ];
      if (!_sameBlocks(local, merged)) {
        blocks.load(merged);
        _save(kBlocks, blocks.toJson());
        _changed(synced: true);
      }
    }
    if (includeRemarks && data["remarks"] is List) {
      var incoming = (data["remarks"] as List)
          .map(UserRemark.fromJson)
          .whereType<UserRemark>()
          .toList();
      if (replace) {
        var before = json.encode(remarks.toJson());
        remarks.load(incoming);
        if (json.encode(remarks.toJson()) != before) {
          _save(kRemarks, remarks.toJson());
          _changed(synced: true);
        }
      } else {
        // merge 有变化时自己会保存并通知
        remarks.merge(incoming);
      }
    }
  }

  static bool _sameBlocks(List<UserBlock> a, List<UserBlock> b) =>
      json.encode([for (var e in a) e.toJson()]) ==
      json.encode([for (var e in b) e.toJson()]);

  @override
  void onClose() {
    _purgeTimer?.cancel();
    _syncedChanges.close();
    super.onClose();
  }
}
