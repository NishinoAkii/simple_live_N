import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/multi_window/window_layout.dart';
import 'package:simple_live_app/app/window_geometry.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 一个窗口在看的直播间。标题和主播名只是显示用，没读到时为空
class WindowRoom {
  final String siteId;
  final String roomId;
  final String title;
  final String userName;
  const WindowRoom({
    required this.siteId,
    required this.roomId,
    this.title = "",
    this.userName = "",
  });

  /// 同一个直播间
  String get key => "$siteId|$roomId";

  /// 显示用：主播名，没有时用标题，再没有用房间号
  String get label => userName.isNotEmpty
      ? userName
      : title.isNotEmpty
          ? title
          : roomId;

  Map<String, dynamic> toJson() => {
        "site": siteId,
        "room": roomId,
        if (title.isNotEmpty) "title": title,
        if (userName.isNotEmpty) "name": userName,
      };

  /// 内容不对时抛 [FormatException]。平台和房间号要能放进启动参数（见 [SecondaryLaunch]）
  static WindowRoom fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException("room");
    }
    return WindowRoom(
      siteId: _id(json["site"]),
      roomId: _id(json["room"]),
      title: _text(json["title"] ?? "", 512),
      userName: _text(json["name"] ?? "", 512),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WindowRoom &&
      other.siteId == siteId &&
      other.roomId == roomId &&
      other.title == title &&
      other.userName == userName;

  @override
  int get hashCode => Object.hash(siteId, roomId, title, userName);

  @override
  String toString() => "WindowRoom($key, $label)";
}

/// 一个副窗口：第几个、在看的直播间、位置和大小（物理像素）和当时屏幕的缩放
class WindowEntry {
  final int slot;
  final WindowRoom room;
  final Rect? bounds;
  final double scale;
  const WindowEntry({
    required this.slot,
    required this.room,
    this.bounds,
    this.scale = 1.0,
  });

  WindowEntry copyWith({WindowRoom? room, Rect? bounds, double? scale}) =>
      WindowEntry(
        slot: slot,
        room: room ?? this.room,
        bounds: bounds ?? this.bounds,
        scale: scale ?? this.scale,
      );

  Map<String, dynamic> toJson() => {
        "slot": slot,
        ...room.toJson(),
        if (bounds != null) ..._geometryJson(bounds!, scale),
      };

  static WindowEntry fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException("window");
    }
    var slot = json["slot"];
    if (slot is! int || slot < 1 || slot > SecondaryLaunch.maxWindows) {
      throw const FormatException("slot");
    }
    var bounds = _bounds(json);
    return WindowEntry(
      slot: slot,
      room: WindowRoom.fromJson(json),
      bounds: bounds,
      scale: bounds == null ? 1.0 : _scale(json["scale"]),
    );
  }

  @override
  String toString() => "WindowEntry($slot, $room, $bounds, x$scale)";
}

/// 记下来的一组副窗口（按打开的顺序，后开的在后面），连同当时主窗口在看的直播间
/// （[mainRoom]，不在直播间时为空）
class WindowSet {
  /// 存档的格式。读到别的版本（以后改了格式）时当作没有
  static const version = 1;

  final List<WindowEntry> windows;
  final WindowRoom? mainRoom;
  final DateTime time;
  const WindowSet(this.windows, {this.mainRoom, required this.time});

  bool get isEmpty => windows.isEmpty;

  /// 提示里列的名字
  String get labels => windows.map((e) => e.room.label).join("、");

  String encode() => jsonEncode({
        "v": version,
        "time": time.millisecondsSinceEpoch,
        if (mainRoom != null) "main": mainRoom!.toJson(),
        "windows": [for (var e in windows) e.toJson()],
      });

