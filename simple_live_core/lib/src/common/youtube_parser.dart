import 'dart:convert';

import 'package:simple_live_core/src/model/live_anchor_item.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';

// InnerTube 响应的解析。都是纯函数，便于用离线样本测试。

/// 读取 InnerTube 文本：simpleText、runs（表情换成短代码）或视图模型的 content
String ytText(dynamic node) {
  if (node == null) {
    return "";
  }
  if (node is String) {
    return node;
  }
  if (node is! Map) {
    return "";
  }
  var simple = node["simpleText"];
  if (simple != null) {
    return simple.toString();
  }
  var content = node["content"];
  if (content is String) {
    return content;
  }
  var runs = node["runs"];
  if (runs is List) {
    return runs.map(ytRunText).join();
  }
  return "";
}

/// 一段 run：文字，或表情
String ytRunText(dynamic run) {
  if (run is! Map) {
    return "";
  }
  var text = run["text"];
  if (text != null) {
    return text.toString();
  }
  var emoji = run["emoji"];
  if (emoji is Map) {
    return ytEmojiText(emoji);
  }
  return "";
}

/// 表情的文字形式
///
/// 标准表情的 emojiId 就是表情字符本身，直接显示；
/// 频道自定义表情（emojiId 形如 UC…/xxx）用短代码，如 :face-purple-crying:。
String ytEmojiText(Map emoji) {
  var id = emoji["emojiId"]?.toString() ?? "";
  if (emoji["isCustomEmoji"] != true && id.isNotEmpty && !id.contains('/')) {
    return id;
  }
  var shortcuts = emoji["shortcuts"];
  if (shortcuts is List && shortcuts.isNotEmpty) {
    return shortcuts.first.toString();
  }
  var label = emoji["image"]?["accessibility"]?["accessibilityData"]?["label"];
  if (label != null && label.toString().isNotEmpty) {
    return ":$label:";
  }
  var terms = emoji["searchTerms"];
  if (terms is List && terms.isNotEmpty) {
    return ":${terms.first}:";
  }
  return id;
}

/// 文字（runs）里的频道自定义表情与 YouTube 表情（如 :face-blue-smiling:），
/// 文字形式与 [ytEmojiText] 相同；标准表情是表情字符本身，系统字体能显示，不算在内。
/// 没有时返回 null
List<LiveEmote>? ytEmotes(dynamic node) {
  var runs = node is Map ? node["runs"] : null;
  if (runs is! List) {
    return null;
  }
  var result = <LiveEmote>[];
  var seen = <String>{};
  for (var run in runs) {
    var emoji = run is Map ? run["emoji"] : null;
    if (emoji is! Map) {
      continue;
    }
    var id = emoji["emojiId"]?.toString() ?? "";
    if (emoji["isCustomEmoji"] != true && id.isNotEmpty && !id.contains('/')) {
      continue;
    }
    var text = ytEmojiText(emoji);
    if (text.isEmpty || !seen.add(text)) {
      continue;
    }
    var url = ytThumbnail(emoji["image"], target: 48);
    if (url.isEmpty) {
      continue;
    }
    result.add(LiveEmote(text: text, url: url, width: 1, height: 1));
  }
  return result.isEmpty ? null : result;
}

/// 从缩略图列表中选一张：宽度不小于 [target] 的最小一张，没有时取最大的
///
/// 兼容 {thumbnails: [...]}（渲染器）与 {sources: [...]}（视图模型），
/// 补全以 // 开头的地址。
String ytThumbnail(dynamic node, {int target = 0}) {
  if (node is! Map) {
    return "";
  }
  var list = node["thumbnails"] ?? node["sources"];
  if (list is! List || list.isEmpty) {
    return "";
  }
  var items = list.whereType<Map>().where((e) => e["url"] != null).toList();
  if (items.isEmpty) {
    return "";
  }
  int width(Map e) => (e["width"] as num?)?.toInt() ?? 0;
  items.sort((a, b) => width(a).compareTo(width(b)));
  var picked = items.last;
  for (var item in items) {
    if (width(item) >= target) {
      picked = item;
      break;
    }
  }
  return ytFixUrl(picked["url"].toString());
}

