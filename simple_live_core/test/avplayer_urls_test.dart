import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/avplayer_url.dart';
import 'package:test/test.dart';

/// iOS 系统画中画（AVPlayer）用的地址：各平台的解析和转换，全部用固定数据，不联网
void main() {
  group('isHlsPlayUrl / hlsOnlyPlayUrl', () {
    test('m3u8 and YouTube hls_playlist urls count as HLS', () {
      expect(isHlsPlayUrl('https://a.example.com/live/index.m3u8?t=1'), isTrue);
      expect(isHlsPlayUrl('http://a.example.com/x/STREAM.M3U8'), isTrue);
      expect(
        isHlsPlayUrl(
          'https://manifest.googlevideo.com/api/manifest/hls_playlist/expire/1/itag/96/playlist/index.m3u8',
        ),
        isTrue,
      );
      expect(isHlsPlayUrl('https://a.example.com/live/x.flv?m3u8=1'), isFalse);
      expect(isHlsPlayUrl('edl://%10%https://a/x.m3u8'), isFalse);
      expect(isHlsPlayUrl(''), isFalse);
    });

    test('keeps order and headers, null when nothing is HLS', () {
      var play = hlsOnlyPlayUrl(
        LivePlayUrl(
          urls: [
            'https://a.example.com/1.flv',
            'https://b.example.com/2.m3u8',
            'https://c.example.com/3.m3u8',
          ],
          headers: {'user-agent': 'UA'},
        ),
      );
      expect(play!.urls, [
        'https://b.example.com/2.m3u8',
        'https://c.example.com/3.m3u8',
      ]);
      expect(play.headers, {'user-agent': 'UA'});
      expect(
        hlsOnlyPlayUrl(LivePlayUrl(urls: ['https://a.example.com/1.flv'])),
        isNull,
      );
    });
  });

  group('huyaHlsUrl', () {
    const query =
        'wsSecret=abc&wsTime=6a1b2c3d&seqid=1&ctype=huya_pc_exe&ver=1&fs=bgct&fm=RFdx&t=100&u=1&codec=264';

    test('swaps flv host and extension, keeps anticode', () {
      expect(
        huyaHlsUrl('http://al.flv.huya.com/src/1-2-3-A-0-1-imgplus.flv?$query'),
        'http://al.hls.huya.com/src/1-2-3-A-0-1-imgplus.m3u8?$query',
      );
      expect(
        huyaHlsUrl(
          'https://tx.flv.huya.com/src/1-2-3-A-0-1-imgplus.flv?$query&ratio=2000',
        ),
        'https://tx.hls.huya.com/src/1-2-3-A-0-1-imgplus.m3u8?$query&ratio=2000',
      );
      // 查询串里的 .flv 不受影响
      expect(
        huyaHlsUrl('http://hs.flv.huya.com/src/s.flv?a=b.flv&c=.flv.huya.com'),
        'http://hs.hls.huya.com/src/s.m3u8?a=b.flv&c=.flv.huya.com',
      );
    });

    test('skips lines that do not follow the pattern', () {
      expect(huyaHlsUrl('http://hw.huyacdn.com/src/s.flv?$query'), isNull);
      expect(
        huyaHlsUrl('http://al.flv.huya.com.example.net/src/s.flv'),
        isNull,
      );
      expect(huyaHlsUrl('http://al.flv.huya.com/src/s.m3u8?$query'), isNull);
      expect(huyaHlsUrl(''), isNull);
    });
  });

  group('orderBiliLiveUrls', () {
    test('FLV first, then HLS; mcdn last within each; otherwise API order', () {
      const a = 'https://d1--ov-gotcha03.bilivideo.com/live-bvc/1/live_1.flv?expires=1';
      const b = 'https://xy1x2x3x4xy.mcdn.bilivideo.cn:486/live-bvc/1/live_1.flv?expires=1';
      const c = 'https://d1--ov-gotcha07.bilivideo.com/live-bvc/1/live_1.flv?expires=1';
      const d = 'https://d1--ov-gotcha03.bilivideo.com/live-bvc/1/live_1/index.m3u8?expires=1';
      const e = 'https://xy5x6x7x8xy.mcdn.bilivideo.cn:486/live-bvc/1/live_1/index.m3u8?expires=1';
      expect(orderBiliLiveUrls([e, d, b, a, c]), [a, c, b, d, e]);
      expect(orderBiliLiveUrls([d, a]), [a, d]);
      expect(orderBiliLiveUrls([]), isEmpty);
    });
  });

  group('parseBiliLiveHlsUrls', () {
    Map codec(
      String name,
      String baseUrl,
      List<(String, String)> hosts, {
      int qn = 10000,
    }) => {
      'codec_name': name,
      'current_qn': qn,
      'accept_qn': [10000, 400, 250],
      'base_url': baseUrl,
      'url_info': [
        for (var (host, extra) in hosts)
          {'host': host, 'extra': extra, 'stream_ttl': 3600},
      ],
    };

    Map fixture({bool fmp4Avc = true}) => {
      'room_id': 1,
      'live_status': 1,
      'playurl_info': {
        'playurl': {
          'stream': [
            {
              'protocol_name': 'http_stream',
              'format': [
                {
                  'format_name': 'flv',
                  'codec': [
                    codec('avc', '/live-bvc/1/live_1.flv?', [
                      ('https://cn-flv.bilivideo.com', 'expires=1&sign=f'),
                    ]),
                  ],
                },
              ],
            },
            {
              'protocol_name': 'http_hls',
              'format': [
                {
                  'format_name': 'ts',
                  'codec': [
                    codec('avc', '/live-bvc/1/live_1/index.m3u8?', [
                      ('https://cn-ts.bilivideo.com', 'expires=1&sign=t'),
                    ]),
                    codec('hevc', '/live-bvc/1/live_1_h265/index.m3u8?', [
                      ('https://cn-ts.bilivideo.com', 'expires=1&sign=th'),
                    ]),
                  ],
                },
                {
                  'format_name': 'fmp4',
                  'codec': [
                    codec('hevc', '/live-bvc/1/live_1_h265/index.m3u8?', [
                      ('https://cn-fmp4.bilivideo.com', 'expires=1&sign=mh'),
                    ]),
                    if (fmp4Avc)
                      codec('avc', '/live-bvc/1/live_1_fmp4/index.m3u8?', [
                        (
                          'https://xy1x2x3x4xy.mcdn.bilivideo.cn:486',
                          'sign=m1',
                        ),
                        ('https://cn-fmp4.bilivideo.com', 'expires=1&sign=m2'),
                        (
                          'https://cn-fmp4-2.bilivideo.com',
                          'expires=1&sign=m3',
                        ),
                      ]),
                  ],
                },
              ],
            },
          ],
        },
      },
    };

    test('fmp4 before ts, avc only, mcdn last, host + base_url + extra', () {
      expect(parseBiliLiveHlsUrls(fixture()), [
        'https://cn-fmp4.bilivideo.com/live-bvc/1/live_1_fmp4/index.m3u8?expires=1&sign=m2',
        'https://cn-fmp4-2.bilivideo.com/live-bvc/1/live_1_fmp4/index.m3u8?expires=1&sign=m3',
        'https://xy1x2x3x4xy.mcdn.bilivideo.cn:486/live-bvc/1/live_1_fmp4/index.m3u8?sign=m1',
        'https://cn-ts.bilivideo.com/live-bvc/1/live_1/index.m3u8?expires=1&sign=t',
      ]);
    });

    test('falls back to ts when fmp4 only has hevc', () {
      expect(parseBiliLiveHlsUrls(fixture(fmp4Avc: false)), [
        'https://cn-ts.bilivideo.com/live-bvc/1/live_1/index.m3u8?expires=1&sign=t',
      ]);
    });

    test('offline room or bad data gives an empty list', () {
      expect(
        parseBiliLiveHlsUrls({'live_status': 0, 'playurl_info': null}),
        [],
      );
      expect(parseBiliLiveHlsUrls(null), []);
      expect(
        parseBiliLiveHlsUrls({
          'playurl_info': {
            'playurl': {'stream': 'x'},
          },
        }),
        [],
      );
    });
  });

  group('parseDouyuRateStream', () {
    const url =
        'http://openhls-hw.douyucdn2.cn/live/9999rAbc_2000.m3u8?txSecret=s&txTime=t&token=k&did=d&origin=hw&vhost=play2&sid=1';
    Map response({int code = 0, String? streamUrl = url}) => {
      'code': code,
      'msg': code == 0 ? 'ok' : '房间未开播',
      'data': code == 0
          ? {
              'url': streamUrl,
              'rate': 0,
              'settings': [
                {'name': '超清', 'rate': 3},
                {'name': '高清', 'rate': 2},
              ],
            }
          : null,
    };

    test('code 0 gives the m3u8 url', () {
      expect(parseDouyuRateStream(response()), url);
      // 接口按文本返回时也能解析
      expect(parseDouyuRateStream(json.encode(response())), url);
      expect(
        parseDouyuRateStream(response(streamUrl: url.replaceAll('&', '&amp;'))),
        url,
      );
    });

    test('code != 0, missing or non-HLS url gives null', () {
      expect(parseDouyuRateStream(response(code: -5)), isNull);
      expect(parseDouyuRateStream(response(streamUrl: null)), isNull);
      expect(
        parseDouyuRateStream(
          response(
            streamUrl: 'http://hw-tct.douyucdn.cn/live/9999rAbc.flv?a=1',
          ),
        ),
        isNull,
      );
      expect(parseDouyuRateStream('<html>'), isNull);
      expect(parseDouyuRateStream(null), isNull);
    });
  });

  group('parseDouyinHlsUrls', () {
    String hls(String key) =>
        'http://pull-hls-f11.douyinliving.com/thirdgame/stream-1_$key.m3u8?expire=1&sign=s';
    String flv(String key) =>
        'http://pull-flv-f11.douyinliving.com/thirdgame/stream-1_$key.flv?expire=1&sign=s';
    Map main(String key, String vcodec) => {
      'main': {
        'flv': flv(key),
        'hls': hls(key),
        'cmaf': '',
        'sdk_params': json.encode({'VCodec': vcodec, 'resolution': ''}),
      },
    };
    Map quality(String name, String key, int level, {String vCodec = '264'}) =>
        {'name': name, 'sdk_key': key, 'level': level, 'v_codec': vCodec};

    Map streamUrl({String originCodec = 'h264'}) => {
      'flv_pull_url': {'FULL_HD1': flv('uhd'), 'HD1': flv('hd')},
      'hls_pull_url_map': {'FULL_HD1': hls('uhd'), 'HD1': hls('hd')},
      'live_core_sdk_data': {
        'pull_data': {
          'options': {
            'qualities': [
              quality('标清', 'ld', 1),
              quality('高清', 'sd', 2),
              quality('蓝光', 'uhd', 4),
              quality(
                '原画',
                'origin',
                5,
                vCodec: originCodec == 'h264' ? '264' : '265',
              ),
            ],
          },
          'stream_data': json.encode({
            'common': {},
            'data': {
              'ld': main('ld', 'h264'),
              'sd': main('sd', 'h264'),
              'uhd': main('uhd', 'h264'),
              'origin': main('or4', originCodec),
              'ao': {
                'main': {'flv': '', 'hls': ''},
              },
            },
          }),
        },
      },
    };

    test('stream_data: picks the selected quality by sdk_key', () {
      expect(parseDouyinHlsUrls(streamUrl(), quality: '原画', level: 5), [
        hls('or4'),
      ]);
      expect(parseDouyinHlsUrls(streamUrl(), quality: '高清', level: 2), [
        hls('sd'),
      ]);
    });

    test('stream_data: HEVC quality falls back to the best H.264 one', () {
      expect(
        parseDouyinHlsUrls(
          streamUrl(originCodec: 'h265'),
          quality: '原画',
          level: 5,
        ),
        [hls('uhd')],
      );
    });

    test('stream_data: unknown quality gives an empty list', () {
      expect(parseDouyinHlsUrls(streamUrl(), quality: '杜比', level: 9), []);
    });

    test('without stream_data json: hls_pull_url_map by level', () {
      var data = streamUrl();
      (data['live_core_sdk_data']['pull_data'] as Map)['stream_data'] = '';
      // 和 flv_pull_url 一样：第 length - level 个
      expect(parseDouyinHlsUrls(data, quality: '蓝光', level: 2), [hls('uhd')]);
      expect(parseDouyinHlsUrls(data, quality: '高清', level: 1), [hls('hd')]);
      expect(parseDouyinHlsUrls(data, quality: '标清', level: 3), []);
    });

    test('offline room data gives an empty list', () {
      expect(parseDouyinHlsUrls({}, quality: '原画', level: 5), []);
      expect(parseDouyinHlsUrls(null, quality: '原画', level: 5), []);
    });
  });
}
