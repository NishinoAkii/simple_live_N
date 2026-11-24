import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/proto/douyin.pb.dart';
import 'package:simple_live_core/src/model/tars/huya_danmaku.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';
import 'package:test/test.dart';

const _dir = 'test/fixtures/badges';

/// 实抓的虎牙聊天（整帧，发言人已替换），顺序见 huya_chat.txt
List<List<int>> huyaFrames() => File('$_dir/huya_chat.txt')
    .readAsLinesSync()
    .where((e) => e.trim().isNotEmpty && !e.startsWith('#'))
    .map((e) => base64.decode(e.trim()))
    .toList();

/// 实抓的抖音聊天（只留了身份字段，发言人已替换）：类别 → ChatMessage
Map<String, ChatMessage> douyinChats() => {
  for (var line in File('$_dir/douyin_chat.txt').readAsLinesSync())
    if (line.trim().isNotEmpty && !line.startsWith('#'))
      line.split(' ')[0]: ChatMessage.fromBuffer(
        base64.decode(line.split(' ')[1].trim()),
      ),
};

/// 服务器推送的一帧（命令 7，uri 1400 是聊天）
List<int> huyaFrame(List<int> msg) {
  var push = TarsOutputStream();
  push.write(3, 0);
  push.write(1400, 1);
  push.write(Uint8List.fromList(msg), 2);
  push.write(0, 3);
  var cmd = TarsOutputStream();
  cmd.write(7, 0);
  cmd.write(push.toUint8List(), 1);
  return cmd.toUint8List();
}

Uint8List tarsBody(TarsStruct struct) {
  var os = TarsOutputStream();
  struct.writeTo(os);
  return os.toUint8List();
}

HuyaDecorationInfo deco(int appId, List<int> data, {int viewType = 0}) =>
    HuyaDecorationInfo()
      ..iAppId = appId
      ..iViewType = viewType
      ..vData = Uint8List.fromList(data);

/// 一帧聊天里主播的 uid（MessageNotice 的 tag 11 lPid）
int _presenterUid(List<int> frame) {
  var cmd = TarsInputStream(Uint8List.fromList(frame));
  var push = HYPushMessage()
    ..readFrom(TarsInputStream(cmd.readBytes(1, false)));
  return TarsInputStream(Uint8List.fromList(push.msg)).readInt(11, true);
}

/// 一条虎牙聊天（MessageNotice）：tag 0 发送人（含贵族）、3 内容、8/9 装饰、20 id
List<int> huyaNotice({
  String nick = '测试',
  String content = '你好',
  String id = '1',
  int nobleLevel = 0,
  int nobleInfoLevel = 0,
  List<HuyaDecorationInfo> prefix = const [],
  List<HuyaDecorationInfo> suffix = const [],
}) {
  var os = TarsOutputStream();
  os.writeHead(TarsStructType.STRUCT_BEGIN.index, 0);
  os.write(10001, 0);
  os.write(nick, 2);
  os.write(nobleLevel, 5);
  os.write(HuyaNobleLevelInfo()..iNobleLevel = nobleInfoLevel, 6);
  os.writeHead(TarsStructType.STRUCT_END.index, 0);
  os.write(content, 3);
  os.write(prefix, 8);
  os.write(suffix, 9);
  os.write(id, 20);
  return os.toUint8List();
}

List<int> pushFrame(List<Message> messages) {
  var response = Response()..messagesList.addAll(messages);
  return (PushFrame()
        ..payloadType = "msg"
        ..payload = gzip.encode(response.writeToBuffer()))
      .writeToBuffer();
}

Image badgeImage(int type, {String url = '', String name = '', int? level}) =>
    Image()
      ..imageType = type
      ..urlListList.addAll([if (url.isNotEmpty) url])
      ..content = (ImageContent()
        ..name = name
        ..level = Int64(level ?? 0)
        ..alternativeText = type == 3 ? '房管勋章' : '');

