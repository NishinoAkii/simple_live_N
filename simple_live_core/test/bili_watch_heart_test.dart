// 哔哩哔哩观看时长心跳（x25Kn）：签名、参数和 WBI 签名。
// 期望值用 Python 标准库按 BLTH、BiliBiliDropsMiner 的算法另算了一遍；
// WBI 的一组是 bilibili-API-collect 文档里的例子。不访问网络
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

const room = BiliHeartRoom(
  roomId: 21452505,
  parentAreaId: 9,
  areaId: 371,
  anchorUid: 50329118,
);
const buvid = "AUTO1234567890123456";
const uuid = "f14f8180-1111-4222-8333-444455556666";
const secretKey = "seacasdgyijfhofiuxoannn";
const userAgent =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0";

String sign(List<int> rule) => BiliWatchHeart.sign(
  parentAreaId: 9,
  areaId: 371,
  seq: 1,
  roomId: 21452505,
  buvid: buvid,
  uuid: uuid,
  ets: 1717921241,
  time: 60,
  ts: 1717921301491,
  secretKey: secretKey,
  secretRule: rule,
);

void main() {
  group("签名", () {
    test("六种算法和 RFC 2202、RFC 4231 的例子一致", () {
      const expected = [
        "750c783e6ab0b503eaa86e310a5db738",
        "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79",
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
        "a30e01098bc6dbbf45690f3a7e9e6d0f8bbea2a39e6148008fd05e44",
        "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737",
        "af45d2e376484031617f78d2b58a6b1b9c7ef464f5a01b47e42ec3736322445e8e2240ca5e69e2c78b3239ecfab21649",
      ];
      for (var rule = 0; rule < 6; rule++) {
        var hash = BiliWatchHeart.hashOf(rule)!;
        expect(
          Hmac(
            hash,
            utf8.encode("Jefe"),
          ).convert(utf8.encode("what do ya want for nothing?")).toString(),
          expected[rule],
        );
      }
      expect(BiliWatchHeart.hashOf(6), isNull);
    });

    test("一步：每种算法", () {
      expect(sign([0]), "a4bf8167e54aec386067938dc62daa1d");
      expect(sign([1]), "eef91a36479bd339d08db1f25cee83f8307b6290");
      expect(
        sign([2]),
        "6b421be544212fba16d91700cbc4e644820faa9f80d74be3d39f399ebccd8664",
      );
      expect(
        sign([3]),
        "02d682bb2d11d29492eebca35f4af6873c81fa3c8df605d423450ad6",
      );
      expect(
        sign([4]),
        "585b599baab646d608f46ad398fac8b9e5f456c267ed5b887b7a3ba3ee3c30ef4888171cb167ac2535569ce783ebc818d2d8a4c739d8b7de51ce9c35e0244fa6",
      );
      expect(
        sign([5]),
        "aa7018efa3eabb7a666e77edb021a0af1de0898e937bd62b0b549beeb2a6017ab0b50800cfb4322350a2acc024e50ac3",
      );
    });

    test("几步连着做：上一步的十六进制结果是下一步的输入", () {
      expect(
        sign([2, 5, 1, 4]),
        "5a4bc0545a944270243fa579a9239b31b01f20c219ccf04891101f22829dd02040353f9985e7cbc3857189f6406b2c7e000027664a03439af24a72f45894ce6b",
      );
      expect(
        sign([0, 1, 2, 3, 4, 5]),
        "851dd399e318e30bfb29e06f643b17a35be4c35e341a093cb6d7691b4f1382a7519208428b61e83fae17641f99cdb18a",
      );
    });

    test("不认识的算法报错，不悄悄算一个错的", () {
      expect(() => sign([2, 9]), throwsA(isA<BiliHeartRuleError>()));
    });

    test("规则 0 做两遍的那一种：只影响 0", () {
      addTearDown(() => BiliWatchHeart.md5Twice = false);
      var once = sign([0]);
      var other = sign([2, 5, 1, 4]);
      BiliWatchHeart.md5Twice = true;
      expect(
        sign([0]),
        Hmac(
          md5,
          utf8.encode(secretKey),
        ).convert(utf8.encode(once)).toString(),
      );
      expect(sign([2, 5, 1, 4]), other);
    });
  });

  group("参数", () {
    test("E：序号 0，没有签名", () {
      var params = BiliWatchHeart.enterParams(
        room: room,
        buvid: buvid,
        uuid: uuid,
        ts: 1717921241491,
        userAgent: userAgent,
        csrf: "jct",
      );
      expect(params, {
        "id": "[9,371,0,21452505]",
        "device": '["$buvid","$uuid"]',
        "ruid": "50329118",
        "ts": "1717921241491",
        "is_patch": "0",
        "heart_beat": "[]",
        "ua": userAgent,
        "web_location": "444.8",
        "csrf": "jct",
      });
    });

    test("X：序号加一，ets、benchmark、time 用上一次返回的", () {
      var state = BiliHeartState.fromEnter({
        "code": 0,
        "data": {
          "timestamp": 1717921241,
          "heartbeat_interval": 60,
          "secret_key": secretKey,
          "secret_rule": [2, 5, 1, 4],
          "patch_status": 2,
        },
      });
      expect(state.seq, 0);
      var params = BiliWatchHeart.beatParams(
        room: room,
        state: state,
        buvid: buvid,
        uuid: uuid,
        ts: 1717921301491,
        userAgent: userAgent,
        csrf: "jct",
      );
      expect(params["s"], sign([2, 5, 1, 4]));
      expect(params["id"], "[9,371,1,21452505]");
      expect(params["device"], '["$buvid","$uuid"]');
      expect(params["ets"], "1717921241");
      expect(params["benchmark"], secretKey);
      expect(params["time"], "60");
      expect(params["ts"], "1717921301491");
      expect(params["ruid"], "50329118");
      expect(params["trackid"], "-99998");
      expect(params["web_location"], "444.8");
      expect(params["csrf"], "jct");
      expect(params.containsKey("is_patch"), isFalse);

      // 下一次：序号再加一，换成这次返回的密钥和时间戳
      var second = state.next({
        "code": 0,
        "data": {
          "timestamp": 1717921301,
          "heartbeat_interval": 60,
          "secret_key": "next_key",
          "secret_rule": [1, 0],
        },
      });
      expect(second.seq, 1);
      expect(second.ets, 1717921301);
      expect(second.secretKey, "next_key");
      expect(second.secretRule, [1, 0]);
      var next = BiliWatchHeart.beatParams(
        room: room,
        state: second,
        buvid: buvid,
        uuid: uuid,
        ts: 1717921361000,
        userAgent: userAgent,
        csrf: "jct",
      );
      expect(next["id"], "[9,371,2,21452505]");
      expect(next["benchmark"], "next_key");
    });

    test("返回里没有的沿用上一次的；间隔不对时按 60 秒", () {
      var state = BiliHeartState.fromEnter({
        "code": 0,
        "data": {
          "timestamp": "100",
          "heartbeat_interval": 0,
          "secret_key": "k",
          "secret_rule": ["2"],
        },
      });
      expect(state.ets, 100);
      expect(state.interval, 60);
      expect(state.secretRule, [2]);
      var next = state.next({"code": 0, "data": {}});
      expect(next.seq, 1);
      expect(next.ets, 100);
      expect(next.secretKey, "k");
      expect(next.secretRule, [2]);
    });

    test("接口报错", () {
      expect(
        () => BiliHeartState.fromEnter({"code": -101, "message": "账号未登录"}),
        throwsA(
          isA<BiliHeartError>().having((e) => e.notLoggedIn, "没登录", isTrue),
        ),
      );
      expect(
        () => BiliHeartState.fromEnter({"code": 0, "data": {}}),
        throwsA(isA<BiliHeartError>()),
      );
      expect(
        () => BiliHeartState.fromEnter("nothing"),
        throwsA(isA<BiliHeartError>()),
      );
      var state = BiliHeartState.fromEnter({
        "code": 0,
        "data": {
          "timestamp": 1,
          "heartbeat_interval": 60,
          "secret_key": "k",
          "secret_rule": [2],
        },
      });
      expect(
        () => state.next({"code": 1012002, "message": "time check failed"}),
        throwsA(
          isA<BiliHeartError>().having((e) => e.notLoggedIn, "没登录", isFalse),
        ),
      );
    });

    test("设备号和 UUID 的格式", () {
      var random = Random(7);
      expect(
        BiliWatchHeart.newLiveBuvid(random),
        matches(RegExp(r"^AUTO\d{16}$")),
      );
      expect(
        BiliWatchHeart.newUuid(random),
        matches(
          RegExp(
            r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
          ),
        ),
      );
      expect(room.valid, isTrue);
      expect(
        const BiliHeartRoom(
          roomId: 1,
          parentAreaId: 0,
          areaId: 0,
          anchorUid: 1,
        ).valid,
        isFalse,
      );
    });
  });

  group("WBI 签名", () {
    // 文档里的密钥：img 7cd0…077c、sub 4932…ac45，混出来是这个
    const mixinKey = "ea1db124af3c7062474693fa704f4ff8";

    test("文档里的例子", () {
      var signed = biliWbiSigned(
        {"foo": "114", "bar": "514", "zab": "1919810"},
        mixinKey: mixinKey,
        wts: 1702204169,
      );
      expect(signed["w_rid"], "8f6f2b5b3d485fe1886cec6a0be8c5d4");
      expect(signed["wts"], "1702204169");
      expect(signed["foo"], "114");
    });

    test("空格按 %20 算，!'()* 去掉后再发", () {
      var params = BiliWatchHeart.enterParams(
        room: room,
        buvid: buvid,
        uuid: uuid,
        ts: 1717921241491,
        userAgent: userAgent,
        csrf: "0123456789abcdef0123456789abcdef",
      );
      var signed = biliWbiSigned(params, mixinKey: mixinKey, wts: 1717921241);
      expect(signed["w_rid"], "546d574b0c6734a74d93395655f5be77");
      expect(
        signed["ua"],
        "Mozilla/5.0 Windows NT 10.0; Win64; x64 AppleWebKit/537.36 KHTML, like Gecko Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0",
      );
      expect(signed["id"], "[9,371,0,21452505]");
      // 原来的参数不动
      expect(params["ua"], userAgent);
    });
  });
}
