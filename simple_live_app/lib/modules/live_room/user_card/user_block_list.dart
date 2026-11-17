import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/chat_users/chat_user.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/chat_users/room_user_blocks.dart';
import 'package:simple_live_app/services/chat_users/user_block_store.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 名单里一条记录的说明：范围和时长，如“全平台 · 永久”“本直播间 · 还剩 25 分钟”
String userBlockDetail(UserBlock block, {bool showRoom = false, int? now}) {
  var scope = block.visit
      ? null
      : block.roomId == null
          ? "全平台".t
          : showRoom
              ? "直播间 {room}".tf({
                  "room": block.roomLabel.isNotEmpty
                      ? block.roomLabel
                      : block.roomId,
                })
              : "本直播间".t;
  var time = switch (block.kind) {
    UserBlockKind.permanent => "永久".t,
    UserBlockKind.visit => "本次进入".t,
    UserBlockKind.timed => "还剩 {time}".tf({
        "time": chatUserRemainingText(
          Duration(
            milliseconds: block.expireAt! -
                (now ?? DateTime.now().millisecondsSinceEpoch),
          ),
        ),
      }),
  };
  return scope == null ? time : "$scope · $time";
}

/// 名单里显示的名字：最近一次用的名字，后面跟着灰色的备注
Widget userBlockName(UserBlock block) {
  var remark = ChatUsersService.maybeInstance?.remarkOf(block.user);
  var name = chatUserLabel(
    block.name,
    userId: block.userId,
    midHash: block.midHash,
  );
  return Text.rich(
    TextSpan(
      children: [
        TextSpan(text: name),
        if (remark != null)
          TextSpan(
            text: " ($remark)",
            style: const TextStyle(color: Colors.grey),
          ),
      ],
    ),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}

/// 名单的一行：名字和备注、范围和时长、右边解除
class UserBlockTile extends StatelessWidget {
  final UserBlock block;
  final bool showRoom;
  final VoidCallback onRemove;
  const UserBlockTile({
    required this.block,
    required this.onRemove,
    this.showRoom = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: userBlockName(block),
      subtitle: Text(
        userBlockDetail(block, showRoom: showRoom),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: "解除屏蔽".t,
        icon: const Icon(Icons.close),
        onPressed: onRemove,
      ),
    );
  }
}

/// 名单上的剩余时间每半分钟刷新一次
mixin _Ticking<T extends StatefulWidget> on State<T> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// 直播间设置里“本直播间屏蔽的人（N）›”打开的卡片：在这个直播间生效的所有人
/// （全平台屏蔽的、只在这个直播间屏蔽的、本次进入屏蔽的），可以单个解除，
/// 也可以一键解除全部临时屏蔽。和弹幕卡片同一个样式
Future<void> showRoomBlockList(RoomUserBlocks blocks) {
  var context = Get.context!;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxWidth: 600,
      maxHeight: MediaQuery.sizeOf(context).height * 0.9,
    ),
    builder: (_) => RoomBlockList(blocks: blocks),
  );
}

class RoomBlockList extends StatefulWidget {
  final RoomUserBlocks blocks;
  const RoomBlockList({required this.blocks, super.key});

  @override
  State<RoomBlockList> createState() => _RoomBlockListState();
}

class _RoomBlockListState extends State<RoomBlockList> with _Ticking {
  RoomUserBlocks get blocks => widget.blocks;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Obx(() {
        blocks.service?.version.value;
        blocks.visitVersion.value;
        var list = blocks.effective();
        var hasTemporary = list.any((e) => !e.permanent);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Text(
                "本直播间屏蔽的人（{n}）".tf({"n": list.length}),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const Divider(height: 1),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  "没有屏蔽的人".t,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (var e in list)
                      UserBlockTile(
                        block: e,
                        onRemove: () => blocks.remove(e),
                      ),
                  ],
                ),
              ),
            if (hasTemporary)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: blocks.removeTemporary,
                    child: Text("解除全部临时屏蔽".t),
                  ),
                ),
              ),
          ],
        );
      }),
    );
  }
}

/// “弹幕屏蔽”页的“用户”一栏：被屏蔽的人发的 SC 和礼物要不要显示，
/// 存在本机的名单按平台分组，可以单个解除、一键解除全部临时屏蔽、清空
class UserBlockSection extends StatefulWidget {
  final ChatUsersService service;
  const UserBlockSection({required this.service, super.key});

  @override
  State<UserBlockSection> createState() => _UserBlockSectionState();
}

class _UserBlockSectionState extends State<UserBlockSection> with _Ticking {
  ChatUsersService get service => widget.service;

  Future<void> clearAll() async {
    var ok = await Utils.showAlertDialog(
      "要清空全部屏蔽的用户吗？永久屏蔽也会解除。".t,
      title: "清空".t,
      confirm: "清空".t,
      cancel: "取消".t,
    );
    if (ok) {
      service.blocks.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      service.version.value;
      var now = service.blocks.now;
      var items = service.blocks.items.where((e) => e.activeAt(now)).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      var groups = <String, List<UserBlock>>{};
      for (var e in items) {
        groups.putIfAbsent(e.siteId, () => []).add(e);
      }
      var hasTemporary = items.any((e) => !e.permanent);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            "用户（{n}）".tf({"n": items.length}),
            style: Get.textTheme.titleSmall,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text("被屏蔽的人发的 SC 和礼物也不显示".t),
            value: service.hidePaid.value,
            onChanged: service.setHidePaid,
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                "在弹幕卡片里屏蔽的人显示在这里".t,
                style: Get.textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
            ),
          for (var entry in groups.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 2),
              child: Text(
                Sites.allSites[entry.key]?.name ?? entry.key,
                style: Get.textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
            ),
            for (var e in entry.value)
              UserBlockTile(
                block: e,
                showRoom: true,
                onRemove: () => service.blocks.remove([e]),
              ),
          ],
          if (items.isNotEmpty)
            Wrap(
              spacing: 8,
              children: [
                if (hasTemporary)
                  TextButton(
                    onPressed: service.blocks.removeTemporary,
                    child: Text("解除全部临时屏蔽".t),
                  ),
                TextButton(onPressed: clearAll, child: Text("清空".t)),
              ],
            ),
        ],
      );
    });
  }
}
