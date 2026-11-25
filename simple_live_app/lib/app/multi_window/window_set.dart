import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Rect, Size;

import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/multi_window/window_layout.dart';
import 'package:simple_live_app/app/multi_window/window_switcher.dart';
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

/// 一个副窗口：第几个、在看的直播间、位置和大小（物理像素，看得见的部分，见 FrameInsets）
/// 和当时屏幕的缩放、选的声音输出设备、是不是窗口全屏和置顶、宽屏时聊天栏收起没有、
/// 音量这些设置（只在本机）
class WindowEntry {
  final int slot;
  final WindowRoom room;
  final Rect? bounds;
  final double scale;
  final String? audioDevice;

  /// 直播间是窗口全屏（以前存的没有这项，当作 false）
  final bool windowFull;

  /// 窗口置顶（以前存的没有这项，当作 false）
  final bool pinned;

  /// 宽屏时右侧聊天栏收起了（以前存的没有这项，当作 false）。只在打开这一组时用
  final bool chatCollapsed;

  /// 这个窗口的音量、静音、弹幕开关、清晰度（不含声音输出设备，那个在 [audioDevice]）。
  /// 打开上次的一组时用这里记的；以前存的没有，用这个直播间记的
  final WindowSettings? settings;
  const WindowEntry({
    required this.slot,
    required this.room,
    this.bounds,
    this.scale = 1.0,
    this.audioDevice,
    this.windowFull = false,
    this.pinned = false,
    this.chatCollapsed = false,
    this.settings,
  });

  WindowEntry copyWith({
    WindowRoom? room,
    Rect? bounds,
    double? scale,
    String? audioDevice,
    bool? windowFull,
    bool? pinned,
    bool? chatCollapsed,
    WindowSettings? settings,
  }) =>
      WindowEntry(
        slot: slot,
        room: room ?? this.room,
        bounds: bounds ?? this.bounds,
        scale: scale ?? this.scale,
        audioDevice: audioDevice ?? this.audioDevice,
        windowFull: windowFull ?? this.windowFull,
        pinned: pinned ?? this.pinned,
        chatCollapsed: chatCollapsed ?? this.chatCollapsed,
        settings: settings ?? this.settings,
      );

  /// 开这个窗口的启动参数：位置、置顶在显示之前就设好，窗口全屏、收起聊天栏进直播间时设
  SecondaryLaunch toLaunch({
    required int port,
    required String token,
    required String dataDir,
    int mainPid = 0,
    Map<String, dynamic>? settings,
  }) =>
      SecondaryLaunch(
        port: port,
        token: token,
        dataDir: dataDir,
        slot: slot,
        siteId: room.siteId,
        roomId: room.roomId,
        bounds: bounds,
        scale: scale,
        mainPid: mainPid,
        pinned: pinned,
        windowFull: windowFull,
        chatCollapsed: chatCollapsed,
        settings: settings,
      );

  Map<String, dynamic> toJson() => {
        "slot": slot,
        ...room.toJson(),
        if (bounds != null) ..._geometryJson(bounds!, scale),
        if (audioDevice != null) "device": audioDevice,
        if (windowFull) "full": true,
        if (pinned) "pinned": true,
        if (chatCollapsed) "chatCollapsed": true,
        if (settings != null && !settings!.roomPart.isEmpty)
          "settings": settings!.roomPart.toJson(),
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
    var device = json["device"];
    var settings = json["settings"] == null
        ? null
        : WindowSettings.fromJson(json["settings"]).roomPart;
    return WindowEntry(
      slot: slot,
      room: WindowRoom.fromJson(json),
      bounds: bounds,
      scale: bounds == null ? 1.0 : _scale(json["scale"]),
      audioDevice: device == null ? null : _text(device, 512),
      windowFull: _flag(json["full"]) ?? false,
      pinned: _flag(json["pinned"]) ?? false,
      chatCollapsed: _flag(json["chatCollapsed"]) ?? false,
      settings: settings == null || settings.isEmpty ? null : settings,
    );
  }

  @override
  String toString() => "WindowEntry($slot, $room, $bounds, x$scale"
      "${windowFull ? ", 窗口全屏" : ""}${pinned ? ", 置顶" : ""}"
      "${chatCollapsed ? ", 收起聊天栏" : ""})";
}

/// 记下来的一组副窗口（按打开的顺序，后开的在后面），连同当时主窗口在看的直播间
/// （[mainRoom]，不在直播间时为空）、主窗口是不是窗口全屏（[mainFull]）和置顶（[mainPinned]）、
/// 聊天栏收起没有（[mainChatCollapsed]）、主窗口的位置和大小（[mainPlacement]）、
/// 主窗口直播间的音量这些设置（[mainSettings]）。
/// 主窗口的这些只在打开这一组时用，平常打开主窗口还是按它自己记的（WindowMemory 等）
class WindowSet {
  /// 存档的格式。读到别的版本（以后改了格式）时当作没有
  static const version = 1;

  final List<WindowEntry> windows;
  final WindowRoom? mainRoom;

  /// 主窗口的直播间是窗口全屏（没有 [mainRoom] 时一定是 false）
  final bool mainFull;
  final bool mainPinned;

  /// 主窗口的直播间宽屏时收起了聊天栏（没有 [mainRoom] 时一定是 false）
  final bool mainChatCollapsed;

  /// 主窗口的位置和大小，和 WindowMemory 记的一样（外框，物理像素，连同缩放、是否最大化）
  final WindowPlacement? mainPlacement;

