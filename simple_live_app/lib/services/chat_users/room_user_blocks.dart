import 'package:get/get.dart';
import 'package:simple_live_app/services/chat_users/chat_user.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/chat_users/user_block_store.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 一个直播间里的屏蔽：本机名单里在这里生效的，加上“本次进入”的。
///
/// 直播间收到消息时调用 [drops]；
/// 卡片和“本直播间屏蔽的人”通过这里屏蔽、解除
class RoomUserBlocks {
  RoomUserBlocks({
    required String Function() siteId,
    required String? Function() roomId,
    String Function()? roomLabel,
    ChatUsersService? Function()? service,
  })  : _siteId = siteId,
        _roomId = roomId,
        _roomLabel = roomLabel ?? (() => ""),
        _service = service ?? (() => ChatUsersService.maybeInstance);

  final String Function() _siteId;
  final String? Function() _roomId;
  final String Function() _roomLabel;
  final ChatUsersService? Function() _service;

  String get siteId => _siteId();

  /// “只在这个直播间”用的房间号；为空时没有这一项
  String? get roomId => _roomId();

  String get roomLabel => _roomLabel();

  /// 本次进入的屏蔽，离开直播间就没了
  late final UserBlockStore visit = UserBlockStore(
    onChanged: ({required bool persistent}) => visitVersion.value++,
  );

  /// 本次进入的名单变了时加一（和 [ChatUsersService.version] 一起看）
  final visitVersion = 0.obs;

  ChatUsersService? get service => _service();

  /// 这条直播消息的人被屏蔽了，不显示：聊天、SC、礼物
  /// （SC 和礼物看设置“被屏蔽的人发的 SC 和礼物也不显示”）。
  /// 顺便给按名字屏蔽、备注的人补上 ID
  bool drops(LiveMessage msg) {
    switch (msg.type) {
      case LiveMessageType.chat:
        break;
      case LiveMessageType.superChat:
      case LiveMessageType.gift:
        if (!(service?.hidePaid.value ?? true)) {
          return false;
        }
        break;
      default:
        return false;
    }
    var user = ChatUser.ofMessage(siteId, msg);
    service?.observe(user);
    return blocks(user);
  }

  /// 进房时读到的 SC 列表里，被屏蔽的人发的不要（看同一个设置）
  bool keepsSuperChat(LiveSuperChatMessage sc) =>
      !(service?.hidePaid.value ?? true) ||
      !blocks(ChatUser.ofSuperChat(siteId, sc));

  bool blocks(ChatUser user) {
    if (!visit.isEmpty && visit.matches(user, roomId: roomId).isNotEmpty) {
      return true;
    }
    var store = service?.blocks;
    return store != null &&
        !store.isEmpty &&
        store.matches(user, roomId: roomId).isNotEmpty;
  }

  /// 屏蔽着这个人的记录（本机的和本次进入的）
  List<UserBlock> matches(ChatUser user) => [
        ...visit.matches(user, roomId: roomId),
        ...?service?.blocks.matches(user, roomId: roomId),
      ];

  /// 卡片上显示的那一条（永久的优先，其次剩得最久的）
  UserBlock? strongest(ChatUser user) =>
      UserBlockStore.strongestOf(matches(user));

  /// 在这里生效的全部记录：整个平台的、只在这个直播间的、本次进入的
  List<UserBlock> effective() {
    var list = [
      ...?service?.blocks.effectiveIn(siteId, roomId),
      ...visit.effectiveIn(siteId, roomId),
    ];
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  /// 屏蔽。[visitOnly] 为本次进入（只在这个直播间）；否则 [roomOnly] 为只在这个直播间，
  /// [duration] 为空时永久。返回撤销用的函数
  void Function() block(
    ChatUser user, {
    bool roomOnly = false,
    bool visitOnly = false,
    Duration? duration,
  }) {
    var room = roomId;
    var block = UserBlock(
      siteId: user.siteId,
      userId: user.userId,
      midHash: user.userId == null ? user.midHash : null,
      name: user.name,
      roomId: visitOnly || (roomOnly && room != null) ? room : null,
      roomLabel: roomLabel,
      expireAt: visitOnly || duration == null
          ? null
          : DateTime.now().add(duration).millisecondsSinceEpoch,
      visit: visitOnly,
    );
    var store = visitOnly ? visit : service?.blocks;
    if (store == null) {
      return () {};
    }
    var replaced = store.add(block);
    return () => store.undo(block, replaced);
  }

  /// 解除这个人在这里生效的全部屏蔽
  void unblock(ChatUser user) {
    visit.remove(visit.matches(user, roomId: roomId));
    var store = service?.blocks;
    store?.remove(store.matches(user, roomId: roomId));
  }

  void remove(UserBlock block) {
    if (block.visit) {
      visit.remove([block]);
    } else {
      service?.blocks.remove([block]);
    }
  }

  /// 解除这里生效的全部临时屏蔽（定时的和本次进入的）
  void removeTemporary() {
    visit.clear();
    var store = service?.blocks;
    store?.remove(
      store.effectiveIn(siteId, roomId).where((e) => !e.permanent).toList(),
    );
  }

  /// 换直播间或离开时：本次进入的屏蔽解除
  void leaveRoom() => visit.clear();
}
