import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/src/common/hls_master.dart';
import 'package:simple_live_core/src/common/youtube_innertube.dart';
import 'package:simple_live_core/src/common/youtube_parser.dart';
import 'package:test/test.dart';

dynamic fixture(String name) =>
    json.decode(File('test/fixtures/youtube/$name').readAsStringSync());

void main() {
  group('player response', () {
    test('ANDROID_VR live response carries the HLS manifest', () {
      var info = YouTubePlayerInfo.fromJson(fixture('player_vr_live.json'));
      expect(info.status, 'OK');
      expect(info.isLive, isTrue);
      expect(info.isUpcoming, isFalse);
      expect(info.channelId, 'UCaaaaaaaaaaaaaaaaaaaaaa');
      expect(
        info.hlsManifestUrl,
        startsWith('https://manifest.googlevideo.com/'),
      );
      expect(info.thumbnail, endsWith('sddefault_live.jpg'));
      expect(info.author, 'Test Channel');
    });

    test('WEB response: isLiveNow and start time from microformat', () {
      var info = YouTubePlayerInfo.fromJson(fixture('player_web_live.json'));
      expect(info.status, 'UNPLAYABLE');
      expect(info.isLive, isTrue);
      expect(info.hlsManifestUrl, isEmpty);
      expect(info.category, 'Gaming');
      expect(info.startTime, DateTime.parse('2026-10-25T23:29:21+00:00'));
    });

    test('upcoming stream is not live and keeps the scheduled time', () {
      var info = YouTubePlayerInfo.fromJson(
        fixture('player_web_upcoming.json'),
      );
      expect(info.isLive, isFalse);
      expect(info.isUpcoming, isTrue);
      expect(info.startTime, DateTime.parse('2026-10-30T23:00:00+00:00'));
    });

    test('empty response does not throw', () {
      var info = YouTubePlayerInfo.fromJson({});
      expect(info.hasDetails, isFalse);
      expect(info.isLive, isFalse);
    });
  });

  test('YouTube HLS master playlist variants', () {
    const master = '''#EXTM3U
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-STREAM-INF:BANDWIDTH=269034,CODECS="mp4a.40.5,avc1.4D400C",RESOLUTION=256x144,FRAME-RATE=30,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE
https://manifest.googlevideo.com/api/manifest/hls_playlist/itag/91/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2922155,CODECS="mp4a.40.2,avc1.4D4020",RESOLUTION=1280x720,FRAME-RATE=60,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE
https://manifest.googlevideo.com/api/manifest/hls_playlist/itag/300/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5552610,CODECS="mp4a.40.2,avc1.4D402A",RESOLUTION=1920x1080,FRAME-RATE=60,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE
https://manifest.googlevideo.com/api/manifest/hls_playlist/itag/301/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1282517,CODECS="mp4a.40.2,avc1.4D401F",RESOLUTION=854x480,FRAME-RATE=30,VIDEO-RANGE=SDR,CLOSED-CAPTIONS=NONE
https://manifest.googlevideo.com/api/manifest/hls_playlist/itag/94/index.m3u8
''';
    var variants = parseHlsMaster(
      master,
      Uri.parse('https://manifest.googlevideo.com/api/manifest/hls_variant/x'),
    );
    expect(variants.map((e) => e.name), ['1080p60', '720p60', '480p', '144p']);
    expect(variants.first.id, '1920x1080');
    expect(variants.first.url, endsWith('/itag/301/index.m3u8'));
    expect(variants.any((e) => e.audioOnly), isFalse);
  });

  group('lists', () {
    test('live destination: only live videos, room id is the channel', () {
      var rooms = parseYouTubeLiveRooms(fixture('browse_live.json'));
      expect(rooms.map((e) => e.roomId), [
        'UCaaaaaaaaaaaaaaaaaaaaaa',
        'UCcccccccccccccccccccccc',
      ]);
      expect(rooms.first.online, 8989);
      expect(rooms.first.title, 'Test live stream');
      expect(rooms.first.userName, 'Test Channel');
      expect(rooms.first.cover, endsWith('sqp=large'));
      // 搜索结果的样式：徽章标记直播、频道在 longBylineText、地址缺协议
      expect(rooms[1].online, 1437);
      expect(rooms[1].userName, 'Third Channel');
      expect(rooms[1].cover, startsWith('https://i.ytimg.com/'));
      expect(
        ytContinuationToken(fixture('browse_live.json')),
        'NEXT_PAGE_TOKEN',
      );
      // 同一频道的第二场不重复出现；记下列表显示的那一场
      expect(
        parseYouTubeLiveVideos(
          fixture('browse_live.json'),
        ).map((e) => e.videoId),
        ['AbCdEfGhIjK', 'LmNoPqRsTuV'],
      );
    });

    test('channel search results', () {
      var channels = parseYouTubeChannels(fixture('search_channels.json'));
      expect(channels, hasLength(1));
      expect(channels.first.roomId, 'UCaaaaaaaaaaaaaaaaaaaaaa');
      expect(channels.first.userName, 'Test Channel');
      expect(
        channels.first.avatar,
        startsWith('https://yt3.ggpht.com/test=s88'),
      );
      expect(
        ytContinuationToken(fixture('search_channels.json')),
        'CHANNEL_PAGE_2',
      );
    });

    test('concurrent viewers from updated_metadata', () {
      expect(parseYouTubeViewers(fixture('updated_metadata.json')), 13895);
      expect(parseYouTubeViewers({}), isNull);
    });

    test('counts and avatars', () {
      expect(ytParseCount('8,989 人正在观看'), 8989);
      expect(ytParseCount('No viewers'), 0);
      expect(
        ytResizeAvatar(
          'https://yt3.ggpht.com/x=s900-c-k-c0x00ffffff-no-rj',
          176,
        ),
        'https://yt3.ggpht.com/x=s176-c-k-c0x00ffffff-no-rj',
      );
    });
  });

  group('YouTubeLink.parse (resolveRoomId without network)', () {
    const vid = 'AbCdEfGhIjK';
    const ch = 'UCaaaaaaaaaaaaaaaaaaaaaa';
    YouTubeLink video(String v) => YouTubeLink(YouTubeLinkType.video, v);
    YouTubeLink channel(String v) => YouTubeLink(YouTubeLinkType.channel, v);
    YouTubeLink handle(String v) => YouTubeLink(YouTubeLinkType.handle, v);

    test('video links', () {
      expect(
        YouTubeLink.parse('https://www.youtube.com/watch?v=$vid'),
        video(vid),
      );
      expect(
        YouTubeLink.parse(
          'https://m.youtube.com/watch?feature=share&v=$vid&t=1',
        ),
        video(vid),
      );
      expect(YouTubeLink.parse('youtu.be/$vid?si=x'), video(vid));
      expect(YouTubeLink.parse('https://youtu.be/$vid'), video(vid));
      expect(
        YouTubeLink.parse('https://www.youtube.com/live/$vid?feature=share'),
        video(vid),
      );
      expect(YouTubeLink.parse('https://youtube.com/shorts/$vid'), video(vid));
      expect(
        YouTubeLink.parse(
          'https://www.youtube.com/live_chat?v=$vid&is_popout=1',
        ),
        video(vid),
      );
    });

    test('channel links and bare ids', () {
      expect(YouTubeLink.parse(ch), channel(ch));
      expect(YouTubeLink.parse(' $ch '), channel(ch));
      expect(
        YouTubeLink.parse('https://www.youtube.com/channel/$ch'),
        channel(ch),
      );
      expect(
        YouTubeLink.parse('www.youtube.com/channel/$ch/live'),
        channel(ch),
      );
      expect(
        YouTubeLink.parse('https://m.youtube.com/channel/$ch/streams'),
        channel(ch),
      );
    });

    test('handles and custom paths', () {
      expect(YouTubeLink.parse('@NASA'), handle('NASA'));
      expect(
        YouTubeLink.parse('https://www.youtube.com/@NASA'),
        handle('NASA'),
      );
      expect(
        YouTubeLink.parse('https://www.youtube.com/@NASA/live'),
        handle('NASA'),
      );
      expect(
        YouTubeLink.parse('https://www.youtube.com/@%E6%B5%8B%E8%AF%95/live'),
        handle('测试'),
      );
      expect(
        YouTubeLink.parse('https://www.youtube.com/c/LinusTechTips'),
        const YouTubeLink(
          YouTubeLinkType.path,
          'https://www.youtube.com/c/LinusTechTips',
        ),
      );
      expect(
        YouTubeLink.parse('youtube.com/user/somebody/videos')?.type,
        YouTubeLinkType.path,
      );
    });

    test('unrecognized input', () {
      expect(YouTubeLink.parse(''), isNull);
      expect(YouTubeLink.parse('hello world'), isNull);
      expect(YouTubeLink.parse('@'), isNull);
      expect(YouTubeLink.parse('https://example.com/watch?v=$vid'), isNull);
      expect(YouTubeLink.parse('https://notyoutube.com/@x'), isNull);
      expect(
        YouTubeLink.parse('https://www.youtube.com/watch?v=short'),
        isNull,
      );
      expect(YouTubeLink.parse('https://www.youtube.com/'), isNull);
      expect(
        YouTubeLink.parse('https://www.youtube.com/feed/trending'),
        isNull,
      );
      expect(YouTubeLink.parse('UCtooShort'), isNull);
    });
  });

  group('cookie authorization', () {
    test('SAPISIDHASH matches sha1("<ts> <SAPISID> <origin>")', () {
      expect(
        youTubeSapisidHash('TESTSAPISID/abc', timestamp: 1700000000),
        '1700000000_023c6b8ea0fa22f57f2b51573aba7e268ac00e9d',
      );
    });

    test('Authorization header with 1P/3P variants', () {
      var cookie =
          'PREF=x; SAPISID=TESTSAPISID/abc; __Secure-1PAPISID=P1VALUE; __Secure-3PAPISID=P3VALUE';
      expect(
        youTubeCookieAuthorization(cookie, timestamp: 1700000000),
        'SAPISIDHASH 1700000000_023c6b8ea0fa22f57f2b51573aba7e268ac00e9d '
        'SAPISID1PHASH 1700000000_0c1af3e7e9cc0bf1e7477a6b1d43099b0fec6de0 '
        'SAPISID3PHASH 1700000000_b3b045e50cb116fcb26d9c0da98823a535d71173',
      );
    });

    test('__Secure-3PAPISID stands in for a missing SAPISID', () {
      expect(
        youTubeCookieAuthorization(
          '__Secure-3PAPISID=P3VALUE',
          timestamp: 1700000000,
        ),
        startsWith(
          'SAPISIDHASH 1700000000_b3b045e50cb116fcb26d9c0da98823a535d71173',
        ),
      );
      expect(youTubeCookieAuthorization('PREF=x; SID=y'), isNull);
    });

    test('cookie headers', () {
      var headers = youTubeCookieHeaders('SAPISID=abc; SID=def');
      expect(headers['Authorization'], startsWith('SAPISIDHASH '));
      expect(headers['X-Origin'], 'https://www.youtube.com');
      expect(headers['X-Goog-AuthUser'], '0');
      expect(headers['Cookie'], 'SAPISID=abc; SID=def');
    });
  });
}