  /// 主窗口直播间的音量、静音、弹幕开关、清晰度、声音输出设备（没有 [mainRoom] 时为空）
  final WindowSettings? mainSettings;
  final DateTime time;
  const WindowSet(
    this.windows, {
    this.mainRoom,
    this.mainFull = false,
    this.mainPinned = false,
    this.mainChatCollapsed = false,
    this.mainPlacement,
    this.mainSettings,
    required this.time,
  });

  bool get isEmpty => windows.isEmpty;

  /// 提示里列的名字
  String get labels => windows.map((e) => e.room.label).join("、");

  String encode() => jsonEncode({
        "v": version,
        "time": time.millisecondsSinceEpoch,
        if (mainRoom != null) "main": mainRoom!.toJson(),
        if (mainRoom != null && mainFull) "mainFull": true,
        if (mainPinned) "mainPinned": true,
        if (mainRoom != null && mainChatCollapsed) "mainChatCollapsed": true,
        if (mainPlacement != null)
          "mainAt": jsonDecode(mainPlacement!.encode()),
        if (mainRoom != null && mainSettings != null && !mainSettings!.isEmpty)
          "mainSettings": mainSettings!.toJson(),
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
      // 主窗口的位置、设置坏了只是不用（以前存的也没有）
      var mainAt = json["mainAt"];
      WindowSettings? mainSettings;
      if (mainRoom != null && json["mainSettings"] != null) {
        try {
          mainSettings = WindowSettings.fromJson(json["mainSettings"]);
        } on FormatException {
          mainSettings = null;
        }
      }
      var time = json["time"];
      return WindowSet(
        windows,
        mainRoom: mainRoom,
        // 以前存的没有这两项：都当作 false
        mainFull: mainRoom != null && json["mainFull"] == true,
        mainPinned: json["mainPinned"] == true,
        // 以前存的没有：当作没收起
        mainChatCollapsed:
            mainRoom != null && json["mainChatCollapsed"] == true,
        mainPlacement: mainAt is Map
            ? _placement(WindowPlacement.decode(jsonEncode(mainAt)))
            : null,
        mainSettings:
            mainSettings == null || mainSettings.isEmpty ? null : mainSettings,
        time: DateTime.fromMillisecondsSinceEpoch(time is int ? time : 0),
      );
    } catch (_) {
      return null;
    }
  }
}

/// 副窗口告诉主窗口的事：在看哪个直播间（[room]）、窗口挪到了哪里（[bounds]，物理像素，
/// 看得见的部分，连同所在屏幕的缩放）、声音和弹幕这些设置（[settings]）、
/// 进出窗口全屏（[windowFull]）、置顶变了（[pinned]）、收起或展开聊天栏（[chatCollapsed]）。
/// 至少有一项
class WindowReport {
  final WindowRoom? room;
  final Rect? bounds;
  final double scale;
  final WindowSettings? settings;
  final bool? windowFull;
  final bool? pinned;
  final bool? chatCollapsed;

  /// 和 [room] 一起报：还是原来那个直播间，只是房间号换成了平台认的（抖音的旧房间号换成 WebRid），
  /// 这里是原来的房间号。主窗口只改记着的房间号，不当作换了直播间
  final String? renamedFrom;
  const WindowReport({
    this.room,
    this.bounds,
    this.scale = 1.0,
    this.settings,
    this.windowFull,
    this.pinned,
    this.chatCollapsed,
    this.renamedFrom,
  });

  Map<String, dynamic> toJson() => {
        if (room != null) "room": room!.toJson(),
        if (room != null && renamedFrom != null) "renamedFrom": renamedFrom,
        if (bounds != null) ..._geometryJson(bounds!, scale),
        if (settings != null) "settings": settings!.toJson(),
        if (windowFull != null) "full": windowFull,
        if (pinned != null) "pinned": pinned,
        if (chatCollapsed != null) "chatCollapsed": chatCollapsed,
      };

  /// 内容不对时抛 [FormatException]（主窗口回 400）
  static WindowReport decode(Object? body) {
    if (body is! Map) {
      throw const FormatException("report");
    }
    var room = body["room"] == null ? null : WindowRoom.fromJson(body["room"]);
    var renamedFrom =
        body["renamedFrom"] == null ? null : _id(body["renamedFrom"]);
    if (renamedFrom != null && room == null) {
      throw const FormatException("renamedFrom");
    }
    var bounds = _bounds(body);
    var settings = body["settings"] == null
        ? null
        : WindowSettings.fromJson(body["settings"]);
    var windowFull = _flag(body["full"]);
    var pinned = _flag(body["pinned"]);
    var chatCollapsed = _flag(body["chatCollapsed"]);
    if (room == null &&
        bounds == null &&
        settings == null &&
        windowFull == null &&
        pinned == null &&
        chatCollapsed == null) {
      throw const FormatException("empty");
    }
    return WindowReport(
      room: room,
      bounds: bounds,
      scale: bounds == null ? 1.0 : _scale(body["scale"]),
      settings: settings,
      windowFull: windowFull,
      pinned: pinned,
      chatCollapsed: chatCollapsed,
      renamedFrom: renamedFrom,
    );
  }
}

/// 一个多开窗口里除了位置以外要记住的：音量、静音、弹幕开关、这个窗口里选的清晰度，
/// 还有声音输出设备。前四项按直播间记（“多开时对应直播间设置”，跟着 WebDAV、局域网同步），
/// 声音输出设备各台电脑不一样，只记在本机的那一组里。没有的项为 null（用默认的）
class WindowSettings {
  /// 0 到 100。静音不改它（[muted] 单独记），记的总是静音之前的音量
  final double? volume;
  final bool? muted;
  final bool? danmaku;

  /// 清晰度的名字（比如“原画”）
  final String? quality;

