import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/bilibili_link_mic.dart';
import 'package:simple_live_core/src/danmaku/douyu_link_mic.dart';
import 'package:test/test.dart';

const _biliRoom = "21452505";
const _douyuRoom = "24422";

/// 哔哩哔哩：按 BiliBiliDanmaku.parseMessage 的路径解析，收集发出的消息
class BiliRun {
  final out = <LiveMessage>[];
  late final BiliBiliDanmaku danmaku = BiliBiliDanmaku()
    ..onMessage = out.add
    ..linkMic.roomId = _biliRoom;

  void send(Map message) => danmaku.parseMessage(json.encode(message));

  void raw(String text) => danmaku.parseMessage(text);

  /// 发出的连麦状态，按顺序
  List<LiveLinkMicState> get states => [
    for (var m in out)
      if (m.type == LiveMessageType.linkMic) m.data as LiveLinkMicState,
  ];

  List<LiveMessage> get chats =>
      out.where((m) => m.type == LiveMessageType.chat).toList();
}

/// 斗鱼的 STT 编码：先转义 @ 再转义 /，嵌套的对象、数组整体转义一层
String sttEscape(String value) =>
    value.replaceAll("@", "@A").replaceAll("/", "@S");

String stt(dynamic value) {
  if (value is Map) {
    return value.entries
        .map((e) => "${e.key}@=${sttEscape(stt(e.value))}/")
        .join();
  }
  if (value is List) {
    return value.map((e) => "${sttEscape(stt(e))}/").join();
  }
  return value.toString();
}

/// 斗鱼：按 DouyuDanmaku 收到一帧的路径解析，收集发出的消息
class DouyuRun {
  final out = <LiveMessage>[];
  late final DouyuDanmaku danmaku = DouyuDanmaku()
    ..roomId = _douyuRoom
    ..onMessage = out.add;

  void send(Map message) => line(stt(message));

  void line(String text) => danmaku.decodeMessage(danmaku.serializeDouyu(text));

  List<LiveLinkMicState> get states => [
    for (var m in out)
      if (m.type == LiveMessageType.linkMic) m.data as LiveLinkMicState,
  ];

  List<LiveMessage> get chats =>
      out.where((m) => m.type == LiveMessageType.chat).toList();
}

Map<String, dynamic> multiConn(
  List<Map<String, dynamic>> members, {
  String cmd = "UNIVERSAL_EVENT_GIFT_V2",
  dynamic sessionStatus = 1,
}) => {
  "cmd": cmd,
  "data": {
    "business_label": "universal_multi_conn",
    "session_status": sessionStatus,
    "members": members,
  },
};

Map<String, dynamic> member(
  int uid,
  String name,
  dynamic roomId, {
  String display = "",
}) => {
  "uid": uid,
  "uname": name,
  "face": "http://i0.hdslb.com/bfs/face/$uid.jpg",
  "room_id": roomId,
  "display_name": display,
  "gift_info": {"score": 1200},
};

final _own = member(100, "本房的主播", int.parse(_biliRoom), display: "本房主播");
final _a = member(201, "主播甲", 30001, display: "1号位");
final _b = member(202, "主播乙", 30002, display: "2号位");

const _userA = LiveLinkMicUser(
  name: "主播甲",
  face: "https://i0.hdslb.com/bfs/face/201.jpg",
  roomId: "30001",
);
const _userB = LiveLinkMicUser(
  name: "主播乙",
  face: "https://i0.hdslb.com/bfs/face/202.jpg",
  roomId: "30002",
);

Map<String, dynamic> pkPre({int pkId = 9001}) => {
  "cmd": "PK_BATTLE_PRE_NEW",
  "pk_status": 101,
  "pk_id": pkId,
  "timestamp": 1731400000,
  "data": {
    "battle_type": 6,
    "match_type": 1,
    "uname": "对手主播",
    "face": "https://i1.hdslb.com/bfs/face/pk.jpg",
    "uid": 555,
    "room_id": 40001,
    "season_id": 70,
    "pre_timer": 10,
    "pk_votes_name": "PK值",
    "end_win_task": null,
  },
  "roomid": int.parse(_biliRoom),
};