void main() {
  setUpAll(() => CoreLog.enableLog = false);

  group('虎牙聊天的身份（实抓）', () {
    late List<LiveMessage> chats;
    setUpAll(() {
      var danmaku = HuyaDanmaku();
      chats = [];
      danmaku.onMessage = chats.add;
      for (var frame in huyaFrames()) {
        danmaku.decodeMessage(frame);
      }
    });

    test('五条都照常出来，昵称是替换后的', () {
      expect(chats.map((e) => e.type).toSet(), {LiveMessageType.chat});
      expect(chats.map((e) => e.userName), [
        '测试用户1',
        '测试用户2',
        '测试用户3',
        '测试用户4',
        '测试用户5',
      ]);
    });

    test('粉丝牌、贵族、消费等级，按装饰的顺序', () {
      expect(chats[0].message, '这盾狗牛逼');
      expect(chats[0].badges, const [
        LiveBadge(LiveBadgeKind.level, '等级', level: 19),
        // 没有主播名，lBadgeId 是主播的 uid
        LiveBadge(LiveBadgeKind.medal, '楚河', level: 20, ownerUid: '294636272'),
        LiveBadge(LiveBadgeKind.noble, '剑士', level: 1),
      ]);
    });

    test('没有装饰的普通聊天没有身份', () {
      expect(chats[1].message, '拿下拿下');
      expect(chats[1].badges, isNull);
    });

    test('房管、公会管理带图标；后缀里的钻粉图标不当粉丝牌', () {
      expect(chats[2].badges, const [
        LiveBadge(LiveBadgeKind.level, '等级', level: 24),
        LiveBadge(
          LiveBadgeKind.medal,
          '林yn',
          level: 36,
          ownerUid: '2210112017',
        ),
        LiveBadge(
          LiveBadgeKind.admin,
          '公会管理',
          icon: 'https://livewebbs2.msstatic.com/newgonghuifangguan.png',
        ),
        LiveBadge(
          LiveBadgeKind.admin,
          '房管',
          icon: 'https://livewebbs2.msstatic.com/newfangguan.png',
        ),
        LiveBadge(LiveBadgeKind.noble, '公爵', level: 4),
      ]);
    });

    test('主播本人', () {
      expect(chats[3].badges, const [
        LiveBadge(LiveBadgeKind.level, '等级', level: 13),
        LiveBadge(LiveBadgeKind.broadcaster, '主播', color: 0xFF6600),
      ]);
    });

    test('连麦转来的消息没有贵族装饰，用发送人的贵族等级', () {
      expect(chats[4].badges, const [
        LiveBadge(LiveBadgeKind.level, '等级', level: 42),
        LiveBadge(LiveBadgeKind.noble, '公爵', level: 4),
      ]);
    });

    test('直播间自己的粉丝牌：lBadgeId 和推送里主播的 uid（lPid）一样', () {
      // 两条带粉丝牌的聊天都是在牌子主播的直播间里抓的
      var owners = [
        for (var chat in chats)
          for (var badge in chat.badges ?? const <LiveBadge>[])
            if (badge.kind == LiveBadgeKind.medal) badge.ownerUid,
      ];
      var presenters = [
        for (var i in [0, 2]) '${_presenterUid(huyaFrames()[i])}',
      ];
      expect(owners, ['294636272', '2210112017']);
      expect(owners, presenters);
    });

    test('身份会写进 toString 的 JSON', () {
      var map = json.decode(chats[0].toString()) as Map;
      expect(map['badges'], [
        {'k': 'level', 't': '等级', 'l': 19},
        {'k': 'medal', 't': '楚河', 'l': 20, 'u': '294636272'},
        {'k': 'noble', 't': '剑士', 'l': 1},
      ]);
    });
  });

  group('虎牙聊天的身份（构造）', () {
    test('粉丝牌加贵族装饰', () {
      var badges = parseHuyaChatBadges(
        huyaNotice(
          nobleLevel: 5,
          nobleInfoLevel: 5,
          prefix: [
            deco(
              10400,
              tarsBody(
                HuyaBadgeInfo()
                  ..lBadgeId = 1
                  ..sBadgeName = '测试牌'
                  ..iBadgeLevel = 11,
              ),
            ),
            deco(
              10200,
              tarsBody(
                HuyaNobleBase()
                  ..iLevel = 5
                  ..tLevelInfo = (HuyaNobleLevelInfo()..iNobleLevel = 5),
              ),
            ),
          ],
        ),
      );
      expect(badges, const [
        LiveBadge(LiveBadgeKind.medal, '测试牌', level: 11, ownerUid: '1'),
        LiveBadge(LiveBadgeKind.noble, '君王', level: 5),
      ]);
    });

    test('粉丝牌是谁的：主播名、主播的 uid，空的和 0 没有；信仰牌不算某个主播的', () {
      LiveBadge medal(HuyaBadgeInfo info) => parseHuyaChatBadges(
        huyaNotice(
          prefix: [
            deco(
              10400,
              tarsBody(
                info
                  ..sBadgeName = '测试牌'
                  ..iBadgeLevel = 11,
              ),
            ),
          ],
        ),
      )!.single;
      var full = medal(
        HuyaBadgeInfo()
          ..lBadgeId = 1259527100648
          ..sPresenterNickName = ' 主播丙 ',
      );
      expect(full.ownerName, '主播丙');
      expect(full.ownerUid, '1259527100648');
      expect(full.ownerRoomId, isNull);
      var none = medal(HuyaBadgeInfo());
      expect(none.level, 11);
      expect(none.hasOwner, isFalse);
      var faith = medal(
        HuyaBadgeInfo()
          ..lBadgeId = 1259527100648
          ..iBadgeType = 1,
      );
      expect(faith.text, '测试牌');
      expect(faith.hasOwner, isFalse);
    });

    test('贵族装饰里有名称时用它，没有装饰时按等级取名', () {
      var named = parseHuyaChatBadges(
        huyaNotice(
          prefix: [
            deco(
              10200,
              tarsBody(
                HuyaNobleBase()
                  ..iLevel = 6
                  ..sName = '帝皇',
              ),
            ),
          ],
        ),
      );
      expect(named, const [LiveBadge(LiveBadgeKind.noble, '帝皇', level: 6)]);
      expect(parseHuyaChatBadges(huyaNotice(nobleInfoLevel: 7)), const [
        LiveBadge(LiveBadgeKind.noble, '超神帝皇', level: 7),
      ]);
      expect(parseHuyaChatBadges(huyaNotice(nobleLevel: 9)), const [
        LiveBadge(LiveBadgeKind.noble, '贵族', level: 9),
      ]);
    });

    test('没有身份时为 null，没名字或 0 级的粉丝牌不算', () {
      expect(parseHuyaChatBadges(huyaNotice()), isNull);
      var badges = parseHuyaChatBadges(
        huyaNotice(
          prefix: [
            deco(10400, tarsBody(HuyaBadgeInfo()..iBadgeLevel = 3)),
            deco(
              10400,
              tarsBody(
                HuyaBadgeInfo()
                  ..sBadgeName = '零级'
                  ..iBadgeLevel = 0,
              ),
            ),
            deco(11200, tarsBody(HuyaConsumeLevelBadgeInfo())),
            // 聊天气泡等别的装饰不管
            deco(5000, [0x00, 0x01]),
          ],
        ),
      );
      expect(badges, isNull);
    });

    test('没有内容的房管装饰也算房管', () {
      expect(parseHuyaChatBadges(huyaNotice(prefix: [deco(10100, [])])), const [
        LiveBadge(LiveBadgeKind.admin, '房管'),
      ]);
    });

    test('解析不了的装饰只跳过它，别的照常', () {
      var badges = parseHuyaChatBadges(
        huyaNotice(
          suffix: [
            // 牌子名的位置是数字，类型不对
            deco(10400, [0x30, 0x05, 0x40, 0x03]),
            // 字符串长度超出内容
            deco(10200, [0x36, 0xff, 0x41]),
            deco(11200, tarsBody(HuyaConsumeLevelBadgeInfo()..iLevel = 8)),
          ],
        ),
      );
      expect(badges, const [LiveBadge(LiveBadgeKind.level, '等级', level: 8)]);
    });

    test('整段解析不了时为 null，不抛异常', () {
      expect(parseHuyaChatBadges(const []), isNull);
      expect(parseHuyaChatBadges(const [0xff, 0x01, 0x02]), isNull);
      // 装饰列表说有 5 个，后面没有
      var os = TarsOutputStream();
      os.writeHead(TarsStructType.LIST.index, 8);
      os.write(5, 0);
      os.write('2', 20);
      expect(parseHuyaChatBadges(os.toUint8List()), isNull);
    });

    test('装饰坏了的聊天照常显示，只是没有身份', () {
      var good = huyaNotice(
        nick: '甲',
        content: '你好',
        id: '10',
        prefix: [
          deco(10400, [0x36, 0x09, 0x41]),
        ],
      );
      var out = <LiveMessage>[];
      HuyaDanmaku()
        ..onMessage = out.add
        ..decodeMessage(huyaFrame(good))
        // 整帧是乱的：不抛异常，也不出消息
        ..decodeMessage(const [0x0f, 0xff, 0x00]);
      expect(out.single.userName, '甲');
      expect(out.single.message, '你好');
      expect(out.single.badges, isNull);
    });
  });

  group('抖音聊天的身份（实抓）', () {
    late Map<String, ChatMessage> chats;
    setUpAll(() => chats = douyinChats());

    test('房管、粉丝团带图标；隐藏了的荣誉等级不显示', () {
      expect(parseDouyinChatBadges(chats['admin']!.user), const [
        LiveBadge(
          LiveBadgeKind.admin,
          '房管',
          icon:
              'https://p11-webcast.douyinpic.com/img/webcast/webcast_admin_badge.png~tplv-obj.image',
        ),
        LiveBadge(
          LiveBadgeKind.medal,
          '1126',
          level: 20,
          icon:
              'https://p3-webcast.douyinpic.com/img/webcast/fansclub_level_v6_20.png~tplv-obj.image',
        ),
      ]);
    });

    test('荣誉等级和有团名的粉丝团', () {
      var badges = parseDouyinChatBadges(chats['medal_named']!.user)!;
      expect(badges.map((e) => (e.kind, e.text, e.level)), [
        (LiveBadgeKind.level, '等级', 27),
        (LiveBadgeKind.medal, '琪饱宝', 10),
      ]);
      expect(badges[0].icon, contains('new_user_grade_level_v1_27.png'));
      expect(badges[1].icon, contains('fansclub_level_v6_10.png'));
    });

    test('团名是空的粉丝团显示“粉丝团”', () {
      var badges = parseDouyinChatBadges(chats['medal_unnamed']!.user)!;
      expect(badges.map((e) => (e.kind, e.text, e.level)), [
        (LiveBadgeKind.level, '等级', 11),
        (LiveBadgeKind.medal, '粉丝团', 1),
      ]);
    });

    test('熄灭的粉丝团不显示，没有等级的人没有身份', () {
      expect(
        parseDouyinChatBadges(
          chats['medal_unlit']!.user,
        )!.map((e) => (e.kind, e.level)),
        [(LiveBadgeKind.level, 15)],
      );
      expect(parseDouyinChatBadges(chats['none']!.user), isNull);
    });

    test('从推送帧解出的聊天带着身份', () {
      var out = <LiveMessage>[];
      DouyinDanmaku()
        ..onMessage = out.add
        ..decodeMessage(
          pushFrame([
            for (var key in ['medal_named', 'none'])
              Message()
                ..method = 'WebcastChatMessage'
                ..payload = chats[key]!.writeToBuffer(),
          ]),
        );
      expect(out.map((e) => e.userName), ['测试用户2', '测试用户5']);
      expect(out[0].badges?.map((e) => e.text), ['等级', '琪饱宝']);
      expect(out[1].badges, isNull);
    });
  });

  group('抖音聊天的身份（构造）', () {
    test('房管、荣誉等级、粉丝团', () {
      var user = User()
        ..nickName = '测试'
        ..userAttr = (UserAttr()..isAdmin = true)
        ..payGrade = (PayGrade()..level = Int64(5))
        ..fansClub = (FansClub()
          ..data = (FansClubData()
            ..clubName = '测试团'
            ..level = 3
            ..userFansClubStatus = 1));
      // 走一遍编码，和收到的一样
      user = User.fromBuffer(user.writeToBuffer());
      expect(parseDouyinChatBadges(user), const [
        LiveBadge(LiveBadgeKind.admin, '房管'),
        LiveBadge(LiveBadgeKind.level, '等级', level: 5),
        LiveBadge(LiveBadgeKind.medal, '测试团', level: 3),
      ]);
    });

    test('只有超管标记时是“超管”', () {
      var user = User()..userAttr = (UserAttr()..isSuperAdmin = true);
      expect(parseDouyinChatBadges(user), const [
        LiveBadge(LiveBadgeKind.admin, '超管'),
      ]);
    });

    test('熄灭的粉丝团、隐藏的等级、0 级都不显示', () {
      var user = User()
        ..payGrade = (PayGrade()
          ..level = Int64(30)
          ..newImIconWithLevel = (Image()
            ..urlListList.add(
              'https://p3-webcast.douyinpic.com/img/webcast/hide_paygrade_badge_v2.png~tplv-obj.image',
            )))
        ..fansClub = (FansClub()
          ..data = (FansClubData()
            ..clubName = '测试团'
            ..level = 6
            ..userFansClubStatus = 2));
      expect(parseDouyinChatBadges(user), isNull);
      expect(
        parseDouyinChatBadges(
          User()
            ..payGrade = PayGrade()
            ..fansClub = (FansClub()
              ..data = (FansClubData()..userFansClubStatus = 1)),
        ),
        isNull,
      );
      expect(parseDouyinChatBadges(User()), isNull);
    });

    test('只有徽章图片时从图片说明里取等级和团名', () {
      var user = User()
        ..badgeImageList.addAll([
          badgeImage(1, url: 'https://example.com/level.png', level: 8),
          badgeImage(7, name: '图片团', level: 2),
          // 类型 3 但不是房管的图片不算
          badgeImage(3)..content.alternativeText = '其他勋章',
        ]);
      expect(parseDouyinChatBadges(user), const [
        LiveBadge(
          LiveBadgeKind.level,
          '等级',
          level: 8,
          icon: 'https://example.com/level.png',
        ),
        LiveBadge(LiveBadgeKind.medal, '图片团', level: 2),
      ]);
    });

    test('身份字段的类型不对时当作没有，聊天照常解析', () {
      var user = User()..nickName = '测试';
      user.unknownFields
        ..mergeVarintField(23, Int64(5))
        ..mergeFixed64Field(24, Int64(7))
        ..mergeFixed32Field(32, 1);
      var chat = ChatMessage()
        ..user = user
        ..content = '你好';
      var out = <LiveMessage>[];
      DouyinDanmaku()
        ..onMessage = out.add
        ..unPackWebcastChatMessage(chat.writeToBuffer());
      expect(out.single.userName, '测试');
      expect(out.single.message, '你好');
      expect(out.single.badges, isNull);
    });
  });
}