/// 补全协议
String ytFixUrl(String url) {
  if (url.startsWith("//")) {
    return "https:$url";
  }
  return url;
}

/// 频道头像地址中的尺寸（=s900-…）换成 [size]，减少列表中加载的图片大小
String ytResizeAvatar(String url, int size) {
  return url.replaceFirst(RegExp(r'=s\d+(?=-|$)'), "=s$size");
}

/// 递归查找所有名为 [key] 的节点
List<dynamic> ytFindAll(dynamic node, String key) {
  var result = <dynamic>[];
  void walk(dynamic value) {
    if (value is Map) {
      value.forEach((k, v) {
        if (k == key) {
          result.add(v);
        }
        walk(v);
      });
    } else if (value is List) {
      for (var v in value) {
        walk(v);
      }
    }
  }

  walk(node);
  return result;
}

/// 第一个名为 [key] 的节点
dynamic ytFindFirst(dynamic node, String key) {
  dynamic found;
  bool walk(dynamic value) {
    if (value is Map) {
      for (var entry in value.entries) {
        if (entry.key == key) {
          found = entry.value;
          return true;
        }
        if (walk(entry.value)) {
          return true;
        }
      }
    } else if (value is List) {
      for (var v in value) {
        if (walk(v)) {
          return true;
        }
      }
    }
    return false;
  }

  walk(node);
  return found;
}

/// 文本中的数字（“8,989 人正在观看”→ 8989），没有时为 0
///
/// 只用于完整数字的文本（viewCountText），不能用于“8.9K”这类缩写。
int ytParseCount(String text) {
  var digits = text.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) {
    return 0;
  }
  return int.tryParse(digits) ?? 0;
}

/// 视频卡片是否正在直播（排除预告和已经结束的直播）
bool ytIsLiveVideo(Map video) {
  if (video["upcomingEventData"] != null) {
    return false;
  }
  var badges = video["badges"];
  if (badges is List) {
    for (var badge in badges) {
      if (badge is Map &&
          badge["metadataBadgeRenderer"]?["style"] ==
              "BADGE_STYLE_TYPE_LIVE_NOW") {
        return true;
      }
    }
  }
  var overlays = video["thumbnailOverlays"];
  if (overlays is List) {
    for (var overlay in overlays) {
      if (overlay is Map &&
          overlay["thumbnailOverlayTimeStatusRenderer"]?["style"] == "LIVE") {
        return true;
      }
    }
  }
  return false;
}

/// 视频卡片所属频道 ID
String ytVideoChannelId(Map video) {
  for (var key in ["ownerText", "longBylineText", "shortBylineText"]) {
    var runs = video[key]?["runs"];
    if (runs is List) {
      for (var run in runs) {
        var id = run is Map
            ? (run["navigationEndpoint"]?["browseEndpoint"]?["browseId"])
            : null;
        if (id is String && id.startsWith("UC")) {
          return id;
        }
      }
    }
  }
  var id = ytFindFirst(video["channelThumbnailSupportedRenderers"], "browseId");
  if (id is String && id.startsWith("UC")) {
    return id;
  }
  return "";
}

/// 响应中所有正在直播的视频，房间号为频道 ID；同一频道只保留第一条
List<LiveRoomItem> parseYouTubeLiveRooms(dynamic response) {
  return parseYouTubeLiveVideos(response).map((e) => e.room).toList();
}

