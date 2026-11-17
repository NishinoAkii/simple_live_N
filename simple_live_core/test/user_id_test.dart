import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/youtube_chat_parser.dart';
import 'package:simple_live_core/src/danmaku/bilibili_gifts.dart';
import 'package:simple_live_core/src/danmaku/douyu_gifts.dart';
import 'package:simple_live_core/src/danmaku/proto/douyin.pb.dart';
import 'package:simple_live_core/src/danmaku/twitch_gifts.dart';
import 'package:simple_live_core/src/script/script_convert.dart';
import 'package:test/test.dart';

import 'chat_badges_huya_douyin_test.dart' show huyaFrame, huyaNotice;

// 发言人的用户 ID（LiveMessage / SC / 礼物的 userId）。
// 样本都是离线的：test/fixtures 里匿名抓到的（id 已替换）和照公开格式拼的

List<String> _lines(String path) => File(path)
    .readAsLinesSync()
    .where((e) => e.trim().isNotEmpty && !e.startsWith('#'))
    .toList();

List<LiveMessage> _bili(Iterable<Map<String, dynamic>> messages) {
  var out = <LiveMessage>[];
  var danmaku = BiliBiliDanmaku()..onMessage = out.add;
  for (var m in messages) {
    danmaku.parseMessage(json.encode(m));
  }
  return out;
}

