import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';

/// 重复弹幕过滤（设置里的“过滤重复弹幕”）。
///
/// 规则：时间范围（[windowMs]）里同样的弹幕已经显示了 [maxCount] 次，再来的就不显示。
/// 只算显示出来的那几次：被过滤掉的不计数，所以一直有人刷同一句时，
/// 每过一个时间范围还会再显示一次，不会整场都看不到。
///
/// 做法：显示过的弹幕按时间排成一个队列（环形缓冲），另有一张“键 → 时间范围里显示了几次”
/// 的计数表。每来一条，先把队头过期的出队、计数减一，再查表。每条最多进队、出队各一次，
/// 平均每条是 O(1)；队列最长 [maxEntries]，满了先丢最早的，内存有上限。
///
/// 时间是毫秒，由调用方给（直播用单调时钟）。
/// 时间往回走时按上一次的时间算。
class DanmakuRepeatWindow {
  DanmakuRepeatWindow({this.maxEntries = 20000}) : assert(maxEntries > 0);

  /// 队列最多记多少条（大直播间 60 秒的时间范围也够用）
  final int maxEntries;

  List<String?> _keys = List<String?>.filled(64, null);
  List<int> _times = List<int>.filled(64, 0);
  int _head = 0;
  int _length = 0;
  final Map<String, int> _counts = <String, int>{};
  int? _last;

  /// 现在记着的条数
  int get length => _length;

  /// 现在记着多少种不同的弹幕
  int get distinct => _counts.length;

  /// [key] 在 [now] 之前 [windowMs] 毫秒内（不含正好 [windowMs] 毫秒前的那一刻）
  /// 显示过的次数少于 [maxCount] 时记一次，返回 true（显示）；否则返回 false（过滤掉）
  bool allow(String key, int now,
      {required int windowMs, required int maxCount}) {
    var last = _last;
    if (last != null && now < last) {
      now = last;
    }
    _last = now;
    var cutoff = now - windowMs;
    while (_length > 0 && _times[_head] <= cutoff) {
      _popFront();
    }
    var count = _counts[key] ?? 0;
    if (count >= maxCount) {
      return false;
    }
    if (_length >= maxEntries) {
      _popFront();
      count = _counts[key] ?? 0;
    }
    _push(key, now);
    _counts[key] = count + 1;
    return true;
  }

  void _push(String key, int now) {
    var capacity = _keys.length;
    if (_length == capacity) {
      _grow();
      capacity = _keys.length;
    }
    var index = (_head + _length) & (capacity - 1);
    _keys[index] = key;
    _times[index] = now;
    _length++;
  }

  void _grow() {
    var capacity = _keys.length;
    var keys = List<String?>.filled(capacity * 2, null);
    var times = List<int>.filled(capacity * 2, 0);
    for (var i = 0; i < _length; i++) {
      var from = (_head + i) & (capacity - 1);
      keys[i] = _keys[from];
      times[i] = _times[from];
    }
    _keys = keys;
    _times = times;
    _head = 0;
  }

  void _popFront() {
    var key = _keys[_head]!;
    _keys[_head] = null;
    _head = (_head + 1) & (_keys.length - 1);
    _length--;
    var count = (_counts[key] ?? 1) - 1;
    if (count <= 0) {
      _counts.remove(key);
    } else {
      _counts[key] = count;
    }
  }

  /// 全部清空（换直播间、清屏）
  void clear() {
    if (_keys.length > 64) {
      _keys = List<String?>.filled(64, null);
      _times = List<int>.filled(64, 0);
    } else {
      _keys.fillRange(0, _keys.length, null);
    }
    _head = 0;
    _length = 0;
    _counts.clear();
    _last = null;
  }
}

/// 一条弹幕在过滤里怎么处理
enum DanmakuRepeat {
  /// 不算重复，照常显示
  none,

  /// 重复：不上视频，聊天区照常显示
  video,

  /// 重复：视频和聊天区（以及跟着聊天区的录屏接口、弹幕记录）都不显示
  all,
}

/// 过滤用到的设置。设置可以随时变，每条弹幕都重新读一次
class DanmakuDedupeOptions {
  /// 开没开“过滤重复弹幕”
  final bool enabled;

