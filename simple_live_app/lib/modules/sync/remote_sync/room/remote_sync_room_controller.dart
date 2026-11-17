import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/signalr_service.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class RemoteSyncRoomController extends BaseController {
  final String roomId;
  final SignalRService signalR = SignalRService();
  RemoteSyncRoomController(this.roomId) {
    if (roomId.isNotEmpty) {
      currentRoomId.value = roomId;
    }
  }
  StreamSubscription? _roomDestroyedSubscription;
  StreamSubscription? _roomUserUpdatedSubscription;
  StreamSubscription? _onFavoriteSubscription;
  StreamSubscription? _onHistorySubscription;
  StreamSubscription? _onShieldWordSubscription;
  StreamSubscription? _onBiliAccountSubscription;
  var currentRoomId = "--".obs;
  RxList<RoomUser> roomUsers = <RoomUser>[].obs;

  Timer? _timer;
  var countDown = 600.obs;

  @override
  void onInit() {
    connect();
    super.onInit();
  }

  void connect() async {
    listenSignalR();
    try {
      await signalR.connect();
    } catch (e) {
      _serverUnavailable(roomId.isEmpty ? "创建房间".t : "加入房间".t, e, connected: false);
      return;
    }
    if (signalR.state == SignalRConnectionState.connected) {
      if (roomId.isEmpty) {
        createRoom();
      } else {
        joinRoom(roomId);
      }
    }
  }

  void createRoom() async {
    try {
      var resp = await signalR.createRoom();
      if (resp.isSuccess) {
        currentRoomId.value = resp.data!;
        _startTimer();
      } else {
        SmartDialog.showToast(resp.message);
        Get.back();
      }
    } catch (e) {
      _serverUnavailable("创建房间".t, e);
    }
  }

  void _startTimer() {
    // 倒计时5分钟，自动关闭页面
    countDown.value = 600;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      countDown--;
      if (countDown <= 0) {
        timer.cancel();
        Get.back();
      }
    });
  }

  void joinRoom(String roomId) async {
    try {
      var resp = await signalR.joinRoom(roomId);
      if (!resp.isSuccess) {
        SmartDialog.showToast(resp.message);
        Get.back();
      }
    } catch (e) {
      _serverUnavailable("加入房间".t, e);
    }
  }

  /// 房间同步经过原作者的服务器（sync1.nsapps.cn）。连不上或服务器出错
  /// （2026-10 起创建、加入房间都返回服务器内部错误）时说明原因，
  /// 并指向不依赖它的局域网同步
  void _serverUnavailable(String action, Object error,
      {bool connected = true}) async {
    Log.logPrint(error);
    // 已经离开了房间页面：不再关页面、不再提示
    if (isClosed) return;
    Get.back();
    var reason = connected ? "同步服务器出错了".t : "连不上同步服务器".t;
    var toLan = await Utils.showAlertDialog(
      ("{action}失败：{reason}。房间同步经过原作者的服务器，不是本机的问题，"
      "可以过段时间再试。\n\n"
      "同一个 Wi-Fi 或热点下可以用局域网同步，"
      "也可以用 WebDAV 同步。").tf({"action": action, "reason": reason}),
      title: "房间同步暂时不可用".t,
      confirm: "去局域网同步".t,
      cancel: "关闭".t,
    );
    if (toLan) {
      Get.toNamed(RoutePath.kLocalSync);
    }
  }

  void listenSignalR() {
    _roomDestroyedSubscription = signalR.onRoomDestroyedStream.listen((roomId) {
      SmartDialog.showToast("房间已关闭".t);
      Get.back();
    });
    _roomUserUpdatedSubscription = signalR.onRoomUserUpdatedStream.listen(
      (roomUsers) {
        this.roomUsers.assignAll(roomUsers);
      },
    );
    _onFavoriteSubscription = signalR.onFavoriteStream.listen((data) {
      onReceiveFavorite(data.$1, data.$2);
    });
    _onHistorySubscription = signalR.onHistoryStream.listen((data) {
      onReceiveHistory(data.$1, data.$2);
    });
    _onShieldWordSubscription = signalR.onShieldWordStream.listen((data) {
      onReceiveShieldWord(data.$1, data.$2);
    });
    _onBiliAccountSubscription = signalR.onBiliAccountStream.listen((data) {
      onReceiveBiliAccount(data.$1, data.$2);
    });
  }

  void onReceiveFavorite(bool overlay, String data) async {
    try {
      var jsonBody = json.decode(data);
      // 房间里可能有官方版设备，发来的数据不含新平台，保留本地新平台的关注
      if (overlay) {
        await SyncCompat.clearFollows(includeExt: false);
      }
      for (var item in jsonBody) {
        var user = FollowUser.fromJson(item);
        await DBService.instance.followBox.put(user.id, user);
      }
      SmartDialog.showToast('已同步关注列表'.t);
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      SmartDialog.showToast("已同步关注列表".t);
    } catch (e) {
      SmartDialog.showToast("同步失败：{e}".tf({"e": e}));
      Log.logPrint(e);
    }
  }

  void onReceiveHistory(bool overlay, String data) async {
    try {
      var jsonBody = json.decode(data);
      if (overlay) {
        await SyncCompat.clearHistories(includeExt: false);
      }
      for (var item in jsonBody) {
        var history = History.fromJson(item);
        if (DBService.instance.historyBox.containsKey(history.id)) {
          var old = DBService.instance.historyBox.get(history.id);
          //如果本地的更新时间比较新，就不更新
          if (old!.updateTime.isAfter(history.updateTime)) {
            continue;
          }
        }
        await DBService.instance.addOrUpdateHistory(history);
      }
      SmartDialog.showToast('已同步历史记录'.t);
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
    } catch (e) {
      SmartDialog.showToast("同步失败：{e}".tf({"e": e}));
      Log.logPrint(e);
    }
  }

  void onReceiveShieldWord(bool overlay, String data) async {
    try {
      var jsonBody = json.decode(data);
      // 存到全局的关键词（开着直播间单独设置时也一样）
      await AppSettingsController.instance.updateGlobalShieldList(
        clear: overlay,
        add: [for (var item in jsonBody) item.toString()],
      );
      SmartDialog.showToast('已同步屏蔽词'.t);
    } catch (e) {
      SmartDialog.showToast("同步失败：{e}".tf({"e": e}));
      Log.logPrint(e);
    }
  }

  void onReceiveBiliAccount(bool overlay, String data) async {
    try {
      var jsonBody = json.decode(data);
      var cookie = jsonBody['cookie'];
      BiliBiliAccountService.instance.setCookie(cookie);
      BiliBiliAccountService.instance.loadUserInfo();
      SmartDialog.showToast('已同步哔哩哔哩账号'.t);
    } catch (e) {
      SmartDialog.showToast("同步失败：{e}".tf({"e": e}));
      Log.logPrint(e);
    }
  }

  Future<bool> showOverlayDialog() async {
    var overlay = await Utils.showAlertDialog(
      "要用本机数据覆盖其他设备上的数据吗？".t,
      title: "覆盖数据".t,
      confirm: "覆盖".t,
      cancel: "不覆盖".t,
    );
    return overlay;
  }

  void syncFollow() async {
    try {
      if (roomUsers.length <= 1) {
        SmartDialog.showToast("还没有其他设备加入".t);
        return;
      }

      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "发送中...".t);
      // 房间会广播给所有设备（可能是官方版），只发送官方版支持的平台
      var users =
          SyncCompat.upstreamFollows(DBService.instance.getFollowList());
      var data = json.encode(users.map((e) => e.toJson()).toList());

      var resp = await signalR.sendContent(
        roomName: currentRoomId.value,
        action: "SendFavorite",
        overlay: overlay,
        content: data,
      );
      if (resp.isSuccess) {
        SmartDialog.showToast("已发送关注列表".t);
      } else {
        SmartDialog.showToast("发送失败：{message}".tf({"message": resp.message}));
      }
    } catch (e) {
      SmartDialog.showToast("发送失败：{e}".tf({"e": e}));
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncHistory() async {
    try {
      if (roomUsers.length <= 1) {
        SmartDialog.showToast("还没有其他设备加入".t);
        return;
      }
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "发送中...".t);
      var histores =
          SyncCompat.upstreamHistories(DBService.instance.getHistores());
      var data = json.encode(histores.map((e) => e.toJson()).toList());
      var resp = await signalR.sendContent(
        roomName: currentRoomId.value,
        action: "SendHistory",
        overlay: overlay,
        content: data,
      );
      if (resp.isSuccess) {
        SmartDialog.showToast("已发送历史记录".t);
      } else {
        SmartDialog.showToast("发送失败：{message}".tf({"message": resp.message}));
      }
    } catch (e) {
      SmartDialog.showToast("发送失败：{e}".tf({"e": e}));
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncBlockedWord() async {
    try {
      if (roomUsers.length <= 1) {
        SmartDialog.showToast("还没有其他设备加入".t);
        return;
      }
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "发送中...".t);
      var data = json.encode(AppSettingsController.instance.globalShieldList);

      var resp = await signalR.sendContent(
        roomName: currentRoomId.value,
        action: "SendShieldWord",
        overlay: overlay,
        content: data,
      );
      if (resp.isSuccess) {
        SmartDialog.showToast("已发送屏蔽词".t);
      } else {
        SmartDialog.showToast("发送失败：{message}".tf({"message": resp.message}));
      }
    } catch (e) {
      SmartDialog.showToast("发送失败：{e}".tf({"e": e}));
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncBiliAccount() async {
    try {
      if (roomUsers.length <= 1) {
        SmartDialog.showToast("还没有其他设备加入".t);
        return;
      }
      if (!BiliBiliAccountService.instance.logined.value) {
        SmartDialog.showToast("本机还没登录哔哩哔哩".t);
        return;
      }
      SmartDialog.showLoading(msg: "发送中...".t);

      var resp = await signalR.sendContent(
        roomName: currentRoomId.value,
        action: "SendBiliAccount",
        overlay: true,
        content: json.encode({
          "cookie": BiliBiliAccountService.instance.cookie,
        }),
      );
      if (resp.isSuccess) {
        SmartDialog.showToast("已发送哔哩哔哩账号".t);
      } else {
        SmartDialog.showToast("发送失败：{message}".tf({"message": resp.message}));
      }
    } catch (e) {
      SmartDialog.showToast("同步失败：{e}".tf({"e": e}));
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void showQRInfo() {
    Utils.showBottomSheet(
      title: "房间信息".t,
      child: Column(
        children: [
          QrImageView(
            data: currentRoomId.value,
            version: QrVersions.auto,
            backgroundColor: Colors.white,
            padding: AppStyle.edgeInsetsA12,
            size: 200,
          ),
          AppStyle.vGap24,
          Text(
            currentRoomId.value,
            textAlign: TextAlign.center,
            style: Get.textTheme.titleLarge,
          ),
          Text(
            "用其他设备的 Simple Live 扫码\n连上后选要同步的数据".t,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  @override
  void onClose() {
    _timer?.cancel();
    _roomDestroyedSubscription?.cancel();
    _roomUserUpdatedSubscription?.cancel();
    _onFavoriteSubscription?.cancel();
    _onHistorySubscription?.cancel();
    _onShieldWordSubscription?.cancel();
    _onBiliAccountSubscription?.cancel();
    signalR.dispose();
    super.onClose();
  }
}
