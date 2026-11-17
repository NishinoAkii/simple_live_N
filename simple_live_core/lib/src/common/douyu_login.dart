import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_text.dart';

// 斗鱼账号登录。
//
// 扫码：passport.douyu.com 先发一个设备号（dy_did），再生成二维码；用户在斗鱼 App 里确认后，
// 轮询结果里带一个确认地址，打开它时 Set-Cookie 下发长期有效的 LTP0。
// 续期：拿 dy_did + LTP0 调 safeAuth，Set-Cookie 里就是新的登录 Cookie。登录 Cookie 里
// acf_jwt_token 的 exp 大约是 7 天以后，过期了再换一次，不用重新扫码；斗鱼撤销授权时只能重新扫码。
//
// 扫码全程用自己的 Dio 和 Cookie 表，不走共享的 HTTP 客户端，凭据不会进请求日志。
//
// 扫码登录和续期的流程参考了 June6699/dart_simple_live（GPL-3.0）。

const String _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
final Uri _passport = Uri.parse('https://passport.douyu.com/');

BaseOptions _timeouts() => BaseOptions(
  connectTimeout: const Duration(seconds: 15),
  sendTimeout: const Duration(seconds: 15),
  receiveTimeout: const Duration(seconds: 15),
);

/// 斗鱼 Cookie 串（"a=1; b=2"）的读写
abstract final class DouyuCookie {
  /// 名为 [name] 的值（名字不分大小写），没有时为空串
  static String read(String cookie, String name) {
    var key = name.toLowerCase();
    for (var entry in _entries(cookie)) {
      if (entry.key.toLowerCase() == key) {
        return entry.value;
      }
    }
    return '';
  }

  /// [base] 加上 [extra]：同名的（不分大小写）取 [extra] 的值，位置不变
  static String merge(String base, String extra) {
    var merged = <String, MapEntry<String, String>>{};
    for (var entry in [..._entries(base), ..._entries(extra)]) {
      merged[entry.key.toLowerCase()] = entry;
    }
    return _join(merged.values);
  }

  /// Set-Cookie 头里每一条开头的“名=值”，连成一个 Cookie 串
  static String fromSetCookie(Iterable<String>? headers) {
    var pairs = <String>[];
    for (var header in headers ?? const <String>[]) {
      var pair = header.split(';').first.trim();
      if (pair.contains('=')) {
        pairs.add(pair);
      }
    }
    return pairs.join('; ');
  }

