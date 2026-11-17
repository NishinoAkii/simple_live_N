import 'dart:math';

import 'package:simple_live_core/simple_live_core.dart';

/// 弹幕在 ASS 里的显示方式
enum AssCommentType {
  /// 从右往左滚动
  scroll,

  /// 顶部居中固定
  top,

  /// 底部居中固定
  bottom,
}

/// 礼物在 ASS 里的颜色（金色，0xRRGGBB）
const int kAssGiftColor = 0xffc857;

/// 写进 ASS 的一条弹幕（或一行备注）
class AssComment {
  /// 相对于文件开头的时间
  final Duration time;

  /// 弹幕文字（表情保留文字，如“[doge]”）
  final String text;

  /// 颜色 0xRRGGBB
  final int color;

  final AssCommentType type;

  /// 发送者，写在 Dialogue 的 Name 字段，方便在字幕编辑器里查找
  final String userName;

  /// 醒目留言（[AssOptions.superChats] 关闭时不写）
  final bool superChat;

  /// 备注（如切换了直播间），写成 Comment 行，播放器不显示
  final bool note;

  const AssComment({
    required this.time,
    required this.text,
    this.color = 0xffffff,
    this.type = AssCommentType.scroll,
    this.userName = "",
    this.superChat = false,
    this.note = false,
  });

  /// 一行备注
  const AssComment.note(this.time, this.text)
      : color = 0xffffff,
        type = AssCommentType.top,
        userName = "",
        superChat = false,
        note = true;

  /// 聊天消息：表情保留文字，整条是大表情时用它的文字说明；
  /// 只有表情、一点文字都没有时写“[表情]”，不丢掉这条
  factory AssComment.chat(LiveMessage msg, [Duration time = Duration.zero]) {
    var text = msg.message;
    var sticker = msg.sticker;
    if (sticker != null && sticker.text.trim().isNotEmpty) {
      text = sticker.text;
    }
    if (text.trim().isEmpty && msg.hasEmotes) {
      var first = msg.emotes?.firstOrNull?.text.trim() ?? "";
      text = first.isEmpty ? "[表情]".t : first;
    }
    // 虎牙旧版的表情转义“/{dx”写成名称“[大笑]”
    text = huyaReadableEmotes(text);
    return AssComment(
      time: time,
      text: text,
      color: (msg.color.r << 16) | (msg.color.g << 8) | msg.color.b,
      userName: msg.userName,
    );
  }

  /// 醒目留言：顶部一行“【SC ￥30】用户名：内容”
  factory AssComment.superChat(
    LiveSuperChatMessage sc, [
    Duration time = Duration.zero,
  ]) {
    var price = sc.priceText ?? "￥${sc.price}";
    var text = sc.message;
    var sticker = sc.sticker;
    if (text.trim().isEmpty && sticker != null) {
      text = sticker.text;
    }
    return AssComment(
      time: time,
      text: "【SC $price】${sc.userName}：$text",
      type: AssCommentType.top,
      userName: sc.userName,
      superChat: true,
    );
  }

  /// 礼物：滚动的金色一行“【礼物】用户 投喂 小心心 ×3（¥0.1）”
  factory AssComment.gift(
    LiveGiftMessage gift, [
    Duration time = Duration.zero,
  ]) {
    const String? price = null; // 不显示礼物的价格
    return AssComment(
      time: time,
      text: ("【礼物】{userName} {text}"
          "{p}").tf({"userName": gift.userName, "text": gift.text, "p": price == null || price.isEmpty ? "" : "（$price）"}),
      color: kAssGiftColor,
      userName: gift.userName,
    );
  }

  /// 换一个时间
  AssComment at(Duration time) => AssComment(
        time: time,
        text: text,
        color: color,
        type: type,
        userName: userName,
        superChat: superChat,
        note: note,
      );
}

/// ASS 弹幕的样式与排布
class AssOptions {
  /// 画面大小（PlayResX、PlayResY）
  final int width;
  final int height;

  /// 字号（按 [height] 的像素）
  final double fontSize;

  final String fontName;

  /// 描边粗细（像素）
  final double outline;

  /// 不透明度 0~1
  final double opacity;

  /// 弹幕占画面高度的比例 0~1，决定有几行
  final double area;

  /// 滚动弹幕从右边进入到完全移出左边的时间
  final Duration scrollDuration;

  /// 顶部、底部弹幕的显示时间
  final Duration fixedDuration;

  /// 醒目留言的显示时间
  final Duration superChatDuration;

  final bool bold;

