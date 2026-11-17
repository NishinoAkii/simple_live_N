import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:fixnum/fixnum.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart' as core;
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:simple_live_core/src/scripts/douyin_sign.dart';

import 'douyin_gifts.dart';
import 'proto/douyin.pb.dart';

class DouyinDanmakuArgs {
  final String webRid;
  final String roomId;
  final String userId;
  final String cookie;

  /// 主播的用户 id（owner.id_str），连麦名单里用它去掉本直播间的主播；
  /// 没有时从弹幕里认（见 [DouyinLinkMic]）
  final String anchorId;

  /// 主播的 sec_uid（在线观众榜要用），没有时为空
  final String secAnchorId;
  DouyinDanmakuArgs({
    required this.webRid,
    required this.roomId,
    required this.userId,
    required this.cookie,
    this.anchorId = "",
    this.secAnchorId = "",
  });
  @override
  String toString() {
    return json.encode({
      "webRid": webRid,
      "roomId": roomId,
      "userId": userId,
      "cookie": cookie,
      if (anchorId.isNotEmpty) "anchorId": anchorId,
    });
  }
}

class DouyinDanmaku implements LiveDanmaku {
  @override
  int heartbeatTime = 10 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;
  String serverUrl = "wss://webcast3-ws-web-lq.douyin.com/webcast/im/push/v2/";
  late DouyinDanmakuArgs danmakuArgs;
  WebScoketUtils? webScoketUtils;

  /// 连麦和 PK 的状态，有变化时发一条 [LiveMessageType.linkMic]；
  /// 每次 start、stop 时清空
  late final DouyinLinkMic linkMic = DouyinLinkMic(
    onChange: (state) => onMessage?.call(state.toMessage()),
  );

