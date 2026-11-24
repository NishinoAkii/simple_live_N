import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:simple_live_core/src/danmaku/huya_gifts.dart';
import 'package:simple_live_core/src/model/tars/huya_danmaku.dart';
import 'package:simple_live_core/src/model/tars/huya_gift.dart';
import 'package:simple_live_core/src/model/tars/huya_link_mic.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';

class HuyaDanmakuArgs {
  final int ayyuid;
  final int topSid;
  final int subSid;

  /// 主播 uid（读直播间的表情包用），没有时为 0
  final int presenterUid;

  /// 分类 id（读表情包用）
  final int gid;
  HuyaDanmakuArgs({
    required this.ayyuid,
    required this.topSid,
    required this.subSid,
    this.presenterUid = 0,
    this.gid = 0,
  });
  @override
  String toString() {
    return json.encode({
      "ayyuid": ayyuid,
      "topSid": topSid,
      "subSid": subSid,
      "presenterUid": presenterUid,
      "gid": gid,
    });
  }
}

class HuyaDanmaku implements LiveDanmaku {
  /// 读表情包用；为空时只有内置的默认表情
  final HuyaSite? site;
  HuyaDanmaku({this.site});

  @override
  int heartbeatTime = 60 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;
  String serverUrl = "wss://cdnws.api.huya.com";

  WebScoketUtils? webScoketUtils;

  final heartbeatData = base64.decode("ABQdAAwsNgBM");

  late HuyaDanmakuArgs danmakuArgs;

  /// 主播 uid，表情包按它缓存；没有时为 0（只有内置的默认表情）
  int _presenterUid = 0;

  /// 主播连麦（42008）多久没有再推送就算结束：连麦中大约每 20 秒重发一次
  Duration linkMicStaleAfter = const Duration(seconds: 65);

  /// PK 面板（1090009）多久没有再推送就算结束：PK 中大约每 10 秒推送一次
  Duration pkStaleAfter = const Duration(seconds: 35);

  /// 这次连接的连麦状态
  HuyaLinkMic? _linkMic;

  /// 换直播间或重新开始时清掉上一次连接的状态
  void _resetConnection(HuyaDanmakuArgs args) {
    danmakuArgs = args;
    _presenterUid = args.presenterUid;
    _linkMic?.reset();
    _linkMic = HuyaLinkMic(
      onState: (state) => onMessage?.call(state.toMessage()),
      presenterUid: args.presenterUid,
      yyId: args.ayyuid,
      channelId: args.topSid,
      linkStaleAfter: linkMicStaleAfter,
      pkStaleAfter: pkStaleAfter,
    );
  }

  /// 测试用：不连接服务器，只设置直播间（之后可以直接 [decodeMessage]）
  void debugSetArgs(HuyaDanmakuArgs args) => _resetConnection(args);