/// 同 [parseYouTubeLiveRooms]，并带上各条对应的视频 ID
///
/// 同一频道可能同时开着几场直播（如新闻台），列表里显示的不一定是
/// /channel/UC…/live 指向的那一场；站点据此记住用户点开的是哪一场。
List<({LiveRoomItem room, String videoId})> parseYouTubeLiveVideos(
  dynamic response,
) {
  var items = <({LiveRoomItem room, String videoId})>[];
  var channels = <String>{};
  for (var video in ytFindAll(response, "videoRenderer")) {
    if (video is! Map || !ytIsLiveVideo(video)) {
      continue;
    }
    var channelId = ytVideoChannelId(video);
    if (channelId.isEmpty || !channels.add(channelId)) {
      continue;
    }
    var owner = ytText(video["ownerText"]);
    items.add((
      room: LiveRoomItem(
        roomId: channelId,
        title: ytText(video["title"]),
        cover: ytThumbnail(video["thumbnail"], target: 480),
        userName: owner.isNotEmpty ? owner : ytText(video["longBylineText"]),
        online: ytParseCount(ytText(video["viewCountText"])),
      ),
      videoId: video["videoId"]?.toString() ?? "",
    ));
  }
  return items;
}

/// 频道搜索结果
List<LiveAnchorItem> parseYouTubeChannels(dynamic response) {
  var items = <LiveAnchorItem>[];
  for (var channel in ytFindAll(response, "channelRenderer")) {
    if (channel is! Map) {
      continue;
    }
    var id = channel["channelId"]?.toString() ?? "";
    if (!id.startsWith("UC")) {
      continue;
    }
    items.add(
      LiveAnchorItem(
        roomId: id,
        avatar: ytThumbnail(channel["thumbnail"], target: 88),
        userName: ytText(channel["title"]),
        // 频道搜索结果不显示是否在直播
        liveStatus: false,
      ),
    );
  }
  return items;
}

/// 列表的下一页令牌
String? ytContinuationToken(dynamic response) {
  for (var item in ytFindAll(response, "continuationItemRenderer")) {
    var token = item is Map
        ? (item["continuationEndpoint"]?["continuationCommand"]?["token"])
        : null;
    if (token is String && token.isNotEmpty) {
      return token;
    }
  }
  return null;
}

/// updated_metadata 中的同时在线人数
int? parseYouTubeViewers(dynamic response) {
  var renderer = ytFindFirst(response, "videoViewCountRenderer");
  if (renderer is! Map) {
    return null;
  }
  var original = int.tryParse(renderer["originalViewCount"]?.toString() ?? "");
  if (original != null) {
    return original;
  }
  var text = ytText(renderer["unlabeledViewCountValue"]);
  if (text.isEmpty) {
    text = ytText(renderer["viewCount"]);
  }
  var count = ytParseCount(text);
  return count > 0 ? count : null;
}

/// 播放接口（player）响应中用到的信息
class YouTubePlayerInfo {
  /// playabilityStatus.status：OK、LIVE_STREAM_OFFLINE、UNPLAYABLE、LOGIN_REQUIRED…
  final String status;
  final String reason;
  final String videoId;
  final String channelId;
  final String title;
  final String author;
  final String description;
  final String thumbnail;

  /// 正在直播（microformat 的 isLiveNow 优先，没有时用 videoDetails.isLive）
  final bool isLive;
  final bool isUpcoming;

  /// 直播 HLS 主播放列表地址，只有 ANDROID_VR 客户端会返回
  final String hlsManifestUrl;

  /// 开播时间（预告时为计划开播时间）
  final DateTime? startTime;

  /// 分类（microformat.category）
  final String category;

  /// 原始的 streamingData，没有时为 null
  final dynamic streamingData;

  /// 时长（秒），直播中为 0
  final int lengthSeconds;
  final int viewCount;

  /// 发布时间（microformat.publishDate，只有网页端有）
  final DateTime? publishTime;

  /// 是否是直播（含已结束的直播）
  final bool isLiveContent;

  /// 直播刚结束、YouTube 还没处理完录制：此时只有分片格式和 HLS
  final bool isPostLiveDvr;

  YouTubePlayerInfo({
    required this.status,
    required this.reason,
    required this.videoId,
    required this.channelId,
    required this.title,
    required this.author,
    required this.description,
    required this.thumbnail,
    required this.isLive,
    required this.isUpcoming,
    required this.hlsManifestUrl,
    required this.startTime,
    required this.category,
    this.streamingData,
    this.lengthSeconds = 0,
    this.viewCount = 0,
    this.publishTime,
    this.isLiveContent = false,
    this.isPostLiveDvr = false,
  });