const _pkUser = LiveLinkMicUser(
  name: "对手主播",
  face: "https://i1.hdslb.com/bfs/face/pk.jpg",
  roomId: "40001",
);

Map<String, dynamic> danmu(String text) => {
  "cmd": "DANMU_MSG",
  "info": [
    [],
    text,
    [1, "观众"],
  ],
};

const _douyuAvatar = "https://apic.douyucdn.cn/upload/avatar_v3/202311/";

Map<String, dynamic> dyMember(String rid, String name, String icon) => {
  "rid": rid,
  "uid": "9$rid",
  "nickname": name,
  "icon": icon,
  "team": "1",
};

void main() {
  group('哔哩哔哩 多人连线（UNIVERSAL_EVENT_GIFT_V2）', () {
    test('开始：名单里去掉本房主播', () {
      var run = BiliRun()..send(multiConn([_own, _a, _b]));
      expect(run.states, [
        const LiveLinkMicState(kind: "多人连线", linked: [_userA, _userB]),
      ]);
      expect(run.out.single.message, "多人连线：主播甲、主播乙");
      expect(run.out.single.userName, "");
    });

    test('同样的名单不重复发，有人离开时发新的完整名单', () {
      var run = BiliRun()
        ..send(multiConn([_own, _a, _b]))
        ..send(multiConn([_own, _a, _b]))
        ..send(multiConn([_b, _own, _a]))
        ..send(multiConn([_own, _a]));
      expect(run.states, [
        const LiveLinkMicState(kind: "多人连线", linked: [_userA, _userB]),
        const LiveLinkMicState(kind: "多人连线", linked: [_userB, _userA]),
        const LiveLinkMicState(kind: "多人连线", linked: [_userA]),
      ]);
    });

    test('房间号是本房间的也去掉（没有“本房主播”标记时）', () {
      var self = member(100, "本房的主播", _biliRoom);
      var run = BiliRun()..send(multiConn([self, _a]));
      expect(run.states.single.linked, [_userA]);
    });

    test('名单为空或 session_status 为 0 时结束', () {
      var run = BiliRun()
        ..send(multiConn([_own, _a]))
        ..send(multiConn([]))
        ..send(multiConn([]));
      expect(run.states, [
        const LiveLinkMicState(kind: "多人连线", linked: [_userA]),
        const LiveLinkMicState(kind: "多人连线"),
      ]);
      expect(run.out.last.message, "连麦结束");

      var run2 = BiliRun()
        ..send(multiConn([_own, _a]))
        ..send(multiConn([_own, _a], sessionStatus: 0));
      expect(run2.states.last.linked, isEmpty);
    });

    test('只剩本房主播时也算结束', () {
      var run = BiliRun()
        ..send(multiConn([_own, _a]))
        ..send(multiConn([_own]));
      expect(run.states.last, const LiveLinkMicState(kind: "多人连线"));
    });

    test('旧版 UNIVERSAL_EVENT_GIFT：名单在 data.info 里，cmd 带后缀', () {
      var run = BiliRun()
        ..send({
          "cmd": "UNIVERSAL_EVENT_GIFT:1",
          "data": {
            "info": {
              "business_label": "universal_multi_conn",
              "members": [_own, _b],
            },
          },
        });
      expect(run.states.single.linked, [_userB]);
    });

    test('data 是 json 字符串时也能读', () {
      var message = multiConn([_own, _a]);
      message["data"] = json.encode(message["data"]);
      var run = BiliRun()..send(message);
      expect(run.states.single.linked, [_userA]);
    });

    test('别的活动（business_label 不是连线）不管', () {
      var run = BiliRun()
        ..send({
          "cmd": "UNIVERSAL_EVENT_GIFT_V2",
          "data": {
            "business_label": "universal_gift_battle",
            "members": [_a, _b],
          },
        });
      expect(run.states, isEmpty);
    });
  });

  group('哔哩哔哩 PK', () {
    test('PK_BATTLE_PRE_NEW 开始，START 不变，SETTLE 结束', () {
      var run = BiliRun()
        ..send(pkPre())
        ..send({
          "cmd": "PK_BATTLE_START_NEW",
          "pk_id": 9001,
          "pk_status": 201,
          "data": {"battle_type": 6, "pk_votes_name": "PK值"},
          "roomid": _biliRoom,
        })
        ..send({"cmd": "PK_BATTLE_END", "pk_id": "9001", "data": {}})
        ..send({
          "cmd": "PK_BATTLE_SETTLE_V2",
          "pk_id": 9001,
          "data": {"pk_id": 9001},
        });
      expect(run.states, [
        const LiveLinkMicState(kind: "PK", linked: [_pkUser]),
        const LiveLinkMicState(kind: "PK"),
      ]);
    });

    test('别的 pk_id 的结束消息不管', () {
      var run = BiliRun()
        ..send(pkPre(pkId: 9002))
        ..send({"cmd": "PK_BATTLE_END", "pk_id": 9001, "data": {}});
      expect(run.states, [
        const LiveLinkMicState(kind: "PK", linked: [_pkUser]),
      ]);
      run.send({"cmd": "PK_BATTLE_SETTLE_NEW", "pk_id": 9002, "data": {}});
      expect(run.states.last.linked, isEmpty);
    });

    test('PK 和多人连线同时进行：方式是 PK，名单不重复', () {
      var pk = pkPre();
      (pk["data"] as Map)["room_id"] = 30001;
      (pk["data"] as Map)["uname"] = "主播甲";
      var run = BiliRun()
        ..send(multiConn([_own, _a, _b]))
        ..send(pk);
      expect(run.states.last.kind, "PK");
      expect(run.states.last.linked.map((e) => e.roomId), ["30001", "30002"]);
    });

    test('对手是本房间时不算', () {
      var pk = pkPre();
      (pk["data"] as Map)["room_id"] = int.parse(_biliRoom);
      var run = BiliRun()..send(pk);
      expect(run.states, isEmpty);
    });
  });

  group('哔哩哔哩 视频连线', () {
    test('JOIN_START 开始，JOIN_END 结束', () {
      var run = BiliRun()
        ..send({
          "cmd": "VIDEO_CONNECTION_JOIN_START",
          "data": {
            "status": 1,
            "invited_uid": 777,
            "channel_id": "ch-1",
            "invited_uname": "连线嘉宾",
            "invited_face": "//i2.hdslb.com/bfs/face/v.jpg",
            "start_at": 1731400000,
            "current_time": 1731400001,
          },
          "roomid": int.parse(_biliRoom),
        })
        ..send({
          "cmd": "VIDEO_CONNECTION_JOIN_END",
          "data": {
            "channel_id": "ch-1",
            "start_at": 1731400000,
            "toast": "连线已结束",
            "current_time": 1731400300,
          },
          "roomid": int.parse(_biliRoom),
        });
      expect(run.states, [
        const LiveLinkMicState(
          kind: "视频连线",
          linked: [
            LiveLinkMicUser(
              name: "连线嘉宾",
              face: "https://i2.hdslb.com/bfs/face/v.jpg",
            ),
          ],
        ),
        const LiveLinkMicState(kind: "视频连线"),
      ]);
    });

    test('VIDEO_CONNECTION_START 带房间号；本房间的不算', () {
      var run = BiliRun()
        ..send({
          "cmd": "VIDEO_CONNECTION_START",
          "data": {"uid": 100, "uname": "本房的主播", "room_id": _biliRoom},
        })
        ..send({
          "cmd": "VIDEO_CONNECTION_START",
          "data": {"uid": 301, "uname": "隔壁主播", "face": "", "room_id": 50001},
        });
      expect(run.states, [
        const LiveLinkMicState(
          kind: "视频连线",
          linked: [LiveLinkMicUser(name: "隔壁主播", roomId: "50001")],
        ),
      ]);
    });
  });

  group('哔哩哔哩 语音连麦', () {
    Map<String, dynamic> status(int status, int uid, String name) => {
      "cmd": "VOICE_JOIN_STATUS",
      "data": {
        "room_id": int.parse(_biliRoom),
        "status": status,
        "channel": "voice-1",
        "channel_type": "voice",
        "uid": uid,
        "user_name": name,
        "head_pic": "http://i0.hdslb.com/bfs/face/u$uid.jpg",
        "guard": 3,
        "start_at": 1731400000,
        "current_time": 1731400001,
        "web_share_link": "",
      },
    };
    Map<String, dynamic> count(String cmd, int n) => {
      "cmd": cmd,
      "data": {
        "room_id": int.parse(_biliRoom),
        "root_status": 1,
        "room_status": 1,
        "apply_count": n,
        "notify_count": 0,
        "red_point": 0,
      },
    };
    const guest = LiveLinkMicUser(
      name: "观众丙",
      face: "https://i0.hdslb.com/bfs/face/u42.jpg",
    );

    test('排队人数、连上、断开、关闭连麦', () {
      var run = BiliRun()
        ..send(count("VOICE_JOIN_ROOM_COUNT_INFO", 3))
        ..send(status(1, 42, "观众丙"))
        ..send(count("VOICE_JOIN_ROOM_COUNT_INFO", 3))
        ..send(count("VOICE_JOIN_LIST", 2))
        ..send(status(0, 42, "观众丙"))
        ..send({
          "cmd": "VOICE_JOIN_SWITCH",
          "data": {"room_id": _biliRoom, "root_status": 1, "room_status": 0},
        });
      expect(run.states, [
        const LiveLinkMicState(kind: "语音连麦", queueCount: 3),
        const LiveLinkMicState(kind: "语音连麦", linked: [guest], queueCount: 3),
        const LiveLinkMicState(kind: "语音连麦", linked: [guest], queueCount: 2),
        const LiveLinkMicState(kind: "语音连麦", queueCount: 2),
        const LiveLinkMicState(kind: "语音连麦"),
      ]);
      expect(run.states.first.waiting, 3);
    });

    test('多人语音：排队人数和麦上的人，空位不算', () {
      var run = BiliRun()
        ..send({
          "cmd": "MULTI_VOICE_APPLICATION_USER",
          "data": {"room_id": _biliRoom, "count": 4},
        })
        ..send({
          "cmd": "MULTI_VOICE_PK_STATUS",
          "data": {
            "positions": [
              {"position": 1, "uid": 61, "nickname": "麦上甲", "avatar": ""},
              {"position": 2, "uid": 0, "nickname": "", "avatar": ""},
              {
                "position": 3,
                "uid": 62,
                "nickname": "麦上乙",
                "avatar": "https://i0.hdslb.com/bfs/face/62.jpg",
              },
            ],
          },
        })
        ..send({
          "cmd": "MULTI_VOICE_PK_STATUS",
          "data": {"positions": []},
        });
      expect(run.states, [
        const LiveLinkMicState(kind: "语音连麦", queueCount: 4),
        const LiveLinkMicState(
          kind: "语音连麦",
          linked: [
            LiveLinkMicUser(name: "麦上甲"),
            LiveLinkMicUser(
              name: "麦上乙",
              face: "https://i0.hdslb.com/bfs/face/62.jpg",
            ),
          ],
          queueCount: 4,
        ),
        const LiveLinkMicState(kind: "语音连麦", queueCount: 4),
      ]);
    });

    test('从多人连线认出的本房主播 uid 不进麦上名单', () {
      var run = BiliRun()
        ..send(multiConn([_own, _a]))
        ..send(multiConn([]))
        ..send({
          "cmd": "MULTI_VOICE_PK_STATUS",
          "data": {
            "positions": [
              {"uid": 100, "nickname": "本房的主播"},
              {"uid": 63, "nickname": "麦上丙"},
            ],
          },
        });
      expect(run.states.last.linked, [const LiveLinkMicUser(name: "麦上丙")]);
    });
  });

  group('哔哩哔哩 异常输入', () {
    test('格式不对的连麦消息不抛异常、不发消息，也不影响后面的聊天', () {
      var run = BiliRun();
      var bad = <dynamic>[
        {"cmd": "UNIVERSAL_EVENT_GIFT_V2"},
        {"cmd": "UNIVERSAL_EVENT_GIFT_V2", "data": "garbage"},
        {"cmd": "UNIVERSAL_EVENT_GIFT_V2", "data": "{broken"},
        {
          "cmd": "UNIVERSAL_EVENT_GIFT_V2",
          "data": {"business_label": "universal_multi_conn", "members": "x"},
        },
        {
          "cmd": "UNIVERSAL_EVENT_GIFT_V2",
          "data": {
            "business_label": "universal_multi_conn",
            "members": [1, null, "a", [], {}],
          },
        },
        {"cmd": "PK_BATTLE_PRE_NEW", "data": []},
        {
          "cmd": "PK_BATTLE_PRE_NEW",
          "data": {"uname": "", "room_id": {}},
        },
        {"cmd": "PK_BATTLE_END"},
        {"cmd": "VIDEO_CONNECTION_JOIN_START", "data": null},
        {
          "cmd": "VOICE_JOIN_STATUS",
          "data": {"status": "x"},
        },
        {"cmd": "VOICE_JOIN_STATUS", "data": 5},
        {
          "cmd": "VOICE_JOIN_ROOM_COUNT_INFO",
          "data": {"apply_count": "?"},
        },
        {
          "cmd": "VOICE_JOIN_SWITCH",
          "data": {"room_status": 1},
        },
        {
          "cmd": "MULTI_VOICE_APPLICATION_USER",
          "data": {"count": []},
        },
        {
          "cmd": "MULTI_VOICE_PK_STATUS",
          "data": {"positions": "x"},
        },
        {
          "cmd": "MULTI_VOICE_PK_STATUS",
          "data": {
            "positions": [null, 3],
          },
        },
        {"cmd": 12},
        {"cmd": null},
      ];
      for (var m in bad) {
        expect(() => run.send(m as Map), returnsNormally);
      }
      expect(() => run.raw("[1,2,3]"), returnsNormally);
      expect(() => run.raw("{not json"), returnsNormally);
      expect(run.states, isEmpty);
      run.send(danmu("还在吗"));
      expect(run.chats.single.message, "还在吗");
      // 之后正常的消息照样处理
      run.send(multiConn([_own, _a]));
      expect(run.states.last.linked.last, _userA);
    });

    test('tracker 直接收到非对象、不认识的 cmd 时返回 null', () {
      var tracker = BiliLinkMic(roomId: _biliRoom);
      expect(tracker.handle(null), isNull);
      expect(tracker.handle("x"), isNull);
      expect(tracker.handle({"cmd": "SEND_GIFT", "data": {}}), isNull);
      expect(BiliLinkMic.handles("PK_BATTLE_PRE_NEW:2"), isTrue);
      expect(BiliLinkMic.handles("DANMU_MSG"), isFalse);
    });

    test('stop 清空状态，同样的名单再来时重新发', () async {
      var run = BiliRun()..send(multiConn([_own, _a]));
      expect(run.danmaku.linkMic.state.active, isTrue);
      await run.danmaku.stop();
      expect(run.danmaku.linkMic.state, LiveLinkMicState.none);
      expect(run.danmaku.linkMic.roomId, _biliRoom);
      run.danmaku.onMessage = run.out.add;
      run.send(multiConn([_own, _a]));
      expect(run.states.length, 2);
    });
  });

  group('斗鱼 多人 PK（mapkb）', () {
    test('开始：名单是 STT 编码的数组，去掉本房间', () {
      var run = DouyuRun()
        ..send({
          "type": "mapkb",
          "cmd": "1",
          "pkid": "77",
          "members": [
            dyMember(_douyuRoom, "本房主播", "avatar_v3/202311/own"),
            dyMember("5001", "斗鱼甲", "avatar_v3/202311/aaa"),
            dyMember("5002", "斗鱼乙", "avatar_v3/202311/bbb"),
          ],
        });
      expect(run.states, [
        const LiveLinkMicState(
          kind: "PK",
          linked: [
            LiveLinkMicUser(
              name: "斗鱼甲",
              face: "${_douyuAvatar}aaa_middle.jpg",
              roomId: "5001",
            ),
            LiveLinkMicUser(
              name: "斗鱼乙",
              face: "${_douyuAvatar}bbb_middle.jpg",
              roomId: "5002",
            ),
          ],
        ),
      ]);
      expect(run.out.single.message, "PK：斗鱼甲、斗鱼乙");
    });

    test('进行中、出结果不重复发，没有名单的消息不变，5/6 结束', () {
      var members = [
        dyMember(_douyuRoom, "本房主播", ""),
        dyMember("5001", "斗鱼甲", "avatar_v3/202311/aaa"),
      ];
      var run = DouyuRun()
        ..send({"type": "mapkb", "cmd": "1", "members": members})
        ..send({"type": "mapkb", "cmd": "3", "members": members})
        ..send({"type": "mapkb", "cmd": "3", "score": "120"})
        ..send({"type": "mapkb", "cmd": "4", "members": members})
        ..send({"type": "mapkb", "cmd": "5"})
        ..send({"type": "mapkb", "cmd": "6"});
      expect(run.states, [
        const LiveLinkMicState(
          kind: "PK",
          linked: [
            LiveLinkMicUser(
              name: "斗鱼甲",
              face: "${_douyuAvatar}aaa_middle.jpg",
              roomId: "5001",
            ),
          ],
        ),
        const LiveLinkMicState(kind: "PK"),
      ]);
      expect(run.out.last.message, "连麦结束");
    });

    test('nick 字段、完整的头像地址、名字里带 / 和 @', () {
      var run = DouyuRun()
        ..send({
          "type": "mapkb",
          "cmd": "1",
          "members": [
            {
              "rid": "5003",
              "uid": "1",
              "nick": "a/b@c",
              "icon": "https://apic.douyucdn.cn/upload/avatar/x_middle.jpg",
            },
            {"rid": "5004", "uid": "2", "nickname": "无头像", "icon": ""},
          ],
        });
      expect(run.states.single.linked, [
        const LiveLinkMicUser(
          name: "a/b@c",
          face: "https://apic.douyucdn.cn/upload/avatar/x_middle.jpg",
          roomId: "5003",
        ),
        const LiveLinkMicUser(name: "无头像", roomId: "5004"),
      ]);
    });
  });

  group('斗鱼 1v1 连麦 PK（nlkstatus）', () {
    Map<String, dynamic> nlk(
      int status, {
      String pkId = "pk-1",
      String rida = _douyuRoom,
      String ridb = "6001",
      bool info = true,
    }) => {
      "type": "nlkstatus",
      "pkId": pkId,
      "status": "$status",
      "rida": rida,
      "ridb": ridb,
      if (info) "ridainfo": {"nn": "本房主播", "avt": "avatar_v3/202311/own"},
      if (info) "ridbinfo": {"nn": "对面主播", "avt": "avatar_v3/202311/ccc"},
    };
    const partner = LiveLinkMicUser(
      name: "对面主播",
      face: "${_douyuAvatar}ccc_middle.jpg",
      roomId: "6001",
    );

    test('开始、进行中、别的 pkId 结束不管、status 3 结束', () {
      var run = DouyuRun()
        ..send(nlk(1))
        ..send(nlk(2))
        ..send({
          "type": "nlkdoing",
          "pkId": "pk-1",
          "rida": _douyuRoom,
          "ridb": "6001",
          "scorea": "10",
          "scoreb": "20",
        })
        ..send(nlk(3, pkId: "pk-0"))
        ..send(nlk(3));
      expect(run.states, [
        const LiveLinkMicState(kind: "PK", linked: [partner]),
        const LiveLinkMicState(kind: "PK"),
      ]);
    });

    test('本房间在 ridb 时对手取 ridainfo', () {
      var run = DouyuRun()
        ..send({
          "type": "nlkstatus",
          "pkId": "pk-2",
          "status": "1",
          "rida": "6002",
          "ridb": _douyuRoom,
          "ridainfo": {"nn": "左边主播", "avt": "avatar_v3/202311/ddd"},
          "ridbinfo": {"nn": "本房主播", "avt": ""},
        });
      expect(run.states.single.linked, [
        const LiveLinkMicUser(
          name: "左边主播",
          face: "${_douyuAvatar}ddd_middle.jpg",
          roomId: "6002",
        ),
      ]);
    });

    test('没有对手信息时用房间号代替；两边都不是本房间时不管', () {
      var run = DouyuRun()
        ..send(nlk(1, rida: "7001", ridb: "7002"))
        ..send(nlk(1, info: false));
      expect(run.states, [
        const LiveLinkMicState(
          kind: "PK",
          linked: [LiveLinkMicUser(name: "直播间 6001", roomId: "6001")],
        ),
      ]);
    });

    test('多人 PK 和 1v1 同时：合在一起，同一个房间不重复', () {
      var run = DouyuRun()
        ..send({
          "type": "mapkb",
          "cmd": "1",
          "members": [
            dyMember(_douyuRoom, "本房主播", ""),
            dyMember("6001", "对面主播", "avatar_v3/202311/ccc"),
            dyMember("5001", "斗鱼甲", ""),
          ],
        })
        ..send(nlk(1));
      expect(run.states.length, 1);
      expect(run.states.single.linked.map((e) => e.roomId), ["6001", "5001"]);
    });
  });

  group('斗鱼 异常输入', () {
    test('格式不对的不抛异常、不发消息，也不影响后面的聊天', () {
      var run = DouyuRun();
      var lines = [
        "type@=mapkb/",
        "type@=mapkb/cmd@=1/members@=garbage/",
        "type@=mapkb/cmd@=1/members@=a@AA@AAb/",
        "type@=mapkb/cmd@=x/members@=/",
        "type@=nlkstatus/",
        "type@=nlkstatus/status@=1/rida@=$_douyuRoom/",
        "type@=nlkstatus/status@=1/rida@=$_douyuRoom/ridb@=$_douyuRoom/",
        "type@=nlkdoing/rida@=@A@S/ridb@=/",
        "type@=nlkfoo/pkId@=1/",
      ];
      for (var line in lines) {
        expect(() => run.line(line), returnsNormally);
      }
      expect(run.states, isEmpty);
      run.line(
        "type@=chatmsg/rid@=$_douyuRoom/uid@=1/nn@=观众/txt@=还在吗/"
        "level@=5/dms@=3/",
      );
      expect(run.chats.single.message, "还在吗");
    });

    test('tracker 直接收到非对象、不认识的类型时返回 null', () {
      var tracker = DouyuLinkMic(roomId: _douyuRoom);
      expect(tracker.handle(null), isNull);
      expect(tracker.handle({"type": "chatmsg"}), isNull);
      expect(
        tracker.handle({"type": "mapkb", "cmd": "1", "members": 3}),
        isNull,
      );
      expect(DouyuLinkMic.handles("nlkstatus"), isTrue);
      expect(DouyuLinkMic.handles("dgb"), isFalse);
    });

    test('stop 清空状态', () async {
      var run = DouyuRun()
        ..send({
          "type": "mapkb",
          "cmd": "1",
          "members": [dyMember("5001", "斗鱼甲", "")],
        });
      expect(run.states.single.linked.single.roomId, "5001");
      await run.danmaku.stop();
      expect(run.danmaku.linkMic.state, LiveLinkMicState.none);
    });
  });
}
