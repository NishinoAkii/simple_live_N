import 'package:simple_live_core/src/danmaku/bilibili_gifts.dart';
import 'package:simple_live_core/src/danmaku/douyu_gifts.dart';
import 'package:test/test.dart';

// 字段名来自 blivedm（xfgryujk/blivedm models/web.py）和直播间里的消息格式，
// 用户名、uid 是编的
Map<String, dynamic> guardBuy({int start = 1763000000, int num = 1}) => {
  "cmd": "GUARD_BUY",
  "data": {
    "uid": 1,
    "username": "用户A",
    "guard_level": 3,
    "num": num,
    "price": 198000,
    "gift_id": 10003,
    "gift_name": "舰长",
    "start_time": start,
    "end_time": start,
  },
};

Map<String, dynamic> toastV2(
  String toast, {
  int start = 1763000000,
  int source = 0,
  int num = 1,
}) => {
  "cmd": "USER_TOAST_MSG_V2",
  "data": {
    "sender_uinfo": {
      "uid": 1,
      "base": {"name": "用户A", "face": "https://i0.hdslb.com/bfs/face/a.jpg"},
    },
    "guard_info": {
      "guard_level": 3,
      "role_name": "舰长",
      "start_time": start,
      "end_time": start,
    },
    "pay_info": {"num": num, "price": 198000, "unit": "月"},
    "gift_info": {"gift_id": 10003},
    "option": {"source": source},
    "toast_msg": toast,
  },
};

void main() {
  group('哔哩哔哩上舰：分开通、续费', () {
    test('提示文字里的动作', () {
      expect(biliGuardAction("<%A%> 在主播B的直播间开通了舰长", 0), "开通");
      expect(biliGuardAction("<%A%> 在主播B的直播间续费了舰长", 0), "续费");
      expect(biliGuardAction("<%A%> 自动续费了舰长", 0), "自动续费");
      expect(biliGuardAction("", 2), "续费");
      expect(biliGuardAction("", 0), "上舰");
    });

    test('GUARD_BUY 先到：先发“上舰”，提示到了再发一次“续费”（同一行）', () {
      var merger = BiliGuardMerger();
      var first = merger.merge(parseBiliGift(guardBuy())!, fromToast: false);
      expect(first!.action, "上舰");
      expect(first.giftName, "舰长");
      expect(first.priceText, "¥198");
      // 舰长用大航海的舰长徽章
      expect(first.icon!.url, endsWith("icon-guard3.png"));
      var toast = merger.merge(
        parseBiliGift(toastV2("<%用户A%> 在主播B的直播间续费了舰长"))!,
        fromToast: true,
      );
      expect(toast!.action, "续费");
      expect(toast.comboId, first.comboId);
    });

    test('提示先到：后来的 GUARD_BUY 不再发', () {
      var merger = BiliGuardMerger();
      var toast = merger.merge(
        parseBiliGift(toastV2("<%用户A%> 在主播B的直播间开通了舰长，今天是TA陪伴主播的第1天"))!,
        fromToast: true,
      );
      expect(toast!.action, "开通");
      expect(toast.face, endsWith("@100w.jpg"));
      expect(
        merger.merge(parseBiliGift(guardBuy())!, fromToast: false),
        isNull,
      );
    });

    test('不同时间的两次上舰各算各的；赠送提示（source 2）不要', () {
      var merger = BiliGuardMerger();
      var a = merger.merge(
        parseBiliGift(guardBuy(start: 1))!,
        fromToast: false,
      );
      var b = merger.merge(
        parseBiliGift(guardBuy(start: 2))!,
        fromToast: false,
      );
      expect(a!.comboId, isNot(b!.comboId));
      expect(parseBiliGift(toastV2("续费了舰长", source: 2)), isNull);
    });

    test('多个月：数量是月数，价格是总价', () {
      var gift = parseBiliGift(toastV2("续费了舰长", num: 3))!;
      expect(gift.count, 3);
      expect(gift.priceText, "¥594");
      expect(gift.text, "续费 舰长 ×3");
    });
  });

  group('斗鱼钻粉：开通、续费', () {
    test('dfobc 开通、dfrbc 续费，不带价格', () {
      var open = parseDouyuDiamondFans({
        "type": "dfobc",
        "rid": "9999",
        "nn": "用户A",
        "uid": "1",
      }, "9999")!;
      expect(open.action, "开通");
      expect(open.giftName, "钻粉");
      expect(open.paid, isTrue);
      expect(open.priceText, isNull);
      expect(open.icon!.url, contains("diamond-icon"));
      var renew = parseDouyuDiamondFans({
        "type": "dfrbc",
        "nick": "用户B",
      }, "9999")!;
      expect(renew.action, "续费");
      expect(renew.userName, "用户B");
    });

    test('别的房间的、没有名字的不要', () {
      expect(
        parseDouyuDiamondFans({
          "type": "dfobc",
          "rid": "1",
          "nn": "用户A",
        }, "9999"),
        isNull,
      );
      expect(parseDouyuDiamondFans({"type": "dfobc"}, "9999"), isNull);
      expect(parseDouyuDiamondFans({"type": "dgb"}, "9999"), isNull);
    });
  });

  test('总督、提督、斗鱼贵族都有各自的徽章', () {
    expect(biliGuardIcon(1, "总督")!.url, endsWith("icon-guard1.png"));
    expect(biliGuardIcon(2, "提督")!.url, endsWith("icon-guard2.png"));
    expect(biliGuardIcon(0, "x"), isNull);
    var noble = parseDouyuNoble({
      "type": "anbc",
      "drid": "9999",
      "unk": "用户A",
      "nl": "5",
    }, "9999")!;
    expect(noble.giftName, "贵族国王");
    expect(noble.icon!.url, contains("noble-level5"));
    var unknown = parseDouyuNoble({
      "type": "rnewbc",
      "drid": "9999",
      "unk": "用户A",
      "nl": "99",
    }, "9999")!;
    expect(unknown.icon, isNull);
  });
}
