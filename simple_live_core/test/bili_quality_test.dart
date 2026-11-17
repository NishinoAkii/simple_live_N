import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  group('parseBiliNavVip', () {
    var now = DateTime.fromMillisecondsSinceEpoch(1800000000000);
    Map<String, dynamic> nav(Map<String, dynamic> data) => {
      "code": 0,
      "data": {"isLogin": true, ...data},
    };

    test('active annual 大会员', () {
      expect(
        parseBiliNavVip(
          nav({"vipStatus": 1, "vipType": 2, "vipDueDate": 1900000000000}),
          now: now,
        ),
        isTrue,
      );
    });

    test('only the vip object', () {
      expect(
        parseBiliNavVip(
          nav({
            "vip": {"type": 1, "status": 1, "due_date": 1900000000000},
          }),
          now: now,
        ),
        isTrue,
      );
    });

    test('expired, not opened, no type', () {
      expect(
        parseBiliNavVip(
          nav({"vipStatus": 1, "vipType": 2, "vipDueDate": 1700000000000}),
          now: now,
        ),
        isFalse,
      );
      expect(
        parseBiliNavVip(nav({"vipStatus": 0, "vipType": 2}), now: now),
        isFalse,
      );
      expect(
        parseBiliNavVip(nav({"vipStatus": 1, "vipType": 0}), now: now),
        isFalse,
      );
    });

    test('due date in seconds', () {
      expect(
        parseBiliNavVip(
          nav({"vipStatus": 1, "vipType": 1, "vipDueDate": 1900000000}),
          now: now,
        ),
        isTrue,
      );
    });

    test('logged out (-101) or garbage', () {
      expect(
        parseBiliNavVip({
          "code": -101,
          "data": {"isLogin": false, "vipStatus": 1, "vipType": 2},
        }),
        isFalse,
      );
      expect(parseBiliNavVip(null), isFalse);
      expect(parseBiliNavVip({"code": 0}), isFalse);
    });
  });
}
