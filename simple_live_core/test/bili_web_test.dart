import 'package:simple_live_core/src/common/bili_web.dart';
import 'package:test/test.dart';

void main() {
  test('sec-ch-ua matches what real Chrome versions sent', () {
    expect(
      BiliWeb.secChUaFor(120),
      '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"',
    );
    expect(
      BiliWeb.secChUaFor(124),
      '"Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99"',
    );
    expect(
      BiliWeb.secChUaFor(131),
      '"Google Chrome";v="131", "Chromium";v="131", "Not_A Brand";v="24"',
    );
  });

  test('Chrome version follows the release cadence, one version behind', () {
    expect(BiliWeb.chromeMajor(DateTime.utc(2026, 1, 13)), 143);
    expect(BiliWeb.chromeMajor(DateTime.utc(2026, 2, 10)), 144);
    expect(BiliWeb.chromeMajor(DateTime.utc(2025, 6, 1)), 143);
    expect(
      BiliWeb.userAgent(DateTime.utc(2026, 2, 10)),
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36",
    );
  });

  test('every Bilibili request uses the same user agent', () {
    var ua = BiliWeb.userAgent();
    expect(BiliWeb.apiHeaders()["user-agent"], ua);
    expect(BiliWeb.socketHeaders()["user-agent"], ua);
    expect(BiliWeb.playHeaders()["user-agent"], ua);
    expect(BiliWeb.apiHeaders(cookie: "a=1")["cookie"], "a=1");
    expect(BiliWeb.apiHeaders().containsKey("cookie"), isFalse);
  });
}