  @override
  Future start(dynamic args) async {
    danmakuArgs = args as DouyinDanmakuArgs;
    linkMic.reset(roomId: danmakuArgs.roomId, anchorId: danmakuArgs.anchorId);
    // 表情图片的列表，每次运行读取一次，读好之前表情显示为文字
    unawaited(DouyinEmotes.load());
    var ts = DateTime.now().millisecondsSinceEpoch;
    var uri = Uri.parse(serverUrl).replace(
      scheme: "wss",
      queryParameters: {
        "app_name": "douyin_web",
        "version_code": "180800",
        "webcast_sdk_version": "1.3.0",
        "update_version_code": "1.3.0",
        "compress": "gzip",
        // "internal_ext":
        //     "internal_src:dim|wss_push_room_id:${danmakuArgs.roomId}|wss_push_did:${danmakuArgs.userId}|dim_log_id:20230626152702E8F63662383A350588E1|fetch_time:1687764422114|seq:1|wss_info:0-1687764422114-0-0|wrds_kvs:WebcastRoomRankMessage-1687764036509597990_InputPanelComponentSyncData-1687736682345173033_WebcastRoomStatsMessage-1687764414427812578",
        "cursor": "h-1_t-${ts}_r-1_d-1_u-1",
        "host": "https://live.douyin.com",
        "aid": "6383",
        "live_id": "1",
        "did_rule": "3",
        "debug": "false",
        "maxCacheMessageNumber": "20",
        "endpoint": "live_pc",
        "support_wrds": "1",
        "im_path": "/webcast/im/fetch/",
        "user_unique_id": danmakuArgs.userId,
        "device_platform": "web",
        "cookie_enabled": "true",
        "screen_width": "1920",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Mozilla",
        "browser_version": DouyinSite.kDefaultUserAgent.replaceAll(
          "Mozilla/",
          "",
        ),
        "browser_online": "true",
        "tz_name": "Asia/Shanghai",
        "identity": "audience",
        "room_id": danmakuArgs.roomId,
        "heartbeatDuration": "0",
        //"signature": "00000000"
      },
    );

    var sign = DouyinSign.getSignature(danmakuArgs.roomId, danmakuArgs.userId);

    var url = "$uri&signature=$sign";
    var backupUrl = url.replaceAll("webcast3-ws-web-lq", "webcast5-ws-web-lf");
    print(url);
    webScoketUtils = WebScoketUtils(
      url: url,
      backupUrl: backupUrl,
      headers: {
        "User-Agnet": DouyinSite.kDefaultUserAgent,
        "Cookie": danmakuArgs.cookie,
        "Origin": "https://live.douyin.com",
      },
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

  @override
  void heartbeat() {
    var obj = PushFrame();
    obj.payloadType = 'hb';
    webScoketUtils?.sendMessage(obj.writeToBuffer());
  }

  void decodeMessage(args) {
    // CoreLog.i(args.toString());

    var wssPackage = PushFrame.fromBuffer(args);

    var logId = wssPackage.logId;
    var decompressed = gzip.decode(wssPackage.payload);
    var payloadPackage = Response.fromBuffer(decompressed);
    if (payloadPackage.needAck) {
      sendAck(logId, payloadPackage.internalExt);
      //return;
    }
    for (var msg in payloadPackage.messagesList) {
      if (msg.method == 'WebcastChatMessage') {
        unPackWebcastChatMessage(msg.payload);
      } else if (msg.method == 'WebcastRoomUserSeqMessage') {
        unPackWebcastRoomUserSeqMessage(msg.payload);
      } else if (msg.method == 'WebcastGiftMessage') {
        unPackWebcastGiftMessage(msg.payload);
      } else if (msg.method == 'WebcastLikeMessage') {
        unPackWebcastLikeMessage(msg.payload);
      } else {
        // 连麦、PK；解析失败只记日志
        linkMic.handle(msg.method, msg.payload);
      }
    }
  }

  /// 送礼，见 douyin_gifts.dart；解析失败只记日志，不影响同一帧里的其他消息
  void unPackWebcastGiftMessage(List<int> payload) {
    LiveGiftMessage? gift;
    try {
      gift = parseDouyinGift(GiftMessage.fromBuffer(payload));
    } catch (e) {
      CoreLog.error(e);
    }
    if (gift != null) {
      onMessage?.call(gift.toMessage());
    }
  }

  /// 抖音用户的 ID：id 为 0 时用 idStr（连麦解析里也这样取），都没有时为 null
  static String? douyinUserId(User user) =>
      liveUserId(user.id != 0 ? user.id.toString() : user.idStr);

  void unPackWebcastChatMessage(List<int> payload) {
    var chatMessage = ChatMessage.fromBuffer(payload);
    onMessage?.call(
      LiveMessage(
        type: LiveMessageType.chat,
        color: LiveMessageColor.white,
        //暂不知道具体怎么转换颜色
        // color: chatMessage.common.fullScreenTextColor.
        //     ? LiveMessageColor.white
        //     : LiveMessageColor.numberToColor(color),
        message: chatMessage.content,
        userName: chatMessage.user.nickName,
        emotes: DouyinEmotes.parse(chatMessage.content),
        badges: parseDouyinChatBadges(chatMessage.user),
        userId: douyinUserId(chatMessage.user),
      ),
    );
  }

  /// 在线人数和累计看过的人数。2026-11-13 在真的直播间里看到的一条：
  /// total=33039（网页上的“3万在线观众”，和房间信息里的在线人数是同一个数）、
  /// totalUser=570304（totalPvForAnchor 是它的写法“57.0万”）。
  /// 原来把 totalUser 当成了在线人数
  void unPackWebcastRoomUserSeqMessage(List<int> payload) {
    var roomUserSeqMessage = RoomUserSeqMessage.fromBuffer(payload);
    var online = roomUserSeqMessage.total.toInt();
    if (online > 0) {
      onMessage?.call(
        LiveMessage(
          type: LiveMessageType.online,
          data: online,
          color: LiveMessageColor.white,
          message: "",
          userName: "",
        ),
      );
    }
    var watched = roomUserSeqMessage.totalUser.toInt();
    if (watched > 0) {
      onMessage?.call(LiveRoomStats(watched: watched).toMessage());
    }
    // 在线观众榜的前三名
    var top = douyinSeqRankTop(roomUserSeqMessage);
    if (top != null) {
      onMessage?.call(top.toMessage());
    }
  }

  /// RoomUserSeqMessage 里的在线观众榜前几名（ranksList），没有时返回 null。
  /// 隐身的人（isHidden）没有名字，不要
  static LiveRankUpdate? douyinSeqRankTop(RoomUserSeqMessage message) {
    var items = <LiveRankItem>[];
    for (var e in message.ranksList) {
      var name = e.user.nickName.trim();
      if (e.isHidden || name.isEmpty) {
        continue;
      }
      var urls = e.user.avatarThumb.urlListList;
      var description = e.scoreDescription.trim();
      var score = e.score.toInt();
      items.add(
        LiveRankItem(
          rank: e.rank.toInt() > 0 ? e.rank.toInt() : items.length + 1,
          userName: name,
          userId: douyinUserId(e.user),
          face: urls.isEmpty ? "" : liveEmoteUrl(urls.first),
          score: score > 0 ? score : null,
          scoreText: description.isEmpty ? null : description,
          badges: [
            for (var b in parseDouyinChatBadges(e.user) ?? const <LiveBadge>[])
              if (b.kind == LiveBadgeKind.medal ||
                  b.kind == LiveBadgeKind.level)
                b,
          ],
        ),
      );
    }
    return items.isEmpty ? null : LiveRankUpdate("online", items);
  }

  /// 点赞：total 是本场的点赞总数（count 是这一条里点了几下）
  void unPackWebcastLikeMessage(List<int> payload) {
    try {
      var likes = LikeMessage.fromBuffer(payload).total.toInt();
      if (likes > 0) {
        onMessage?.call(LiveRoomStats(likes: likes).toMessage());
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  void sendAck(var logId, String internalExt) {
    var obj = PushFrame();
    obj.payloadType = 'ack';
    obj.logId = logId;
    obj.payload = utf8.encode(internalExt);
    webScoketUtils?.sendMessage(obj.writeToBuffer());
  }

  void joinRoom(args) {
    var obj = PushFrame();
    obj.payloadType = 'hb';
    webScoketUtils?.sendMessage(obj.writeToBuffer());
  }

  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    linkMic.reset();
    webScoketUtils?.close();
  }
}

/// 抖音的连麦（连线）和 PK，整理成完整的一份 [LiveLinkMicState]，
/// 有变化时调用 [onChange]，一样的状态不重复发。
///
/// - WebcastLinkMessage：连线名单（名单变化、进入、离开、更新、跨房更新）、
///   排队名单和排队人数、连线关闭
/// - WebcastRoomDataSyncMessage（syncKey 为 RoomLinkMicSyncData）：完整名单
/// - WebcastLinkMicBattle 开始 PK（对手在 userInfos 里），LinkMicMethod 202
///   是 PK 比分（中途进直播间时只有它），LinkMicBattleFinishMethod 结束 PK
///
/// 名单里去掉本直播间的主播：用 [DouyinDanmakuArgs.anchorId]，没有时从消息里认
/// （linkerContentMap 里本直播间那一项的 anchorId、PK 里 roomId 是本直播间的主播）。
/// 别的主播带上他的直播间号（[LiveLinkMicUser.roomId]，可以直接打开）。
class DouyinLinkMic {
  DouyinLinkMic({this.onChange});

  void Function(LiveLinkMicState state)? onChange;

  String _roomId = "";
  String _anchorId = "";

  /// 连线名单；版本只和同一次连线（linkerId）的比，旧的不要
  List<_DouyinLinker> _linked = const [];
  Int64 _linkerId = Int64.ZERO;
  Int64 _linkVersion = Int64.ZERO;
  Int64 _syncVersion = Int64.ZERO;

  List<_DouyinLinker> _queue = const [];
  int _queueCount = 0;

  /// PK 的对手，null 时没有在 PK
  List<_DouyinLinker>? _pk;
  String _battleId = "";
  final Set<String> _finishedBattles = {};

  /// 主播的用户 id → 直播间号
  final Map<String, String> _rooms = {};

  LiveLinkMicState _state = LiveLinkMicState.none;

  /// 最后发出去的状态
  LiveLinkMicState get state => _state;

  /// 本直播间主播的用户 id，还不知道时为空
  String get anchorId => _anchorId;

  /// 新的连接：清掉之前的状态（不发消息）
  void reset({String roomId = "", String anchorId = ""}) {
    _roomId = roomId;
    _anchorId = anchorId;
    _linked = const [];
    _linkerId = Int64.ZERO;
    _linkVersion = Int64.ZERO;
    _syncVersion = Int64.ZERO;
    _queue = const [];
    _queueCount = 0;
    _pk = null;
    _battleId = "";
    _finishedBattles.clear();
    _rooms.clear();
    _state = LiveLinkMicState.none;
  }

  /// 处理一条弹幕消息（不相关的直接忽略）。解析失败只记日志，不影响别的消息
  void handle(String method, List<int> payload) {
    var name = method.startsWith("Webcast") ? method.substring(7) : method;
    try {
      switch (name) {
        case "LinkMessage":
          _onLink(LinkMessage.fromBuffer(payload));
        case "RoomDataSyncMessage":
          _onSync(RoomDataSyncMessage.fromBuffer(payload));
        case "LinkMicBattle":
        case "LinkMicBattleMethod":
          _onBattle(LinkMicBattle.fromBuffer(payload));
        case "LinkMicBattleFinish":
        case "LinkMicBattleFinishMethod":
          _onBattleFinish(LinkMicBattleFinish.fromBuffer(payload));
        case "LinkMicMethod":
          _onLinkMicMethod(LinkMicMethod.fromBuffer(payload));
        default:
          return;
      }
    } catch (e) {
      CoreLog.error(e);
      return;
    }
    _emit();
  }

  void _onLink(LinkMessage m) {
    if (m.hasCloseContent()) {
      // 连线关闭：名单、排队、PK 都没了
      _linked = const [];
      _linkVersion = Int64.ZERO;
      _queue = const [];
      _queueCount = 0;
      _pk = null;
      _battleId = "";
    } else if (m.hasLinkedListChangeContent()) {
      var c = m.linkedListChangeContent;
      _learnRooms(c.linkerContentMap);
      // 名单变化是完整的一份，空的就是没人连了
      if (_fresh(m, c.version)) {
        _linked = _users(c.linkedUsers);
      }
    } else if (m.hasEnterContent()) {
      var c = m.enterContent;
      _learnRooms(c.linkerContentMap);
      _replaceLinked(m, c.version, c.linkedUsers);
    } else if (m.hasUpdateUserContent()) {
      var c = m.updateUserContent;
      _learnRooms(c.linkerContentMap);
      _replaceLinked(m, c.version, c.linkedUsers);
    } else if (m.hasCrossRoomUpdateContent()) {
      var c = m.crossRoomUpdateContent;
      _learnRooms(c.linkerContentMap);
      _replaceLinked(m, c.version, c.linkedUsers);
    } else if (m.hasLeaveContent()) {
      _onLeave(m);
    } else if (m.hasWaitingListChangeContent()) {
      _queue = _users(m.waitingListChangeContent.listUsers);
    } else if (m.hasAudienceWaitingListChange()) {
      _queueCount = _count(m.audienceWaitingListChange.totalWaitingCnt);
    } else if (m.hasUpdateWaitingUserOffsetContent()) {
      _queueCount = _count(m.updateWaitingUserOffsetContent.totalCount);
    } else if (m.hasBattleLinkedListChangeContent()) {
      var c = m.battleLinkedListChangeContent;
      _learnRoom(c.battleAnchorId, c.battleRoomId);
    }
  }

  /// 进入、更新时带的名单是完整的一份；没带名单时不变
  void _replaceLinked(LinkMessage m, Int64 version, List<ListUser> users) {
    if (users.isNotEmpty && _fresh(m, version)) {
      _linked = _users(users);
    }
  }

  void _onLeave(LinkMessage m) {
    var c = m.leaveContent;
    _learnRooms(c.linkerContentMap);
    if (!_fresh(m, c.version)) {
      return;
    }
    var gone = <String>{
      if (c.userId != 0) c.userId.toString(),
      if (c.hasUser()) _DouyinLinker.user(c.user.user).id,
    }..remove("");
    if (_anchorId.isNotEmpty && gone.contains(_anchorId)) {
      // 本直播间的主播退出了连线
      _linked = const [];
      return;
    }
    var list = _users(c.linkedUsers);
    // 带的名单一般是剩下的人；没带，或者带的是离开的人时，从现在的名单里去掉
    if (list.isEmpty || list.any((u) => gone.contains(u.id))) {
      var leaving = {...gone, for (var u in list) u.id};
      list = [
        for (var u in _linked)
          if (!leaving.contains(u.id)) u,
      ];
    }
    _linked = list;
  }

  void _onSync(RoomDataSyncMessage m) {
    if (m.syncKey != "RoomLinkMicSyncData") {
      return;
    }
    var data = RoomLinkMicSyncData.fromBuffer(m.payload);
    _learnRooms(data.linkerContentMap);
    var version = data.version;
    if (version > 0 && version < _syncVersion) {
      return;
    }
    _syncVersion = version;
    _linked = _users(data.linkedUsers);
  }

  void _onBattle(LinkMicBattle m) {
    var id = _battle(m.battleSettings.battleIdStr, m.battleSettings.battleId);
    if (id.isNotEmpty && _finishedBattles.contains(id)) {
      // 已经结束的场次晚到的消息
      return;
    }
    var rivals = <_DouyinLinker>[];
    m.userInfos.forEach((key, info) {
      var u = info.user;
      var uid = u.userId != 0
          ? u.userId.toString()
          : u.userIdStr.isNotEmpty
          ? u.userIdStr
          : key.toString();
      _learnRoom(uid, info.roomId);
      rivals.add(_DouyinLinker(uid, _name(u.nickName), _face(u.avatarThumb)));
    });
    var status = m.battleSettings.battleStatus.toInt();
    if (status == 2 || status == 3) {
      _finishPk(id);
      return;
    }
    var pk = _pk;
    if (rivals.isEmpty && pk != null && _battleId == id) {
      rivals = pk;
    }
    _pk = rivals;
    _battleId = id;
  }

  void _onBattleFinish(LinkMicBattleFinish m) {
    _finishPk(_battle(m.battleSettings.battleIdStr, m.battleSettings.battleId));
  }

  void _finishPk(String id) {
    if (id.isNotEmpty) {
      _finishedBattles.add(id);
      if (_finishedBattles.length > 64) {
        _finishedBattles.remove(_finishedBattles.first);
      }
    }
    if (_pk != null && (id.isEmpty || _battleId.isEmpty || _battleId == id)) {
      _pk = null;
      _battleId = "";
    }
  }

  /// 202 是 PK 比分：中途进直播间时 PK 的开始已经错过了，靠它知道在 PK
  void _onLinkMicMethod(LinkMicMethod m) {
    if (m.messageType != 202) {
      return;
    }
    var id = _battle(m.battleIdStr, m.battleId);
    if (id.isEmpty || _finishedBattles.contains(id)) {
      return;
    }
    var rivals = [for (var u in m.linkedUsers) _DouyinLinker.user(u)];
    if (rivals.isEmpty && m.rivalAnchorId != 0) {
      var rival = m.rivalAnchorId.toString();
      rivals = [
        for (var u in _linked)
          if (u.id == rival) u,
      ];
    }
    var pk = _pk;
    if (pk != null && (_battleId == id || _battleId.isEmpty)) {
      _battleId = id;
      if (pk.isEmpty) {
        _pk = rivals;
      }
      return;
    }
    _pk = rivals;
    _battleId = id;
  }

  /// 同一次连线里版本比现在的旧就不要（版本是 0 时不比）
  bool _fresh(LinkMessage m, Int64 contentVersion) {
    var version = contentVersion != 0 ? contentVersion : m.version;
    if (m.linkerId == _linkerId && version > 0 && version < _linkVersion) {
      return false;
    }
    if (m.linkerId != _linkerId) {
      _linkerId = m.linkerId;
      _linkVersion = Int64.ZERO;
    }
    if (version > _linkVersion) {
      _linkVersion = version;
    }
    return true;
  }

  void _learnRooms(Map<Int64, RoomLinkerContent> map) {
    map.forEach((room, content) {
      if (content.anchorId != 0) {
        _learnRoom(content.anchorId.toString(), room.toString());
      }
    });
  }

  /// 记下主播的直播间号；是本直播间时记下本直播间的主播
  void _learnRoom(String anchorId, String roomId) {
    if ({anchorId, roomId}.any((e) => e.isEmpty || e == "0")) {
      return;
    }
    _rooms[anchorId] = roomId;
    if (_anchorId.isEmpty && roomId == _roomId) {
      _anchorId = anchorId;
    }
  }

  bool _isOwnAnchor(_DouyinLinker u) =>
      u.id.isNotEmpty &&
      (u.id == _anchorId || (_roomId.isNotEmpty && _rooms[u.id] == _roomId));

  List<LiveLinkMicUser> _public(Iterable<_DouyinLinker> users) {
    var seen = <String>{};
    return [
      for (var u in users)
        if (!_isOwnAnchor(u) &&
            seen.add(u.id.isEmpty ? "name:${u.name}" : u.id))
          LiveLinkMicUser(
            name: u.name,
            face: u.face,
            roomId: _rooms[u.id] ?? "",
          ),
    ];
  }

  void _emit() {
    var pk = _pk;
    var linked = _public([...?pk, ..._linked]);
    var state = LiveLinkMicState(
      kind: pk != null && linked.isNotEmpty ? "PK" : "连麦",
      linked: linked,
      queue: _public(_queue),
      queueCount: _queueCount,
    );
    if (state == _state) {
      return;
    }
    _state = state;
    onChange?.call(state);
  }

  static List<_DouyinLinker> _users(List<ListUser> users) => [
    for (var u in users)
      if (u.hasUser()) _DouyinLinker.user(u.user),
  ];

  static int _count(Int64 value) => value > 0 ? value.toInt() : 0;

  static String _battle(String idStr, Int64 id) =>
      idStr.isNotEmpty && idStr != "0"
      ? idStr
      : id != 0
      ? id.toString()
      : "";
}

/// 连麦名单里的一个人
class _DouyinLinker {
  final String id;
  final String name;
  final String face;
  const _DouyinLinker(this.id, this.name, this.face);

  factory _DouyinLinker.user(User user) => _DouyinLinker(
    user.id != 0 ? user.id.toString() : user.idStr,
    _name(user.nickName, user.displayId),
    _face(user.avatarThumb),
  );
}

/// 昵称，没有时用抖音号，都没有时是“神秘人”（抖音隐藏身份时也这么叫）
String _name(String nickName, [String displayId = ""]) {
  var name = nickName.trim();
  if (name.isEmpty) {
    name = displayId.trim();
  }
  return name.isEmpty ? "神秘人" : name;
}

/// 头像：第一个 http 地址
String _face(Image image) {
  for (var url in image.urlListList) {
    if (url.startsWith("http") || url.startsWith("//")) {
      return liveEmoteUrl(url);
    }
  }
  return "";
}

/// 抖音聊天里发言人的身份，按网页端的顺序：房管、荣誉等级、粉丝团；没有时返回 null。
///
/// - 房管：user.userAttr.isAdmin（只有 isSuperAdmin 时为“超管”）
/// - 荣誉等级：user.payGrade.level；用户隐藏了等级时（图片是 hide_paygrade_badge）不显示
/// - 粉丝团：user.fansClub.data 的团名和等级，和网页端一样只在点亮
///   （userFansClubStatus 1）时显示；团名经常是空的，这时显示“粉丝团”
///
/// 图标用 user.badgeImageList 里对应的图片（imageType 1 荣誉等级、3 房管、7 粉丝团），
/// 结构化字段缺了时也从这些图片的说明里取等级和团名
List<LiveBadge>? parseDouyinChatBadges(User user) {
  try {
    return _douyinChatBadges(user);
  } catch (e) {
    CoreLog.error(e);
    return null;
  }
}

List<LiveBadge>? _douyinChatBadges(User user) {
  Image? image(int type) {
    for (var item in user.badgeImageList) {
      if (item.imageType == type) {
        return item;
      }
    }
    return null;
  }

  String? icon(Image? image) {
    for (var url in image?.urlListList ?? const <String>[]) {
      var value = liveEmoteUrl(url);
      if (value.startsWith("http")) {
        return value;
      }
    }
    return null;
  }

  var badges = <LiveBadge>[];

  // 房管
  var adminImage = image(3);
  if (adminImage != null &&
      !adminImage.content.alternativeText.contains("房管")) {
    adminImage = null;
  }
  var attr = user.userAttr;
  if (attr.isAdmin || adminImage != null) {
    badges.add(LiveBadge(LiveBadgeKind.admin, "房管", icon: icon(adminImage)));
  } else if (attr.isSuperAdmin) {
    badges.add(const LiveBadge(LiveBadgeKind.admin, "超管"));
  }

  // 荣誉等级
  var grade = user.payGrade;
  var levelImage = image(1);
  var level = grade.level.toInt();
  if (level <= 0 && levelImage != null) {
    level = levelImage.content.level.toInt();
  }
  // 隐藏了等级时两处的图片都是 hide_paygrade_badge
  var hidden = [
    ...?levelImage?.urlListList,
    ...grade.newImIconWithLevel.urlListList,
  ].any((e) => e.contains("hide_paygrade"));
  if (level > 0 && !hidden) {
    badges.add(
      LiveBadge(
        LiveBadgeKind.level,
        "等级",
        level: level,
        icon: icon(levelImage) ?? icon(grade.newImIconWithLevel),
      ),
    );
  }

  // 粉丝团
  var club = user.fansClub.data;
  var clubImage = image(7);
  var clubLevel = club.level;
  var clubName = club.clubName.trim();
  if (clubImage != null) {
    if (clubLevel <= 0) {
      clubLevel = clubImage.content.level.toInt();
    }
    if (clubName.isEmpty) {
      clubName = clubImage.content.name.trim();
    }
  }
  if (clubLevel > 0 && (club.userFansClubStatus == 1 || clubImage != null)) {
    badges.add(
      LiveBadge(
        LiveBadgeKind.medal,
        clubName.isEmpty ? "粉丝团" : clubName,
        level: clubLevel,
        icon: icon(clubImage),
      ),
    );
  }
  return badges.isEmpty ? null : badges;
}

/// 抖音表情（聊天里是“[捂脸]”这样的文字）的图片。
///
/// 弹幕里没有图片地址，网页端用一份固定的表情列表（不需要登录）对照，
/// 每次运行读取一次；读取失败时 10 分钟后再试，在此之前表情显示为文字。
///
/// 图片地址带签名，每次读列表都不一样，所以表情带上 [LiveEmote.cacheKey]
/// （emoji_url.uri），App 按它做磁盘缓存，不用每次启动都重新下载。
class DouyinEmotes {
  static const String kListUrl =
      "https://www.douyin.com/aweme/v1/web/emoji/list";

  static Map<String, LiveEmote> _emotes = const {};
  static Future<void>? _loading;
  static DateTime? _failedAt;

  static final RegExp _pattern = RegExp(r'\[[^\[\]]{1,8}\]');

  /// 读取表情列表（已读取或正在读取时不重复请求）
  static Future<void> load() {
    if (_emotes.isNotEmpty) {
      return Future.value();
    }
    var failed = _failedAt;
    if (failed != null &&
        DateTime.now().difference(failed) < const Duration(minutes: 10)) {
      return Future.value();
    }
    return _loading ??= () async {
      try {
        var result = await core.HttpClient.instance.getJson(
          kListUrl,
          queryParameters: {
            "device_platform": "webapp",
            "aid": "6383",
            "channel": "channel_pc_web",
            "pc_client_type": "1",
            "version_code": "170400",
            "version_name": "17.4.0",
            "cookie_enabled": "true",
            "platform": "PC",
          },
          header: {"User-Agent": DouyinSite.kDefaultUserAgent},
        );
        _emotes = parseDouyinEmojiTable(result);
        if (_emotes.isEmpty) {
          _failedAt = DateTime.now();
        }
      } catch (e) {
        CoreLog.error(e);
        _failedAt = DateTime.now();
      } finally {
        _loading = null;
      }
    }();
  }

  /// 测试用：直接设置表情列表（文字 → 图片地址）
  static void debugSet(Map<String, String> urls) {
    _emotes = {
      for (var e in urls.entries)
        e.key: LiveEmote(text: e.key, url: e.value, width: 1, height: 1),
    };
  }

  /// 消息里的表情，列表还没读到或没有表情时返回 null
  static List<LiveEmote>? parse(String content) {
    if (_emotes.isEmpty || !content.contains('[')) {
      return null;
    }
    var result = <LiveEmote>[];
    var seen = <String>{};
    for (var m in _pattern.allMatches(content)) {
      var text = m.group(0)!;
      var emote = _emotes[text];
      if (emote != null && seen.add(text)) {
        result.add(emote);
      }
    }
    return result.isEmpty ? null : result;
  }
}

/// 解析抖音网页端的表情列表：{emoji_list: [{display_name: "[捂脸]",
/// emoji_url: {url_list: [...]}}]} → 文字到图片地址
Map<String, String> parseDouyinEmojiList(dynamic json) => {
  for (var e in parseDouyinEmojiTable(json).entries) e.key: e.value.url,
};

/// 同 [parseDouyinEmojiList]，得到表情；缓存键是 emoji_url.uri
/// （签名地址每次都变，uri 不变），没有 uri 时为空
Map<String, LiveEmote> parseDouyinEmojiTable(dynamic json) {
  var list = json is Map ? json["emoji_list"] : null;
  var result = <String, LiveEmote>{};
  if (list is! List) {
    return result;
  }
  for (var item in list) {
    if (item is! Map) {
      continue;
    }
    var name = item["display_name"]?.toString() ?? "";
    var image = item["emoji_url"];
    var urls = image is Map ? image["url_list"] : null;
    if (name.isEmpty || urls is! List || urls.isEmpty) {
      continue;
    }
    var url = urls.first.toString();
    if (!url.startsWith("http")) {
      continue;
    }
    var uri = image is Map ? image["uri"]?.toString() ?? "" : "";
    result[name] = LiveEmote(
      text: name,
      url: liveEmoteUrl(url),
      width: 1,
      height: 1,
      cacheKey: uri.isEmpty ? null : "douyin-emoji:$uri",
    );
  }
  return result;
}
