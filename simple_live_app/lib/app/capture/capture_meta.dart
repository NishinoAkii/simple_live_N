import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:simple_live_app/i18n/i18n.dart';

/// 截图、录屏时的直播间信息：写进文件名和图片信息
class CaptureMeta {
  /// 平台 id（bilibili）和名字（哔哩哔哩）
  final String siteId;
  final String siteName;
  final String roomId;
  final String title;
  final String streamer;
  final String url;
  final DateTime time;

  /// 应用名和版本，如“Simple Live 1.25.0”
  final String software;

  /// 多出来的一行，可以为空
  final String extra;

  const CaptureMeta({
    required this.siteId,
    required this.siteName,
    required this.roomId,
    required this.title,
    required this.streamer,
    required this.url,
    required this.time,
    this.software = "Simple Live N",
    this.extra = "",
  });

  /// 文件名（不含扩展名）：主播_平台_年月日_时分秒
  String get baseName => captureBaseName(
        streamer: streamer.isNotEmpty ? streamer : roomId,
        platform: siteName.isNotEmpty ? siteName : siteId,
        time: time,
      );

  /// 图片信息里的说明，一行一项
  String get description => [
        "{label}：{value}".tf({
          "label": "平台".t,
          "value": siteName == siteId || siteName.isEmpty
              ? siteId
              : "$siteName（$siteId）",
        }),
        if (roomId.isNotEmpty)
          "{label}：{value}".tf({"label": "房间号".t, "value": roomId}),
        if (streamer.isNotEmpty)
          "{label}：{value}".tf({"label": "主播".t, "value": streamer}),
        if (title.isNotEmpty)
          "{label}：{value}".tf({"label": "标题".t, "value": title}),
        if (extra.isNotEmpty) extra,
        "{label}：{value}".tf({"label": "时间".t, "value": isoTime(time)}),
        if (url.isNotEmpty)
          "{label}：{value}".tf({"label": "链接".t, "value": url}),
      ].join("\n");

  /// PNG 的文字信息（标准的 Title、Author 等加上几项自己的）
  Map<String, String> get pngText => {
        if (title.isNotEmpty) "Title": title,
        if (streamer.isNotEmpty) "Author": streamer,
        "Description": description,
        "Creation Time": isoTime(time),
        "Software": software,
        "Source": siteName.isNotEmpty ? siteName : siteId,
        "Platform": siteId,
        if (roomId.isNotEmpty) "Room ID": roomId,
        if (url.isNotEmpty) "URL": url,
      };

  /// 2026-11-19T20:03:12+08:00
  static String isoTime(DateTime time) {
    var t = time.toLocal();
    String two(int v) => v.toString().padLeft(2, "0");
    var offset = t.timeZoneOffset;
    var sign = offset.isNegative ? "-" : "+";
    var minutes = offset.inMinutes.abs();
    return "${t.year}-${two(t.month)}-${two(t.day)}T"
        "${two(t.hour)}:${two(t.minute)}:${two(t.second)}"
        "$sign${two(minutes ~/ 60)}:${two(minutes % 60)}";
  }
}

/// 主播_平台_20261119_200312
String captureBaseName({
  required String streamer,
  required String platform,
  required DateTime time,
}) {
  var t = time.toLocal();
  String two(int v) => v.toString().padLeft(2, "0");
  var stamp = "${t.year}${two(t.month)}${two(t.day)}_"
      "${two(t.hour)}${two(t.minute)}${two(t.second)}";
  var name = safeFileName(streamer, maxLength: 40);
  return [name, safeFileName(platform, maxLength: 20), stamp]
      .where((e) => e.isNotEmpty)
      .join("_");
}

/// 去掉文件名里不能用的字符（Windows 最严），空白换成下划线
String safeFileName(String value, {int maxLength = 60}) {
  var text = value
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f\s]+'), "_")
      .replaceAll(RegExp(r'_+'), "_")
      .replaceAll(RegExp(r'^[._ ]+|[._ ]+$'), "");
  if (text.runes.length > maxLength) {
    text = String.fromCharCodes(text.runes.take(maxLength));
  }
  return text;
}

/// [dir] 里还没有的文件名：重名时加 _2、_3
File uniqueCaptureFile(Directory dir, String baseName, String extension) {
  var file = File(p.join(dir.path, "$baseName.$extension"));
  for (var i = 2; file.existsSync(); i++) {
    file = File(p.join(dir.path, "${baseName}_$i.$extension"));
  }
  return file;
}

/// 往 PNG 里写信息：文字（tEXt，有中文时用 UTF-8 的 iTXt）和 EXIF（eXIf）。
/// 都插在 IHDR 后面（eXIf 必须在图像数据之前）
class PngMeta {
  PngMeta._();

  static const List<int> _signature = [137, 80, 78, 71, 13, 10, 26, 10];

  static bool isPng(Uint8List bytes) {
    if (bytes.length < 33) {
      return false;
    }
    for (var i = 0; i < 8; i++) {
      if (bytes[i] != _signature[i]) {
        return false;
      }
    }
    return true;
  }

