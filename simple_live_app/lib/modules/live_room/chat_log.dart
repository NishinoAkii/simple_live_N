import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 收到的一条聊天消息及接收时间
class LiveChatRecord {
  final DateTime time;
  final LiveMessage message;
  LiveChatRecord(this.time, this.message);
}

/// 直播间收到的聊天消息（包括系统提示），切换直播间时清空。
///
/// 按 [chunkSize] 条一块追加：最近的 [hotChunks] 块留在内存里，
/// 更早的块编码后交给 [ChatChunkStore] 保存（默认是临时文件），
/// 翻看或搜索到时再读回来，最近读过的 [cachedChunks] 块缓存在内存里。
/// 这样内存占用不会随观看时间一直增长。
///
/// [maxCount] 为 0 时一条都不删；否则超出时整块丢掉最早的，并调用 [onTrimmed]。
class ChatLog {
  ChatLog({
    ChatChunkStore? store,
    this.chunkSize = 512,
    this.hotChunks = 8,
    this.cachedChunks = 4,
    this.maxCount = 0,
    this.onTrimmed,
  }) : _store = store ?? MemoryChunkStore();

  final int chunkSize;
  final int hotChunks;
  final int cachedChunks;
  final ChatChunkStore _store;

  /// 最多保留的条数，0 为不限。超出时整块丢掉最早的，所以实际最多再多出不到一块
  int maxCount;

  /// 丢掉最早的条目后调用，参数为丢掉的条数；显示列表据此平移，正在看的内容不跳
  void Function(int dropped)? onTrimmed;

  final List<_Chunk> _sealed = [];
  List<LiveChatRecord> _tail = [];
  final _cache = <int, List<LiveChatRecord>>{};

  /// 清空时加一，进行中的搜索据此放弃
  int _generation = 0;

  /// 一共丢掉了多少块，进行中的搜索据此换算位置
  int _droppedChunks = 0;

  /// 下一块要转存的位置（之前的块都已交给 [_store]）
  int _spilled = 0;

  int get length => _sealed.length * chunkSize + _tail.length;
  bool get isEmpty => length == 0;

  void add(LiveChatRecord record) {
    _tail.add(record);
    if (_tail.length >= chunkSize) {
      _sealed.add(_Chunk(_tail));
      _tail = [];
      _spillOld();
      _trim();
    }
  }

  LiveChatRecord operator [](int index) {
    RangeError.checkValidIndex(index, this, "index", length);
    var c = index ~/ chunkSize;
    if (c == _sealed.length) {
      return _tail[index - c * chunkSize];
    }
    return _items(c, cache: true)[index - c * chunkSize];
  }

  /// 找出符合条件的记录（按时间顺序）。
  ///
  /// 分批进行，中间让出主线程，不会卡住界面；进行中又收到的消息也会包含在内，
  /// 进行中被丢掉的块跳过。清空或 [cancelled] 返回 true 时放弃，返回 null。
  Future<List<LiveChatRecord>?> where(
    bool Function(LiveChatRecord item) test, {
    bool Function()? cancelled,
  }) async {
    var generation = _generation;
    var base = _droppedChunks;
    var out = <LiveChatRecord>[];
    var watch = Stopwatch()..start();
    for (var c = 0;; c++) {
      if (watch.elapsedMilliseconds >= 8) {
        await Future<void>.delayed(Duration.zero);
        if (generation != _generation || (cancelled?.call() ?? false)) {
          return null;
        }
        watch.reset();
      }
      var i = c - (_droppedChunks - base);
      if (i >= _sealed.length) {
        break;
      }
      if (i >= 0) {
        out.addAll(_items(i, cache: false).where(test));
      }
    }
    out.addAll(_tail.where(test));
    return out;
  }

  void clear() {
    _generation++;
    _sealed.clear();
    _tail = [];
    _cache.clear();
    _spilled = 0;
    _droppedChunks = 0;
    _store.clear();
  }

