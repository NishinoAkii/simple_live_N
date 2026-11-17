import 'dart:convert';

import 'package:get/get.dart';
import 'package:simple_live_app/app/danmaku_dedupe.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 重复弹幕过滤和弹幕延迟的设置，混入 AppSettingsController。
///
/// - 重复弹幕过滤的几项可以按直播间、平台单独设置（[danmakuFilterScoped] 放进 `_scoped`）；
/// - 弹幕延迟本来就是每个平台一个值，不跟单独设置走。
mixin DanmakuFilterSettings on GetxController {
  /// 过滤重复弹幕（默认关）
  static const String kDedupe = "DanmuDedupe";

  /// 时间范围（秒）
  static const String kDedupeWindow = "DanmuDedupeWindow";

  /// 比较方式：[modeUser] 同一个人，[modeContent] 只看内容
  static const String kDedupeMode = "DanmuDedupeMode";

  /// 时间范围里同样的弹幕最多显示几次
  static const String kDedupeMax = "DanmuDedupeMax";

  /// 聊天区也去掉重复（录屏接口、弹幕记录跟着聊天区）
  static const String kDedupeChat = "DanmuDedupeChat";

  /// 各平台的弹幕延迟：JSON，平台 id → 十分之一秒
  static const String kDelayBySite = "DanmuDelayBySite";

  /// 这几项只有本版本有，备份时放在扩展部分（见 SyncCompat.forkSettingKeys）
  static const List<String> storageKeys = [
    kDedupe,
    kDedupeWindow,
    kDedupeMode,
    kDedupeMax,
    kDedupeChat,
    kDelayBySite,
  ];

  static const int modeUser = 0;
  static const int modeContent = 1;

  static const int defaultWindow = 10;
  static const int minWindow = 3;
  static const int maxWindow = 60;
  static const int defaultMax = 1;
  static const int minMax = 1;
  static const int maxMax = 5;

  /// 弹幕延迟最多 5 秒，每档 0.1 秒（存的是十分之一秒）
  static const int maxDelayTenths = 50;

  final danmuDedupe = false.obs;
  final danmuDedupeWindow = defaultWindow.obs;
  final danmuDedupeMode = modeUser.obs;
  final danmuDedupeMax = defaultMax.obs;
  final danmuDedupeChat = false.obs;

  /// 各平台的弹幕延迟（十分之一秒），没有的是 0
  final danmuDelayBySite = <String, int>{}.obs;

  /// 保存一项可以单独设置的设置（AppSettingsController 接到它的 `_saveScoped`）
  void saveScopedSetting(String field, Object value);

  /// 可以单独设置的几项：存储键 → (当前值, 默认值)，放进 AppSettingsController 的 `_scoped`
  Map<String, (Rx<dynamic>, Object Function())> get danmakuFilterScoped => {
        kDedupe: (danmuDedupe, () => false),
        kDedupeWindow: (danmuDedupeWindow, () => defaultWindow),
        kDedupeMode: (danmuDedupeMode, () => modeUser),
        kDedupeMax: (danmuDedupeMax, () => defaultMax),
        kDedupeChat: (danmuDedupeChat, () => false),
      };

  void loadDanmakuFilterSettings() {
    var storage = LocalStorageService.instance;
    danmuDedupe.value = storage.getValue(kDedupe, false);
    danmuDedupeWindow.value = storage
        .getValue(kDedupeWindow, defaultWindow)
        .clamp(minWindow, maxWindow);
    danmuDedupeMode.value = storage.getValue(kDedupeMode, modeUser);
    danmuDedupeMax.value =
        storage.getValue(kDedupeMax, defaultMax).clamp(minMax, maxMax);
    danmuDedupeChat.value = storage.getValue(kDedupeChat, false);
    danmuDelayBySite.assignAll(
      decodeDanmakuDelays(storage.getValue<String>(kDelayBySite, "")),
    );
  }

  void setDanmuDedupe(bool e) {
    danmuDedupe.value = e;
    saveScopedSetting(kDedupe, e);
  }

  void setDanmuDedupeWindow(int e) {
    e = e.clamp(minWindow, maxWindow);
    danmuDedupeWindow.value = e;
    saveScopedSetting(kDedupeWindow, e);
  }

  void setDanmuDedupeMode(int e) {
    danmuDedupeMode.value = e;
    saveScopedSetting(kDedupeMode, e);
  }

  void setDanmuDedupeMax(int e) {
    e = e.clamp(minMax, maxMax);
    danmuDedupeMax.value = e;
    saveScopedSetting(kDedupeMax, e);
  }

  void setDanmuDedupeChat(bool e) {
    danmuDedupeChat.value = e;
    saveScopedSetting(kDedupeChat, e);
  }

  /// 现在生效的过滤设置（直播间每条弹幕读一次）
  DanmakuDedupeOptions get danmakuDedupeOptions {
    if (!danmuDedupe.value) {
      return DanmakuDedupeOptions.off;
    }
    return DanmakuDedupeOptions(
      windowSeconds: danmuDedupeWindow.value.clamp(minWindow, maxWindow),
      byUser: danmuDedupeMode.value != modeContent,
      maxCount: danmuDedupeMax.value.clamp(minMax, maxMax),
      chatToo: danmuDedupeChat.value,
    );
  }

  /// [siteId] 这个平台的弹幕延迟（十分之一秒）
  int danmuDelayTenths(String siteId) => danmuDelayBySite[siteId] ?? 0;

  /// [siteId] 这个平台的弹幕延迟（毫秒）
  int danmuDelayMs(String siteId) => danmuDelayTenths(siteId) * 100;

  void setDanmuDelay(String siteId, int tenths) {
    if (siteId.isEmpty) {
      return;
    }
    tenths = tenths.clamp(0, maxDelayTenths);
    if (tenths == 0) {
      danmuDelayBySite.remove(siteId);
    } else {
      danmuDelayBySite[siteId] = tenths;
    }
    LocalStorageService.instance.setValue(
      kDelayBySite,
      danmuDelayBySite.isEmpty ? "" : json.encode(danmuDelayBySite),
    );
  }

  /// 读存着的各平台延迟，坏的、超出范围的值不要
  static Map<String, int> decodeDanmakuDelays(String raw) {
    if (raw.isEmpty) {
      return {};
    }
    try {
      var map = json.decode(raw);
      if (map is! Map) {
        return {};
      }
      return {
        for (var e in map.entries)
          if (e.value is num && (e.value as num) > 0)
            e.key.toString(): (e.value as num).round().clamp(0, maxDelayTenths),
      };
    } catch (_) {
      return {};
    }
  }
}
