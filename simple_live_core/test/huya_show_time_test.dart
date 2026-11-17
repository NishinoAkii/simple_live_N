import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 虎牙 m.huya.com 页面里 HNF_GLOBAL_INIT.roomInfo.tLiveInfo 的开播时间（2026-11-14 看过真页面）
void main() {
  test("在播：iStartTime 是开播时间（秒）", () {
    expect(HuyaSite.huyaShowTime({"iStartTime": 1794640857, "iTime": 257}),
        "1794640857");
  });

  test("没开播是 0，或者没有这个字段：不给开播时间", () {
    expect(HuyaSite.huyaShowTime({"iStartTime": 0}), isNull);
    expect(HuyaSite.huyaShowTime({}), isNull);
    expect(HuyaSite.huyaShowTime(null), isNull);
  });

  test("字符串形式也认", () {
    expect(HuyaSite.huyaShowTime({"iStartTime": "1794640857"}), "1794640857");
  });
}
