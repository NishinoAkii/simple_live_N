import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/danmaku_filter_settings.dart';
import 'package:simple_live_app/app/danmaku_dedupe.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_core/simple_live_core.dart';

LiveMessage chat(
  String text, {
  String user = "甲",
  List<LiveEmote>? emotes,
  LiveEmote? sticker,
  bool history = false,
  String? userId,
}) =>
    LiveMessage(
      type: LiveMessageType.chat,
      userName: user,
      userId: userId,
      message: text,
      color: LiveMessageColor.white,
      emotes: emotes,
      sticker: sticker,
      history: history,
    );

LiveEmote emote(String text, {bool spaced = false}) =>
    LiveEmote(text: text, url: "https://e.test/$text.png", spaced: spaced);

/// 测试里的时钟（毫秒）
class Clock {
  int ms = 0;
  int call() => ms;
}

/// 对照用的笨办法：把显示过的都记下来，每次数一遍时间范围里有几条
class NaiveDedupe {
  final List<(String, int)> shown = [];
  bool allow(String key, int now, int windowMs, int maxCount) {
    var count = shown.where((e) => e.$1 == key && e.$2 > now - windowMs).length;
    if (count >= maxCount) return false;
    shown.add((key, now));
    return true;
  }
}

/// 不读本地存储的设置
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  group("规范化", () {
    String n(String text, {List<LiveEmote>? emotes, LiveEmote? sticker}) =>
        normalizeDanmakuText(text, emotes: emotes, sticker: sticker);

    test("去掉首尾空白、合并中间的空白、英文转小写", () {
      expect(n("  Hello \t  World  "), "hello world");
      expect(n("ＧＧ　ｗｐ"), "ｇｇ ｗｐ");
      expect(n("A\nB"), "a b");
      expect(n("666"), n(" 666 "));
    });

    test("去掉句末标点，句中的不动", () {
      expect(n("666！！！"), "666");
      expect(n("666!!!"), "666");
      expect(n("好的。"), "好的");
      expect(n("真的吗？？"), "真的吗");
      expect(n("hi... "), "hi");
      expect(n("来了～～"), "来了");
      expect(n("哈哈，"), "哈哈");
      expect(n("a!b"), "a!b");
      expect(n("666 ！"), "666");
    });

    test("整句都是标点时保留", () {
      expect(n("？？？"), "？？？");
      expect(n("???"), "???");
      expect(n("..."), "...");
      expect(n("? ?"), "? ?");
      expect(n("???"), isNot(n("？？？")));
    });

    test("绕过重复检查的零宽字符、标签字符去掉", () {
      expect(n("666͏"), "666");
      expect(n("666 \u{E0000}"), "666");
      expect(n("6​66"), "666");
      expect(n("﻿666"), "666");
      expect(n("\u{E0000}"), "");
    });

    test("空的和只有空白的", () {
      expect(n(""), "");
      expect(n("   "), "");
    });

    test("表情按表情本身比：表情的文字不转小写，结尾是表情时不去标点", () {
      var kappa = emote("Kappa");
      expect(n("Kappa", emotes: [kappa]), "Kappa");
      // 不是表情的“kappa”转成小写，和表情“Kappa”不算同一句
      expect(n("KAPPA"), "kappa");
      expect(n("Kappa", emotes: [kappa]), isNot(n("kappa")));
      var sad = emote("D:", spaced: true);
      expect(n("nice D:", emotes: [sad]), "nice D:");
      expect(n("nice D:"), "nice d");
      expect(n("LUL  Hello   LUL", emotes: [emote("LUL")]), "LUL hello LUL");
      expect(n("[doge][doge]！", emotes: [emote("[doge]")]), "[doge][doge]");
      expect(
        n("Hi [doge]", emotes: [emote("[doge]")]),
        n("hi  [doge]", emotes: [emote("[doge]")]),
      );
    });

    test("大表情按大表情本身比", () {
      var big =
          const LiveEmote(text: "[打call]", url: "https://e.test/call.png");
      expect(n("[打call]", sticker: big), n("[打call]", sticker: big));
      expect(n("[打call]", sticker: big), isNot(n("[打call]")));
    });
  });

  group("时间范围", () {
    test("允许 1～5 次：前几次显示，之后过滤", () {
      for (var max = 1; max <= 5; max++) {
        var w = DanmakuRepeatWindow();
        var shown = 0;
        for (var i = 0; i < max + 3; i++) {
          if (w.allow("666", i * 100, windowMs: 10000, maxCount: max)) {
            shown++;
          }
        }
        expect(shown, max, reason: "允许 $max 次");
      }
    });

    test("边界：正好一个时间范围以后再显示，差 1 毫秒还不行", () {
      var w = DanmakuRepeatWindow();
      bool allow(int t) => w.allow("a", t, windowMs: 10000, maxCount: 1);
      expect(allow(0), isTrue);
      expect(allow(9999), isFalse);
      expect(allow(10000), isTrue);
      expect(allow(19999), isFalse);
      expect(allow(20000), isTrue);
    });

    test("滑动：允许 2 次时最早的一次过期后又能显示一次", () {
      var w = DanmakuRepeatWindow();
      bool allow(int t) => w.allow("a", t, windowMs: 10000, maxCount: 2);
      expect(allow(0), isTrue);
      expect(allow(5000), isTrue);
      expect(allow(6000), isFalse);
      expect(allow(10000), isTrue); // 0 的那次过期
      expect(allow(10001), isFalse);
      expect(allow(15000), isTrue); // 5000 的那次过期
    });

    test("被过滤的不计数：一直刷同一句，每个时间范围显示一次", () {
      var w = DanmakuRepeatWindow();
      var shownAt = <int>[];
      for (var t = 0; t <= 60000; t += 1000) {
        if (w.allow("刷", t, windowMs: 10000, maxCount: 1)) shownAt.add(t);
      }
      expect(shownAt, [0, 10000, 20000, 30000, 40000, 50000, 60000]);
    });

    test("不同的键各算各的", () {
      var w = DanmakuRepeatWindow();
      expect(w.allow("a", 0, windowMs: 10000, maxCount: 1), isTrue);
      expect(w.allow("b", 1, windowMs: 10000, maxCount: 1), isTrue);
      expect(w.allow("a", 2, windowMs: 10000, maxCount: 1), isFalse);
      expect(w.distinct, 2);
    });

    test("时间往回走按上一次的时间算", () {
      var w = DanmakuRepeatWindow();
      expect(w.allow("a", 50000, windowMs: 10000, maxCount: 1), isTrue);
      expect(w.allow("a", 1000, windowMs: 10000, maxCount: 1), isFalse);
      expect(w.allow("a", 60000, windowMs: 10000, maxCount: 1), isTrue);
    });

    test("时间范围随时改：改短后早的马上过期", () {
      var w = DanmakuRepeatWindow();
      expect(w.allow("a", 0, windowMs: 60000, maxCount: 1), isTrue);
      expect(w.allow("a", 5000, windowMs: 60000, maxCount: 1), isFalse);
      expect(w.allow("a", 5000, windowMs: 3000, maxCount: 1), isTrue);
    });

    test("记的条数有上限，满了先丢最早的", () {
      var w = DanmakuRepeatWindow(maxEntries: 100);
      for (var i = 0; i < 1000; i++) {
        w.allow("k$i", i, windowMs: 60000, maxCount: 1);
      }
      expect(w.length, 100);
      expect(w.distinct, 100);
      // 最早的已经丢了，可以再显示；最近的还在
      expect(w.allow("k0", 1000, windowMs: 60000, maxCount: 1), isTrue);
      expect(w.allow("k999", 1000, windowMs: 60000, maxCount: 1), isFalse);
    });

    test("清空以后重新开始", () {
      var w = DanmakuRepeatWindow();
      for (var i = 0; i < 500; i++) {
        w.allow("k${i % 7}", i, windowMs: 60000, maxCount: 5);
      }
      w.clear();
      expect(w.length, 0);
      expect(w.distinct, 0);
      expect(w.allow("k1", 0, windowMs: 60000, maxCount: 1), isTrue);
    });

    test("大量随机弹幕：和笨办法的结果完全一样", () {
      var random = Random(7);
      for (var max = 1; max <= 5; max++) {
        var w = DanmakuRepeatWindow();
        var naive = NaiveDedupe();
        var t = 0;
        var windowMs = 3000 * max;
        for (var i = 0; i < 4000; i++) {
          t += random.nextInt(40);
          var key = "k${random.nextInt(30)}";
          expect(
            w.allow(key, t, windowMs: windowMs, maxCount: max),
            naive.allow(key, t, windowMs, max),
            reason: "第 $i 条，允许 $max 次",
          );
        }
      }
    });
  });

  group("直播间", () {
    var options = const DanmakuDedupeOptions();
    late Clock clock;
    late DanmakuDedupeFilter filter;
    setUp(() {
      options = const DanmakuDedupeOptions();
      clock = Clock();
      filter = DanmakuDedupeFilter(
        options: () => options,
        siteId: () => "bilibili",
        now: clock.call,
      );
    });

    test("关着时什么都不过滤", () {
      options = DanmakuDedupeOptions.off;
      for (var i = 0; i < 5; i++) {
        expect(filter.check(chat("666")), DanmakuRepeat.none);
      }
      expect(filter.length, 0);
    });

    test("同一个人：别人发同样的照常显示，同一个人再发不上视频", () {
      expect(filter.check(chat("666", user: "甲")), DanmakuRepeat.none);
      expect(filter.check(chat("666", user: "乙")), DanmakuRepeat.none);
      clock.ms = 3000;
      expect(filter.check(chat("666！", user: "甲")), DanmakuRepeat.video);
      clock.ms = 10000;
      expect(filter.check(chat("666", user: "甲")), DanmakuRepeat.none);
    });

    test("只看内容：谁发的都算", () {
      options = const DanmakuDedupeOptions(byUser: false);
      expect(filter.check(chat("666", user: "甲")), DanmakuRepeat.none);
      expect(filter.check(chat("666", user: "乙")), DanmakuRepeat.video);
      expect(filter.check(chat("777", user: "乙")), DanmakuRepeat.none);
    });

    test("聊天区也去掉重复：整条不显示", () {
      options = const DanmakuDedupeOptions(chatToo: true);
      expect(filter.check(chat("666")), DanmakuRepeat.none);
      expect(filter.check(chat("666")), DanmakuRepeat.all);
    });

    test("自己发的不过滤，也不计数", () {
      options = const DanmakuDedupeOptions(byUser: false);
      expect(
          filter.check(chat("666", user: "我"), self: true), DanmakuRepeat.none);
      expect(
          filter.check(chat("666", user: "我"), self: true), DanmakuRepeat.none);
      expect(filter.length, 0);
      // 自己发过的不挡别人
      expect(filter.check(chat("666", user: "乙")), DanmakuRepeat.none);
      // 别人发过的也不挡自己
      expect(
          filter.check(chat("666", user: "我"), self: true), DanmakuRepeat.none);
    });

    test("补发的历史消息不过滤，也不计数", () {
      for (var i = 0; i < 3; i++) {
        expect(filter.check(chat("666", history: true)), DanmakuRepeat.none);
      }
      expect(filter.length, 0);
      expect(filter.check(chat("666")), DanmakuRepeat.none);
    });

    test("同一个人方式下认不出是谁的不过滤", () {
      expect(filter.check(chat("666", user: "")), DanmakuRepeat.none);
      expect(filter.check(chat("666", user: "")), DanmakuRepeat.none);
    });

    test("认人的键带平台", () {
      expect(danmakuPersonKey("douyu", chat("a", user: "甲")),
          isNot(danmakuPersonKey("huya", chat("a", user: "甲"))));
      expect(danmakuPersonKey("douyu", chat("a", user: "")), isNull);
    });

    test("有用户 ID 时按 ID 认人：改名还是同一个人，同名不同 ID 是两个人", () {
      expect(danmakuPersonKey("douyu", chat("a", user: "甲", userId: "1")),
          danmakuPersonKey("douyu", chat("a", user: "乙", userId: "1")));
      expect(danmakuPersonKey("douyu", chat("a", user: "甲", userId: "1")),
          isNot(danmakuPersonKey("douyu", chat("a", user: "甲", userId: "2"))));
      expect(danmakuPersonKey("douyu", chat("a", user: "", userId: "1")),
          isNotNull);
    });

    test("改设置马上生效：次数调大、时间范围调短", () {
      expect(filter.check(chat("a")), DanmakuRepeat.none);
      expect(filter.check(chat("a")), DanmakuRepeat.video);
      options = const DanmakuDedupeOptions(maxCount: 3);
      expect(filter.check(chat("a")), DanmakuRepeat.none);
      expect(filter.check(chat("a")), DanmakuRepeat.none);
      expect(filter.check(chat("a")), DanmakuRepeat.video);
      options = const DanmakuDedupeOptions(windowSeconds: 3);
      clock.ms = 3000;
      expect(filter.check(chat("a")), DanmakuRepeat.none);
    });

    test("清空（换直播间）以后重新算", () {
      filter.check(chat("a"));
      expect(filter.check(chat("a")), DanmakuRepeat.video);
      filter.clear();
      expect(filter.check(chat("a")), DanmakuRepeat.none);
    });

    test("表情：同一个表情算重复", () {
      options = const DanmakuDedupeOptions(byUser: false);
      var doge = emote("[doge]");
      expect(filter.check(chat("[doge]", emotes: [doge])), DanmakuRepeat.none);
      expect(filter.check(chat("[doge] ", user: "乙", emotes: [doge])),
          DanmakuRepeat.video);
    });
  });

  group("大直播间", () {
    /// 像 Twitch 大直播间：每秒 300 条，七成是 200 句常见的话（带标点、大小写、
    /// 绕过检查的字符），三成是不重复的长句；5000 个人
    List<(LiveMessage, int)> traffic(int count) {
      var random = Random(42);
      var common = [for (var i = 0; i < 200; i++) "Common Phrase $i"];
      var tails = ["", "!", "！！", " ", " \u{E0000}", "͏", "?"];
      var list = <(LiveMessage, int)>[];
      for (var i = 0; i < count; i++) {
        var user = "user${random.nextInt(5000)}";
        String text;
        if (random.nextInt(10) < 7) {
          var phrase = common[random.nextInt(common.length)];
          if (random.nextBool()) phrase = phrase.toUpperCase();
          text = phrase + tails[random.nextInt(tails.length)];
        } else {
          text =
              "unique message number $i with some extra words to make it long";
        }
        list.add((chat(text, user: user), i * 1000 ~/ 300));
      }
      return list;
    }

    test("10 万条：按内容过滤掉大部分，内存有上限", () {
      var list = traffic(100000);
      var clock = Clock();
      var filter = DanmakuDedupeFilter(
        options: () =>
            const DanmakuDedupeOptions(byUser: false, windowSeconds: 60),
        siteId: () => "twitch",
        now: clock.call,
      );
      var shown = 0;
      for (var (msg, t) in list) {
        clock.ms = t;
        if (filter.check(msg) == DanmakuRepeat.none) shown++;
      }
      // 常见的话每 60 秒只显示一次，不重复的都显示
      expect(shown, lessThan(40000));
      expect(shown, greaterThan(25000));
      expect(filter.length, lessThanOrEqualTo(20000));
    });

    test("性能：10 万条在时间预算内（两种方式各一遍）", () {
      var list = traffic(100000);
      for (var byUser in [true, false]) {
        var clock = Clock();
        var filter = DanmakuDedupeFilter(
          options: () => DanmakuDedupeOptions(byUser: byUser, maxCount: 2),
          siteId: () => "twitch",
          now: clock.call,
        );
        // 先热身，让 JIT 编译好
        for (var (msg, t) in list.take(5000)) {
          clock.ms = t;
          filter.check(msg);
        }
        filter.clear();
        var watch = Stopwatch()..start();
        for (var (msg, t) in list) {
          clock.ms = t;
          filter.check(msg);
        }
        watch.stop();
        var perMessage = watch.elapsedMicroseconds / list.length;
        // ignore: avoid_print
        print("重复过滤（${byUser ? "同一个人" : "只看内容"}）：10 万条 "
            "${watch.elapsedMilliseconds} ms，每条 ${perMessage.toStringAsFixed(2)} µs");
        // 大直播间每秒几百条，每条几微秒；测试机慢、调试模式也留足余量
        expect(watch.elapsedMilliseconds, lessThan(3000));
      }
    });

    test("每条的耗时不随记着的条数变长（平均 O(1)）", () {
      double perMessage(int distinct) {
        var w = DanmakuRepeatWindow(maxEntries: 200000);
        var keys = [for (var i = 0; i < distinct; i++) "k$i"];
        var t = 0;
        for (var i = 0; i < 20000; i++) {
          w.allow(keys[i % distinct], t++, windowMs: 1 << 30, maxCount: 1);
        }
        var watch = Stopwatch()..start();
        for (var i = 0; i < 200000; i++) {
          w.allow(keys[i % distinct], t++, windowMs: 1 << 30, maxCount: 1);
        }
        return watch.elapsedMicroseconds / 200000;
      }

      var small = perMessage(100);
      var large = perMessage(100000);
      // ignore: avoid_print
      print(
          "每条：100 种 ${small.toStringAsFixed(3)} µs，10 万种 ${large.toStringAsFixed(3)} µs");
      expect(large, lessThan(small * 20 + 2));
    });
  });

  group("设置", () {
    late Directory dir;
    late Box box;
    late Box<String> shieldBox;
    late _TestSettings settings;
    const room = RoomContext(
      id: "live:1",
      siteId: "huya",
      siteName: "虎牙直播",
      roomId: "100",
      roomLabel: "主播",
    );

    setUp(() async {
      Get.testMode = true;
      dir = Directory.systemTemp.createTempSync("danmaku_filter_");
      Hive.init(dir.path);
      box = await Hive.openBox("settings");
      shieldBox = await Hive.openBox<String>("shield");
      Get.put(LocalStorageService()
        ..settingsBox = box
        ..shieldBox = shieldBox);
      settings =
          Get.put<AppSettingsController>(_TestSettings()) as _TestSettings;
    });
    tearDown(() async {
      await box.close();
      await shieldBox.close();
      Get.reset();
      dir.deleteSync(recursive: true);
    });

    test("默认关；读存着的值，超出范围的改到范围里", () async {
      settings.loadDanmakuFilterSettings();
      expect(settings.danmakuDedupeOptions.enabled, isFalse);
      await box.put(DanmakuFilterSettings.kDedupe, true);
      await box.put(DanmakuFilterSettings.kDedupeWindow, 600);
      await box.put(DanmakuFilterSettings.kDedupeMax, 0);
      await box.put(
          DanmakuFilterSettings.kDedupeMode, DanmakuFilterSettings.modeContent);
      settings.loadDanmakuFilterSettings();
      var o = settings.danmakuDedupeOptions;
      expect(o.enabled, isTrue);
      expect(o.windowSeconds, 60);
      expect(o.maxCount, 1);
      expect(o.byUser, isFalse);
      expect(o.chatToo, isFalse);
    });

    test("本直播间特别设置：过滤的几项只记到这个直播间", () {
      settings.enterRoomContext(room);
      settings.setRoomSpecific(true);
      settings.setDanmuDedupe(true);
      settings.setDanmuDedupeWindow(30);
      settings.setDanmuDedupeMax(3);
      settings.setDanmuDedupeChat(true);
      expect(box.get(DanmakuFilterSettings.kDedupe), isNull);
      var key = AppSettingsController.roomSettingsKey(room);
      var profile = json.decode(box.get(key) as String) as Map;
      expect(profile[DanmakuFilterSettings.kDedupe], isTrue);
      expect(profile[DanmakuFilterSettings.kDedupeWindow], 30);
      expect(profile[DanmakuFilterSettings.kDedupeMax], 3);
      expect(profile[DanmakuFilterSettings.kDedupeChat], isTrue);
      // 离开直播间：回到全局（关）
      settings.leaveRoomContext(room.id);
      expect(settings.danmuDedupe.value, isFalse);
      expect(settings.danmuDedupeWindow.value,
          DanmakuFilterSettings.defaultWindow);
      // 再进来：直播间的回来
      settings.enterRoomContext(room);
      expect(settings.danmuDedupe.value, isTrue);
      expect(settings.danmuDedupeMax.value, 3);
      for (var k in [
        DanmakuFilterSettings.kDedupe,
        DanmakuFilterSettings.kDedupeWindow,
        DanmakuFilterSettings.kDedupeMode,
        DanmakuFilterSettings.kDedupeMax,
        DanmakuFilterSettings.kDedupeChat,
      ]) {
        expect(settings.scopedSettingKeys, contains(k));
      }
    });

    test("本平台特别设置也行，直播间的优先", () {
      settings.enterRoomContext(room);
      settings.setSiteSpecific(true);
      settings.setDanmuDedupeMode(DanmakuFilterSettings.modeContent);
      var key = AppSettingsController.siteSettingsKey(room);
      var profile = json.decode(box.get(key) as String) as Map;
      expect(profile[DanmakuFilterSettings.kDedupeMode],
          DanmakuFilterSettings.modeContent);
      expect(box.get(DanmakuFilterSettings.kDedupeMode), isNull);
    });

    test("弹幕延迟按平台存，0～5 秒，不跟特别设置走", () {
      settings.enterRoomContext(room);
      settings.setRoomSpecific(true);
      settings.setDanmuDelay("huya", 15);
      settings.setDanmuDelay("twitch", 99);
      settings.setDanmuDelay("douyu", -3);
      expect(settings.danmuDelayMs("huya"), 1500);
      expect(settings.danmuDelayTenths("twitch"), 50);
      expect(settings.danmuDelayMs("douyu"), 0);
      expect(settings.danmuDelayMs("bilibili"), 0);
      var stored = DanmakuFilterSettings.decodeDanmakuDelays(
          box.get(DanmakuFilterSettings.kDelayBySite) as String);
      expect(stored, {"huya": 15, "twitch": 50});
      // 调回 0 就不存了
      settings.setDanmuDelay("huya", 0);
      settings.setDanmuDelay("twitch", 0);
      expect(box.get(DanmakuFilterSettings.kDelayBySite), "");
      settings.leaveRoomContext(room.id);
    });

    test("读坏的延迟设置不出错", () {
      expect(DanmakuFilterSettings.decodeDanmakuDelays(""), isEmpty);
      expect(DanmakuFilterSettings.decodeDanmakuDelays("[1,2]"), isEmpty);
      expect(DanmakuFilterSettings.decodeDanmakuDelays("{坏"), isEmpty);
      expect(
        DanmakuFilterSettings.decodeDanmakuDelays(
            '{"huya": 12, "kick": "x", "douyu": 0, "twitch": 800}'),
        {"huya": 12, "twitch": 50},
      );
    });

    test("备份时这几项只放在扩展部分（官方版不读）", () {
      for (var key in DanmakuFilterSettings.storageKeys) {
        expect(SyncCompat.isExtSetting(key), isTrue, reason: key);
        expect(SyncCompat.isLocalOnlySetting(key), isFalse, reason: key);
      }
    });
  });
}