  bool get hasDetails => videoId.isNotEmpty && channelId.isNotEmpty;

  factory YouTubePlayerInfo.fromJson(dynamic json) {
    var playability = json?["playabilityStatus"] ?? {};
    var details = json?["videoDetails"] ?? {};
    var micro = json?["microformat"]?["playerMicroformatRenderer"] ?? {};
    var broadcast = micro["liveBroadcastDetails"];
    bool isLive;
    if (broadcast is Map && broadcast["isLiveNow"] is bool) {
      isLive = broadcast["isLiveNow"] == true;
    } else {
      isLive = details["isLive"] == true;
    }
    var upcoming = details["isUpcoming"] == true;
    DateTime? start = DateTime.tryParse(
      broadcast is Map ? broadcast["startTimestamp"]?.toString() ?? "" : "",
    );
    if (start == null) {
      var scheduled = int.tryParse(
        ytFindFirst(playability, "scheduledStartTime")?.toString() ?? "",
      );
      if (scheduled != null) {
        start = DateTime.fromMillisecondsSinceEpoch(scheduled * 1000);
      }
    }
    return YouTubePlayerInfo(
      status: playability["status"]?.toString() ?? "",
      reason: playability["reason"]?.toString() ?? "",
      videoId: details["videoId"]?.toString() ?? "",
      channelId:
          details["channelId"]?.toString() ??
          micro["externalChannelId"]?.toString() ??
          "",
      title: details["title"]?.toString() ?? ytText(micro["title"]),
      author:
          details["author"]?.toString() ??
          micro["ownerChannelName"]?.toString() ??
          "",
      description:
          details["shortDescription"]?.toString() ??
          ytText(micro["description"]),
      thumbnail: ytThumbnail(details["thumbnail"], target: 640).isNotEmpty
          ? ytThumbnail(details["thumbnail"], target: 640)
          : ytThumbnail(micro["thumbnail"], target: 640),
      isLive: isLive && !upcoming,
      isUpcoming: upcoming,
      hlsManifestUrl:
          json?["streamingData"]?["hlsManifestUrl"]?.toString() ?? "",
      startTime: start,
      category: micro["category"]?.toString() ?? "",
      streamingData: json?["streamingData"],
      lengthSeconds:
          int.tryParse(
            (details["lengthSeconds"] ?? micro["lengthSeconds"])?.toString() ??
                "",
          ) ??
          0,
      viewCount:
          int.tryParse(
            (details["viewCount"] ?? micro["viewCount"])?.toString() ?? "",
          ) ??
          0,
      publishTime: DateTime.tryParse(
        (micro["publishDate"] ?? micro["uploadDate"])?.toString() ?? "",
      ),
      isLiveContent: details["isLiveContent"] == true || broadcast is Map,
      isPostLiveDvr: details["isPostLiveDvr"] == true,
    );
  }
}

enum YouTubeLinkType {
  /// 频道 ID（UC…）
  channel,

  /// 视频 ID
  video,

  /// @handle（不含 @）
  handle,

  /// 需要 YouTube 解析的频道路径，如 /c/name、/user/name（值为完整链接）
  path,
}

/// 从用户输入识别出的 YouTube 链接
class YouTubeLink {
  final YouTubeLinkType type;
  final String value;
  const YouTubeLink(this.type, this.value);

  static final RegExp _channelId = RegExp(r'^UC[A-Za-z0-9_-]{22}$');
  static final RegExp _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  static bool isChannelId(String value) => _channelId.hasMatch(value);
  static bool isVideoId(String value) => _videoId.hasMatch(value);

  @override
  String toString() => "${type.name}:$value";

  @override
  bool operator ==(Object other) =>
      other is YouTubeLink && other.type == type && other.value == value;

