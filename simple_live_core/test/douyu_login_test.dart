import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 不联网的 passport：记下请求，按 [answer] 回应
class _Passport implements HttpClientAdapter {
  _Passport(this.answer);

  final ResponseBody Function(RequestOptions request) answer;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return answer(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _reply(
  String body, {
  int status = 200,
  List<String> setCookie = const [],
  String? location,
}) {
  return ResponseBody.fromString(
    body,
    status,
    headers: {
      if (setCookie.isNotEmpty) 'set-cookie': setCookie,
      if (location != null) 'location': [location],
    },
  );
}

/// 只有 exp 的 JWT（签名部分随便写）
String _jwt(int exp) {
  var payload = base64Url.encode(utf8.encode(jsonEncode({'exp': exp})));
  return 'eyJhbGciOiJIUzI1NiJ9.${payload.replaceAll('=', '')}.sig';
}

int _seconds(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

void main() {
  group('DouyuCookie', () {
    test('取值不分名字大小写，去掉空格；没有时为空串', () {
      var cookie = ' acf_uid = 42 ;LTP0=abc; broken; =x';
      expect(DouyuCookie.read(cookie, 'ACF_UID'), '42');
      expect(DouyuCookie.read(cookie, 'ltp0'), 'abc');
      expect(DouyuCookie.read(cookie, 'missing'), '');
    });

    test('合并：同名的用后者的值和写法，位置不变，新的排在后面', () {
      expect(DouyuCookie.merge('A=1; b=2', 'a=3; c=4'), 'a=3; b=2; c=4');
      expect(DouyuCookie.merge('', 'x=1'), 'x=1');
    });

    test('Set-Cookie 只取每条开头的“名=值”', () {
      expect(
        DouyuCookie.fromSetCookie([
          'x=1; Path=/',
          'no-pair; Path=/',
          ' y=2 ; HttpOnly',
        ]),
        'x=1; y=2',
      );
      expect(DouyuCookie.fromSetCookie(null), '');
    });

    test('过期看 acf_jwt_token 的 exp', () {
      var now = DateTime(2026, 11, 17, 12);
      var later = 'acf_jwt_token=${_jwt(_seconds(now) + 3600)}';
      var earlier = 'acf_jwt_token=${_jwt(_seconds(now) - 1)}';
      expect(DouyuCookie.expired(later, now: now), isFalse);
      expect(DouyuCookie.expired(earlier, now: now), isTrue);
      expect(DouyuCookie.expired('acf_uid=1', now: now), isTrue);
      expect(DouyuCookie.expired('acf_jwt_token=not.a-jwt', now: now), isTrue);
    });
  });

  group('DouyuQrLogin', () {
    test('领设备号、生成二维码、扫码、确认，跟着跳转收下 LTP0', () async {
      var polls = 0;
      var passport = _Passport((request) {
        switch (request.uri.path) {
          case '/lapi/did/api/get':
            return _reply('slive_did({"error":0,"data":{"did":"DID123"}})');
          case '/scan/generateCode':
            return _reply(
              '{"error":0,"data":{"code":"C1","url":"https://passport.douyu.com/qr?c=C1"}}',
            );
          case '/japi/scan/auth':
            polls++;
            var error = const [-2, 1, 0][polls - 1];
            return _reply(
              '{"error":$error,"data":{"url":"/member/confirm?x=1"}}',
            );
          case '/member/confirm':
            return _reply(
              '',
              status: 302,
              location: 'https://passport.douyu.com/member/landing',
              setCookie: ['LTP0=LT; Path=/; HttpOnly', 'acf_uid=7; Path=/'],
            );
          case '/member/landing':
            return _reply(
              'appClient_json_callback({"error":0});',
              setCookie: ['stale=1; Max-Age=0'],
            );
        }
        return _reply('not found', status: 404);
      });
      var login = DouyuQrLogin(dio: Dio()..httpClientAdapter = passport);

      expect(await login.begin(), 'https://passport.douyu.com/qr?c=C1');
      expect(login.credentials, isNull);
      expect(await login.check(), DouyuQrStep.waiting);
      expect(await login.check(), DouyuQrStep.scanned);
      expect(await login.check(), DouyuQrStep.confirmed);
      // 确认以后二维码就用掉了
      expect(await login.check(), DouyuQrStep.expired);

      var credentials = login.credentials!;
      expect(credentials.deviceId, 'DID123');
      expect(credentials.ltp0, 'LT');
      expect(DouyuCookie.read(credentials.cookie, 'acf_uid'), '7');
      expect(DouyuCookie.read(credentials.cookie, 'dy_did'), 'DID123');
      expect(DouyuCookie.read(credentials.cookie, 'LTP0'), '');

      var did = passport.requests[0];
      expect(did.method, 'GET');
      expect(did.uri.queryParameters, {
        'client_id': '1',
        'callback': 'slive_did',
      });
      var generate = passport.requests[1];
      expect(generate.method, 'POST');
      expect(generate.data, {'client_id': '1', 'isMultiAccount': '0'});
      expect(generate.headers['Cookie'], 'dy_did=DID123');
      expect(generate.headers['Referer'], 'https://passport.douyu.com/');
      expect(generate.headers['Origin'], 'https://passport.douyu.com');
      var auth = passport.requests[2];
      expect(auth.uri.queryParameters['code'], 'C1');
      expect(auth.uri.queryParameters['time'], isNotEmpty);
      var confirm = passport.requests[5];
      expect(confirm.uri.queryParameters, {
        'x': '1',
        'callback': 'appClient_json_callback',
      });
      expect(confirm.followRedirects, isFalse);
      // 跳转后的请求不带表单，Cookie 里已经有 LTP0（按小写的名字发）
      var landing = passport.requests[6];
      expect(landing.method, 'GET');
      expect(landing.headers['Cookie'], contains('ltp0=LT'));
      login.dispose();
    });

    test('扫码结果是不认识的值时报错', () async {
      var passport = _Passport((request) {
        switch (request.uri.path) {
          case '/lapi/did/api/get':
            return _reply('{"error":0,"data":{"did":"D"}}');
          case '/scan/generateCode':
            return _reply('{"error":0,"data":{"code":"C","url":"u"}}');
        }
        return _reply('{"error":5}');
      });
      var login = DouyuQrLogin(dio: Dio()..httpClientAdapter = passport);
      await login.begin();
      await expectLater(login.check(), throwsA(isA<CoreError>()));
    });

    test('确认地址跳到别的网站时报错，不收凭据', () async {
      var passport = _Passport((request) {
        switch (request.uri.path) {
          case '/lapi/did/api/get':
            return _reply('{"error":0,"data":{"did":"D"}}');
          case '/scan/generateCode':
            return _reply('{"error":0,"data":{"code":"C","url":"u"}}');
          case '/japi/scan/auth':
            return _reply('{"error":0,"data":{"url":"/go"}}');
          case '/go':
            return _reply('', status: 302, location: 'https://example.com/');
        }
        return _reply('{"error":99}');
      });
      var login = DouyuQrLogin(dio: Dio()..httpClientAdapter = passport);
      await login.begin();
      await expectLater(login.check(), throwsA(isA<CoreError>()));
      expect(login.credentials, isNull);
    });

    test('生成二维码失败时报错', () async {
      var passport = _Passport(
        (request) => request.uri.path == '/scan/generateCode'
            ? _reply('{"error":1}')
            : _reply('{"error":0,"data":{"did":"D"}}'),
      );
      var login = DouyuQrLogin(dio: Dio()..httpClientAdapter = passport);
      await expectLater(login.begin(), throwsA(isA<CoreError>()));
    });
  });

  group('renewDouyuCookie', () {
    test('用 dy_did 和 LTP0 换新的登录 Cookie', () async {
      var exp = _seconds(DateTime.now()) + 7 * 24 * 3600;
      var passport = _Passport(
        (_) => _reply(
          'axiosJsonpCallback({})',
          setCookie: [
            'acf_jwt_token=${_jwt(exp)}; Path=/; HttpOnly',
            'acf_nickname=%E5%B0%8F%E6%98%8E; Path=/',
          ],
        ),
      );
      var cookie = await renewDouyuCookie(
        deviceId: 'D',
        ltp0: 'L',
        dio: Dio()..httpClientAdapter = passport,
      );
      expect(DouyuCookie.expired(cookie), isFalse);
      expect(DouyuCookie.read(cookie, 'acf_nickname'), '%E5%B0%8F%E6%98%8E');

      var request = passport.requests.single;
      expect(request.uri.path, '/lapi/passport/iframe/safeAuth');
      expect(request.uri.queryParameters['client_id'], '1');
      expect(request.uri.queryParameters['callback'], 'axiosJsonpCallback');
      expect(
        request.uri.queryParameters['t'],
        request.uri.queryParameters['_'],
      );
      expect(request.headers['Cookie'], 'dy_did=D;LTP0=L');
      expect(request.headers['Referer'], 'https://www.douyu.com/');
    });

    test('拿回来的已经过期、或者缺凭据时报错', () async {
      var stale = _Passport(
        (_) => _reply('', setCookie: ['acf_jwt_token=${_jwt(1)}; Path=/']),
      );
      await expectLater(
        renewDouyuCookie(
          deviceId: 'D',
          ltp0: 'L',
          dio: Dio()..httpClientAdapter = stale,
        ),
        throwsA(isA<CoreError>()),
      );
      await expectLater(
        renewDouyuCookie(deviceId: '', ltp0: 'L'),
        throwsA(isA<CoreError>()),
      );
    });
  });
}
