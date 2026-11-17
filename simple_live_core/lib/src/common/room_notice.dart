/// 直播间公告、简介的文字处理。
///
/// 平台给的不一定是纯文字：哔哩哔哩的简介（room_info.description）是 HTML，
/// 有的直播间还是转义过一遍的 HTML（`&lt;p&gt;…`）；字段是 null 时
/// 有的平台代码里会变成字符串 "null"
library;

final _blockEnd = RegExp(
  r'<\s*br\s*/?\s*>|</\s*(p|div|li|ul|ol|h[1-6]|tr|table|section|blockquote)\s*>',
  caseSensitive: false,
);
final _hidden = RegExp(
  r'<\s*(style|script)\b[^>]*>[\s\S]*?<\s*/\s*\1\s*>',
  caseSensitive: false,
);
final _comment = RegExp(r'<!--[\s\S]*?-->');

/// 只认像标签的写法（字母或 / 开头），公告里的“<8点>”这类文字留着
final _tag = RegExp(r'</?[a-zA-Z][^<>]*>');
final _entity = RegExp(r'&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});');

/// 空格、制表符、不换行空格、全角空格、零宽字符
final _spaces = RegExp('[ \\t\\u00a0\\u3000\\u200b\\ufeff]+');

const _named = {
  "amp": "&",
  "lt": "<",
  "gt": ">",
  "quot": '"',
  "apos": "'",
  "nbsp": " ",
  "ensp": " ",
  "emsp": " ",
  "middot": "·",
  "hellip": "…",
  "mdash": "—",
  "ndash": "–",
  "ldquo": "“",
  "rdquo": "”",
  "lsquo": "‘",
  "rsquo": "’",
  "times": "×",
};

String _decodeEntities(String text) {
  if (!text.contains("&")) {
    return text;
  }
  return text.replaceAllMapped(_entity, (m) {
    var name = m[1]!;
    if (name.startsWith("#")) {
      var hex = name.length > 1 && (name[1] == "x" || name[1] == "X");
      var code = int.tryParse(
        name.substring(hex ? 2 : 1),
        radix: hex ? 16 : 10,
      );
      if (code == null ||
          code <= 0 ||
          code > 0x10ffff ||
          (code >= 0xd800 && code <= 0xdfff)) {
        return m[0]!;
      }
      return String.fromCharCode(code);
    }
    return _named[name.toLowerCase()] ?? m[0]!;
  });
}

/// 公告、简介变成纯文字：去掉 HTML 标签和实体，段落和 `<br>` 变成换行，
/// 每行去掉首尾空白，空行去掉。超过 [maxLength] 个字时截断并加省略号。
/// null、空白、字符串 "null" 都返回空字符串
String plainRoomText(String? text, {int maxLength = 2000}) {
  if (text == null) {
    return "";
  }
  var s = text.trim();
  if (s.isEmpty || s == "null") {
    return "";
  }
  // 转义过一遍的 HTML：先还原再去标签
  if (!s.contains("<") && s.contains("&lt;")) {
    s = _decodeEntities(s);
  }
  if (s.contains("<")) {
    s = s
        .replaceAll(_hidden, "")
        .replaceAll(_comment, "")
        .replaceAll(_blockEnd, "\n")
        .replaceAll(_tag, "");
  }
  s = _decodeEntities(s);
  var lines = <String>[];
  for (var line in s.split(RegExp(r'\r\n|\r|\n'))) {
    line = line.replaceAll(_spaces, " ").trim();
    if (line.isNotEmpty) {
      lines.add(line);
    }
  }
  s = lines.join("\n");
  if (maxLength > 0 && s.runes.length > maxLength) {
    s = "${String.fromCharCodes(s.runes.take(maxLength)).trimRight()}…";
  }
  return s;
}

/// 哔哩哔哩的主播公告，在房间信息（getInfoByRoom 的 data）的 news_info 里：
/// `{"uid":434334701,"ctime":"2020-10-26 11:47:20","content":"每天晚上21:00开播"}`。
/// 没写公告时 content 是空的，返回空字符串
String parseBiliRoomNews(dynamic roomInfo) {
  var news = roomInfo is Map ? roomInfo["news_info"] : null;
  if (news is! Map) {
    return "";
  }
  var content = news["content"]?.toString().trim() ?? "";
  return content == "null" ? "" : content;
}
