import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/models/sync_client_info_model.dart';
import 'package:simple_live_app/services/sync_lan_crypto.dart';

void main() {
  const path = "/sync/follow";
  const plain = '[{"id":"bilibili_1","roomId":"1"}]';

  test("加密以后收方能解开，网上看到的只有密文", () {
    var receiver = LanSyncCrypto();
    var sealed = LanSyncCrypto.seal(receiver.publicKey, path, plain);
    var wire = jsonEncode(sealed);
    expect(wire, isNot(contains("bilibili_1")));
    expect(receiver.open(path, wire), plain);
  });

  test("每次发送的密文都不一样", () {
    var receiver = LanSyncCrypto();
    var a = LanSyncCrypto.seal(receiver.publicKey, path, plain);
    var b = LanSyncCrypto.seal(receiver.publicKey, path, plain);
    expect(a["data"], isNot(b["data"]));
    expect(a["key"], isNot(b["key"]));
  });

  test("明文（官方版发来的）不处理，返回 null", () {
    var receiver = LanSyncCrypto();
    expect(receiver.open(path, plain), isNull);
    expect(receiver.open(path, '{"cookie":"x"}'), isNull);
    expect(receiver.open(path, "not json"), isNull);
  });

  test("改过的密文、换了接口、用旧公钥加密的都解不开", () {
    var receiver = LanSyncCrypto();
    var sealed = LanSyncCrypto.seal(receiver.publicKey, path, plain);

    var tampered = Map<String, dynamic>.from(sealed);
    var bytes = base64.decode(tampered["data"]);
    bytes[0] ^= 1;
    tampered["data"] = base64.encode(bytes);
    expect(() => receiver.open(path, jsonEncode(tampered)), throwsA(anything));

    expect(() => receiver.open("/sync/history", jsonEncode(sealed)),
        throwsA(anything));

    // 收方重启过同步服务（换了密钥）
    var restarted = LanSyncCrypto();
    expect(() => restarted.open(path, jsonEncode(sealed)), throwsA(anything));
  });

  test("只有声明了加密的设备才给公钥", () {
    var key = LanSyncCrypto().publicKey;
    var ours = SyncClientInfoModel.fromJson({
      "type": "windows",
      "name": "pc",
      "version": "1.24.0",
      "address": "1.2.3.4",
      "port": 23234,
      "features": [LanSyncCrypto.feature],
      LanSyncCrypto.infoKey: key,
    });
    expect(ours.encKey, key);
    var official = SyncClientInfoModel.fromJson({
      "type": "windows",
      "name": "pc",
      "version": "1.11.7",
      "address": "1.2.3.4",
      "port": 23234,
    });
    expect(official.encKey, isNull);
  });
}
