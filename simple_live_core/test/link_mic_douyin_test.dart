import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/proto/douyin.pb.dart';
import 'package:test/test.dart';

/// 抖音连麦：按 douyin.proto 构造的消息（匿名连接能不能收到还没确认）
const ownRoom = "7400000000000000001";
const otherRoom = "7400000000000000002";

User user(int id, String name, {String face = ""}) {
  var u = User()
    ..id = Int64(id)
    ..nickName = name;
  if (face.isNotEmpty) {
    u.avatarThumb = Image()..urlListList.add(face);
  }
  return u;
}

ListUser listUser(int id, String name, {String face = ""}) =>
    ListUser()..user = user(id, name, face: face);

/// 本直播间的主播 A（1001），另一个直播间的主播 B（2002），观众 C（3003）
ListUser get anchorA => listUser(1001, "主播A");
ListUser get anchorB =>
    listUser(2002, "主播B", face: "https://p3.douyinpic.com/b.jpeg");
ListUser get guestC => listUser(3003, "观众C");

Map<Int64, RoomLinkerContent> rooms() => {
  Int64.parseInt(ownRoom): RoomLinkerContent()..anchorId = Int64(1001),
  Int64.parseInt(otherRoom): RoomLinkerContent()..anchorId = Int64(2002),
};

LinkMessage listChange(
  List<ListUser> users, {
  int version = 0,
  int linkerId = 1,
  bool withRooms = true,
}) {
  var c = LinkerLinkedListChangeContent()
    ..linkedUsers.addAll(users)
    ..version = Int64(version);
  if (withRooms) {
    c.linkerContentMap.addAll(rooms());
  }
  return LinkMessage()
    ..linkerId = Int64(linkerId)
    ..linkedListChangeContent = c;
}

Message msg(String method, List<int> payload) => Message()
  ..method = method
  ..payload = payload;

Message link(LinkMessage m) => msg("WebcastLinkMessage", m.writeToBuffer());

Message chat(String name, String text) => msg(
  "WebcastChatMessage",
  (ChatMessage()
        ..user = (User()..nickName = name)
        ..content = text)
      .writeToBuffer(),
);

Message sync(String key, List<int> payload) => msg(
  "WebcastRoomDataSyncMessage",
  (RoomDataSyncMessage()
        ..syncKey = key
        ..payload = payload)
      .writeToBuffer(),
);

BattleUserInfo battleUser(
  int id,
  String name,
  String room, {
  String face = "",
}) {
  var base = BattleBaseUserInfo()
    ..userId = Int64(id)
    ..nickName = name;
  if (face.isNotEmpty) {
    base.avatarThumb = Image()..urlListList.add(face);
  }
  return BattleUserInfo()
    ..user = base
    ..roomId = room;
}

Message battle(
  int battleId, {
  int status = 1,
  String method = "WebcastLinkMicBattle",
}) {
  var m = LinkMicBattle()
    ..battleSettings = (BattleSettings()
      ..battleId = Int64(battleId)
      ..battleStatus = Int64(status));
  m.userInfos.addAll({
    Int64(1001): battleUser(1001, "主播A", ownRoom),
    Int64(2002): battleUser(
      2002,
      "主播B",
      otherRoom,
      face: "https://p3.douyinpic.com/b.jpeg",
    ),
  });
  return msg(method, m.writeToBuffer());
}

Message battleFinish(int battleId) => msg(
  "WebcastLinkMicBattleFinishMethod",
  (LinkMicBattleFinish()
        ..battleSettings = (BattleSettings()..battleId = Int64(battleId)))
      .writeToBuffer(),
);

Message pkScore(int battleId, {List<User> users = const [], int rival = 0}) {
  var m = LinkMicMethod()
    ..messageType = Int64(202)
    ..battleIdStr = "$battleId"
    ..rivalAnchorId = Int64(rival);
  m.linkedUsers.addAll(users);
  return msg("WebcastLinkMicMethod", m.writeToBuffer());
}

