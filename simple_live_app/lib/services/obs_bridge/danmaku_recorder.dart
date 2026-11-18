import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simple_live_app/services/obs_bridge/ass_writer.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 直播间的“记录弹幕（ASS）”：开始时写文件头，之后每条弹幕一行，
/// 时间从开始记录算起。每秒写一次文件，不需要录屏接口开着
class DanmakuAssRecorder {
  DanmakuAssRecorder._(
    this.file,
    this._file,
    this._writer,
    this.startedAt,
    this._roomKey,
  ) {
    _flushTimer = Timer.periodic(const Duration(seconds: 1), (_) => _flush());
  }

  /// 保存的文件
  final File file;
  final RandomAccessFile _file;
  final AssDanmakuWriter _writer;

  /// 开始记录的时间
  final DateTime startedAt;

  String? _roomKey;
  final StringBuffer _pending = StringBuffer();
  Timer? _flushTimer;
  bool _stopped = false;

  /// 写入的弹幕条数
  int get count => _writer.written;

  /// 没有空行丢掉的条数
  int get dropped => _writer.dropped;

  Duration get elapsed => DateTime.now().difference(startedAt);

  /// 在 [dir] 里新建文件开始记录。[roomKey]、[roomLabel] 为当前直播间，写一行备注。
  /// 给了 [file] 时就写到它（录屏时和视频同名的弹幕文件）
  static Future<DanmakuAssRecorder> start({
    required Directory dir,
    required AssOptions options,
    String? site,
    String? roomId,
    String? roomKey,
    String? roomLabel,
    DateTime? now,
    File? file,
  }) async {
    var time = now ?? DateTime.now();
    await dir.create(recursive: true);
    File target;
    if (file != null) {
      target = file;
    } else {
      var name = assFileName(site: site, roomId: roomId, time: time);
      var candidate = File(p.join(dir.path, name));
      // 同一秒再次开始时加序号，不覆盖
      for (var i = 2; await candidate.exists(); i++) {
        candidate =
            File(p.join(dir.path, name.replaceFirst(".ass", "_$i.ass")));
      }
      target = candidate;
    }
    var handle = await target.open(mode: FileMode.write);
    var writer = AssDanmakuWriter(options);
    var title = roomLabel == null || roomLabel.isEmpty
        ? "SimpleLive 弹幕".t
        : "SimpleLive 弹幕 - {roomLabel}".tf({"roomLabel": roomLabel});
    var recorder = DanmakuAssRecorder._(target, handle, writer, time, roomKey);
    recorder._pending.write("\uFEFF${writer.header(title: title)}");
    if (roomLabel != null && roomLabel.isNotEmpty) {
      recorder._writeLine(
          writer.line(AssComment.note(Duration.zero, "直播间：{roomLabel}".tf({"roomLabel": roomLabel}))));
    }
    recorder._flush();
    return recorder;
  }

  Duration _now() => DateTime.now().difference(startedAt);

  void _writeLine(String? line) {
    if (line == null || _stopped) {
      return;
    }
    _pending.write(line);
    _pending.write("\n");
  }

  /// 一条聊天消息（已经过关键词屏蔽）
  void addChat(LiveMessage msg, {Duration? at}) {
    _writeLine(_writer.line(AssComment.chat(msg, at ?? _now())));
  }

  /// 收到的醒目留言（[AssOptions.superChats] 关闭时不写）
  void addSuperChats(Iterable<LiveSuperChatMessage> list, {Duration? at}) {
    for (var sc in list) {
      _writeLine(_writer.line(AssComment.superChat(sc, at ?? _now())));
    }
  }

  /// 直播间变了（[key] 与上次不同）时写一行备注
  void noteRoom(String key, String label, {Duration? at}) {
    if (key == _roomKey) {
      return;
    }
    _roomKey = key;
    _writeLine(_writer.line(AssComment.note(at ?? _now(), "直播间：{label}".tf({"label": label}))));
  }

  void _flush() {
    if (_pending.isEmpty) {
      return;
    }
    var text = _pending.toString();
    _pending.clear();
    try {
      _file.writeStringSync(text);
    } catch (_) {}
  }

  /// 停止记录，写完并关闭文件
  Future<File> stop() async {
    if (_stopped) {
      return file;
    }
    _flushTimer?.cancel();
    _flush();
    _stopped = true;
    try {
      await _file.close();
    } catch (_) {}
    return file;
  }

  /// 在系统的文件管理器里显示 [file]
  static Future<void> reveal(File file) async {
    try {
      if (Platform.isWindows) {
        await Process.run("explorer.exe", ["/select,", file.path]);
      } else if (Platform.isMacOS) {
        await Process.run("open", ["-R", file.path]);
      } else if (Platform.isLinux) {
        await Process.run("xdg-open", [file.parent.path]);
      }
    } catch (_) {}
  }
}