  @override
  Future start(dynamic args) async {
    _resetConnection(args as HuyaDanmakuArgs);
    // 直播间的道具列表（礼物名称、图片、价格）；没读到时礼物只有消息里的名称
    _giftsLoading = HuyaRoomGifts.load(_presenterUid);
    var site = this.site;
    if (site != null && danmakuArgs.presenterUid > 0) {
      unawaited(
        HuyaRoomEmotes.load(
          danmakuArgs.presenterUid,
          () => site.getEmoticonPackages(
            presenterUid: danmakuArgs.presenterUid,
            gid: danmakuArgs.gid,
          ),
        ),
      );
    }
    webScoketUtils = WebScoketUtils(
      url: serverUrl,
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        onReady?.call();
        joinRoom();
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

  void joinRoom() {
    var joinData = getJoinData(
      danmakuArgs.ayyuid,
      danmakuArgs.topSid,
      danmakuArgs.topSid,
    );
    webScoketUtils?.sendMessage(joinData);
    // 送礼广播（6501）只推给订阅了“chat:主播uid”消息组的连接；
    // 订阅后聊天会从两边各来一份，按消息 id 去重。
    // PK 面板（1090009）只在“live:主播uid”消息组里（新版推送，命令 22），
    // 这个组推来的只读连麦，别的不管
    if (_presenterUid > 0) {
      webScoketUtils?.sendMessage(
        getRegisterGroupData(_presenterUid, prefixes: kRoomGroups),
      );
    }
  }

  /// 进直播间时订阅的消息组
  static const List<String> kRoomGroups = ["live", "chat"];

  /// 订阅直播间的消息组（命令 16，WSRegisterGroupReq），
  /// [prefixes] 是组名的前缀，默认只有“chat”
  static List<int> getRegisterGroupData(
    int presenterUid, {
    List<String> prefixes = const ["chat"],
  }) {
    var req = HuyaRegisterGroupReq()
      ..vGroupId = [for (var prefix in prefixes) "$prefix:$presenterUid"];
    var wscmd = TarsOutputStream();
    wscmd.write(16, 0);
    wscmd.write(req.toByteArray(), 1);
    return wscmd.toUint8List();
  }

  List<int> getJoinData(int ayyuid, int tid, int sid) {
    try {
      var oos = TarsOutputStream();
      oos.write(ayyuid, 0);
      oos.write(true, 1);
      oos.write("", 2);
      oos.write("", 3);
      oos.write(tid, 4);
      oos.write(sid, 5);
      oos.write(0, 6);
      oos.write(0, 7);

      var wscmd = TarsOutputStream();
      wscmd.write(1, 0);
      wscmd.write(oos.toUint8List(), 1);
      return wscmd.toUint8List();
    } catch (e) {
      CoreLog.error(e);
      return [];
    }
  }

  @override
  void heartbeat() {
    webScoketUtils?.sendMessage(heartbeatData);
  }

  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    _linkMic?.reset();
    _linkMic = null;
    webScoketUtils?.close();
  }

  void decodeMessage(List<int> data) {
    try {
      var stream = TarsInputStream(Uint8List.fromList(data));
      var type = stream.read(0, 0, false);
      if (type == 22) {
        // 新版推送（WSPushMessage_V2），只来自“live:”消息组：只读连麦
        var push = HuyaWSPushMessageV2()
          ..readFrom(TarsInputStream(stream.readBytes(1, false)));
        for (var item in push.vMsgItem) {
          if (HuyaLinkMic.uris.contains(item.lUri)) {
            _linkMic?.handle(item.lUri, item.sMsg);
          }
        }
      } else if (type == 7) {
        var push = stream.readBytes(1, false);
        stream = TarsInputStream(push);
        HYPushMessage wSPushMessage = HYPushMessage();
        wSPushMessage.readFrom(stream);
        if (HuyaLinkMic.uris.contains(wSPushMessage.uri)) {
          _linkMic?.handle(wSPushMessage.uri, wSPushMessage.msg);
          return;
        }
        // “live:”消息组推来的聊天、礼物、在线人数不要（订阅前也收不到它们）
        if (const {1400, 8006, 6501}.contains(wSPushMessage.uri) &&
            _isLiveGroupPush(push)) {
          return;
        }
        if (wSPushMessage.uri == 1400) {
          if (_isRepeatedChat(wSPushMessage.msg)) {
            return;
          }
          HYMessage messageNotice = HYMessage();
          messageNotice.readFrom(
            TarsInputStream(Uint8List.fromList(wSPushMessage.msg)),
          );
          var uname = messageNotice.userInfo.nickName;
          var content = messageNotice.content;

          var color = messageNotice.bulletFormat.fontColor;
          var packages = HuyaRoomEmotes.of(_presenterUid);
          var sticker = huyaEmoteSticker(content, packages);

          onMessage?.call(
            LiveMessage(
              type: LiveMessageType.chat,
              color: color <= 0
                  ? LiveMessageColor.white
                  : LiveMessageColor.numberToColor(color),
              message: content,
              userName: uname,
              emotes: sticker == null
                  ? parseHuyaEmotes(content, packages: packages)
                  : null,
              sticker: sticker,
              badges: parseHuyaChatBadges(wSPushMessage.msg),
              // 发送人信息的 tag 0 是 lUid
              userId: liveUserId(messageNotice.userInfo.uid),
            ),
          );
        } else if (wSPushMessage.uri == 8006) {
          int online = 0;
          var s = TarsInputStream(Uint8List.fromList(wSPushMessage.msg));
          online = s.read(online, 0, false);
          onMessage?.call(
            LiveMessage(
              type: LiveMessageType.online,
              data: online,
              color: LiveMessageColor.white,
              message: "",
              userName: "",
            ),
          );
        } else if (wSPushMessage.uri == 6211) {
          // 贵宾数（虎牙自己的应用右上角头像旁边那个数），几秒推一次；
          // 结构：tag 0 主播 uid、tag 1 人数。2026-11-13 抓到的一条是
          // {0: 1199668582454, 1: 7991, 2: 0}，同时推的 6213 是前三位贵宾的头像
          var s = TarsInputStream(Uint8List.fromList(wSPushMessage.msg));
          if (s.skipToTag(1)) {
            var nobles = LiveRoomStats.count(s.read(0, 1, false));
            if (nobles != null) {
              onMessage?.call(LiveRoomStats(nobles: nobles).toMessage());
            }
          }
        } else if (wSPushMessage.uri == 6501) {
          var packet = HuyaSendItemPacket()
            ..readFrom(TarsInputStream(Uint8List.fromList(wSPushMessage.msg)));
          _queueGift(packet);
        }
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  /// 推送（WSPushMessage）来自“live:”消息组。tag 4 是组名，没有组时不带；
  /// 当作结构读，读到末尾也不会报错
  static bool _isLiveGroupPush(List<int> push) {
    try {
      return _readHuyaStruct(
        push,
        _HuyaPushGroup(),
      ).sGroupId.startsWith("live:");
    } catch (_) {
      return false;
    }
  }

  /// 最近的聊天消息 id，订阅消息组后同一条会来两次
  final LinkedHashSet<String> _recentChats = LinkedHashSet();

  bool _isRepeatedChat(List<int> msg) {
    String id;
    try {
      // HYMessage 的 tag 20 是消息 id
      id = TarsInputStream(Uint8List.fromList(msg)).read("", 20, false);
    } catch (_) {
      id = "";
    }
    if (id.isEmpty) {
      id = base64.encode(msg);
    }
    if (!_recentChats.add(id)) {
      return true;
    }
    while (_recentChats.length > 500) {
      _recentChats.remove(_recentChats.first);
    }
    return false;
  }

  /// 送礼消息按顺序发出：道具列表正在读时先等它（最多 5 秒）
  Future<void> _giftQueue = Future.value();
  Future<void>? _giftsLoading;
  final HuyaGiftCombos _giftCombos = HuyaGiftCombos();

  void _queueGift(HuyaSendItemPacket packet) {
    // 别的直播间的广播不要
    if (_presenterUid > 0 &&
        packet.lPresenterUid > 0 &&
        packet.lPresenterUid != _presenterUid) {
      return;
    }
    var time = DateTime.now();
    _giftQueue = _giftQueue
        .then((_) async {
          if (HuyaRoomGifts.of(_presenterUid) == null &&
              _giftsLoading != null) {
            await _giftsLoading!.timeout(
              const Duration(seconds: 5),
              onTimeout: () {},
            );
          }
          var gift = parseHuyaGift(
            packet,
            info: HuyaRoomGifts.of(_presenterUid)?[packet.iItemType],
            combos: _giftCombos,
            now: time,
          );
          if (gift != null) {
            onMessage?.call(gift.toMessage());
          }
        })
        .catchError((e) {
          CoreLog.error(e);
        });
  }
}

/// 推送（WSPushMessage）里的消息组名（tag 4）
class _HuyaPushGroup extends TarsStruct {
  String sGroupId = "";

  @override
  void readFrom(TarsInputStream input) {
    sGroupId = input.read(sGroupId, 4, false);
  }

  @override
  void writeTo(TarsOutputStream output) {}

  @override
  Object deepCopy() => _HuyaPushGroup()..sGroupId = sGroupId;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 虎牙直播间的连麦状态：四种推送整理成一份完整的 [LiveLinkMicState]，
/// 有变化时才通过 [onState] 发出。
///
/// - 42008 主播连麦（LinkMicStatusChangeNotice）：“连麦”，名单里去掉本直播间的主播。
///   实测连麦中 iLinkMicStatus 为 2、大约每 20 秒重发一次；结束时怎么推没抓到，
///   名单（去掉自己）为空、状态为 0 或者 [linkStaleAfter] 内没再推送都算结束
/// - 1090009 PK 面板（MultiPKPanelInfo）：“PK”，两队里除了本直播间主播的人。
///   实测 PK 中大约每 10 秒推一次（状态、比分、剩余时间实测都是 0），
///   [pkStaleAfter] 内没再推送算结束
/// - 2400001 多人视频（MultiVideoSyncNotice）：“多人连麦”，座位上的人，排队的人
/// - 1025601 语音房（LiveMeetingSyncNotice）：“语音连麦”，麦位上的人，排队的人
///
/// 同时有几种时按 PK、连麦、多人连麦、语音连麦的顺序取第一种。
/// 解析不了的推送只跳过，不抛异常
class HuyaLinkMic {
  static const int kLinkMicUri = 42008;
  static const int kPkUri = 1090009;
  static const int kMeetingUri = 1025601;
  static const int kMultiVideoUri = 2400001;
  static const Set<int> uris = {
    kLinkMicUri,
    kPkUri,
    kMeetingUri,
    kMultiVideoUri,
  };

  static const List<String> _priority = ["PK", "连麦", "多人连麦", "语音连麦"];

  final void Function(LiveLinkMicState state) onState;

  /// 本直播间主播的 uid、YY 号、频道号（topSid），用来从名单里去掉自己；没有为 0
  final int presenterUid;
  final int yyId;
  final int channelId;
  final Duration linkStaleAfter;
  final Duration pkStaleAfter;

  HuyaLinkMic({
    required this.onState,
    this.presenterUid = 0,
    this.yyId = 0,
    this.channelId = 0,
    this.linkStaleAfter = const Duration(seconds: 65),
    this.pkStaleAfter = const Duration(seconds: 35),
  });

  /// 正在进行的，按种类
  final Map<String, LiveLinkMicState> _active = {};
  final Map<String, Timer> _staleTimers = {};
  LiveLinkMicState _last = LiveLinkMicState.none;

  /// 现在的状态（最后一次发出的）
  LiveLinkMicState get state => _last;

  /// 处理一条推送；不是连麦的 uri 或解析不了时什么也不做
  void handle(int uri, List<int> msg) {
    String kind;
    LiveLinkMicState next;
    Duration? staleAfter;
    try {
      switch (uri) {
        case kLinkMicUri:
          kind = "连麦";
          next = _linkMicState(_readHuyaStruct(msg, HuyaLinkMicStatusNotice()));
          staleAfter = linkStaleAfter;
        case kPkUri:
          kind = "PK";
          next = _pkState(_readHuyaStruct(msg, HuyaMultiPKPanelInfo()));
          staleAfter = pkStaleAfter;
        case kMultiVideoUri:
          kind = "多人连麦";
          next = _multiVideoState(
            _readHuyaStruct(msg, HuyaMultiVideoSyncNotice()),
          );
        case kMeetingUri:
          kind = "语音连麦";
          next = _meetingState(
            _readHuyaStruct(msg, HuyaLiveMeetingSyncNotice()),
          );
        default:
          return;
      }
    } catch (e) {
      CoreLog.error(e);
      return;
    }
    _staleTimers.remove(kind)?.cancel();
    if (next.active) {
      _active[kind] = next;
      if (staleAfter != null) {
        _staleTimers[kind] = Timer(staleAfter, () {
          _staleTimers.remove(kind);
          _active.remove(kind);
          _emit();
        });
      }
    } else {
      _active.remove(kind);
    }
    _emit();
  }

  /// 清空（换连接、停止时），不发消息
  void reset() {
    for (var timer in _staleTimers.values) {
      timer.cancel();
    }
    _staleTimers.clear();
    _active.clear();
    _last = LiveLinkMicState.none;
  }

  void _emit() {
    LiveLinkMicState? current;
    for (var kind in _priority) {
      current = _active[kind];
      if (current != null) {
        break;
      }
    }
    // 都结束了：发一次空的（保留最后的种类）
    current ??= _last.active ? LiveLinkMicState(kind: _last.kind) : _last;
    if (current == _last) {
      return;
    }
    _last = current;
    onState(current);
  }

  bool _isSelf({int uid = 0, int yy = 0, int channel = 0}) =>
      (uid > 0 && (uid == presenterUid || uid == channelId)) ||
      (yy > 0 && yy == yyId) ||
      (channel > 0 && channel == channelId);

  static LiveLinkMicUser _user(String nick, String face, int uid, int room) {
    var name = nick.trim();
    if (name.isEmpty) {
      name = room > 0 ? "$room" : "$uid";
    }
    return LiveLinkMicUser(
      name: name,
      face: liveEmoteUrl(face),
      roomId: room > 0 ? "$room" : "",
    );
  }

  /// 按 uid 去重（uid 为 0 时不去重）
  static List<LiveLinkMicUser> _unique(Iterable<(int, LiveLinkMicUser)> users) {
    var seen = <int>{};
    return [
      for (var (uid, user) in users)
        if (uid <= 0 || seen.add(uid)) user,
    ];
  }

  LiveLinkMicState _linkMicState(HuyaLinkMicStatusNotice notice) {
    if (notice.iLinkMicStatus == 0) {
      return const LiveLinkMicState(kind: "连麦");
    }
    return LiveLinkMicState(
      kind: "连麦",
      linked: _unique([
        for (var p in notice.vLMPresenterInfos)
          if (!_isSelf(uid: p.lUid, yy: p.lYYId, channel: p.lChannelId))
            (p.lUid, _user(p.sNick, p.sAvatarUrl, p.lUid, p.iRoomId)),
      ]),
    );
  }

  LiveLinkMicState _pkState(HuyaMultiPKPanelInfo panel) {
    return LiveLinkMicState(
      kind: "PK",
      linked: _unique([
        for (var team in [panel.tLeftTeam, panel.tRightTeam])
          for (var m in team.vMemberInfo)
            if (!_isSelf(
              uid: m.lPid > 0 ? m.lPid : m.tLiveInfo.lUid,
              yy: m.tLiveInfo.lYYId,
              channel: m.tLiveInfo.lTid,
            ))
              (
                m.lPid,
                _user(m.sNickName, m.sAvatarUrl, m.lPid, m.tLiveInfo.iRoomId),
              ),
      ]),
    );
  }

  LiveLinkMicState _multiVideoState(HuyaMultiVideoSyncNotice notice) {
    var host = notice.tRoom.lUid;
    var seats = notice.vSeat.where((e) => e.lUid > 0).toList()
      ..sort((a, b) => a.iPos.compareTo(b.iPos));
    return LiveLinkMicState(
      kind: "多人连麦",
      linked: _unique([
        for (var s in seats)
          if (s.lUid != host && !_isSelf(uid: s.lUid))
            (s.lUid, _user(s.sNick, s.sAvatarUrl, s.lUid, 0)),
      ]),
      queue: _unique([
        for (var a in notice.vApply)
          if (a.lUid > 0 || a.sNick.trim().isNotEmpty)
            (a.lUid, _user(a.sNick, a.sAvatarUrl, a.lUid, 0)),
      ]),
    );
  }

  LiveLinkMicState _meetingState(HuyaLiveMeetingSyncNotice notice) {
    var host = notice.tStat.lPresenterUid;
    var seats = notice.vSeats.where((e) => e.lUid > 0).toList()
      ..sort((a, b) => a.iPos.compareTo(b.iPos));
    return LiveLinkMicState(
      kind: "语音连麦",
      linked: _unique([
        for (var s in seats)
          if (s.lUid != host && !_isSelf(uid: s.lUid))
            (s.lUid, _user(s.sNick, s.sAvatarUrl, s.lUid, 0)),
      ]),
      queue: _unique([
        for (var a in notice.tStat.vApplyList)
          if (a.lUid > 0 || a.sNick.trim().isNotEmpty)
            (a.lUid, _user(a.sNick, a.sAvatarUrl, a.lUid, 0)),
      ]),
    );
  }
}

/// 虎牙贵族等级的名称
const Map<int, String> kHuyaNobleNames = {
  1: "剑士",
  2: "骑士",
  3: "领主",
  4: "公爵",
  5: "君王",
  6: "帝皇",
  7: "超神帝皇",
};

/// 把一段 tars 字节当作结构读：前后补上结构的开始、结束标记，
/// 末尾省略了的字段读到结束标记就停（不会读到字节末尾报错）。解析不了时抛异常
T _readHuyaStruct<T extends TarsStruct>(List<int> bytes, T struct) {
  var wrapped = Uint8List(bytes.length + 2)
    ..[0] = TarsStructType.STRUCT_BEGIN.index
    ..setRange(1, bytes.length + 1, bytes)
    ..[bytes.length + 1] = TarsStructType.STRUCT_END.index;
  return TarsInputStream(wrapped).readTarsStruct(struct, 0, true) as T;
}

LiveBadge _huyaNobleBadge(int level, [String name = ""]) => LiveBadge(
  LiveBadgeKind.noble,
  name.trim().isNotEmpty ? name.trim() : kHuyaNobleNames[level] ?? "贵族",
  level: level,
);

String? _huyaBadgeIcon(String url) {
  var value = liveEmoteUrl(url);
  return value.isEmpty ? null : value;
}

/// 一个装饰对应的身份，不认识或没有内容时为 null；解析不了时抛异常
LiveBadge? _huyaDecorationBadge(HuyaDecorationInfo item) {
  var data = item.vData;
  switch (item.iAppId) {
    case 10400:
      // 粉丝牌（BadgeInfo）。后缀里有同号的图标装饰（iViewType 2，钻粉图标），
      // 内容不是 BadgeInfo，跳过
      if (item.iViewType != 0 || data.isEmpty) {
        return null;
      }
      var badge = _readHuyaStruct(data, HuyaBadgeInfo());
      var name = badge.sBadgeName.trim();
      if (name.isEmpty || badge.iBadgeLevel <= 0) {
        return null;
      }
      var owner = badge.sPresenterNickName.trim();
      return LiveBadge(
        LiveBadgeKind.medal,
        name,
        level: badge.iBadgeLevel,
        ownerName: owner.isEmpty ? null : owner,
        // 信仰牌不是某一个主播的
        ownerUid: badge.iBadgeType == 0 ? liveNumericId(badge.lBadgeId) : null,
      );
    case 10200:
      // 贵族（NobleBase）
      if (data.isEmpty) {
        return null;
      }
      var noble = _readHuyaStruct(data, HuyaNobleBase());
      var level = noble.iLevel > 0
          ? noble.iLevel
          : noble.tLevelInfo.iNobleLevel;
      return level > 0 ? _huyaNobleBadge(level, noble.sName) : null;
    case 10100:
      // 房管
      var icon = data.isEmpty
          ? null
          : _huyaBadgeIcon(
              _readHuyaStruct(data, HuyaUserTypeInfo()).sManagerDecorationUrl,
            );
      return LiveBadge(LiveBadgeKind.admin, "房管", icon: icon);
    case 10090:
      // 公会管理：公会的成员，可以协助公会的主播管理直播间
      var icon = data.isEmpty
          ? null
          : _huyaBadgeIcon(
              _readHuyaStruct(data, HuyaGuildAdminInfo()).sIconUrl,
            );
      return LiveBadge(LiveBadgeKind.admin, "公会管理", icon: icon);
    case 10900:
      // 主播本人，文字“【主播】”和颜色
      var color = data.isEmpty
          ? -1
          : _readHuyaStruct(data, HuyaTextDecoration()).iColor;
      return LiveBadge(
        LiveBadgeKind.broadcaster,
        "主播",
        color: color >= 0 ? color & 0xFFFFFF : null,
      );
    case 11200:
      // 消费等级
      if (data.isEmpty) {
        return null;
      }
      var level = _readHuyaStruct(data, HuyaConsumeLevelBadgeInfo()).iLevel;
      return level > 0
          ? LiveBadge(LiveBadgeKind.level, "等级", level: level)
          : null;
  }
  return null;
}

/// 虎牙聊天（MessageNotice，[notice] 是它的原始字节）里发言人的身份，
/// 按装饰的顺序（前缀在前）；没有时返回 null。
///
/// 装饰按 iAppId 认：10400 粉丝牌（牌子名、等级）、10200 贵族、10100 房管、
/// 10090 公会管理、10900 主播、11200 消费等级；聊天气泡等别的装饰不管。
/// 没有贵族装饰时用发送人的贵族等级（连麦的另一个直播间转来的消息只有发送人里有）。
/// 某个装饰解析不了只跳过它，整段解析不了时返回 null，都不影响消息本身
List<LiveBadge>? parseHuyaChatBadges(List<int> notice) {
  HuyaMessageNoticeBadges source;
  try {
    source = _readHuyaStruct(notice, HuyaMessageNoticeBadges());
  } catch (e) {
    CoreLog.error(e);
    return null;
  }
  var badges = <LiveBadge>[];
  var seen = <String>{};
  void add(LiveBadge? badge) {
    if (badge != null && seen.add("${badge.kind.name}:${badge.text}")) {
      badges.add(badge);
    }
  }

  for (var item in [...source.vDecorationPrefix, ...source.vDecorationSuffix]) {
    try {
      add(_huyaDecorationBadge(item));
    } catch (e) {
      CoreLog.error(e);
    }
  }
  if (!badges.any((e) => e.kind == LiveBadgeKind.noble)) {
    var sender = source.tUserInfo;
    var level = sender.tNobleLevelInfo.iNobleLevel > 0
        ? sender.tNobleLevelInfo.iNobleLevel
        : sender.iNobleLevel;
    if (level > 0) {
      add(_huyaNobleBadge(level));
    }
  }
  return badges.isEmpty ? null : badges;
}

/// 虎牙网页端内置的默认表情：名称 → 图片代码。
/// 聊天里是“[大笑]”，旧版是“/{dx”，图片为
/// https://a.msstatic.com/huya/main/emot_png/<代码>.png
const Map<String, String> kHuyaEmotes = {
  "大笑": "dx", "送花": "sh", "偷笑": "tx", "大哭": "dk", "嘿哈": "hh", //
  "666": "66", "感动": "gd", "疑问": "yw", "喜欢": "xh", "奸笑": "jx", //
  "赞": "zan", "可爱": "ka", "傲慢": "am", "开心": "kx", "拜拜": "88", //
  "害羞": "hx", "衰": "zs", "吐血": "pu", "嘴馋": "zc", "生气": "sq", //
  "扶额": "fe", "闭嘴": "bz", "枯萎": "kw", "嘘": "xu", "笑哭": "xk", //
  "流汗": "lh", "不看": "bk", "哈欠": "hq", "调皮": "tp", "鬼脸": "gl", //
  "戳脸": "cl", "大哥": "dg", "困": "kun", "拥抱": "yb", "猪头": "zt", //
  "骷髅": "kl", "臭臭": "cc", "心动": "xd", "刀": "dao",
};

final Set<String> _huyaEmoteCodes = kHuyaEmotes.values.toSet();

final Map<String, String> _huyaEmoteNames = {
  for (var e in kHuyaEmotes.entries) e.value: e.key,
};

/// 把旧版的表情转义“/{dx”换成名称“[大笑]”（导出、复制时好认）；
/// 不认识的转义和其它文字不变
String huyaReadableEmotes(String text) {
  if (!text.contains("/{")) {
    return text;
  }
  return text.replaceAllMapped(RegExp(r'/\{([A-Za-z0-9_]+)'), (m) {
    var name = _huyaEmoteNames[m.group(1)];
    return name == null ? m.group(0)! : "[$name]";
  });
}

/// 和网页端（@huyafed/emoticon-parser）一样：名称“[…]”，
/// 转义“/{”后面贪婪地取 ASCII 字母数字下划线，再按整个文字精确查表
/// （“/{dxabc”不是“/{dx”）
final RegExp _huyaEmotePattern = RegExp(
  r'\[([^\[\]]{1,12})\]|/\{([A-Za-z0-9_]+)',
);

/// 直播间的表情包解析后的表，键是消息里的文字：名称“[大笑]”和转义“/{dx”
class HuyaEmoticons {
  /// 小表情、大表情：消息里按文字认，显示在行内
  final Map<String, LiveEmote> inline;

  /// 梗表情（横长的文字图）、大表情：整条消息就是它时显示成一张大表情
  final Map<String, LiveEmote> stickers;
  const HuyaEmoticons({this.inline = const {}, this.stickers = const {}});

  bool get isEmpty => inline.isEmpty && stickers.isEmpty;
}

/// 网页端 Flexi/大表情用的“_3”版本：原始的 steam.png 是 404，steam_3.png 才有
String _huyaFlexiUrl(String url) {
  var value = liveEmoteUrl(url);
  if (value.isEmpty || value.endsWith("_3.png")) {
    return value;
  }
  var i = value.lastIndexOf(".png");
  return i < 0
      ? value
      : "${value.substring(0, i)}_3.png${value.substring(i + 4)}";
}

/// 表情包 → [HuyaEmoticons]。
///
/// 类型（表情自己的 iType，没有时用包的）：0 小表情用 sUrl（png）；
/// 2 梗表情、3 大表情用 sFlexiUrl 的“_3.png”；1 Frame 网页端不在聊天里解析，跳过。
/// 网页端支持 webp 时大表情会用 sExtraFlexiUrl 的“_3.webp”，但实测梗表情的
/// steam.webp、steam_3.webp 都是 404，这里只用 png。
/// 当前用户用不了的（贵族、等级表情）也收进来，别人发的消息里会有
HuyaEmoticons parseHuyaEmoticonPackages(
  List<HuyaExpressionEmoticonPackage> packages,
) {
  var inline = <String, LiveEmote>{};
  var stickers = <String, LiveEmote>{};
  for (var package in packages) {
    // 网页端跳过没有 id 的包
    if (package.sPackageId.isEmpty) {
      continue;
    }
    for (var item in package.vEmoticon) {
      var type = item.iType != 0 ? item.iType : package.iType;
      String url;
      if (type == 0) {
        url = liveEmoteUrl(item.sUrl.isNotEmpty ? item.sUrl : item.sExtraUrl);
      } else if (type == 2 || type == 3) {
        url = _huyaFlexiUrl(
          item.sFlexiUrl.isNotEmpty ? item.sFlexiUrl : item.sUrl,
        );
      } else {
        continue;
      }
      if (url.isEmpty) {
        continue;
      }
      for (var text in [item.sName, item.sEscape]) {
        if (text.isEmpty) {
          continue;
        }
        if (type != 2) {
          inline.putIfAbsent(
            text,
            () => LiveEmote(text: text, url: url, width: 1, height: 1),
          );
        }
        if (type != 0) {
          stickers.putIfAbsent(text, () => LiveEmote(text: text, url: url));
        }
      }
    }
  }
  return HuyaEmoticons(inline: inline, stickers: stickers);
}

/// 虎牙聊天里的表情，没有时返回 null。
///
/// [packages] 是直播间的表情包（[parseHuyaEmoticonPackages]），优先用它；
/// 没有的再查内置的默认表情 [kHuyaEmotes]
List<LiveEmote>? parseHuyaEmotes(String content, {HuyaEmoticons? packages}) {
  if (!content.contains('[') && !content.contains('/{')) {
    return null;
  }
  var result = <LiveEmote>[];
  var seen = <String>{};
  for (var m in _huyaEmotePattern.allMatches(content)) {
    var text = m.group(0)!;
    if (seen.contains(text)) {
      continue;
    }
    var emote = packages?.inline[text];
    if (emote == null) {
      var code = m.group(1) != null ? kHuyaEmotes[m.group(1)] : m.group(2);
      if (code != null && _huyaEmoteCodes.contains(code)) {
        emote = LiveEmote(
          text: text,
          url: "https://a.msstatic.com/huya/main/emot_png/$code.png",
          width: 1,
          height: 1,
        );
      }
    }
    if (emote != null) {
      seen.add(text);
      result.add(emote);
    }
  }
  return result.isEmpty ? null : result;
}

/// 整条消息就是一个梗表情或大表情时，返回这张大表情，否则为 null
LiveEmote? huyaEmoteSticker(String content, HuyaEmoticons? packages) {
  var emote = packages?.stickers[content.trim()];
  if (emote == null) {
    return null;
  }
  return LiveEmote(
    text: content,
    url: emote.url,
    staticUrl: emote.staticUrl,
    width: emote.width,
    height: emote.height,
  );
}

/// 虎牙直播间的表情包，按主播 uid 缓存：每个直播间读一次，1 小时后过期，
/// 重连时不重新请求；失败后 10 分钟内不再请求；最多缓存 [kMaxRooms] 个直播间。
/// 没读到时只有内置的默认表情
class HuyaRoomEmotes {
  HuyaRoomEmotes._();

  static const int kMaxRooms = 20;
  static const Duration _ttl = Duration(hours: 1);
  static const Duration _retryAfter = Duration(minutes: 10);

  static final LinkedHashMap<int, (DateTime, HuyaEmoticons)> _rooms =
      LinkedHashMap();
  static final Map<int, Future<void>> _loading = {};
  static final Map<int, DateTime> _failedAt = {};

  /// 读取直播间的表情包（已读到、正在读或刚失败过时不重复请求）
  static Future<void> load(
    int presenterUid,
    Future<List<HuyaExpressionEmoticonPackage>> Function() fetch,
  ) {
    if (presenterUid <= 0) {
      return Future.value();
    }
    var cached = _rooms[presenterUid];
    if (cached != null && DateTime.now().difference(cached.$1) < _ttl) {
      return Future.value();
    }
    var failed = _failedAt[presenterUid];
    if (failed != null && DateTime.now().difference(failed) < _retryAfter) {
      return Future.value();
    }
    return _loading[presenterUid] ??= () async {
      try {
        var emoticons = parseHuyaEmoticonPackages(await fetch());
        _rooms.remove(presenterUid);
        _rooms[presenterUid] = (DateTime.now(), emoticons);
        _failedAt.remove(presenterUid);
        while (_rooms.length > kMaxRooms) {
          _rooms.remove(_rooms.keys.first);
        }
      } catch (e) {
        CoreLog.error(e);
        _failedAt[presenterUid] = DateTime.now();
      } finally {
        _loading.remove(presenterUid);
      }
    }();
  }

  /// 直播间的表情包，还没读到时为 null
  static HuyaEmoticons? of(int presenterUid) => _rooms[presenterUid]?.$2;

  /// 测试用：直接设置直播间的表情包
  static void debugSet(int presenterUid, HuyaEmoticons emoticons) {
    _rooms[presenterUid] = (DateTime.now(), emoticons);
  }

  /// 测试用：清空缓存
  static void debugReset() {
    _rooms.clear();
    _loading.clear();
    _failedAt.clear();
  }
}