  /// mpv 的 audio-device 名字，auto 或 null 是默认设备
  final String? audioDevice;

  const WindowSettings({
    this.volume,
    this.muted,
    this.danmaku,
    this.quality,
    this.audioDevice,
  });

  static const empty = WindowSettings();

  bool get isEmpty =>
      volume == null &&
      muted == null &&
      danmaku == null &&
      quality == null &&
      audioDevice == null;

  /// 按直播间记、可以同步的那部分（不含声音输出设备）
  WindowSettings get roomPart => WindowSettings(
      volume: volume, muted: muted, danmaku: danmaku, quality: quality);

  /// [other] 里有的项盖掉这里的
  WindowSettings merge(WindowSettings? other) => other == null
      ? this
      : WindowSettings(
          volume: other.volume ?? volume,
          muted: other.muted ?? muted,
          danmaku: other.danmaku ?? danmaku,
          quality: other.quality ?? quality,
          audioDevice: other.audioDevice ?? audioDevice,
        );

  WindowSettings withMuted(bool? value) => WindowSettings(
      volume: volume,
      muted: value,
      danmaku: danmaku,
      quality: quality,
      audioDevice: audioDevice);

  WindowSettings withDevice(String? value) => WindowSettings(
      volume: volume,
      muted: muted,
      danmaku: danmaku,
      quality: quality,
      audioDevice: value);

  WindowSettings withQuality(String? value) => WindowSettings(
      volume: volume,
      muted: muted,
      danmaku: danmaku,
      quality: value,
      audioDevice: audioDevice);

  Map<String, dynamic> toJson() => {
        if (volume != null) "volume": volume,
        if (muted != null) "muted": muted,
        if (danmaku != null) "danmaku": danmaku,
        if (quality != null) "quality": quality,
        if (audioDevice != null) "device": audioDevice,
      };

  /// 内容不对时抛 [FormatException]
  static WindowSettings fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException("settings");
    }
    var volume = json["volume"];
    if (volume != null && (volume is! num || !(volume >= 0 && volume <= 100))) {
      throw const FormatException("volume");
    }
    bool? flag(String key) {
      var v = json[key];
      if (v != null && v is! bool) {
        throw const FormatException("bool");
      }
      return v as bool?;
    }

    var quality = json["quality"];
    var device = json["device"];
    return WindowSettings(
      volume: (volume as num?)?.toDouble(),
      muted: flag("muted"),
      danmaku: flag("danmaku"),
      quality: quality == null ? null : _text(quality, 256),
      audioDevice: device == null ? null : _text(device, 512),
    );
  }

  /// 副窗口一开始用的：照记的（[room]：打开上次的一组时是这一组里这个窗口记的，平常新开时是
  /// 这个直播间记的）。静音记过就照记的（记的优先），没记过时按“新开的多开窗口默认静音”。
  /// 主窗口不用这些
  static WindowSettings initial({
    required bool muteNew,
    WindowSettings? room,
    String? audioDevice,
  }) {
    var base = room?.roomPart ?? empty;
    return base.withMuted(room?.muted ?? muteNew).withDevice(audioDevice);
  }

  @override
  bool operator ==(Object other) =>
      other is WindowSettings &&
      other.volume == volume &&
      other.muted == muted &&
      other.danmaku == danmaku &&
      other.quality == quality &&
      other.audioDevice == audioDevice;

  @override
  int get hashCode => Object.hash(volume, muted, danmaku, quality, audioDevice);

  @override
  String toString() => "WindowSettings(${toJson()})";
}

/// 选声音输出设备：记下的还在就用它；不在了（拔了耳机、换了电脑）用默认设备，
/// [missing] 为 true（要提示一下）。没记过、记的是默认时用默认，不提示
({String device, bool missing}) pickAudioDevice(
    String? saved, List<String> available) {
  if (saved == null || saved.isEmpty || saved == "auto") {
    return (device: "auto", missing: false);
  }
  if (available.contains(saved)) {
    return (device: saved, missing: false);
  }
  return (device: "auto", missing: true);
}

/// 一个直播间在多开窗口里最近一次关掉时的样子（只在本机，不记位置）：窗口大小
/// （看得见的部分，物理像素，连同那块屏幕的缩放）、是不是窗口全屏、选的声音输出设备。
/// 之后新开这个直播间的窗口（不是打开上次的一组）时用。音量、静音这些在按直播间记的设置里
class RoomLayout {
  final Size? size;
  final double scale;
  final bool windowFull;

  /// mpv 的 audio-device 名字（“每个窗口单独选声音输出设备”开着时才记）
  final String? audioDevice;
  const RoomLayout({
    this.size,
    this.scale = 1.0,
    this.windowFull = false,
    this.audioDevice,
  });

  Map<String, dynamic> toJson() => {
        if (size != null) ...{
          "w": size!.width.round(),
          "h": size!.height.round(),
          "scale": scale,
        },
        if (windowFull) "full": true,
        if (audioDevice != null) "device": audioDevice,
      };

  /// 内容不对时抛 [FormatException]
  static RoomLayout fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException("layout");
    }
    Size? size;
    if (json["w"] != null || json["h"] != null) {
      var w = json["w"], h = json["h"];
      if (w is! num ||
          h is! num ||
          !(w > 0 && w <= 100000) ||
          !(h > 0 && h <= 100000)) {
        throw const FormatException("size");
      }
      size = Size(w.toDouble(), h.toDouble());
    }
    var device = json["device"];
    return RoomLayout(
      size: size,
      scale: size == null ? 1.0 : _scale(json["scale"]),
      windowFull: _flag(json["full"]) ?? false,
      audioDevice: device == null ? null : _text(device, 512),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RoomLayout &&
      other.size == size &&
      other.scale == scale &&
      other.windowFull == windowFull &&
      other.audioDevice == audioDevice;

  @override
  int get hashCode => Object.hash(size, scale, windowFull, audioDevice);

  @override
  String toString() => "RoomLayout(${toJson()})";
}

