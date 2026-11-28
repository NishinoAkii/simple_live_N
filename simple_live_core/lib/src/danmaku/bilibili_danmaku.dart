import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli/brotli.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/bili_web.dart';
import 'package:simple_live_core/src/common/convert_helper.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';

import '../common/binary_writer.dart';
import 'bili_web_watch.dart';
import 'bilibili_gifts.dart';
import 'bilibili_link_mic.dart';
import 'bilibili_room_stats.dart';
import 'bilibili_voice_room.dart';

/// 认证包（op 7）的内容，字段和顺序与网页端（room-player）一致。
/// uid 必须是 Cookie 里的账号（DedeUserID），没登录时为 0
String biliAuthBody(BiliBiliDanmakuArgs args, String queueUuid) =>
    json.encode({
      "uid": args.uid,
      "roomid": args.roomId,
      "protover": 3,
      "buvid": args.buvid,
      "support_ack": true,
      "queue_uuid": queueUuid,
      "scene": "room",
      "platform": "web",
      "type": 2,
      "key": args.token,
    });

/// 认证包里的 queue_uuid：8 位随机小写字母和数字，和网页端的取值方式一样
String biliQueueUuid([Random? random]) {
  var r = random ?? Random.secure();
  const chars = "0123456789abcdefghijklmnopqrstuvwxyz";
  return List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
}

/// 消息带 p_is_ack: true 时要回的确认包（op 24）内容；不需要确认时返回 null
String? biliAckBody(Map obj) {
  if (obj["p_is_ack"] != true) {
    return null;
  }
  return json.encode({
    "msg_id": obj["msg_id"],
    "cmd": obj["cmd"],
    "p_msg_type": obj["p_msg_type"],
  });
}

class BiliBiliDanmakuArgs {
  final int roomId;
  final String token;
  final String buvid;
  final String serverHost;
  final int uid;
  final String cookie;

  /// 主播的 uid（榜单接口要用），没读到时为 0
  final int anchorUid;

  /// 直播间的父分区和分区（观看时长心跳要用），没读到时为 0
  final int parentAreaId;
  final int areaId;
  BiliBiliDanmakuArgs({
    required this.roomId,
    required this.token,
    required this.serverHost,
    required this.buvid,
    required this.uid,
    required this.cookie,
    this.anchorUid = 0,
    this.parentAreaId = 0,
    this.areaId = 0,
  });
  @override
  String toString() {
    return json.encode({
      "roomId": roomId,
      "token": token,
      "serverHost": serverHost,
      "buvid": buvid,
      "uid": uid,
      "cookie": cookie,
    });
  }
}

class BiliBiliDanmaku implements LiveDanmaku {
  /// 所属站点
  final BiliBiliSite? site;
  BiliBiliDanmaku({this.site});

  /// 上舰的 GUARD_BUY 和提示消息合成一行（分出开通、续费）
  final BiliGuardMerger _guards = BiliGuardMerger();

  /// 连麦、PK、连线的状态（每个连接一份，start/stop 时清空）
  final BiliLinkMic linkMic = BiliLinkMic();

  /// 网页端每 30 秒一次心跳（认证后马上先发一次）
  @override
  int heartbeatTime = 30 * 1000;

  /// 最近收到的要确认（p_msg_type 为 1）的消息 id：服务器没收到确认时会重发，重发的不再处理
  final List<String> _ackedIds = [];

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;

  //String serverUrl = "wss://broadcastlv.chat.bilibili.com/sub";

  WebScoketUtils? webScoketUtils;
  late BiliBiliDanmakuArgs danmakuArgs;

  /// 进直播间时读最近聊天（测试里换掉），默认用 [site] 的 [BiliBiliSite.getChatHistory]
  Future<List<LiveMessage>> Function(BiliBiliDanmakuArgs args)? historyLoader;

  /// 读最近聊天最多等多久，过了就不等，先连弹幕
  Duration historyTimeout = const Duration(seconds: 3);

  /// [start]、[stop] 一次加一：读最近聊天时离开了直播间，就不再连弹幕
  int _session = 0;

  /// 已经显示过最近聊天的直播间：刷新（同一个连接再 [start]）时不再显示，免得聊天区出现两遍
  int _historyRoom = 0;