  /// 没有空行时也保留（叠在最早的那一行上）；关闭时丢掉
  final bool keepAll;

  /// 写醒目留言
  final bool superChats;

  /// 醒目留言的文字颜色 0xRRGGBB
  final int superChatColor;

  const AssOptions({
    this.width = 1920,
    this.height = 1080,
    this.fontSize = 32,
    this.fontName = "Microsoft YaHei",
    this.outline = 2,
    this.opacity = 1,
    this.area = 0.8,
    this.scrollDuration = const Duration(seconds: 10),
    this.fixedDuration = const Duration(seconds: 4),
    this.superChatDuration = const Duration(seconds: 8),
    this.bold = false,
    this.keepAll = false,
    this.superChats = true,
    this.superChatColor = 0xffd54f,
  });

  /// 应用里的弹幕大小以 540 像素高的画面为准，按 [height] 换算
  static const double referenceHeight = 540;

  /// 按应用的弹幕设置（/api/config 的内容）：字号、描边按画面高度换算。
  /// 应用的描边画在文字轮廓的两侧，ASS 的描边全在外侧，所以取一半
  factory AssOptions.fromConfig(
    Map<String, dynamic> config, {
    int width = 1920,
    int height = 1080,
    double? fontSize,
    double? speed,
    double? area,
    double? opacity,
    double? outline,
    String? fontName,
    bool keepAll = false,
    bool superChats = true,
  }) {
    double read(String key, double initial) {
      var value = config[key];
      return value is num ? value.toDouble() : initial;
    }

    var scale = height / referenceHeight;
    var weight = config["fontWeight"];
    return AssOptions(
      width: width,
      height: height,
      fontSize: fontSize ?? (read("size", 16) * scale).roundToDouble(),
      outline: outline ??
          ((read("stroke", 2) * scale / 2) * 10).roundToDouble() / 10,
      opacity: (opacity ?? read("opacity", 1)).clamp(0.0, 1.0).toDouble(),
      area: (area ?? read("area", 0.8)).clamp(0.05, 1.0).toDouble(),
      scrollDuration: Duration(
        milliseconds:
            ((speed ?? read("speed", 10)).clamp(1, 120) * 1000).round(),
      ),
      fontName: fontName ?? "Microsoft YaHei",
      // FontWeight.values 的下标：6 是 w700（粗体）
      bold: weight is num && weight >= 6,
      keepAll: keepAll,
      superChats: superChats,
    );
  }
}

/// 估算文字宽度（字号的倍数）：中日韩文字、全角符号和 emoji 约 1 个字宽，
/// ASCII 约 0.55，其它约 0.6
double estimateTextEm(String text) {
  var em = 0.0;
  for (var rune in text.runes) {
    if (rune < 0x80) {
      em += 0.55;
    } else if (_isWide(rune)) {
      em += 1.0;
    } else {
      em += 0.6;
    }
  }
  return em;
}

bool _isWide(int c) =>
    (c >= 0x1100 && c <= 0x115f) ||
    (c >= 0x2e80 && c <= 0xa4cf) ||
    (c >= 0xac00 && c <= 0xd7a3) ||
    (c >= 0xf900 && c <= 0xfaff) ||
    (c >= 0xfe30 && c <= 0xfe4f) ||
    (c >= 0xff00 && c <= 0xff60) ||
    (c >= 0xffe0 && c <= 0xffe6) ||
    (c >= 0x1f300 && c <= 0x1faff) ||
    (c >= 0x20000 && c <= 0x3fffd);

/// ASS 文字转义：“\”后面加零宽空格（不会变成 \N、\h 等），
/// 花括号写成 \{ \}，换行换成空格（弹幕只占一行）
String escapeAssText(String text) => text
    .replaceAll("\r\n", " ")
    .replaceAll("\n", " ")
    .replaceAll("\r", " ")
    .replaceAll("\\", "\\\u200b")
    .replaceAll("{", "\\{")
    .replaceAll("}", "\\}");

/// Name、Style 等以逗号分隔的字段：去掉逗号和换行
String _assField(String text) =>
    text.replaceAll(",", "，").replaceAll(RegExp(r"[\r\n]+"), " ").trim();

/// ASS 时间：H:MM:SS.cc
String assTime(Duration time) {
  var cs = (time.inMilliseconds / 10).round();
  if (cs < 0) cs = 0;
  var h = cs ~/ 360000;
  var m = (cs ~/ 6000) % 60;
  var s = (cs ~/ 100) % 60;
  var c = cs % 100;
  String two(int v) => v.toString().padLeft(2, "0");
  return "$h:${two(m)}:${two(s)}.${two(c)}";
}