  /// 读不出来、格式版本不对时为 null；单个窗口的记录坏了只丢掉那一个
  static WindowSet? decode(String? text) {
    if (text == null || text.isEmpty) {
      return null;
    }
    try {
      var json = jsonDecode(text);
      if (json is! Map || json["v"] != version || json["windows"] is! List) {
        return null;
      }
      var windows = <WindowEntry>[];
      var slots = <int>{};
      for (var item in json["windows"] as List) {
        if (windows.length >= SecondaryLaunch.maxWindows) {
          break;
        }
        try {
          var entry = WindowEntry.fromJson(item);
          if (slots.add(entry.slot)) {
            windows.add(entry);
          }
        } on FormatException {
          // 坏了的这一个不要
        }
      }
      WindowRoom? mainRoom;
      if (json["main"] != null) {
        try {
          mainRoom = WindowRoom.fromJson(json["main"]);
        } on FormatException {
          mainRoom = null;
        }
      }
      var time = json["time"];
      return WindowSet(
        windows,
        mainRoom: mainRoom,
        time: DateTime.fromMillisecondsSinceEpoch(time is int ? time : 0),
      );
    } catch (_) {
      return null;
    }
  }
}

/// 副窗口告诉主窗口的事：在看哪个直播间（[room]）、窗口挪到了哪里（[bounds]，物理像素，
/// 连同所在屏幕的缩放）。两项至少有一项
class WindowReport {
  final WindowRoom? room;
  final Rect? bounds;
  final double scale;
  const WindowReport({this.room, this.bounds, this.scale = 1.0});

  Map<String, dynamic> toJson() => {
        if (room != null) "room": room!.toJson(),
        if (bounds != null) ..._geometryJson(bounds!, scale),
      };

  /// 内容不对时抛 [FormatException]（主窗口回 400）
  static WindowReport decode(Object? body) {
    if (body is! Map) {
      throw const FormatException("report");
    }
    var room = body["room"] == null ? null : WindowRoom.fromJson(body["room"]);
    var bounds = _bounds(body);
    if (room == null && bounds == null) {
      throw const FormatException("empty");
    }
    return WindowReport(
      room: room,
      bounds: bounds,
      scale: bounds == null ? 1.0 : _scale(body["scale"]),
    );
  }
}

/// 记着开着的副窗口，定下“上次的一组”（历史页“打开上次的窗口”用）。
///
/// - 开窗口、副窗口挪动或改大小、换直播间时更新开着的这一组（[kOpen]，随时存，
///   主窗口崩了、直接关机时下次启动拿它当上次的一组）；
/// - 关全部多开窗口、主窗口退出时（[closingAll]），开着的这一组定下来存进 [kLast]，
///   这样关掉的窗口都还在里面；
/// - 别的窗口还开着时手动关掉一个，它从这一组里去掉；手动关掉最后一个时，
///   这一组到此为止，连同它一起定下来；
/// - 同时记下当时主窗口在看的直播间，打开时主窗口不在直播间里就在主窗口打开它；
/// - 每个编号（第几个窗口）记住用户拖到的位置和大小（[kSlots]），下次开到这个编号时放回去。
///
/// 都只存在本机（SyncCompat.localOnlySettingKeys），旧版本不认识这几项，不读也不用
class WindowSetRecorder {
  WindowSetRecorder({
    WindowRoom? Function()? mainRoom,
    this.saveDelay = const Duration(milliseconds: 600),
    DateTime Function()? clock,
  })  : _mainRoom = mainRoom,
        _clock = clock ?? DateTime.now;

  static const String kLast = "MultiWindowLastSet";
  static const String kOpen = "MultiWindowOpenSet";
  static const String kSlots = "MultiWindowSlotPlacements";
  static const List<String> storageKeys = [kLast, kOpen, kSlots];

  /// 挪窗口时连着来很多次，停下这么久以后再存
  final Duration saveDelay;
  final WindowRoom? Function()? _mainRoom;
  final DateTime Function() _clock;

  /// 按打开的顺序（重新开到同一个编号的排到最后）
  final Map<int, WindowEntry> _entries = {};

