import 'dart:convert';

import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/live_room/chat_log.dart';
import 'package:simple_live_app/modules/live_room/user_card/chat_user_card.dart';
import 'package:simple_live_app/modules/live_room/user_card/user_block_list.dart';
import 'package:simple_live_app/services/chat_users/chat_user.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/chat_users/room_user_blocks.dart';
import 'package:simple_live_app/services/chat_users/user_block_store.dart';
import 'package:simple_live_app/services/chat_users/user_remark_store.dart';
import 'package:simple_live_core/simple_live_core.dart';

// 弹幕里的人（认人、屏蔽、本直播间名单、备注、聊天记录里的用户 ID）

LiveMessage chat(String name, {String? id, String text = "hi"}) => LiveMessage(
      type: LiveMessageType.chat,
      userName: name,
      message: text,
      color: LiveMessageColor.white,
      userId: id,
    );

LiveMessage superChat(String name, {String? id}) {
  var sc = LiveSuperChatMessage(
    backgroundBottomColor: "#000000",
    backgroundColor: "#000000",
    endTime: DateTime(2030),
    face: "",
    message: "sc",
    price: 30,
    startTime: DateTime(2026),
    userName: name,
    userId: id,
  );
  // 哔哩哔哩的 SC 消息 userName 是固定的，名字在 data 里
  return LiveMessage(
    type: LiveMessageType.superChat,
    userName: "SUPER_CHAT_MESSAGE",
    message: "SUPER_CHAT_MESSAGE",
    color: LiveMessageColor.white,
    data: sc,
    userId: id,
  );
}

LiveMessage gift(String name, {String? id}) =>
    LiveGiftMessage(userName: name, giftName: "小心心", userId: id).toMessage();

