import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/model/live_message.dart';

/// Twitch / Kick 的第三方表情：7TV、BTTV、FFZ。
///
/// 这些表情不在聊天消息里，是按“空格分开的整个词”查表认出来的，
/// 表情名区分大小写，可能带标点（“???”“D:”）。
/// 表都是公开接口，不用登录：
/// - 7TV：https://7tv.io/v3/emote-sets/global、/users/twitch/{id}、/users/kick/{id}
/// - BTTV：https://api.betterttv.net/3/cached/emotes/global、/users/twitch/{id}
/// - FFZ（经 BTTV 的缓存）：…/cached/frankerfacez/emotes/global、/users/twitch/{id}
///
/// 图片只用 webp（Flutter 解不了 AVIF），宽高用 1x 的（约 32），
/// 不然 2x 的 64 会被聊天栏当成大表情。零宽表情（叠在前一个表情上的帽子、特效）
/// 和 BTTV 的文字修饰符（h!、w!…）跳过，照常显示为文字。

int _int(dynamic value) => value is num ? value.toInt() : 0;

/// BTTV 的零宽表情（叠在前一个表情上），网页端是写死的
const Set<String> _bttvZeroWidth = {
  "SoSnowy",
  "IceCold",
  "SantaHat",
  "TopHat",
  "ReinDeer",
  "CandyCane",
  "cvMask",
  "cvHazmat",
};

bool _validName(String name) =>
    name.isNotEmpty && !name.codeUnits.any(isLiveEmoteSpace);

/// 7TV 表情集 → 表情名到表情。
///
/// [json] 是 emote-set 对象，或 users/{platform}/{id} 的返回（取其中的 emote_set）。
/// 用频道表情自己的 name（频道可以改名，如 xqc 的“reeferSad”原名“TriSad”），
/// 图片 2x.webp，动图的 staticUrl 是 2x_static.webp，宽高用 1x 的；
/// 零宽表情（flags & 1，或 data.flags & 256）跳过
Map<String, LiveEmote> parseSevenTvEmoteSet(dynamic json) {
  var set = json is Map && json["emote_set"] is Map ? json["emote_set"] : json;
  var list = set is Map ? set["emotes"] : null;
  var result = <String, LiveEmote>{};
  if (list is! List) {
    return result;
  }
  for (var item in list) {
    if (item is! Map) {
      continue;
    }
    var data = item["data"];
    var name = item["name"]?.toString() ?? "";
    if (data is! Map || !_validName(name)) {
      continue;
    }
    if (_int(item["flags"]) & 1 != 0 || _int(data["flags"]) & 256 != 0) {
      continue;
    }
    var host = data["host"];
    if (host is! Map || host["files"] is! List) {
      continue;
    }
    var base = liveEmoteUrl(host["url"]);
    if (base.isEmpty) {
      continue;
    }
    var files = <String, Map>{
      for (var file in host["files"] as List)
        if (file is Map && file["name"] != null) file["name"].toString(): file,
    };
    // webp 优先；没有 webp 时动图用 gif、静态图用 png。不用 avif
    var animated = data["animated"] == true;
    Map? file;
    String? format;
    var scale = 1;
    for (var f in ["webp", if (animated) "gif" else "png"]) {
      for (var s in [2, 1, 3, 4]) {
        file = files["${s}x.$f"];
        if (file != null) {
          format = f;
          scale = s;
          break;
        }
      }
      if (file != null) {
        break;
      }
    }
    if (file == null) {
      continue;
    }
    var staticName = file["static_name"]?.toString() ?? "";
    // 宽高按 1x 算（约 32），没有 1x 时按选中那张的倍数换算
    var small = files["1x.$format"];
    var width = small != null
        ? _int(small["width"])
        : _int(file["width"]) ~/ scale;
    var height = small != null
        ? _int(small["height"])
        : _int(file["height"]) ~/ scale;
    result.putIfAbsent(
      name,
      () => LiveEmote(
        text: name,
        url: "$base/${file!["name"]}",
        staticUrl: animated && staticName.isNotEmpty
            ? "$base/$staticName"
            : null,
        width: width > 0 && height > 0 ? width : 1,
        height: width > 0 && height > 0 ? height : 1,
        spaced: true,
      ),
    );
  }
  return result;
}