  @override
  int get hashCode => Object.hash(type, value);

  /// 识别链接或输入；无法识别时返回 null
  ///
  /// 支持 watch?v=、youtu.be/、/live/、/shorts/、/embed/、/@handle（及其子页面）、
  /// /channel/UC…、/c/、/user/，以及裸的 UC… 频道 ID 与 @handle。
  static YouTubeLink? parse(String input) {
    var text = input.trim();
    if (text.isEmpty) {
      return null;
    }
    if (isChannelId(text)) {
      return YouTubeLink(YouTubeLinkType.channel, text);
    }
    if (text.startsWith('@')) {
      var handle = _handle(text.substring(1));
      return handle == null
          ? null
          : YouTubeLink(YouTubeLinkType.handle, handle);
    }
    if (!text.contains("://")) {
      var lower = text.toLowerCase();
      if (lower.startsWith("youtu.be/") ||
          RegExp(r'^([a-z0-9-]+\.)*youtube\.com(/|$)').hasMatch(lower)) {
        text = "https://$text";
      } else {
        return null;
      }
    }
    var uri = Uri.tryParse(text);
    if (uri == null) {
      return null;
    }
    var host = uri.host.toLowerCase();
    var segments = uri.pathSegments.where((e) => e.isNotEmpty).toList();
    if (host == "youtu.be") {
      if (segments.isNotEmpty && isVideoId(segments.first)) {
        return YouTubeLink(YouTubeLinkType.video, segments.first);
      }
      return null;
    }
    if (host != "youtube.com" &&
        !host.endsWith(".youtube.com") &&
        host != "youtube-nocookie.com" &&
        !host.endsWith(".youtube-nocookie.com")) {
      return null;
    }
    var v = uri.queryParameters["v"];
    if (segments.isEmpty) {
      return null;
    }
    var first = segments.first;
    switch (first.toLowerCase()) {
      case "watch":
      case "live_chat":
        if (v != null && isVideoId(v)) {
          return YouTubeLink(YouTubeLinkType.video, v);
        }
        return null;
      case "live":
      case "shorts":
      case "embed":
      case "v":
        if (segments.length > 1 && isVideoId(segments[1])) {
          return YouTubeLink(YouTubeLinkType.video, segments[1]);
        }
        return null;
      case "channel":
        if (segments.length > 1 && isChannelId(segments[1])) {
          return YouTubeLink(YouTubeLinkType.channel, segments[1]);
        }
        return null;
      case "c":
      case "user":
        if (segments.length > 1) {
          return YouTubeLink(
            YouTubeLinkType.path,
            "https://www.youtube.com/$first/${Uri.encodeComponent(segments[1])}",
          );
        }
        return null;
    }
    if (first.startsWith('@')) {
      var handle = _handle(first.substring(1));
      return handle == null
          ? null
          : YouTubeLink(YouTubeLinkType.handle, handle);
    }
    return null;
  }

  /// handle 可以是多种文字，排除空白和路径字符即可
  static String? _handle(String value) {
    var handle = value.trim();
    if (handle.isEmpty || RegExp(r'[\s/?#@]').hasMatch(handle)) {
      return null;
    }
    return handle;
  }
}

/// 从网页中取出 `marker` 之后的第一个 JSON 对象（如 ytInitialData）
dynamic extractYouTubeJson(String html, String marker) {
  var index = html.indexOf(marker);
  if (index < 0) {
    return null;
  }
  var start = html.indexOf('{', index + marker.length);
  if (start < 0) {
    return null;
  }
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < html.length; i++) {
    var c = html.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == 0x5c) {
        escaped = true;
      } else if (c == 0x22) {
        inString = false;
      }
      continue;
    }
    if (c == 0x22) {
      inString = true;
    } else if (c == 0x7b) {
      depth++;
    } else if (c == 0x7d) {
      depth--;
      if (depth == 0) {
        try {
          return json.decode(html.substring(start, i + 1));
        } catch (_) {
          return null;
        }
      }
    }
  }
  return null;
}
