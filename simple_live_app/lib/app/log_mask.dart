import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// 日志里不留账号和密码。
///
/// 敏感的值换成“已隐藏”和 8 位校验码。校验码取 HMAC-SHA256 的前 8 位，
/// 密钥每次启动随机生成：同一份日志里相同的值校验码相同，能看出值有没有变，
/// 但算不回原值。
class LogMask {
  static final List<int> _key = List<int>.generate(
    32,
    (_) => Random.secure().nextInt(256),
  );

  static const String _hiddenPrefix = "[已隐藏";

  /// 值的校验码
  static String fingerprint(String value) =>
      Hmac(sha256, _key).convert(utf8.encode(value)).toString().substring(0, 8);

  /// 隐藏整个值；空值和已经隐藏过的原样返回
  static String hide(Object? value) {
    var text = value?.toString() ?? "";
    if (text.isEmpty || text.startsWith(_hiddenPrefix)) {
      return text;
    }
    return "$_hiddenPrefix ${fingerprint(text)}]";
  }

  /// 名字像登录信息的字段：Cookie、令牌、密码、会话、CSRF 等
  static final RegExp _sensitiveName = RegExp(
    r"cookie|token|passw|secret|sessdata|session|csrf|jct|auth|ticket|ltp0|apisid|psid|login_info|^sid$|^sid_|_sid$",
    caseSensitive: false,
  );

  static bool isSensitiveName(String name) => _sensitiveName.hasMatch(name);

  // 地址里的账号密码：scheme://user:pass@host
  static final RegExp _userInfo = RegExp(
    r"([a-z][a-z0-9+.\-]*://)([^/\s:@]+):([^/\s@]+)@",
    caseSensitive: false,
  );

  // 一整行“名字: 值”，如 Cookie: a=1; b=2
  static final RegExp _line = RegExp(
    r"^([ \t]*)([\w\-]{1,64})([ \t]*[:：][ \t]*)(\S[^\r\n]*)$",
    multiLine: true,
  );

  // Dart 的 Map 打印出来的 {名字: 值, …}（请求头、表单、地址参数）
  static final RegExp _mapPair =
      RegExp(r"([{,][ \t]*)([\w.\-]{1,64}): ([^,}\r\n]*)");

  // JSON 的 "名字": "值"
  static final RegExp _jsonPair =
      RegExp(r'"([\w.\-]{1,64})"(\s*:\s*)"((?:[^"\\]|\\.)*)"');

  // 名字=值：Cookie、地址参数、表单
  static final RegExp _eqPair =
      RegExp(r"([\w.\-]{1,64})=([^;&\s,'" '"' r"}\]]+)");

  /// 把一段日志里的账号、密码、Cookie、令牌换成校验码
  static String scrub(String text) {
    if (text.isEmpty) {
      return text;
    }
    var out = text.replaceAllMapped(
      _userInfo,
      (m) => "${m[1]}${hide("${m[2]}:${m[3]}")}@",
    );
    out = out.replaceAllMapped(
      _line,
      (m) =>
          isSensitiveName(m[2]!) ? "${m[1]}${m[2]}${m[3]}${hide(m[4])}" : m[0]!,
    );
    out = out.replaceAllMapped(
      _mapPair,
      (m) => isSensitiveName(m[2]!) ? "${m[1]}${m[2]}: ${hide(m[3])}" : m[0]!,
    );
    out = out.replaceAllMapped(
      _jsonPair,
      (m) => isSensitiveName(m[1]!) ? '"${m[1]}"${m[2]}"${hide(m[3])}"' : m[0]!,
    );
    out = out.replaceAllMapped(
      _eqPair,
      (m) => isSensitiveName(m[1]!) ? "${m[1]}=${hide(m[2])}" : m[0]!,
    );
    return out;
  }
}
