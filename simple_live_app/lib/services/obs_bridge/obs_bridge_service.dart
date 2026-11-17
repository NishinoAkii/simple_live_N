import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/obs_bridge/obs_bridge_hub.dart';
import 'package:simple_live_app/services/obs_bridge/obs_bridge_server.dart';
import 'package:simple_live_app/services/obs_bridge/obs_events.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _RoomOwner {
  final Object owner;
  final ObsRoomInfo? Function() info;
  const _RoomOwner(this.owner, this.info);
}

/// 录屏接口（OBS 等）：打开直播间时，本机的网页服务提供弹幕层、聊天框、
/// 醒目留言页面、WebSocket 和 ASS 字幕，方便叠在录屏画面上。
///
/// 直播间打开时 [attach]，关闭时 [detach]；只有最上层（最后打开）的直播间推送。
/// 接口关着时各个 publish 方法只做一次判断就返回
class ObsBridgeService extends GetxService with WidgetsBindingObserver {
  static ObsBridgeService get instance => Get.find<ObsBridgeService>();

  /// 没有注册（如测试里）时为 null
  static ObsBridgeService? get maybeInstance =>
      Get.isRegistered<ObsBridgeService>()
          ? Get.find<ObsBridgeService>()
          : null;

  static const int kDefaultPort = 25789;

  /// 开关（默认关闭）
  var enabled = false.obs;

  /// 端口
  var port = kDefaultPort.obs;

  /// 允许局域网访问（监听 0.0.0.0，地址要带令牌）
  var lanAccess = false.obs;

  /// 局域网访问令牌（第一次需要时生成，之后一直用它）
  var token = "".obs;

  /// 正在运行
  var running = false.obs;

  /// 启动失败的原因
  var errorMsg = "".obs;

  /// 本机的局域网地址（IPv4）
  var lanAddresses = <String>[].obs;

  /// 电脑上“记录弹幕（ASS）”的保存位置，空为下载文件夹里的 SimpleLive
  var recordDir = "".obs;

  ObsBridgeHub? _hub;
  ObsBridgeServer? _server;
  final List<_RoomOwner> _owners = [];

  /// 接口正在运行（直播间据此决定要不要整理房间信息）
  bool get active => _hub != null;

  @override
  void onInit() {
    var storage = LocalStorageService.instance;
    enabled.value =
        storage.getValue(LocalStorageService.kObsBridgeEnable, false);
    port.value =
        storage.getValue(LocalStorageService.kObsBridgePort, kDefaultPort);
    lanAccess.value =
        storage.getValue(LocalStorageService.kObsBridgeLan, false);
    token.value = storage.getValue(LocalStorageService.kObsBridgeToken, "");
    recordDir.value =
        storage.getValue(LocalStorageService.kDanmakuRecordDir, "");
    // 多开的副窗口不开录屏接口（端口只能一个进程用）
    if (enabled.value && !MultiWindow.skips(BackgroundTask.obsBridge)) {
      start();
    }
    if (Platform.isIOS) {
      WidgetsBinding.instance.addObserver(this);
    }
    super.onInit();
  }

  @override
  void onClose() {
    if (Platform.isIOS) {
      WidgetsBinding.instance.removeObserver(this);
    }
    stop();
    super.onClose();
  }

  bool _wasPaused = false;