/// ASS 颜色 &HBBGGRR（不带透明度）
String _bgr(int rgb) {
  var r = (rgb >> 16) & 0xff;
  var g = (rgb >> 8) & 0xff;
  var b = rgb & 0xff;
  String hex(int v) => v.toRadixString(16).padLeft(2, "0").toUpperCase();
  return "${hex(b)}${hex(g)}${hex(r)}";
}

String _num(double value) {
  if (value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  return value.toStringAsFixed(1);
}

/// 导出文件名：SimpleLive_<平台>_<房间号>_<yyyyMMdd-HHmmss>.ass
String assFileName({String? site, String? roomId, required DateTime time}) {
  String two(int v) => v.toString().padLeft(2, "0");
  var stamp = "${time.year}${two(time.month)}${two(time.day)}-"
      "${two(time.hour)}${two(time.minute)}${two(time.second)}";
  String clean(String value) =>
      value.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), "_");
  var parts = [
    "SimpleLive",
    if (site != null && site.isNotEmpty) clean(site),
    if (roomId != null && roomId.isNotEmpty) clean(roomId),
    stamp,
  ];
  return "${parts.join("_")}.ass";
}

class _ScrollSlot {
  final double start;
  final double width;
  const _ScrollSlot(this.start, this.width);
}

/// 一个 ASS 弹幕文件的写入器：文件头，然后按时间顺序逐条写 Dialogue。
///
/// 排布参考 danmaku2ass / DanmakuFactory：滚动弹幕找第一条不会和前一条
/// 相撞的行（进入时前一条已经完全进入画面，移出时追不上前一条），
/// 顶部、底部弹幕找已经消失的行；都没有空行时丢掉（[AssOptions.keepAll] 时叠上去）。
/// 每个写入器自己记行的占用，传入的弹幕要按时间先后。
class AssDanmakuWriter {
  final AssOptions options;

  AssDanmakuWriter(this.options)
      : laneHeight = max(1, (options.fontSize * 1.2).ceil()),
        _gap = options.fontSize / 2 {
    laneCount = max(1, (options.height * options.area / laneHeight).floor());
    _scroll = List.filled(laneCount, null);
    _top = List.filled(laneCount, double.negativeInfinity);
    _bottom = List.filled(laneCount, double.negativeInfinity);
  }

  /// 每行高度（像素）
  final int laneHeight;

  /// 行数
  late final int laneCount;

  final double _gap;
  late final List<_ScrollSlot?> _scroll;
  late final List<double> _top;
  late final List<double> _bottom;

  /// 写入的 Dialogue 数和丢掉的弹幕数
  int written = 0;
  int dropped = 0;

  /// 文件头：[Script Info]、[V4+ Styles]、[Events] 的 Format 行（不含 BOM）
  String header({
    String title = "SimpleLive 弹幕",
    List<String> notes = const [],
  }) {
    var o = options;
    var alpha = ((1 - o.opacity.clamp(0.0, 1.0)) * 255).round();
    var a = alpha.toRadixString(16).padLeft(2, "0").toUpperCase();
    var titleLine = title.replaceAll(RegExp(r"[\r\n]+"), " ").trim();
    return [
      "[Script Info]",
      "; SimpleLive 导出的弹幕".t,
      for (var note in notes) "; ${note.replaceAll(RegExp(r"[\r\n]+"), " ")}",
      "Title: $titleLine",
      "ScriptType: v4.00+",
      "PlayResX: ${o.width}",
      "PlayResY: ${o.height}",
      "WrapStyle: 2",
      "ScaledBorderAndShadow: yes",
      "YCbCr Matrix: None",
      "",
      "[V4+ Styles]",
      "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, "
          "OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, "
          "ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
          "Alignment, MarginL, MarginR, MarginV, Encoding",
      "Style: Default,${_assField(o.fontName)},${_num(o.fontSize)},"
          "&H${a}FFFFFF,&H${a}FFFFFF,&H${a}000000,&H${a}000000,"
          "${o.bold ? -1 : 0},0,0,0,100,100,0,0,1,${_num(o.outline)},0,7,0,0,0,1",
      "",
      "[Events]",
      "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, "
          "Effect, Text",
      "",
    ].join("\n");
  }

  /// 估算的文字宽度（像素，含描边）
  double textWidth(String text) =>
      estimateTextEm(text) * options.fontSize + options.outline * 2;

