import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/youtube_chat_parser.dart';
import 'package:simple_live_core/src/common/youtube_parser.dart';
import 'package:test/test.dart';

String fixtureText(String name) =>
    File('test/fixtures/youtube/$name').readAsStringSync();
dynamic fixture(String name) => json.decode(fixtureText(name));

void main() {
  var now = DateTime.utc(2026, 10, 26, 1, 0, 0);

  group('get_live_chat', () {
    late YouTubeChatBatch batch;
    setUp(() {
      batch = parseYouTubeChatResponse(fixture('get_live_chat.json'), now: now);
    });

    test('continuation and timeout', () {
      expect(batch.valid, isTrue);
      expect(batch.ended, isFalse);
      expect(batch.continuation, 'NEXT_CHAT_TOKEN');
      expect(batch.timeoutMs, 10000);
    });

    test('only text, paid messages and stickers are kept', () {
      expect(batch.items.map((e) => e.id), [
        'MSG_TEXT_1',
        'MSG_PAID_1',
        'MSG_PAID_2',
        'MSG_STICKER_1',
      ]);
    });

    test('text message with custom and standard emoji', () {
      var item = batch.items.first;
      expect(item.message.type, LiveMessageType.chat);
      expect(item.message.userName, '@viewer-one');
      expect(item.message.message, 'hello :face-purple-crying: 😂');
      expect(item.message.face, contains('=s64'));
      expect(item.time, DateTime.fromMicrosecondsSinceEpoch(1792985180481118));
    });

    test('paid message', () {
      var item = batch.items[1];
      expect(item.message.type, LiveMessageType.superChat);
      expect(item.message.message, 'Great stream!');
      var sc = item.message.data as LiveSuperChatMessage;
      expect(sc.id, 'MSG_PAID_1');
      expect(sc.userName, '@viewer-two');
      expect(sc.face, contains('avatar-two'));
      expect(sc.message, 'Great stream!');
      expect(sc.priceText, r'$5.00');
      expect(sc.price, 5);
      expect(sc.backgroundColor, '#00BFA5');
      expect(sc.backgroundBottomColor, '#1DE9B6');
      expect(sc.startTime, now);
      // 绿色档（约 $5–9.99）显示 2 分钟
      expect(sc.endTime.difference(sc.startTime), const Duration(minutes: 2));
    });

    test('paid message without text, red tier', () {
      var sc = batch.items[2].message.data as LiveSuperChatMessage;
      expect(sc.message, '');
      expect(sc.price, 10000);
      expect(sc.priceText, '¥10,000');
      expect(sc.face, '');
      expect(sc.endTime.difference(sc.startTime), const Duration(minutes: 5));
    });

    test('paid sticker uses its label', () {
      var item = batch.items[3];
      expect(item.message.type, LiveMessageType.superChat);
      var sc = item.message.data as LiveSuperChatMessage;
      expect(sc.message, 'A cat waving hello');
      expect(sc.priceText, '€2,00');
      expect(sc.price, 2);
      expect(sc.backgroundColor, '#FFCA28');
      expect(sc.backgroundBottomColor, '#FFB300');
      expect(sc.endTime.difference(sc.startTime), const Duration(minutes: 3));
    });

    test('history mode times super chats from their timestamps', () {
      var later = DateTime.fromMicrosecondsSinceEpoch(
        1792985181000000,
      ).add(const Duration(seconds: 30));
      var history = parseYouTubeChatResponse(
        fixture('get_live_chat.json'),
        now: later,
        useTimestamps: true,
      );
      var sc = history.items[1].message.data as LiveSuperChatMessage;
      expect(
        sc.startTime,
        DateTime.fromMicrosecondsSinceEpoch(1792985181000000),
      );
      // 没有时间戳的仍从 now 开始
      var noTime = history.items[2].message.data as LiveSuperChatMessage;
      expect(noTime.startTime, later);
    });

    test('ended chat and invalid responses', () {
      var ended = parseYouTubeChatResponse(fixture('get_live_chat_ended.json'));
      expect(ended.valid, isTrue);
      expect(ended.ended, isTrue);
      var invalid = parseYouTubeChatResponse({'responseContext': {}});
      expect(invalid.valid, isFalse);
    });
  });

  group('price and colors', () {
    test('ytParsePrice', () {
      expect(ytParsePrice(r'$5.00'), 5);
      expect(ytParsePrice(r'$4.99'), 5);
      expect(ytParsePrice('¥1,000'), 1000);
      expect(ytParsePrice('€2,50'), 3);
      expect(ytParsePrice('₫20.000'), 20000);
      expect(ytParsePrice(r'CA$1,234.56'), 1235);
      expect(ytParsePrice('1.234,56 €'), 1235);
      expect(ytParsePrice('NT\$75.00'), 75);
      expect(ytParsePrice('₹ 1 000'), 1000);
      expect(ytParsePrice(''), 0);
      expect(ytParsePrice('free'), 0);
    });

    test('ytArgbToHex', () {
      expect(ytArgbToHex(4278239141), '#00BFA5');
      expect(ytArgbToHex(4279592384), '#1565C0');
      expect(ytArgbToHex(null, fallback: '#123456'), '#123456');
    });

    test('durations by color tier', () {
      expect(ytSuperChatDuration(0xFF1565C0, null), const Duration(minutes: 1));
      expect(
        ytSuperChatDuration(0xFFE65100, 0xFFF57C00),
        const Duration(minutes: 4),
      );
      expect(ytSuperChatDuration(null, 0xFFE91E63), const Duration(minutes: 5));
      expect(ytSuperChatDuration(0xFF123456, null), const Duration(minutes: 2));
    });
  });

  group('live_chat page', () {
    test('anonymous page: all-chat token', () {
      var page = YouTubeLiveChatPage.parse(
        fixtureText('live_chat_anonymous.html'),
      );
      expect(page.allChatContinuation, 'ALL_CHAT_TOKEN');
      expect(page.defaultContinuation, 'TOP_CHAT_TOKEN');
      expect(page.continuation, 'ALL_CHAT_TOKEN');
      expect(page.unavailableReason, isNull);
    });

    test('logged-in page: timed token', () {
      var page = YouTubeLiveChatPage.parse(
        fixtureText('live_chat_logged_in.html'),
      );
      expect(page.continuation, 'TIMED_TOKEN');
    });

    test('chat disabled', () {
      var page = YouTubeLiveChatPage.parse(
        fixtureText('live_chat_disabled.html'),
      );
      expect(page.continuation, isNull);
      expect(page.unavailableReason, 'Chat is disabled for this live stream.');
      expect(
        YouTubeLiveChatPage.parse('<html></html>').unavailableReason,
        isNotNull,
      );
    });

    test('JSON extraction skips braces inside strings', () {
      var data = extractYouTubeJson(
        fixtureText('live_chat_anonymous.html'),
        'window["ytInitialData"]',
      );
      var text = ytText(
        data['contents']['liveChatRenderer']['actions'][0]['addChatItemAction']['item']['liveChatTextMessageRenderer']['message'],
      );
      expect(text, 'a } brace and " quote');
    });
  });

  group('connection', () {
    test('offline room closes without network', () async {
      var danmaku = YouTubeDanmaku();
      String? closed;
      danmaku.onClose = (m) => closed = m;
      await danmaku.start(YouTubeDanmakuArgs(videoId: '', channelId: 'UCx'));
      expect(closed, isNotNull);
      await danmaku.stop();
    });
  });
}