/// 一帧 PushFrame（gzip 的 Response），和服务器推来的一样
List<int> pushFrame(List<Message> messages) {
  var response = Response()..messagesList.addAll(messages);
  return (PushFrame()
        ..payloadType = "msg"
        ..payload = gzip.encode(response.writeToBuffer()))
      .writeToBuffer();
}

class Room {
  final out = <LiveMessage>[];
  late final DouyinDanmaku danmaku;

  Room({String roomId = ownRoom, String anchorId = ""}) {
    danmaku = DouyinDanmaku()..onMessage = out.add;
    danmaku.linkMic.reset(roomId: roomId, anchorId: anchorId);
  }

  void push(List<Message> messages) =>
      danmaku.decodeMessage(pushFrame(messages));

  List<LiveLinkMicState> get states => [
    for (var m in out)
      if (m.type == LiveMessageType.linkMic) m.data as LiveLinkMicState,
  ];

  LiveLinkMicState get last => states.last;
}

List<String> names(List<LiveLinkMicUser> users) => [
  for (var u in users) u.name,
];

void main() {
  setUpAll(() => CoreLog.enableLog = false);

  group('抖音连麦', () {
    test('连线名单：开始、有人加入、结束', () {
      var room = Room();
      room.push([
        link(listChange([anchorA, anchorB], version: 1)),
      ]);
      expect(room.states, hasLength(1));
      var s = room.last;
      expect(s.kind, "连麦");
      expect(s.active, isTrue);
      // 本直播间的主播不算，从 linkerContentMap 认出来
      expect(room.danmaku.linkMic.anchorId, "1001");
      expect(s.linked, [
        const LiveLinkMicUser(
          name: "主播B",
          face: "https://p3.douyinpic.com/b.jpeg",
          roomId: otherRoom,
        ),
      ]);
      expect(s.summary, "连麦：主播B");
      var message = room.out.last;
      expect(message.type, LiveMessageType.linkMic);
      expect(message.message, "连麦：主播B");

      room.push([
        link(listChange([anchorA, anchorB, guestC], version: 2)),
      ]);
      expect(names(room.last.linked), ["主播B", "观众C"]);
      // 观众没有直播间号
      expect(room.last.linked[1].roomId, "");

      // 只剩本直播间的主播：结束
      room.push([
        link(listChange([anchorA], version: 3)),
      ]);
      expect(room.states, hasLength(3));
      expect(room.last, LiveLinkMicState.none);
      expect(room.last.summary, "连麦结束");
    });

    test('空名单也是结束', () {
      var room = Room();
      room.push([
        link(listChange([anchorA, anchorB], version: 1)),
        link(listChange([], version: 2)),
      ]);
      expect(room.states, hasLength(2));
      expect(room.last.active, isFalse);
    });

    test('同一次连线里旧版本的名单不要，新的一次连线重新算', () {
      var room = Room();
      room.push([
        link(listChange([anchorA, anchorB, guestC], version: 5)),
        // 晚到的旧名单
        link(listChange([anchorA, anchorB], version: 4)),
      ]);
      expect(room.states, hasLength(1));
      expect(names(room.last.linked), ["主播B", "观众C"]);

      // 新的一次连线，版本从头开始
      room.push([
        link(listChange([anchorA, guestC], version: 1, linkerId: 2)),
      ]);
      expect(names(room.last.linked), ["观众C"]);
    });

    test('进入、更新、跨房更新带完整名单，没带名单时不变', () {
      var room = Room();
      room.push([
        link(
          LinkMessage()
            ..enterContent = (LinkerEnterContent()
              ..linkedUsers.addAll([anchorA, anchorB])
              ..linkerContentMap.addAll(rooms())),
        ),
      ]);
      expect(names(room.last.linked), ["主播B"]);
      expect(room.last.linked.single.roomId, otherRoom);

      room.push([
        link(
          LinkMessage()
            ..updateUserContent = (LinkerUpdateUserContent()
              ..linkedUsers.addAll([anchorA, anchorB, guestC])),
        ),
        // 没带名单
        link(LinkMessage()..updateUserContent = LinkerUpdateUserContent()),
      ]);
      expect(room.states, hasLength(2));
      expect(names(room.last.linked), ["主播B", "观众C"]);

      room.push([
        link(
          LinkMessage()
            ..crossRoomUpdateContent = (LinkerCrossRoomUpdateContent()
              ..linkedUsers.addAll([anchorA, guestC])),
        ),
      ]);
      expect(names(room.last.linked), ["观众C"]);
    });

    test('离开：带剩下的名单、只带离开的人、带的是离开的人', () {
      var room = Room();
      var guestD = listUser(4004, "观众D");
      room.push([
        link(listChange([anchorA, anchorB, guestC, guestD])),
      ]);
      expect(names(room.last.linked), ["主播B", "观众C", "观众D"]);

      // 带剩下的名单
      room.push([
        link(
          LinkMessage()
            ..leaveContent = (LinkerLeaveContent()
              ..userId = Int64(4004)
              ..linkedUsers.addAll([anchorA, anchorB, guestC])),
        ),
      ]);
      expect(names(room.last.linked), ["主播B", "观众C"]);

      // 只带离开的人
      room.push([
        link(
          LinkMessage()..leaveContent = (LinkerLeaveContent()..user = guestC),
        ),
      ]);
      expect(names(room.last.linked), ["主播B"]);

      // 名单里是离开的人自己：从现在的名单里去掉
      room.push([
        link(
          LinkMessage()
            ..leaveContent = (LinkerLeaveContent()
              ..userId = Int64(2002)
              ..linkedUsers.add(anchorB)),
        ),
      ]);
      expect(room.last, LiveLinkMicState.none);
    });

    test('本直播间的主播退出连线：结束', () {
      var room = Room(anchorId: "1001");
      room.push([
        link(listChange([anchorA, anchorB, guestC], withRooms: false)),
      ]);
      expect(names(room.last.linked), ["主播B", "观众C"]);
      room.push([
        link(
          LinkMessage()
            ..leaveContent = (LinkerLeaveContent()..userId = Int64(1001)),
        ),
      ]);
      expect(room.last.active, isFalse);
    });

    test('排队：名单和人数', () {
      var room = Room();
      room.push([
        link(listChange([anchorA, guestC])),
        link(
          LinkMessage()
            ..waitingListChangeContent = (LinkerWaitingListChangeContent()
              ..listUsers.addAll([
                listUser(5005, "排队E"),
                listUser(6006, "排队F"),
              ])),
        ),
      ]);
      expect(names(room.last.queue), ["排队E", "排队F"]);
      expect(room.last.waiting, 2);

      room.push([
        link(
          LinkMessage()
            ..audienceWaitingListChange =
                (LinkerAudienceWaitingListChangeContent()
                  ..totalWaitingCnt = Int64(5)),
        ),
      ]);
      expect(room.last.queueCount, 5);
      expect(room.last.waiting, 5);

      room.push([
        link(
          LinkMessage()
            ..updateWaitingUserOffsetContent =
                (LinkerUpdateWaitingUserOffsetContent()..totalCount = Int64(7)),
        ),
      ]);
      expect(room.last.queueCount, 7);
      expect(names(room.last.linked), ["观众C"]);
      expect(room.states, hasLength(4));

      // 连线关闭：名单和排队都清掉
      room.push([link(LinkMessage()..closeContent = LinkerCloseContent())]);
      expect(room.last, LiveLinkMicState.none);
    });

    test('没人连麦时只有排队人数也发', () {
      var room = Room();
      room.push([
        link(
          LinkMessage()
            ..audienceWaitingListChange =
                (LinkerAudienceWaitingListChangeContent()
                  ..totalWaitingCnt = Int64(3)),
        ),
      ]);
      expect(room.last.active, isFalse);
      expect(room.last.queueCount, 3);
    });

    test('RoomLinkMicSyncData：完整名单', () {
      var room = Room();
      var data = RoomLinkMicSyncData()
        ..linkedUsers.addAll([anchorA, anchorB, guestC])
        ..linkerContentMap.addAll(rooms())
        ..version = Int64(10);
      room.push([
        // 别的同步数据不管，坏的也不管
        sync("LotteryInfoSyncData", [0xff, 0xff, 0xff]),
        sync("RoomLinkMicSyncData", data.writeToBuffer()),
      ]);
      expect(room.states, hasLength(1));
      expect(names(room.last.linked), ["主播B", "观众C"]);
      expect(room.last.linked.first.roomId, otherRoom);

      // 旧版本的不要
      var old = RoomLinkMicSyncData()
        ..linkedUsers.addAll([anchorA])
        ..version = Int64(9);
      room.push([sync("RoomLinkMicSyncData", old.writeToBuffer())]);
      expect(room.states, hasLength(1));

      var ended = RoomLinkMicSyncData()..version = Int64(11);
      room.push([sync("RoomLinkMicSyncData", ended.writeToBuffer())]);
      expect(room.last, LiveLinkMicState.none);
    });

    test('PK：开始、比分、结束', () {
      var room = Room();
      room.push([battle(9001)]);
      var s = room.last;
      expect(s.kind, "PK");
      expect(s.linked, [
        const LiveLinkMicUser(
          name: "主播B",
          face: "https://p3.douyinpic.com/b.jpeg",
          roomId: otherRoom,
        ),
      ]);
      expect(s.summary, "PK：主播B");
      // 本直播间的主播从 PK 的 roomId 认出来
      expect(room.danmaku.linkMic.anchorId, "1001");

      // 同一场的比分、重复的开始：状态没变，不发
      room.push([
        pkScore(9001, users: [user(1001, "主播A"), user(2002, "主播B")]),
        battle(9001, method: "WebcastLinkMicBattleMethod"),
      ]);
      expect(room.states, hasLength(1));

      room.push([battleFinish(9001)]);
      expect(room.states, hasLength(2));
      expect(room.last, LiveLinkMicState.none);

      // 结束后晚到的比分、开始不算
      room.push([
        pkScore(9001, users: [user(2002, "主播B")]),
        battle(9001),
      ]);
      expect(room.states, hasLength(2));
    });

    test('PK 结束后还连着线：回到连麦', () {
      var room = Room();
      room.push([
        link(listChange([anchorA, anchorB])),
        battle(9001),
      ]);
      expect(room.last.kind, "PK");
      expect(names(room.last.linked), ["主播B"]);
      room.push([battleFinish(9001)]);
      expect(room.last.kind, "连麦");
      expect(names(room.last.linked), ["主播B"]);
      expect(room.states, hasLength(3));
    });

    test('PK 状态 2、3 也是结束', () {
      var room = Room();
      room.push([battle(9001)]);
      room.push([battle(9001, status: 3)]);
      expect(room.last, LiveLinkMicState.none);
      room.push([
        pkScore(9001, users: [user(2002, "主播B")]),
      ]);
      expect(room.last, LiveLinkMicState.none);
    });

    test('中途进直播间：靠 202 比分知道在 PK', () {
      var room = Room(anchorId: "1001");
      room.push([
        pkScore(9002, users: [user(1001, "主播A"), user(7007, "主播G")]),
      ]);
      expect(room.last.kind, "PK");
      expect(names(room.last.linked), ["主播G"]);

      // 没带名单时按 rivalAnchorId 从连线名单里找
      var other = Room();
      other.push([
        link(listChange([anchorA, anchorB, guestC])),
        pkScore(9003, rival: 2002),
      ]);
      expect(other.last.kind, "PK");
      expect(names(other.last.linked), ["主播B", "观众C"]);

      // 别的 LinkMicMethod 不管
      var third = Room();
      third.push([
        msg(
          "WebcastLinkMicMethod",
          (LinkMicMethod()
                ..messageType = Int64(100)
                ..battleId = Int64(1))
              .writeToBuffer(),
        ),
      ]);
      expect(third.states, isEmpty);
    });

    test('去掉本直播间的主播：用参数里的主播 id；不知道时都显示', () {
      var room = Room(anchorId: "1001");
      room.push([
        link(listChange([anchorA, anchorB], withRooms: false)),
      ]);
      expect(names(room.last.linked), ["主播B"]);

      var unknown = Room();
      unknown.push([
        link(listChange([anchorA, anchorB], withRooms: false)),
      ]);
      expect(names(unknown.last.linked), ["主播A", "主播B"]);
      // 后来认出来了，下次变化时去掉
      unknown.push([battle(9001)]);
      expect(unknown.last.kind, "PK");
      expect(names(unknown.last.linked), ["主播B"]);
    });

    test('一样的状态不重复发', () {
      var room = Room();
      var data = RoomLinkMicSyncData()
        ..linkedUsers.addAll([anchorA, anchorB])
        ..linkerContentMap.addAll(rooms());
      room.push([
        link(listChange([anchorA, anchorB], version: 1)),
        link(listChange([anchorA, anchorB], version: 1)),
        link(listChange([anchorA, anchorB], version: 2)),
        sync("RoomLinkMicSyncData", data.writeToBuffer()),
        // 名单里同一个人出现两次
        link(listChange([anchorA, anchorB, anchorB], version: 3)),
      ]);
      expect(room.states, hasLength(1));
      // 没在连麦时结束也不发
      var idle = Room();
      idle.push([link(listChange([], version: 1))]);
      expect(idle.states, isEmpty);
    });

    test('坏的连麦消息不影响聊天和别的消息', () {
      var room = Room();
      room.push([
        chat("用户A", "主播好"),
        msg("WebcastLinkMessage", [0xff, 0xff, 0xff]),
        msg("WebcastLinkMicBattle", [0x0a, 0x05, 0x01]),
        msg("WebcastLinkMicMethod", [0x80]),
        sync("RoomLinkMicSyncData", [0xff, 0xff, 0xff]),
        msg("WebcastLinkMicBattleFinishMethod", [0x12, 0x10]),
        link(listChange([anchorA, anchorB])),
        chat("用户B", "来了"),
      ]);
      expect(room.out.map((m) => m.type).toList(), [
        LiveMessageType.chat,
        LiveMessageType.linkMic,
        LiveMessageType.chat,
      ]);
      expect(room.out.first.message, "主播好");
      expect(room.out.last.message, "来了");
      // 坏的 PK 消息没有被当成 PK 开始
      expect(room.last.kind, "连麦");
      expect(names(room.last.linked), ["主播B"]);
    });

    test('start、stop 时清空，之后同样的名单会再发', () async {
      var room = Room();
      room.push([
        link(listChange([anchorA, anchorB])),
      ]);
      expect(room.states, hasLength(1));
      await room.danmaku.stop();
      expect(room.danmaku.linkMic.state, LiveLinkMicState.none);
      expect(room.danmaku.linkMic.anchorId, "");

      room.danmaku.onMessage = room.out.add;
      room.danmaku.linkMic.reset(roomId: ownRoom);
      room.push([
        link(listChange([anchorA, anchorB])),
      ]);
      expect(room.states, hasLength(2));
      expect(names(room.last.linked), ["主播B"]);
    });

    test('没有昵称时用抖音号，都没有时是神秘人', () {
      var room = Room(anchorId: "1001");
      room.push([
        link(
          listChange([
            ListUser()
              ..user = (User()
                ..id = Int64(8008)
                ..displayId = "dy8008"),
            ListUser()..user = (User()..id = Int64(9009)),
          ]),
        ),
      ]);
      expect(names(room.last.linked), ["dy8008", "神秘人"]);
    });
  });
}
