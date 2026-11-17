import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/live_gift_list.dart';
import 'package:simple_live_app/modules/live_room/live_gifts.dart';
import 'package:simple_live_app/modules/live_room/player/notice_queue.dart';
import 'package:simple_live_app/services/danmaku_export.dart';
import 'package:simple_live_app/services/obs_bridge/ass_writer.dart';
import 'package:simple_live_core/simple_live_core.dart';

LiveGiftMessage gift({
  String? combo,
  int count = 1,
  bool paid = true,
  String name = "小心心",
}) =>
    LiveGiftMessage(
      comboId: combo,
      userName: "用户A",
      action: "投喂",
      giftName: name,
      count: count,
      paid: paid,
      priceText: paid ? "¥1" : null,
    );

LiveMessage chat(String text,
        {String user = "用户B",
        bool history = false,
        List<LiveEmote>? emotes,
        LiveEmote? sticker}) =>
    LiveMessage(
      type: LiveMessageType.chat,
      userName: user,
      message: text,
      color: LiveMessageColor.white,
      history: history,
      emotes: emotes,
      sticker: sticker,
    );

LiveSuperChatMessage sc(DateTime start, {int seconds = 60}) =>
    LiveSuperChatMessage(
      backgroundBottomColor: "#000000",
      backgroundColor: "#000000",
      endTime: start.add(Duration(seconds: seconds)),
      face: "",
      message: "SC 内容",
      price: 30,
      startTime: start,
      userName: "用户C",
    );