  /// 加上 [meta] 的信息；不是 PNG 时原样返回
  static Uint8List embedMeta(Uint8List png, CaptureMeta meta) =>
      embed(png, meta.pngText, exif: Exif.build(meta));

  static Uint8List embed(
    Uint8List png,
    Map<String, String> text, {
    Uint8List? exif,
  }) {
    if (!isPng(png)) {
      return png;
    }
    var ihdrLength = _readUint32(png, 8);
    var insertAt = 8 + 12 + ihdrLength;
    var out = BytesBuilder(copy: false)..add(png.sublist(0, insertAt));
    if (exif != null) {
      out.add(_chunk("eXIf", exif));
    }
    text.forEach((key, value) {
      out.add(_textChunk(key, value));
    });
    out.add(png.sublist(insertAt));
    return out.takeBytes();
  }

  static Uint8List _textChunk(String key, String value) {
    var keyword = latin1.encode(key);
    var latin = value.runes.every((c) => c < 0x100);
    if (latin) {
      return _chunk("tEXt", [...keyword, 0, ...latin1.encode(value)]);
    }
    // iTXt：关键字、0、不压缩（0, 0）、语言（空）、0、翻译后的关键字（空）、0、UTF-8 文字
    return _chunk("iTXt", [...keyword, 0, 0, 0, 0, 0, ...utf8.encode(value)]);
  }

  static Uint8List _chunk(String type, List<int> data) {
    var typeBytes = ascii.encode(type);
    var out = ByteData(12 + data.length);
    out.setUint32(0, data.length);
    var bytes = out.buffer.asUint8List();
    bytes.setRange(4, 8, typeBytes);
    bytes.setRange(8, 8 + data.length, data);
    out.setUint32(8 + data.length, _crc32(bytes, 4, 8 + data.length));
    return bytes;
  }

  static int _readUint32(Uint8List b, int at) =>
      (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

  /// 读出 PNG 里所有的块（类型, 数据）
  static List<(String, Uint8List)> chunks(Uint8List png) {
    var list = <(String, Uint8List)>[];
    if (!isPng(png)) {
      return list;
    }
    var at = 8;
    while (at + 12 <= png.length) {
      var length = _readUint32(png, at);
      var type = ascii.decode(png.sublist(at + 4, at + 8));
      list.add((type, png.sublist(at + 8, at + 8 + length)));
      at += 12 + length;
    }
    return list;
  }

  /// 读出文字信息（tEXt 和不压缩的 iTXt）
  static Map<String, String> readText(Uint8List png) {
    var result = <String, String>{};
    for (var (type, data) in chunks(png)) {
      var zero = data.indexOf(0);
      if (zero <= 0) {
        continue;
      }
      var key = latin1.decode(data.sublist(0, zero));
      if (type == "tEXt") {
        result[key] = latin1.decode(data.sublist(zero + 1));
      } else if (type == "iTXt" && data[zero + 1] == 0) {
        // 跳过压缩标记、压缩方法、语言、翻译后的关键字
        var at = zero + 3;
        at = data.indexOf(0, at) + 1;
        at = data.indexOf(0, at) + 1;
        result[key] = utf8.decode(data.sublist(at));
      }
    }
    return result;
  }

  static final List<int> _crcTable = List.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  static int _crc32(Uint8List bytes, int start, int end) {
    var c = 0xffffffff;
    for (var i = start; i < end; i++) {
      c = _crcTable[(c ^ bytes[i]) & 0xff] ^ (c >> 8);
    }
    return c ^ 0xffffffff;
  }
}

/// 最小的 EXIF（TIFF，小端）：说明、主播、软件、时间，Windows 的标题、备注、作者、标记，
/// 以及带时区的拍摄时间和 Unicode 的用户注释
class Exif {
  Exif._();

  static const int _byte = 1;
  static const int _ascii = 2;
  static const int _long = 4;
  static const int _undefined = 7;

  /// 写进 EXIF 的标签号（测试里用）
  static const int tagImageDescription = 0x010E;
  static const int tagSoftware = 0x0131;
  static const int tagDateTime = 0x0132;
  static const int tagArtist = 0x013B;
  static const int tagExifIfd = 0x8769;
  static const int tagXPTitle = 0x9C9B;
  static const int tagXPComment = 0x9C9C;
  static const int tagXPAuthor = 0x9C9D;
  static const int tagXPKeywords = 0x9C9E;
  static const int tagDateTimeOriginal = 0x9003;
  static const int tagOffsetTimeOriginal = 0x9011;
  static const int tagUserComment = 0x9286;

