import 'dart:async';
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/model/tars/huya_gift.dart';
import 'package:simple_live_core/src/model/tars/huya_link_mic.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------- 虎牙

/// 本直播间：主播 uid 100、YY 号 200、频道 100
final _room = HuyaDanmakuArgs(
  ayyuid: 200,
  topSid: 100,
  subSid: 100,
  presenterUid: 100,
);

/// 服务器推送的一帧（命令 7）；[group] 不为空时是消息组推来的
List<int> frame7(int uri, List<int> msg, {String group = ""}) {
  var push = TarsOutputStream();
  push.write(group.isEmpty ? 3 : 5, 0);
  push.write(uri, 1);
  push.write(Uint8List.fromList(msg), 2);
  push.write(0, 3);
  if (group.isNotEmpty) {
    push.write(group, 4);
  }
  var cmd = TarsOutputStream();
  cmd.write(7, 0);
  cmd.write(push.toUint8List(), 1);
  return cmd.toUint8List();
}

/// 新版推送（命令 22，WSPushMessage_V2），一次几条
List<int> frame22(List<(int, List<int>)> items, {String group = "live:100"}) {
  var push = HuyaWSPushMessageV2()
    ..sGroupId = group
    ..vMsgItem = [
      for (var (uri, msg) in items)
        HuyaWSMsgItem()
          ..lUri = uri
          ..sMsg = Uint8List.fromList(msg),
    ];
  var cmd = TarsOutputStream();
  cmd.write(22, 0);
  cmd.write(push.toByteArray(), 1);
  return cmd.toUint8List();
}

/// 一条聊天（HYMessage：tag 0 发送人、tag 3 内容、tag 20 消息 id）
List<int> chat(String nick, String content, String id) {
  var os = TarsOutputStream();
  os.writeHead(TarsStructType.STRUCT_BEGIN.index, 0);
  os.write(10001, 0);
  os.write(nick, 2);
  os.writeHead(TarsStructType.STRUCT_END.index, 0);
  os.write(content, 3);
  os.write(id, 20);
  return os.toUint8List();
}

HuyaLMPresenterInfo presenter(
  int uid,
  String nick, {
  int room = 0,
  int yy = 0,
  int channel = -1,
}) => HuyaLMPresenterInfo()
  ..lUid = uid
  ..lChannelId = channel < 0 ? uid : channel
  ..lSubChannelId = channel < 0 ? uid : channel
  ..sNick = nick
  ..sAvatarUrl = "http://huyaimg.msstatic.com/avatar/$uid.jpg"
  ..lYYId = yy
  ..bLive = true
  ..iRoomId = room;

/// 主播连麦（42008）
List<int> linkMic(List<HuyaLMPresenterInfo> presenters, {int status = 2}) =>
    (HuyaLinkMicStatusNotice()
          ..lLMSessionId = 7707411948278011742
          ..iLinkMicStatus = status
          ..lOwnerUid = 100
          ..vLMPresenterInfos = presenters)
        .toByteArray();

HuyaPKUserInfo pkUser(int pid, String nick, int room, {int yy = 0}) =>
    HuyaPKUserInfo()
      ..lPid = pid
      ..sNickName = nick
      ..sAvatarUrl = "https://huyaimg.msstatic.com/avatar/$pid.jpg"
      ..tLiveInfo = (HuyaPresenterChannelInfo()
        ..lYYId = yy
        ..lTid = pid
        ..lSid = pid
        ..lUid = pid
        ..iRoomId = room);

/// PK 面板（1090009）
List<int> pk(List<HuyaPKUserInfo> left, List<HuyaPKUserInfo> right) =>
    (HuyaMultiPKPanelInfo()
          ..tLeftTeam = (HuyaPKTeamInfo()..vMemberInfo = left)
          ..tRightTeam = (HuyaPKTeamInfo()..vMemberInfo = right))
        .toByteArray();