void main() {
  group("认人", () {
    test("两边都有 ID 只比 ID；有一边没有比平台和名字", () {
      const a = ChatUser("douyu", userId: "1", name: "旧名字");
      expect(
          a.sameAs(const ChatUser("douyu", userId: "1", name: "新名字")), isTrue);
      expect(
          a.sameAs(const ChatUser("douyu", userId: "2", name: "旧名字")), isFalse);
      expect(a.sameAs(const ChatUser("douyu", name: "旧名字")), isTrue);
      expect(
          a.sameAs(const ChatUser("huya", userId: "1", name: "旧名字")), isFalse);
      expect(
        const ChatUser("douyu", name: "甲")
            .sameAs(const ChatUser("douyu", name: "甲 ")),
        isFalse,
      );
    });

    test("SC、礼物按里面的人认，不按消息的 userName", () {
      var user = ChatUser.ofMessage("bilibili", superChat("乙", id: "9"));
      expect(user.name, "乙");
      expect(user.userId, "9");
      expect(ChatUser.ofMessage("douyu", gift("丙", id: "3")).name, "丙");
    });

    test("剩余时间的写法", () {
      expect(chatUserRemainingText(const Duration(seconds: 10)), "1 分钟");
      expect(chatUserRemainingText(const Duration(minutes: 25)), "25 分钟");
      expect(chatUserRemainingText(const Duration(minutes: 60)), "1 小时");
      expect(chatUserRemainingText(const Duration(minutes: 185)), "3 小时 5 分钟");
      expect(chatUserRemainingText(const Duration(hours: 100)), "4 天 4 小时");
      expect(chatUserRemainingText(const Duration(hours: 240)), "10 天");
      expect(chatUserLabel("", midHash: "ab12"), "ab12");
      expect(chatUserLabel("", userId: "7"), "7");
    });
  });

  group("屏蔽名单", () {
    late int now;
    late UserBlockStore store;
    var changes = <bool>[];
    setUp(() {
      now = 1000000;
      changes.clear();
      store = UserBlockStore(
        clock: () => now,
        onChanged: ({required bool persistent}) => changes.add(persistent),
      );
    });

    test("按 ID 屏蔽：改名后照样屏蔽，名单显示最近的名字", () {
      store.add(UserBlock(siteId: "douyu", userId: "1", name: "旧名字"));
      expect(store.matches(const ChatUser("douyu", userId: "1", name: "新名字")),
          hasLength(1));
      // 别人用了同一个名字（ID 不同）不算
      expect(store.matches(const ChatUser("douyu", userId: "2", name: "旧名字")),
          isEmpty);
      expect(store.observe(const ChatUser("douyu", userId: "1", name: "新名字")),
          isTrue);
      expect(store.items.single.name, "新名字");
      expect(changes.last, isTrue);
    });

    test("只按 ID 屏蔽：没有 ID 的不记，也不按名字认", () {
      // 没登录的哔哩哔哩只有打码的名字、没有 ID：不屏蔽，免得误伤同一个打码名字的人
      expect(store.add(UserBlock(siteId: "bilibili", name: "用***")), isEmpty);
      expect(store.isEmpty, isTrue);
      expect(const ChatUser("bilibili", name: "用***").hasId, isFalse);
      store.add(UserBlock(siteId: "bilibili", userId: "5", name: "用***"));
      // 同一个名字、没有 ID 或 ID 不同的都不算
      expect(store.matches(const ChatUser("bilibili", name: "用***")), isEmpty);
      expect(
          store.matches(const ChatUser("bilibili", userId: "6", name: "用***")),
          isEmpty);
      expect(store.matches(const ChatUser("bilibili", userId: "5", name: "改了")),
          hasLength(1));
      // 存档里没有 ID 的记录读不进来
      expect(UserBlock.fromJson({"s": "bilibili", "n": "用***"}), isNull);
    });

    test("范围：整个平台，或只在一个直播间", () {
      store.add(UserBlock(siteId: "huya", userId: "1", name: "a"));
      store.add(
          UserBlock(siteId: "huya", userId: "2", name: "b", roomId: "100"));
      const a = ChatUser("huya", userId: "1", name: "a");
      const b = ChatUser("huya", userId: "2", name: "b");
      expect(store.matches(a, roomId: "200"), hasLength(1));
      expect(store.matches(b, roomId: "100"), hasLength(1));
      expect(store.matches(b, roomId: "200"), isEmpty);
      expect(store.effectiveIn("huya", "100"), hasLength(2));
      expect(store.effectiveIn("huya", "200"), hasLength(1));
      expect(store.effectiveIn("douyu", "100"), isEmpty);
    });

    test("定时的到期自动解除；永久的不会", () {
      store.add(UserBlock(
          siteId: "douyu", userId: "1", name: "a", expireAt: now + 60000));
      store.add(UserBlock(siteId: "douyu", userId: "2", name: "b"));
      expect(store.matches(const ChatUser("douyu", userId: "1", name: "a")),
          hasLength(1));
      now += 60001;
      expect(store.matches(const ChatUser("douyu", userId: "1", name: "a")),
          isEmpty);
      expect(store.purgeExpired(), isTrue);
      expect(store.items.map((e) => e.userId), ["2"]);
      expect(store.purgeExpired(), isFalse);
    });

    test("同一个人同一个范围换一种时长：替换；撤销时放回原来的", () {
      var first = UserBlock(
          siteId: "douyu", userId: "1", name: "a", expireAt: now + 1000);
      store.add(first);
      var second = UserBlock(siteId: "douyu", userId: "1", name: "a");
      var replaced = store.add(second);
      expect(replaced, [first]);
      expect(store.items, [second]);
      store.undo(second, replaced);
      expect(store.items, [first]);
      // 范围不同的两条可以并存
      store
          .add(UserBlock(siteId: "douyu", userId: "1", name: "a", roomId: "9"));
      expect(store.items, hasLength(2));
    });

    test("最“重”的一条：永久 > 本次进入 > 剩得久的", () {
      var t1 = UserBlock(siteId: "s", name: "a", expireAt: now + 10);
      var t2 =
          UserBlock(siteId: "s", name: "a", expireAt: now + 20, roomId: "r");
      expect(UserBlockStore.strongestOf([t1, t2]), t2);
      var visit = UserBlock(siteId: "s", name: "a", roomId: "r", visit: true);
      expect(UserBlockStore.strongestOf([t1, visit]), visit);
      var p = UserBlock(siteId: "s", name: "a");
      expect(UserBlockStore.strongestOf([visit, p, t2]), p);
      expect(UserBlockStore.strongestOf([]), isNull);
    });

    test("一键解除临时的、清空；只有永久的变化才要同步", () {
      store.add(
          UserBlock(siteId: "s", userId: "1", name: "a", expireAt: now + 10));
      expect(changes.last, isFalse);
      store.add(UserBlock(siteId: "s", userId: "2", name: "b"));
      expect(changes.last, isTrue);
      store.removeTemporary();
      expect(store.items.map((e) => e.name), ["b"]);
      store.clear();
      expect(store.isEmpty, isTrue);
    });

    test("只有 crc32 的记录：直播间里认出来后补上 uid 和名字", () {
      var hash = getCrc32(utf8.encode("8888")).toRadixString(16);
      store.add(UserBlock(siteId: "bilibili", midHash: hash, name: ""));
      const live = ChatUser("bilibili", userId: "8888", name: "主播的粉丝");
      expect(store.matches(live), hasLength(1));
      store.observe(live);
      var block = store.items.single;
      expect(block.userId, "8888");
      expect(block.midHash, isNull);
      expect(block.name, "主播的粉丝");
      // 直播间里屏蔽的人，只有 crc32 时也认得出
      var hashOnly = ChatUser("bilibili", midHash: hash, name: "");
      expect(store.matches(hashOnly), hasLength(1));
    });

    test("存档：本次进入的不存；同步只要永久的", () {
      store.add(UserBlock(
          siteId: "s", userId: "1", name: "a", roomId: "r", roomLabel: "主播"));
      store.add(
          UserBlock(siteId: "s", userId: "2", name: "b", expireAt: now + 10));
      store.add(UserBlock(
          siteId: "s", userId: "3", name: "c", roomId: "r", visit: true));
      expect(store.toJson(), hasLength(2));
      var synced = store.toJson(permanentOnly: true);
      expect(synced, hasLength(1));
      var back = UserBlock.fromJson(jsonDecode(jsonEncode(synced.single)))!;
      expect(back.userId, "1");
      expect(back.roomId, "r");
      expect(back.roomLabel, "主播");
      expect(back.permanent, isTrue);
      expect(UserBlock.fromJson({"s": "x"}), isNull);
      expect(UserBlock.fromJson("bad"), isNull);
    });

    test("很多条记录也按索引查", () {
      for (var i = 0; i < 2000; i++) {
        store.add(UserBlock(siteId: "twitch", userId: "$i", name: "u$i"));
      }
      var watch = Stopwatch()..start();
      for (var i = 0; i < 20000; i++) {
        store.matches(ChatUser("twitch", userId: "x$i", name: "n$i"));
      }
      expect(watch.elapsedMilliseconds, lessThan(1000));
      expect(store.matches(const ChatUser("twitch", userId: "1999", name: "?")),
          hasLength(1));
    });
  });

  group("备注", () {
    test("按 ID 存，改名后还在；名字后面跟着改", () {
      var remarks = UserRemarkStore();
      remarks.set(const ChatUser("douyu", userId: "1", name: "旧名字"), " 老朋友 ");
      expect(
          remarks.remarkOf(const ChatUser("douyu", userId: "1", name: "新名字")),
          "老朋友");
      expect(
          remarks.remarkOf(const ChatUser("douyu", userId: "2", name: "旧名字")),
          isNull);
      expect(remarks.remarkOf(const ChatUser("huya", userId: "1", name: "旧名字")),
          isNull);
      remarks.observe(const ChatUser("douyu", userId: "1", name: "新名字"));
      expect(remarks.items.single.name, "新名字");
    });

    test("只按 ID：没有 ID 的不写；同名的其他人不显示；改名后还在", () {
      var changed = 0;
      var remarks = UserRemarkStore(onChanged: () => changed++);
      remarks.set(const ChatUser("bilibili", name: "用***"), "备注");
      expect(remarks.isEmpty, isTrue);
      remarks.set(const ChatUser("bilibili", userId: "3", name: "甲"), "备注");
      expect(remarks.remarkOf(const ChatUser("bilibili", name: "甲")), isNull);
      expect(
          remarks.remarkOf(const ChatUser("bilibili", userId: "4", name: "甲")),
          isNull);
      remarks.observe(const ChatUser("bilibili", userId: "3", name: "乙"));
      expect(remarks.items.single.name, "乙");
      expect(
          remarks.remarkOf(const ChatUser("bilibili", userId: "3", name: "乙")),
          "备注");
      expect(changed, 2);
      expect(
          UserRemark.fromJson({"s": "bilibili", "n": "甲", "r": "备注"}), isNull);
    });

    test("哔哩哔哩只有 crc32 的备注：直播弹幕带 uid 时也认得出", () {
      var remarks = UserRemarkStore();
      var hash = getCrc32(utf8.encode("12345")).toRadixString(16);
      remarks.set(ChatUser("bilibili", midHash: hash, name: ""), "备注");
      expect(
          remarks
              .remarkOf(const ChatUser("bilibili", userId: "12345", name: "甲")),
          "备注");
    });

    test("改备注换掉原来的；空的就是删除；太长的截断", () {
      var remarks = UserRemarkStore();
      const u = ChatUser("kick", userId: "1", name: "a");
      remarks.set(u, "一");
      remarks.set(u, "二");
      expect(remarks.items.single.remark, "二");
      remarks.set(u, "  ");
      expect(remarks.isEmpty, isTrue);
      remarks.set(u, "长" * 50);
      expect(remarks.remarkOf(u)!.length, UserRemarkStore.maxLength);
    });

    test("合并：同一个人以新写的为准", () {
      var remarks = UserRemarkStore();
      remarks.load([
        UserRemark(
            siteId: "s", userId: "1", name: "a", remark: "旧", updatedAt: 1),
        UserRemark(
            siteId: "s", userId: "2", name: "b", remark: "本机新", updatedAt: 9),
      ]);
      remarks.merge([
        UserRemark(
            siteId: "s", userId: "1", name: "a", remark: "云端新", updatedAt: 5),
        UserRemark(
            siteId: "s", userId: "2", name: "b", remark: "云端旧", updatedAt: 3),
        UserRemark(
            siteId: "s", userId: "3", name: "c", remark: "新人", updatedAt: 3),
      ]);
      expect(
        {for (var e in remarks.items) e.userId: e.remark},
        {"1": "云端新", "2": "本机新", "3": "新人"},
      );
    });
  });

  group("服务：存档、同步", () {
    late MemoryChatUsersStorage storage;
    late ChatUsersService service;
    setUp(() async {
      storage = MemoryChatUsersStorage();
      service = ChatUsersService(storage: storage, purgeInterval: null);
      await service.init();
    });
    tearDown(() => service.onClose());

    test("改动存下来，重新打开还在", () async {
      service.blocks.add(UserBlock(siteId: "s", userId: "1", name: "a"));
      service.blocks.add(
        UserBlock(
          siteId: "s",
          userId: "2",
          name: "b",
          expireAt: DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        ),
      );
      service.remarks.set(const ChatUser("s", userId: "1", name: "a"), "备注");
      var again = ChatUsersService(storage: storage, purgeInterval: null);
      await again.init();
      expect(again.blocks.items, hasLength(2));
      expect(
          again.remarkOf(const ChatUser("s", userId: "1", name: "改名")), "备注");
      again.onClose();
    });

    test("到期的重新打开时去掉", () async {
      storage.values[ChatUsersService.kBlocks] = jsonEncode([
        UserBlock(siteId: "s", userId: "1", name: "a", expireAt: 1).toJson(),
        UserBlock(siteId: "s", userId: "2", name: "b").toJson(),
      ]);
      var again = ChatUsersService(storage: storage, purgeInterval: null);
      await again.init();
      expect(again.blocks.items.map((e) => e.name), ["b"]);
      again.onClose();
    });

    test("存档坏了不出错", () async {
      storage.values[ChatUsersService.kBlocks] = "{bad";
      storage.values[ChatUsersService.kRemarks] = jsonEncode({"x": 1});
      var again = ChatUsersService(storage: storage, purgeInterval: null);
      await again.init();
      expect(again.blocks.isEmpty, isTrue);
      expect(again.remarks.isEmpty, isTrue);
      again.onClose();
    });

    test("同步只发永久屏蔽和备注；永久的或备注变了才通知", () async {
      var events = 0;
      var sub = service.syncedChanges.listen((_) => events++);
      service.blocks.add(
        UserBlock(
            siteId: "s",
            name: "t",
            expireAt: DateTime(2100).millisecondsSinceEpoch),
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, 0);
      service.blocks.add(UserBlock(siteId: "s", userId: "1", name: "p"));
      service.remarks.set(const ChatUser("s", userId: "1", name: "p"), "r");
      await Future<void>.delayed(Duration.zero);
      expect(events, 2);
      var data = service.exportSync();
      expect((data["blocks"] as List).map((e) => e["n"]), ["p"]);
      expect((data["remarks"] as List), hasLength(1));
      await sub.cancel();
    });

    test("收到同步：覆盖时以对方为准，本机的定时屏蔽留着；合并时加上没有的", () {
      service.blocks.add(UserBlock(siteId: "s", userId: "1", name: "本机永久"));
      service.blocks.add(
        UserBlock(
            siteId: "s",
            userId: "2",
            name: "本机定时",
            expireAt: DateTime(2100).millisecondsSinceEpoch),
      );
      var incoming = {
        "blocks": [
          UserBlock(siteId: "s", userId: "3", name: "对方永久").toJson(),
          // 对方发来定时的也不收（只同步永久的）
          UserBlock(siteId: "s", userId: "4", name: "对方定时", expireAt: 99)
              .toJson(),
        ],
        "remarks": [
          UserRemark(siteId: "s", userId: "3", name: "对方永久", remark: "对方写的")
              .toJson(),
        ],
      };
      service.importSync(incoming, replace: false);
      expect(service.blocks.items.map((e) => e.name).toSet(),
          {"本机永久", "本机定时", "对方永久"});
      service.importSync(incoming, replace: true);
      expect(service.blocks.items.map((e) => e.name).toSet(), {"本机定时", "对方永久"});
      expect(service.remarkOf(const ChatUser("s", userId: "3", name: "x")),
          "对方写的");
      // 不收屏蔽时只动备注
      service.importSync(
        {"blocks": [], "remarks": []},
        replace: true,
        includeBlocks: false,
      );
      expect(service.blocks.items, hasLength(2));
      expect(service.remarks.isEmpty, isTrue);
    });
  });

  group("直播间里的屏蔽", () {
    late ChatUsersService service;
    late RoomUserBlocks room;
    var roomId = "100";
    setUp(() async {
      service = ChatUsersService(
          storage: MemoryChatUsersStorage(), purgeInterval: null);
      await service.init();
      room = RoomUserBlocks(
        siteId: () => "douyu",
        roomId: () => roomId,
        roomLabel: () => "主播",
        service: () => service,
      );
    });
    tearDown(() => service.onClose());

    test("屏蔽的人发的聊天、SC、礼物刚进来就拦下；SC 和礼物看设置", () {
      room.block(const ChatUser("douyu", userId: "1", name: "a"));
      expect(room.drops(chat("a", id: "1")), isTrue);
      expect(room.drops(chat("改名了", id: "1")), isTrue);
      expect(room.drops(chat("b", id: "2")), isFalse);
      expect(room.drops(superChat("a", id: "1")), isTrue);
      expect(room.drops(gift("a", id: "1")), isTrue);
      service.setHidePaid(false);
      expect(room.drops(superChat("a", id: "1")), isFalse);
      expect(room.drops(gift("a", id: "1")), isFalse);
      expect(room.drops(chat("a", id: "1")), isTrue);
      // 别的消息不管
      expect(
        room.drops(LiveRoomStats(viewers: 1).toMessage()),
        isFalse,
      );
    });

    test("进房时读到的 SC 列表也去掉", () {
      room.block(const ChatUser("douyu", userId: "7", name: "a"));
      var sc = superChat("a", id: "7").data as LiveSuperChatMessage;
      expect(room.keepsSuperChat(sc), isFalse);
      service.setHidePaid(false);
      expect(room.keepsSuperChat(sc), isTrue);
    });

    test("只按 ID 屏蔽：没有 ID 的人点了也不记；同名的其他人不受影响", () {
      room.block(const ChatUser("douyu", name: "a"));
      expect(service.blocks.isEmpty, isTrue);
      room.block(const ChatUser("douyu", userId: "42", name: "a"));
      expect(room.drops(chat("新名字", id: "42")), isTrue);
      expect(room.drops(chat("a", id: "43")), isFalse);
      expect(room.drops(chat("a")), isFalse);
    });

    test("本次进入：只在内存里，离开直播间就解除", () {
      room.block(const ChatUser("douyu", userId: "1", name: "a"),
          visitOnly: true);
      expect(service.blocks.isEmpty, isTrue);
      expect(room.drops(chat("a", id: "1")), isTrue);
      expect(
          room.strongest(const ChatUser("douyu", userId: "1", name: "a"))!.kind,
          UserBlockKind.visit);
      room.leaveRoom();
      expect(room.drops(chat("a", id: "1")), isFalse);
    });

    test("只在这个直播间：换了直播间就不屏蔽", () {
      room.block(const ChatUser("douyu", userId: "1", name: "a"),
          roomOnly: true);
      expect(service.blocks.items.single.roomId, "100");
      expect(room.drops(chat("a", id: "1")), isTrue);
      roomId = "200";
      expect(room.drops(chat("a", id: "1")), isFalse);
      roomId = "100";
    });

    test("定时；撤销；解除", () {
      var undo = room.block(
        const ChatUser("douyu", userId: "1", name: "a"),
        duration: const Duration(minutes: 5),
      );
      var block = service.blocks.items.single;
      expect(block.kind, UserBlockKind.timed);
      expect(block.expireAt! - DateTime.now().millisecondsSinceEpoch,
          inInclusiveRange(4 * 60000, 5 * 60000));
      undo();
      expect(service.blocks.isEmpty, isTrue);
      room.block(const ChatUser("douyu", userId: "1", name: "a"));
      room.block(const ChatUser("douyu", userId: "1", name: "a"),
          visitOnly: true);
      room.unblock(const ChatUser("douyu", userId: "1", name: "a"));
      expect(room.drops(chat("a", id: "1")), isFalse);
    });

    test("本直播间名单：全平台的、只在这里的、本次进入的；一键解除临时的", () {
      room.block(const ChatUser("douyu", userId: "1", name: "全平台"));
      room.block(const ChatUser("douyu", userId: "2", name: "本直播间"),
          roomOnly: true);
      room.block(const ChatUser("douyu", userId: "3", name: "本次"),
          visitOnly: true);
      room.block(
        const ChatUser("douyu", userId: "4", name: "定时"),
        duration: const Duration(hours: 1),
      );
      service.blocks.add(UserBlock(
          siteId: "douyu", userId: "5", name: "别的直播间", roomId: "999"));
      service.blocks.add(UserBlock(siteId: "huya", userId: "6", name: "别的平台"));
      expect(room.effective().map((e) => e.name).toSet(),
          {"全平台", "本直播间", "本次", "定时"});
      room.removeTemporary();
      expect(room.effective().map((e) => e.name).toSet(), {"全平台", "本直播间"});
      // 别的直播间、别的平台的不动
      expect(service.blocks.items, hasLength(4));
    });
  });

  group("卡片和名单的文字", () {
    test("第一级“屏蔽这个人”那一行", () {
      var now = DateTime(2026, 1, 1, 12);
      expect(ChatUserCard.blockedTitleFor(null), "屏蔽这个人");
      expect(
        ChatUserCard.blockedTitleFor(UserBlock(siteId: "s", name: "a")),
        "已永久屏蔽",
      );
      expect(
        ChatUserCard.blockedTitleFor(
          UserBlock(
            siteId: "s",
            name: "a",
            expireAt:
                now.add(const Duration(minutes: 25)).millisecondsSinceEpoch,
          ),
          now: now,
        ),
        "已屏蔽（还剩 25 分钟）",
      );
      expect(
        ChatUserCard.blockedTitleFor(
            UserBlock(siteId: "s", name: "a", roomId: "1", visit: true)),
        "已屏蔽（本次进入）",
      );
    });

    test("名单里的范围和时长", () {
      var now = DateTime(2026, 1, 1).millisecondsSinceEpoch;
      expect(userBlockDetail(UserBlock(siteId: "s", name: "a"), now: now),
          "全平台 · 永久");
      expect(
        userBlockDetail(
          UserBlock(
              siteId: "s", name: "a", roomId: "1", expireAt: now + 600000),
          now: now,
        ),
        "本直播间 · 还剩 10 分钟",
      );
      expect(
        userBlockDetail(
          UserBlock(siteId: "s", name: "a", roomId: "1", roomLabel: "主播"),
          showRoom: true,
          now: now,
        ),
        "直播间 主播 · 永久",
      );
      expect(
        userBlockDetail(
            UserBlock(siteId: "s", name: "a", roomId: "1", visit: true),
            now: now),
        "本次进入",
      );
    });
  });

  test("聊天记录：存进临时文件的旧消息也带着用户 ID", () async {
    var log = ChatLog(chunkSize: 4, hotChunks: 1);
    for (var i = 0; i < 20; i++) {
      log.add(LiveChatRecord(
          DateTime(2026), chat("n$i", id: i.isEven ? "$i" : null)));
    }
    // 最早的几块已经编码转存，读回来时 ID 还在
    expect(log[0].message.userId, "0");
    expect(log[1].message.userId, isNull);
    expect(log[18].message.userId, "18");
    var found = await log.where(
      (e) => sameLiveUser("4", "改名后", e.message.userId, e.message.userName),
    );
    expect(found!.single.message.userName, "n4");
    log.dispose();
  });

  tearDown(Get.reset);
}