/// BTTV 表情：全局列表，或频道的 {channelEmotes, sharedEmotes}。
///
/// 图片 https://cdn.betterttv.net/emote/{id}/2x.webp（png、gif 都有 webp 版），
/// 动图的静态图是 …/static/2x.webp（只有动图有）。不给宽高，按正方形占位。
/// 修饰符（modifier，如 h!、w!）和零宽表情跳过
Map<String, LiveEmote> parseBttvEmotes(dynamic json) {
  var items = <dynamic>[
    if (json is List) ...json,
    if (json is Map && json["channelEmotes"] is List) ...json["channelEmotes"],
    if (json is Map && json["sharedEmotes"] is List) ...json["sharedEmotes"],
  ];
  var result = <String, LiveEmote>{};
  for (var item in items) {
    if (item is! Map) {
      continue;
    }
    var id = item["id"]?.toString() ?? "";
    var code = item["code"]?.toString() ?? "";
    if (id.isEmpty ||
        !_validName(code) ||
        item["modifier"] == true ||
        _bttvZeroWidth.contains(code)) {
      continue;
    }
    var animated = item["animated"] == true || item["imageType"] == "gif";
    var width = _int(item["width"]);
    var height = _int(item["height"]);
    result.putIfAbsent(
      code,
      () => LiveEmote(
        text: code,
        url: "https://cdn.betterttv.net/emote/$id/2x.webp",
        staticUrl: animated
            ? "https://cdn.betterttv.net/emote/$id/static/2x.webp"
            : null,
        width: width > 0 && height > 0 ? width : 1,
        height: width > 0 && height > 0 ? height : 1,
        spaced: true,
      ),
    );
  }
  return result;
}

/// FFZ 表情：BTTV 缓存的格式（列表，{code, images:{1x,2x,4x}, animated, modifier}），
/// 或 FFZ 官方 /v1/set/global、/v1/room/id/{id} 的 {sets:{…}}
/// （{name, width, height, urls:{1,2,4}, animated?:{1,2,4}, modifier}）。
/// 用 2x 的图片；修饰符（modifier）跳过
Map<String, LiveEmote> parseFfzEmotes(dynamic json) {
  var result = <String, LiveEmote>{};
  void add(String name, String url, String? staticUrl, int width, int height) {
    if (!_validName(name) || url.isEmpty) {
      return;
    }
    result.putIfAbsent(
      name,
      () => LiveEmote(
        text: name,
        url: url,
        staticUrl: staticUrl == null || staticUrl == url ? null : staticUrl,
        width: width > 0 && height > 0 ? width : 1,
        height: width > 0 && height > 0 ? height : 1,
        spaced: true,
      ),
    );
  }

  if (json is List) {
    for (var item in json) {
      if (item is! Map || item["modifier"] == true || item["images"] is! Map) {
        continue;
      }
      var images = item["images"] as Map;
      var url = liveEmoteUrl(images["2x"] ?? images["1x"]);
      // 动图地址是 …/animated/2，去掉 animated 就是静态图
      String? staticUrl;
      if (url.contains("/animated/")) {
        staticUrl = url.replaceFirst("/animated/", "/");
      }
      add(
        item["code"]?.toString() ?? "",
        url,
        staticUrl,
        _int(item["width"]),
        _int(item["height"]),
      );
    }
    return result;
  }
  if (json is! Map || json["sets"] is! Map) {
    return result;
  }
  var sets = json["sets"] as Map;
  // 全局只用 default_sets，房间用 room.set；都没有时用全部
  var ids = <String>[
    if (json["default_sets"] is List)
      for (var id in json["default_sets"]) id.toString(),
    if (json["room"] is Map && json["room"]["set"] != null)
      json["room"]["set"].toString(),
  ];
  if (ids.isEmpty) {
    ids = [for (var id in sets.keys) id.toString()];
  }
  for (var id in ids) {
    var set = sets[id];
    var list = set is Map ? set["emoticons"] : null;
    if (list is! List) {
      continue;
    }
    for (var item in list) {
      if (item is! Map || item["modifier"] == true || item["urls"] is! Map) {
        continue;
      }
      var urls = item["urls"] as Map;
      var still = liveEmoteUrl(urls["2"] ?? urls["1"]);
      var animated = item["animated"] is Map ? item["animated"] as Map : null;
      var moving = animated == null
          ? ""
          : liveEmoteUrl(animated["2"] ?? animated["1"]);
      add(
        item["name"]?.toString() ?? "",
        moving.isNotEmpty ? moving : still,
        moving.isNotEmpty ? still : null,
        _int(item["width"]),
        _int(item["height"]),
      );
    }
  }
  return result;
}

