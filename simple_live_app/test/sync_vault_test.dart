import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_backup_format.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_app/services/sync_vault.dart';

String hex(List<int> bytes) =>
    bytes.map((e) => e.toRadixString(16).padLeft(2, "0")).join();

/// 测试用的少量迭代，正式是 SyncVault.defaultIterations
const int fastIterations = 1000;

const String biliCookie = "SESSDATA=secret-sess-1; bili_jct=secret-jct-2";
const String douyinCookie = "sessionid=secret-douyin-3";
const String twitchToken = "secret-twitch-4";
const String twitchLogin = "secret-login-5";
const String davUser = "secret-dav-user";
const String davPassword = "secret-dav-password";

Map<String, dynamic> localSettings() => {
      LocalStorageService.kBilibiliCookie: biliCookie,
      LocalStorageService.kDouyinCookie: douyinCookie,
      LocalStorageService.kTwitchToken: twitchToken,
      LocalStorageService.kTwitchLogin: twitchLogin,
      LocalStorageService.kKickToken: "",
      LocalStorageService.kWebDAVUri: "https://dav.example.com/dav",
      LocalStorageService.kWebDAVUser: davUser,
      LocalStorageService.kWebDAVPassword: davPassword,
      LocalStorageService.kObsBridgeToken: "secret-obs-6",
      "DanmuSize": 16,
    };

/// 和 WebDavArchive.build 一样拼出设置文件
Future<Map<String, dynamic>> settingsFile(Map<String, dynamic> settings,
    {required int dataTime}) async {
  var (plain, accounts) = SyncVault.split(settings);
  var key =
      await SyncVault.keyFor(davUser, davPassword, iterations: fastIterations);
  return SyncBackupFormat.pack(
    SyncCompat.upstreamSettings(plain),
    SyncCompat.extSettings(plain),
    {
      SyncBackupFormat.dataTimeKey: dataTime,
      SyncVault.extraKey:
          SyncVault.seal(accounts, key!, SyncVault.webDavContext(dataTime)),
    },
  );
}