  /// 时间范围（秒）
  final int windowSeconds;

  /// true：同一个人发的相同内容才算重复；false：只看内容
  final bool byUser;

  /// 时间范围里同样的弹幕最多显示几次
  final int maxCount;

  /// 聊天区也去掉重复
  final bool chatToo;

  const DanmakuDedupeOptions({
    this.enabled = true,
    this.windowSeconds = 10,
    this.byUser = true,
    this.maxCount = 1,
    this.chatToo = false,
  });

  static const DanmakuDedupeOptions off = DanmakuDedupeOptions(enabled: false);
}

/// 比较前把弹幕内容规范化：
/// - 去掉首尾空白，中间连续的空白合成一个空格；
/// - 零宽字符、U+034F、标签字符（U+E0000～U+E007F）直接去掉：Twitch 的聊天客户端
///   靠在末尾加这些字符绕过平台的重复消息检查；
/// - 英文转小写，去掉句末的标点（“666！！！”和“666”算同一句）；
///   整句都是标点时保留（“？？？”不会变成空的）；
/// - 表情按表情本身比：表情的文字（“[doge]”“Kappa”“:)”）原样保留，
///   不转小写，结尾是表情时也不去标点；整条是大表情时按大表情比。
String normalizeDanmakuText(
  String text, {
  List<LiveEmote>? emotes,
  LiveEmote? sticker,
}) {
  if (sticker != null) {
    var name = sticker.text.isNotEmpty ? sticker.text : text;
    return "\u0001$name";
  }
  var writer = _NormalWriter(text.length);
  if (emotes == null || emotes.isEmpty) {
    writer.writeText(text.toLowerCase());
  } else {
    for (var part in splitLiveEmotes(text, emotes)) {
      if (part.isEmote) {
        writer.writeEmote(part.text);
      } else {
        writer.writeText(part.text.toLowerCase());
      }
    }
  }
  return writer.finish();
}

class _NormalWriter {
  _NormalWriter(int capacity) : _units = Uint16List(capacity);

  Uint16List _units;
  int _length = 0;
  bool _pendingSpace = false;

  /// 最后一个表情结束的位置：去句末标点时不能删到这里之前
  int _protected = 0;

  void _add(int unit) {
    if (_length == _units.length) {
      var more = Uint16List(_units.length * 2 + 8);
      more.setRange(0, _length, _units);
      _units = more;
    }
    _units[_length++] = unit;
  }

  void _addVisible(int unit) {
    if (_pendingSpace) {
      _pendingSpace = false;
      if (_length > 0) {
        _add(0x20);
      }
    }
    _add(unit);
  }

  void writeText(String text) {
    var n = text.length;
    for (var i = 0; i < n; i++) {
      var c = text.codeUnitAt(i);
      if (c == 0xdb40 && i + 1 < n) {
        var low = text.codeUnitAt(i + 1);
        if (low >= 0xdc00 && low <= 0xdc7f) {
          // 标签字符（U+E0000～U+E007F）
          i++;
          continue;
        }
      }
      if (_isInvisible(c)) {
        continue;
      }
      if (_isSpace(c)) {
        _pendingSpace = true;
        continue;
      }
      _addVisible(c);
    }
  }

  void writeEmote(String text) {
    for (var i = 0; i < text.length; i++) {
      _addVisible(text.codeUnitAt(i));
    }
    _protected = _length;
  }

  String finish() {
    var end = _length;
    while (end > _protected &&
        (_units[end - 1] == 0x20 || _isEndPunctuation(_units[end - 1]))) {
      end--;
    }
    if (end == 0) {
      // 整句都是标点：保留原样（已经合并了空白）
      end = _length;
    }
    return String.fromCharCodes(_units, 0, end);
  }
}

bool _isInvisible(int c) =>
    c == 0x034f ||
    c == 0x200b ||
    c == 0x200c ||
    c == 0x200d ||
    c == 0x2060 ||
    c == 0xfeff;