  /// 登录 Cookie 是否已经过期：看 acf_jwt_token 的 exp，没有这一项或读不出来都算过期
  static bool expired(String cookie, {DateTime? now}) {
    var exp = _expiry(read(cookie, 'acf_jwt_token'));
    if (exp == null) {
      return true;
    }
    return (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 >= exp;
  }

  static int? _expiry(String jwt) {
    var parts = jwt.split('.');
    if (parts.length < 2) {
      return null;
    }
    try {
      var payload = base64Url.normalize(parts[1].replaceAll('=', ''));
      var claims = jsonDecode(utf8.decode(base64Url.decode(payload)));
      var exp = claims is Map ? claims['exp'] : null;
      return exp is int ? exp : null;
    } catch (_) {
      return null;
    }
  }

  static Iterable<MapEntry<String, String>> _entries(String cookie) sync* {
    for (var part in cookie.split(';')) {
      var text = part.trim();
      var cut = text.indexOf('=');
      if (cut > 0) {
        yield MapEntry(
          text.substring(0, cut).trim(),
          text.substring(cut + 1).trim(),
        );
      }
    }
  }

  static String _join(Iterable<MapEntry<String, String>> entries) =>
      entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// 扫码登录得到的续期凭据
class DouyuCredentials {
  const DouyuCredentials({
    required this.deviceId,
    required this.ltp0,
    required this.cookie,
  });

  /// dy_did
  final String deviceId;

  /// LTP0：续期用，不放进 [cookie]
  final String ltp0;

  /// 确认登录时主站下发的其他 Cookie（acf_uid 等）
  final String cookie;
}

/// 扫码登录的进度
enum DouyuQrStep { waiting, scanned, expired, confirmed }

/// 一次扫码登录：[begin] 返回二维码内容，之后定时调用 [check]，
/// 返回 [DouyuQrStep.confirmed] 后从 [credentials] 取凭据。不用了要 [dispose]
class DouyuQrLogin {
  DouyuQrLogin({Dio? dio}) : _dio = dio ?? Dio(_timeouts());

  final Dio _dio;

  /// 这次登录收到的 Cookie，按小写的名字存（dy_did 和 LTP0 的大小写不固定），
  /// 发给 passport 时也用这个名字
  final Map<String, Cookie> _jar = {};
  CancelToken? _cancel;
  String _scanCode = '';

  /// 确认登录以后才有
  DouyuCredentials? get credentials {
    var deviceId = _jar['dy_did']?.value ?? '';
    var ltp0 = _jar['ltp0']?.value ?? '';
    if (deviceId.isEmpty || ltp0.isEmpty) {
      return null;
    }
    var others = _jar.values.where((c) => c.name.toUpperCase() != 'LTP0');
    return DouyuCredentials(
      deviceId: deviceId,
      ltp0: ltp0,
      cookie: others.map((c) => '${c.name}=${c.value}').join('; '),
    );
  }

  /// 重新开始，返回二维码里的内容
  Future<String> begin() async {
    _reset();
    _cancel = CancelToken();
    // 斗鱼网页生成二维码前先领一个设备号
    var device = await _call(
      '/lapi/did/api/get',
      query: const {'client_id': '1', 'callback': 'slive_did'},
    );
    _jar['dy_did'] = Cookie('dy_did', '${device['data']?['did'] ?? ''}')
      ..domain = 'douyu.com'
      ..path = '/';
    var made = await _call(
      '/scan/generateCode',
      form: const {'client_id': '1', 'isMultiAccount': '0'},
    );
    var code = made['data']?['code'];
    var content = made['data']?['url'];
    if (made['error'] != 0 || code == null || content == null) {
      throw CoreError("没能拿到斗鱼的登录二维码，请重试".t);
    }
    _scanCode = '$code';
    return '$content';
  }

  /// 查一次扫码结果
  Future<DouyuQrStep> check() async {
    if (_scanCode.isEmpty) {
      return DouyuQrStep.expired;
    }
    var state = await _call(
      '/japi/scan/auth',
      query: {
        'code': _scanCode,
        'time': '${DateTime.now().millisecondsSinceEpoch}',
      },
    );
    var step = const {
      -2: DouyuQrStep.waiting,
      1: DouyuQrStep.scanned,
      -1: DouyuQrStep.expired,
      0: DouyuQrStep.confirmed,
    }[state['error']];
    if (step == null) {
      throw CoreError("斗鱼没有确认这次登录，请换一个二维码再试".t);
    }
    if (step == DouyuQrStep.confirmed) {
      await _confirm('${state['data']?['url'] ?? ''}');
      _scanCode = '';
    }
    return step;
  }

  /// 打开确认地址，LTP0 和 dy_did 在它的 Set-Cookie 里
  Future<void> _confirm(String target) async {
    if (target.isEmpty) {
      throw CoreError("斗鱼没有返回登录确认，请刷新二维码再试".t);
    }
    var reply = await _call(
      target,
      query: const {'callback': 'appClient_json_callback'},
    );
    if (reply['error'] != 0 || credentials == null) {
      throw CoreError("斗鱼没有返回续期信息，请刷新二维码再试".t);
    }
  }

  void dispose() {
    _cancel?.cancel();
    _reset();
  }

  void _reset() {
    _cancel = null;
    _jar.clear();
    _scanCode = '';
  }

  /// 请求 passport（[form] 不为空时 POST 表单），返回解开 JSONP 之后的 JSON。
  /// 跳转自己跟：凭据在跳转响应的 Set-Cookie 里，交给 Dio 跟会丢掉
  Future<Map<String, dynamic>> _call(
    String target, {
    Map<String, String>? query,
    Map<String, String>? form,
  }) async {
    var uri = _passport.resolve(target);
    if (query != null) {
      uri = uri.replace(queryParameters: {...uri.queryParameters, ...query});
    }
    var body = form;
    for (var hop = 0; hop < 5; hop++) {
      if (!_isDouyu(uri)) {
        throw CoreError("斗鱼给的登录地址不对".t);
      }
      var response = await _dio.requestUri<String>(
        uri,
        data: body,
        cancelToken: _cancel,
        options: Options(
          method: body == null ? 'GET' : 'POST',
          responseType: ResponseType.plain,
          contentType: Headers.formUrlEncodedContentType,
          followRedirects: false,
          validateStatus: (code) => code != null && code < 400,
          headers: {
            'Referer': '$_passport',
            'Origin': 'https://passport.douyu.com',
            'User-Agent': _ua,
            'Cookie': _jar.entries
                .map((e) => '${e.key}=${e.value.value}')
                .join('; '),
          },
        ),
      );
      _keep(response.headers['set-cookie']);
      if ((response.statusCode ?? 200) < 300) {
        return _json(response.data ?? '');
      }
      var next = response.headers.value('location');
      if (next == null) {
        throw CoreError("斗鱼登录时跳转出错".t);
      }
      uri = uri.resolve(next);
      body = null;
    }
    throw CoreError("斗鱼登录时跳转太多次".t);
  }

  static bool _isDouyu(Uri uri) =>
      uri.scheme == 'https' &&
      (uri.host == 'douyu.com' || uri.host.endsWith('.douyu.com'));

  /// 收下 Set-Cookie；已经过期或 Max-Age=0 的表示删除。解析不了的那条跳过
  void _keep(List<String>? headers) {
    for (var header in headers ?? const <String>[]) {
      Cookie cookie;
      try {
        cookie = Cookie.fromSetCookieValue(header);
      } catch (_) {
        continue;
      }
      var key = cookie.name.toLowerCase();
      var expires = cookie.expires;
      var gone =
          cookie.maxAge == 0 ||
          (expires != null && !expires.isAfter(DateTime.now()));
      if (gone) {
        _jar.remove(key);
      } else {
        _jar[key] = cookie;
      }
    }
  }

  /// JSON，或者包在回调函数里的 JSONP
  static Map<String, dynamic> _json(String text) {
    var body = text.trim();
    if (!body.startsWith('{')) {
      var wrapped = RegExp(r'^[\w.$]+\s*\(([\s\S]*)\)\s*;?$').firstMatch(body);
      if (wrapped == null) {
        throw CoreError("斗鱼登录返回的内容不对".t);
      }
      body = wrapped.group(1)!;
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }
}

/// 用 [deviceId]（dy_did）和 [ltp0] 换一份新的登录 Cookie。
/// 凭据失效或斗鱼撤销了授权时抛 [CoreError]，这时要重新扫码
Future<String> renewDouyuCookie({
  required String deviceId,
  required String ltp0,
  Dio? dio,
}) async {
  if (deviceId.isEmpty || ltp0.isEmpty) {
    throw CoreError("缺少斗鱼续期信息，请重新扫码登录".t);
  }
  var client =
      dio ??
      Dio(
        _timeouts()
          ..followRedirects = false
          ..validateStatus = (code) => code != null && code < 400,
      );
  var stamp = '${DateTime.now().millisecondsSinceEpoch}';
  try {
    var response = await client.get<String>(
      _passport.resolve('/lapi/passport/iframe/safeAuth').toString(),
      queryParameters: {
        'client_id': '1',
        't': stamp,
        '_': stamp,
        'callback': 'axiosJsonpCallback',
      },
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'Referer': 'https://www.douyu.com/',
          'Origin': 'https://passport.douyu.com',
          'User-Agent': _ua,
          'Cookie': 'dy_did=$deviceId;LTP0=$ltp0',
        },
      ),
    );
    var cookie = DouyuCookie.fromSetCookie(response.headers['set-cookie']);
    if (cookie.isEmpty || DouyuCookie.expired(cookie)) {
      throw CoreError("斗鱼登录续期失败，请重新扫码登录".t);
    }
    return cookie;
  } on DioException catch (e) {
    throw CoreError("斗鱼登录续期失败：{p}".tf({"p": e.message ?? '网络异常'.t}));
  } finally {
    if (dio == null) {
      client.close(force: true);
    }
  }
}
