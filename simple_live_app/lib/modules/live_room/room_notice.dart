import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 聊天区顶上的直播间公告卡片显示的内容：标题、公告，以及什么时候开播的
/// （卡片上的时间是开播时长）。标题和公告是平台给的文字，不翻译
class RoomNotice {
  /// 直播间标题
  final String title;

  /// 主播公告；平台没给公告时用简介，都没有时为空
  final String body;

  /// 开播时间；没开播，或者平台没给开播时间时为 null（卡片上不显示时间）
  final DateTime? liveStart;

  const RoomNotice({required this.title, this.body = "", this.liveStart});

  bool get isEmpty => title.isEmpty && body.isEmpty;

  /// 从房间信息里取：公告优先，没有就用简介；HTML 变成纯文字。
  /// 简介和标题一样（虎牙）时不重复显示
  factory RoomNotice.of(LiveRoomDetail detail) {
    var title = detail.title.trim();
    if (title == "null") {
      title = "";
    }
    var notice = plainRoomText(detail.notice);
    var body = notice.isNotEmpty ? notice : plainRoomText(detail.introduction);
    if (body == title) {
      body = "";
    }
    // 开播时间是秒；轮播录像（isRecord）不算开播
    var start = detail.status ? int.tryParse(detail.showTime ?? "") ?? 0 : 0;
    return RoomNotice(
      title: title,
      body: body,
      liveStart:
          start > 0 ? DateTime.fromMillisecondsSinceEpoch(start * 1000) : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RoomNotice &&
      other.title == title &&
      other.body == body &&
      other.liveStart == liveStart;

  @override
  int get hashCode => Object.hash(title, body, liveStart);

  @override
  String toString() => "RoomNotice($title, $body, $liveStart)";
}

/// 开播了多久，写成 HH:mm:ss，和播放器上的开播时长一个算法
String roomLiveDurationText(DateTime start, {DateTime? now}) {
  var seconds = (now ?? DateTime.now()).difference(start).inSeconds;
  if (seconds < 0) {
    seconds = 0;
  }
  String two(int v) => v.toString().padLeft(2, "0");
  return "${two(seconds ~/ 3600)}:${two(seconds % 3600 ~/ 60)}:${two(seconds % 60)}";
}

/// 一个直播间页面里公告卡片的状态（在 LiveRoomController 上）
class RoomNoticeState {
  /// 现在这个直播间的公告；还没读到房间信息（刚进来、刚换直播间）时为 null
  final Rx<RoomNotice?> notice = Rx<RoomNotice?>(null);

  /// 这次进来把卡片关掉了；换直播间或重新进来后再显示
  final RxBool closed = false.obs;

  /// 卡片的下边离聊天列表顶部多远，没显示时为 0。
  /// 卡片浮在列表上面，列表顶部留出这么多，消息不会被它挡住
  final RxDouble inset = 0.0.obs;

  /// 这次进直播间后聊天列表滚起来了，卡片自己收成了小条（不记到设置里）
  final RxBool autoFolded = false.obs;

  /// 用户点开的卡片：新消息再多也不自己收起，用户自己滑聊天列表时才收
  bool keepOpen = false;

  /// 用户点了收起或展开：记到设置里，下次进直播间照这个
  void foldByHand(bool fold) {
    AppSettingsController.instance.setChatNoticeFolded(fold);
    autoFolded.value = false;
    keepOpen = !fold;
  }

  /// 聊天列表滚起来了：[byUser] 是用户自己滑的，否则是新消息多到把列表顶了上去。
  /// 展开着的卡片这时收成小条；用户点开的那张只在用户自己滑时才收
  void chatScrolled({required bool byUser}) {
    if (byUser) {
      keepOpen = false;
    }
    if (!keepOpen && !autoFolded.value) {
      autoFolded.value = true;
    }
  }

  /// 读到了房间信息；[detail] 为 null 表示还没读到现在这个直播间的
  void update(LiveRoomDetail? detail) {
    notice.value = detail == null ? null : RoomNotice.of(detail);
  }

  /// 换了直播间
  void enterRoom() {
    notice.value = null;
    closed.value = false;
    autoFolded.value = false;
    keepOpen = false;
  }
}
