import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/window_changes.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 播放设置：记住上次的清晰度、全屏方向。
///
/// 都只存本机，不进备份和同步（见 SyncCompat.localOnlySettingKeys）。
/// 没注册存储时（测试里）用默认值，改动也不保存
class PlayPrefs {
  PlayPrefs._();

  static PlayPrefs? _instance;
  static PlayPrefs get instance => _instance ??= PlayPrefs._()..load();

  @visibleForTesting
  static set instance(PlayPrefs? value) => _instance = value;

  @visibleForTesting
  factory PlayPrefs.forTest() => PlayPrefs._();

  /// 「默认清晰度」选了「记住上次」
  final rememberQuality = false.obs;

  /// 「数据网络清晰度」选了「记住上次」
  final rememberQualityCellular = false.obs;

  /// 全屏方向（安卓）：0 智能，1 强制横屏，2 跟随系统
  final fullscreenOrientation = 0.obs;

  /// 各平台上次手动选的清晰度，Wi-Fi 等和数据网络各一份
  final Map<String, RememberedQuality> _memory = {};
  final Map<String, RememberedQuality> _memoryCellular = {};

  LocalStorageService? get _storage => Get.isRegistered<LocalStorageService>()
      ? LocalStorageService.instance
      : null;

  void load() {
    var storage = _storage;
    if (storage == null) {
      return;
    }
    rememberQuality.value =
        storage.getValue(LocalStorageService.kQualityRemember, false);
    rememberQualityCellular.value =
        storage.getValue(LocalStorageService.kQualityRememberCellular, false);
    fullscreenOrientation.value =
        storage.getValue(LocalStorageService.kFullscreenOrientation, 0);
    _memory
      ..clear()
      ..addAll(RememberedQuality.decodeAll(
          storage.getValue<String>(LocalStorageService.kQualityMemory, "")));
    _memoryCellular
      ..clear()
      ..addAll(RememberedQuality.decodeAll(storage.getValue<String>(
          LocalStorageService.kQualityMemoryCellular, "")));
  }

  void setRememberQuality(bool value, {required bool cellular}) {
    var target = cellular ? rememberQualityCellular : rememberQuality;
    target.value = value;
    _storage?.setValue(
      cellular
          ? LocalStorageService.kQualityRememberCellular
          : LocalStorageService.kQualityRemember,
      value,
    );
  }

  void setFullscreenOrientation(int value) {
    fullscreenOrientation.value = value;
    _storage?.setValue(LocalStorageService.kFullscreenOrientation, value);
  }

  /// 这个平台上次手动选的清晰度（数据网络下看数据网络那一份）；没记过时为 null
  RememberedQuality? remembered(String siteId, {required bool cellular}) =>
      (cellular ? _memoryCellular : _memory)[siteId];

  /// 手动切换清晰度时记下来。不管有没有选「记住上次」都记，选上以后马上能用
  void rememberManualQuality(
    String siteId,
    List<LivePlayQuality> qualities,
    int index, {
    required bool cellular,
  }) {
    if (index < 0 || index >= qualities.length) {
      return;
    }
    var value = RememberedQuality(qualities[index].quality, index);
    storeRemembered(siteId, value, cellular: cellular);
    // 多开的副窗口：交给主窗口记下
    MultiWindow.forward(QualityRemembered(
      siteId: siteId,
      name: value.name,
      index: index,
      cellular: cellular,
    ));
  }

  /// 记下这个平台的清晰度并保存
  void storeRemembered(
    String siteId,
    RememberedQuality value, {
    required bool cellular,
  }) {
    var map = cellular ? _memoryCellular : _memory;
    map[siteId] = value;
    try {
      _storage?.setValue(
        cellular
            ? LocalStorageService.kQualityMemoryCellular
            : LocalStorageService.kQualityMemory,
        RememberedQuality.encodeAll(map),
      );
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 进直播间时选清晰度：选了「记住上次」并且这个平台记过时用记下的那一档，否则用 [fallback]
  int pickQuality(
    String siteId,
    List<LivePlayQuality> qualities,
    int fallback, {
    required bool cellular,
  }) {
    var on = cellular ? rememberQualityCellular.value : rememberQuality.value;
    if (!on) {
      return fallback;
    }
    var index = RememberedQuality.resolve(
      qualities,
      remembered(siteId, cellular: cellular),
    );
    return index < 0 ? fallback : index;
  }
}

/// 记下的一档清晰度：名字和它在列表里的位置（0 是最高）
class RememberedQuality {
  final String name;
  final int index;
  const RememberedQuality(this.name, this.index);

  /// 在这个直播间的清晰度里找：先按名字找，找不到时按位置，
  /// 位置超出时用最低一档；没记过或列表是空的返回 -1
  static int resolve(List<LivePlayQuality> qualities, RememberedQuality? saved) {
    if (saved == null || qualities.isEmpty) {
      return -1;
    }
    var byName = qualities.indexWhere((e) => e.quality == saved.name);
    if (byName >= 0) {
      return byName;
    }
    if (saved.index < 0) {
      return -1;
    }
    return saved.index.clamp(0, qualities.length - 1).toInt();
  }

  static String encodeAll(Map<String, RememberedQuality> map) => json.encode({
        for (var e in map.entries)
          e.key: {"name": e.value.name, "index": e.value.index},
      });

  /// 读坏了或者格式不对的项跳过
  static Map<String, RememberedQuality> decodeAll(String text) {
    if (text.isEmpty) {
      return {};
    }
    try {
      var data = json.decode(text);
      if (data is! Map) {
        return {};
      }
      var result = <String, RememberedQuality>{};
      data.forEach((key, value) {
        if (value is Map) {
          var name = value["name"];
          var index = value["index"];
          if (name is String && name.isNotEmpty && index is int) {
            result[key.toString()] = RememberedQuality(name, index);
          }
        }
      });
      return result;
    } catch (e) {
      Log.logPrint(e);
      return {};
    }
  }
}