  /// 进直播间时把平台记着的最近聊天标成历史消息交给 [onMessage]（只进聊天区，不上视频弹幕）。
  /// [session] 是哪一次 [start] 读的：读完时已经刷新或离开了，这次的不显示
  Future<void> loadHistory(BiliBiliDanmakuArgs args, {int? session}) async {
    var site = this.site;
    var load =
        historyLoader ??
        (site == null
            ? null
            : (BiliBiliDanmakuArgs a) => site.getChatHistory(a.roomId));
    if (load == null || args.roomId <= 0 || args.roomId == _historyRoom) {
      return;
    }
    List<LiveMessage> list;
    try {
      list = await load(args).timeout(historyTimeout);
    } catch (e) {
      CoreLog.error(e);
      return;
    }
    if (session != null && session != _session) {
      return;
    }
    _historyRoom = args.roomId;
    for (var message in list) {
      onMessage?.call(message.history ? message : message.asHistory());
    }
  }

  @override
  Future start(dynamic args) async {
    danmakuArgs = args as BiliBiliDanmakuArgs;
    var session = ++_session;
    linkMic.reset(roomId: "${args.roomId}");
    // 先读完最近的聊天再连弹幕，新消息排在它们后面
    await loadHistory(args, session: session);
    if (session != _session) {
      return;
    }
    webScoketUtils = WebScoketUtils(
      url: "wss://${args.serverHost}/sub",
      heartBeatTime: heartbeatTime,
      // 握手请求头与网页端一致（浏览器身份、Origin、Cookie），见 BiliWeb
      headers: BiliWeb.socketHeaders(cookie: args.cookie),
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        onReady?.call();
        joinRoom(danmakuArgs);
        // 和网页端一样，认证后立即发第一次心跳
        heartbeat();
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
    _startWatch(args);
  }

  /// 已登录时像网页端一样上报在看（进房记录、观看时长心跳），离开直播间时停止
  BiliWebWatch? _watch;

  void _startWatch(BiliBiliDanmakuArgs args) {
    _watch?.close();
    _watch = null;
    var site = this.site;
    if (site == null || site.csrf.isEmpty) {
      return;
    }
    var watch = BiliWebWatch(
      site,
      BiliHeartRoom(
        roomId: args.roomId,
        parentAreaId: args.parentAreaId,
        areaId: args.areaId,
        anchorUid: args.anchorUid,
      ),
    );
    _watch = watch;
    unawaited(watch.run());
  }

  /// 每次连接（包括重连）都重新认证，queue_uuid 每次新生成
  void joinRoom(BiliBiliDanmakuArgs args) {
    webScoketUtils?.sendMessage(
      encodeData(biliAuthBody(args, biliQueueUuid()), 7),
    );
  }

  /// 心跳包的内容和网页端一样是字符串 "[object Object]"
  @override
  void heartbeat() {
    webScoketUtils?.sendMessage(encodeData("[object Object]", 2));
  }

  /// 带 p_is_ack 的消息（醒目留言等）要像网页端一样立即回一个确认包（op 24）。
  /// 返回 false 表示这是已经处理过的重发消息
  bool _ack(Map obj) {
    var body = biliAckBody(obj);
    if (body == null) {
      return true;
    }
    webScoketUtils?.sendMessage(encodeData(body, 24));
    if (obj["p_msg_type"] != 1) {
      return true;
    }
    var id = obj["msg_id"]?.toString() ?? "";
    if (id.isEmpty) {
      return true;
    }
    if (_ackedIds.contains(id)) {
      return false;
    }
    _ackedIds.add(id);
    if (_ackedIds.length > 200) {
      _ackedIds.removeAt(0);
    }
    return true;
  }

  @override
  Future stop() async {
    _session++;
    onMessage = null;
    onClose = null;
    _watch?.close();
    _watch = null;
    webScoketUtils?.close();
    linkMic.reset();
  }

  List<int> encodeData(String msg, int action) {
    var data = utf8.encode(msg);
    //头部长度固定16
    var length = data.length + 16;
    var buffer = Uint8List(length);

    var writer = BinaryWriter([]);

    //数据包长度
    writer.writeInt(buffer.length, 4);
    //数据包头部长度,固定16
    writer.writeInt(16, 2);

    //协议版本：网页端发出的认证、心跳和确认包都是 1
    writer.writeInt(1, 2);

    //操作类型
    writer.writeInt(action, 4);

    //数据包头部长度,固定1

    writer.writeInt(1, 4);

    writer.writeBytes(data);

    return writer.buffer;
  }

  void decodeMessage(List<int> data) {
    try {
      //协议版本。0为JSON，可以直接解析；1为房间人气值,Body为4位Int32；2为压缩过Buffer，需要解压再处理
      int protocolVersion = readInt(data, 6, 2);
      //操作类型。3=心跳回应，内容为房间人气值；5=通知，弹幕、广播等全部信息；8=进房回应，空
      int operation = readInt(data, 8, 4);
      //内容
      var body = data.skip(16).toList();
      if (operation == 3) {
        var online = readInt(body, 0, 4);
        // 人气值已经停用，心跳回应里一般只是 1：不拿它盖掉房间信息里的数
        if (online <= 1) {
          return;
        }

        onMessage?.call(
          LiveMessage(
            type: LiveMessageType.online,
            data: online,
            color: LiveMessageColor.white,
            message: "",
            userName: "",
          ),
        );
      } else if (operation == 5) {
        if (protocolVersion == 2) {
          body = zlib.decode(body);
        } else if (protocolVersion == 3) {
          body = brotli.decode(body);
        }

        var text = utf8.decode(body, allowMalformed: true);

        var group = text.split(
          RegExp(r"[\x00-\x1f]+", unicode: true, multiLine: true),
        );
        for (var item in group.where(
          (x) => x.length > 2 && x.startsWith('{'),
        )) {
          parseMessage(item);
        }
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  void parseMessage(String jsonMessage) {
    try {
      var obj = json.decode(jsonMessage);
      if (obj is Map && !_ack(obj)) {
        return;
      }
      var cmd = obj["cmd"].toString();
      if (cmd.contains("DANMU_MSG")) {
        var liveMsg = parseBiliDanmuMsg(obj);
        if (liveMsg != null) {
          onMessage?.call(liveMsg);
        }
      } else if (cmd == "SUPER_CHAT_MESSAGE") {
        if (obj["data"] == null) {
          return;
        }
        LiveSuperChatMessage sc = LiveSuperChatMessage(
          id: obj["data"]["id"]?.toString(),
          backgroundBottomColor: obj["data"]["background_bottom_color"]
              .toString(),
          backgroundColor: obj["data"]["background_color"].toString(),
          endTime: DateTime.fromMillisecondsSinceEpoch(
            obj["data"]["end_time"] * 1000,
          ),
          face: "${obj["data"]["user_info"]["face"]}@200w.jpg",
          message: obj["data"]["message"].toString(),
          price: obj["data"]["price"],
          startTime: DateTime.fromMillisecondsSinceEpoch(
            obj["data"]["start_time"] * 1000,
          ),
          userName: obj["data"]["user_info"]["uname"].toString(),
          userId: liveUserId(obj["data"]["uid"]),
        );
        var liveMsg = LiveMessage(
          type: LiveMessageType.superChat,
          userName: "SUPER_CHAT_MESSAGE",
          message: "SUPER_CHAT_MESSAGE",
          color: LiveMessageColor.white,
          data: sc,
          userId: sc.userId,
        );
        onMessage?.call(liveMsg);
      } else if (cmd == "SEND_GIFT" ||
          cmd == "SEND_GIFT_V2" ||
          cmd == "COMBO_SEND" ||
          cmd == "GUARD_BUY" ||
          cmd == "USER_TOAST_MSG" ||
          cmd == "USER_TOAST_MSG_V2") {
        // 礼物，见 bilibili_gifts.dart；上舰的两条消息合成一行
        var gift = parseBiliGift(obj);
        if (gift != null &&
            (cmd == "GUARD_BUY" || cmd.startsWith("USER_TOAST"))) {
          gift = _guards.merge(gift, fromToast: cmd != "GUARD_BUY");
        }
        if (gift != null) {
          onMessage?.call(gift.toMessage());
        }
      } else if (BiliLinkMic.handles(cmd)) {
        // 连麦、PK、连线：状态有变化时发一份完整的
        var state = linkMic.handle(obj);
        if (state != null) {
          onMessage?.call(state.toMessage());
        }
      } else if (BiliVoiceRoom.handles(cmd)) {
        // 语聊房：谁在说话（语音转文字）
        var caption = BiliVoiceRoom.captionOf(obj);
        if (caption != null) {
          onMessage?.call(caption.toMessage());
        }
      } else if (cmd == "ONLINE_RANK_V2" || cmd == "ONLINE_RANK_V3") {
        // 高能榜（在线贡献榜）前几名有变化
        var update = parseBiliOnlineRankPush(obj);
        if (update != null) {
          onMessage?.call(update.toMessage());
        }
      } else if (BiliRoomStats.handles(cmd)) {
        // 多少人看过、点赞数
        var stats = BiliRoomStats.fromMessage(obj);
        if (stats != null) {
          onMessage?.call(stats.toMessage());
        }
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  /// 解析一条 DANMU_MSG，格式不对时返回 null
  ///
  /// 表情在 info[0] 里：
  /// - info[0][13]：表情包弹幕（整条是一张大表情）的 {url, width, height}，
  ///   没有时是字符串 "{}"；这时 info[1] 是表情的文字说明
  /// - info[0][15].extra（JSON 字符串）的 emots：文字里的小表情，
  ///   如 {"[比心]": {url, width, height, ...}}
  static LiveMessage? parseBiliDanmuMsg(dynamic obj) {
    var info = obj["info"];
    if (info is! List || info.length < 3) {
      return null;
    }
    var user = info[2];
    if (user is! List || user.length < 2) {
      return null;
    }
    var message = info[1].toString();
    var meta = info[0] is List ? info[0] as List : const [];
    var color = meta.length > 3 ? asT<int?>(meta[3]) ?? 0 : 0;
    LiveEmote? sticker;
    if (meta.length > 13 && meta[13] is Map) {
      var big = meta[13] as Map;
      var url = liveEmoteUrl(big["url"]);
      if (url.isNotEmpty) {
        sticker = LiveEmote(
          text: message,
          url: url,
          width: _size(big["width"]),
          height: _size(big["height"]),
        );
      }
    }
    List<LiveEmote>? emotes;
    if (sticker == null && meta.length > 15 && meta[15] is Map) {
      var extra = meta[15]["extra"];
      if (extra is String && extra.contains('"emots"')) {
        try {
          var emots = json.decode(extra)["emots"];
          if (emots is Map) {
            emotes = [
              for (var entry in emots.entries)
                if (entry.value is Map &&
                    liveEmoteUrl(entry.value["url"]).isNotEmpty)
                  LiveEmote(
                    text: entry.key.toString(),
                    url: liveEmoteUrl(entry.value["url"]),
                    width: _size(entry.value["width"]),
                    height: _size(entry.value["height"]),
                  ),
            ];
            if (emotes.isEmpty) {
              emotes = null;
            }
          }
        } catch (e) {
          CoreLog.error(e);
        }
      }
    }
    return LiveMessage(
      type: LiveMessageType.chat,
      userName: user[1].toString(),
      message: message,
      color: color == 0
          ? LiveMessageColor.white
          : LiveMessageColor.numberToColor(color),
      emotes: emotes,
      sticker: sticker,
      badges: parseBiliDanmuBadges(info),
      // info[2][0] 是 uid；没登录时是 0（名字也打了码），这时只能按名字认人
      userId: liveUserId(user[0]),
    );
  }

  /// DANMU_MSG 里发言人的身份（下标同 blivedm 的 DanmakuMessage），
  /// 按大航海、房管、粉丝牌、等级、头衔排列，一个也没有时返回 null：
  /// - info[7]：大航海，1 总督、2 提督、3 舰长
  /// - info[2][2]：房管时为 1
  /// - info[3]：戴着的粉丝牌 [等级, 名称, 主播名, 房间号, 颜色, …]，没戴时是 []。
  ///   第 12 项是牌子主播的 uid，没有时用 info[0][15].user.medal.ruid（同一个牌子）；
  ///   主播名可能是空的
  /// - info[4][0]：用户等级（UL）
  /// - info[16][0]：荣耀等级
  /// - info[5]：头衔 [旧 id, id]，如 "title-111-1"，没有时是空字符串
  ///
  /// 数字可能是字符串，数组可能缺项，缺的就不算
  static List<LiveBadge>? parseBiliDanmuBadges(dynamic info) {
    if (info is! List) {
      return null;
    }
    var badges = <LiveBadge>[];
    var guard = _toInt(_at(info, 7)) ?? 0;
    var guardName = const {1: "总督", 2: "提督", 3: "舰长"}[guard];
    if (guardName != null) {
      badges.add(
        LiveBadge(
          LiveBadgeKind.guard,
          guardName,
          level: guard,
          icon: biliGuardIcon(guard, guardName)?.url,
        ),
      );
    }
    if (_toInt(_at(_at(info, 2), 2)) == 1) {
      badges.add(const LiveBadge(LiveBadgeKind.admin, "房管"));
    }
    var medal = _at(info, 3);
    var medalName = _text(_at(medal, 1));
    if (medalName.isNotEmpty) {
      var level = _toInt(_at(medal, 0)) ?? 0;
      var color = (_toInt(_at(medal, 4)) ?? 0) & 0xffffff;
      var ownerName = _text(_at(medal, 2));
      badges.add(
        LiveBadge(
          LiveBadgeKind.medal,
          medalName,
          level: level > 0 ? level : null,
          color: color != 0 ? color : null,
          ownerName: ownerName.isEmpty ? null : ownerName,
          ownerRoomId: liveNumericId(_at(medal, 3)),
          ownerUid:
              liveNumericId(_at(medal, 12)) ?? liveNumericId(_medalRuid(info)),
        ),
      );
    }
    var userLevel = _toInt(_at(_at(info, 4), 0)) ?? 0;
    if (userLevel > 0) {
      badges.add(LiveBadge(LiveBadgeKind.level, "UL", level: userLevel));
    }
    var wealth = _at(info, 16);
    var wealthLevel = _toInt(wealth is List ? _at(wealth, 0) : wealth) ?? 0;
    if (wealthLevel > 0) {
      badges.add(LiveBadge(LiveBadgeKind.level, "荣耀", level: wealthLevel));
    }
    var titles = _at(info, 5);
    var title = _text(_at(titles, 1));
    if (title.isEmpty) {
      title = _text(_at(titles, 0));
    }
    if (title.isNotEmpty) {
      badges.add(LiveBadge(LiveBadgeKind.title, title));
    }
    return badges.isEmpty ? null : badges;
  }

  /// 新格式里戴着的牌子的主播 uid（info[0][15].user.medal.ruid），没有时为 null
  static dynamic _medalRuid(List info) {
    var meta = _at(_at(info, 0), 15);
    var user = meta is Map ? meta["user"] : null;
    var medal = user is Map ? user["medal"] : null;
    return medal is Map ? medal["ruid"] : null;
  }

  /// [list] 的第 [index] 项，不是数组或没有这一项时为 null
  static dynamic _at(dynamic list, int index) =>
      list is List && index >= 0 && index < list.length ? list[index] : null;

  /// 数字或数字字符串，别的都是 null
  static int? _toInt(dynamic value) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  /// 字符串或数字的文字，别的（null、数组、对象）都是空字符串
  static String _text(dynamic value) =>
      value is String || value is num ? value.toString().trim() : "";

  static int _size(dynamic value) => value is num ? value.toInt() : 0;

  int readInt(List<int> buffer, int start, int len) {
    var bytes = Uint8List.fromList(
      buffer.getRange(start, start + len).toList(),
    );
    var byteBuffer = bytes.buffer;
    var data = ByteData.view(byteBuffer);
    var result = 0;

    if (len == 1) {
      result = data.getUint8(0);
    }
    if (len == 2) {
      result = data.getInt16(0, Endian.big);
    }
    if (len == 4) {
      result = data.getInt32(0, Endian.big);
    }
    if (len == 8) {
      result = data.getInt64(0, Endian.big);
    }

    return result;
  }
}
