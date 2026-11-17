import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/services/chat_users/chat_user.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/chat_users/room_user_blocks.dart';
import 'package:simple_live_app/services/chat_users/user_block_store.dart';
import 'package:simple_live_app/services/chat_users/user_remark_store.dart';
import 'package:simple_live_app/widgets/compact_buttons.dart';
import 'package:simple_live_app/widgets/undo_toast.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 卡片第一级里的一行操作（点了先关卡片再执行）
class ChatUserCardAction {
  final IconData icon;
  final String title;

  /// 为空时这一行灰掉
  final VoidCallback? onTap;
  const ChatUserCardAction(this.icon, this.title, this.onTap);
}

/// 卡片的层级：第一级是原来的操作，屏蔽是第二级，自定义时间是第三级；备注单独一级
enum ChatUserCardLevel { main, block, customTime, remark }

/// 点一条弹幕（或 SC、礼物）弹出的卡片。
///
/// 上面是名字（有备注时后面跟着灰色的备注）和 [body]（身份、这条弹幕），
/// 下面一行一个操作：[before]、屏蔽这个人 ›、备注、[after]。
/// 点“屏蔽这个人”后卡片内容换成第二级，左上角有返回；高度变化有过渡，不会跳
Future<void> showChatUserCard({
  required ChatUser user,
  required RoomUserBlocks blocks,
  required WidgetBuilder body,
  List<ChatUserCardAction> before = const [],
  List<ChatUserCardAction> after = const [],
  String? visitHint,
  VoidCallback? onBlocked,
}) {
  var context = Get.context!;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxWidth: 600,
      maxHeight: MediaQuery.sizeOf(context).height * 0.9,
    ),
    builder: (_) => ChatUserCard(
      user: user,
      blocks: blocks,
      body: body,
      before: before,
      after: after,
      visitHint: visitHint,
      onBlocked: onBlocked,
    ),
  );
}

class ChatUserCard extends StatefulWidget {
  final ChatUser user;
  final RoomUserBlocks blocks;
  final WidgetBuilder body;
  final List<ChatUserCardAction> before;
  final List<ChatUserCardAction> after;

  /// “本次进入”下面的说明，默认是“离开直播间后解除”
  final String? visitHint;

  /// 屏蔽以后
  final VoidCallback? onBlocked;

  /// 测试用：从哪一级开始、自定义时间里先填好的数
  final ChatUserCardLevel initialLevel;
  final String initialDuration;

  /// 屏蔽以后带“撤销”的提示、普通提示（测试里换掉）
  static void Function(String text, VoidCallback onUndo) undoToast =
      showUndoToast;
  static void Function(String text) toast = SmartDialog.showToast;

  const ChatUserCard({
    required this.user,
    required this.blocks,
    required this.body,
    this.before = const [],
    this.after = const [],
    this.visitHint,
    this.onBlocked,
    this.initialLevel = ChatUserCardLevel.main,
    this.initialDuration = "",
    super.key,
  });

  @override
  State<ChatUserCard> createState() => _ChatUserCardState();

  /// 没有用户 ID 时“屏蔽这个人”下面的说明，备注那一行同样不能点（哔哩哔哩没登录时不给 ID）
  static String noIdHint(String siteId) => siteId == Constant.kBiliBili
      ? "未登录时没有用户 ID，无法屏蔽和备注".t
      : "没有用户 ID，无法屏蔽和备注".t;

  /// 第一级“屏蔽这个人”那一行：没屏蔽、永久、还剩多久、本次进入
  static String blockedTitleFor(UserBlock? block, {DateTime? now}) {
    if (block == null) {
      return "屏蔽这个人".t;
    }
    return switch (block.kind) {
      UserBlockKind.permanent => "已永久屏蔽".t,
      UserBlockKind.visit => "已屏蔽（本次进入）".t,
      UserBlockKind.timed => "已屏蔽（还剩 {time}）".tf({
          "time": chatUserRemainingText(
            DateTime.fromMillisecondsSinceEpoch(block.expireAt!)
                .difference(now ?? DateTime.now()),
          ),
        }),
    };
  }
}