  /// 刚开时放的位置：报上来的还是这里就不算用户挪过
  final Map<int, Rect> _launched = {};
  final Map<int, WindowPlacement> _slots = {};
  final Set<int> _closing = {};
  final Rx<WindowSet?> _last = Rx<WindowSet?>(null);
  bool _loaded = false;
  Timer? _saveTimer;

  static LocalStorageService? get _storage =>
      Get.isRegistered<LocalStorageService>()
          ? LocalStorageService.instance
          : null;

  /// 上次的一组（没有时为 null）
  Rx<WindowSet?> get last {
    _load();
    return _last;
  }

  /// 开着的副窗口，含正在关的（按打开的顺序）
  List<WindowEntry> get entries => _entries.values.toList();

  /// 每个编号记住的位置和大小（用户挪过、改过大小的）
  Map<int, WindowPlacement> get slotPlacements {
    _load();
    return Map.unmodifiable(_slots);
  }

  /// 开着、不在关的副窗口
  List<WindowEntry> get active => [
        for (var e in entries)
          if (!_closing.contains(e.slot)) e,
      ];

  /// 正在关的（关全部、主窗口退出时请它们退出了，还没退）
  Set<int> get closing => Set.unmodifiable(_closing);

  void opened(WindowEntry entry) {
    _load();
    _entries.remove(entry.slot);
    _entries[entry.slot] = entry;
    _closing.remove(entry.slot);
    if (entry.bounds != null) {
      _launched[entry.slot] = entry.bounds!;
    } else {
      _launched.remove(entry.slot);
    }
    _saveOpen();
  }

  /// 副窗口报告了位置或直播间
  void reported(int slot, WindowReport report) {
    var entry = _entries[slot];
    if (entry == null) {
      return;
    }
    _entries[slot] = entry.copyWith(
      room: report.room,
      bounds: report.bounds,
      scale: report.bounds == null ? null : report.scale,
    );
    if (!_closing.contains(slot)) {
      _scheduleSave();
    }
    var bounds = report.bounds;
    if (bounds != null && !_near(bounds, _launched[slot])) {
      // 用户挪过、改过大小：这个编号以后都放在这里
      _launched.remove(slot);
      _slots[slot] = WindowPlacement(bounds, report.scale);
      unawaited(_write(kSlots, _encodeSlots()));
    }
  }

  static bool _near(Rect a, Rect? b) =>
      b != null &&
      (a.left - b.left).abs() <= 2 &&
      (a.top - b.top).abs() <= 2 &&
      (a.width - b.width).abs() <= 2 &&
      (a.height - b.height).abs() <= 2;

  String _encodeSlots() => jsonEncode({
        for (var e in _slots.entries) "${e.key}": jsonDecode(e.value.encode()),
      });

  /// 主窗口换了直播间
  void mainRoomChanged() {
    if (active.isNotEmpty) {
      _scheduleSave();
    }
  }

  /// 副窗口的进程退出了
  void exited(int slot) {
    var entry = _entries.remove(slot);
    _launched.remove(slot);
    if (entry == null) {
      return;
    }
    // 关全部、主窗口退出时关的：已经定在上次的一组里
    if (_closing.remove(slot)) {
      return;
    }
    if (active.isNotEmpty) {
      // 手动关掉一个，别的还开着：从这一组去掉
      _saveOpen();
      return;
    }
    // 手动关掉了最后一个：这一组到此为止
    unawaited(_freeze([entry]));
  }

  /// 关全部多开窗口、主窗口退出：开着的这一组定下来，之后它们退出时不再改。
  /// 没有开着的窗口时什么都不做，返回 false
  Future<bool> closingAll() async {
    var list = active;
    if (list.isEmpty) {
      return false;
    }
    _closing.addAll(list.map((e) => e.slot));
    await _freeze(list);
    return true;
  }