  void dispose() {
    clear();
    _store.dispose();
  }

  /// 超出 [maxCount] 时整块丢掉最早的
  void _trim() {
    if (maxCount <= 0) {
      return;
    }
    var chunks = 0;
    while (_sealed.isNotEmpty && length - chunkSize >= maxCount) {
      var chunk = _sealed.removeAt(0);
      var handle = chunk.handle;
      if (handle != null) {
        _store.remove(handle);
      }
      if (_spilled > 0) {
        _spilled--;
      }
      chunks++;
    }
    if (chunks == 0) {
      return;
    }
    _droppedChunks += chunks;
    // 缓存按块的位置存的，跟着前移（保持原来的先后，最近用过的在后面）
    var shifted = <int, List<LiveChatRecord>>{};
    _cache.forEach((c, items) {
      if (c - chunks >= 0) {
        shifted[c - chunks] = items;
      }
    });
    _cache
      ..clear()
      ..addAll(shifted);
    onTrimmed?.call(chunks * chunkSize);
  }

  List<LiveChatRecord> _items(int c, {required bool cache}) {
    var chunk = _sealed[c];
    var items = chunk.items ?? _cache.remove(c);
    if (items == null) {
      try {
        items = _decode(_store.read(chunk.handle!));
      } catch (e) {
        // 临时文件被删了等情况：显示占位，不让列表报错
        Log.logPrint("读取聊天记录失败：$e");
        var placeholder = LiveChatRecord(
          DateTime.fromMillisecondsSinceEpoch(0),
          LiveMessage(
            type: LiveMessageType.chat,
            userName: "LiveSysMessage",
            message: "（这段聊天记录读取失败）".t,
            color: LiveMessageColor.white,
          ),
        );
        items = List.filled(chunkSize, placeholder);
      }
      if (!cache) {
        return items;
      }
    }
    if (chunk.items == null) {
      // 重新放到最后，表示最近用过
      _cache[c] = items;
      while (_cache.length > cachedChunks) {
        _cache.remove(_cache.keys.first);
      }
    }
    return items;
  }

  void _spillOld() {
    while (_spilled < _sealed.length - hotChunks) {
      var chunk = _sealed[_spilled];
      var handle = _store.write(_encode(chunk.items!));
      if (handle == null) {
        // 暂时存不了（比如临时目录还没准备好），下次封存新块时再试
        return;
      }
      chunk.handle = handle;
      chunk.items = null;
      _spilled++;
    }
  }

  /// 每条存成 [时间毫秒, 用户名, 内容, RGB, 头像, 身份, 表情, 大表情, 名字颜色, 用户 ID]，
  /// 后面没有内容的项省掉（大多数消息只有前 4 项，不多占空间）。
  /// 用户 ID 也存下来，“只看这个人”翻得到存进临时文件的他改名前的消息
  static Uint8List _encode(List<LiveChatRecord> items) {
    var rows = [for (var e in items) _encodeRow(e)];
    return utf8.encode(jsonEncode(rows));
  }

  static List<Object?> _encodeRow(LiveChatRecord e) {
    var m = e.message;
    var row = <Object?>[
      e.time.millisecondsSinceEpoch,
      m.userName,
      m.message,
      (m.color.r << 16) | (m.color.g << 8) | m.color.b,
      (m.face?.isNotEmpty ?? false) ? m.face : null,
      (m.badges?.isNotEmpty ?? false)
          ? [for (var b in m.badges!) b.toJson()]
          : null,
      (m.emotes?.isNotEmpty ?? false)
          ? [for (var emote in m.emotes!) emote.toJson()]
          : null,
      m.sticker?.toJson(),
      m.nameColor == null
          ? null
          : (m.nameColor!.r << 16) | (m.nameColor!.g << 8) | m.nameColor!.b,
      m.userId,
    ];
    while (row.length > 4 && row.last == null) {
      row.removeLast();
    }
    return row;
  }