/// 多人视频（2400001）：座位（uid、昵称、位置）和排队的人
List<int> multiVideo(
  List<(int, String, int)> seats,
  List<(int, String)> apply,
) =>
    (HuyaMultiVideoSyncNotice()
          ..tRoom = (HuyaMultiVideoRoomInfo()
            ..lUid = 100
            ..sNick = "主播"
            ..iState = 1)
          ..vSeat = [
            for (var (uid, nick, pos) in seats)
              HuyaMultiVideoSeatInfo()
                ..lUid = uid
                ..sNick = nick
                ..sAvatarUrl = uid == 0 ? "" : "https://a/$uid.jpg"
                ..iPos = pos,
          ]
          ..vApply = [
            for (var (uid, nick) in apply)
              HuyaMultiVideoApplyInfo()
                ..lUid = uid
                ..sNick = nick,
          ])
        .toByteArray();

/// 语音房（1025601）：麦位和排队的人
List<int> meeting(List<(int, String, int)> seats, List<(int, String)> apply) =>
    (HuyaLiveMeetingSyncNotice()
          ..tStat = (HuyaMeetingStat()
            ..lPresenterUid = 100
            ..sPresenterNick = "主播"
            ..vApplyList = [
              for (var (uid, nick) in apply)
                HuyaMeetingApplyUser()
                  ..lUid = uid
                  ..sNick = nick,
            ])
          ..vSeats = [
            for (var (uid, nick, pos) in seats)
              HuyaMeetingSeat()
                ..iPos = pos
                ..lUid = uid
                ..sNick = nick,
          ])
        .toByteArray();

/// 测试用的虎牙连接：不联网，只解码
(HuyaDanmaku, List<LiveMessage>) huya({
  Duration link = const Duration(minutes: 1),
  Duration pkStale = const Duration(minutes: 1),
}) {
  var danmaku = HuyaDanmaku()
    ..linkMicStaleAfter = link
    ..pkStaleAfter = pkStale;
  danmaku.debugSetArgs(_room);
  addTearDown(danmaku.stop);
  var out = <LiveMessage>[];
  danmaku.onMessage = out.add;
  return (danmaku, out);
}

List<LiveLinkMicState> states(List<LiveMessage> out) => [
  for (var m in out)
    if (m.type == LiveMessageType.linkMic) m.data as LiveLinkMicState,
];

List<String> names(List<LiveLinkMicUser> users) => [
  for (var u in users) u.name,
];

// ---------------------------------------------------------------- Twitch

/// 一行 IRC：[room] 是本频道 id，[source] 是消息来自的频道 id（共享聊天）
String irc(
  String text, {
  String command = "PRIVMSG",
  String room = "100",
  String? source,
  String user = "viewer",
}) {
  var tags = [
    "badge-info=",
    "badges=",
    "color=#FF0000",
    "display-name=$user",
    "emotes=",
    "id=00000000-0000-0000-0000-${text.hashCode.abs()}",
    "room-id=$room",
    if (source != null) ...[
      "source-badge-info=",
      "source-badges=",
      "source-id=00000000-0000-0000-0000-000000000001",
      "source-room-id=$source",
    ],
    "tmi-sent-ts=1794503950000",
    "user-id=200000001",
  ].join(";");
  return "@$tags :$user!$user@$user.tmi.twitch.tv $command #channel :$text";
}

/// 测试用的名称查询：按 [names] 给，[calls] 记下每次请求的 id
class FakeLookup {
  final Map<String, LiveLinkMicUser?> names;
  final List<String> calls = [];
  final Map<String, Completer<LiveLinkMicUser?>> pending = {};
  final bool manual;
  FakeLookup(this.names, {this.manual = false});

  Future<LiveLinkMicUser?> call(String id) {
    calls.add(id);
    if (manual) {
      return (pending[id] = Completer<LiveLinkMicUser?>()).future;
    }
    return Future.value(names[id]);
  }

  void complete(String id) => pending[id]!.complete(names[id]);
}

(TwitchDanmaku, List<LiveMessage>) twitch(
  FakeLookup lookup, {
  Duration idle = const Duration(minutes: 5),
}) {
  var danmaku = TwitchDanmaku(channelLookup: lookup.call);
  danmaku.sharedChat.idle = idle;
  addTearDown(danmaku.stop);
  var out = <LiveMessage>[];
  danmaku.onMessage = out.add;
  return (danmaku, out);
}

List<String> chats(List<LiveMessage> out) => [
  for (var m in out)
    if (m.type == LiveMessageType.chat) "${m.userName}:${m.message}",
];

