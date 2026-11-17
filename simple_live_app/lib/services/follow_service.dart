import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/active_players.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/window_changes.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/account_follow/account_follow_models.dart';
import 'package:simple_live_app/services/account_follow_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/live_notify_service.dart';
import 'package:simple_live_core/simple_live_core.dart' show LiveRoomDetail;
import 'package:simple_live_app/models/db/sync_time.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class FollowService extends GetxService {
  StreamSubscription<dynamic>? subscription;
  static FollowService get instance => Get.find<FollowService>();

  final StreamController _updatedListController = StreamController.broadcast();
  Stream get updatedListStream => _updatedListController.stream;

  /// 关注用户列表
  RxList<FollowUser> followList = RxList<FollowUser>();

  /// 直播中的用户列表
  RxList<FollowUser> liveList = RxList<FollowUser>();

  /// 未直播的用户列表
  RxList<FollowUser> notLiveList = RxList<FollowUser>();

  /// 用户自定义的tag
  RxList<FollowUserTag> followTagList = RxList<FollowUserTag>();

  /// 当前tag的用户列表
  RxList<FollowUser> curTagFollowList = RxList<FollowUser>();

  /// 是否正在更新
  var updating = false.obs;

  Timer? updateTimer;

  /// 看直播时到了刷新时间：先不刷，离开后补一次
  bool _updateDeferred = false;

  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      loadData(updateStatus: false);
    });
    ActivePlayers.addIdleListener(_onPlayersIdle);
    initTimer();
    super.onInit();
  }

  void _onPlayersIdle() {
    if (_updateDeferred) {
      _updateDeferred = false;
      loadData();
    }
  }

  // 添加标签
  Future<void> addFollowUserTag(String tag) async {
    // 判断待添加tag是否已存在，存在则return
    if (followTagList.any((item) => item.tag == tag)) {
      SmartDialog.showToast("已经有同名的标签了".t);
      return;
    }
    FollowUserTag item = await DBService.instance.addFollowTag(tag);
    followTagList.add(item);
  }

  // 删除标签
  Future<void> delFollowUserTag(FollowUserTag tag) async {
    followTagList.remove(tag);
    await DBService.instance.deleteFollowTag(tag.id);
  }

  // 获取用户自定义标签列表
  void getAllTagList() {
    var list = DBService.instance.getFollowTagList();
    followTagList.assignAll(list);
  }

  // 修改标签
  void updateFollowUserTag(FollowUserTag tag) {
    DBService.instance.updateFollowTag(tag);
    // 查找并修改
    var index = followTagList.indexWhere((oTag) => oTag.id == tag.id);
    followTagList[index] = tag;
  }

  // 根据标签筛选数据
  void filterDataByTag(FollowUserTag tag) {
    curTagFollowList.clear();
    // 用一个新的列表来存储需要删除的 userId
    List<String> toRemove = [];
    for (var id in tag.userId) {
      if (followList.any((x) => x.id == id)) {
        // 找到对应的 followUser 添加到 curTagFollowList
        curTagFollowList.add(followList.firstWhere((x) => x.id == id));
      } else {
        // 标记要删除的 id
        toRemove.add(id);
      }
    }
    // 双向确认用户取消关注后标签内是否还有该用户
    // 在遍历结束后统一移除不在 followList 中的 id
    tag.userId.removeWhere((id) => toRemove.contains(id));
    // 更新数据库
    if (toRemove.isNotEmpty) {
      DBService.instance.updateFollowTag(tag);
    }
    // 标签内排序
    curTagFollowList.sort(
      (a, b) => b.liveStatus.value.compareTo(a.liveStatus.value),
    );
  }

  // 添加关注
  Future<void> addFollow(FollowUser follow) async {
    await DBService.instance.addFollow(follow);
  }

  /// 关注（新增或覆盖）
  ///
  /// [origin] 为 user（在 App 里点的）且该平台打开了“同步到账号”时，会同步到账号；
  /// 导入、恢复、迁移、同步来的都不会。
  Future<void> follow(
    FollowUser follow, {
    FollowChangeOrigin origin = FollowChangeOrigin.user,
  }) async {
    await DBService.instance.addFollow(follow);
    if (MultiWindow.isSecondary) {
      // 多开的副窗口：交给主窗口保存，同步到账号也由主窗口做
      MultiWindow.forward(FollowAdded(follow, origin));
      return;
    }
    await AccountFollowService.maybe?.onLocalChange(
      follow,
      FollowWriteAction.follow,
      origin,
    );
  }

  /// 取消关注以后只从列表里拿掉：不重读数据库，也不查开播状态（不发请求）
  void removeLocal(String id) {
    followList.removeWhere((e) => e.id == id);
    filterData();
  }

  /// 取消关注；[localOnly] 为 true 时只在 App 里取消（用户在确认框里选的）
  Future<void> unfollow(
    FollowUser follow, {
    FollowChangeOrigin origin = FollowChangeOrigin.user,
    bool localOnly = false,
  }) async {
    await DBService.instance.deleteFollow(follow.id);
    if (MultiWindow.isSecondary) {
      MultiWindow.forward(FollowRemoved(follow, origin, localOnly: localOnly));
      return;
    }
    await AccountFollowService.maybe?.onLocalChange(
      follow,
      FollowWriteAction.unfollow,
      origin,
      localOnly: localOnly,
    );
  }

  void initTimer() {
    if (AppSettingsController.instance.autoUpdateFollowEnable.value) {
      updateTimer?.cancel();
      updateTimer = Timer.periodic(
        Duration(
            minutes:
                AppSettingsController.instance.autoUpdateFollowDuration.value),
        (timer) {
          // 看直播时不去逐个查关注的开播状态（一次要发很多请求），离开后补一次
          if (ActivePlayers.isPlaying) {
            _updateDeferred = true;
            return;
          }
          Log.logPrint("Update Follow Timer");
          loadData();
        },
      );
    } else {
      updateTimer?.cancel();
    }
  }

  /// 每一轮查开播状态的编号：新的一轮开始后，旧的一轮查完手上那个就停，结果不再用
  int _round = 0;

  /// 关注超过这么多个时，直播间里第一次切到“关注”会提示一次可以少查一些
  static const manyFollows = 100;

  /// 上一轮查完的时间
  DateTime? _lastRoundEnd;

  /// 切到“关注”时最短隔这么久才再查（来回切也不会查得太勤）
  static const showRefreshGap = Duration(seconds: 15);

  bool get _checkedJustNow {
    var last = _lastRoundEnd;
    return last != null && DateTime.now().difference(last) < showRefreshGap;
  }

  /// 关注列表显示出来了（切到“关注”、打开关注列表）：查一遍开播状态。
  /// 看直播时定时刷新会推迟，这里不推迟；正在查、或者离上次查完不到
  /// [showRefreshGap] 时不再查
  void refreshOnShow() {
    if (updating.value || _checkedJustNow) {
      return;
    }
    loadData();
  }

  /// 直播间里切到“关注”：按“关注设置”里选的查全部、一个分组、
  /// 正在看的主播所在的分组，或者不查。返回查了几个
  Future<int> refreshForLiveRoom({
    required String siteId,
    required String roomId,
  }) async {
    var mode = AppSettingsController.instance.liveRoomFollowCheck.value;
    if (mode == "none" || updating.value || _checkedJustNow) {
      return 0;
    }
    if (followList.isEmpty) {
      await loadData(updateStatus: false);
    }
    var members = liveRoomCheckMembers(mode, siteId: siteId, roomId: roomId);
    if (members == null) {
      refreshOnShow();
      return followList.length;
    }
    if (members.isNotEmpty) {
      unawaited(startUpdateStatus(only: members));
    }
    return members.length;
  }

  /// 设置成只查一个分组时要查的主播；null 表示查全部（设置是全部，或者选的分组已经删了）
  List<FollowUser>? liveRoomCheckMembers(
    String mode, {
    required String siteId,
    required String roomId,
  }) {
    FollowUserTag? tag;
    if (mode == "current") {
      // 正在看的主播所在的分组；没关注或者没分组时不查
      var current = followList.firstWhereOrNull(
          (e) => e.siteId == siteId && e.roomId == roomId);
      tag = followTagList.firstWhereOrNull((e) => e.tag == current?.tag);
      if (tag == null) {
        return const [];
      }
    } else if (mode.startsWith("tag:")) {
      var id = mode.substring(4);
      tag = followTagList.firstWhereOrNull((e) => e.id == id);
      if (tag == null) {
        return null;
      }
    } else {
      return null;
    }
    var ids = tag.userId.toSet();
    return followList.where((e) => ids.contains(e.id)).toList();
  }

  Future<void> loadData({bool updateStatus = true}) async {
    var list = DBService.instance.getFollowList();
    getAllTagList();
    // 同步、导入以后数据库里是新的对象：已经查到的开播状态接着用，
    // 不然全变回“读取中”
    var known = {for (var e in followList) e.id: e};
    var checkedBefore = known.values.any((e) => e.liveStatus.value != 0);
    for (var item in list) {
      var old = known[item.id];
      if (old != null && !identical(old, item)) {
        item.liveStatus.value = old.liveStatus.value;
        item.liveStartTime = old.liveStartTime;
        item.liveCover = old.liveCover;
        item.liveTitle = old.liveTitle;
        item.liveOnline = old.liveOnline;
      }
    }
    followList.assignAll(list);
    if (list.isEmpty) {
      _round++;
      updating.value = false;
      filterData();
      return;
    }
    if (updateStatus) {
      startUpdateStatus();
      return;
    }
    filterData();
    if (updating.value) {
      // 正在查的那一轮改的是旧对象（比如刚打开关注页就拉到了 WebDAV 的备份）：
      // 换成新的列表重查一轮
      startUpdateStatus();
    } else if (checkedBefore) {
      // 新加进来的（同步来的、刚关注的）还不知道开播状态：只补查这几个。
      // 一次都没查过时不查，和原来一样等打开关注列表或者定时刷新
      var unknown = list
          .where((e) =>
              e.liveStatus.value == 0 && Sites.allSites.containsKey(e.siteId))
          .toList();
      if (unknown.isNotEmpty) {
        startUpdateStatus(only: unknown);
      }
    }
  }

  /// 获取最优并发数
  /// 根据 CPU 核心数和用户设置自动计算
  int getOptimalConcurrency() {
    var userSetting =
        AppSettingsController.instance.updateFollowThreadCount.value;

    // 如果用户设置为 0，则自动根据 CPU 核心数计算
    if (userSetting == 0) {
      var cpuCount = Platform.numberOfProcessors;
      // 网络 I/O 密集型任务，并发数可以是 CPU 核心数的 2-3 倍
      var optimal = (cpuCount * 2.5).round();
      // 限制在合理范围内（最少 4，最多 20）
      return optimal.clamp(4, 20);
    }

    return userSetting;
  }

  /// 按平台交错排列，避免单一平台阻塞
  List<FollowUser> interleaveByPlatform(List<FollowUser> list) {
    // 按平台分组
    var grouped = <String, Queue<FollowUser>>{};
    for (var item in list) {
      grouped.putIfAbsent(item.siteId, () => Queue<FollowUser>()).add(item);
    }

    // 交错处理
    var result = <FollowUser>[];
    while (grouped.values.any((queue) => queue.isNotEmpty)) {
      for (var queue in grouped.values) {
        if (queue.isNotEmpty) {
          result.add(queue.removeFirst());
        }
      }
    }

    return result;
  }

  /// 查一轮开播状态；[only] 只查这几个
  Future<void> startUpdateStatus({List<FollowUser>? only}) async {
    var round = ++_round;
    updating.value = true;

    var concurrency = getOptimalConcurrency();
    var items = only ?? followList.toList();

    Log.logPrint("开始更新关注状态，并发数: $concurrency，总数: ${items.length}");

    // 按平台交错排列，避免单一平台阻塞
    var taskQueue = Queue<FollowUser>.from(interleaveByPlatform(items));

    // 工作函数 - 持续从队列中取任务执行；有了新的一轮就停
    Future<void> worker() async {
      while (taskQueue.isNotEmpty && round == _round) {
        await updateLiveStatus(taskQueue.removeFirst());
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency; i++) worker(),
    ]);
    if (round != _round) {
      return;
    }
    filterData();
    updating.value = false;
    _lastRoundEnd = DateTime.now();
    Log.logPrint("关注状态更新完成");
  }

  /// 查一个直播间的开播状态；在播时再读房间信息拿开播时间。
  /// 读到的结果交给开播提醒，比较前后两次的状态
  Future<void> updateLiveStatus(FollowUser item) async {
    var site = Sites.allSites[item.siteId];
    if (site == null) {
      // 平台未安装（已删除的直播源），不查询
      item.liveStatus.value = 0;
      item.liveStartTime = null;
      return;
    }
    bool isLiving;
    try {
      // 先只查状态
      isLiving = await site.liveSite.getLiveStatus(roomId: item.roomId);
    } catch (e) {
      Log.logPrint(e);
      item.liveStatus.value = 0;
      item.liveStartTime = null;
      return;
    }
    item.liveStatus.value = isLiving ? 2 : 1;
    LiveRoomDetail? detail;
    if (isLiving) {
      // 只有正在直播时才查详细信息；读不到也算在播，只是没有开播时间
      try {
        detail = await site.liveSite.getRoomDetail(roomId: item.roomId);
      } catch (e) {
        Log.logPrint(e);
      }
    }
    item.liveStartTime = detail?.showTime;
    // 关注页的卡片样式用；读的还是上面这一次，不多发请求
    item.liveCover = detail?.cover;
    item.liveTitle = detail?.title;
    item.liveOnline = detail?.online ?? 0;
    LiveNotifyService.maybe?.observe(item, isLiving, detail);
  }

  /// 订阅或取消开播提醒。存进数据库，跟着关注列表同步
  Future<void> setNotify(FollowUser item, bool value) async {
    item.notify = value;
    await DBService.instance.addFollow(item);
    MultiWindow.forward(FollowNotifyChanged(item.id, value));
    LiveNotifyService.maybe?.onSubscriptionChanged(item);
  }

  void filterData() {
    followList.sort((a, b) => b.liveStatus.value.compareTo(a.liveStatus.value));
    liveList.assignAll(followList.where((x) => x.liveStatus.value == 2));
    notLiveList.assignAll(followList.where((x) => x.liveStatus.value == 1));
    _updatedListController.add(0);
  }

  void exportFile() async {
    if (followList.isEmpty) {
      SmartDialog.showToast("关注列表是空的".t);
      return;
    }

    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("没有文件访问权限".t);
        return;
      }

      var dir = "";
      if (Platform.isIOS) {
        dir = (await getApplicationDocumentsDirectory()).path;
      } else {
        dir = await FilePicker.platform.getDirectoryPath() ?? "";
      }

      if (dir.isEmpty) {
        return;
      }
      var jsonFile = File(
          '$dir/SimpleLive_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.json');
      var jsonText = generateJson();
      await jsonFile.writeAsString(jsonText);
      SmartDialog.showToast("已导出关注列表".t);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导出失败：{e}".tf({"e": e}));
    }
  }

  void inputFile() async {
    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("没有文件访问权限".t);
        return;
      }
      var file = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null) {
        return;
      }
      var jsonFile = File(file.files.single.path!);
      await inputJson(await jsonFile.readAsString());
      SmartDialog.showToast("导入成功".t);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导入失败：{e}".tf({"e": e}));
    } finally {
      loadData();
    }
  }

  void exportText() {
    if (followList.isEmpty) {
      SmartDialog.showToast("关注列表是空的".t);
      return;
    }
    var content = generateJson();
    Get.dialog(
      AlertDialog(
        title: Text("导出为文本".t),
        content: TextField(
          controller: TextEditingController(text: content),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: Text("关闭".t),
          ),
          TextButton(
            onPressed: () {
              Utils.copyToClipboard(content);
              Get.back();
            },
            child: Text("复制".t),
          ),
        ],
      ),
    );
  }

  void inputText() async {
    final TextEditingController textController = TextEditingController();
    await Get.dialog(
      AlertDialog(
        title: Text("从文本导入".t),
        content: TextField(
          controller: textController,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: "粘贴导出的关注列表".t,
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: Text("关闭".t),
          ),
          TextButton(
            onPressed: () async {
              var content = await Utils.getClipboard();
              if (content != null) {
                textController.text = content;
              }
            },
            child: Text("粘贴".t),
          ),
          TextButton(
            onPressed: () async {
              if (textController.text.isEmpty) {
                SmartDialog.showToast("请先输入内容".t);
                return;
              }
              try {
                await inputJson(textController.text);
                SmartDialog.showToast("导入成功".t);
                Get.back();
                loadData();
              } catch (e) {
                SmartDialog.showToast("导入失败，看看内容对不对".t);
              }
            },
            child: Text("导入".t),
          ),
        ],
      ),
    );
  }

  String generateJson() {
    var data = followList
        .map(
          (item) => {
            "siteId": item.siteId,
            "id": item.id,
            "roomId": item.roomId,
            "userName": item.userName,
            "face": item.face,
            ...SyncTime.write("addTime", item.addTime),
            "tag": item.tag
          },
        )
        .toList();
    return jsonEncode(data);
  }

  Future inputJson(String content) async {
    var data = jsonDecode(content);

    for (var item in data) {
      var follow = FollowUser.fromJson(item);
      // 导入关注列表同时导入标签列表 此方法可优化为所有导入逻辑
      if (follow.tag != "全部") {
        // logic: 尝试添加，存在则返回已存在的对象
        var tag = await DBService.instance.addFollowTag(follow.tag);
        // 更新tag
        tag.userId.addIf(!tag.userId.contains(follow.id), follow.id);
        await DBService.instance.updateFollowTag(tag);
      }
      await DBService.instance.addFollow(follow);
    }
  }

  @override
  void onClose() {
    updateTimer?.cancel();
    ActivePlayers.removeIdleListener(_onPlayersIdle);
    subscription?.cancel();
    super.onClose();
  }
}