  static Uint8List build(CaptureMeta meta) {
    var t = meta.time.toLocal();
    String two(int v) => v.toString().padLeft(2, "0");
    var exifTime = "${t.year}:${two(t.month)}:${two(t.day)} "
        "${two(t.hour)}:${two(t.minute)}:${two(t.second)}";
    var iso = CaptureMeta.isoTime(t);
    var offset = iso.substring(iso.length - 6);
    var platform = meta.siteName.isNotEmpty ? meta.siteName : meta.siteId;

    Uint8List text(String s) => Uint8List.fromList([...utf8.encode(s), 0]);
    Uint8List ucs2(String s) {
      var data = ByteData(s.codeUnits.length * 2 + 2);
      for (var i = 0; i < s.codeUnits.length; i++) {
        data.setUint16(i * 2, s.codeUnits[i], Endian.little);
      }
      return data.buffer.asUint8List();
    }

    var ifd0 = SplayTreeMap<int, (int, Uint8List)>()
      ..[tagImageDescription] = (_ascii, text(meta.description))
      ..[tagSoftware] = (_ascii, text(meta.software))
      ..[tagDateTime] = (_ascii, text(exifTime))
      ..[tagExifIfd] = (_long, Uint8List(4))
      ..[tagXPComment] = (_byte, ucs2(meta.description))
      ..[tagXPKeywords] = (_byte, ucs2("Simple Live N;$platform"));
    if (meta.streamer.isNotEmpty) {
      ifd0[tagArtist] = (_ascii, text(meta.streamer));
      ifd0[tagXPAuthor] = (_byte, ucs2(meta.streamer));
    }
    if (meta.title.isNotEmpty) {
      ifd0[tagXPTitle] = (_byte, ucs2(meta.title));
    }
    var comment = ucs2(meta.description);
    var exif = SplayTreeMap<int, (int, Uint8List)>()
      ..[0x9000] = (_undefined, Uint8List.fromList(ascii.encode("0232")))
      ..[tagDateTimeOriginal] = (_ascii, text(exifTime))
      ..[tagOffsetTimeOriginal] = (_ascii, text(offset))
      ..[tagUserComment] = (
        _undefined,
        Uint8List.fromList([
          ...ascii.encode("UNICODE"),
          0,
          // 不要结尾的 0
          ...comment.sublist(0, comment.length - 2),
        ]),
      );

    int ifdSize(Map<int, (int, Uint8List)> m) => 2 + m.length * 12 + 4;
    int even(int n) => n + (n & 1);
    int dataSize(Map<int, (int, Uint8List)> m) => m.values
        .where((e) => e.$2.length > 4)
        .fold(0, (sum, e) => sum + even(e.$2.length));

    var ifd0At = 8;
    var exifAt = ifd0At + ifdSize(ifd0) + dataSize(ifd0);
    var total = exifAt + ifdSize(exif) + dataSize(exif);
    var exifPointer = ByteData(4)..setUint32(0, exifAt, Endian.little);
    ifd0[tagExifIfd] = (_long, exifPointer.buffer.asUint8List());

    var out = ByteData(total);
    var bytes = out.buffer.asUint8List();
    // 头：II、42、第一个 IFD 的位置
    bytes[0] = 0x49;
    bytes[1] = 0x49;
    out.setUint16(2, 42, Endian.little);
    out.setUint32(4, ifd0At, Endian.little);

    void writeIfd(Map<int, (int, Uint8List)> m, int at) {
      out.setUint16(at, m.length, Endian.little);
      var entry = at + 2;
      var data = at + ifdSize(m);
      for (var e in m.entries) {
        var (type, value) = e.value;
        out.setUint16(entry, e.key, Endian.little);
        out.setUint16(entry + 2, type, Endian.little);
        out.setUint32(entry + 4,
            type == _long ? value.length ~/ 4 : value.length, Endian.little);
        if (value.length <= 4) {
          bytes.setRange(entry + 8, entry + 8 + value.length, value);
        } else {
          out.setUint32(entry + 8, data, Endian.little);
          bytes.setRange(data, data + value.length, value);
          data += even(value.length);
        }
        entry += 12;
      }
      // 没有下一个 IFD
      out.setUint32(entry, 0, Endian.little);
    }

    writeIfd(ifd0, ifd0At);
    writeIfd(exif, exifAt);
    return bytes;
  }

  /// 读出某个 IFD 里的标签（测试里核对用）：标签号 → 原始数据
  static Map<int, Uint8List> readIfd(Uint8List tiff, {bool exifIfd = false}) {
    var data = ByteData.sublistView(tiff);
    var at = data.getUint32(4, Endian.little);
    Map<int, Uint8List> read(int at) {
      var result = <int, Uint8List>{};
      var count = data.getUint16(at, Endian.little);
      for (var i = 0; i < count; i++) {
        var entry = at + 2 + i * 12;
        var tag = data.getUint16(entry, Endian.little);
        var type = data.getUint16(entry + 2, Endian.little);
        var n = data.getUint32(entry + 4, Endian.little);
        var length = type == _long ? n * 4 : n;
        var offset =
            length <= 4 ? entry + 8 : data.getUint32(entry + 8, Endian.little);
        result[tag] = tiff.sublist(offset, offset + length);
      }
      return result;
    }

    var ifd0 = read(at);
    if (!exifIfd) {
      return ifd0;
    }
    var pointer = ifd0[tagExifIfd];
    if (pointer == null) {
      return {};
    }
    return read(ByteData.sublistView(pointer).getUint32(0, Endian.little));
  }
}
