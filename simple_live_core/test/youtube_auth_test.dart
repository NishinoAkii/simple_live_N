import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/youtube_data_api.dart';
import 'package:simple_live_core/src/common/youtube_innertube.dart';
import 'package:test/test.dart';

/// 记录请求并按顺序返回预设响应
class FakeTransport {
  final List<YouTubeHttpResponse Function(String method, Uri url, String? body)>
  responses;
  final List<
    ({String method, Uri url, Map<String, String> headers, String? body})
  >
  requests = [];
  FakeTransport(this.responses);

  Future<YouTubeHttpResponse> call(
    String method,
    Uri url,
    Map<String, String> headers,
    String? body,
  ) async {
    requests.add((method: method, url: url, headers: headers, body: body));
    if (responses.isEmpty) {
      throw StateError('unexpected request $method $url');
    }
    return responses.removeAt(0)(method, url, body);
  }
}

YouTubeHttpResponse Function(String, Uri, String?) reply(
  int status,
  Object body,
) =>
    (_, _, _) => YouTubeHttpResponse(status, json.encode(body));

void main() {
  const config = YouTubeOAuthConfig(clientId: 'cid', clientSecret: 'secret');

  tearDown(() => YouTubeHttp.transport = null);

  test('token JSON round-trip', () {
    var token = YouTubeOAuthToken(
      accessToken: 'a',
      refreshToken: 'r',
      expiresAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
    var copy = YouTubeOAuthToken.fromJson(
      json.decode(json.encode(token.toJson())) as Map<String, dynamic>,
    );
    expect(copy.accessToken, 'a');
    expect(copy.refreshToken, 'r');
    expect(copy.expiresAt, token.expiresAt);
    expect(copy.expired, isTrue);
    expect(YouTubeOAuthToken.fromJson({}).accessToken, '');
  });

  group('device flow responses', () {
    var now = DateTime.utc(2026, 10, 26);

    test('device code', () {
      var code = YouTubeOAuth.parseDeviceCodeResponse(200, {
        'device_code': 'dev',
        'user_code': 'ABCD-EFGH',
        'verification_url': 'https://www.google.com/device',
        'expires_in': 1800,
        'interval': 5,
      }, now: now);
      expect(code.userCode, 'ABCD-EFGH');
      expect(code.interval, const Duration(seconds: 5));
      expect(code.expiresAt, now.add(const Duration(minutes: 30)));
      expect(
        () => YouTubeOAuth.parseDeviceCodeResponse(401, {
          'error': 'invalid_client',
        }),
        throwsA(
          isA<CoreError>().having(
            (e) => e.message,
            'message',
            contains('Client ID'),
          ),
        ),
      );
    });

    test('pending, slow_down and success', () {
      expect(
        YouTubeOAuth.parseTokenPollResponse(428, {
          'error': 'authorization_pending',
        }).state,
        YouTubeTokenPollState.pending,
      );
      expect(
        YouTubeOAuth.parseTokenPollResponse(403, {'error': 'slow_down'}).state,
        YouTubeTokenPollState.slowDown,
      );
      var ok = YouTubeOAuth.parseTokenPollResponse(200, {
        'access_token': 'at',
        'refresh_token': 'rt',
        'expires_in': 3599,
        'scope': YouTubeOAuth.kScope,
        'token_type': 'Bearer',
      }, now: now);
      expect(ok.state, YouTubeTokenPollState.success);
      expect(ok.token!.refreshToken, 'rt');
      expect(ok.token!.expiresAt, now.add(const Duration(seconds: 3599)));
    });

    test('denied, expired and wrong secret are final CoreErrors', () {
      Matcher error(String text) => throwsA(
        isA<CoreError>().having((e) => e.message, 'message', contains(text)),
      );
      expect(
        () => YouTubeOAuth.parseTokenPollResponse(403, {
          'error': 'access_denied',
        }),
        error('拒绝'),
      );
      expect(
        () => YouTubeOAuth.parseTokenPollResponse(400, {
          'error': 'expired_token',
        }),
        error('过期'),
      );
      expect(
        () => YouTubeOAuth.parseTokenPollResponse(401, {
          'error': 'invalid_client',
          'error_description': 'Unauthorized',
        }),
        error('Client Secret'),
      );
    });

    test('server errors are retryable, not CoreError', () {
      expect(
        () => YouTubeOAuth.parseTokenPollResponse(503, 'unavailable'),
        throwsA(isA<YouTubeNetworkException>()),
      );
    });
  });

  group('device flow polling', () {
    YouTubeDeviceCode code(String id, {Duration? interval}) =>
        YouTubeDeviceCode(
          deviceCode: id,
          userCode: 'U',
          verificationUrl: 'https://www.google.com/device',
          interval: interval ?? Duration.zero,
          expiresAt: DateTime.now().add(const Duration(minutes: 10)),
        );

    test('pending returns null, then the token', () async {
      var fake = FakeTransport([
        reply(428, {'error': 'authorization_pending'}),
        reply(200, {
          'access_token': 'at',
          'refresh_token': 'rt',
          'expires_in': 3600,
        }),
      ]);
      YouTubeHttp.transport = fake.call;
      var oauth = YouTubeOAuth(config);
      var c = code('poll-1');
      expect(await oauth.pollDeviceFlow(c), isNull);
      var token = await oauth.pollDeviceFlow(c);
      expect(token?.accessToken, 'at');
      var form = Uri.splitQueryString(fake.requests.first.body!);
      expect(
        form['grant_type'],
        'urn:ietf:params:oauth:grant-type:device_code',
      );
      expect(form['device_code'], 'poll-1');
      expect(form['client_secret'], 'secret');
    });

    test('slow_down increases the interval by 5 s', () async {
      YouTubeHttp.transport = FakeTransport([
        reply(403, {'error': 'slow_down'}),
      ]).call;
      var oauth = YouTubeOAuth(config);
      var c = code('poll-2', interval: const Duration(seconds: 5));
      expect(await oauth.pollDeviceFlow(c), isNull);
      expect(YouTubeOAuth.currentInterval(c), const Duration(seconds: 10));
    });

    test('denied throws CoreError', () async {
      YouTubeHttp.transport = FakeTransport([
        reply(403, {'error': 'access_denied'}),
      ]).call;
      expect(
        YouTubeOAuth(config).pollDeviceFlow(code('poll-3')),
        throwsA(isA<CoreError>()),
      );
    });

    test('expired device code throws without a request', () async {
      var fake = FakeTransport([]);
      YouTubeHttp.transport = fake.call;
      var expired = YouTubeDeviceCode(
        deviceCode: 'poll-4',
        userCode: 'U',
        verificationUrl: '',
        interval: Duration.zero,
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );
      await expectLater(
        YouTubeOAuth(config).pollDeviceFlow(expired),
        throwsA(isA<CoreError>()),
      );
      expect(fake.requests, isEmpty);
    });
  });

  group('refresh', () {
    var old = YouTubeOAuthToken(
      accessToken: 'old',
      refreshToken: 'keep-me',
      expiresAt: DateTime.now(),
    );

    test('keeps the refresh token when none is returned', () async {
      YouTubeHttp.transport = FakeTransport([
        reply(200, {'access_token': 'new', 'expires_in': 3600}),
      ]).call;
      var token = await YouTubeOAuth(config).refresh(old);
      expect(token.accessToken, 'new');
      expect(token.refreshToken, 'keep-me');
      expect(token.expired, isFalse);
    });

    test('revoked refresh token asks to sign in again', () async {
      YouTubeHttp.transport = FakeTransport([
        reply(400, {
          'error': 'invalid_grant',
          'error_description': 'Token has been expired or revoked.',
        }),
      ]).call;
      await expectLater(
        YouTubeOAuth(config).refresh(old),
        throwsA(
          isA<CoreError>().having(
            (e) => e.message,
            'message',
            contains('重新登录'),
          ),
        ),
      );
    });

    test('server error is retryable', () async {
      YouTubeHttp.transport = FakeTransport([reply(500, {})]).call;
      await expectLater(
        YouTubeOAuth(config).refresh(old),
        throwsA(isA<YouTubeNetworkException>()),
      );
    });
  });

  test('fetchMyChannel', () async {
    var fake = FakeTransport([
      reply(200, {
        'items': [
          {
            'id': 'UCffffffffffffffffffffff',
            'snippet': {
              'title': 'Me',
              'thumbnails': {
                'default': {'url': 'https://yt3.ggpht.com/me=s88'},
                'medium': {'url': 'https://yt3.ggpht.com/me=s240'},
              },
            },
          },
        ],
      }),
      reply(200, {'items': []}),
    ]);
    YouTubeHttp.transport = fake.call;
    var me = await YouTubeOAuth(config).fetchMyChannel('at');
    expect(me.id, 'UCffffffffffffffffffffff');
    expect(me.avatar, 'https://yt3.ggpht.com/me=s240');
    expect(fake.requests.first.headers['Authorization'], 'Bearer at');
    expect(fake.requests.first.url.queryParameters['mine'], 'true');
    await expectLater(
      YouTubeOAuth(config).fetchMyChannel('at'),
      throwsA(isA<CoreError>()),
    );
  });

  test('account menu', () {
    var body = json.decode(
      File('test/fixtures/youtube/account_menu.json').readAsStringSync(),
    );
    var info = YouTubeCookieAuth.parseAccountMenu(body);
    expect(info?.id, 'UCffffffffffffffffffffff');
    expect(info?.title, 'Test Account');
    expect(info?.avatar, startsWith('https://yt3.ggpht.com/account'));
    expect(YouTubeCookieAuth.parseAccountMenu({'actions': []}), isNull);
  });

  test('cookie without SAPISID is rejected offline', () async {
    var fake = FakeTransport([]);
    YouTubeHttp.transport = fake.call;
    expect(await YouTubeCookieAuth.verify('PREF=x'), isNull);
    expect(fake.requests, isEmpty);
  });

  group('Data API errors', () {
    test('mapping', () {
      expect(YouTubeDataApi.toError(401, {}).message, contains('重新登录'));
    });
  });
}
