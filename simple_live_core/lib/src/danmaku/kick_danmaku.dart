import 'dart:async';
import 'dart:convert';

import 'package:simple_live_core/src/common/online_poller.dart';
import 'package:simple_live_core/src/common/third_party_emotes.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:simple_live_core/src/danmaku/kick_gifts.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/kick_site.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/common/core_text.dart';

class KickDanmakuArgs {
  final int chatroomId;
  final int channelId;
  final String slug;

  /// 主播的 user_id（7TV 按它查频道表情；和 channel id 不一样，xqc 是 676 / 668），
  /// 没有时为 0
  final int userId;

  KickDanmakuArgs({
    required this.chatroomId,
    required this.channelId,
    required this.slug,
    this.userId = 0,
  });

  @override
  String toString() => "$slug/$chatroomId";
}

/// Kick 聊天（Pusher WebSocket）
///
/// 接收不需要登录。
class KickDanmaku implements LiveDanmaku {
  final KickSite? site;
  KickDanmaku({this.site});

  @override
  int heartbeatTime = 60 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;

  WebScoketUtils? webScoketUtils;
  late KickDanmakuArgs danmakuArgs;

  /// 观看人数：聊天连接里没有，每分钟读一次
  late final OnlinePoller _viewers = OnlinePoller(
    read: () async => site?.getViewers(danmakuArgs.slug),
    onOnline: (online) => onMessage?.call(
      LiveMessage(
        type: LiveMessageType.online,
        userName: "",
        message: "",
        color: LiveMessageColor.white,
        data: online,
      ),
    ),
  );