/// 主窗口现在的样子（记进这一组，打开这一组时恢复）
typedef MainLayout = ({
  bool windowFull,
  bool pinned,
  bool chatCollapsed,
  WindowPlacement? placement,
  WindowSettings? settings,
});

/// 记着开着的副窗口，定下“上次的一组”（历史页“打开上次的窗口”用）。
///
/// - 开窗口、副窗口挪动或改大小、换直播间时更新开着的这一组（[kOpen]，随时存，
///   主窗口崩了、直接关机时下次启动拿它当上次的一组）；
/// - 关全部多开窗口、主窗口退出时（[closingAll]），开着的这一组定下来存进 [kLast]，
///   这样关掉的窗口都还在里面；
/// - 别的窗口还开着时手动关掉一个，它从这一组里去掉；手动关掉最后一个时，
///   这一组到此为止，连同它一起定下来；
/// - 同时记下当时主窗口在看的直播间，打开时主窗口不在直播间里就在主窗口打开它；
/// - 每个窗口（连同主窗口）的位置、大小、窗口全屏、置顶、聊天栏收起没有、音量、静音、
///   弹幕开关、清晰度、声音输出设备都记在这一组里，只在打开这一组时用；
/// - 每个编号（第几个窗口）记住用户拖到的位置和大小（[kSlots]），下次开到这个编号时放回去；
/// - 副窗口里用户改了音量、静音、弹幕开关、清晰度，马上记成它的直播间的（[kRoomSettings]）；
///   副窗口关掉（不管在不在这一组里）、在里面换了直播间、关全部时，那个直播间再记下这时的设置
///   和窗口大小、窗口全屏、声音输出设备（[kRoomLayouts]，不记位置），之后新开这个直播间时用。
///   开的时候给的（打开这一组时是这一组记的）报回来不算改动，不会改掉它们。
///   静音不改音量，静音着记的就是静音之前的音量；
/// - 直播间只是换成了平台认的房间号（抖音，[WindowReport.renamedFrom]）不算换直播间：
///   只改记着的房间号，设置照旧，原来的房间号什么都不记。
///
/// 除了 [kRoomSettings] 都只存在本机（SyncCompat.localOnlySettingKeys），旧版本不认识这几项，不读也不用
class WindowSetRecorder {
  WindowSetRecorder({
    WindowRoom? Function()? mainRoom,
    MainLayout Function()? mainLayout,
    this.saveDelay = const Duration(milliseconds: 600),
    DateTime Function()? clock,
    this.onGroupClosed,
  })  : _mainRoom = mainRoom,
        _mainLayout = mainLayout,
        _clock = clock ?? DateTime.now;

  static const String kLast = "MultiWindowLastSet";
  static const String kOpen = "MultiWindowOpenSet";
  static const String kSlots = "MultiWindowSlotPlacements";

  /// 每个编号（0 是主窗口）选的声音输出设备
  static const String kSlotDevices = "MultiWindowSlotDevices";

  /// 每个主窗口直播间最近一次和它一起关的那一组
  static const String kGroups = "MultiWindowGroups";

  /// 每个直播间最近一次在多开窗口里关掉时的窗口大小、窗口全屏、声音输出设备（[RoomLayout]）
  static const String kRoomLayouts = "MultiWindowRoomLayouts";

  /// 只在本机的（位置、大小、声音输出设备）
  static const List<String> storageKeys = [
    kLast,
    kOpen,
    kSlots,
    kSlotDevices,
    kGroups,
    kRoomLayouts,
  ];

  /// 多开时各直播间的设置（音量、静音、弹幕开关、清晰度）。本版本专用，
  /// 跟着 WebDAV、局域网同步，放在扩展部分（官方版不读）
  static const String kRoomSettings = "MultiWindowRoomSettings";

  /// 最多记多少个直播间的设置（[kRoomLayouts] 也是）、多少组
  static const int maxRoomSettings = 200;
  static const int maxGroups = 50;

  /// 关全部、主窗口退出时，主窗口在一个直播间里：这一组记在这个直播间名下以后调用
  /// （把这几个直播间的观看记录时间写在一起）
  Future<void> Function(WindowSet group)? onGroupClosed;

  /// 挪窗口时连着来很多次，停下这么久以后再存
  final Duration saveDelay;
  final WindowRoom? Function()? _mainRoom;

  /// 主窗口现在的样子
  final MainLayout Function()? _mainLayout;
  final DateTime Function() _clock;

  /// 按打开的顺序（重新开到同一个编号的排到最后）
  final Map<int, WindowEntry> _entries = {};

  /// 刚开时放的位置：报上来的还是这里就不算用户挪过
  final Map<int, Rect> _launched = {};
  final Map<int, WindowPlacement> _slots = {};
  final Map<int, String> _slotDevices = {};
  final Map<String, WindowSet> _groups = {};
  final Set<int> _closing = {};
  final Map<String, RoomLayout> _roomLayouts = {};

  /// 报过清晰度的窗口（开窗口、换直播间以后重新算）：第一次报的是读到清晰度以后选的
  final Set<int> _qualitySeen = {};
  final Rx<WindowSet?> _last = Rx<WindowSet?>(null);
  bool _loaded = false;
  Timer? _saveTimer;