  /// iOS 退到后台挂起后，监听的端口可能被系统收回；从后台回来时重新启动
  /// （网页会自动重连）。只是下拉通知栏等短暂离开时不重启
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _wasPaused = true;
    } else if (state == AppLifecycleState.resumed && _wasPaused) {
      _wasPaused = false;
      if (enabled.value) {
        start();
      }
    }
  }

  // ---------------- 设置 ----------------

  Future<void> setEnabled(bool value) async {
    enabled.value = value;
    LocalStorageService.instance
        .setValue(LocalStorageService.kObsBridgeEnable, value);
    if (value) {
      await start();
    } else {
      await stop();
    }
  }

  Future<void> setPort(int value) async {
    if (value < 1024 || value > 65535 || value == port.value) {
      return;
    }
    port.value = value;
    LocalStorageService.instance
        .setValue(LocalStorageService.kObsBridgePort, value);
    if (enabled.value) {
      await start();
    }
  }

  Future<void> setLanAccess(bool value) async {
    lanAccess.value = value;
    LocalStorageService.instance
        .setValue(LocalStorageService.kObsBridgeLan, value);
    if (value) {
      _ensureToken();
    }
    if (enabled.value) {
      await start();
    }
  }

  /// 换一个局域网访问令牌（旧地址失效）
  Future<void> regenerateToken() async {
    _setToken(_newToken());
    if (enabled.value && lanAccess.value) {
      await start();
    }
  }

  void setRecordDir(String value) {
    recordDir.value = value;
    LocalStorageService.instance
        .setValue(LocalStorageService.kDanmakuRecordDir, value);
  }

  void _ensureToken() {
    if (token.value.isEmpty) {
      _setToken(_newToken());
    }
  }

  void _setToken(String value) {
    token.value = value;
    LocalStorageService.instance
        .setValue(LocalStorageService.kObsBridgeToken, value);
  }

  static String _newToken() {
    const chars = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    var random = Random.secure();
    return List.generate(20, (_) => chars[random.nextInt(chars.length)]).join();
  }

  // ---------------- 地址 ----------------

  /// 本机地址，如 http://127.0.0.1:25789/overlay（局域网模式带令牌）
  String localUrl(String path) => _url("127.0.0.1", path);

  /// 局域网地址（第一个局域网 IP），没有时为 null
  String? lanUrl(String path) {
    if (!lanAccess.value || lanAddresses.isEmpty) {
      return null;
    }
    return _url(lanAddresses.first, path);
  }

  String _url(String host, String path) {
    var url = "http://$host:${port.value}$path";
    if (lanAccess.value && token.value.isNotEmpty) {
      url += "${path.contains("?") ? "&" : "?"}token=${token.value}";
    }
    return url;
  }

  Future<void> refreshLanAddresses() async {
    try {
      var list = await NetworkInterface.list(type: InternetAddressType.IPv4);
      var addresses = <String>[];
      for (var item in list) {
        for (var address in item.addresses) {
          if (address.isLoopback || address.address.startsWith("169.254.")) {
            continue;
          }
          addresses.add(address.address);
        }
      }
      // 家用路由器常见的 192.168.x.x 排在前面
      int rank(String ip) {
        if (ip.startsWith("192.168.")) return 0;
        if (ip.startsWith("10.")) return 1;
        if (RegExp(r"^172\.(1[6-9]|2\d|3[01])\.").hasMatch(ip)) return 2;
        return 3;
      }

      addresses.sort((a, b) => rank(a).compareTo(rank(b)));
      lanAddresses.value = addresses;
    } catch (e) {
      Log.logPrint(e);
      lanAddresses.clear();
    }
  }

  // ---------------- 启动、停止 ----------------

  /// 启动、停止按顺序进行（连续改设置时不会同时启动两个）
  Future<void> _queue = Future.value();
  Future<void> _serial(Future<void> Function() action) {
    var next = _queue.then((_) => action()).catchError((Object e) {
      Log.logPrint(e);
    });
    _queue = next;
    return next;
  }

  /// 启动（已在运行时按新设置重启）
  Future<void> start() => _serial(_start);

  Future<void> stop() => _serial(_stop);

  Future<void> _start() async {
    await _stop();
    if (lanAccess.value) {
      _ensureToken();
    }
    var hub = ObsBridgeHub();
    var server = ObsBridgeServer(
      hub: hub,
      config: danmakuConfig,
      port: port.value,
      lan: lanAccess.value,
      token: lanAccess.value ? token.value : null,
    );
    try {
      await server.start();
    } catch (e) {
      Log.logPrint(e);
      await hub.close();
      running.value = false;
      errorMsg.value = e is SocketException
          ? "端口 {port} 无法使用（可能被占用），请换一个".tf({"port": port.value})
          : "启动失败：{e}".tf({"e": e});
      return;
    }
    _hub = hub;
    _server = server;
    errorMsg.value = "";
    running.value = true;
    hub.setRoom(_top?.info());
    if (lanAccess.value) {
      refreshLanAddresses();
    }
  }

  Future<void> _stop() async {
    var server = _server;
    var hub = _hub;
    _server = null;
    _hub = null;
    running.value = false;
    await server?.stop();
    await hub?.close();
  }

  /// 应用当前的弹幕设置（/api/config，也是 ASS 的默认样式）。
  /// 手机上用全屏时的那一套大小
  static Map<String, dynamic> danmakuConfig() {
    var settings = AppSettingsController.instance;
    return {
      "size": settings.danmuSizeFor(DanmakuViewMode.fullscreen),
      "speed": settings.danmuSpeedFor(DanmakuViewMode.fullscreen),
      "area": settings.danmuArea.value,
      "opacity": settings.danmuOpacity.value,
      "stroke": settings.danmuStrokeWidth.value,
      "fontWeight": settings.danmuFontWeight.value,
      "emoteImage": settings.danmuEmoteImage.value,
      "emoteScale": settings.effectiveEmoteScale,
      "chatSize": settings.chatTextSize.value,
      "chatShowFace": settings.chatShowFace.value,
    };
  }

  // ---------------- 直播间推送 ----------------

  _RoomOwner? get _top => _owners.isEmpty ? null : _owners.last;

  bool _isTop(Object owner) =>
      _owners.isNotEmpty && identical(_owners.last.owner, owner);

  /// 打开直播间：成为最上层，[info] 返回它当前的房间信息
  void attach(Object owner, ObsRoomInfo? Function() info) {
    _owners.removeWhere((e) => identical(e.owner, owner));
    _owners.add(_RoomOwner(owner, info));
    _hub?.setRoom(info());
  }

  /// 关闭直播间：下面还有直播间时换成它，否则推送 room: null
  void detach(Object owner) {
    var wasTop = _isTop(owner);
    _owners.removeWhere((e) => identical(e.owner, owner));
    if (wasTop) {
      _hub?.setRoom(_top?.info());
    }
  }

  /// 房间信息变了（换了直播间、读到了标题、开播状态变了）
  void updateRoom(Object owner) {
    var hub = _hub;
    if (hub == null || !_isTop(owner)) {
      return;
    }
    hub.setRoom(_top!.info());
  }

  /// 一条聊天消息（已经过关键词屏蔽）
  void publishChat(Object owner, LiveMessage msg) {
    var hub = _hub;
    if (hub == null || !_isTop(owner)) {
      return;
    }
    hub.addChat(msg);
  }

  /// 醒目留言；[live] 为 false 表示进直播间时读到的历史 SC
  void publishSuperChats(
    Object owner,
    Iterable<LiveSuperChatMessage> list, {
    bool live = true,
  }) {
    var hub = _hub;
    if (hub == null || !_isTop(owner)) {
      return;
    }
    for (var sc in list) {
      hub.addSuperChat(sc, live: live);
    }
  }

  void publishOnline(Object owner, int online) {
    var hub = _hub;
    if (hub == null || !_isTop(owner)) {
      return;
    }
    hub.setOnline(online);
  }

  // ---------------- 记录弹幕（ASS） ----------------

  /// “记录弹幕（ASS）”的保存文件夹：电脑上为设置的位置 [custom] 或下载文件夹里的
  /// SimpleLive，手机上为应用自己的文件夹（保存后用系统分享发出去）。
  /// 写不进去时依次换下一个
  static Future<Directory> danmakuRecordDirectory([String custom = ""]) async {
    var desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    var candidates = <Future<Directory?> Function()>[
      if (desktop && custom.isNotEmpty) () async => Directory(custom),
      if (desktop)
        () async {
          var downloads = await getDownloadsDirectory();
          return downloads == null
              ? null
              : Directory(p.join(downloads.path, "SimpleLive"));
        },
      if (Platform.isAndroid)
        () async {
          var external = await getExternalStorageDirectory();
          return external == null
              ? null
              : Directory(p.join(external.path, "danmaku"));
        },
      () async => Directory(p.join(
          (await getApplicationDocumentsDirectory()).path,
          desktop ? "SimpleLive" : "danmaku")),
    ];
    Object? lastError;
    for (var candidate in candidates) {
      try {
        var dir = await candidate();
        if (dir == null) {
          continue;
        }
        await dir.create(recursive: true);
        // 确认能写入（macOS 沙盒等情况下可能没有权限）
        var probe = File(p.join(dir.path, ".simplelive_write_test"));
        await probe.writeAsString("");
        await probe.delete();
        return dir;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? "找不到可以保存的文件夹".t;
  }
}