  static List<LiveChatRecord> _decode(Uint8List bytes) {
    var rows = jsonDecode(utf8.decode(bytes)) as List;
    return [for (var row in rows.cast<List>()) _decodeRow(row)];
  }

  static LiveChatRecord _decodeRow(List row) {
    dynamic at(int i) => row.length > i ? row[i] : null;
    var rgb = row[3] as int;
    var badges = at(5) is List
        ? [
            for (var b in at(5) as List)
              if (LiveBadge.fromJson(b) case var badge?) badge,
          ]
        : null;
    var emotes = at(6) is List
        ? [
            for (var e in at(6) as List)
              if (_emoteFromJson(e) case var emote?) emote,
          ]
        : null;
    return LiveChatRecord(
      DateTime.fromMillisecondsSinceEpoch(row[0] as int),
      LiveMessage(
        type: LiveMessageType.chat,
        userName: row[1] as String,
        message: row[2] as String,
        color: LiveMessageColor(rgb >> 16 & 0xff, rgb >> 8 & 0xff, rgb & 0xff),
        face: at(4) as String?,
        badges: (badges?.isEmpty ?? true) ? null : badges,
        emotes: (emotes?.isEmpty ?? true) ? null : emotes,
        sticker: _emoteFromJson(at(7)),
        nameColor: at(8) is int
            ? LiveMessageColor(
                (at(8) as int) >> 16 & 0xff,
                (at(8) as int) >> 8 & 0xff,
                (at(8) as int) & 0xff,
              )
            : null,
        userId: at(9)?.toString(),
      ),
    );
  }

  static LiveEmote? _emoteFromJson(dynamic json) {
    if (json is! Map || json["text"] == null || json["url"] == null) {
      return null;
    }
    int size(dynamic v) => v is num ? v.toInt() : 0;
    return LiveEmote(
      text: json["text"].toString(),
      url: json["url"].toString(),
      staticUrl: json["staticUrl"]?.toString(),
      width: size(json["width"]),
      height: size(json["height"]),
      spaced: json["spaced"] == true,
      cacheKey: json["cacheKey"]?.toString(),
    );
  }
}

class _Chunk {
  _Chunk(this.items);

  /// 留在内存里时的内容，转存后为 null
  List<LiveChatRecord>? items;

  /// 转存后由 [ChatChunkStore.write] 返回，用来读回
  Object? handle;
}

/// 存放封存的聊天块。换成数据库等别的存法时实现这个接口即可。
abstract class ChatChunkStore {
  /// 保存一块，返回读回时用的句柄；暂时存不了时返回 null
  Object? write(Uint8List bytes);

  Uint8List read(Object handle);

  /// 这一块不再需要（超出保留条数被丢掉了），可以释放
  void remove(Object handle);

  /// 丢弃已保存的全部块（切换直播间）
  void clear();

  void dispose();
}

/// 存在内存里（编码后约为对象的三分之一），用于测试和临时文件不可用时
class MemoryChunkStore implements ChatChunkStore {
  final List<Uint8List?> _chunks = [];

  @override
  Object? write(Uint8List bytes) {
    _chunks.add(bytes);
    return _chunks.length - 1;
  }

  @override
  Uint8List read(Object handle) => _chunks[handle as int]!;

  @override
  void remove(Object handle) {
    if (handle is int && handle < _chunks.length) {
      _chunks[handle] = null;
    }
  }

  @override
  void clear() => _chunks.clear();

  @override
  void dispose() => clear();
}

/// 存在临时目录的文件里，关闭页面时删除。
///
/// 按 [segmentChunks] 块一个文件分段写：丢掉的块总是最早的，一段里的块都丢掉后
/// 整个文件删掉，挂得再久临时文件也不会一直变大。
/// 读写都很小（一块几十 KB），直接同步进行；文件出错时改存内存，不丢消息。
class FileChunkStore implements ChatChunkStore {
  FileChunkStore([
    Future<Directory> Function()? directory,
    this.segmentChunks = 32,
  ]) {
    (directory ?? _defaultDirectory)().then((dir) {
      if (!_disposed) {
        _dir = dir;
      }
    }).catchError((e) {
      Log.logPrint("聊天记录临时目录不可用：$e");
      _failed = true;
    });
  }

