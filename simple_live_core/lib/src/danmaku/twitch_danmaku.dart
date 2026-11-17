import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:simple_live_core/src/common/online_poller.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/third_party_emotes.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:simple_live_core/src/danmaku/twitch_gifts.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/twitch_site.dart';
import 'package:simple_live_core/src/common/core_text.dart';

class TwitchDanmakuArgs {
  /// 频道 login（小写）
  final String channel;

  /// 频道的数字 id（读 7TV、BTTV、FFZ 的频道表情用），为空时从 IRC 的 room-id 读
  final String userId;
  TwitchDanmakuArgs({required this.channel, this.userId = ""});

  @override
  String toString() => channel;
}

/// 一行 IRC 消息
class TwitchIrcLine {
  final Map<String, String> tags;
  final String prefix;
  final String command;
  final List<String> params;
  final String trailing;
  TwitchIrcLine({
    required this.tags,
    required this.prefix,
    required this.command,
    required this.params,
    required this.trailing,
  });

  /// 发送者昵称（prefix 中 ! 之前的部分）
  String get nick {
    var i = prefix.indexOf('!');
    return i > 0 ? prefix.substring(0, i) : prefix;
  }

  static TwitchIrcLine parse(String line) {
    var rest = line;
    var tags = <String, String>{};
    if (rest.startsWith('@')) {
      var space = rest.indexOf(' ');
      if (space < 0) {
        space = rest.length;
      }
      for (var pair in rest.substring(1, space).split(';')) {
        var eq = pair.indexOf('=');
        if (eq < 0) {
          tags[pair] = '';
        } else {
          tags[pair.substring(0, eq)] = _unescape(pair.substring(eq + 1));
        }
      }
      rest = space < rest.length ? rest.substring(space + 1) : '';
    }
    var prefix = '';
    if (rest.startsWith(':')) {
      var space = rest.indexOf(' ');
      if (space < 0) {
        space = rest.length;
      }
      prefix = rest.substring(1, space);
      rest = space < rest.length ? rest.substring(space + 1) : '';
    }
    var trailing = '';
    var trailingIndex = rest.indexOf(' :');
    if (rest.startsWith(':')) {
      trailing = rest.substring(1);
      rest = '';
    } else if (trailingIndex >= 0) {
      trailing = rest.substring(trailingIndex + 2);
      rest = rest.substring(0, trailingIndex);
    }
    var parts = rest.split(' ').where((e) => e.isNotEmpty).toList();
    return TwitchIrcLine(
      tags: tags,
      prefix: prefix,
      command: parts.isEmpty ? '' : parts.first,
      params: parts.length > 1 ? parts.sublist(1) : [],
      trailing: trailing,
    );
  }

  static String _unescape(String value) {
    var buffer = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      var c = value[i];
      if (c == '\\' && i + 1 < value.length) {
        i++;
        switch (value[i]) {
          case 's':
            buffer.write(' ');
            break;
          case ':':
            buffer.write(';');
            break;
          case 'r':
            buffer.write('\r');
            break;
          case 'n':
            buffer.write('\n');
            break;
          default:
            buffer.write(value[i]);
        }
      } else {
        buffer.write(c);
      }
    }
    return buffer.toString();
  }
}

/// Twitch 聊天（IRC over WebSocket）
///
/// 只读，一律以匿名 justinfan 身份连接，登录与否都一样。
class TwitchDanmaku implements LiveDanmaku {
  final TwitchSite? site;

  /// [channelLookup] 按用户 id 读频道名称（共享聊天用），
  /// 默认用 [TwitchSite.getChannelById]；测试里换成不联网的
  TwitchDanmaku({
    this.site,
    Future<LiveLinkMicUser?> Function(String id)? channelLookup,
  }) {
    sharedChat = TwitchSharedChat(
      onState: (state) => onMessage?.call(state.toMessage()),
      lookup: channelLookup ?? site?.getChannelById,
    );
  }