  /// 记下的直播间设置、大小、声音输出设备还在写（[flush] 等它们写完）
  Future<void> _roomWrites = Future.value();

  /// 马上开始写（按调用的顺序），记着什么时候写完
  void _writeInOrder(String key, String value) {
    var write = _write(key, value);
    _roomWrites = _roomWrites.then((_) => write);
  }

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

  /// 这个直播间多开时记的设置（音量、静音、弹幕、清晰度）
  WindowSettings? roomSettings(WindowRoom room) =>
      _readRoomSettings()[_roomKey(room)];

  /// 每次现读：同步（WebDAV、局域网）可能刚改过
  Map<String, WindowSettings> _readRoomSettings() {
    var result = <String, WindowSettings>{};
    try {
      var json =
          jsonDecode(_storage?.getValue<String>(kRoomSettings, "") ?? "");
      if (json is Map) {
        json.forEach((key, value) {
          try {
            var settings = WindowSettings.fromJson(value).roomPart;
            if (!settings.isEmpty) {
              result[key.toString()] = settings;
            }
          } on FormatException {
            // 坏了的这一项不要
          }
        });
      }
    } catch (_) {
      // 没存过、坏了
    }
    return result;
  }

  static String _roomKey(WindowRoom room) => "${room.siteId}_${room.roomId}";

  /// 这个直播间最近一次在多开窗口里关掉时的窗口大小、窗口全屏、声音输出设备（没关过时为 null）
  RoomLayout? roomLayout(WindowRoom room) {
    _load();
    return _roomLayouts[_roomKey(room)];
  }

  /// 第 [slot] 个窗口（0 是主窗口）选的声音输出设备
  String? slotDevice(int slot) {
    _load();
    return _slotDevices[slot];
  }

  void setSlotDevice(int slot, String? device) {
    _load();
    if (device == null || device == "auto") {
      _slotDevices.remove(slot);
    } else {
      _slotDevices[slot] = device;
    }
    _writeInOrder(kSlotDevices,
        jsonEncode({for (var e in _slotDevices.entries) "${e.key}": e.value}));
  }

  /// 这个直播间作为主窗口时，最近一次和它一起关的那一组（没有时为 null）
  WindowSet? groupFor(String siteId, String roomId) {
    _load();
    var group = _groups["$siteId|$roomId"];
    return group == null || group.isEmpty ? null : group;
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
    _qualitySeen.remove(entry.slot);
    if (entry.bounds != null) {
      _launched[entry.slot] = entry.bounds!;
    } else {
      _launched.remove(entry.slot);
    }
    _saveOpen();
  }