void main() {
  setUpAll(() => CoreLog.enableLog = false);

  group('认人规则', () {
    test('ID 统一成字符串，0 和空的算没有', () {
      expect(liveUserId(123), '123');
      expect(liveUserId(123.0), '123');
      expect(liveUserId(' 77 '), '77');
      expect(liveUserId('UCabc'), 'UCabc');
      expect(liveUserId(0), isNull);
      expect(liveUserId('0'), isNull);
      expect(liveUserId(''), isNull);
      expect(liveUserId(null), isNull);
    });

    test('两边都有 ID 只比 ID；有一边没有时比用户名，必须完全一致', () {
      // 改了名还是同一个人
      expect(sameLiveUser('1', '旧名字', '1', '新名字'), isTrue);
      // 同名不同 ID 不是同一个人
      expect(sameLiveUser('1', '同名', '2', '同名'), isFalse);
      expect(sameLiveUser(null, '甲', '1', '甲'), isTrue);
      expect(sameLiveUser('1', '甲', null, '甲'), isTrue);
      expect(sameLiveUser(null, '甲', null, '甲 '), isFalse);
      expect(sameLiveUser(null, 'Abc', null, 'abc'), isFalse);
      // 没名字也没 ID 的不算任何人
      expect(sameLiveUser(null, '', null, ''), isFalse);
      expect(sameLiveUser('', '', '', ''), isFalse);
    });

    test('写进 toString、历史消息保留 ID', () {
      var m = LiveMessage(
        type: LiveMessageType.chat,
        userName: 'a',
        message: 'b',
        color: LiveMessageColor.white,
        userId: '9',
      );
      expect(json.decode(m.toString())['userId'], '9');
      expect(m.asHistory().userId, '9');
      var plain = LiveMessage(
        type: LiveMessageType.chat,
        userName: 'a',
        message: 'b',
        color: LiveMessageColor.white,
      );
      expect(json.decode(plain.toString()).containsKey('userId'), isFalse);
    });

    test('礼物换上 ID 后其余不变，包成消息时带上', () {
      var gift = LiveGiftMessage(
        comboId: 'c',
        userName: '甲',
        giftName: '小心心',
        count: 3,
        priceText: '¥0.3',
      );
      var withId = gift.withUserId(5);
      expect(withId.userId, '5');
      expect(withId.comboId, 'c');
      expect(withId.count, 3);
      expect(withId.time, gift.time);
      expect(withId.toMessage().userId, '5');
      expect(identical(gift.withUserId(0), gift), isTrue);
      expect(identical(withId.withUserId('5'), withId), isTrue);
    });
  });

  group('哔哩哔哩：info[2][0]、data.uid', () {
    test('实抓的 DANMU_MSG（uid 已替换）', () {
      var messages =
          (json.decode(
                    File(
                      'test/fixtures/gifts/bilibili_gifts.json',
                    ).readAsStringSync(),
                  )['messages']
                  as List)
              .cast<Map<String, dynamic>>()
              .where((m) => m['cmd'] == 'DANMU_MSG');
      expect(_bili(messages).map((e) => e.userId), ['10000001', '10000002']);
    });

    test('没登录时 uid 是 0：没有 ID，只能按名字认', () {
      var out = _bili([
        {
          'cmd': 'DANMU_MSG',
          'info': [
            [],
            '你好',
            [0, '用***', 0],
          ],
        },
      ]);
      expect(out.single.userName, '用***');
      expect(out.single.userId, isNull);
    });

    test('SC 和礼物', () {
      var out = _bili([
        {
          'cmd': 'SUPER_CHAT_MESSAGE',
          'data': {
            'id': 1,
            'uid': 3456,
            'background_bottom_color': '#2A60B2',
            'background_color': '#EDF5FF',
            'end_time': 1794500060,
            'start_time': 1794500000,
            'message': 'sc',
            'price': 30,
            'user_info': {'face': 'https://i0.hdslb.com/a.jpg', 'uname': '乙'},
          },
        },
        {
          'cmd': 'GUARD_BUY',
          'data': {
            'uid': 7788,
            'username': '丙',
            'guard_level': 3,
            'num': 1,
            'price': 198000,
            'gift_name': '舰长',
            'start_time': 1794500001,
          },
        },
        {
          'cmd': 'COMBO_SEND',
          'data': {
            'uid': 0,
            'uname': '丁',
            'gift_name': '小心心',
            'batch_combo_id': 'b1',
            'total_num': 2,
            'combo_total_coin': 0,
            'coin_type': 'silver',
            'sender_uinfo': {
              'uid': 991,
              'base': {'name': '丁', 'face': ''},
            },
          },
        },
      ]);
      var sc = out[0].data as LiveSuperChatMessage;
      expect(sc.userId, '3456');
      expect(out[0].userId, '3456');
      expect(out[1].userId, '7788');
      expect((out[1].data as LiveGiftMessage).userId, '7788');
      // data.uid 是 0 时看 sender_uinfo.uid
      expect(out[2].userId, '991');
    });

    test('SEND_GIFT_V2：pb 的字段 1；没有时为空', () {
      var messages =
          (json.decode(
                    File(
                      'test/fixtures/gifts/bilibili_gifts.json',
                    ).readAsStringSync(),
                  )['messages']
                  as List)
              .cast<Map<String, dynamic>>()
              .where((m) => m['cmd'] == 'SEND_GIFT_V2');
      var gifts = [
        for (var m in messages)
          if (parseBiliGift(m) case var gift?) gift,
      ];
      expect(gifts, isNotEmpty);
      for (var gift in gifts) {
        expect(gift.userId == null || int.parse(gift.userId!) > 0, isTrue);
      }
    });
  });

  test('斗鱼：chatmsg 和礼物的 uid', () {
    var out = <LiveMessage>[];
    var danmaku = DouyuDanmaku()
      ..roomId = '24422'
      ..onMessage = out.add;
    for (var line in _lines('test/fixtures/badges/douyu_chatmsg.txt')) {
      danmaku.decodeMessage(danmaku.serializeDouyu(line));
    }
    expect(out, isNotEmpty);
    expect(out.first.userId, '10001');
    expect(out.every((e) => e.userId != null), isTrue);
    var gift = parseDouyuGift({
      'type': 'dgb',
      'rid': '24422',
      'uid': '555',
      'nn': '戊',
      'gfid': '824',
      'gfcnt': '1',
    });
    expect(gift?.userId, '555');
    var noble = parseDouyuNoble({
      'type': 'anbc',
      'drid': '24422',
      'uid': '556',
      'unk': '己',
      'nl': '1',
    }, '24422');
    expect(noble?.userId, '556');
  });

  test('虎牙：发送人的 lUid', () {
    var out = <LiveMessage>[];
    HuyaDanmaku()
      ..onMessage = out.add
      ..decodeMessage(huyaFrame(huyaNotice()));
    // huyaNotice 在发送人的 tag 0 写的是 10001
    expect(out.single.userId, '10001');
  });

  group('抖音：user.id，为 0 时用 idStr', () {
    LiveMessage run(User user) {
      var out = <LiveMessage>[];
      DouyinDanmaku()
        ..onMessage = out.add
        ..unPackWebcastChatMessage(
          (ChatMessage()
                ..user = user
                ..content = 'hi')
              .writeToBuffer(),
        );
      return out.single;
    }

    test('有 id', () {
      expect(
        run(
          User()
            ..id = Int64(123)
            ..nickName = 'a',
        ).userId,
        '123',
      );
    });

    test('id 为 0 时用 idStr', () {
      expect(
        run(
          User()
            ..idStr = '456'
            ..nickName = 'a',
        ).userId,
        '456',
      );
    });

    test('都没有', () {
      expect(run(User()..nickName = 'a').userId, isNull);
    });

    test('实抓的聊天（id 已替换）', () {
      var lines = _lines('test/fixtures/badges/douyin_chat.txt');
      var ids = [
        for (var line in lines)
          DouyinDanmaku.douyinUserId(
            ChatMessage.fromBuffer(
              base64.decode(line.split(' ')[1].trim()),
            ).user,
          ),
      ];
      // 匿名连接收到的聊天也带着 ID
      expect(ids.every((e) => e != null), isTrue, reason: '$ids');
    });
  });

  group('Twitch：user-id', () {
    test('实抓的 PRIVMSG 都带 user-id', () {
      var lines = _lines('test/fixtures/badges/twitch_irc.txt');
      var ids = [
        for (var raw in lines)
          TwitchDanmaku.privmsgToMessage(TwitchIrcLine.parse(raw), null).userId,
      ];
      expect(
        ids.every((e) => e != null && int.tryParse(e) != null),
        isTrue,
        reason: '$ids',
      );
    });

    test('礼物（USERNOTICE）', () {
      var parser = TwitchGiftParser();
      var ids = <String?>[];
      for (var raw in _lines('test/fixtures/gifts/twitch_irc.txt')) {
        var line = TwitchIrcLine.parse(raw);
        if (line.command != 'USERNOTICE') continue;
        var gift = parser.userNotice(line);
        if (gift == null) continue;
        var message = TwitchDanmaku.giftToMessage(gift, line);
        expect(message.userId, line.tags['user-id']);
        expect((message.data as LiveGiftMessage).userId, line.tags['user-id']);
        ids.add(message.userId);
      }
      expect(ids, isNotEmpty);
    });
  });

  test('Kick：sender.id', () {
    var out = <LiveMessage>[];
    var danmaku = KickDanmaku()
      ..danmakuArgs = KickDanmakuArgs(
        chatroomId: 1000,
        channelId: 2000,
        slug: 'channel-a',
      )
      ..onMessage = out.add;
    _lines(
      'test/fixtures/badges/kick_pusher.jsonl',
    ).forEach(danmaku.handleFrame);
    expect(out, isNotEmpty);
    expect(out.first.userId, '4001');
    expect(out.every((e) => e.userId != null), isTrue);
  });

  group('YouTube：频道 ID', () {
    test('文字消息', () {
      var items = parseYouTubeChatActions([
        {
          'addChatItemAction': {
            'item': {
              'liveChatTextMessageRenderer': {
                'id': 'X',
                'message': {'simpleText': 'hi'},
                'authorName': {'simpleText': '@a'},
                'authorExternalChannelId': 'UCviewer1',
              },
            },
          },
        },
      ]);
      expect(items.single.message.userId, 'UCviewer1');
    });

    test('实抓的聊天都带频道 ID', () {
      var data = json.decode(
        File('test/fixtures/badges/youtube_live_chat.json').readAsStringSync(),
      );
      var batch = parseYouTubeChatResponse(data);
      var chats = batch.items
          .map((e) => e.message)
          .where((m) => m.type == LiveMessageType.chat)
          .toList();
      expect(chats, isNotEmpty);
      expect(chats.every((m) => m.userId?.startsWith('UC') ?? false), isTrue);
    });

    test('SC', () {
      var items = parseYouTubeChatActions([
        {
          'addChatItemAction': {
            'item': {
              'liveChatPaidMessageRenderer': {
                'id': 'P',
                'message': {'simpleText': 'thanks'},
                'authorName': {'simpleText': '@b'},
                'authorExternalChannelId': 'UCpayer',
                'purchaseAmountText': {'simpleText': r'$5.00'},
              },
            },
          },
        },
      ]);
      var message = items.single.message;
      expect(message.type, LiveMessageType.superChat);
      expect(message.userId, 'UCpayer');
      expect((message.data as LiveSuperChatMessage).userId, 'UCpayer');
    });
  });

  test('直播源：SC 的 userId 选填', () {
    expect(
      scriptSuperChat({'user': 'a', 'text': 'x', 'userId': 5}).userId,
      '5',
    );
    expect(scriptSuperChat({'user': 'a', 'text': 'x'}).userId, isNull);
  });
}