  /// 共享聊天（连麦状态）
  late final TwitchSharedChat sharedChat;

  /// 观看人数：聊天连接里没有，每分钟读一次
  late final OnlinePoller _viewers = OnlinePoller(
    read: () async => site?.getViewers(danmakuArgs.channel),
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
  int heartbeatTime = 4 * 60 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;

  WebScoketUtils? webScoketUtils;
  late TwitchDanmakuArgs danmakuArgs;


  /// 订阅、礼物订阅与 Bits
  final TwitchGiftParser _gifts = TwitchGiftParser();

  /// 频道的数字 id（第三方表情按它查），没有时为空
  String _roomId = "";

  /// 知道了频道 id 后读频道的第三方表情（已缓存时不会重复请求）
  void _setRoomId(String? id) {
    if (id == null || id.isEmpty || id == _roomId) {
      return;
    }
    _roomId = id;
    unawaited(ThirdPartyEmotes.loadTwitchChannel(id));
  }

  /// 第三方表情（7TV、BTTV、FFZ）的表，频道表还没读到时只有全局表情
  Map<String, LiveEmote> get _emoteTable => ThirdPartyEmotes.twitch(_roomId);

  @override
  Future start(dynamic args) async {
    danmakuArgs = args as TwitchDanmakuArgs;
    sharedChat.reset();
    if (site != null) {
      _viewers.start();
    }
    unawaited(ThirdPartyEmotes.loadGlobal());
    _setRoomId(danmakuArgs.userId);
    webScoketUtils = WebScoketUtils(
      url: "wss://irc-ws.chat.twitch.tv:443",
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        if (e is String) {
          for (var line in e.split('\r\n')) {
            if (line.isNotEmpty) {
              handleLine(line);
            }
          }
        }
      },
      onReady: () {
        _login0();
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

  /// 连接建立后登录并加入频道
  void _login0() {
    var send = webScoketUtils?.sendMessage;
    send?.call("CAP REQ :twitch.tv/tags twitch.tv/commands");
    // 聊天只读，一律匿名连接；登录只用于画质和导入关注
    send?.call("PASS SCHMOOPIIE");
    send?.call("NICK justinfan${10000 + Random().nextInt(80000)}");
    send?.call("JOIN #${danmakuArgs.channel}");
  }

  /// 处理服务器发来的一行（测试里也直接调用）
  void handleLine(String raw) {
    var line = TwitchIrcLine.parse(raw);
    switch (line.command) {
      case "PING":
        webScoketUtils?.sendMessage("PONG :${line.trailing}");
        break;
      case "001":
        onReady?.call();
        break;
      case "ROOMSTATE":
        _setRoomId(line.tags["room-id"]);
        break;
      case "PRIVMSG":
        _handlePrivmsg(line);
        sharedChat.handle(line, ownRoomId: _roomId);
        break;
      case "USERNOTICE":
        var gift = _gifts.userNotice(line);
        if (gift != null) {
          onMessage?.call(giftToMessage(gift, line));
        }
        sharedChat.handle(line, ownRoomId: _roomId);
        break;
      case "NOTICE":
        _handleNotice(line);
        break;
      case "RECONNECT":
        // 服务器即将重启，主动重连
        webScoketUtils?.connect();
        break;
    }
  }

  void _handlePrivmsg(TwitchIrcLine line) {
    _setRoomId(line.tags["room-id"]);
    onMessage?.call(privmsgToMessage(line, _emoteTable));
    // Cheer：聊天照常显示，另外再出一条礼物
    var cheer = TwitchGiftParser.cheer(line);
    if (cheer != null) {
      onMessage?.call(giftToMessage(cheer, line));
    }
  }

  /// 礼物消息（订阅、礼物订阅、Bits）带上送礼人在这个直播间的身份
  static LiveMessage giftToMessage(LiveGiftMessage gift, TwitchIrcLine line) {
    var message = gift.withUserId(line.tags["user-id"]).toMessage();
    var badges = parseBadges(line.tags);
    if (badges == null) {
      return message;
    }
    return LiveMessage(
      type: message.type,
      userName: message.userName,
      message: message.message,
      data: message.data,
      color: message.color,
      face: message.face,
      emotes: message.emotes,
      sticker: message.sticker,
      history: message.history,
      badges: badges,
      userId: message.userId,
    );
  }

  /// badges、badge-info 标签 → 发言人身份，按 badges 里的顺序。
  ///
  /// badges 形如“moderator/1,subscriber/12”，斜杠后面是徽章的档位，
  /// 实际订阅月数在 badge-info（“subscriber/14”，创始订阅者是“founder/14”）。
  /// 只认主播、房管、VIP、订阅、Prime、Turbo、认证、官方，
  /// 活动、游戏、Bits、送订阅之类的纪念徽章不要。没有认得的时返回 null
  static List<LiveBadge>? parseBadges(Map<String, String> tags) {
    var badges = tags["badges"] ?? "";
    if (badges.isEmpty) {
      return null;
    }
    // badge-info 里竞猜（predictions）的值是选项名，可能带斜杠，按第一个斜杠分
    var info = <String, String>{};
    for (var item in (tags["badge-info"] ?? "").split(',')) {
      var slash = item.indexOf('/');
      if (slash > 0) {
        info.putIfAbsent(
          item.substring(0, slash),
          () => item.substring(slash + 1),
        );
      }
    }
    int? positive(int? n) => n != null && n > 0 ? n : null;
    int? number(String? value) => positive(int.tryParse(value?.trim() ?? ""));

    var result = <LiveBadge>[];
    void add(LiveBadgeKind kind, String text, {int? level}) {
      if (!result.any((e) => e.kind == kind && e.text == text)) {
        result.add(LiveBadge(kind, text, level: level));
      }
    }

    for (var item in badges.split(',')) {
      var slash = item.indexOf('/');
      var name = (slash >= 0 ? item.substring(0, slash) : item).trim();
      var version = slash >= 0 ? item.substring(slash + 1) : "";
      switch (name) {
        case "broadcaster":
          add(LiveBadgeKind.broadcaster, "主播");
        case "moderator":
        case "lead_moderator":
          add(LiveBadgeKind.admin, "房管");
        case "vip":
          add(LiveBadgeKind.vip, "VIP");
        case "subscriber":
          // 没有 badge-info 时按档位估（Tier 2、3 的档位是 2000、3000 加月数）
          add(
            LiveBadgeKind.subscriber,
            "订阅",
            level:
                number(info["subscriber"]) ??
                positive((number(version) ?? 0) % 1000),
          );
        case "founder":
          add(
            LiveBadgeKind.subscriber,
            "创始订阅",
            level: number(info["founder"]) ?? number(info["subscriber"]),
          );
        case "premium":
          add(LiveBadgeKind.title, "Prime");
        case "turbo":
          add(LiveBadgeKind.title, "Turbo");
        case "partner":
          add(LiveBadgeKind.title, "认证");
        case "staff":
        case "admin":
        case "global_mod":
          add(LiveBadgeKind.title, "官方");
      }
    }
    return result.isEmpty ? null : result;
  }

  /// PRIVMSG → 聊天消息。表情：IRC emotes 标签里的原生表情，
  /// 加上 [emoteTable]（第三方表情）里按整个词认出来的；
  /// 只有一个原生表情的消息（emote-only=1）是一张大表情
  static LiveMessage privmsgToMessage(
    TwitchIrcLine line,
    Map<String, LiveEmote>? emoteTable,
  ) {
    var message = line.trailing;
    // /me 消息：\u0001ACTION 内容\u0001
    if (message.startsWith('\u0001ACTION ') && message.endsWith('\u0001')) {
      message = message.substring(8, message.length - 1);
    }
    var displayName = line.tags["display-name"] ?? "";
    var native = parseTwitchEmotes(line.tags["emotes"], message);
    var sticker = line.tags["emote-only"] == "1"
        ? twitchEmoteOnlySticker(message, native)
        : null;
    var nameColor = _parseColor(line.tags["color"]);
    return LiveMessage(
      type: LiveMessageType.chat,
      userName: displayName.isNotEmpty ? displayName : line.nick,
      message: message,
      color: nameColor ?? LiveMessageColor.white,
      nameColor: nameColor,
      emotes: sticker != null
          ? null
          : matchWordEmotes(message, emoteTable, native: native),
      sticker: sticker,
      badges: parseBadges(line.tags),
      userId: liveUserId(line.tags["user-id"]),
    );
  }

  /// 表情图片地址（default 有动图时是动图）
  static String emoteUrl(String id) =>
      "https://static-cdn.jtvnw.net/emoticons/v2/$id/default/dark/2.0";

  /// 只有一个原生表情的消息（IRC 带 emote-only=1 标签）显示成一张大表情，
  /// 否则返回 null
  static LiveEmote? twitchEmoteOnlySticker(
    String message,
    List<LiveEmote>? native,
  ) {
    if (native == null || native.length != 1) {
      return null;
    }
    var emote = native.single;
    if (message.trim() != emote.text) {
      return null;
    }
    return LiveEmote(text: message, url: emote.url, width: 1, height: 1);
  }

  /// 解析 emotes 标签，如“25:0-4,12-16/1902:6-10”：表情 id 与它在消息中的位置
  /// （按 Unicode 字符计，/me 消息相对于去掉 ACTION 之后的内容）。
  /// 没有表情时返回 null
  static List<LiveEmote>? parseTwitchEmotes(String? tag, String message) {
    if (tag == null || tag.isEmpty) {
      return null;
    }
    var runes = message.runes.toList();
    var result = <LiveEmote>[];
    var seen = <String>{};
    for (var item in tag.split('/')) {
      var colon = item.indexOf(':');
      if (colon <= 0) {
        continue;
      }
      var id = item.substring(0, colon);
      for (var range in item.substring(colon + 1).split(',')) {
        var dash = range.indexOf('-');
        var start = int.tryParse(dash > 0 ? range.substring(0, dash) : "");
        var end = int.tryParse(dash > 0 ? range.substring(dash + 1) : "");
        if (start == null ||
            end == null ||
            start > end ||
            end >= runes.length) {
          continue;
        }
        var text = String.fromCharCodes(runes.sublist(start, end + 1));
        if (seen.add(text)) {
          result.add(LiveEmote(text: text, url: emoteUrl(id)));
        }
        // 同一个表情的其它位置文字相同
        break;
      }
    }
    return result.isEmpty ? null : result;
  }

  void _handleNotice(TwitchIrcLine line) {
    var text = line.trailing;
    if (text.isNotEmpty) {
      onClose?.call(text);
    }
  }

  static LiveMessageColor? _parseColor(String? hex) {
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
    webScoketUtils?.sendMessage("PING :tmi.twitch.tv");
  }

  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    sharedChat.reset();
    _viewers.stop();
    webScoketUtils?.close();
  }
}

/// Twitch 共享聊天（Shared Chat）：几个频道的聊天合在一起时，别的频道来的
/// 消息（PRIVMSG、USERNOTICE）带 source-room-id，和 room-id 不同。
/// IRC 不说这次共享有哪些频道、什么时候结束，只能按收到的消息推断：
/// 出现过别的频道的消息就算在共享，[idle] 内没有再出现就算结束。
///
/// 频道先用 id 当名称，[lookup] 读到名称后再发一次；每个 id 只读一次，
/// 不会每条消息都请求。解析不了的标签只跳过，不抛异常
class TwitchSharedChat {
  static const String kind = "共享聊天";

  /// 一次共享聊天最多 6 个频道；多出来的不认，免得异常的标签把名单撑大
  static const int kMaxChannels = 8;

  final void Function(LiveLinkMicState state) onState;

  /// 按用户 id 读频道（名称、头像、login），没有时一直用 id
  Future<LiveLinkMicUser?> Function(String id)? lookup;

  /// 多久没有别的频道的消息算结束
  Duration idle;

  TwitchSharedChat({
    required this.onState,
    this.lookup,
    this.idle = const Duration(minutes: 5),
  });

  static final RegExp _numericId = RegExp(r'^[0-9]{1,20}$');

  /// 这次共享里的别的频道，按出现的顺序
  final LinkedHashMap<String, LiveLinkMicUser> _channels = LinkedHashMap();

  /// 这次连接里读到的频道，共享结束后再出现时直接用
  final Map<String, LiveLinkMicUser> _resolved = {};
  final Set<String> _asked = {};
  DateTime _lastSeen = DateTime.fromMillisecondsSinceEpoch(0);

  /// 只在共享进行中才有
  Timer? _timer;

  /// [reset] 之后，之前的名称请求回来也不用
  int _generation = 0;
  LiveLinkMicState _last = LiveLinkMicState.none;

  /// 现在的状态（最后一次发出的）
  LiveLinkMicState get state => _last;

  /// 处理一行 PRIVMSG、USERNOTICE；[ownRoomId] 是本频道的 id，行里没有 room-id 时用
  void handle(TwitchIrcLine line, {String ownRoomId = ""}) {
    try {
      if (line.command != "PRIVMSG" && line.command != "USERNOTICE") {
        return;
      }
      var source = line.tags["source-room-id"]?.trim() ?? "";
      if (source.isEmpty || !_numericId.hasMatch(source)) {
        return;
      }
      var room = line.tags["room-id"]?.trim() ?? "";
      if (room.isEmpty) {
        room = ownRoomId;
      }
      if (room.isEmpty || source == room) {
        return;
      }
      _lastSeen = DateTime.now();
      _timer ??= Timer(idle, _check);
      if (_channels.containsKey(source) || _channels.length >= kMaxChannels) {
        return;
      }
      _channels[source] = _resolved[source] ?? LiveLinkMicUser(name: source);
      _emit();
      _resolve(source);
    } catch (e) {
      CoreLog.error(e);
    }
  }

  void _resolve(String id) {
    var lookup = this.lookup;
    if (lookup == null || !_asked.add(id)) {
      return;
    }
    var generation = _generation;
    Future<LiveLinkMicUser?>.sync(() => lookup(id))
        .then((user) {
          if (user == null || generation != _generation) {
            return;
          }
          var named = LiveLinkMicUser(
            name: user.name.trim().isEmpty ? id : user.name,
            face: user.face,
            roomId: user.roomId,
          );
          _resolved[id] = named;
          if (_channels.containsKey(id)) {
            _channels[id] = named;
            _emit();
          }
        })
        .catchError((Object e) {
          CoreLog.error(e);
        });
  }

  void _check() {
    _timer = null;
    if (_channels.isEmpty) {
      return;
    }
    var since = DateTime.now().difference(_lastSeen);
    if (since < idle) {
      _timer = Timer(idle - since, _check);
      return;
    }
    _channels.clear();
    _emit();
  }

  void _emit() {
    var next = _channels.isEmpty
        ? (_last.active ? const LiveLinkMicState(kind: kind) : _last)
        : LiveLinkMicState(
            kind: kind,
            linked: List.unmodifiable(_channels.values),
          );
    if (next == _last) {
      return;
    }
    _last = next;
    onState(next);
  }

  /// 清空（换连接、停止时），不发消息
  void reset() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _channels.clear();
    _resolved.clear();
    _asked.clear();
    _last = LiveLinkMicState.none;
  }
}
