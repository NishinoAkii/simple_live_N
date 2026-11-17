import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simple_live_app/modules/live_room/live_gifts.dart';
import 'package:simple_live_app/services/obs_bridge/ass_writer.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 直播间导出时的时间轴：文件里的 0 秒对应哪个时刻
class LiveExportOrigin {
  final DateTime time;

  /// 说明，写进文件头，如“开播时间 2026-11-08 20:03:12”
  final String label;

  /// 按开播时间对齐
  final bool liveStart;

  const LiveExportOrigin(this.time, this.label, {this.liveStart = false});

  /// 有开播时间（秒级时间戳，平台给出）且不晚于第一条内容时用开播时间，
  /// 否则用第一条内容的时间
  static LiveExportOrigin choose({
    String? showTime,
    required DateTime earliest,
  }) {
    var seconds = int.tryParse(showTime ?? "");
    if (seconds != null && seconds > 0) {
      var start = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
      // 平台的开播时间偶尔比实际晚几秒，差一分钟以内也算
      if (!start.isAfter(earliest.add(const Duration(minutes: 1)))) {
        return LiveExportOrigin(
          start,
          "开播时间 {formatExportTime}".tf({"formatExportTime": formatExportTime(start)}),
          liveStart: true,
        );
      }
    }
    return LiveExportOrigin(earliest, "第一条记录 {formatExportTime}".tf({"formatExportTime": formatExportTime(earliest)}));
  }
}

/// “2026-11-08 20:03:12（UTC+8）”
String formatExportTime(DateTime time) {
  var t = time.toLocal();
  String two(int v) => v.toString().padLeft(2, "0");
  var offset = t.timeZoneOffset;
  var sign = offset.isNegative ? "-" : "+";
  var minutes = offset.inMinutes.abs();
  var zone = minutes % 60 == 0
      ? "UTC$sign${minutes ~/ 60}"
      : "UTC$sign${minutes ~/ 60}:${two(minutes % 60)}";
  return "${t.year}-${two(t.month)}-${two(t.day)} "
      "${two(t.hour)}:${two(t.minute)}:${two(t.second)}（$zone）";
}

/// 直播间导出的内容统计
class DanmakuExportCount {
  int chats = 0;
  int superChats = 0;
  int gifts = 0;
  int get total => chats + superChats + gifts;

  @override
  String toString() => [
        if (chats > 0) "弹幕 {chats} 条".tf({"chats": chats}),
        if (superChats > 0) "SC {superChats} 条".tf({"superChats": superChats}),
        if (gifts > 0) "礼物 {gifts} 条".tf({"gifts": gifts}),
      ].join("、".t);
}

/// 直播间收到的弹幕、SC、礼物换算成 ASS 的弹幕。
///
/// [chats] 是（收到的时间, 消息），系统提示（[sysUser]）和进直播间时补发的历史消息不导出；
/// SC 用平台给的开始时间；礼物用第一次收到的时间。早于 [origin] 的算 0 秒
List<AssComment> liveExportComments({
  required DateTime origin,
  Iterable<(DateTime, LiveMessage)> chats = const [],
  Iterable<LiveSuperChatMessage> superChats = const [],
  Iterable<GiftRecord> gifts = const [],
  String sysUser = "",
  DanmakuExportCount? count,
}) {
  Duration at(DateTime time) {
    var d = time.difference(origin);
    return d.isNegative ? Duration.zero : d;
  }

  var list = <AssComment>[];
  for (var (time, msg) in chats) {
    if (msg.type != LiveMessageType.chat ||
        msg.history ||
        (sysUser.isNotEmpty && msg.userName == sysUser)) {
      continue;
    }
    list.add(AssComment.chat(msg, at(time)));
    count?.chats++;
  }
  for (var sc in superChats) {
    list.add(AssComment.superChat(sc, at(sc.startTime)));
    count?.superChats++;
  }
  for (var record in gifts) {
    list.add(AssComment.gift(record.gift, at(record.time)));
    count?.gifts++;
  }
  return list;
}

/// 要导出的内容里最早的时间（规则同 [liveExportComments]），没有内容时为 null
DateTime? earliestExportTime({
  Iterable<(DateTime, LiveMessage)> chats = const [],
  Iterable<LiveSuperChatMessage> superChats = const [],
  Iterable<GiftRecord> gifts = const [],
  String sysUser = "",
}) {
  DateTime? first;
  void see(DateTime time) {
    if (first == null || time.isBefore(first!)) {
      first = time;
    }
  }

  for (var (time, msg) in chats) {
    if (msg.type == LiveMessageType.chat &&
        !msg.history &&
        (sysUser.isEmpty || msg.userName != sysUser)) {
      see(time);
    }
  }
  for (var sc in superChats) {
    see(sc.startTime);
  }
  for (var record in gifts) {
    see(record.time);
  }
  return first;
}

/// 导出用的样式：按应用的弹幕设置，全部保留（弹幕多时叠在一起，也不丢）
AssOptions exportAssOptions(Map<String, dynamic> config) =>
    AssOptions.fromConfig(config, keepAll: true);

/// 写出 ASS 文件（带 BOM，播放器按 UTF-8 读）。重名时加序号，不覆盖
Future<File> writeAssExport({
  required Directory dir,
  required String name,
  required String content,
}) async {
  await dir.create(recursive: true);
  var file = File(p.join(dir.path, name));
  for (var i = 2; await file.exists(); i++) {
    file = File(p.join(dir.path, name.replaceFirst(".ass", "_$i.ass")));
  }
  await file.writeAsBytes(utf8.encode("\uFEFF$content"), flush: true);
  return file;
}