  @override
  Future start(dynamic args) async {
    danmakuArgs = args as KickDanmakuArgs;
    if (site != null) {
      _viewers.start();
    }
    if (danmakuArgs.chatroomId == 0) {
      onClose?.call("没拿到 Kick 聊天室信息".t);
      return;
    }
    // 7TV 表情（Kick 只有 7TV，没有 BTTV、FFZ）
    unawaited(ThirdPartyEmotes.loadGlobal(bttvFfz: false));
    unawaited(ThirdPartyEmotes.loadKickChannel(danmakuArgs.userId));
    var credentials = site != null
        ? await site!.getPusherCredentials(danmakuArgs.channelId)
        : (appKey: KickSite.kPusherAppKey, cluster: KickSite.kPusherCluster);
    webScoketUtils = WebScoketUtils(
      url:
          "wss://ws-${credentials.cluster}.pusher.com/app/${credentials.appKey}"
          "?protocol=7&client=js&version=8.4.0&flash=false",
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        if (e is String) {
          _handle(e);
        }
      },
      onHeartBeat: () {
        heartbeat();
      },
      onReconnect: () {
        onClose?.call("和弹幕服务器断开了，正在重连".t);
      },
      onClose: (e) {
        onClose?.call("连接弹幕服务器失败：{e}".tf({"e": e}));
      },
    );
    webScoketUtils?.connect();
  }

  void _send(String event, Map<String, dynamic> data) {
    webScoketUtils?.sendMessage(json.encode({"event": event, "data": data}));
  }

  /// 订阅、礼物订阅与 Kicks 礼物
  final KickGiftParser _gifts = KickGiftParser();

  String get _chatChannel => "chatrooms.${danmakuArgs.chatroomId}.v2";

  void _handle(String text) {
    Map<String, dynamic> frame;
    try {
      frame = json.decode(text);
    } catch (_) {
      return;
    }
    switch (frame["event"]) {
      case "pusher:connection_established":
        _send("pusher:subscribe", {"auth": "", "channel": _chatChannel});
        // 礼物订阅在 chatroom_{id}，Kicks 礼物在 channel_{id}（和网页端一样）
        _send("pusher:subscribe", {
          "auth": "",
          "channel": "chatroom_${danmakuArgs.chatroomId}",
        });
        if (danmakuArgs.channelId != 0) {
          _send("pusher:subscribe", {
            "auth": "",
            "channel": "channel_${danmakuArgs.channelId}",
          });
        }
        break;
      case "pusher_internal:subscription_succeeded":
        // 只按聊天频道算连接成功
        if (frame["channel"] == null || frame["channel"] == _chatChannel) {
          onReady?.call();
        }
        break;
      case "pusher:ping":
        _send("pusher:pong", {});
        break;
      case "pusher:error":
        var message = frame["data"] is Map ? frame["data"]["message"] : null;
        onClose?.call("Kick 聊天服务器出错{p}".tf({"p": message == null ? "" : "${"：".t}$message"}));
        break;
      case r"App\Events\ChatMessageEvent":
        _handleChat(frame["data"]);
        break;
      default:
        // 订阅、礼物订阅、Kicks 礼物
        var gift = _gifts.parse(
          frame["event"]?.toString() ?? "",
          frame["data"],
        );
        if (gift != null) {
          onMessage?.call(gift.toMessage());
        }
    }
  }

  /// 处理收到的一帧（测试时直接喂入抓到的数据）
  void handleFrame(String text) => _handle(text);

  void _handleChat(dynamic raw) {
    Map<String, dynamic> data;
    try {
      data = raw is String ? json.decode(raw) : Map<String, dynamic>.from(raw);
    } catch (_) {
      return;
    }
    var content = data["content"]?.toString() ?? "";
    if (content.isEmpty) {
      return;
    }
    var sender = data["sender"] is Map ? data["sender"] as Map : const {};
    var identity = sender["identity"] is Map ? sender["identity"] as Map : null;
    var text = replaceEmotes(content);
    var nameColor = _parseColor(identity?["color"]?.toString());
    onMessage?.call(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: sender["username"]?.toString() ?? "",
        message: text,
        color: nameColor ?? LiveMessageColor.white,
        nameColor: nameColor,
        emotes: matchKickEmotes(
          content,
          ThirdPartyEmotes.kick(danmakuArgs.userId),
        ),
        badges: parseBadges(identity),
        userId: liveUserId(sender["id"]),
      ),
    );
  }

  /// sender.identity 里的身份 → 发言人身份。
  ///
  /// badges 形如 [{type: "subscriber", text: "Subscriber", count: 12}]，
  /// 按数组顺序；订阅的 count 是月数。只认主播、房管、VIP、OG、订阅、认证、官方，
  /// 送订阅（sub_gifter）等不要。badges_v2 里用户选了显示（selected）的
  /// 等级（name 为 level，metadata.level，带图标）放在最后。没有认得的时返回 null
  static List<LiveBadge>? parseBadges(dynamic identity) {
    if (identity is! Map) {
      return null;
    }
    int? positive(dynamic value) {
      var n = value is num
          ? value.toInt()
          : int.tryParse(value?.toString().trim() ?? "");
      return n != null && n > 0 ? n : null;
    }

    var result = <LiveBadge>[];
    void add(LiveBadgeKind kind, String text, {int? level, String? icon}) {
      if (!result.any((e) => e.kind == kind && e.text == text)) {
        result.add(LiveBadge(kind, text, level: level, icon: icon));
      }
    }

    var badges = identity["badges"];
    for (var badge in badges is List ? badges : const []) {
      if (badge is! Map) {
        continue;
      }
      switch (badge["type"]?.toString().trim().toLowerCase()) {
        case "broadcaster":
          add(LiveBadgeKind.broadcaster, "主播");
        case "moderator":
          add(LiveBadgeKind.admin, "房管");
        case "vip":
          add(LiveBadgeKind.vip, "VIP");
        case "og":
          add(LiveBadgeKind.title, "OG");
        case "founder":
          add(
            LiveBadgeKind.subscriber,
            "创始订阅",
            level: positive(badge["count"]),
          );
        case "subscriber":
          add(LiveBadgeKind.subscriber, "订阅", level: positive(badge["count"]));
        case "verified":
          add(LiveBadgeKind.title, "认证");
        case "staff":
          add(LiveBadgeKind.title, "官方");
      }
    }
    var v2 = identity["badges_v2"];
    for (var badge in v2 is List ? v2 : const []) {
      if (badge is! Map ||
          badge["name"] != "level" ||
          badge["selected"] != true) {
        continue;
      }
      var meta = badge["metadata"];
      var level = positive(meta is Map ? meta["level"] : null);
      if (level == null) {
        continue;
      }
      var icon = liveEmoteUrl(badge["image_url"]);
      add(
        LiveBadgeKind.level,
        "等级",
        level: level,
        icon: icon.startsWith("https://") ? icon : null,
      );
    }
    return result.isEmpty ? null : result;
  }

  /// 消息里的表情：Kick 自己的 [emote:id:name]，加上 [table]（7TV）里
  /// 按整个词认出来的。[content] 是原始消息，表情名在 [replaceEmotes] 之后的文字里
  static List<LiveEmote>? matchKickEmotes(
    String content,
    Map<String, LiveEmote>? table,
  ) => matchWordEmotes(
    replaceEmotes(content),
    table,
    native: parseEmotes(content),
  );

  static final RegExp _emotePattern = RegExp(r'\[emote:(\d+):([^\]]*)\]');

  /// 将 [emote:37226:KEKW] 替换为表情名称。
  ///
  /// 表情名称和前后的字母数字（或另一个表情）之间补一个空格，
  /// 否则“abc[emote:1:KEKW][emote:1:KEKW]”会连成一个词，认不出表情
  static String replaceEmotes(String content) {
    var buffer = StringBuffer();
    var last = 0;
    var lastUnit = -1;
    void write(String text) {
      if (text.isNotEmpty) {
        buffer.write(text);
        lastUnit = text.codeUnitAt(text.length - 1);
      }
    }

    for (var m in _emotePattern.allMatches(content)) {
      write(content.substring(last, m.start));
      last = m.end;
      var name = m.group(2) ?? "";
      if (name.isEmpty) {
        continue;
      }
      if (_isWordUnit(lastUnit) && _isWordUnit(name.codeUnitAt(0))) {
        write(" ");
      }
      write(name);
      if (last < content.length &&
          _isWordUnit(content.codeUnitAt(last)) &&
          _isWordUnit(lastUnit)) {
        write(" ");
      }
    }
    write(content.substring(last));
    return buffer.toString();
  }

  static bool _isWordUnit(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5a) ||
      (c >= 0x61 && c <= 0x7a) ||
      c == 0x5f;

  /// [replaceEmotes] 之后的表情名称对应的图片，没有表情时返回 null
  static List<LiveEmote>? parseEmotes(String content) {
    var result = <LiveEmote>[];
    var seen = <String>{};
    for (var m in _emotePattern.allMatches(content)) {
      var name = m.group(2) ?? "";
      if (name.isNotEmpty && seen.add(name)) {
        result.add(
          LiveEmote(
            text: name,
            url: "https://files.kick.com/emotes/${m.group(1)}/fullsize",
          ),
        );
      }
    }
    return result.isEmpty ? null : result;
  }

  LiveMessageColor? _parseColor(String? hex) {
    if (hex == null || !hex.startsWith('#') || hex.length != 7) {
      return null;
    }
    var value = int.tryParse(hex.substring(1), radix: 16);
    if (value == null) {
      return null;
    }
    return LiveMessageColor(
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    );
  }

  @override
  void heartbeat() {
    _send("pusher:ping", {});
  }

  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    _viewers.stop();
    webScoketUtils?.close();
  }
}