Future<void> settle() => Future.delayed(const Duration(milliseconds: 10));

void main() {
  group('虎牙 主播连麦（42008）', () {
    test('开始、重复推送、有人离开、结束', () {
      var (danmaku, out) = huya();
      var self = presenter(100, "本直播间", room: 1001, yy: 200);
      var a = presenter(300, "主播甲", room: 3003);
      var b = presenter(400, "主播乙", room: 4004);

      danmaku.decodeMessage(frame7(42008, linkMic([self, a, b])));
      var s = states(out);
      expect(s, hasLength(1));
      expect(s.single.kind, "连麦");
      expect(names(s.single.linked), ["主播甲", "主播乙"]);
      expect(s.single.linked.first.roomId, "3003");
      expect(
        s.single.linked.first.face,
        "https://huyaimg.msstatic.com/avatar/300.jpg",
      );
      expect(out.single.message, "连麦：主播甲、主播乙");
      expect(out.single.userName, "");

      // 每 20 秒重发一次，“live:”组的新版推送也有一份：都不重复发
      danmaku.decodeMessage(frame7(42008, linkMic([self, a, b])));
      danmaku.decodeMessage(
        frame22([
          (42008, linkMic([self, a, b])),
        ]),
      );
      expect(states(out), hasLength(1));

      danmaku.decodeMessage(frame7(42008, linkMic([self, a])));
      expect(names(states(out).last.linked), ["主播甲"]);

      danmaku.decodeMessage(frame7(42008, linkMic([self])));
      var end = states(out).last;
      expect(end.active, isFalse);
      expect(end.linked, isEmpty);
      expect(end.kind, "连麦");
      expect(out.last.message, "连麦结束");

      danmaku.decodeMessage(frame7(42008, linkMic([self])));
      danmaku.decodeMessage(frame7(42008, linkMic([])));
      expect(states(out), hasLength(3));
    });

    test('名单里的本直播间主播按 uid、YY 号、频道号认，都去掉', () {
      var (danmaku, out) = huya();
      // uid 对不上、YY 号对上
      var byYy = presenter(999, "本直播间", yy: 200);
      // 只有频道号对上
      var byChannel = presenter(0, "本直播间", channel: 100);
      var a = presenter(300, "主播甲");
      danmaku.decodeMessage(frame7(42008, linkMic([byYy, a, byChannel])));
      expect(names(states(out).single.linked), ["主播甲"]);
      // 没有直播间号时 roomId 为空，没有昵称时用 uid
      expect(states(out).single.linked.single.roomId, "");
      danmaku.decodeMessage(frame7(42008, linkMic([presenter(500, " ")])));
      expect(names(states(out).last.linked), ["500"]);
    });

    test('状态为 0 算结束', () {
      var (danmaku, out) = huya();
      var a = presenter(300, "主播甲");
      danmaku.decodeMessage(frame7(42008, linkMic([a])));
      danmaku.decodeMessage(frame7(42008, linkMic([a], status: 0)));
      expect(states(out).map((e) => e.active), [true, false]);
    });

    test('一段时间没再推送算结束，只发一次', () async {
      var (danmaku, out) = huya(link: const Duration(milliseconds: 150));
      danmaku.decodeMessage(frame7(42008, linkMic([presenter(300, "甲")])));
      await Future.delayed(const Duration(milliseconds: 60));
      // 重发会重新计时
      danmaku.decodeMessage(frame7(42008, linkMic([presenter(300, "甲")])));
      await Future.delayed(const Duration(milliseconds: 100));
      expect(states(out).map((e) => e.active), [true]);
      await Future.delayed(const Duration(milliseconds: 200));
      expect(states(out).map((e) => e.active), [true, false]);
      await Future.delayed(const Duration(milliseconds: 150));
      expect(states(out), hasLength(2));
    });
  });

  group('虎牙 PK（1090009）', () {
    test('两队里除了本直播间主播的人；PK 优先，PK 停了回到连麦', () async {
      var (danmaku, out) = huya(pkStale: const Duration(milliseconds: 80));
      var me = pkUser(100, "本直播间", 1001);
      var c = pkUser(500, "对手丙", 5005);
      var d = pkUser(600, "队友丁", 6006);

      danmaku.decodeMessage(
        frame22([
          (1090009, pk([me, d], [c])),
        ]),
      );
      var s = states(out).single;
      expect(s.kind, "PK");
      expect(names(s.linked), ["队友丁", "对手丙"]);
      expect(s.linked.last.roomId, "5005");
      expect(out.last.message, "PK：队友丁、对手丙");

      // 重复推送不重复发；同时有主播连麦时还是显示 PK
      danmaku.decodeMessage(
        frame22([
          (1090009, pk([me, d], [c])),
        ]),
      );
      danmaku.decodeMessage(
        frame7(42008, linkMic([presenter(100, "本直播间"), presenter(500, "对手丙")])),
      );
      expect(states(out), hasLength(1));

      // PK 面板不再推送：回到连麦（不发“结束”）
      await Future.delayed(const Duration(milliseconds: 200));
      var after = states(out);
      expect(after, hasLength(2));
      expect(after.last.kind, "连麦");
      expect(names(after.last.linked), ["对手丙"]);
    });

    test('只有本直播间主播的面板算结束', () {
      var (danmaku, out) = huya();
      var me = pkUser(100, "本直播间", 1001, yy: 200);
      danmaku.decodeMessage(
        frame22([
          (1090009, pk([me], [pkUser(5, "丙", 5)])),
        ]),
      );
      danmaku.decodeMessage(
        frame22([
          (1090009, pk([me], [])),
        ]),
      );
      expect(states(out).map((e) => e.active), [true, false]);
      expect(states(out).last.kind, "PK");
    });
  });

  group('虎牙 多人视频（2400001）、语音房（1025601）', () {
    test('多人连麦：座位按位置，排队的人有名字', () {
      var (danmaku, out) = huya();
      danmaku.decodeMessage(
        frame22([
          (
            2400001,
            multiVideo(
              [(100, "主播", 0), (11, "观众一", 2), (12, "观众二", 1), (0, "", 3)],
              [(21, "排队甲"), (22, "排队乙")],
            ),
          ),
        ]),
      );
      var s = states(out).single;
      expect(s.kind, "多人连麦");
      expect(names(s.linked), ["观众二", "观众一"]);
      expect(names(s.queue), ["排队甲", "排队乙"]);
      expect(s.waiting, 2);
      expect(s.linked.first.face, "https://a/12.jpg");

      // 排队变了也是变化
      danmaku.decodeMessage(
        frame7(
          2400001,
          multiVideo([(11, "观众一", 2), (12, "观众二", 1)], [(22, "排队乙")]),
        ),
      );
      expect(names(states(out).last.queue), ["排队乙"]);
      // 同样的再来一次不发
      danmaku.decodeMessage(
        frame7(
          2400001,
          multiVideo([(11, "观众一", 2), (12, "观众二", 1)], [(22, "排队乙")]),
        ),
      );
      expect(states(out), hasLength(2));

      // 座位上只剩主播：结束
      danmaku.decodeMessage(frame7(2400001, multiVideo([(100, "主播", 0)], [])));
      expect(states(out).last.active, isFalse);
      expect(states(out).last.kind, "多人连麦");
    });

    test('语音连麦：麦位上的人和排队的人', () {
      var (danmaku, out) = huya();
      danmaku.decodeMessage(
        frame7(
          1025601,
          meeting([(31, "麦上一", 1), (0, "", 2), (100, "主播", 0)], [(41, "排队丙")]),
        ),
      );
      var s = states(out).single;
      expect(s.kind, "语音连麦");
      expect(names(s.linked), ["麦上一"]);
      expect(names(s.queue), ["排队丙"]);
      expect(out.single.message, "语音连麦：麦上一");

      danmaku.decodeMessage(frame7(1025601, meeting([], [])));
      expect(states(out).map((e) => e.active), [true, false]);
    });
  });

  group('虎牙 解析不了、消息组、重置', () {
    test('坏数据不抛异常、不影响聊天和礼物', () async {
      var (danmaku, out) = huya();
      var garbage = [0x13, 0x00, 0xff, 0x09, 0x7f, 0x01];
      for (var uri in HuyaLinkMic.uris) {
        expect(
          () => danmaku.decodeMessage(frame7(uri, garbage)),
          returnsNormally,
        );
        expect(
          () => danmaku.decodeMessage(frame22([(uri, garbage)])),
          returnsNormally,
        );
        // 截断的推送
        var good = linkMic([presenter(300, "甲"), presenter(400, "乙")]);
        expect(
          () => danmaku.decodeMessage(
            frame7(uri, good.sublist(0, good.length ~/ 2)),
          ),
          returnsNormally,
        );
      }
      expect(() => danmaku.decodeMessage([22, 1, 2]), returnsNormally);
      expect(
        () => danmaku.decodeMessage([0x00, 0x16, 0x1d, 0x00, 0x05]),
        returnsNormally,
      );
      expect(() => danmaku.decodeMessage([]), returnsNormally);

      // 新版推送里有别的 uri（聊天）也不管，不会多出聊天
      danmaku.decodeMessage(
        frame22([(1400, chat('用户X', '不显示', '1')), (42008, garbage)]),
      );
      danmaku.decodeMessage(frame7(1400, chat('用户A', '你好', '2')));
      danmaku.decodeMessage(
        frame7(1400, chat('用户A', '你好', '2'), group: 'chat:100'),
      );
      danmaku.decodeMessage(frame7(42008, linkMic([presenter(300, "甲")])));
      danmaku.decodeMessage(
        frame7(1400, chat('用户B', '在吗', '3'), group: 'chat:100'),
      );

      var gift =
          (HuyaSendItemPacket()
                ..iItemType = 4
                ..iItemCount = 1
                ..lPresenterUid = 100
                ..lSenderUid = 9
                ..sSenderNick = '送礼人'
                ..sPropsName = '虎粮')
              .toByteArray();
      danmaku.decodeMessage(frame7(6501, gift, group: 'chat:100'));
      // “live:”组推来的聊天、礼物、在线人数不要（只读连麦）
      danmaku.decodeMessage(frame7(6501, gift, group: 'live:100'));
      danmaku.decodeMessage(
        frame7(1400, chat('用户C', '别处', '4'), group: 'live:100'),
      );
      danmaku.decodeMessage(
        frame7(
          8006,
          (TarsOutputStream()..write(5, 0)).toUint8List(),
          group: 'live:100',
        ),
      );
      danmaku.decodeMessage(
        frame7(8006, (TarsOutputStream()..write(7, 0)).toUint8List()),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      expect(
        [
          for (var m in out)
            if (m.type == LiveMessageType.chat) '${m.userName}:${m.message}',
        ],
        ['用户A:你好', '用户B:在吗'],
      );
      expect(out.where((e) => e.type == LiveMessageType.gift), hasLength(1));
      expect(
        out.where((e) => e.type == LiveMessageType.online).map((e) => e.data),
        [7],
      );
      expect(names(states(out).single.linked), ["甲"]);
    });

    test('订阅“live:”和“chat:”两个消息组；默认只有“chat:”', () {
      List<String> groups(List<int> data) {
        var stream = TarsInputStream(Uint8List.fromList(data));
        expect(stream.read(0, 0, false), 16);
        return (HuyaRegisterGroupReq()
              ..readFrom(TarsInputStream(stream.readBytes(1, false))))
            .vGroupId;
      }

      expect(
        groups(
          HuyaDanmaku.getRegisterGroupData(
            1,
            prefixes: HuyaDanmaku.kRoomGroups,
          ),
        ),
        ['live:1', 'chat:1'],
      );
      expect(groups(HuyaDanmaku.getRegisterGroupData(1)), ['chat:1']);
    });

    test('停止、换连接后状态重新开始，计时器不再发消息', () async {
      var (danmaku, out) = huya(link: const Duration(milliseconds: 60));
      var notice = frame7(42008, linkMic([presenter(300, "甲")]));
      danmaku.decodeMessage(notice);
      await danmaku.stop();
      danmaku.onMessage = out.add;
      await Future.delayed(const Duration(milliseconds: 120));
      // 停止后既不发“结束”，也不再处理
      danmaku.decodeMessage(notice);
      expect(states(out), hasLength(1));

      danmaku.debugSetArgs(_room);
      danmaku.decodeMessage(notice);
      expect(states(out).map((e) => e.active), [true, true]);
      await danmaku.stop();
    });
  });

  group('Twitch 共享聊天', () {
    // 不联网：第三方表情的请求都当作 404
    setUp(() {
      ThirdPartyEmotes.debugReset();
      ThirdPartyEmotes.debugGetJson = (url) async =>
          throw CoreError("offline", statusCode: 404);
    });
    tearDown(ThirdPartyEmotes.debugReset);

    test('别的频道的消息：先用 id，读到名称后再发一次；每个 id 只读一次', () async {
      var lookup = FakeLookup({
        "200": const LiveLinkMicUser(
          name: "Alice",
          face: "https://f/a.png",
          roomId: "alice",
        ),
        "300": const LiveLinkMicUser(name: "鲍勃(bob)", roomId: "bob"),
      }, manual: true);
      var (danmaku, out) = twitch(lookup);

      danmaku.handleLine(irc("hi from alice", source: "200", user: "a1"));
      var s = states(out);
      expect(s, hasLength(1));
      expect(s.single.kind, "共享聊天");
      expect(s.single.linked, [const LiveLinkMicUser(name: "200")]);
      // 聊天照常
      expect(chats(out), ["a1:hi from alice"]);

      // 同一个频道再来很多条：不重复发、不重复请求
      for (var i = 0; i < 50; i++) {
        danmaku.handleLine(irc("more $i", source: "200"));
      }
      expect(states(out), hasLength(1));
      expect(lookup.calls, ["200"]);

      lookup.complete("200");
      await settle();
      expect(states(out).last.linked, [
        const LiveLinkMicUser(
          name: "Alice",
          face: "https://f/a.png",
          roomId: "alice",
        ),
      ]);
      expect(out.last.message, "共享聊天：Alice");

      danmaku.handleLine(irc("yo", source: "300", command: "USERNOTICE"));
      expect(names(states(out).last.linked), ["Alice", "300"]);
      lookup.complete("300");
      await settle();
      expect(names(states(out).last.linked), ["Alice", "鲍勃(bob)"]);
      expect(states(out), hasLength(4));
      expect(lookup.calls, ["200", "300"]);
    });

    test('本频道的消息（没有 source-room-id 或和 room-id 相同）不算', () {
      var lookup = FakeLookup({});
      var (danmaku, out) = twitch(lookup);
      danmaku.handleLine(irc("plain"));
      danmaku.handleLine(irc("own in session", source: "100"));
      danmaku.handleLine(
        "@room-id=100;source-room-id=100 :tmi.twitch.tv USERNOTICE #channel :x",
      );
      expect(states(out), isEmpty);
      expect(lookup.calls, isEmpty);
      expect(chats(out), ["viewer:plain", "viewer:own in session"]);
    });

    test('一段时间没有别的频道的消息算结束，只发一次；有消息就一直算', () async {
      var lookup = FakeLookup({});
      var (danmaku, out) = twitch(
        lookup,
        idle: const Duration(milliseconds: 120),
      );
      for (var i = 0; i < 6; i++) {
        danmaku.handleLine(irc("tick $i", source: "200"));
        await Future.delayed(const Duration(milliseconds: 40));
      }
      expect(states(out).map((e) => e.active), [true]);
      await Future.delayed(const Duration(milliseconds: 250));
      var s = states(out);
      expect(s.map((e) => e.active), [true, false]);
      expect(s.last.kind, "共享聊天");
      expect(s.last.linked, isEmpty);
      expect(out.last.message, "连麦结束");
      await Future.delayed(const Duration(milliseconds: 200));
      expect(states(out), hasLength(2));

      // 又出现：重新开始；名称已经请求过（读不到）不再请求
      danmaku.handleLine(irc("again", source: "200"));
      expect(states(out).map((e) => e.active), [true, false, true]);
      expect(lookup.calls, ["200"]);
      await danmaku.stop();
    });

    test('名称在结束后才读到：不发；下次出现直接用名称', () async {
      var lookup = FakeLookup({
        "200": const LiveLinkMicUser(name: "Alice", roomId: "alice"),
      }, manual: true);
      var (danmaku, out) = twitch(
        lookup,
        idle: const Duration(milliseconds: 50),
      );
      danmaku.handleLine(irc("hi", source: "200"));
      await Future.delayed(const Duration(milliseconds: 150));
      expect(states(out).map((e) => e.active), [true, false]);
      lookup.complete("200");
      await settle();
      expect(states(out), hasLength(2));
      danmaku.handleLine(irc("back", source: "200"));
      expect(states(out).last.linked.single.name, "Alice");
      expect(lookup.calls, ["200"]);
      await danmaku.stop();
    });

    test('名称读不到、请求出错：一直用 id，不抛异常，不重试', () async {
      var calls = 0;
      var danmaku = TwitchDanmaku(
        channelLookup: (id) {
          calls++;
          if (id == "201") {
            throw StateError("sync failure");
          }
          return Future.error(Exception("network"));
        },
      );
      var out = <LiveMessage>[];
      danmaku.onMessage = out.add;
      danmaku.handleLine(irc("a", source: "200"));
      danmaku.handleLine(irc("b", source: "201"));
      danmaku.handleLine(irc("c", source: "200"));
      await settle();
      expect(names(states(out).last.linked), ["200", "201"]);
      expect(calls, 2);
      expect(chats(out), hasLength(3));
      await danmaku.stop();
    });

    test('坏标签、坏行不抛异常，聊天照常', () {
      var lookup = FakeLookup({});
      var (danmaku, out) = twitch(lookup);
      const noRoomId =
          "@source-room-id=200 :x!x@x.tmi.twitch.tv PRIVMSG #channel :no room id";
      // 还不知道本频道的 id 时，没有 room-id 的行认不出是不是别的频道
      danmaku.handleLine(noRoomId);
      var lines = [
        irc("bad id", source: "abc"),
        irc("empty id", source: ""),
        irc("too long", source: "1" * 40),
        irc("negative", source: "-5"),
        "@@@;;;==",
        "@source-room-id=200;room-id=100",
        ":only.prefix",
        "@source-room-id=200;room-id=100 :tmi.twitch.tv NOTICE #channel :not a chat",
      ];
      for (var line in lines) {
        expect(() => danmaku.handleLine(line), returnsNormally);
      }
      expect(states(out), isEmpty);
      expect(lookup.calls, isEmpty);
      expect(chats(out), hasLength(5));

      // 前面的行带了 room-id=100：没有 room-id 的行按本频道的 id 认
      danmaku.handleLine(noRoomId);
      expect(names(states(out).single.linked), ["200"]);
      expect(chats(out), hasLength(6));
    });

    test('上限：异常多的频道只认前 8 个', () {
      var lookup = FakeLookup({});
      var (danmaku, out) = twitch(lookup);
      for (var i = 0; i < 20; i++) {
        danmaku.handleLine(irc("x$i", source: "${1000 + i}"));
      }
      expect(states(out).last.linked, hasLength(TwitchSharedChat.kMaxChannels));
      expect(lookup.calls, hasLength(TwitchSharedChat.kMaxChannels));
    });

    test('停止后：迟到的名称、计时器都不再发消息；重新开始是新的状态', () async {
      var lookup = FakeLookup({
        "200": const LiveLinkMicUser(name: "Alice", roomId: "alice"),
      }, manual: true);
      var (danmaku, out) = twitch(
        lookup,
        idle: const Duration(milliseconds: 50),
      );
      danmaku.handleLine(irc("hi", source: "200"));
      expect(states(out), hasLength(1));
      await danmaku.stop();
      danmaku.onMessage = out.add;
      lookup.complete("200");
      await Future.delayed(const Duration(milliseconds: 150));
      expect(states(out), hasLength(1));
      expect(danmaku.sharedChat.state, LiveLinkMicState.none);

      // 新的连接：同一个频道重新开始（id 先当名称，重新请求一次名称）
      danmaku.handleLine(irc("hi again", source: "200"));
      expect(states(out).last.linked.single.name, "200");
      expect(lookup.calls, ["200", "200"]);
      await danmaku.stop();
    });

    test('TwitchSite.getChannelById：不是数字的 id 不请求', () async {
      var site = TwitchSite();
      expect(await site.getChannelById(""), isNull);
      expect(await site.getChannelById("abc"), isNull);
    });
  });
}
