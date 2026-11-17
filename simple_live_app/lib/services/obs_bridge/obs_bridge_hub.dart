import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:simple_live_app/services/obs_bridge/ass_writer.dart';
import 'package:simple_live_app/services/obs_bridge/obs_events.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 推给网页和 ASS 流的一个事件
class ObsHubEvent {
  /// chat / superchat / online / room / clear
  final String type;

  /// 事件 JSON（见 [ObsEvents]）
  final Map<String, dynamic> json;

  /// 时间（Unix 毫秒）
  final int time;

  /// chat、superchat 对应的弹幕（ASS 流用）
  final AssComment? comment;

  /// room 事件：新的直播间（关闭时为 null）
  final ObsRoomInfo? room;

  /// room 事件：换了直播间（不只是标题、开播状态变了）
  final bool roomChanged;

  ObsHubEvent({
    required this.type,
    required this.json,
    required this.time,
    this.comment,
    this.room,
    this.roomChanged = false,
  });

  /// 编码一次，发给所有 WebSocket
  late final String encoded = jsonEncode(json);
}

/// 一条记录（导出 ASS 用）
class ObsHistoryEntry {
  /// 时间（Unix 毫秒）
  final int time;

  /// 时间为 0 的弹幕或备注，导出时换成相对时间
  final AssComment comment;
  const ObsHistoryEntry(this.time, this.comment);
}

/// 录屏接口的数据：当前直播间、最近的消息（给轮询的客户端）、
/// 本次开启接口以来的弹幕记录（导出 ASS），以及推给网页的事件流。
/// 只在接口开着时存在，关掉接口时丢弃
class ObsBridgeHub {
  ObsBridgeHub({
    this.bufferSize = 300,
    this.historyLimit = 50000,
    this.superChatLimit = 50,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 最近消息的条数（/api/messages）
  final int bufferSize;

  /// 弹幕记录的条数上限（/api/ass）
  final int historyLimit;

  /// 保留的醒目留言条数
  final int superChatLimit;

  final int Function() _clock;

  /// 这次启动的标识：客户端据此发现接口重启过（消息 id 会从头开始）
  final String instance = List.generate(
    8,
    (_) => Random().nextInt(36).toRadixString(36),
  ).join();

  final _events = StreamController<ObsHubEvent>.broadcast();
  Stream<ObsHubEvent> get events => _events.stream;

  int _lastId = 0;
  int get lastId => _lastId;

  ObsRoomInfo? _room;
  ObsRoomInfo? get room => _room;

  final ListQueue<Map<String, dynamic>> _recent = ListQueue();
  final ListQueue<ObsHistoryEntry> _history = ListQueue();
  final List<Map<String, dynamic>> _superChats = [];
  final Set<String> _superChatKeys = {};

  int now() => _clock();

  void _emit(ObsHubEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  void _record(int time, AssComment comment) {
    _history.addLast(ObsHistoryEntry(time, comment));
    while (_history.length > historyLimit) {
      _history.removeFirst();
    }
  }

  /// 设置当前直播间。换了直播间（或关闭）时先发 clear，清掉最近消息和醒目留言，
  /// 并在弹幕记录里加一行备注；同一个直播间只是信息变了时只发 room
  void setRoom(ObsRoomInfo? room) {
    var time = now();
    var changed = room?.key != _room?.key;
    if (!changed && room != null && _room != null) {
      var same = jsonEncode(room.toJson()) == jsonEncode(_room!.toJson());
      if (same) {
        return;
      }
    }
    if (!changed && room == null) {
      return;
    }
    _room = room;
    if (changed) {
      _recent.clear();
      _superChats.clear();
      _superChatKeys.clear();
      _emit(ObsHubEvent(
        type: "clear",
        json: ObsEvents.clear(time: time),
        time: time,
      ));
      _record(
        time,
        AssComment.note(
          Duration.zero,
          room == null ? "直播间已关闭".t : "直播间：{label}".tf({"label": room.label}),
        ),
      );
    }
    _emit(ObsHubEvent(
      type: "room",
      json: ObsEvents.room(room, time: time),
      time: time,
      room: room,
      roomChanged: changed,
    ));
  }

  /// 一条聊天消息（已经过关键词屏蔽）。没有直播间时忽略
  void addChat(LiveMessage msg) {
    var room = _room;
    if (room == null) {
      return;
    }
    var time = now();
    var json = ObsEvents.chat(
      msg,
      id: ++_lastId,
      time: time,
      site: room.site,
      roomId: room.roomId,
    );
    _recent.addLast(json);
    while (_recent.length > bufferSize) {
      _recent.removeFirst();
    }
    var comment = AssComment.chat(msg);
    _record(time, comment);
    _emit(ObsHubEvent(type: "chat", json: json, time: time, comment: comment));
  }

  /// 醒目留言。[live] 为 false 表示进直播间时读到的历史 SC：
  /// 照常推给网页，但不写进弹幕记录（时间不对）
  void addSuperChat(LiveSuperChatMessage sc, {bool live = true}) {
    var room = _room;
    if (room == null) {
      return;
    }
    // 刷新直播间时会重新读到同一批 SC
    var key = sc.id ??
        "${sc.userName}|${sc.startTime.millisecondsSinceEpoch}|${sc.message}";
    if (!_superChatKeys.add(key)) {
      return;
    }
    var time = now();
    var json = ObsEvents.superChat(
      sc,
      id: ++_lastId,
      time: time,
      site: room.site,
      roomId: room.roomId,
    );
    _recent.addLast(json);
    while (_recent.length > bufferSize) {
      _recent.removeFirst();
    }
    _superChats.add(json);
    if (_superChats.length > superChatLimit) {
      _superChats.removeRange(0, _superChats.length - superChatLimit);
    }
    AssComment? comment;
    if (live) {
      comment = AssComment.superChat(sc);
      _record(time, comment);
    }
    _emit(ObsHubEvent(
      type: "superchat",
      json: json,
      time: time,
      comment: comment,
    ));
  }

  /// 人气 / 在线人数
  void setOnline(int online) {
    var room = _room;
    if (room == null || room.online == online) {
      return;
    }
    _room = room.copyWith(online: online);
    var time = now();
    _emit(ObsHubEvent(
      type: "online",
      json: ObsEvents.online(
        online,
        time: time,
        site: room.site,
        roomId: room.roomId,
      ),
      time: time,
    ));
  }

  /// id 大于 [since] 的最近消息；[since] 比最新的 id 还大（接口重启过）时返回全部
  List<Map<String, dynamic>> messagesSince(int since) {
    if (since > _lastId) {
      since = 0;
    }
    return _recent.where((e) => (e["id"] as int) > since).toList();
  }

  /// 最近 [count] 条聊天消息（按时间先后）
  List<Map<String, dynamic>> recentChats(int count) {
    if (count <= 0) {
      return const [];
    }
    var chats = _recent.where((e) => e["type"] == "chat").toList();
    return chats.length <= count ? chats : chats.sublist(chats.length - count);
  }

  /// 还在显示的醒目留言
  List<Map<String, dynamic>> activeSuperChats() {
    var time = now();
    return _superChats.where((e) => (e["end"] as int) > time).toList();
  }

  /// 最早一条记录的时间
  int? get historyStart => _history.isEmpty ? null : _history.first.time;

  /// 弹幕记录条数
  int get historyLength => _history.length;

  /// [from]~[to]（含）之间的记录
  List<ObsHistoryEntry> history({int? from, int? to}) => _history
      .where((e) =>
          (from == null || e.time >= from) && (to == null || e.time <= to))
      .toList();

  Future<void> close() => _events.close();
}