class _ChatUserCardState extends State<ChatUserCard> {
  late ChatUserCardLevel level = widget.initialLevel;

  /// 第二级的开关“只在这个直播间”，默认关（整个平台）
  bool roomOnly = false;

  /// 第三级：自定义时长，单位是小时（否则分钟）
  late final TextEditingController durationText =
      TextEditingController(text: widget.initialDuration);
  bool hours = false;

  late final TextEditingController remarkText = TextEditingController(
    text: _remark ?? "",
  );

  /// 最长能屏蔽多久
  static const int maxHours = 240;

  ChatUser get user => widget.user;
  RoomUserBlocks get blocks => widget.blocks;
  ChatUsersService? get service => blocks.service;

  String? get _remark => service?.remarkOf(user);

  @override
  void dispose() {
    durationText.dispose();
    remarkText.dispose();
    super.dispose();
  }

  void go(ChatUserCardLevel next) => setState(() => level = next);

  /// 关掉卡片（只关弹出的卡片，不会退出直播间）
  void close() {
    var route = mounted ? ModalRoute.of(context) : null;
    if (route is PopupRoute && route.isCurrent) {
      Navigator.of(context).pop();
    }
  }

  void block({bool visitOnly = false, Duration? duration}) {
    var undo = blocks.block(
      user,
      roomOnly: roomOnly,
      visitOnly: visitOnly,
      duration: duration,
    );
    close();
    widget.onBlocked?.call();
    ChatUserCard.undoToast(
      "已屏蔽 {name}".tf({"name": _displayName}),
      () {
        undo();
        widget.onBlocked?.call();
      },
    );
  }

  void unblock() {
    blocks.unblock(user);
    close();
    ChatUserCard.toast("已解除屏蔽".t);
  }

  String get _displayName =>
      chatUserLabel(user.name, userId: user.userId, midHash: user.midHash);

  /// 自定义时长：分钟数；没填或不对时为 null
  int? get _customMinutes {
    var value = int.tryParse(durationText.text.trim());
    if (value == null || value <= 0) {
      return null;
    }
    return hours ? value * 60 : value;
  }

