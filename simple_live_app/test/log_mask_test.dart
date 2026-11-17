import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/log_mask.dart';

void main() {
  group("日志脱敏", () {
    test("请求头里的 Cookie 和授权", () {
      var text = LogMask.scrub(
        "Request Headers：{cookie: SESSDATA=abc123; bili_jct=def456, "
        "user-agent: Mozilla/5.0, authorization: Bearer tok789}",
      );
      expect(text, isNot(contains("abc123")));
      expect(text, isNot(contains("def456")));
      expect(text, isNot(contains("tok789")));
      expect(text, contains("user-agent: Mozilla/5.0"));
      expect(text, contains("[已隐藏 "));
    });

    test("JSON、地址参数、表单", () {
      var json = LogMask.scrub('{"cookie":"SESSDATA=abc","name":"主播"}');
      expect(json, isNot(contains("abc")));
      expect(json, contains('"name":"主播"'));

      var url = LogMask.scrub(
          "https://api.example.com/x?access_token=tok123&room_id=5");
      expect(url, isNot(contains("tok123")));
      expect(url, contains("room_id=5"));

      var form = LogMask.scrub("Request Data：{oid: 1, msg: 你好, csrf: jct999}");
      expect(form, isNot(contains("jct999")));
      expect(form, contains("msg: 你好"));
    });

    test("地址里的账号密码和单独一行的 Cookie", () {
      var url = LogMask.scrub("https://user:pass123@dav.example.com/dav/");
      expect(url, isNot(contains("pass123")));
      expect(url, contains("dav.example.com/dav/"));

      var line = LogMask.scrub("GET /x\r\nCookie: a=1; b=2\r\nHost: h");
      expect(line, isNot(contains("a=1")));
      expect(line, contains("Host: h"));
    });

    test("同样的值校验码相同，可以对比；普通内容不变", () {
      expect(LogMask.hide("value"), LogMask.hide("value"));
      expect(LogMask.hide("value"), isNot(LogMask.hide("value2")));
      expect(LogMask.hide(""), "");
      var plain = "Request URL：https://api.live.bilibili.com/room?id=5";
      expect(LogMask.scrub(plain), plain);
      var masked = LogMask.scrub("{token: abc}");
      expect(LogMask.scrub(masked), masked);
    });
  });
}