void main() {
  final t0 = DateTime(2026, 11, 13, 20, 0, 0);

  group('礼物页：连击合成一行', () {
    test('同一个连击更新数量，时间是第一次收到的', () {
      var book = GiftBook();
      var (first, isNew) = book.add(gift(combo: "c1"), now: t0);
      expect(isNew, isTrue);
      var (again, isNew2) = book.add(
        gift(combo: "c1", count: 5),
        now: t0.add(const Duration(seconds: 3)),
      );
      expect(isNew2, isFalse);
      expect(identical(first, again), isTrue);
      expect(book.records.length, 1);
      expect(first.gift.count, 5);
      expect(first.time, t0);
      expect(first.updatedAt, t0.add(const Duration(seconds: 3)));
      // 晚到的较早一条不会把数量改小
      book.add(gift(combo: "c1", count: 3));
      expect(first.gift.count, 5);
    });

    test('没有连击 id 的每条单独一行；免费礼物也记下', () {
      var book = GiftBook();
      book.add(gift());
      book.add(gift(paid: false));
      expect(book.records.length, 2);
      expect(book.records.last.gift.paid, isFalse);
    });

    test('超过上限时丢掉最早的，连击 id 跟着清掉', () {
      var book = GiftBook(maxCount: 10);
      for (var i = 0; i < 11; i++) {
        book.add(gift(combo: "c$i"));
      }
      // 一次丢掉超出的再加上限的五分之一（11 - 1 - 2 = 8），不用每条都挪
      expect(book.records.length, 8);
      // 被丢掉的 c0 再来时算新的一行
      var (_, isNew) = book.add(gift(combo: "c0", count: 2));
      expect(isNew, isTrue);
    });
  });

  test('开通、续费的标签颜色', () {
    expect(giftActionColor("开通"), isNotNull);
    expect(giftActionColor("自动续费"), giftActionColor("续费"));
    expect(giftActionColor("续费"), isNot(giftActionColor("开通")));
    expect(giftActionColor("投喂"), isNull);
  });


  group('视频左下角：SC 和礼物共用位置和队列', () {
    int remaining(LiveSuperChatMessage s) => 60;

    test('先来先显示，最多 4 张，其余排队', () {
      var q = NoticeQueue();
      var book = GiftBook();
      q.pushSuperChat(sc(t0), "sc1");
      for (var i = 0; i < 5; i++) {
        q.pushGift(book.add(gift(combo: "g$i")).$1, t0);
      }
      q.tick(t0, remaining);
      expect(q.shown.length, 4);
      expect(q.shown.first.isGift, isFalse);
      expect(q.queued.length, 2);
      // 礼物显示 5 秒，收起后排队的补上
      q.tick(t0.add(const Duration(seconds: 4)), remaining);
      expect(q.queued.length, 2);
      q.tick(t0.add(const Duration(seconds: 5)), remaining);
      expect(q.shown.where((e) => e.isGift).length, 2);
      expect(q.queued, isEmpty);
    });

    test('同一条 SC 只排一次；已经结束的 SC 不显示', () {
      var q = NoticeQueue();
      var s = sc(t0);
      q.pushSuperChat(s, "sc1");
      q.pushSuperChat(s, "sc1");
      expect(q.queued.length, 1);
      q.tick(t0, (_) => 0);
      expect(q.shown, isEmpty);
    });

    test('正在显示的礼物连击时每次多显示 1 秒，不多占一张', () {
      var q = NoticeQueue();
      var book = GiftBook();
      var (record, _) = book.add(gift(combo: "c1"));
      q.pushGift(record, t0);
      q.tick(t0, remaining);
      expect(q.shown.single.hideAt, t0.add(const Duration(seconds: 5)));
      book.add(gift(combo: "c1", count: 9));
      q.pushGift(record, t0.add(const Duration(seconds: 3)));
      q.pushGift(record, t0.add(const Duration(seconds: 4)));
      expect(q.shown.length, 1);
      expect(q.shown.single.hideAt, t0.add(const Duration(seconds: 7)));
      expect(q.shown.single.gift!.gift.count, 9);
      q.tick(t0.add(const Duration(seconds: 6)), remaining);
      expect(q.shown.length, 1);
      q.tick(t0.add(const Duration(seconds: 7)), remaining);
      expect(q.shown, isEmpty);
    });

    test('连击再多，最长也只到 SC 的 15 秒', () {
      var q = NoticeQueue();
      var (record, _) = GiftBook().add(gift(combo: "c1"));
      q.pushGift(record, t0);
      q.tick(t0, remaining);
      for (var i = 0; i < 50; i++) {
        q.pushGift(record, t0.add(const Duration(seconds: 1)));
      }
      expect(q.shown.single.hideAt, t0.add(const Duration(seconds: 16)));
    });

    test('礼物刷屏时只留最近的排队，SC 不会被挤掉', () {
      var q = NoticeQueue(maxVisible: 1, maxQueuedGifts: 3);
      var book = GiftBook();
      q.pushGift(book.add(gift(combo: "first")).$1, t0);
      q.tick(t0, remaining);
      q.pushSuperChat(sc(t0), "sc1");
      for (var i = 0; i < 10; i++) {
        q.pushGift(book.add(gift(combo: "g$i")).$1, t0);
      }
      expect(q.queued.where((e) => e.isGift).length, 3);
      expect(q.queued.where((e) => !e.isGift).length, 1);
    });

    test('SC 显示 15 秒，礼物 5 秒', () {
      var q = NoticeQueue();
      q.pushSuperChat(sc(t0), "sc1");
      q.pushGift(GiftBook().add(gift()).$1, t0);
      q.tick(t0, remaining);
      expect(q.shown.map((e) => e.hideAt!.difference(t0).inSeconds), [15, 5]);
    });

    test('排太久的礼物不再显示', () {
      var q = NoticeQueue(maxVisible: 1);
      q.pushSuperChat(sc(t0, seconds: 600), "sc1");
      q.tick(t0, (_) => 600);
      q.pushGift(GiftBook().add(gift()).$1, t0);
      // SC 显示 15 秒，礼物排了 40 秒已经过时
      q.tick(t0.add(const Duration(seconds: 40)), (_) => 560);
      expect(q.shown, isEmpty);
      expect(q.queued, isEmpty);
    });
  });

  group('导出 ASS', () {
    test('按开播时间对齐：时间 = 收到的时间 - 开播时间', () {
      var start = t0.subtract(const Duration(minutes: 10));
      var origin = LiveExportOrigin.choose(
        showTime: "${start.millisecondsSinceEpoch ~/ 1000}",
        earliest: t0,
      );
      expect(origin.liveStart, isTrue);
      expect(origin.time, start);
      var count = DanmakuExportCount();
      var list = liveExportComments(
        origin: origin.time,
        chats: [
          (t0, chat("第一条")),
          (t0.add(const Duration(seconds: 5)), chat("系统提示", user: "Sys")),
          (t0, chat("进房时补发的", history: true)),
        ],
        superChats: [sc(t0.add(const Duration(seconds: 30)))],
        gifts: [GiftRecord(gift(count: 3), t0.add(const Duration(minutes: 1)))],
        sysUser: "Sys",
        count: count,
      );
      expect(count.chats, 1);
      expect(count.superChats, 1);
      expect(count.gifts, 1);
      var byText = {for (var c in list) c.text: c};
      expect(byText["第一条"]!.time, const Duration(minutes: 10));
      var gift3 = list.firstWhere((c) => c.text.startsWith("【礼物】"));
      expect(gift3.time, const Duration(minutes: 11));
      expect(gift3.text, "【礼物】用户A 投喂 小心心 ×3");
      expect(gift3.color, kAssGiftColor);
      var s = list.firstWhere((c) => c.superChat);
      expect(s.time, const Duration(minutes: 10, seconds: 30));
    });

    test('没有开播时间（或开播时间比内容还晚）时从第一条开始', () {
      expect(LiveExportOrigin.choose(earliest: t0).liveStart, isFalse);
      var late = t0.add(const Duration(hours: 1));
      var origin = LiveExportOrigin.choose(
        showTime: "${late.millisecondsSinceEpoch ~/ 1000}",
        earliest: t0,
      );
      expect(origin.liveStart, isFalse);
      expect(origin.time, t0);
    });

    test('只发表情的弹幕：保留表情的文字说明，不丢', () {
      var dogeEmote =
          const LiveEmote(text: "[doge]", url: "https://x/doge.png");
      expect(
        AssComment.chat(chat("[doge][doge]", emotes: [dogeEmote])).text,
        "[doge][doge]",
      );
      // 整条是大表情：用大表情的文字说明
      var sticker =
          const LiveEmote(text: "[热词系列_知识增加]", url: "https://x/s.png");
      expect(
        AssComment.chat(chat("知识增加", sticker: sticker)).text,
        "[热词系列_知识增加]",
      );
      // 一点文字都没有时用表情的文字，再没有才写“[表情]”
      expect(AssComment.chat(chat("", emotes: [dogeEmote])).text, "[doge]");
      expect(
        AssComment.chat(chat("", emotes: [const LiveEmote(text: "", url: "u")]))
            .text,
        "[表情]",
      );
      var ass = AssDanmakuWriter.build(
        AssOptions.fromConfig(const {}, keepAll: true),
        [
          AssComment.chat(chat("", emotes: [dogeEmote]))
        ],
        notes: const ["时间轴：0 秒是开播时间"],
      );
      expect(ass, contains("; 时间轴：0 秒是开播时间"));
      expect(ass, contains("[doge]"));
    });

    test('导出时弹幕多也全部保留', () {
      var comments = [
        for (var i = 0; i < 200; i++)
          AssComment(time: Duration.zero, text: "同一时间的弹幕 $i"),
      ];
      var ass = AssDanmakuWriter.build(
        AssOptions.fromConfig(const {}, keepAll: true),
        comments,
      );
      expect("Dialogue:".allMatches(ass).length, 200);
    });
  });
}
