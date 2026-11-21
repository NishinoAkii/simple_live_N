import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/services/device_secrets.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_vault.dart';

/// 所有账号、令牌、Cookie 和 WebDAV 密码：设置里只存密文，原版留下的明文照样读、启动时加密；
/// 同步时和别的账号一起加密，到了别的设备用那台的密钥重新加密
void main() {
  const token = "kick-token-0123456789abcdefghijklmn";
  const tokenKey = LocalStorageService.kKickToken;
  var secrets = DeviceSecrets.instance;

  setUp(() => secrets.useKeyForTest(Uint8List.fromList(List.filled(32, 7))));
  tearDown(() => secrets.useKeyForTest(null));

  test('加密后解得开，每次密文不一样，里面看不到明文', () {
    var a = secrets.protect(token);
    var b = secrets.protect(token);
    expect(a, startsWith(DeviceSecrets.prefix));
    expect(a, isNot(b));
    expect(a, isNot(contains(token)));
    expect(secrets.reveal(a), token);
  });

  test('改过的密文、换了密钥都解不开；旧版本的明文原样读出', () {
    var sealed = secrets.protect(token);
    var tampered =
        "${sealed.substring(0, sealed.length - 3)}${sealed.endsWith("A") ? "B" : "A"}==";
    expect(secrets.reveal(tampered), isNull);
    secrets.useKeyForTest(Uint8List.fromList(List.filled(32, 9)));
    expect(secrets.reveal(sealed), isNull);
    expect(secrets.reveal(token), token);
  });

  test('没有设备密钥：不能加密保存，写设置时宁可去掉也不存明文', () {
    secrets.useKeyForTest(null);
    expect(() => secrets.protect(token), throwsStateError);
    expect(secrets.protectSettings({tokenKey: token, "a": 1}), {"a": 1});
  });

  test('写设置前：明文加密，已经是密文的不动', () {
    var sealed = secrets.protect("other");
    var out = secrets.protectSettings({tokenKey: token});
    expect(DeviceSecrets.isProtected(out[tokenKey]), isTrue);
    expect(secrets.reveal(out[tokenKey]), token);
    expect(secrets.protectSettings({tokenKey: sealed})[tokenKey], sealed);
  });

  test('同步存档：令牌解开后和账号一起加密，存档里没有本机的密文，别的设备解开后重新加密', () async {
    var key = await SyncVault.keyFor("user", "password");
    var settings = {tokenKey: secrets.protect(token), "DouyuCookie": "c=1"};
    var (_, accounts) = SyncVault.split(settings);
    expect(accounts.containsKey(tokenKey), isTrue, reason: "要同步");
    var vault = SyncVault.seal(accounts, key!, "webdav|1");
    expect(vault.toString(), isNot(contains(token)));
    expect(vault.toString(), isNot(contains(DeviceSecrets.prefix)));
    var opened = await SyncVault.open(vault,
        user: "user", password: "password", context: "webdav|1");
    expect(opened![tokenKey], token);
    // 另一台设备：自己的密钥
    secrets.useKeyForTest(Uint8List.fromList(List.filled(32, 3)));
    var written = secrets.protectSettings(opened);
    expect(DeviceSecrets.isProtected(written[tokenKey]), isTrue);
    expect(secrets.reveal(written[tokenKey]), token);
  });


  group('设置的读写', () {
    late Directory dir;
    late Box box;
    late LocalStorageService storage;
    setUp(() async {
      Get.testMode = true;
      dir = Directory.systemTemp.createTempSync("sl_secret_box_");
      Hive.init(dir.path);
      box = await Hive.openBox("settings");
      var shield = await Hive.openBox<String>("shield");
      storage = Get.put(LocalStorageService()
        ..settingsBox = box
        ..shieldBox = shield);
    });
    tearDown(() async {
      await Hive.close();
      Get.reset();
      dir.deleteSync(recursive: true);
    });

    test('Cookie、令牌、别的账号、WebDAV 密码都存密文，读出来是明文；普通设置不变', () async {
      const cookie = "SESSDATA=abc; bili_jct=def";
      await storage.setValue(LocalStorageService.kBilibiliCookie, cookie);
      await storage.setValue(LocalStorageService.kTwitchToken, "tw-token");
      await storage.setValue(LocalStorageService.kWebDAVPassword, "dav-pass");
      await storage.setValue(tokenKey, token);
      await storage.setValue(LocalStorageService.kWebDAVUser, "me");
      for (var key in [
        LocalStorageService.kBilibiliCookie,
        LocalStorageService.kTwitchToken,
        LocalStorageService.kWebDAVPassword,
        tokenKey,
      ]) {
        expect(DeviceSecrets.isProtected(box.get(key)), isTrue, reason: key);
      }
      expect(box.get(LocalStorageService.kWebDAVUser), "me");
      expect(storage.getValue(LocalStorageService.kBilibiliCookie, ""), cookie);
      expect(storage.getValue(tokenKey, ""), token);
      expect(storage.plainSettings()[LocalStorageService.kTwitchToken], "tw-token");
      expect(box.toMap().toString(), isNot(contains("SESSDATA")));
    });

    test('原版、旧版本留下的明文照样读；启动时改成密文', () async {
      await box.put(LocalStorageService.kBilibiliCookie, "SESSDATA=old");
      await box.put(LocalStorageService.kDouyuCookie, "acf=1");
      expect(storage.getValue(LocalStorageService.kBilibiliCookie, ""),
          "SESSDATA=old");
      await secrets.initAt(dir.path, migrate: true);
      expect(DeviceSecrets.isProtected(box.get(LocalStorageService.kBilibiliCookie)),
          isTrue);
      expect(DeviceSecrets.isProtected(box.get(LocalStorageService.kDouyuCookie)),
          isTrue);
      expect(storage.getValue(LocalStorageService.kBilibiliCookie, ""),
          "SESSDATA=old");
    });

    test('设置没变时不算改动（不会因为密文每次不同而触发同步）', () async {
      var changes = <String>[];
      storage.onSettingChanged = changes.add;
      await storage.setValue(LocalStorageService.kKickToken, "k");
      await storage.setValue(LocalStorageService.kKickToken, "k");
      expect(changes, [LocalStorageService.kKickToken]);
    });
  });

  test('Windows：设备密钥用 DPAPI 加密保存，重新读出来是同一把', () async {
    if (!Platform.isWindows) return;
    var dir = await Directory.systemTemp.createTemp("sl_secret_");
    addTearDown(() => dir.delete(recursive: true));
    secrets.useKeyForTest(null);
    await secrets.initAt(dir.path);
    expect(secrets.ready, isTrue);
    var file = File("${dir.path}${Platform.pathSeparator}device.key");
    expect(file.readAsStringSync(), startsWith("dpapi1:"));
    var sealed = secrets.protect(token);
    secrets.useKeyForTest(null);
    await secrets.initAt(dir.path);
    expect(secrets.reveal(sealed), token);
  });
}