void main() {
  group("PBKDF2-HMAC-SHA256", () {
    test("和标准测试向量一致", () {
      var password = utf8.encode("password");
      var salt = utf8.encode("salt");
      expect(
        hex(SyncVault.pbkdf2(password, salt, 1)),
        "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b",
      );
      expect(
        hex(SyncVault.pbkdf2(password, salt, 2)),
        "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43",
      );
      expect(
        hex(SyncVault.pbkdf2(password, salt, 4096)),
        "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a",
      );
    });
  });

  group("账号类设置", () {
    test("本版本专用的账号都算账号", () {
      for (var key in SyncCompat.extSettingKeys) {
        expect(LocalStorageService.isAccountKey(key), isTrue, reason: key);
      }
      expect(LocalStorageService.isAccountKey("BilibiliCookie"), isTrue);
      expect(LocalStorageService.isAccountKey("DouyinCookie"), isTrue);
      // 以后新加的、名字里带 Cookie 或令牌的也算
      expect(LocalStorageService.isAccountKey("HuyaCookie"), isTrue);
      expect(LocalStorageService.isAccountKey("SomeApiToken"), isTrue);
      expect(LocalStorageService.isAccountKey("DanmuSize"), isFalse);
      expect(LocalStorageService.isAccountKey("BilibiliLoginTip"), isFalse);
    });

    test("拆开设置：账号单独放，WebDAV 连接不放，没登录的不放", () {
      var (plain, accounts) = SyncVault.split(localSettings());
      expect(accounts, {
        LocalStorageService.kBilibiliCookie: biliCookie,
        LocalStorageService.kDouyinCookie: douyinCookie,
        LocalStorageService.kTwitchToken: twitchToken,
        LocalStorageService.kTwitchLogin: twitchLogin,
      });
      expect(plain.keys, containsAll(["DanmuSize"]));
      for (var key in SyncVault.connectionKeys) {
        expect(plain.containsKey(key), isFalse, reason: key);
        expect(accounts.containsKey(key), isFalse, reason: key);
      }
      // 录屏接口的令牌只在本机，WebDAV 存档里不放；导出配置时放进加密的一项
      expect(plain.containsKey(LocalStorageService.kObsBridgeToken), isFalse);
      var (_, withLocal) =
          SyncVault.split(localSettings(), includeLocalOnly: true);
      expect(withLocal[LocalStorageService.kObsBridgeToken], "secret-obs-6");
    });
  });

  group("加密和解密", () {
    test("同一个 WebDAV 账号能解开，账号名不分大小写和首尾空格", () async {
      var key = await SyncVault.keyFor("Arc", davPassword,
          iterations: fastIterations);
      var vault = SyncVault.seal({"a": "b"}, key!, "ctx");
      var opened = await SyncVault.open(vault,
          user: " arc ", password: davPassword, context: "ctx");
      expect(opened, {"a": "b"});
    });

    test("没有密码时不加密", () async {
      expect(await SyncVault.keyFor("arc", ""), isNull);
    });

    test("密码不对、内容被改过、换到别的存档，都解不开", () async {
      var key = await SyncVault.keyFor(davUser, davPassword,
          iterations: fastIterations);
      var vault = SyncVault.seal({"a": "b"}, key!, "webdav|1");
      Future<Map?> openWith(Map v,
              {String password = davPassword, String context = "webdav|1"}) =>
          SyncVault.open(v,
              user: davUser, password: password, context: context);

      expect(await openWith(vault), {"a": "b"});
      expect(await openWith(vault, password: "wrong"), isNull);
      expect(await openWith(vault, context: "webdav|2"), isNull);

      var data = base64.decode(vault["data"] as String);
      data[0] ^= 1;
      expect(await openWith({...vault, "data": base64.encode(data)}), isNull);
      expect(await openWith({...vault, "iter": fastIterations + 1}), isNull);
      expect(await openWith({...vault, "v": 2}), isNull);
      expect(await openWith({...vault, "iter": 100000000}), isNull);
    });

    test("每次加密的结果都不一样", () async {
      var key = await SyncVault.keyFor(davUser, davPassword,
          iterations: fastIterations);
      var a = SyncVault.seal({"a": "b"}, key!, "ctx");
      var b = SyncVault.seal({"a": "b"}, key, "ctx");
      expect(a["nonce"], isNot(b["nonce"]));
      expect(a["data"], isNot(b["data"]));
    });
  });

  group("WebDAV 存档", () {
    test("文件里看不到账号、Cookie 和 WebDAV 账号密码", () async {
      var file = await settingsFile(localSettings(), dataTime: 123);
      var text = jsonEncode(file);
      for (var secret in [
        "secret-sess-1",
        "secret-jct-2",
        "secret-douyin-3",
        twitchToken,
        twitchLogin,
        davUser,
        davPassword,
        "dav.example.com",
        "secret-obs-6",
      ]) {
        expect(text.contains(secret), isFalse, reason: secret);
      }
      expect(file["data"]["DanmuSize"], 16);
      expect(file[SyncVault.extraKey], isA<Map>());
    });

    test("解开后账号放回原来的位置，后面按明文存档恢复", () async {
      var backup = SyncBackupFormat({
        SyncBackupFormat.settingsFile:
            await settingsFile(localSettings(), dataTime: 123),
      });
      var (opened, ok) = await SyncVault.openBackup(
        backup,
        user: davUser,
        password: davPassword,
        localSettings: const {},
      );
      expect(ok, isTrue);
      var main = opened.main(SyncBackupFormat.settingsFile) as Map;
      var ext = opened.extMap(SyncBackupFormat.settingsFile, "settings")!;
      expect(main[LocalStorageService.kBilibiliCookie], biliCookie);
      expect(main[LocalStorageService.kDouyinCookie], douyinCookie);
      expect(ext[LocalStorageService.kTwitchToken], twitchToken);
      expect(ext[LocalStorageService.kTwitchLogin], twitchLogin);
      expect(main.containsKey(LocalStorageService.kTwitchToken), isFalse);
      expect(
        opened.main(SyncBackupFormat.bilibiliAccountFile),
        {"cookie": biliCookie},
      );

      // 自动同步合并后，这台设备用上了云端的账号
      var merged = SyncCompat.mergeAutoSettings(
        const {},
        Map<String, dynamic>.from(main),
        ext,
        syncSettings: false,
        syncAccounts: true,
        syncBilibili: true,
      );
      expect(merged[LocalStorageService.kTwitchToken], twitchToken);
      expect(merged[LocalStorageService.kBilibiliCookie], biliCookie);
    });

    test("解不开时保留本机登录", () async {
      var backup = SyncBackupFormat({
        SyncBackupFormat.settingsFile:
            await settingsFile(localSettings(), dataTime: 123),
      });
      var local = {
        LocalStorageService.kBilibiliCookie: "local-bili",
        LocalStorageService.kTwitchToken: "local-twitch",
      };
      var (opened, ok) = await SyncVault.openBackup(
        backup,
        user: davUser,
        password: "changed-password",
        localSettings: local,
      );
      expect(ok, isFalse);
      // 不放哔哩哔哩账号文件：恢复时不动本机的哔哩哔哩登录
      expect(opened.has(SyncBackupFormat.bilibiliAccountFile), isFalse);
      var main = Map<String, dynamic>.from(
          opened.main(SyncBackupFormat.settingsFile) as Map);
      var ext = opened.extMap(SyncBackupFormat.settingsFile, "settings");
      var merged = SyncCompat.mergeRestoredSettings(local, main, ext);
      expect(merged[LocalStorageService.kBilibiliCookie], "local-bili");
      expect(merged[LocalStorageService.kTwitchToken], "local-twitch");
      expect(merged.containsKey(LocalStorageService.kDouyinCookie), isFalse);
    });

    test("官方版和旧版的存档没有加密的一项，原样恢复", () async {
      var backup = SyncBackupFormat({
        SyncBackupFormat.settingsFile: SyncBackupFormat.pack({
          LocalStorageService.kBilibiliCookie: "plain-cookie",
        }),
      });
      var (opened, ok) = await SyncVault.openBackup(
        backup,
        user: davUser,
        password: davPassword,
        localSettings: const {},
      );
      expect(ok, isTrue);
      expect(identical(opened, backup), isTrue);
    });
  });
}