/// 把词首尾的不可见字符去掉（Chatterino 等客户端会在消息末尾加 U+E0000 或 U+034F
/// 绕过重复消息检查）
String _trimInvisible(String word) {
  var start = 0;
  var end = word.length;
  bool tagAt(int i) =>
      i + 1 < word.length &&
      word.codeUnitAt(i) == 0xdb40 &&
      word.codeUnitAt(i + 1) >= 0xdc00 &&
      word.codeUnitAt(i + 1) <= 0xdfff;
  while (start < end) {
    if (isLiveEmoteSpace(word.codeUnitAt(start))) {
      start++;
    } else if (tagAt(start)) {
      start += 2;
    } else {
      break;
    }
  }
  while (end > start) {
    if (isLiveEmoteSpace(word.codeUnitAt(end - 1))) {
      end--;
    } else if (end - 2 >= start && tagAt(end - 2)) {
      end -= 2;
    } else {
      break;
    }
  }
  return word.substring(start, end);
}

final RegExp _whitespace = RegExp(r'\s+');

/// 按空格切词，整个词查 [table]。
///
/// [native] 是平台自己给出的表情（如 Twitch IRC 的 emotes 标签），放在前面，
/// 同名时用它（[splitLiveEmotes] 同名时取先出现的）；已经在 [native] 里的词不重复加。
/// 没有表情时返回 null
List<LiveEmote>? matchWordEmotes(
  String message,
  Map<String, LiveEmote>? table, {
  List<LiveEmote>? native,
}) {
  if (table == null || table.isEmpty || message.isEmpty) {
    return native == null || native.isEmpty ? null : native;
  }
  var result = <LiveEmote>[...?native];
  var seen = {for (var e in result) e.text};
  for (var word in message.split(_whitespace)) {
    word = _trimInvisible(word);
    if (word.isEmpty || seen.contains(word)) {
      continue;
    }
    var emote = table[word];
    if (emote != null) {
      seen.add(word);
      result.add(emote);
    }
  }
  return result.isEmpty ? null : result;
}

/// 一张表（全局，或一个频道的一个来源）的加载状态
class _EmoteTable {
  Map<String, LiveEmote> emotes = const {};
  DateTime? loadedAt;
  DateTime? failedAt;
  Future<void>? loading;

  /// 读过，而且没有过期（[ttl] 为 null 时一直有效）
  bool fresh(Duration? ttl) {
    var time = loadedAt;
    return time != null &&
        (ttl == null || DateTime.now().difference(time) < ttl);
  }

  Future<void> load(
    Future<Map<String, LiveEmote>> Function() fetch, {
    Duration? ttl,
  }) {
    if (fresh(ttl)) {
      return Future.value();
    }
    var failed = failedAt;
    if (failed != null &&
        DateTime.now().difference(failed) < ThirdPartyEmotes.kRetryAfter) {
      return Future.value();
    }
    return loading ??= () async {
      try {
        emotes = await fetch();
        loadedAt = DateTime.now();
        failedAt = null;
      } catch (e) {
        CoreLog.error(e);
        failedAt = DateTime.now();
      } finally {
        loading = null;
        ThirdPartyEmotes._version++;
      }
    }();
  }
}

/// 一个频道的表情（7TV；Twitch 还有 BTTV、FFZ）
class _ChannelEmotes {
  final _EmoteTable sevenTv = _EmoteTable();
  final _EmoteTable? bttv;
  final _EmoteTable? ffz;
  _ChannelEmotes({bool twitch = true})
    : bttv = twitch ? _EmoteTable() : null,
      ffz = twitch ? _EmoteTable() : null;

  List<_EmoteTable> get tables => [sevenTv, ?bttv, ?ffz];

  int get size => tables.fold(0, (sum, e) => sum + e.emotes.length);

  bool get loading => tables.any((e) => e.loading != null);
}