  /// 副窗口报告了位置、直播间、窗口全屏、置顶、聊天栏或者音量这些设置。设置记在这个窗口上
  /// （开着的这一组里），其中用户改了的几项马上记成这个直播间的（[kRoomSettings]，主窗口崩了、
  /// 直接关机也还在）；报回来的只是开的时候给的（打开这一组时是这一组记的）就不改直播间记的。
  /// 换了直播间时，原来的直播间先照关掉一样记下（[_rememberRoom]），新的直播间从头记；
  /// 只是换了房间号（[WindowReport.renamedFrom]）时只改房间号
  void reported(int slot, WindowReport report) {
    var entry = _entries[slot];
    if (entry == null) {
      return;
    }
    var room = report.room;
    if (room != null && room.key != entry.room.key && _renamed(entry, report)) {
      // 同一个直播间换成了平台认的房间号（抖音）：设置、读没读到清晰度照旧，原来的房间号不记
      Log.i("多开窗口 $slot：房间号 ${report.renamedFrom} 换成 ${room.roomId}");
    } else if (room != null && room.key != entry.room.key) {
      // 副窗口里换了直播间（关注列表里点了别的）：原来的直播间记下这时的设置、大小、窗口全屏，
      // 它的音量这些不带到新的直播间
      _load();
      _rememberRoom(entry);
      _qualitySeen.remove(slot);
      entry = WindowEntry(
        slot: slot,
        room: room,
        bounds: entry.bounds,
        scale: entry.scale,
        audioDevice: entry.audioDevice,
        windowFull: entry.windowFull,
        pinned: entry.pinned,
        chatCollapsed: entry.chatCollapsed,
      );
    }
    var known = entry.settings;
    var settings = report.settings;
    if (settings != null) {
      _saveRoomSettings(
          entry.room, _userChanges(slot, known, settings.roomPart));
      if (settings.quality != null) {
        _qualitySeen.add(slot);
      }
    }
    _entries[slot] = entry.copyWith(
      room: room,
      bounds: report.bounds,
      scale: report.bounds == null ? null : report.scale,
      windowFull: report.windowFull,
      pinned: report.pinned,
      chatCollapsed: report.chatCollapsed,
      audioDevice: settings?.audioDevice,
      settings: settings == null
          ? null
          : (known ?? WindowSettings.empty).merge(settings.roomPart).roomPart,
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

  /// [report] 报的直播间是 [entry] 原来那个，只是换了房间号
  static bool _renamed(WindowEntry entry, WindowReport report) =>
      report.renamedFrom != null &&
      report.room?.siteId == entry.room.siteId &&
      report.renamedFrom == entry.room.roomId;

  /// 报上来的设置里用户改了的几项：这个窗口已经有的（开的时候给的、之前报过的）变了才算。
  /// 第一次报上来的项（开的时候没给，比如音量用的是平常的）只是这个窗口一开始的样子；
  /// 清晰度第一次报的是读到清晰度以后选的（记的那个没有时换了别的），也不算
  WindowSettings _userChanges(
      int slot, WindowSettings? known, WindowSettings now) {
    T? changed<T>(T? before, T? after) {
      if (before == null || after == null || after == before) {
        return null;
      }
      return after;
    }

    return WindowSettings(
      volume: changed(known?.volume, now.volume),
      muted: changed(known?.muted, now.muted),
      danmaku: changed(known?.danmaku, now.danmaku),
      quality: _qualitySeen.contains(slot)
          ? changed(known?.quality, now.quality)
          : null,
    );
  }

  static bool _near(Rect a, Rect? b) =>
      b != null &&
      (a.left - b.left).abs() <= 2 &&
      (a.top - b.top).abs() <= 2 &&
      (a.width - b.width).abs() <= 2 &&
      (a.height - b.height).abs() <= 2;

  void _saveRoomSettings(WindowRoom room, WindowSettings settings) {
    if (settings.isEmpty) {
      return;
    }
    var key = _roomKey(room);
    var all = _readRoomSettings();
    var old = all[key];
    var merged = (old ?? WindowSettings.empty).merge(settings).roomPart;
    if (merged == old) {
      return;
    }
    // 最近改的排在最后，太多时丢掉最早的
    all.remove(key);
    all[key] = merged;
    while (all.length > maxRoomSettings) {
      all.remove(all.keys.first);
    }
    _writeInOrder(kRoomSettings,
        jsonEncode({for (var e in all.entries) e.key: e.value.toJson()}));
  }

  String _encodeSlots() => jsonEncode({
        for (var e in _slots.entries) "${e.key}": jsonDecode(e.value.encode()),
      });

  /// 主窗口换了直播间，或者位置、窗口全屏、置顶、音量这些变了
  void mainRoomChanged() {
    if (active.isNotEmpty) {
      _scheduleSave();
    }
  }

  /// 副窗口关掉了（或者在里面换了直播间、关全部时到最后还没退出）：它在看的直播间记下这时的
  /// 音量、静音、弹幕开关、清晰度（按直播间记的设置），窗口大小、窗口全屏和声音输出设备
  /// （[kRoomLayouts]，不记位置），这个编号记下声音输出设备
  void _rememberRoom(WindowEntry entry) {
    var settings = entry.settings?.roomPart;
    if (settings != null) {
      _saveRoomSettings(entry.room, settings);
    }
    if (entry.audioDevice != null) {
      setSlotDevice(entry.slot, entry.audioDevice);
    }
    var key = _roomKey(entry.room);
    var old = _roomLayouts[key];
    var bounds = entry.bounds;
    var layout = RoomLayout(
      size: bounds?.size ?? old?.size,
      scale: bounds != null ? entry.scale : (old?.scale ?? 1.0),
      windowFull: entry.windowFull,
      // “每个窗口单独选声音输出设备”关着时不报设备：留着以前记的
      audioDevice: entry.audioDevice ?? old?.audioDevice,
    );
    // 最近关的排在最后，太多时丢掉最早的
    _roomLayouts.remove(key);
    _roomLayouts[key] = layout;
    while (_roomLayouts.length > maxRoomSettings) {
      _roomLayouts.remove(_roomLayouts.keys.first);
    }
    _writeInOrder(
        kRoomLayouts,
        jsonEncode(
            {for (var e in _roomLayouts.entries) e.key: e.value.toJson()}));
  }

  /// 副窗口的进程退出了
  void exited(int slot) {
    var entry = _entries.remove(slot);
    _launched.remove(slot);
    _qualitySeen.remove(slot);
    if (entry == null) {
      return;
    }
    _load();
    // 不管在不在这一组里（手动先关的也算）：记成这个直播间关掉时的样子
    _rememberRoom(entry);
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
    var set = await _freeze(list);
    // 主窗口在一个直播间里：这一组记在它名下（同一个直播间只留最近的一组）。
    // 之前手动关掉的不在里面
    var main = set.mainRoom;
    if (main != null) {
      _groups.remove(main.key);
      _groups[main.key] = set;
      while (_groups.length > maxGroups) {
        _groups.remove(_groups.keys.first);
      }
      await _write(
          kGroups,
          jsonEncode({
            for (var e in _groups.entries) e.key: jsonDecode(e.value.encode())
          }));
      try {
        await onGroupClosed?.call(set);
      } catch (e) {
        Log.logPrint(e);
      }
    }
    return true;
  }

  /// 关全部、主窗口退出时，等完以后还没退出的（强制结束的、还在退的）：照最后报上来的样子
  /// 记下各自的直播间（[_rememberRoom]）。主窗口退出之前就写好，等它们的进程退出可能来不及；
  /// 之后它们退出时照常再记一次
  void rememberClosing() {
    _load();
    for (var e in entries) {
      if (_closing.contains(e.slot)) {
        _rememberRoom(e);
      }
    }
  }

  /// 马上存（不等 [saveDelay]）
  Future<void> flush() async {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      await _saveOpen();
    }
    // 记下的直播间设置、大小也等写完（主窗口退出前）
    await _roomWrites;
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
    Map? readMap(String key) {
      try {
        var json = jsonDecode(storage.getValue<String>(key, ""));
        return json is Map ? json : null;
      } catch (_) {
        return null;
      }
    }

    readMap(kSlotDevices)?.forEach((key, value) {
      var slot = int.tryParse(key.toString());
      if (slot != null &&
          slot >= 0 &&
          slot <= SecondaryLaunch.maxWindows &&
          value is String &&
          value.isNotEmpty &&
          value.length <= 512) {
        _slotDevices[slot] = value;
      }
    });
    readMap(kGroups)?.forEach((key, value) {
      var set = WindowSet.decode(jsonEncode(value));
      if (set != null && !set.isEmpty && set.mainRoom?.key == "$key") {
        _groups[key.toString()] = set;
      }
    });
    readMap(kRoomLayouts)?.forEach((key, value) {
      try {
        _roomLayouts[key.toString()] = RoomLayout.fromJson(value);
      } on FormatException {
        // 坏了的这一项不要
      }
    });
  }

  WindowSet _snapshot(List<WindowEntry> list) {
    var mainRoom = _mainRoom?.call();
    var layout = _mainLayout?.call();
    return WindowSet(
      list,
      mainRoom: mainRoom,
      mainFull: mainRoom != null && (layout?.windowFull ?? false),
      mainPinned: layout?.pinned ?? false,
      mainChatCollapsed: mainRoom != null && (layout?.chatCollapsed ?? false),
      mainPlacement: layout?.placement,
      mainSettings: mainRoom == null ? null : layout?.settings,
      time: _clock(),
    );
  }

  Future<WindowSet> _freeze(List<WindowEntry> list) async {
    _load();
    _saveTimer?.cancel();
    var set = _snapshot(list);
    _last.value = set;
    Log.i("多开：记下这一组 ${list.length} 个窗口");
    await Future.wait([_write(kLast, set.encode()), _write(kOpen, null)]);
    return set;
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

/// 电脑端设置 → 多开窗口里的开关，只在本机
class MultiWindowPrefs {
  MultiWindowPrefs._();

  /// 新开的多开窗口默认静音（默认开；主窗口不受影响）
  static const String kMuteNew = "MultiWindowMuteNew";

  /// 每个窗口单独选声音输出设备（默认关）
  static const String kDevicePerWindow = "MultiWindowDevicePerWindow";

  /// 主窗口最小化时多开窗口一起最小化（默认开）
  static const String kMinimizeTogether = "MultiWindowMinimizeTogether";

  /// 组成贴靠分组时 Alt+Tab 里留下哪些（默认和系统一样）
  static const String kSwitcher = "MultiWindowSwitcher";

  static const List<String> storageKeys = [
    kMuteNew,
    kDevicePerWindow,
    kMinimizeTogether,
    kSwitcher,
    StartupRestoreSetting.kKey,
  ];

  static final Rx<bool> _muteNew = true.obs;
  static final Rx<bool> _devicePerWindow = false.obs;
  static final Rx<bool> _minimizeTogether = true.obs;
  static final Rx<SwitcherMode> _switcher = SwitcherMode.all.obs;
  static bool _loaded = false;

  static void _load() {
    if (_loaded) {
      return;
    }
    _loaded = true;
    var storage = WindowSetRecorder._storage;
    _muteNew.value = storage?.getValue<bool>(kMuteNew, true) ?? true;
    _devicePerWindow.value =
        storage?.getValue<bool>(kDevicePerWindow, false) ?? false;
    _minimizeTogether.value =
        storage?.getValue<bool>(kMinimizeTogether, true) ?? true;
    _switcher.value =
        SwitcherMode.parse(storage?.getValue<String>(kSwitcher, ""));
  }

  static Rx<bool> get muteNew {
    _load();
    return _muteNew;
  }

  static Rx<bool> get devicePerWindow {
    _load();
    return _devicePerWindow;
  }

  static Rx<bool> get minimizeTogether {
    _load();
    return _minimizeTogether;
  }

  static Future<void> setMinimizeTogether(bool value) async {
    _load();
    _minimizeTogether.value = value;
    await WindowSetRecorder._storage?.setValue<bool>(kMinimizeTogether, value);
  }

  static Rx<SwitcherMode> get switcher {
    _load();
    return _switcher;
  }

  static Future<void> setSwitcher(SwitcherMode value) async {
    _load();
    _switcher.value = value;
    await WindowSetRecorder._storage?.setValue<String>(kSwitcher, value.name);
  }

  static Future<void> setMuteNew(bool value) async {
    _load();
    _muteNew.value = value;
    await WindowSetRecorder._storage?.setValue<bool>(kMuteNew, value);
  }

  static Future<void> setDevicePerWindow(bool value) async {
    _load();
    _devicePerWindow.value = value;
    await WindowSetRecorder._storage?.setValue<bool>(kDevicePerWindow, value);
  }

  /// 测试用：下次重新从存档读
  static void reset() {
    _loaded = false;
    _muteNew.value = true;
    _devicePerWindow.value = false;
    _minimizeTogether.value = true;
    _switcher.value = SwitcherMode.all;
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

  /// 开这个窗口用的：放在 [bounds]，窗口全屏、置顶、聊天栏收起照上次的。[followPin]：主窗口
  /// 没有按这一组恢复、现在置顶着，这个窗口也一出来就置顶（后开的在上面）
  WindowEntry reopen({bool followPin = false}) => WindowEntry(
        slot: slot,
        room: saved.room,
        bounds: bounds,
        scale: scale,
        windowFull: saved.windowFull,
        pinned: saved.pinned || followPin,
        chatCollapsed: saved.chatCollapsed,
      );

  /// 这个窗口一开始的音量、静音、弹幕开关、清晰度：这一组里记的优先，这一组没记的项
  /// （以前存的没有）用这个直播间记的（[room]），都没记过静音时按“默认静音”
  WindowSettings launchSettings({
    required bool muteNew,
    WindowSettings? room,
    String? audioDevice,
  }) =>
      WindowSettings.initial(
        muteNew: muteNew,
        room: (room ?? WindowSettings.empty).merge(saved.settings),
        audioDevice: audioDevice,
      );
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

/// 打开上次的一组时主窗口要回到的样子：位置和大小、置顶，主窗口在（或要打开）这一组的
/// 直播间时还有它的窗口全屏、聊天栏收起没有、音量、静音、弹幕开关、清晰度、声音输出设备
class MainRestore {
  /// 用 [windowFull]、[chatCollapsed]、[settings] 的直播间；为空时只放回位置、置顶
  final WindowRoom? room;
  final bool windowFull;
  final bool pinned;
  final bool chatCollapsed;
  final WindowPlacement? placement;
  final WindowSettings? settings;
  const MainRestore({
    this.room,
    this.windowFull = false,
    this.pinned = false,
    this.chatCollapsed = false,
    this.placement,
    this.settings,
  });
}

/// 多开窗口放哪里、“打开上次的窗口”怎么开，都是纯计算
class WindowRestore {
  WindowRestore._();

  /// 新开一个窗口（不是打开上次的一组）：位置照 [where]（这个编号记的，没记过时错开放）；
  /// 这个直播间在多开窗口里关过（[memory]）时用那时的大小（按逻辑大小换算到这块屏幕，
  /// 整个放进屏幕里）和窗口全屏。[pinned]：主窗口现在置顶着。聊天栏不收起（只有打开这一组时照记的）
  static WindowEntry opening(
    int slot,
    WindowRoom room,
    (Rect, double)? where, {
    RoomLayout? memory,
    List<ScreenArea> screens = const [],
    double fallbackScale = 1.0,
    bool pinned = false,
  }) {
    var bounds = where?.$1;
    var scale = where?.$2 ?? fallbackScale;
    var size = memory?.size;
    var screen = bounds == null ? null : WindowLayout.screenOf(screens, bounds);
    if (bounds != null && size != null && screen != null) {
      var rect = WindowLayout.clampInto(
          bounds.topLeft &
              WindowGeometry.convertSize(size, memory!.scale, screen.scale),
          screen.work);
      if (rect != null) {
        bounds = rect;
        scale = screen.scale;
      }
    }
    return WindowEntry(
      slot: slot,
      room: room,
      bounds: bounds,
      scale: scale,
      pinned: pinned,
      windowFull: memory?.windowFull ?? false,
    );
  }

  /// 新开的窗口一开始的音量、静音、弹幕开关、清晰度：照这个直播间记的（[room]）。
  /// 静音记过就照记的（关的时候静音就静音，不静音就不静音），没记过时“默认静音”开着就先静音
  static WindowSettings openingSettings({
    required bool muteNew,
    WindowSettings? room,
    String? audioDevice,
  }) =>
      WindowSettings.initial(
        muteNew: muteNew,
        room: room,
        audioDevice: audioDevice,
      );

  /// 打开上次的一组时主窗口怎么办：主窗口在看别的直播间、这次什么都没打开时不动（null）。
  /// 不然位置、大小和置顶照这一组记的；主窗口在（或要打开，[RestorePlan.mainRoom]）
  /// 这一组的直播间时，那个直播间的窗口全屏、聊天栏、声音、弹幕、清晰度也照记的
  static MainRestore? mainFor(
    WindowSet saved,
    RestorePlan plan, {
    WindowRoom? mainRoomNow,
  }) {
    if (plan.windows.isEmpty && plan.mainRoom == null) {
      return null;
    }
    if (mainRoomNow != null && mainRoomNow.key != saved.mainRoom?.key) {
      return null;
    }
    var room = mainRoomNow ?? plan.mainRoom;
    return MainRestore(
      room: room,
      windowFull: room != null && saved.mainFull,
      pinned: saved.mainPinned,
      chatCollapsed: room != null && saved.mainChatCollapsed,
      placement: saved.mainPlacement,
      settings: room == null ? null : saved.mainSettings,
    );
  }

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

  /// 记下的位置（看得见的部分，[scale] 是当时那块屏幕的缩放）还能不能用：
  /// 要在某块屏幕上找得到（拔了副屏就找不到）。能用时返回应放的位置和那块屏幕的缩放：
  /// 缩放没变时原样放回（贴靠在边上、角上的还贴着），变了时按逻辑大小换算；
  /// 超出可用区域的整个挪进来（按看得见的部分算，换算差一两个像素的不动）
  static (Rect, double)? savedSpot(
      Rect saved, double scale, List<ScreenArea> screens) {
    var displays = [for (var s in screens) DisplayArea(s.work, s.scale)];
    if (displays.isEmpty || !WindowGeometry.isReachable(saved, displays)) {
      return null;
    }
    var display = WindowGeometry.displayOf(saved, displays) ?? displays.first;
    var rect = (display.scale - scale).abs() < 0.01
        ? saved
        : saved.topLeft &
            WindowGeometry.fit(
                WindowGeometry.convertSize(saved.size, scale, display.scale),
                display);
    var clamped =
        WindowLayout.clampInto(rect, display.work, slack: 2 * display.scale);
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

/// 开关项：没有时为 null，不是 true、false 时抛 [FormatException]
bool? _flag(Object? value) {
  if (value != null && value is! bool) {
    throw const FormatException("flag");
  }
  return value as bool?;
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

/// 主窗口记的位置：范围和启动参数一样，不对时不用
WindowPlacement? _placement(WindowPlacement? value) {
  if (value == null) {
    return null;
  }
  var r = value.rect;
  const limit = 100000;
  if (r.left.abs() > limit ||
      r.top.abs() > limit ||
      r.width > limit ||
      r.height > limit ||
      !(value.scale >= 0.5 && value.scale <= 8)) {
    return null;
  }
  return value;
}

double _scale(Object? value) {
  if (value is! num || !(value >= 0.5 && value <= 8)) {
    throw const FormatException("scale");
  }
  return value.toDouble();
}
