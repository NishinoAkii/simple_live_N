import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/danmaku/douyu_aside.dart';
import 'package:simple_live_core/src/danmaku/douyu_emotes_table.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 斗鱼聊天里的表情。
///
/// 消息里没有图片，只有文字：网页端点表情时插入“[名称]”，旧版是“[emot:dyNNN]”。
/// 内置表情的图片在网页端的 JS 里：进直播间时扫一遍当前的 JS（[DouyuAside]），
/// 扫到前或扫不到时用生成好的 [kDouyuEmotes]、[kDouyuLegacyEmotes]；
/// 房间的钻粉表情、通用表情和热门梗表情从 [DouyuRoomEmotes] 读。

final RegExp _douyuEmotePattern = RegExp(
  r'\[emot:dy([^\[\]]{1,24})\]|\[([^\[\]]{1,24})\]',
);

String _imageUrl(String file) =>
    file.startsWith("http") ? file : "$kDouyuEmoteImageBase$file";

/// 内置表情“[名称]”的图片：当前网页里扫到的优先（新表情只在那里），其次内置表
String? _namedFile(String name) => DouyuAside.emote(name) ?? kDouyuEmotes[name];

/// 旧版表情 dyNNN 的图片，规则同 [_namedFile]
String? _legacyFile(String code) =>
    DouyuAside.legacyEmote(code) ?? kDouyuLegacyEmotes[code];

LiveEmote _withText(LiveEmote emote, String text) => LiveEmote(
  text: text,
  url: emote.url,
  staticUrl: emote.staticUrl,
  width: emote.width,
  height: emote.height,
);

/// 消息里的斗鱼表情，没有时返回 null。
///
/// [room] 是房间的表情（[parseDouyuRoomEmojiList]，键是“[名称]”）。
/// 同名时和网页端一样内置表情优先；旧版写法“[emot:dy名称]”也能指房间表情
List<LiveEmote>? parseDouyuEmotes(String txt, {Map<String, LiveEmote>? room}) {
  if (!txt.contains('[')) {
    return null;
  }
  var result = <LiveEmote>[];
  var seen = <String>{};
  for (var m in _douyuEmotePattern.allMatches(txt)) {
    var text = m.group(0)!;
    if (seen.contains(text)) {
      continue;
    }
    LiveEmote? emote;
    var legacy = m.group(1);
    if (legacy != null) {
      var file = _legacyFile("dy$legacy");
      var roomEmote = room?["[$legacy]"];
      if (file != null) {
        emote = LiveEmote(
          text: text,
          url: _imageUrl(file),
          width: 1,
          height: 1,
        );
      } else if (roomEmote != null) {
        emote = _withText(roomEmote, text);
      }
    } else {
      var file = _namedFile(m.group(2)!);
      emote = file != null
          ? LiveEmote(text: text, url: _imageUrl(file), width: 1, height: 1)
          : room?[text];
    }
    if (emote != null) {
      seen.add(text);
      result.add(emote);
    }
  }
  return result.isEmpty ? null : result;
}

/// 整条消息就是一个热门梗表情（200×200 的大图）时，返回这张大表情，否则为 null
LiveEmote? douyuEmoteSticker(String txt, Map<String, LiveEmote>? room) {
  var text = txt.trim();
  if (room == null || !text.startsWith('[') || !text.endsWith(']')) {
    return null;
  }
  var emote = room[text];
  // 内置表情同名时用内置的（小表情），不是大表情
  if (emote == null ||
      emote.height < 36 ||
      _namedFile(text.substring(1, text.length - 1)) != null) {
    return null;
  }
  return _withText(emote, txt);
}

bool _truthy(dynamic value) =>
    value == true || (value is num && value != 0) || value == "1";

int _int(dynamic value) =>
    value is num ? value.toInt() : int.tryParse(value?.toString() ?? "") ?? 0;

