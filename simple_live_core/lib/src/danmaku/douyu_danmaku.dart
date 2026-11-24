import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:simple_live_core/src/danmaku/douyu_aside.dart';

import '../common/binary_writer.dart';
import 'douyu_gifts.dart';
import 'douyu_link_mic.dart';

class DouyuDanmaku implements LiveDanmaku {
  final DouyuSite? site;
  DouyuDanmaku({this.site});

  @override
  int heartbeatTime = 45 * 1000;

  /// 房间号（真实房间号）
  String roomId = "";

  /// 连麦 PK 的状态（每个连接一份，start/stop 时清空）
  final DouyuLinkMic linkMic = DouyuLinkMic();

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;
  String serverUrl = "wss://danmuproxy.douyu.com:8506";

  WebScoketUtils? webScoketUtils;

  @override
  Future start(dynamic args) async {
    roomId = args.toString();
    linkMic.reset(roomId: roomId);
    // 房间的钻粉表情、热门梗；没读到时只有内置表情
    unawaited(DouyuRoomEmotes.load(roomId));
    // 当前网页里的内置表情、贵族和钻粉徽章（文件名带版本号，会变），12 小时读一次
    unawaited(DouyuAside.ensure(roomId));
    // 房间的礼物列表（图片、价格）；没读到时礼物只有名称
    _roomGiftsLoading = DouyuRoomGifts.load(roomId);
    webScoketUtils = WebScoketUtils(
      url: serverUrl,
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        onReady?.call();
        joinRoom(args);
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

  void joinRoom(roomId) {
    webScoketUtils?.sendMessage(
      serializeDouyu("type@=loginreq/roomid@=$roomId/"),
    );
    webScoketUtils?.sendMessage(
      serializeDouyu("type@=joingroup/rid@=$roomId/gid@=-9999/"),
    );
  }

  @override
  void heartbeat() {
    var data = serializeDouyu("type@=mrkl/");
    webScoketUtils?.sendMessage(data);
  }

  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    webScoketUtils?.close();
    linkMic.reset();
  }

  /// 一帧里可能有好几个包（实测热门房间大半的帧不止一个），逐个取出正文
  static List<String> splitDouyuPackets(List<int> data) {
    var result = <String>[];
    var bytes = data is Uint8List ? data : Uint8List.fromList(data);
    var view = ByteData.sublistView(bytes);
    var offset = 0;
    while (offset + 13 <= bytes.length) {
      var length = view.getInt32(offset, Endian.little);
      if (length < 9 || offset + 4 + length > bytes.length) {
        break;
      }
      try {
        result.add(
          utf8.decode(bytes.sublist(offset + 12, offset + 4 + length - 1)),
        );
      } catch (e) {
        CoreLog.error(e);
      }
      offset += 4 + length;
    }
    return result;
  }

  void decodeMessage(List<int> data) {
    for (var text in splitDouyuPackets(data)) {
      _decodePacket(text);
    }
  }

  /// 送礼和贵族消息按顺序处理：要等礼物列表或道具信息读到（最多 5 秒）
  Future<void> _giftQueue = Future.value();
  Future<void>? _roomGiftsLoading;
  final DouyuGiftCombos _giftCombos = DouyuGiftCombos();

  void _queueGift(Map msg) {
    var time = DateTime.now();
    _giftQueue = _giftQueue
        .then((_) async {
          LiveGiftMessage? gift;
          if (msg["type"] == "dgb") {
            gift = parseDouyuGift(
              msg,
              info: await _giftInfo(msg),
              combos: _giftCombos,
              now: time,
            );
          } else {
            // 贵族、钻粉的徽章：网页还在扫时等一会儿
            await DouyuAside.wait();
            gift =
                parseDouyuNoble(msg, roomId, now: time) ??
                parseDouyuDiamondFans(msg, roomId, now: time);
          }
          if (gift != null) {
            onMessage?.call(gift.toMessage());
          }
        })
        .catchError((e) {
          CoreLog.error(e);
        });
  }

  Future<DouyuGiftInfo?> _giftInfo(Map msg) async {
    const wait = Duration(seconds: 5);
    var pid = msg["pid"]?.toString() ?? "";
    // 背包道具（from=2）按道具 id 查，gfid 可能是 0
    if (msg["from"]?.toString() == "2" && pid.isNotEmpty) {
      return DouyuPropGifts.of(pid) ??
          await DouyuPropGifts.load(pid).timeout(wait, onTimeout: () => null);
    }
    if (DouyuRoomGifts.of(roomId) == null && _roomGiftsLoading != null) {
      await _roomGiftsLoading!.timeout(wait, onTimeout: () {});
    }
    return DouyuRoomGifts.of(roomId)?[msg["gfid"]?.toString()];
  }

  void _decodePacket(String result) {
    try {
      var jsonData = sttToJObject(result);
      if (jsonData is! Map) {
        return;
      }

      var type = jsonData["type"]?.toString();
      // 送礼、开通/续费贵族、开通/续费钻粉
      if (type == "dgb" ||
          type == "anbc" ||
          type == "rnewbc" ||
          type == "dfobc" ||
          type == "dfrbc") {
        _queueGift(jsonData);
        return;
      }
      // 连麦 PK：状态有变化时发一份完整的
      if (DouyuLinkMic.handles(type)) {
        linkMic.roomId = roomId;
        var state = linkMic.handle(jsonData, stt: sttToJObject);
        if (state != null) {
          onMessage?.call(state.toMessage());
        }
        return;
      }
      // 在线人数（斗鱼自己的应用右上角那个数）和贵宾数，各自几秒推一次：
      // type@=oun/un@=213/rid@=338281/
      // type@=oni/vn@=116/rid@=338281/list@=/un@=116/
      if (type == "oun" || type == "oni") {
        var stats = type == "oun"
            ? LiveRoomStats(viewers: LiveRoomStats.count(jsonData["un"]))
            : LiveRoomStats(nobles: LiveRoomStats.count(jsonData["vn"]));
        if (!stats.isEmpty) {
          onMessage?.call(stats.toMessage());
        }
        return;
      }
      //斗鱼好像不会返回人气值
      if (type == "chatmsg") {
        // 屏蔽阴间弹幕：斗鱼给匿名连接推送的机器人弹幕没有 dms 字段。
        // 抓了 10 个房间核对过，没有 dms 的消息（各房间 0～26%）：
        // uid 跨房间按时间递增（同一批账号轮流发），cid 的后缀都是 800a…/810a…
        // （带 dms 的正常弹幕是 8000…/0000…），hc 都为空，
        // 内容是“牛批又整这出”“网上直播什么比赛”这类通用句子，换个账号重复出现。
        // 所以不是丢了正常弹幕，照旧屏蔽
        if (jsonData["dms"] == null) {
          return;
        }
        var col = int.tryParse(jsonData["col"].toString()) ?? 0;
        var txt = jsonData["txt"].toString();
        var room = DouyuRoomEmotes.of(roomId);
        var sticker = douyuEmoteSticker(txt, room);
        var liveMsg = LiveMessage(
          type: LiveMessageType.chat,
          userName: jsonData["nn"].toString(),
          message: txt,
          color: getColor(col),
          emotes: sticker == null ? parseDouyuEmotes(txt, room: room) : null,
          sticker: sticker,
          badges: parseChatBadges(jsonData),
          userId: liveUserId(jsonData["uid"]),
        );

        onMessage?.call(liveMsg);
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  /// chatmsg 里发言人的身份，按贵族、主播/房管、钻粉、粉丝牌、等级排列，
  /// 一个也没有时返回 null：
  /// - nl：贵族等级，1 骑士、2 子爵、3 伯爵、4 公爵、5 国王、6 皇帝、7 游侠
  /// - rg：在这个房间的身份，4 房管、5 主播（1 是普通观众）
  /// - diaf：1 是钻粉
  /// - bnn、bl：戴着的粉丝牌的名称、等级；brid 是牌子所属的房间（没有主播名），没戴时是 0
  /// - level：用户等级
  static List<LiveBadge>? parseChatBadges(Map msg) {
    var badges = <LiveBadge>[];
    var nl = _toInt(msg["nl"]) ?? 0;
    if (nl > 0) {
      badges.add(
        LiveBadge(
          LiveBadgeKind.noble,
          kDouyuNobleLevels["$nl"] ?? "贵族",
          level: nl,
          icon: douyuNobleIconUrl("$nl"),
        ),
      );
    }
    var rg = _toInt(msg["rg"]);
    if (rg == 5) {
      badges.add(const LiveBadge(LiveBadgeKind.broadcaster, "主播"));
    } else if (rg == 4) {
      badges.add(const LiveBadge(LiveBadgeKind.admin, "房管"));
    }
    if (_toInt(msg["diaf"]) == 1) {
      badges.add(
        LiveBadge(LiveBadgeKind.vip, "钻粉", icon: douyuDiamondFansIcon().url),
      );
    }
    var medal = msg["bnn"] is String ? (msg["bnn"] as String).trim() : "";
    if (medal.isNotEmpty) {
      var bl = _toInt(msg["bl"]) ?? 0;
      badges.add(
        LiveBadge(
          LiveBadgeKind.medal,
          medal,
          level: bl > 0 ? bl : null,
          ownerRoomId: liveNumericId(msg["brid"]),
        ),
      );
    }
    var level = _toInt(msg["level"]) ?? 0;
    if (level > 0) {
      badges.add(LiveBadge(LiveBadgeKind.level, "等级", level: level));
    }
    return badges.isEmpty ? null : badges;
  }

  static int? _toInt(dynamic value) =>
      value is num ? value.toInt() : int.tryParse("${value ?? ""}".trim());

  List<int> serializeDouyu(String body) {
    try {
      const int clientSendToServer = 689;
      const int encrypted = 0;
      const int reserved = 0;

      List<int> buffer = utf8.encode(body);

      // 长度按 UTF-8 字节数计算，中文弹幕内容才不会被截断
      var writer = BinaryWriter([]);
      writer.writeInt(4 + 4 + buffer.length + 1, 4, endian: Endian.little);
      writer.writeInt(4 + 4 + buffer.length + 1, 4, endian: Endian.little);
      writer.writeInt(clientSendToServer, 2, endian: Endian.little);
      writer.writeInt(encrypted, 1, endian: Endian.little);
      writer.writeInt(reserved, 1, endian: Endian.little);
      writer.writeBytes(buffer);
      writer.writeInt(0, 1, endian: Endian.little);
      return writer.buffer;
    } catch (e) {
      CoreLog.error(e);
      return [];
    }
  }

  String? deserializeDouyu(List<int> buffer) {
    try {
      var reader = BinaryReader(Uint8List.fromList(buffer));
      int fullMsgLength = reader.readInt32(
        endian: Endian.little,
      ); //fullMsgLength
      reader.readInt32(endian: Endian.little); //fullMsgLength2
      int bodyLength = fullMsgLength - 9;
      reader.readShort(endian: Endian.little); //packType
      reader.readByte(endian: Endian.little); //encrypted
      reader.readByte(endian: Endian.little); //reserved

      var bytes = reader.readBytes(bodyLength);

      reader.readByte(endian: Endian.little); //固定为0
      return utf8.decode(bytes);
    } catch (e) {
      CoreLog.error(e);
      return null;
    }
  }

  //辣鸡STT
  dynamic sttToJObject(String str) {
    if (str.contains("//")) {
      var result = [];
      for (var field in str.split("//")) {
        if (field.isEmpty) {
          continue;
        }
        result.add(sttToJObject(field));
      }
      return result;
    }
    if (str.contains("@=")) {
      var result = {};
      for (var field in str.split('/')) {
        if (field.isEmpty) {
          continue;
        }
        var tokens = field.split("@=");
        var k = tokens[0];
        var v = unscapeSlashAt(tokens[1]);
        result[k] = sttToJObject(v);
      }
      return result;
    } else if (str.contains("@A=")) {
      return sttToJObject(unscapeSlashAt(str));
    } else {
      return unscapeSlashAt(str);
    }
  }

  String unscapeSlashAt(String str) {
    return str.replaceAll("@S", "/").replaceAll("@A", "@");
  }

  LiveMessageColor getColor(int type) {
    switch (type) {
      case 1:
        return LiveMessageColor(255, 0, 0);
      case 2:
        return LiveMessageColor(30, 135, 240);
      case 3:
        return LiveMessageColor(122, 200, 75);
      case 4:
        return LiveMessageColor(255, 127, 0);
      case 5:
        return LiveMessageColor(155, 57, 244);
      case 6:
        return LiveMessageColor(255, 105, 180);
      default:
        return LiveMessageColor.white;
    }
  }
}