  final int segmentChunks;

  static Future<Directory> _defaultDirectory() async {
    var temp = await getTemporaryDirectory();
    return Directory("${temp.path}${Platform.pathSeparator}chat_log");
  }

  static int _serial = 0;
  static bool _cleaned = false;

  Directory? _dir;
  bool _failed = false;
  bool _disposed = false;
  final MemoryChunkStore _fallback = MemoryChunkStore();

  /// 段号 → 文件
  final Map<int, _Segment> _segments = {};
  int _current = -1;

  @override
  Object? write(Uint8List bytes) {
    // 页面关闭后（还有迟到的系统提示）不再新建文件
    if (_failed || _disposed) {
      return _fallback.write(bytes);
    }
    if (_dir == null) {
      return null;
    }
    try {
      var segment = _segments[_current];
      if (segment == null || segment.written >= segmentChunks) {
        segment = _open();
      }
      segment.raf.setPositionSync(segment.end);
      segment.raf.writeFromSync(bytes);
      var handle = _FileHandle(_current, segment.end, bytes.length);
      segment.end += bytes.length;
      segment.written++;
      segment.live++;
      return handle;
    } catch (e) {
      Log.logPrint("聊天记录写入临时文件失败，改存内存：$e");
      _failed = true;
      return _fallback.write(bytes);
    }
  }

  @override
  Uint8List read(Object handle) {
    if (handle is int) {
      return _fallback.read(handle);
    }
    var h = handle as _FileHandle;
    var raf = _segments[h.segment]!.raf;
    raf.setPositionSync(h.offset);
    return raf.readSync(h.length);
  }

  @override
  void remove(Object handle) {
    if (handle is int) {
      _fallback.remove(handle);
      return;
    }
    var h = handle as _FileHandle;
    var segment = _segments[h.segment];
    if (segment == null) {
      return;
    }
    segment.live--;
    // 正在写的那一段还会接着用，写满并且都丢掉后才删
    if (segment.live <= 0 && h.segment != _current) {
      _segments.remove(h.segment);
      segment.delete();
    }
  }

  _Segment _open() {
    var dir = _dir!;
    dir.createSync(recursive: true);
    _cleanStale(dir);
    var file = File(
      "${dir.path}${Platform.pathSeparator}chat_${pid}_${_serial++}.bin",
    );
    var segment = _Segment(file, file.openSync(mode: FileMode.write));
    _current++;
    _segments[_current] = segment;
    return segment;
  }

  /// 删除以前异常退出时留下的文件（其他进程正在用的文件删不掉或不受影响）
  static void _cleanStale(Directory dir) {
    if (_cleaned) {
      return;
    }
    _cleaned = true;
    try {
      for (var entity in dir.listSync()) {
        var name = entity.uri.pathSegments.last;
        if (entity is File && !name.startsWith("chat_${pid}_")) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  @override
  void clear() {
    _fallback.clear();
    for (var segment in _segments.values) {
      segment.delete();
    }
    _segments.clear();
    _current = -1;
  }

  @override
  void dispose() {
    _disposed = true;
    clear();
  }
}

class _Segment {
  _Segment(this.file, this.raf);

  final File file;
  final RandomAccessFile raf;

  /// 写到哪里了
  int end = 0;

  /// 写了几块、还有几块没丢
  int written = 0;
  int live = 0;

  void delete() {
    try {
      raf.closeSync();
      file.deleteSync();
    } catch (_) {}
  }
}

class _FileHandle {
  const _FileHandle(this.segment, this.offset, this.length);

  final int segment;
  final int offset;
  final int length;
}