  /// 马上存（不等 [saveDelay]）
  Future<void> flush() async {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      await _saveOpen();
    }
  }

  void _load() {
    if (_loaded) {
      return;
    }
    _loaded = true;
    var storage = _storage;
    if (storage == null) {
      return;
    }
    var last = WindowSet.decode(storage.getValue<String>(kLast, ""));
    var openText = storage.getValue<String>(kOpen, "");
    if (openText.isNotEmpty) {
      var open = WindowSet.decode(openText);
      // 上次主窗口没有正常退出（崩了、直接关机）：当时开着的就是上次的一组
      if (open != null && !open.isEmpty) {
        last = open;
        unawaited(_write(kLast, open.encode()));
        Log.i("多开：上次没有正常退出，记下当时开着的 ${open.windows.length} 个窗口");
      }
      unawaited(_write(kOpen, null));
    }
    _last.value = last == null || last.isEmpty ? null : last;
    try {
      var json = jsonDecode(storage.getValue<String>(kSlots, ""));
      if (json is Map) {
        json.forEach((key, value) {
          var slot = int.tryParse(key.toString());
          var placement = WindowPlacement.decode(jsonEncode(value));
          if (slot != null &&
              slot >= 1 &&
              slot <= SecondaryLaunch.maxWindows &&
              placement != null) {
            _slots[slot] = placement;
          }
        });
      }
    } catch (_) {
      // 没存过、坏了：当作都没记过
    }
  }

  WindowSet _snapshot(List<WindowEntry> list) =>
      WindowSet(list, mainRoom: _mainRoom?.call(), time: _clock());

  Future<void> _freeze(List<WindowEntry> list) async {
    _load();
    _saveTimer?.cancel();
    var set = _snapshot(list);
    _last.value = set;
    Log.i("多开：记下这一组 ${list.length} 个窗口");
    await Future.wait([_write(kLast, set.encode()), _write(kOpen, null)]);
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    if (saveDelay == Duration.zero) {
      unawaited(_saveOpen());
      return;
    }
    _saveTimer = Timer(saveDelay, () => unawaited(_saveOpen()));
  }

  Future<void> _saveOpen() {
    _saveTimer?.cancel();
    var list = active;
    return _write(kOpen, list.isEmpty ? null : _snapshot(list).encode());
  }

  Future<void> _write(String key, String? value) async {
    var storage = _storage;
    if (storage == null) {
      return;
    }
    try {
      if (value == null) {
        await storage.removeValue(key);
      } else {
        await storage.setValue<String>(key, value);
      }
    } catch (e) {
      Log.logPrint(e);
    }
  }
}

/// 启动时恢复上次的多开窗口：询问（默认）、直接打开、不打开
enum StartupRestore { ask, open, off }

/// 主窗口启动时要做的：不管、问一下、直接打开
enum StartupAction { none, ask, open }

/// “启动时恢复上次的多开窗口”的设置，只在本机（SyncCompat.localOnlySettingKeys）
class StartupRestoreSetting {
  StartupRestoreSetting._();

  static const String kKey = "MultiWindowRestoreOnStart";

  static final Rx<StartupRestore> _value = StartupRestore.ask.obs;
  static bool _loaded = false;

  /// 现在的设置（第一次用时从存档读）
  static Rx<StartupRestore> get value {
    if (!_loaded) {
      _loaded = true;
      var storage = WindowSetRecorder._storage;
      _value.value = parse(storage?.getValue<String>(kKey, ""));
    }
    return _value;
  }

  static Future<void> set(StartupRestore choice) async {
    _loaded = true;
    _value.value = choice;
    await WindowSetRecorder._storage?.setValue<String>(kKey, choice.name);
  }

  static StartupRestore parse(String? text) => StartupRestore.values.firstWhere(
        (e) => e.name == text,
        orElse: () => StartupRestore.ask,
      );

  /// 测试用：下次重新从存档读
  static void reset() {
    _loaded = false;
    _value.value = StartupRestore.ask;
  }