/// 第三方表情的表：全局表每次运行读一次，频道表按频道缓存在内存里。
///
/// - 表还没读到时表情显示为文字；失败后 [kRetryAfter] 内不再请求；
/// - 频道没有开通（接口返回 404）时当作没有表情，同样缓存，不会每条消息都去请求；
/// - 频道表 [kChannelTtl] 后过期，重连、重新进入直播间时不重新请求；
///   大频道的 7TV 表有上千个表情（返回的 JSON 有几 MB），
///   所有频道合计超过 [kMaxCachedEmotes] 个或 [kMaxChannels] 个频道时，
///   最久没用的频道先清掉。
class ThirdPartyEmotes {
  ThirdPartyEmotes._();

  static const String kSevenTvApi = "https://7tv.io/v3";
  static const String kBttvApi = "https://api.betterttv.net/3/cached";
  static const Duration kChannelTtl = Duration(hours: 1);
  static const Duration kRetryAfter = Duration(minutes: 10);
  static const int kMaxChannels = 12;
  static const int kMaxCachedEmotes = 20000;

  static final _EmoteTable _sevenTvGlobal = _EmoteTable();
  static final _EmoteTable _bttvGlobal = _EmoteTable();
  static final _EmoteTable _ffzGlobal = _EmoteTable();

  /// 频道：“twitch:{数字 id}”“kick:{user_id}”，按最近使用排序
  static final LinkedHashMap<String, _ChannelEmotes> _channels =
      LinkedHashMap();

  /// 合并后的表，按 [_version] 失效
  static final Map<String, (int, Map<String, LiveEmote>)> _merged = {};

  /// 任何一张表读完（成功或失败）时加一
  static int _version = 0;

  /// 测试用：替换网络请求（返回解析好的 JSON，404 时抛出 statusCode 为 404 的 CoreError）
  static Future<dynamic> Function(String url)? debugGetJson;

  static Future<Map<String, LiveEmote>> _fetch(
    String url,
    Map<String, LiveEmote> Function(dynamic json) parse,
  ) async {
    dynamic result;
    try {
      result = debugGetJson != null
          ? await debugGetJson!(url)
          : await HttpClient.instance.getJson(url);
    } on CoreError catch (e) {
      // 频道没有开通：7TV、BTTV 都返回 404
      if (e.statusCode == 404) {
        return const {};
      }
      rethrow;
    }
    if (result is String) {
      result = result.trim().isEmpty ? null : json.decode(result);
    }
    return parse(result);
  }

  /// 读取全局表情（7TV，[bttvFfz] 时还有 BTTV、FFZ），已读到或正在读时不重复请求
  static Future<void> loadGlobal({bool bttvFfz = true}) {
    return Future.wait([
      _sevenTvGlobal.load(
        () => _fetch("$kSevenTvApi/emote-sets/global", parseSevenTvEmoteSet),
      ),
      if (bttvFfz)
        _bttvGlobal.load(
          () => _fetch("$kBttvApi/emotes/global", parseBttvEmotes),
        ),
      if (bttvFfz)
        _ffzGlobal.load(
          () => _fetch("$kBttvApi/frankerfacez/emotes/global", parseFfzEmotes),
        ),
    ]);
  }

  static _ChannelEmotes _channel(String key, {required bool twitch}) {
    var channel = _channels.remove(key) ?? _ChannelEmotes(twitch: twitch);
    _channels[key] = channel;
    return channel;
  }

  /// 读取 Twitch 频道的表情（[userId] 是 Twitch 的数字 id）
  static Future<void> loadTwitchChannel(String userId) async {
    if (userId.isEmpty) {
      return;
    }
    var key = "twitch:$userId";
    var channel = _channel(key, twitch: true);
    await Future.wait([
      channel.sevenTv.load(
        () => _fetch("$kSevenTvApi/users/twitch/$userId", parseSevenTvEmoteSet),
        ttl: kChannelTtl,
      ),
      channel.bttv!.load(
        () => _fetch("$kBttvApi/users/twitch/$userId", parseBttvEmotes),
        ttl: kChannelTtl,
      ),
      channel.ffz!.load(
        () => _fetch(
          "$kBttvApi/frankerfacez/users/twitch/$userId",
          parseFfzEmotes,
        ),
        ttl: kChannelTtl,
      ),
    ]);
    _trim(key);
  }