  /// 一条弹幕的 Dialogue 行（或备注的 Comment 行，不含换行）；
  /// 丢掉时（没有空行、内容为空、醒目留言已关闭）返回 null
  String? line(AssComment comment) {
    if (comment.note) {
      return "Comment: 0,${assTime(comment.time)},${assTime(comment.time)},"
          "Default,,0,0,0,,${escapeAssText(comment.text.trim())}";
    }
    if (comment.superChat && !options.superChats) {
      return null;
    }
    var text = comment.text.trim();
    if (text.isEmpty) {
      return null;
    }
    var escaped = escapeAssText(text);
    var t = comment.time.inMilliseconds / 1000;
    var width = textWidth(text);
    var color = comment.superChat ? options.superChatColor : comment.color;
    var colorTag = (color & 0xffffff) == 0xffffff ? "" : "\\c&H${_bgr(color)}&";
    var name = _assField(comment.userName);
    if (comment.type == AssCommentType.scroll) {
      var lane = _scrollLane(t, width);
      if (lane == null) {
        dropped++;
        return null;
      }
      _scroll[lane] = _ScrollSlot(t, width);
      var y = lane * laneHeight;
      var end = comment.time + options.scrollDuration;
      written++;
      return "Dialogue: 0,${assTime(comment.time)},${assTime(end)},Default,"
          "$name,0,0,0,,{\\move(${options.width},$y,${-width.ceil()},$y)"
          "$colorTag}$escaped";
    }
    var duration =
        comment.superChat ? options.superChatDuration : options.fixedDuration;
    var lanes = comment.type == AssCommentType.top ? _top : _bottom;
    var lane = _fixedLane(lanes, t);
    if (lane == null) {
      dropped++;
      return null;
    }
    lanes[lane] = t + duration.inMilliseconds / 1000;
    var end = comment.time + duration;
    var x = options.width ~/ 2;
    String tags;
    if (comment.type == AssCommentType.top) {
      tags = "\\an8\\pos($x,${lane * laneHeight})";
    } else {
      tags = "\\an2\\pos($x,${options.height - lane * laneHeight})";
    }
    written++;
    return "Dialogue: ${comment.superChat ? 2 : 1},${assTime(comment.time)},"
        "${assTime(end)},Default,$name,0,0,0,,{$tags$colorTag}$escaped";
  }

  /// 第 [lane] 行能否在 [t] 秒放一条宽 [width] 的滚动弹幕
  bool _scrollFits(_ScrollSlot? prev, double t, double width) {
    if (prev == null) {
      return true;
    }
    var screen = options.width.toDouble();
    var duration = options.scrollDuration.inMilliseconds / 1000;
    var prevSpeed = (screen + prev.width) / duration;
    var speed = (screen + width) / duration;
    var elapsed = t - prev.start;
    if (elapsed < 0) {
      return false;
    }
    // 进入：前一条已经完全进入画面，并留出间隔
    if (elapsed * prevSpeed < prev.width + _gap) {
      return false;
    }
    // 移出：前一条完全移出左边时，这一条的左边还没到左边缘
    var prevEnd = prev.start + duration;
    if (speed * (prevEnd - t) > screen - _gap) {
      return false;
    }
    return true;
  }

  int? _scrollLane(double t, double width) {
    for (var i = 0; i < laneCount; i++) {
      if (_scrollFits(_scroll[i], t, width)) {
        return i;
      }
    }
    if (!options.keepAll) {
      return null;
    }
    // 叠在最早开始的那一行上
    var best = 0;
    for (var i = 1; i < laneCount; i++) {
      if (_scroll[i]!.start < _scroll[best]!.start) {
        best = i;
      }
    }
    return best;
  }

  int? _fixedLane(List<double> lanes, double t) {
    for (var i = 0; i < laneCount; i++) {
      if (lanes[i] <= t) {
        return i;
      }
    }
    if (!options.keepAll) {
      return null;
    }
    var best = 0;
    for (var i = 1; i < laneCount; i++) {
      if (lanes[i] < lanes[best]) {
        best = i;
      }
    }
    return best;
  }

  /// 一次写出整个文件（不含 BOM）：[comments] 按时间排序后逐条写入
  static String build(
    AssOptions options,
    Iterable<AssComment> comments, {
    String title = "SimpleLive 弹幕",
    List<String> notes = const [],
  }) {
    var writer = AssDanmakuWriter(options);
    var sorted = comments.toList()..sort((a, b) => a.time.compareTo(b.time));
    var out = StringBuffer(writer.header(title: title, notes: notes));
    for (var comment in sorted) {
      var text = writer.line(comment);
      if (text != null) {
        out.write(text);
        out.write("\n");
      }
    }
    return out.toString();
  }
}