  /// 主窗口启动时怎么办。[canOpen]：能开多开窗口的主窗口（副窗口、不是电脑时为 false）；
  /// [last]：上次的一组；[forRoom]：这次启动是为了打开某个直播间（链接、参数）
  static StartupAction decide(
    StartupRestore setting, {
    required bool canOpen,
    required WindowSet? last,
    required bool forRoom,
  }) {
    if (!canOpen || forRoom || last == null || last.isEmpty) {
      return StartupAction.none;
    }
    return switch (setting) {
      StartupRestore.ask => StartupAction.ask,
      StartupRestore.open => StartupAction.open,
      StartupRestore.off => StartupAction.none,
    };
  }
}

/// 打开上次的一组里的一个窗口：用第几个、放在哪里（物理像素，为空时居中）、那块屏幕的缩放
class RestoreTarget {
  final WindowEntry saved;
  final int slot;
  final Rect? bounds;
  final double scale;

  /// 放回了上次的位置（false：那块屏幕找不到了，按这个编号记的位置或者错开放）
  final bool atSavedSpot;
  const RestoreTarget({
    required this.saved,
    required this.slot,
    required this.bounds,
    required this.scale,
    required this.atSavedSpot,
  });
}

class RestorePlan {
  /// 按上次打开的顺序（后开的在上面）
  final List<RestoreTarget> windows;

  /// 已经开着（在副窗口或主窗口里）的直播间，没有再开
  final int skipped;

  /// 超出同时开的上限，没有开
  final int limited;

  /// 要在主窗口里打开的直播间（主窗口不在直播间里时）
  final WindowRoom? mainRoom;
  const RestorePlan({
    required this.windows,
    required this.skipped,
    required this.limited,
    this.mainRoom,
  });
}

/// 多开窗口放哪里、“打开上次的窗口”怎么开，都是纯计算
class WindowRestore {
  WindowRestore._();

  /// 新开到第 [slot] 个的窗口放哪里：这个编号记过位置（[remembered]）、还在某块屏幕上就放回去；
  /// 没记过（第一次用）时从前一个开着的窗口（编号比它小的里面最大的，[open]），
  /// 没有时从主窗口往右下错开。一块屏幕都没有时为 null
  static (Rect, double)? place(
    int slot, {
    required List<ScreenArea> screens,
    Map<int, WindowPlacement> remembered = const {},
    Map<int, Rect> open = const {},
    Rect? main,
  }) {
    var memory = remembered[slot];
    if (memory != null) {
      var spot = savedSpot(memory.rect, memory.scale, screens);
      if (spot != null) {
        return spot;
      }
    }
    var before = open.keys.where((e) => e < slot).toList()..sort();
    return WindowLayout.cascade(
        screens, before.isEmpty ? main : open[before.last]);
  }