/// 解析 dfans/emojis 的返回（整个返回或其中的 data）→ “[名称]” 到表情。
///
/// - 钻粉表情 emoList、通用表情 commEmoList：名称 text，图片 pic，
///   只在 allSwitch 为真时用（和网页端一样）；
/// - 热门梗 popularEmojis.list：名称 name，图片 webPic（200×200），
///   只在 showEntry 为真时用。
///
/// 同名时前面的优先
Map<String, LiveEmote> parseDouyuRoomEmojiList(dynamic json) {
  var data = json is Map && json["data"] is Map && json.containsKey("error")
      ? json["data"]
      : json;
  var result = <String, LiveEmote>{};
  if (data is! Map) {
    return result;
  }
  void add(String name, dynamic url, {int width = 1, int height = 1}) {
    var image = liveEmoteUrl(url);
    if (name.isEmpty || image.isEmpty || name.contains(RegExp(r'[\[\]]'))) {
      return;
    }
    var text = "[$name]";
    result.putIfAbsent(
      text,
      () => LiveEmote(
        text: text,
        url: image,
        width: width > 0 && height > 0 ? width : 1,
        height: width > 0 && height > 0 ? height : 1,
      ),
    );
  }

  if (_truthy(data["allSwitch"])) {
    for (var key in ["emoList", "commEmoList"]) {
      var list = data[key];
      if (list is! List) {
        continue;
      }
      for (var item in list) {
        if (item is Map) {
          add(item["text"]?.toString() ?? "", item["pic"]);
        }
      }
    }
  }
  var popular = data["popularEmojis"];
  if (popular is Map && _truthy(popular["showEntry"])) {
    var list = popular["list"];
    for (var item in list is List ? list : const []) {
      if (item is! Map) {
        continue;
      }
      var web = liveEmoteUrl(item["webPic"]).isNotEmpty;
      add(
        item["name"]?.toString() ?? "",
        web ? item["webPic"] : item["appPic"],
        width: _int(web ? item["webPicWidth"] : item["appPicWidth"]),
        height: _int(web ? item["webPicHeight"] : item["appPicHeight"]),
      );
    }
  }
  return result;
}

/// 斗鱼房间的表情（钻粉表情、通用表情、热门梗），不用登录。
///
/// 每个房间读一次，1 小时后过期，重连时不重新请求；失败后 10 分钟内不再请求；
/// 最多缓存 [kMaxRooms] 个房间。没读到时只有内置表情
class DouyuRoomEmotes {
  DouyuRoomEmotes._();

  static const String kUrl =
      "https://www.douyu.com/japi/interact/comm/dfans/emojis";
  static const int kMaxRooms = 20;
  static const Duration _ttl = Duration(hours: 1);
  static const Duration _retryAfter = Duration(minutes: 10);

  static final LinkedHashMap<String, (DateTime, Map<String, LiveEmote>)>
  _rooms = LinkedHashMap();
  static final Map<String, Future<void>> _loading = {};
  static final Map<String, DateTime> _failedAt = {};

  /// 测试用：替换网络请求
  static Future<dynamic> Function(String roomId)? debugFetch;

  static Future<dynamic> _fetch(String roomId) async {
    if (debugFetch != null) {
      return debugFetch!(roomId);
    }
    return HttpClient.instance.getJson(
      kUrl,
      queryParameters: {"rid": roomId},
      header: {
        "Referer": "https://www.douyu.com/$roomId",
        "User-Agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
      },
    );
  }

  /// 读取房间的表情（已读到、正在读或刚失败过时不重复请求）
  static Future<void> load(String roomId) {
    if (roomId.isEmpty) {
      return Future.value();
    }
    var cached = _rooms[roomId];
    if (cached != null && DateTime.now().difference(cached.$1) < _ttl) {
      return Future.value();
    }
    var failed = _failedAt[roomId];
    if (failed != null && DateTime.now().difference(failed) < _retryAfter) {
      return Future.value();
    }
    return _loading[roomId] ??= () async {
      try {
        var result = await _fetch(roomId);
        if (result is String) {
          result = json.decode(result);
        }
        if (result is Map && result["error"] != null && result["error"] != 0) {
          throw StateError("斗鱼房间表情读取失败：{result}".tf({"result": result["error"]}));
        }
        _rooms.remove(roomId);
        _rooms[roomId] = (DateTime.now(), parseDouyuRoomEmojiList(result));
        _failedAt.remove(roomId);
        while (_rooms.length > kMaxRooms) {
          _rooms.remove(_rooms.keys.first);
        }
      } catch (e) {
        CoreLog.error(e);
        _failedAt[roomId] = DateTime.now();
      } finally {
        _loading.remove(roomId);
      }
    }();
  }

  /// 房间的表情，还没读到时为 null
  static Map<String, LiveEmote>? of(String roomId) => _rooms[roomId]?.$2;

  /// 测试用：直接设置房间的表情
  static void debugSet(String roomId, Map<String, LiveEmote> emotes) {
    _rooms[roomId] = (DateTime.now(), emotes);
  }

  /// 测试用：清空缓存和请求替换
  static void debugReset() {
    _rooms.clear();
    _loading.clear();
    _failedAt.clear();
    debugFetch = null;
  }
}
