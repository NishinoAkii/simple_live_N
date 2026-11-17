import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  group('名字颜色', () {
    test('Twitch：color 标签是名字颜色，弹幕颜色也用它', () {
      var message = TwitchDanmaku.privmsgToMessage(
        TwitchIrcLine.parse(
          '@badge-info=;badges=;color=#1E90FF;display-name=Alice;emotes=;'
          'id=1;room-id=10;tmi-sent-ts=1;user-id=2 '
          ':alice!alice@alice.tmi.twitch.tv PRIVMSG #chan :hello',
        ),
        null,
      );
      expect(message.nameColor, LiveMessageColor(0x1E, 0x90, 0xFF));
      expect(message.color, LiveMessageColor(0x1E, 0x90, 0xFF));
      expect(json.decode(message.toString())["nameColor"], isNotNull);
    });

    test('Twitch：没选颜色时没有名字颜色，弹幕是白色', () {
      var message = TwitchDanmaku.privmsgToMessage(
        TwitchIrcLine.parse(
          '@badges=;color=;display-name=Bob;emotes=;id=2;room-id=10;user-id=3 '
          ':bob!bob@bob.tmi.twitch.tv PRIVMSG #chan :hi',
        ),
        null,
      );
      expect(message.nameColor, isNull);
      expect(message.color, LiveMessageColor.white);
    });

    test('Kick：identity.color 是名字颜色', () {
      var messages = <LiveMessage>[];
      var danmaku = KickDanmaku()
        ..danmakuArgs = KickDanmakuArgs(
          chatroomId: 1000,
          channelId: 2000,
          slug: 'channel-a',
        )
        ..onMessage = messages.add;
      danmaku.handleFrame(
        json.encode({
          "event": r"App\Events\ChatMessageEvent",
          "channel": "chatrooms.1000.v2",
          "data": json.encode({
            "id": "m1",
            "chatroom_id": 1000,
            "content": "hey",
            "type": "message",
            "sender": {
              "id": 7,
              "username": "carol",
              "slug": "carol",
              "identity": {"color": "#FF5733", "badges": []},
            },
          }),
        }),
      );
      expect(messages, hasLength(1));
      expect(messages.single.nameColor, LiveMessageColor(0xFF, 0x57, 0x33));
      expect(messages.single.asHistory().nameColor, messages.single.nameColor);
    });
  });
}