  /// 按上次打开的顺序开（后开的在上面）：每个放回它上次的位置；那块屏幕找不到了时按 [place]。
  /// [usedSlots]、[open]：开着的副窗口（含正在关的）占着的编号和位置；
  /// [openRooms]：开着的直播间（[WindowRoom.key]）；[mainRoomNow]：主窗口现在在看的
  static RestorePlan plan(
    WindowSet saved, {
    required List<ScreenArea> screens,
    Map<int, WindowPlacement> remembered = const {},
    Map<int, Rect> open = const {},
    Set<int> usedSlots = const {},
    Set<String> openRooms = const {},
    Rect? main,
    double fallbackScale = 1.0,
    WindowRoom? mainRoomNow,
    int max = SecondaryLaunch.maxWindows,
  }) {
    var rooms = {...openRooms, if (mainRoomNow != null) mainRoomNow.key};
    var used = {...usedSlots};
    var placed = {...open};
    var targets = <RestoreTarget>[];
    var skipped = 0;
    var limited = 0;
    for (var entry in saved.windows) {
      if (rooms.contains(entry.room.key)) {
        skipped++;
        continue;
      }
      // 编号尽量用上次的
      int? slot =
          entry.slot <= max && !used.contains(entry.slot) ? entry.slot : null;
      for (var i = 1; slot == null && i <= max; i++) {
        if (!used.contains(i)) {
          slot = i;
        }
      }
      if (slot == null) {
        limited++;
        continue;
      }
      var spot = entry.bounds == null
          ? null
          : savedSpot(entry.bounds!, entry.scale, screens);
      var where = spot ??
          place(slot,
              screens: screens,
              remembered: remembered,
              open: placed,
              main: main);
      used.add(slot);
      rooms.add(entry.room.key);
      if (where != null) {
        placed[slot] = where.$1;
      }
      targets.add(RestoreTarget(
        saved: entry,
        slot: slot,
        bounds: where?.$1,
        scale: where?.$2 ?? fallbackScale,
        atSavedSpot: spot != null,
      ));
    }
    var mainRoom = saved.mainRoom;
    if (mainRoomNow != null ||
        mainRoom == null ||
        rooms.contains(mainRoom.key)) {
      mainRoom = null;
    }
    return RestorePlan(
      windows: targets,
      skipped: skipped,
      limited: limited,
      mainRoom: mainRoom,
    );
  }

  /// 记下的位置（[scale] 是当时那块屏幕的缩放）还能不能用：要在某块屏幕上找得到
  /// （拔了副屏就找不到）。能用时返回应放的位置（缩放改了时按逻辑大小换算，
  /// 整个放进那块屏幕的可用区域）和那块屏幕的缩放
  static (Rect, double)? savedSpot(
      Rect saved, double scale, List<ScreenArea> screens) {
    var displays = [for (var s in screens) DisplayArea(s.work, s.scale)];
    if (displays.isEmpty || !WindowGeometry.isReachable(saved, displays)) {
      return null;
    }
    var fallback = WindowGeometry.displayOf(saved, displays) ?? displays.first;
    var (rect, display) = WindowGeometry.restore(
        WindowPlacement(saved, scale), displays, fallback);
    var clamped = WindowLayout.clampInto(rect, display.work);
    return clamped == null ? null : (clamped, display.scale);
  }
}

// ---------------- 检查 ----------------

String _text(Object? value, int max) {
  if (value is! String || value.length > max) {
    throw const FormatException("text");
  }
  return value;
}

/// 平台、房间号：不能空，不能换行（要放进启动参数）
String _id(Object? value) {
  var text = _text(value, 256);
  if (text.isEmpty || text.contains("\n")) {
    throw const FormatException("id");
  }
  return text;
}

Map<String, dynamic> _geometryJson(Rect bounds, double scale) => {
      "x": bounds.left.round(),
      "y": bounds.top.round(),
      "w": bounds.width.round(),
      "h": bounds.height.round(),
      "scale": scale,
    };

/// 没有位置时为 null，有但不对时抛 [FormatException]。范围和启动参数一样
Rect? _bounds(Map json) {
  var keys = ["x", "y", "w", "h"];
  if (keys.every((k) => json[k] == null)) {
    return null;
  }
  var n = <double>[];
  for (var k in keys) {
    var v = json[k];
    if (v is! num || !v.isFinite) {
      throw const FormatException("bounds");
    }
    n.add(v.toDouble());
  }
  var (x, y, w, h) = (n[0], n[1], n[2], n[3]);
  const limit = 100000;
  if (x.abs() > limit || y.abs() > limit || w <= 0 || h <= 0) {
    throw const FormatException("bounds");
  }
  if (w > limit || h > limit) {
    throw const FormatException("bounds");
  }
  return Rect.fromLTWH(x, y, w, h);
}

double _scale(Object? value) {
  if (value is! num || !(value >= 0.5 && value <= 8)) {
    throw const FormatException("scale");
  }
  return value.toDouble();
}
