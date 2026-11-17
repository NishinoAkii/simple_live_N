import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_compat.dart';

FollowUser follow(String siteId, String roomId) => FollowUser(
      id: "${siteId}_$roomId",
      roomId: roomId,
      siteId: siteId,
      userName: roomId,
      face: "",
      addTime: DateTime(2026),
    );

History history(String siteId, String roomId) => History(
      id: "${siteId}_$roomId",
      roomId: roomId,
      siteId: siteId,
      userName: roomId,
      face: "",
      updateTime: DateTime(2026),
    );

void main() {
  test('only official sites go to the standard files', () {
    var follows = [
      follow("douyu", "1"),
      follow("twitch", "xqc"),
      follow("kick", "abc"),
    ];
    expect(SyncCompat.upstreamFollows(follows).map((e) => e.siteId), ["douyu"]);
    expect(SyncCompat.extFollows(follows).map((e) => e.siteId),
        ["twitch", "kick"]);
    var histories = [history("bilibili", "2"), history("kick", "x")];
    expect(SyncCompat.upstreamHistories(histories).map((e) => e.siteId),
        ["bilibili"]);
  });

  test('tags drop members from new platforms', () {
    var tags = [
      FollowUserTag(
        id: "t1",
        tag: "常看",
        userId: ["douyu_1", "twitch_xqc", "kick_a_b"],
      ),
    ];
    expect(SyncCompat.upstreamTags(tags).single.userId, ["douyu_1"]);
    // 原标签不被修改
    expect(tags.single.userId.length, 3);
  });

  test('settings: site order filtered, account keys moved to ext', () {
    var settings = {
      LocalStorageService.kSiteSort: "bilibili,twitch,douyu,huya,douyin,kick",
      LocalStorageService.kTwitchToken: "secret",
      LocalStorageService.kDouyuCookie: "acf_uid=1",
      LocalStorageService.kBilibiliCookie: "SESSDATA=x",
      "DanmuSize": 16.0,
    };
    var upstream = SyncCompat.upstreamSettings(settings);
    expect(
        upstream[LocalStorageService.kSiteSort], "bilibili,douyu,huya,douyin");
    expect(upstream.containsKey(LocalStorageService.kTwitchToken), isFalse);
    expect(upstream.containsKey(LocalStorageService.kDouyuCookie), isFalse);
    expect(upstream[LocalStorageService.kBilibiliCookie], "SESSDATA=x");
    expect(upstream["DanmuSize"], 16.0);

    var ext = SyncCompat.extSettings(settings);
    expect(ext[LocalStorageService.kSiteSort],
        "bilibili,twitch,douyu,huya,douyin,kick");
    expect(ext[LocalStorageService.kTwitchToken], "secret");
    expect(ext.containsKey("DanmuSize"), isFalse);
  });

  test('settings: fork-only keys go to ext', () {
    var settings = {
      LocalStorageService.kLiveCatchUp: true,
      LocalStorageService.kIosPipDanmaku: false,
      "LiveSidePanelWidth": 420.0,
      "DanmuSize": 16.0,
    };
    var upstream = SyncCompat.upstreamSettings(settings);
    expect(upstream.keys, ["DanmuSize"]);
    var ext = SyncCompat.extSettings(settings);
    expect(ext[LocalStorageService.kLiveCatchUp], true);
    expect(ext.containsKey("DanmuSize"), isFalse);
  });

  group('mergeRestoredSettings', () {
    var local = {
      LocalStorageService.kTwitchToken: "local-token",
      LocalStorageService.kWebDAVUri: "http://localhost:8090/",
      "LiveSidePanelWidth": 380.0,
      "DanmuSize": 20.0,
    };
    var main = <String, dynamic>{
      "DanmuSize": 16.0,
      LocalStorageService.kWebDAVUri: "http://192.168.1.2:8090/",
      "LiveSidePanelWidth": 500.0,
    };
    var ext = <String, dynamic>{
      LocalStorageService.kTwitchToken: "backup-token",
    };

    test('fork backup overwrites, device and layout keys stay local', () {
      var r = SyncCompat.mergeRestoredSettings(local, main, ext);
      expect(r["DanmuSize"], 16.0);
      expect(r[LocalStorageService.kTwitchToken], "backup-token");
      expect(r[LocalStorageService.kWebDAVUri], "http://localhost:8090/");
      expect(r["LiveSidePanelWidth"], 380.0);
    });

    test('unchecked groups keep the local values', () {
      var r = SyncCompat.mergeRestoredSettings(local, main, ext,
          syncAccounts: false);
      expect(r[LocalStorageService.kTwitchToken], "local-token");
      expect(r["DanmuSize"], 16.0);
    });

    test('official backup keeps every fork-only local value', () {
      var r = SyncCompat.mergeRestoredSettings(local, main, null);
      expect(r["DanmuSize"], 16.0);
      expect(r[LocalStorageService.kTwitchToken], "local-token");
    });
  });

  group('YouTube', () {
    test('follows and histories never go to official builds', () {
      var follows = [
        follow("bilibili", "1"),
        follow("youtube", "UCSJ4gkVC6NrvII8umztf0Ow"),
      ];
      expect(SyncCompat.upstreamFollows(follows).map((e) => e.siteId),
          ["bilibili"]);
      expect(SyncCompat.extFollows(follows).map((e) => e.siteId), ["youtube"]);
      var histories = [
        history("youtube", "UCSJ4gkVC6NrvII8umztf0Ow"),
        history("huya", "2"),
      ];
      expect(SyncCompat.upstreamHistories(histories).map((e) => e.siteId),
          ["huya"]);
      expect(
          SyncCompat.extHistories(histories).map((e) => e.siteId), ["youtube"]);
      // 频道 ID 里也可能有下划线，按第一个下划线取平台
      expect(SyncCompat.isUpstreamFollowId("youtube_UC_a-b"), isFalse);
      var tags = [
        FollowUserTag(
          id: "t1",
          tag: "常看",
          userId: ["huya_2", "youtube_UC_a-b"],
        ),
      ];
      expect(SyncCompat.upstreamTags(tags).single.userId, ["huya_2"]);
    });

    test('account keys and the avatar switch stay out of official settings',
        () {
      var settings = {
        LocalStorageService.kSiteSort: "youtube,bilibili,douyu,huya,douyin",
        LocalStorageService.kYouTubeClientId: "id.apps.googleusercontent.com",
        LocalStorageService.kYouTubeClientSecret: "client-secret",
        LocalStorageService.kYouTubeOAuthToken: '{"accessToken":"a"}',
        LocalStorageService.kYouTubeOAuthChannel: '{"id":"UC1"}',
        LocalStorageService.kYouTubeCookie: "SAPISID=x",
        LocalStorageService.kYouTubeCookieChannel: '{"id":"UC2"}',
        LocalStorageService.kChatShowFace: false,
        LocalStorageService.kDanmuEmoteImage: false,
        "DanmuSize": 16.0,
      };
      var upstream = SyncCompat.upstreamSettings(settings);
      expect(upstream, {
        LocalStorageService.kSiteSort: "bilibili,douyu,huya,douyin",
        "DanmuSize": 16.0,
      });
      var ext = SyncCompat.extSettings(settings);
      expect(ext[LocalStorageService.kSiteSort],
          "youtube,bilibili,douyu,huya,douyin");
      expect(ext[LocalStorageService.kYouTubeClientSecret], "client-secret");
      expect(
          ext[LocalStorageService.kYouTubeOAuthToken], '{"accessToken":"a"}');
      expect(ext[LocalStorageService.kYouTubeCookie], "SAPISID=x");
      expect(ext[LocalStorageService.kChatShowFace], false);
      expect(ext[LocalStorageService.kDanmuEmoteImage], false);
      expect(ext.containsKey("DanmuSize"), isFalse);
      for (var key in [
        LocalStorageService.kYouTubeClientId,
        LocalStorageService.kYouTubeClientSecret,
        LocalStorageService.kYouTubeOAuthToken,
        LocalStorageService.kYouTubeOAuthChannel,
        LocalStorageService.kYouTubeCookie,
        LocalStorageService.kYouTubeCookieChannel,
      ]) {
        expect(SyncCompat.extSettingKeys, contains(key));
      }
    });

    test('restoring follows the account option like other platforms', () {
      var local = {
        LocalStorageService.kYouTubeClientSecret: "local-secret",
        LocalStorageService.kYouTubeOAuthToken: "local-token",
        LocalStorageService.kYouTubeCookie: "local-cookie",
        LocalStorageService.kChatShowFace: false,
      };
      var main = <String, dynamic>{"DanmuSize": 16.0};
      var ext = <String, dynamic>{
        LocalStorageService.kYouTubeClientSecret: "backup-secret",
        LocalStorageService.kYouTubeOAuthToken: "backup-token",
        LocalStorageService.kYouTubeCookie: "backup-cookie",
        LocalStorageService.kChatShowFace: true,
      };

      var r = SyncCompat.mergeRestoredSettings(local, main, ext);
      expect(r[LocalStorageService.kYouTubeClientSecret], "backup-secret");
      expect(r[LocalStorageService.kYouTubeOAuthToken], "backup-token");
      expect(r[LocalStorageService.kYouTubeCookie], "backup-cookie");
      expect(r[LocalStorageService.kChatShowFace], true);

      r = SyncCompat.mergeRestoredSettings(local, main, ext,
          syncAccounts: false);
      expect(r[LocalStorageService.kYouTubeClientSecret], "local-secret");
      expect(r[LocalStorageService.kYouTubeOAuthToken], "local-token");
      expect(r[LocalStorageService.kYouTubeCookie], "local-cookie");
      // 显示设置不属于账号，照常恢复
      expect(r[LocalStorageService.kChatShowFace], true);

      // 备份来自官方版：本机的 YouTube 账号和设置都保留
      r = SyncCompat.mergeRestoredSettings(local, main, null);
      expect(r[LocalStorageService.kYouTubeOAuthToken], "local-token");
      expect(r[LocalStorageService.kYouTubeCookie], "local-cookie");
      expect(r[LocalStorageService.kChatShowFace], false);
      expect(r["DanmuSize"], 16.0);
    });

    test('LAN sync sends only the platforms the peer declares', () {
      var follows = [
        follow("douyu", "1"),
        follow("twitch", "xqc"),
        follow("youtube", "UC1"),
      ];
      var histories = [history("youtube", "UC1"), history("kick", "a")];
      var tags = [
        FollowUserTag(
          id: "t1",
          tag: "常看",
          userId: ["douyu_1", "twitch_xqc", "youtube_UC1"],
        ),
      ];
      // 官方版没有声明扩展平台
      expect(SyncCompat.followsForPeer(follows, const []).map((e) => e.siteId),
          ["douyu"]);
      expect(SyncCompat.historiesForPeer(histories, const []), isEmpty);
      expect(SyncCompat.tagsForPeer(tags, const []).single.userId, ["douyu_1"]);
      // 还没有 YouTube 的旧版
      const oldFork = ["twitch", "kick"];
      expect(SyncCompat.followsForPeer(follows, oldFork).map((e) => e.siteId),
          ["douyu", "twitch"]);
      expect(
          SyncCompat.historiesForPeer(histories, oldFork).map((e) => e.siteId),
          ["kick"]);
      expect(SyncCompat.tagsForPeer(tags, oldFork).single.userId,
          ["douyu_1", "twitch_xqc"]);
      // 支持 YouTube 的版本全部发送
      const newFork = ["twitch", "kick", "youtube"];
      expect(SyncCompat.followsForPeer(follows, newFork), hasLength(3));
      expect(SyncCompat.historiesForPeer(histories, newFork), hasLength(2));
      expect(SyncCompat.tagsForPeer(tags, newFork).single.userId, hasLength(3));
      // 原标签不被修改
      expect(tags.single.userId, hasLength(3));
    });
  });

  group('live sources (js:*)', () {
    test('never go to official builds, settings keys stay in ext', () {
      var follows = [
        follow("douyu", "1"),
        follow("js:acfun", "123"),
        follow("js:acfun_live", "a_b"),
      ];
      expect(
          SyncCompat.upstreamFollows(follows).map((e) => e.siteId), ["douyu"]);
      // 不在 ext 里（旧版会读 ext），另放在 scripts 里
      expect(SyncCompat.extFollows(follows), isEmpty);
      expect(SyncCompat.scriptFollows(follows), hasLength(2));
      var histories = [history("js:acfun", "123"), history("huya", "2")];
      expect(SyncCompat.upstreamHistories(histories).map((e) => e.siteId),
          ["huya"]);
      expect(SyncCompat.extHistories(histories), isEmpty);
      expect(SyncCompat.scriptHistories(histories).map((e) => e.siteId),
          ["js:acfun"]);
      var tags = [
        FollowUserTag(
          id: "t1",
          tag: "常看",
          userId: ["douyu_1", "js:acfun_123", "js:acfun_live_a_b"],
        ),
      ];
      expect(SyncCompat.upstreamTags(tags).single.userId, ["douyu_1"]);
      expect(SyncCompat.extTags(tags).single.userId, ["douyu_1"]);
      expect(SyncCompat.scriptTagMembers(tags), {
        "t1": ["js:acfun_123", "js:acfun_live_a_b"],
      });

      var settings = {
        LocalStorageService.kSiteSort: "bilibili,js:acfun,douyu,huya,douyin",
        LocalStorageService.kLiveSourceAutoCheck: false,
        LocalStorageService.kLiveSourceLastCheck: 1,
        "DanmuSize": 16.0,
      };
      var upstream = SyncCompat.upstreamSettings(settings);
      expect(upstream, {
        LocalStorageService.kSiteSort: "bilibili,douyu,huya,douyin",
        "DanmuSize": 16.0,
      });
      var ext = SyncCompat.extSettings(settings);
      expect(ext[LocalStorageService.kSiteSort], "bilibili,douyu,huya,douyin");
      expect(ext[LocalStorageService.kLiveSourceAutoCheck], false);
      expect(SyncCompat.scriptSettings(settings), {
        LocalStorageService.kSiteSort: "bilibili,js:acfun,douyu,huya,douyin",
      });
      expect(
        SyncCompat.scriptSettings({LocalStorageService.kSiteSort: "bilibili"}),
        isEmpty,
      );
    });

    test('ext parts that older fork builds read mention no js: platform', () {
      var follows = [follow("twitch", "xqc"), follow("js:acfun", "123")];
      var histories = [history("kick", "a"), history("js:acfun", "123")];
      var tags = [
        FollowUserTag(id: "t1", tag: "常看", userId: [
          "twitch_xqc",
          "js:acfun_123",
        ]),
      ];
      var settings = {
        LocalStorageService.kSiteSort: "bilibili,twitch,js:acfun,douyu",
      };
      var ext = jsonEncode([
        SyncCompat.extFollows(follows).map((e) => e.toJson()).toList(),
        SyncCompat.extHistories(histories).map((e) => e.toJson()).toList(),
        SyncCompat.extTags(tags).map((e) => e.toJson()).toList(),
        SyncCompat.extSettings(settings),
      ]);
      expect(ext, isNot(contains("js:")));
      expect(ext, contains("twitch_xqc"));
      expect(ext, contains("bilibili,twitch,douyu"));
    });

    test('the last check time stays local on restore', () {
      var r = SyncCompat.mergeRestoredSettings(
        {LocalStorageService.kLiveSourceLastCheck: 100},
        {"DanmuSize": 16.0},
        {
          LocalStorageService.kLiveSourceLastCheck: 200,
          LocalStorageService.kLiveSourceAutoCheck: false,
        },
      );
      expect(r[LocalStorageService.kLiveSourceLastCheck], 100);
      expect(r[LocalStorageService.kLiveSourceAutoCheck], false);
    });

    test('LAN sync sends them only to peers that declare js:*', () {
      var follows = [
        follow("douyu", "1"),
        follow("twitch", "xqc"),
        follow("js:acfun", "123"),
      ];
      var tags = [
        FollowUserTag(
          id: "t1",
          tag: "常看",
          userId: ["douyu_1", "twitch_xqc", "js:acfun_live_a_b"],
        ),
      ];
      // 官方版、不支持直播源的旧版：不发送
      const oldFork = ["twitch", "kick", "youtube"];
      expect(SyncCompat.followsForPeer(follows, oldFork).map((e) => e.siteId),
          ["douyu", "twitch"]);
      expect(SyncCompat.tagsForPeer(tags, oldFork).single.userId,
          ["douyu_1", "twitch_xqc"]);
      expect(SyncCompat.followsForPeer(follows, const []), hasLength(1));
      // 支持直播源的版本：不管对方装没装这个源都发送
      var newFork = SyncCompat.localExtSites(
          ["bilibili", "douyu", "twitch", "kick", "youtube", "js:acfun"]);
      expect(newFork, ["twitch", "kick", "youtube", "js:*"]);
      expect(SyncCompat.followsForPeer(follows, newFork), hasLength(3));
      expect(SyncCompat.tagsForPeer(tags, newFork).single.userId, hasLength(3));
      expect(SyncCompat.historiesForPeer([history("js:x", "1")], newFork),
          hasLength(1));
    });

    test('overwriting keeps local script data unless the sender has it', () {
      bool clear(String siteId, {required bool ext, bool js = true}) =>
          SyncCompat.shouldClearSite(siteId,
              includeExt: ext, includeScripts: js);
      // 官方版：只清官方平台
      expect(clear("douyu", ext: false), isTrue);
      expect(clear("twitch", ext: false), isFalse);
      expect(clear("js:acfun", ext: false), isFalse);
      // 不支持直播源的旧版：保留直播源平台
      expect(clear("twitch", ext: true, js: false), isTrue);
      expect(clear("js:acfun", ext: true, js: false), isFalse);
      // 支持直播源的版本：全部覆盖
      expect(clear("js:acfun", ext: true), isTrue);
    });
  });
}
