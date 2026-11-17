import 'dart:math';
import 'dart:typed_data';

import 'package:simple_live_app/modules/search/text/pinyin_table.g.dart';
import 'package:simple_live_app/modules/search/text/ts_table.g.dart';

/// 搜索用的文字处理：规范化、繁转简、不带声调的拼音和首字母
///
/// 数据表由 tool/gen_search_text_data.py 从开放数据生成（见各 .g.dart 文件头）。
/// 多音字只取一个读音，拼音只用来补充匹配，不保证都对。
class SearchText {
  SearchText._();

  static Map<int, int>? _tsMap;
  static List<String>? _syllables;
  static Int8List? _alphabet;

  /// 首尾要去掉的括号、引号
  static const String _brackets = "「」『』【】《》〈〉〔〕〖〗“”‘’\"'()[]{}<>";

  /// 规范化：全角转半角、去零宽字符、合并空白、去掉首尾的括号引号、转小写
  static String normalize(String text) {
    var buffer = StringBuffer();
    var space = false;
    for (var rune in text.runes) {
      var c = rune;
      if (c >= 0xFF01 && c <= 0xFF5E) {
        c -= 0xFEE0;
      } else if (c == 0x3000) {
        c = 0x20;
      }
      if (c == 0x200B ||
          c == 0x200C ||
          c == 0x200D ||
          c == 0x2060 ||
          c == 0xFEFF) {
        continue;
      }
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0) {
        space = true;
        continue;
      }
      if (space && buffer.isNotEmpty) {
        buffer.write(" ");
      }
      space = false;
      buffer.writeCharCode(c);
    }
    var s = buffer.toString();
    var start = 0;
    var end = s.length;
    while (start < end && (_brackets.contains(s[start]) || s[start] == " ")) {
      start++;
    }
    while (
        end > start && (_brackets.contains(s[end - 1]) || s[end - 1] == " ")) {
      end--;
    }
    return s.substring(start, end).toLowerCase();
  }

  static Map<int, int> get _ts {
    var map = _tsMap;
    if (map != null) return map;
    map = <int, int>{};
    var n = min(kTraditionalChars.length, kSimplifiedChars.length);
    for (var i = 0; i < n; i++) {
      map[kTraditionalChars.codeUnitAt(i)] = kSimplifiedChars.codeUnitAt(i);
    }
    return _tsMap = map;
  }

  /// 繁体字逐字转成简体（只换单字，不处理词语）
  static String toSimplified(String text) {
    var ts = _ts;
    var changed = false;
    var units = List<int>.of(text.codeUnits);
    for (var i = 0; i < units.length; i++) {
      var s = ts[units[i]];
      if (s != null) {
        units[i] = s;
        changed = true;
      }
    }
    return changed ? String.fromCharCodes(units) : text;
  }

  static bool isHan(int code) =>
      (code >= kPinyinStart && code <= kPinyinEnd) ||
      (code >= 0x3400 && code <= 0x4DBF) ||
      code == 0x3007;

  /// 文字里有没有汉字
  static bool hasHan(String text) => text.runes.any(isHan);

  /// 单个汉字的拼音（不带声调，ü 写成 v），不是汉字或没有读音时返回 null
  static String? pinyinOf(int code) {
    if (code == 0x3007) return "ling";
    if (code < kPinyinStart || code > kPinyinEnd) return null;
    var alphabet = _alphabet ??= _buildAlphabet();
    var i = (code - kPinyinStart) * 2;
    var hi = alphabet[kPinyinCodes.codeUnitAt(i) & 0x7F];
    var lo = alphabet[kPinyinCodes.codeUnitAt(i + 1) & 0x7F];
    if (hi < 0 || lo < 0) return null;
    var index = hi * 64 + lo;
    if (index == 0) return null;
    var syllables = _syllables ??= kPinyinSyllables.split(" ");
    return index <= syllables.length ? syllables[index - 1] : null;
  }

  static Int8List _buildAlphabet() {
    var table = Int8List(128)..fillRange(0, 128, -1);
    for (var i = 0; i < kPinyinAlphabet.length; i++) {
      table[kPinyinAlphabet.codeUnitAt(i)] = i;
    }
    return table;
  }

  static bool _isAsciiWord(int c) =>
      (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39);

  /// 全拼：汉字换成不带声调的拼音，字母数字保留（转小写），其他字符去掉，不加分隔
  ///
  /// 例：“老番茄” → laofanqie，“XTT甜甜” → xtttiantian
  static String toPinyin(String text) {
    var buffer = StringBuffer();
    for (var rune in text.toLowerCase().runes) {
      var py = pinyinOf(rune);
      if (py != null) {
        buffer.write(py);
      } else if (_isAsciiWord(rune)) {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// 首字母：每个汉字取拼音的第一个字母，字母数字保留
  ///
  /// 例：“老番茄” → lfq，“XTT甜甜” → xtttt
  static String toInitials(String text) {
    var buffer = StringBuffer();
    for (var rune in text.toLowerCase().runes) {
      var py = pinyinOf(rune);
      if (py != null) {
        buffer.write(py[0]);
      } else if (_isAsciiWord(rune)) {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// 规范化后只有字母、数字和空格（像拼音、首字母或英文名）
  static bool isLatin(String text) =>
      text.isNotEmpty && text.runes.every((c) => _isAsciiWord(c) || c == 0x20);

  /// 两个字符串的编辑距离，超过 [limit] 时提前返回 limit + 1
  static int editDistance(String a, String b, int limit) {
    if ((a.length - b.length).abs() > limit) return limit + 1;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    var cur = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      cur[0] = i;
      var rowMin = cur[0];
      for (var j = 1; j <= b.length; j++) {
        var cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = min(min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
        rowMin = min(rowMin, cur[j]);
      }
      if (rowMin > limit) return limit + 1;
      var t = prev;
      prev = cur;
      cur = t;
    }
    return prev[b.length];
  }
}

/// 预先算好的一段文字（名字、关键词），比较时不用重复转换
class SearchKey {
  /// 原文
  final String raw;

  /// 规范化 + 繁转简
  final String text;

  /// [text] 去掉空格
  final String compact;

  /// 全拼（见 [SearchText.toPinyin]）
  final String pinyin;

  /// 首字母（见 [SearchText.toInitials]）
  final String initials;

  /// 有没有汉字
  final bool hasHan;

  SearchKey._(
    this.raw,
    this.text,
    this.compact,
    this.pinyin,
    this.initials,
    this.hasHan,
  );

  factory SearchKey(String raw) {
    var text = SearchText.toSimplified(SearchText.normalize(raw));
    var han = SearchText.hasHan(text);
    return SearchKey._(
      raw,
      text,
      text.replaceAll(" ", ""),
      SearchText.toPinyin(text),
      han ? SearchText.toInitials(text) : "",
      han,
    );
  }

  bool get isEmpty => compact.isEmpty;

  /// 关键词像拼音、首字母或英文（只有字母数字）
  bool get isLatin => !hasHan && SearchText.isLatin(text);
}

/// 本地模糊匹配的分数，0 为不匹配：
/// 完全相同 100 > 前缀 80 > 包含 60 > 全拼前缀/包含 50 > 首字母前缀 45 >
/// 拉丁字母编辑距离 ≤1（长度 ≥4）或 ≤2（长度 ≥8）30
int searchScore(SearchKey query, SearchKey name) {
  var q = query.compact;
  var n = name.compact;
  if (q.isEmpty || n.isEmpty) return 0;
  if (n == q) return 100;
  if (n.startsWith(q)) return 80;
  if (n.contains(q)) return 60;
  // 拼音：中文关键词比拼音（能对上同音错字），拉丁关键词直接当拼音；
  // 很短的拉丁关键词只比开头，免得“an”之类到处都能对上
  var qp = query.pinyin;
  var np = name.pinyin;
  if (qp.length >= 2 && (query.hasHan || name.hasHan)) {
    if (np.startsWith(qp) ||
        ((query.hasHan || qp.length >= 4) && np.contains(qp))) {
      return 50;
    }
  }
  if (query.isLatin && name.hasHan && qp.length >= 2) {
    if (name.initials.startsWith(qp)) return 45;
  }
  // 拼写错一两个字母：比整个名字，或者名字开头同样长的一段
  if (query.isLatin && qp.length >= 4) {
    var limit = qp.length >= 8 ? 2 : 1;
    if (SearchText.editDistance(qp, np, limit) <= limit) return 30;
    if (np.length > qp.length &&
        SearchText.editDistance(qp, np.substring(0, qp.length), limit) <=
            limit) {
      return 30;
    }
  }
  return 0;
}
