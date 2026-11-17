import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/hls_master.dart';
import 'package:test/test.dart';

void main() {
  group('parseHlsMaster', () {
    const master = '''#EXTM3U
#EXT-X-TWITCH-INFO:NODE="video-edge"
#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="chunked",NAME="1080p60 (source)",AUTOSELECT=YES,DEFAULT=YES
#EXT-X-STREAM-INF:BANDWIDTH=6931713,RESOLUTION=1920x1080,CODECS="avc1.64002A,mp4a.40.2",VIDEO="chunked",FRAME-RATE=60.000,STABLE-VARIANT-ID="1080p60",IVS-NAME="1080p60"
https://example.com/1080p60.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=160000,CODECS="mp4a.40.2",STABLE-VARIANT-ID="audio_only",IVS-NAME="audio_only"
https://example.com/audio.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1427999,RESOLUTION=852x480,CODECS="avc1.4D401F,mp4a.40.2",FRAME-RATE=30.000
480p/index.m3u8
''';

    test('sorts by bandwidth, audio last, resolves relative urls', () {
      var variants = parseHlsMaster(
        master,
        Uri.parse('https://cdn.example.com/a/b.m3u8'),
      );
      expect(variants.map((e) => e.name), ['1080p60', '480p', 'audio_only']);
      expect(variants.first.id, '1080p60');
      expect(variants[1].url, 'https://cdn.example.com/a/480p/index.m3u8');
      expect(variants.last.audioOnly, isTrue);
    });
  });

  group('TwitchIrcLine', () {
    test('parses tags, prefix, command and trailing', () {
      var line = TwitchIrcLine.parse(
        r'@badge-info=;color=#FF0000;display-name=Some\sOne;emotes= :someone!someone@someone.tmi.twitch.tv PRIVMSG #channel :hello : world',
      );
      expect(line.command, 'PRIVMSG');
      expect(line.params, ['#channel']);
      expect(line.trailing, 'hello : world');
      expect(line.nick, 'someone');
      expect(line.tags['display-name'], 'Some One');
      expect(line.tags['color'], '#FF0000');
    });

    test('parses PING and numeric replies', () {
      expect(TwitchIrcLine.parse('PING :tmi.twitch.tv').command, 'PING');
      expect(
        TwitchIrcLine.parse('PING :tmi.twitch.tv').trailing,
        'tmi.twitch.tv',
      );
      expect(
        TwitchIrcLine.parse(
          ':tmi.twitch.tv 001 justinfan1 :Welcome, GLHF!',
        ).command,
        '001',
      );
    });
  });

  test('Kick emotes are replaced by their names', () {
    expect(
      KickDanmaku.replaceEmotes('[emote:37226:KEKW] hi [emote:1:x]'),
      'KEKW hi x',
    );
  });

  group('Douyu', () {
    test('packet length uses UTF-8 byte count', () {
      var body = 'type@=chatmessage/content@=你好/';
      var packet = DouyuDanmaku().serializeDouyu(body);
      var bytes = utf8.encode(body);
      // 包长 = 4 + 4(重复长度之后的头) + 正文字节 + 结尾 0
      var length = packet[0] | packet[1] << 8 | packet[2] << 16;
      expect(length, 4 + 4 + bytes.length + 1);
      expect(packet.length, 4 + length);
    });

    test('mergeCookies keeps base fields and lets later values win', () {
      var merged = DouyuCookie.merge(
        'acf_uid=1; acf_dmjwt_token=old; acf_stk=a',
        'acf_stk=b; acf_jwt_token=x',
      );
      expect(DouyuCookie.read(merged, 'acf_dmjwt_token'), 'old');
      expect(DouyuCookie.read(merged, 'acf_stk'), 'b');
      expect(DouyuCookie.read(merged, 'acf_jwt_token'), 'x');
    });
  });
}