  /// 读取 Kick 频道的 7TV 表情（[userId] 是 Kick 的 user_id，不是 channel id）
  static Future<void> loadKickChannel(int userId) async {
    if (userId <= 0) {
      return;
    }
    var key = "kick:$userId";
    var channel = _channel(key, twitch: false);
    await channel.sevenTv.load(
      () => _fetch("$kSevenTvApi/users/kick/$userId", parseSevenTvEmoteSet),
      ttl: kChannelTtl,
    );
    _trim(key);
  }

  /// 清掉最久没用的频道，[keep] 是刚读的频道
  static void _trim(String keep) {
    var total = _channels.values.fold(0, (sum, e) => sum + e.size);
    for (var key in _channels.keys.toList()) {
      if (total <= kMaxCachedEmotes && _channels.length <= kMaxChannels) {
        break;
      }
      var channel = _channels[key]!;
      if (key == keep || channel.loading) {
        continue;
      }
      total -= channel.size;
      _channels.remove(key);
      _merged.remove(key);
    }
  }

  /// 频道 [key] 和全局表合并后的表；频道没有读过时只有全局表（共用“{平台}:”这一份）
  static Map<String, LiveEmote> _table(
    String platform,
    String key,
    List<_EmoteTable> Function(_ChannelEmotes? channel) sources,
  ) {
    var channel = _channels.remove(key);
    if (channel != null) {
      // 移到最后：最近使用
      _channels[key] = channel;
    } else {
      key = "$platform:";
    }
    var cached = _merged[key];
    if (cached != null && cached.$1 == _version) {
      return cached.$2;
    }
    var merged = <String, LiveEmote>{};
    for (var table in sources(channel)) {
      for (var entry in table.emotes.entries) {
        merged.putIfAbsent(entry.key, () => entry.value);
      }
    }
    _merged[key] = (_version, merged);
    return merged;
  }

  /// Twitch 频道能用的第三方表情（没有 [userId] 时只有全局表情）。
  /// 同名时：7TV 频道 > BTTV 频道 > FFZ 频道 > 7TV 全局 > BTTV 全局 > FFZ 全局
  static Map<String, LiveEmote> twitch(String? userId) => _table(
    "twitch",
    "twitch:${userId ?? ""}",
    (channel) => [...?channel?.tables, _sevenTvGlobal, _bttvGlobal, _ffzGlobal],
  );

  /// Kick 频道能用的 7TV 表情：频道 > 全局
  static Map<String, LiveEmote> kick(int? userId) => _table(
    "kick",
    "kick:${userId ?? 0}",
    (channel) => [?channel?.sevenTv, _sevenTvGlobal],
  );

  /// 测试用：直接设置表（[twitchChannels] 的键是 Twitch 数字 id，
  /// [kickChannels] 的键是 Kick 的 user_id）
  static void debugSet({
    Map<String, LiveEmote>? sevenTvGlobal,
    Map<String, LiveEmote>? bttvGlobal,
    Map<String, LiveEmote>? ffzGlobal,
    Map<String, Map<String, LiveEmote>>? twitchChannels,
    Map<int, Map<String, LiveEmote>>? kickChannels,
  }) {
    var now = DateTime.now();
    void set(_EmoteTable table, Map<String, LiveEmote>? emotes) {
      if (emotes != null) {
        table
          ..emotes = emotes
          ..loadedAt = now;
      }
    }

    set(_sevenTvGlobal, sevenTvGlobal);
    set(_bttvGlobal, bttvGlobal);
    set(_ffzGlobal, ffzGlobal);
    twitchChannels?.forEach((id, emotes) {
      var channel = _channel("twitch:$id", twitch: true);
      set(channel.sevenTv, emotes);
      set(channel.bttv!, const {});
      set(channel.ffz!, const {});
    });
    kickChannels?.forEach((id, emotes) {
      set(_channel("kick:$id", twitch: false).sevenTv, emotes);
    });
    _version++;
  }

  /// 测试用：清空所有表和请求替换
  static void debugReset() {
    for (var table in [_sevenTvGlobal, _bttvGlobal, _ffzGlobal]) {
      table
        ..emotes = const {}
        ..loadedAt = null
        ..failedAt = null
        ..loading = null;
    }
    _channels.clear();
    _merged.clear();
    debugGetJson = null;
    _version++;
  }

  /// 测试用：缓存了几个频道
  static int get debugChannelCount => _channels.length;
}