  bool get _tooLong {
    var minutes = _customMinutes;
    return minutes != null && minutes > maxHours * 60;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        // 横屏时卡片比屏幕能给的高度高，可以滚
        child: SingleChildScrollView(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(
              key: ValueKey(level),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                buildHeader(context),
                const Divider(height: 1),
                ...switch (level) {
                  ChatUserCardLevel.main => buildMain(),
                  ChatUserCardLevel.block => buildBlock(),
                  ChatUserCardLevel.customTime => buildCustomTime(context),
                  ChatUserCardLevel.remark => buildRemark(context),
                },
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 名字、备注和 [ChatUserCard.body]；第二级起左上角有返回
  Widget buildHeader(BuildContext context) {
    var remark = _remark;
    var sub = level != ChatUserCardLevel.main;
    var name = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: user.name,
            style: const TextStyle(
              color: Colors.grey,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (remark != null)
            TextSpan(
              text: "${user.name.isEmpty ? "" : " "}($remark)",
              style: const TextStyle(color: Colors.grey),
            ),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(sub ? 4 : 16, sub ? 4 : 14, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sub)
            IconButton(
              tooltip: "返回".t,
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              padding: EdgeInsets.zero,
              iconSize: 20,
              icon: const Icon(Icons.arrow_back),
              onPressed: () => go(
                level == ChatUserCardLevel.customTime
                    ? ChatUserCardLevel.block
                    : ChatUserCardLevel.main,
              ),
            ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: sub ? 10 : 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (user.name.isNotEmpty || remark != null) ...[
                    name,
                    const SizedBox(height: 8),
                  ],
                  widget.body(context),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget row(
    IconData icon,
    String title, {
    VoidCallback? onTap,
    String? subtitle,
    Widget? trailing,
    bool closeFirst = false,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: trailing,
      enabled: onTap != null,
      onTap: onTap == null
          ? null
          : closeFirst
              ? () {
                  close();
                  onTap();
                }
              : onTap,
    );
  }

  static const Widget _chevron = Icon(Icons.chevron_right);

  List<Widget> buildMain() {
    var current = blocks.strongest(user);
    var remark = _remark;
    return [
      for (var a in widget.before)
        row(a.icon, a.title, onTap: a.onTap, closeFirst: true),
      row(
        current == null ? Icons.block : Icons.do_not_disturb_on,
        ChatUserCard.blockedTitleFor(current),
        // 屏蔽和备注只按用户 ID 认人，按名字会认错同名的人
        onTap: user.hasId ? () => go(ChatUserCardLevel.block) : null,
        subtitle: user.hasId ? null : ChatUserCard.noIdHint(user.siteId),
        trailing: user.hasId ? _chevron : null,
      ),
      row(
        Icons.edit_note,
        "备注".t,
        onTap: user.hasId ? () => go(ChatUserCardLevel.remark) : null,
        trailing: remark == null
            ? null
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  remark,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
      ),
      for (var a in widget.after)
        row(a.icon, a.title, onTap: a.onTap, closeFirst: true),
    ];
  }

  List<Widget> buildBlock() {
    var blocked = blocks.matches(user).isNotEmpty;
    return [
      if (blocked) row(Icons.lock_open, "解除屏蔽".t, onTap: unblock),
      if (blocks.roomId != null)
        SwitchListTile(
          secondary: const Icon(Icons.meeting_room_outlined),
          title: Text("只在这个直播间".t),
          value: roomOnly,
          onChanged: (e) => setState(() => roomOnly = e),
        ),
      row(Icons.block, "永久屏蔽".t, onTap: () => block()),
      row(
        Icons.login,
        "本次进入".t,
        subtitle: widget.visitHint ?? "离开直播间后解除".t,
        onTap: () => block(visitOnly: true),
      ),
      row(
        Icons.schedule,
        "自定义时间".t,
        onTap: () => go(ChatUserCardLevel.customTime),
        trailing: _chevron,
      ),
    ];
  }

  /// 第三级的预设时长
  static const List<Duration> presets = [
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 30),
    Duration(hours: 1),
  ];

  List<Widget> buildCustomTime(BuildContext context) {
    var minutes = _customMinutes;
    var tooLong = _tooLong;
    return [
      for (var d in presets)
        row(
          Icons.timer_outlined,
          chatUserRemainingText(d),
          onTap: () => block(duration: d),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey("block_duration"),
                controller: durationText,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(5),
                ],
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: "时长".t,
                  border: const OutlineInputBorder(),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  errorText: tooLong ? "最长 {n} 小时".tf({"n": maxHours}) : null,
                  errorMaxLines: 2,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (minutes != null && !tooLong) {
                    block(duration: Duration(minutes: minutes));
                  }
                },
              ),
            ),
            const SizedBox(width: 6),
            SmallToggle(
              label: hours ? "小时".t : "分钟".t,
              selected: true,
              onTap: () => setState(() => hours = !hours),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: minutes == null || tooLong
                  ? null
                  : () => block(duration: Duration(minutes: minutes)),
              child: Text("确定".t),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> buildRemark(BuildContext context) {
    void save() {
      service?.remarks.set(user, remarkText.text);
      go(ChatUserCardLevel.main);
    }

    var hasRemark = _remark != null;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey("remark_input"),
                controller: remarkText,
                autofocus: true,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(UserRemarkStore.maxLength),
                ],
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: "输入备注".t,
                  border: const OutlineInputBorder(),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                ),
                onSubmitted: (_) => save(),
              ),
            ),
            const SizedBox(width: 4),
            TextButton(onPressed: save, child: Text("保存".t)),
          ],
        ),
      ),
      if (hasRemark)
        row(
          Icons.delete_outline,
          "删除备注".t,
          onTap: () {
            service?.remarks.set(user, "");
            go(ChatUserCardLevel.main);
          },
        ),
      const SizedBox(height: 8),
    ];
  }
}