bool _isSpace(int c) =>
    c <= 0x20 ||
    c == 0x7f ||
    c == 0xa0 ||
    (c >= 0x2000 && c <= 0x200a) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202f ||
    c == 0x205f ||
    c == 0x3000;

/// 句末标点：中英文的句号、问号、感叹号、逗号、顿号、省略号、波浪号、分号、冒号
bool _isEndPunctuation(int c) {
  switch (c) {
    case 0x21: // !
    case 0x2c: // ,
    case 0x2e: // .
    case 0x3a: // :
    case 0x3b: // ;
    case 0x3f: // ?
    case 0x7e: // ~
    case 0x2026: // …
    case 0x22ef: // ⋯
    case 0x3001: // 、
    case 0x3002: // 。
    case 0x301c: // 〜
    case 0xff01: // ！
    case 0xff0c: // ，
    case 0xff0e: // ．
    case 0xff1a: // ：
    case 0xff1b: // ；
    case 0xff1f: // ？
    case 0xff5e: // ～
    case 0xff61: // ｡
      return true;
  }
  return false;
}

/// “同一个人”方式里认人用的键，认不出是谁时返回 null（这条不过滤）。
///
/// 和屏蔽、“只看这个人的弹幕”用同一条规则（[sameLiveUser]）：有用户 ID 时按 ID 认，
/// 改名也认得出；没有 ID 时按用户名，必须完全一致。
/// 同一个直播间里一个平台要么都给 ID、要么都不给，所以按键比和两边比的结果一样。
String? danmakuPersonKey(String siteId, LiveMessage msg) {
  var id = msg.userId;
  if (id != null && id.isNotEmpty) {
    return "$siteId\u0001id\u0001$id";
  }
  var name = msg.userName;
  if (name.isEmpty) {
    return null;
  }
  return "$siteId\u0001$name";
}

/// 直播间里的重复弹幕过滤：在关键词屏蔽、用户屏蔽之后，弹幕缓冲之前调用 [check]
class DanmakuDedupeFilter {
  DanmakuDedupeFilter({
    required this.options,
    required this.siteId,
    int Function()? now,
    int maxEntries = 20000,
  })  : _now = now ?? _stopwatchNow(),
        _window = DanmakuRepeatWindow(maxEntries: maxEntries);

  /// 现在的设置（每条都读一次，设置改了马上生效）
  final DanmakuDedupeOptions Function() options;

  /// 现在的平台（认人用）
  final String Function() siteId;

  final int Function() _now;
  final DanmakuRepeatWindow _window;

  static int Function() _stopwatchNow() {
    var watch = Stopwatch()..start();
    return () => watch.elapsedMilliseconds;
  }

  /// 记着的条数（测试用）
  int get length => _window.length;

  /// 一条聊天消息该怎么显示。[self] 是自己发的：不过滤，也不计数。
  /// 补发的历史消息（[LiveMessage.history]）不在这个时间线上，也不过滤、不计数
  DanmakuRepeat check(LiveMessage msg, {bool self = false}) {
    var o = options();
    if (!o.enabled || self || msg.history) {
      return DanmakuRepeat.none;
    }
    var text = normalizeDanmakuText(
      msg.message,
      emotes: msg.emotes,
      sticker: msg.sticker,
    );
    String key;
    if (o.byUser) {
      var person = danmakuPersonKey(siteId(), msg);
      if (person == null) {
        return DanmakuRepeat.none;
      }
      key = "$person\u0002$text";
    } else {
      key = text;
    }
    return danmakuRepeatVerdict(key, _now(), o, _window);
  }

  /// 清空（换直播间、清屏）
  void clear() => _window.clear();
}

/// 按键和时间查一次
DanmakuRepeat danmakuRepeatVerdict(
  String key,
  int now,
  DanmakuDedupeOptions o,
  DanmakuRepeatWindow window,
) {
  var allowed = window.allow(
    key,
    now,
    windowMs: o.windowSeconds * 1000,
    maxCount: o.maxCount < 1 ? 1 : o.maxCount,
  );
  if (allowed) {
    return DanmakuRepeat.none;
  }
  return o.chatToo ? DanmakuRepeat.all : DanmakuRepeat.video;
}
