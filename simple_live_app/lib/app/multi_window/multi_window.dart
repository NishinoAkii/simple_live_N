import 'dart:async';
import 'dart:ffi'
    show DynamicLibrary, DynamicLibraryExtension, Int32, IntPtr, Uint32;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/exit_guard.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/window_apply.dart';
import 'package:simple_live_app/app/multi_window/secondary_process.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/multi_window/window_changes.dart';
import 'package:simple_live_app/app/multi_window/window_frame.dart';
import 'package:simple_live_app/app/multi_window/window_layout.dart';
import 'package:simple_live_app/app/multi_window/window_link.dart';
import 'package:simple_live_app/app/multi_window/window_server.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';
import 'package:simple_live_app/app/multi_window/window_snapshot.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/window_memory.dart';
import 'package:simple_live_app/app/window_pin.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:window_manager/window_manager.dart';

/// 副窗口里不启动的后台功能
enum BackgroundTask {
  /// WebDAV 自动同步
  webdavAutoSync,

  /// 局域网同步（UDP 广播和同步服务）
  lanSync,

  /// 录屏接口（OBS 等）
  obsBridge,

  /// 开播提醒（检查和发通知）
  liveNotify,

  /// 同步关注到账号的队列（关注、取关交给主窗口，由主窗口同步）
  accountFollowQueue,

  /// 直播源每天的自动检查更新
  liveSourceUpdateCheck,

  /// App 启动时检查新版本
  appUpdateCheck,
}

/// 电脑上多开：一个直播间一个窗口，每个窗口是单独的进程。
///
/// - 主窗口：平常打开的那个。开副窗口、收副窗口交来的改动（[WindowServer]）、
///   退出时把副窗口一起关掉。记着开着的副窗口在看什么、放在哪里，定下“上次的一组”，
///   历史页可以一下全部打开（[WindowSetRecorder]、[restoreLast]）。
/// - 副窗口：读一份数据快照（[WindowSnapshot]），关注、观看记录、屏蔽、备注、
///   记住的清晰度、开播提醒的开关交给主窗口保存（[forward]）；音量、弹幕开关、
///   临时换的清晰度、收起侧栏这些只在这个窗口里，不保存。设置只能查看。
///   不启动 [secondarySkips] 里的后台功能，日志单独写一个文件。
///
/// 只在 Windows 上开放：摆放按 Windows 的物理像素算，别的系统没有试过
class MultiWindow {
  MultiWindow._();

  /// 副窗口的启动参数；主窗口、手机上为 null
  static SecondaryLaunch? launch;

  static bool get isSecondary => launch != null;

  /// 主窗口带着链接或参数启动（为了打开某个直播间）
  static bool startedForRoom = false;

  /// 测试里当作电脑（或手机）
  @visibleForTesting
  static bool? debugSupported;

  static bool get supported =>
      debugSupported ?? (!kIsWeb && Platform.isWindows);

  /// 能不能开新窗口（只有主窗口能开）
  static bool get canOpen => supported && !isSecondary;

  static const secondarySkips = {
    BackgroundTask.webdavAutoSync,
    BackgroundTask.lanSync,
    BackgroundTask.obsBridge,
    BackgroundTask.liveNotify,
    BackgroundTask.accountFollowQueue,
    BackgroundTask.liveSourceUpdateCheck,
    BackgroundTask.appUpdateCheck,
  };

  /// 这个窗口里要不要跳过 [task]
  static bool skips(BackgroundTask task) =>
      isSecondary && secondarySkips.contains(task);

  // ---------------------------------------------------------------------
  // 副窗口
  // ---------------------------------------------------------------------

  static MainWindowLink? link;

  /// 主窗口不在了（副窗口顶上显示提示）
  static final mainGone = false.obs;

  /// 提示点了“知道了”
  static final noticeDismissed = false.obs;

  /// 读启动参数。是副窗口时记下来，日志换一个文件名
  static Future<void> init(List<String> args) async {
    if (!supported) {
      return;
    }
    var parsed = SecondaryLaunch.parse(args);
    if (parsed == null) {
      // 带着链接或别的参数启动（为了打开某个直播间）：启动时不问要不要打开上次的多开窗口
      startedForRoom = args.any((e) => e.isNotEmpty && !e.startsWith("-"));
      return;
    }
    var support = (await getApplicationSupportDirectory()).path;
    if (!parsed.dataDirUnder(support) ||
        !await Directory(parsed.dataDir).exists()) {
      return;
    }
    launch = parsed;
    Log.fileTag = "-w${parsed.slot}";
    // 先拿着主窗口进程的句柄：之后它不在了（崩了、被结束）能查到，编号也不会被别的进程占用
    _mainProcess = MainProcess(parsed.mainPid);
    // 启动时各个服务就可能交改动过来（比如清掉到期的屏蔽），先准备好，连接在第一次发时才建
    link = MainWindowLink(
      port: parsed.port,
      token: parsed.token,
      onUnsaved: _onUnsaved,
      onMainGone: _onMainGone,
    );
  }

  static MainProcess? _mainProcess;
  static MainGoneWatch? _goneWatch;

  /// 和主窗口断开了：顶上先提示；确认主窗口进程真的没了（崩了、被结束），这个窗口自己关掉。
  /// 主窗口还在、只是一时没响应时留着提示，等它退出时再关
  static void _onMainGone() {
    mainGone.value = true;
    if (_goneWatch != null) {
      return;
    }
    var process = _mainProcess;
    _goneWatch = MainGoneWatch(
      alive: () => process?.alive,
      onGone: () {
        Log.i("主窗口进程已经不在了，关闭这个窗口");
        unawaited(_closeSelf());
      },
    );
    unawaited(_goneWatch!.start());
  }

  /// 副窗口的标题
  static String get windowTitle =>
      "Simple Live N · ${"多开窗口 {slot}".tf({"slot": launch!.slot})}";

  /// 副窗口：按现在的缩放挪到主窗口算好的位置（到了缩放不同的屏幕上，显示后由 [fixPlacement] 再摆一次）。
  /// 启动参数里是看得见的部分，这里按估的边框换成外框（见 FrameInsets）
  static Future<void> placeSelf() async {
    // 主窗口置顶时开的、打开上次的窗口时上次置顶的：一出来就置顶（后开的在上面）
    if (launch?.pinned ?? false) {
      await WindowPin.instance.set(true);
    }
    var bounds = launch?.bounds;
    if (bounds == null) {
      await windowManager.center();
      return;
    }
    var outer = FrameInsets.estimate(launch!.scale).outerOf(bounds);
    await windowManager.setBounds(_toLogical(outer));
  }

  /// 显示以后调用：窗口到了缩放不同的屏幕上，系统会按新缩放改大小；边框也按这次量到的算，
  /// 让看得见的边正好落在记下的位置（贴靠在屏幕边上的还贴着边）
  static Future<void> fixPlacement() async {
    var bounds = launch?.bounds;
    if (bounds == null) {
      return;
    }
    var target = launch!.scale;
    for (var i = 0; i < 20 && (_dpr() - target).abs() > 0.01; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    var want = WindowFrame.instance.insets(target).outerOf(bounds);
    var frame = WindowFrame.instance.read();
    Rect current;
    if (frame != null) {
      current = frame.$1;
    } else {
      var b = await windowManager.getBounds();
      var r = _dpr();
      current = Rect.fromLTWH(b.left * r, b.top * r, b.width * r, b.height * r);
    }
    if ((current.left - want.left).abs() > 1 ||
        (current.top - want.top).abs() > 1 ||
        (current.width - want.width).abs() > 1 ||
        (current.height - want.height).abs() > 1) {
      await windowManager.setBounds(_toLogical(want));
    }
  }

  /// 副窗口一开始用的音量、静音、弹幕开关、清晰度、声音输出设备（主窗口算好放在启动参数里）
  static WindowSettings? get launchSettings {
    var map = launch?.settings;
    if (map == null) {
      return null;
    }
    try {
      return WindowSettings.fromJson(map);
    } on FormatException {
      return null;
    }
  }

  static WindowSettings? _reportedSettings;

  /// 副窗口：音量、静音、弹幕开关、清晰度、声音输出设备变了，告诉主窗口（记成这个直播间多开时的设置）
  static void reportSettings(WindowSettings settings) {
    var l = link;
    if (!isSecondary || l == null || settings == _reportedSettings) {
      return;
    }
    _reportedSettings = settings;
    unawaited(l.report(WindowReport(settings: settings)));
  }

  static bool? _reportedFull;
  static bool? _reportedPinned;

  /// 副窗口：窗口全屏、置顶变了，告诉主窗口（记在这一组里）
  static void _reportLayout({bool? windowFull, bool? pinned}) {
    var l = link;
    if (!isSecondary || l == null) {
      return;
    }
    if (windowFull == _reportedFull) {
      windowFull = null;
    }
    if (pinned == _reportedPinned) {
      pinned = null;
    }
    if (windowFull == null && pinned == null) {
      return;
    }
    _reportedFull = windowFull ?? _reportedFull;
    _reportedPinned = pinned ?? _reportedPinned;
    unawaited(l.report(WindowReport(windowFull: windowFull, pinned: pinned)));
  }

  static double _dpr() =>
      WidgetsBinding
          .instance.platformDispatcher.implicitView?.devicePixelRatio ??
      1.0;

  static Rect _toLogical(Rect physical) {
    var r = _dpr();
    return Rect.fromLTWH(physical.left / r, physical.top / r,
        physical.width / r, physical.height / r);
  }

  /// runApp 之后调用：连上主窗口，打开直播间
  static void startSecondary() {
    var info = launch;
    if (info == null) {
      return;
    }
    Log.i("多开窗口 ${info.slot}：主窗口进程 ${info.mainPid}");
    // 打开窗口时界面语言还没读出来，这里按界面语言重设一次标题
    unawaited(windowManager.setTitle(windowTitle));
    var l = link;
    if (l == null) {
      return;
    }
    // 置顶变了（自己点的、跟着主窗口的）告诉主窗口，“打开上次的窗口”时照样置顶。
    // 一开始的置顶、窗口全屏主窗口知道
    _reportedPinned = info.pinned;
    _reportedFull = info.windowFull;
    ever<bool>(
        WindowPin.instance.pinned, (value) => _reportLayout(pinned: value));
    unawaited(l.ping().then((ok) {
      if (ok) {
        unawaited(l.watch(
          onClose: _closeSelf,
          // 主窗口置顶或取消置顶：跟着变（之后自己再点只改这个窗口）
          onPin: (value) => unawaited(WindowPin.instance.set(value)),
        ));
      }
    }));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      var site = Sites.allSites[info.siteId];
      if (site == null) {
        SmartDialog.showToast("找不到平台：{siteId}".tf({"siteId": info.siteId}));
        return;
      }
      Get.toNamed(RoutePath.kLiveRoomDetail,
          arguments: site, parameters: {"roomId": info.roomId});
    });
  }

  static DateTime? _lastUnsavedToast;

  static void _onUnsaved(WindowChange change, bool gone) {
    Log.w("多开：改动没有交给主窗口（${change.op}，主窗口${gone ? "不在" : "没收"}）");
    // 连着几条（比如屏蔽后马上撤销）只提示一次
    var now = DateTime.now();
    if (_lastUnsavedToast != null &&
        now.difference(_lastUnsavedToast!) < const Duration(seconds: 3)) {
      return;
    }
    _lastUnsavedToast = now;
    try {
      SmartDialog.showToast(
        gone ? "主窗口已关闭，这项修改不会保存".t : "主窗口未能保存这项修改".t,
      );
    } catch (_) {
      // 界面还没起来（启动时），顶上的提示会说明
    }
  }

  static _PlacementReporter? _placement;
  static WindowRoom? _reportedRoom;

  /// 副窗口显示以后调用：用鼠标拖完、关之前把位置告诉主窗口（“打开上次的窗口”时放回这里）。
  /// 自己点关闭时先拦一下，报完位置再关
  static void watchPlacement() {
    if (!isSecondary || _placement != null) {
      return;
    }
    var reporter = _PlacementReporter();
    _placement = reporter;
    windowManager.addListener(reporter);
    unawaited(windowManager.setPreventClose(true));
  }

  static Object? _mainRoomOwner;
  static WindowRoom? _mainRoom;

  /// 主窗口现在在看的直播间（不在直播间里时为 null）
  static WindowRoom? get mainRoom => _mainRoom;

  /// 直播间页面打开、换直播间、读到直播间信息时调用（[owner] 是那个页面的控制器）。
  /// 副窗口：告诉主窗口这个窗口在看哪个直播间；主窗口：记下自己在看的
  static void noteRoom(Object owner, WindowRoom room) {
    if (isSecondary) {
      if (room == _reportedRoom) {
        return;
      }
      _reportedRoom = room;
      var l = link;
      if (l != null) {
        unawaited(l.report(WindowReport(room: room)));
      }
      return;
    }
    _mainRoomOwner = owner;
    if (room == _mainRoom) {
      return;
    }
    _mainRoom = room;
    recorder.mainRoomChanged();
  }

  /// 直播间页面关了。副窗口里不管（留着最后看的直播间）
  static void leaveRoom(Object owner) {
    if (isSecondary || !identical(owner, _mainRoomOwner)) {
      return;
    }
    _mainRoomOwner = null;
    _mainRoom = null;
    _mainFull = false;
    recorder.mainRoomChanged();
  }

  /// 主窗口的直播间是不是窗口全屏
  static bool _mainFull = false;

  /// 直播间页面进出窗口全屏时调用（[owner] 是那个页面的控制器）。副窗口：告诉主窗口；
  /// 主窗口：记下自己的。“打开上次的窗口”时照样恢复
  static void noteWindowFull(Object owner, bool value) {
    if (isSecondary) {
      _reportLayout(windowFull: value);
      return;
    }
    if (!identical(owner, _mainRoomOwner) || value == _mainFull) {
      return;
    }
    _mainFull = value;
    recorder.mainRoomChanged();
  }

  /// 打开上次的一组时，主窗口要进窗口全屏的直播间（[WindowRoom.key]）。主窗口在这个直播间里的
  /// 页面看到后进窗口全屏（[takeMainFull]，用一次），过一会儿还没用上就作废
  static final mainFullRequest = RxnString();
  static DateTime _mainFullUntil = DateTime(0);

  static void _requestMainFull(WindowRoom room) {
    _mainFullUntil = DateTime.now().add(const Duration(seconds: 15));
    // 上次的没用上、还是这个直播间时也要再通知一次
    mainFullRequest.value = null;
    mainFullRequest.value = room.key;
  }

  /// 主窗口在 [room] 里的页面：要不要进窗口全屏（打开上次的一组时上次是窗口全屏的）
  static bool takeMainFull(WindowRoom room) {
    if (isSecondary || mainFullRequest.value != room.key) {
      return false;
    }
    mainFullRequest.value = null;
    return DateTime.now().isBefore(_mainFullUntil);
  }

  /// 副窗口自己直接退出之前（定时关闭时间到了）：把位置告诉主窗口，最多等 1 秒。
  /// 主窗口、手机上什么都不做
  static Future<void> reportPlacementNow() async {
    try {
      await _placement?.reportNow().timeout(const Duration(seconds: 1));
    } catch (_) {}
  }

  static Future<void> _closeSelf() async {
    Log.i("主窗口要求关闭");
    await reportPlacementNow();
    try {
      await windowManager.close();
    } catch (_) {}
    // 万一没关掉
    await Future<void>.delayed(const Duration(seconds: 2));
    exit(0);
  }

  /// 副窗口：把要留下的改动交给主窗口。主窗口、手机上什么都不做
  static void forward(WindowChange change) {
    if (!isSecondary) {
      return;
    }
    var l = link;
    if (l == null) {
      _onUnsaved(change, true);
      return;
    }
    unawaited(l.send(change));
  }

  // ---------------------------------------------------------------------
  // 主窗口
  // ---------------------------------------------------------------------

  static WindowHost? _host;

  /// 开着几个副窗口
  static final openCount = 0.obs;

  /// 开着的副窗口和上次的一组（只在主窗口里用）
  @visibleForTesting
  static WindowSetRecorder recorder = WindowSetRecorder(
    mainRoom: () => mainRoom,
    mainLayout: () =>
        (windowFull: _mainFull, pinned: WindowPin.instance.pinned.value),
    onGroupClosed: _stampHistory,
  );

  /// 一组关掉时：主窗口的直播间和这几个副窗口的观看记录时间写在一起（主窗口的在最前面，
  /// 副窗口按打开的顺序），观看记录里排在一起。记录的格式不变，只改时间；没有记录的不加
  static Future<void> _stampHistory(WindowSet group) async {
    var main = group.mainRoom;
    if (main == null || !Get.isRegistered<DBService>()) {
      return;
    }
    var db = DBService.instance;
    var rooms = [main, for (var e in group.windows) e.room];
    var now = DateTime.now();
    var changed = false;
    for (var i = 0; i < rooms.length; i++) {
      var history = db.getHistory("${rooms[i].siteId}_${rooms[i].roomId}");
      if (history == null) {
        continue;
      }
      history.updateTime = now.subtract(Duration(milliseconds: i));
      await db.addOrUpdateHistory(history);
      changed = true;
    }
    if (changed) {
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
    }
  }

  /// 主窗口选的声音输出设备（“每个窗口单独选声音输出设备”开着时用，只在本机）
  static String? get mainAudioDevice => recorder.slotDevice(0);
  static set mainAudioDevice(String? name) => recorder.setSlotDevice(0, name);

  /// 观看记录里这个直播间是一组的主窗口直播间时，最近和它一起关的那一组（电脑上的主窗口才有）
  static WindowSet? groupFor(String siteId, String roomId) =>
      canOpen ? recorder.groupFor(siteId, roomId) : null;

  /// 打开这一组里的副窗口（主窗口的直播间已经在主窗口里打开了，它的窗口全屏、置顶也照这一组的）
  static Future<RestoreResult?> restoreGroup(WindowSet group) async {
    if (!canOpen || group.isEmpty) {
      return null;
    }
    return host.restore(group);
  }

  static WindowHost get host =>
      _host ??= WindowHost(AppWindowChangeSink(), recorder);

  /// 在新窗口里打开这个直播间。[title]、[userName] 只是先记着显示用，
  /// 副窗口读到直播间信息后会换成新的
  static Future<bool> openRoom(Site site, String roomId,
      {String title = "", String userName = ""}) async {
    if (!canOpen) {
      return false;
    }
    return host.open(WindowRoom(
      siteId: site.id,
      roomId: roomId,
      title: title,
      userName: userName,
    ));
  }

  /// 关掉全部副窗口：先请它们自己退出，3 秒后还没退的强制结束。返回关了几个。
  /// 关之前开着的这一组记作“上次的一组”
  static Future<int> closeAll() async {
    var host = _host;
    if (host == null) {
      return 0;
    }
    return host.closeAll();
  }

  /// 历史页“打开上次的窗口”要打开的那一组：电脑上的主窗口、记着上次的一组时才有。
  /// 在 Obx 里用（先读上次的一组，有变化时跟着变）
  static WindowSet? get restorableSet {
    var set = recorder.last.value;
    return canOpen && set != null && !set.isEmpty ? set : null;
  }

  /// 打开上次的一组：放回上次的位置，已经开着的直播间跳过，不超过同时开的上限。
  /// 正在开别的窗口、没有上次的一组时返回 null
  static Future<RestoreResult?> restoreLast() async {
    var set = canOpen ? recorder.last.value : null;
    if (set == null || set.isEmpty) {
      return null;
    }
    return host.restore(set);
  }
}

typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = int Function(int, int, int);
typedef _WaitNative = Uint32 Function(IntPtr, Uint32);
typedef _WaitDart = int Function(int, int);

/// 副窗口：主窗口的进程还在不在。Windows 上一启动就打开它的进程句柄（只要等待的权限），
/// 之后不等待地查一下有没有退出
class MainProcess {
  MainProcess(int pid) {
    if (pid <= 0 || !Platform.isWindows) {
      return;
    }
    try {
      var kernel = DynamicLibrary.open("kernel32.dll");
      var open = kernel
          .lookupFunction<_OpenProcessNative, _OpenProcessDart>("OpenProcess");
      _wait =
          kernel.lookupFunction<_WaitNative, _WaitDart>("WaitForSingleObject");
      // SYNCHRONIZE；打不开说明进程已经不在了
      _handle = open(0x00100000, 0, pid);
    } catch (e) {
      Log.logPrint(e);
      _wait = null;
    }
  }

  _WaitDart? _wait;
  int _handle = 0;

  /// true 还在，false 已经退出，null 查不了
  bool? get alive {
    var wait = _wait;
    if (wait == null) {
      return null;
    }
    if (_handle == 0) {
      return false;
    }
    return switch (wait(_handle, 0)) {
      0 => false, // WAIT_OBJECT_0：退出了
      0x102 => true, // WAIT_TIMEOUT：还在
      _ => null,
    };
  }
}

/// 副窗口和主窗口断开以后：主窗口进程不在了，再隔 [grace] 看两次还是不在，就调用 [onGone]
/// （一时查不准不会关）。主窗口还在时每 [poll] 看一次，它退出时再关
class MainGoneWatch {
  MainGoneWatch({
    required this.alive,
    required this.onGone,
    this.grace = const Duration(milliseconds: 2500),
    this.poll = const Duration(seconds: 3),
  });

  final bool? Function() alive;
  final void Function() onGone;
  final Duration grace;
  final Duration poll;
  bool _stopped = false;
  bool _started = false;

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    while (!_stopped) {
      if (alive() == false && await _confirm()) {
        _stopped = true;
        onGone();
        return;
      }
      await Future<void>.delayed(poll);
    }
  }

  Future<bool> _confirm() async {
    for (var i = 0; i < 2; i++) {
      await Future<void>.delayed(grace ~/ 2);
      if (_stopped || alive() != false) {
        return false;
      }
    }
    return true;
  }

  void stop() => _stopped = true;
}

/// 打开上次的一组的结果
class RestoreResult {
  final int opened;
  final int skipped;
  final int limited;
  final int failed;

  /// 要在主窗口里打开的直播间（主窗口不在直播间里时）
  final WindowRoom? mainRoom;
  const RestoreResult({
    required this.opened,
    required this.skipped,
    required this.limited,
    required this.failed,
    this.mainRoom,
  });

  /// 打开以后的提示
  String get message {
    if (opened == 0 && limited == 0 && failed == 0 && skipped > 0) {
      return "上次的窗口都已经开着".t;
    }
    if (limited > 0) {
      return "已打开 {count} 个窗口，多开窗口最多 {max} 个"
          .tf({"count": opened, "max": SecondaryLaunch.maxWindows});
    }
    if (failed > 0) {
      return "已打开 {count} 个窗口，{failed} 个没有打开"
          .tf({"count": opened, "failed": failed});
    }
    return "已打开 {count} 个窗口".tf({"count": opened});
  }
}

/// 副窗口：把位置（物理像素，看得见的部分）告诉主窗口。不定时去看，只在这两个时候：
/// - 关之前（自己点关闭、关全部、主窗口退出时一起关、主窗口没了自己关）量一次。
///   Win+方向键、贴靠布局、贴靠助手没有挪动事件，靠这一次记下；
/// - 用鼠标拖完、改完大小（window_manager 的 moved、resized，拖的时候不算）。
/// 全屏、最小化、最大化、直播间小窗时不报，主窗口那边留着上次正常的位置。
/// 窗口或电脑崩了来不及报时，留着这次之前记的位置
class _PlacementReporter with WindowListener {
  Rect? _sent;
  double _sentScale = 0;
  bool _closing = false;

  /// 关之前马上报一次
  Future<void> reportNow() => _report();

  @override
  void onWindowMoved() => unawaited(_report());
  @override
  void onWindowResized() => unawaited(_report());

  /// 自己点关闭（拦住了）：报完位置再关
  @override
  void onWindowClose() async {
    if (_closing || !await windowManager.isPreventClose()) {
      return;
    }
    _closing = true;
    try {
      await reportNow().timeout(const Duration(seconds: 1));
    } catch (_) {}
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  Future<void> _report() async {
    var l = MultiWindow.link;
    if (l == null || !l.online) {
      return;
    }
    try {
      if (WindowMemory.instance.inSmallWindow ||
          await windowManager.isFullScreen() ||
          await windowManager.isMinimized() ||
          await windowManager.isMaximized()) {
        return;
      }
      var scale = WindowMemory.windowScale;
      Rect visible;
      var frame = WindowFrame.instance.read();
      if (frame != null && frame.$1 != frame.$2) {
        visible = frame.$2;
      } else {
        visible =
            FrameInsets.estimate(scale).visibleOf(await WindowMemory.bounds());
      }
      var rect = Rect.fromLTWH(
          visible.left.roundToDouble(),
          visible.top.roundToDouble(),
          visible.width.roundToDouble(),
          visible.height.roundToDouble());
      if (rect == _sent && scale == _sentScale) {
        return;
      }
      _sent = rect;
      _sentScale = scale;
      await l.report(WindowReport(bounds: rect, scale: scale));
    } catch (e) {
      Log.logPrint(e);
    }
  }
}

class _Secondary {
  _Secondary(this.slot, this.token, this.process, this.dir);
  final int slot;
  final String token;
  final SecondaryProcess process;
  final Directory dir;
  bool exited = false;
}

/// 主窗口这边：开副窗口、记着它们（[recorder]）、关掉它们
class WindowHost {
  WindowHost(WindowChangeSink sink, this.recorder)
      : server = WindowServer(sink) {
    server.onReport = _onReport;
    // 主窗口置顶、取消置顶：开着的副窗口都跟着变；主窗口的也记在开着的这一组里
    _pinWorker = ever<bool>(WindowPin.instance.pinned, (value) {
      server.setPin(value);
      recorder.mainRoomChanged();
    });
  }

  late final Worker _pinWorker;

  /// 不再跟着主窗口的置顶（测试用）
  void dispose() => _pinWorker.dispose();

  final WindowServer server;
  final WindowSetRecorder recorder;
  final Map<int, _Secondary> _windows = {};
  bool _opening = false;

  Future<bool> open(WindowRoom room) async {
    if (_opening) {
      return false;
    }
    _opening = true;
    try {
      return await _open(room);
    } catch (e, stackTrace) {
      Log.e("打开多开窗口失败：$e", stackTrace);
      SmartDialog.showToast("新窗口打开失败：{error}".tf({"error": e}));
      return false;
    } finally {
      _opening = false;
    }
  }

  void _onReport(String token, WindowReport report) {
    for (var w in _windows.values) {
      if (w.token == token) {
        recorder.reported(w.slot, report);
        return;
      }
    }
  }

  /// 开着的副窗口现在的位置（物理像素），按编号
  Map<int, Rect> _openRects() => {
        for (var e in recorder.entries)
          if (e.bounds != null && _windows.containsKey(e.slot))
            e.slot: e.bounds!,
      };

  /// 空着的编号里最小的（1 到 [SecondaryLaunch.maxWindows]）：第几个开的就是第几个
  int? _freeNumber() {
    for (var i = 1; i <= SecondaryLaunch.maxWindows; i++) {
      if (!_windows.containsKey(i)) {
        return i;
      }
    }
    return null;
  }

  /// 屏幕（可用区域，物理像素）、主窗口的位置（物理像素）和它所在屏幕的缩放
  Future<({List<ScreenArea> screens, Rect main, double dpr})> _screens() async {
    var dpr = WidgetsBinding
            .instance.platformDispatcher.implicitView?.devicePixelRatio ??
        1.0;
    var main = await windowManager.getBounds();
    var mainPhysical = Rect.fromLTWH(
        main.left * dpr, main.top * dpr, main.width * dpr, main.height * dpr);
    var screens = <ScreenArea>[];
    for (var d in await screenRetriever.getAllDisplays()) {
      var scale = (d.scaleFactor ?? 1).toDouble();
      var pos = d.visiblePosition ?? Offset.zero;
      var size = d.visibleSize ?? d.size;
      // 屏幕信息是逻辑像素，换回物理像素后取整。不往里收：贴靠在屏幕边上的窗口要放回边上，
      // 差的一两个像素由 WindowLayout.clampInto 的 slack 兜着
      screens.add(ScreenArea(
        Rect.fromLTRB(
          (pos.dx * scale).roundToDouble(),
          (pos.dy * scale).roundToDouble(),
          ((pos.dx + size.width) * scale).roundToDouble(),
          ((pos.dy + size.height) * scale).roundToDouble(),
        ),
        scale,
      ));
    }
    return (screens: screens, main: mainPhysical, dpr: dpr);
  }

  Future<bool> _open(WindowRoom room) async {
    if (_windows.length >= SecondaryLaunch.maxWindows) {
      SmartDialog.showToast(
          "多开窗口最多 {count} 个".tf({"count": SecondaryLaunch.maxWindows}));
      return false;
    }
    // 摆放：这个编号记过的位置；第一次用时从前一个窗口（或主窗口）往右下错开
    var env = await _screens();
    var slot = _freeNumber()!;
    var where = WindowRestore.place(
      slot,
      screens: env.screens,
      remembered: recorder.slotPlacements,
      open: _openRects(),
      main: env.main,
    );
    await _launch(
      WindowEntry(
        slot: slot,
        room: room,
        bounds: where?.$1,
        scale: where?.$2 ?? env.dpr,
        // 主窗口置顶时，新开的一出来就置顶
        pinned: WindowPin.instance.pinned.value,
      ),
      // 新开的：这个直播间记的设置，“默认静音”开着时先静音
      WindowSettings.initial(
        restored: false,
        muteNew: MultiWindowPrefs.muteNew.value,
        room: recorder.roomSettings(room),
        audioDevice: _deviceFor(slot, null),
      ),
    );
    SmartDialog.showToast("已在新窗口打开".t);
    return true;
  }

  /// 打开上次的一组（[saved]）：按上次打开的顺序开（后开的在上面），每个放回上次的位置
  /// （缩放改了按逻辑大小换算，整个放进屏幕里），那块屏幕找不到了时按这个编号记的位置或错开放，
  /// 窗口全屏、置顶也照上次的。已经开着的直播间跳过，不超过同时开的上限。正在开别的窗口时返回 null
  Future<RestoreResult?> restore(WindowSet saved) async {
    if (_opening) {
      return null;
    }
    _opening = true;
    try {
      var env = await _screens();
      // 平台没装了（删掉的直播源）的打不开
      var known = [
        for (var e in saved.windows)
          if (Sites.allSites.containsKey(e.room.siteId)) e,
      ];
      var plan = WindowRestore.plan(
        WindowSet(known, mainRoom: saved.mainRoom, time: saved.time),
        screens: env.screens,
        remembered: recorder.slotPlacements,
        open: _openRects(),
        main: env.main,
        fallbackScale: env.dpr,
        usedSlots: _windows.keys.toSet(),
        openRooms: {for (var e in recorder.active) e.room.key},
        mainRoomNow: MultiWindow.mainRoom,
      );
      // 主窗口没在看别的直播间时，也回到这一组记的样子：置顶先设好（之后开的副窗口按各自记的，
      // 不跟着主窗口变），窗口全屏等主窗口的这个直播间页面出来再进（见 takeMainFull）
      var now = MultiWindow.mainRoom;
      var adoptMain = (plan.windows.isNotEmpty || plan.mainRoom != null) &&
          (now == null || now.key == saved.mainRoom?.key);
      if (adoptMain) {
        if (WindowPin.instance.pinned.value != saved.mainPinned) {
          await WindowPin.instance.set(saved.mainPinned);
        }
        var fullRoom = now ?? plan.mainRoom;
        if (saved.mainFull && fullRoom != null) {
          MultiWindow._requestMainFull(fullRoom);
        }
      }
      // 主窗口不按这一组来、现在置顶着：开的窗口都一出来就置顶（后开的在上面）
      var followPin = !adoptMain && WindowPin.instance.pinned.value;
      var opened = 0;
      var failed = saved.windows.length - known.length;
      for (var t in plan.windows) {
        try {
          await _launch(
            t.reopen(followPin: followPin),
            // 打开上次的：关的时候是什么样就是什么样
            WindowSettings.initial(
              restored: true,
              muteNew: MultiWindowPrefs.muteNew.value,
              room: recorder.roomSettings(t.saved.room),
              audioDevice: _deviceFor(t.slot, t.saved.audioDevice),
            ),
          );
          Log.i(
              "多开窗口 ${t.slot}：${t.atSavedSpot ? "放回上次的位置" : "上次的那块屏幕找不到了，换了个位置"}");
          opened++;
        } catch (e, stackTrace) {
          Log.e("打开上次的窗口失败：$e", stackTrace);
          failed++;
        }
      }
      Log.i("多开：打开上次的窗口，开了 $opened 个，已经开着 ${plan.skipped} 个，"
          "超出上限 ${plan.limited} 个，没打开 $failed 个");
      var mainRoom = plan.mainRoom;
      if (mainRoom != null && !Sites.allSites.containsKey(mainRoom.siteId)) {
        mainRoom = null;
      }
      return RestoreResult(
        opened: opened,
        skipped: plan.skipped,
        limited: plan.limited,
        failed: failed,
        mainRoom: mainRoom,
      );
    } finally {
      _opening = false;
    }
  }

  /// “每个窗口单独选声音输出设备”开着时，这个窗口用的设备：这一组里记的，没有时这个编号记的
  String? _deviceFor(int slot, String? saved) {
    if (!MultiWindowPrefs.devicePerWindow.value) {
      return null;
    }
    return saved ?? recorder.slotDevice(slot);
  }

  /// 开一个副窗口：数据快照、口令、启动参数（位置、置顶、窗口全屏、一开始的设置在参数里，
  /// 显示之前就放好）、日志都走这里
  Future<void> _launch(WindowEntry entry, [WindowSettings? settings]) async {
    if (_exiting) {
      throw StateError("主窗口正在退出");
    }
    var slot = entry.slot;

    // 数据快照
    var support = (await getApplicationSupportDirectory()).path;
    var root = WindowSnapshot.root(support);
    await WindowSnapshot.cleanup(root,
        keep: _windows.values.map((e) => e.dir.path).toSet());
    var dir = await WindowSnapshot.create(support, slot);
    var copied = await WindowSnapshot.copy(Directory(support), dir);
    Log.i("多开窗口 $slot：复制了 $copied 个数据文件");

    await server.start();
    var token = server.addPeer();
    var args = entry
        .toLaunch(
          port: server.port,
          token: token,
          dataDir: dir.path,
          mainPid: pid,
          settings:
              settings == null || settings.isEmpty ? null : settings.toJson(),
        )
        .toArgs();
    SecondaryProcess process;
    try {
      process = await SecondaryProcess.start(Platform.resolvedExecutable, args);
    } catch (e) {
      server.removePeer(token);
      await _deleteLater(dir);
      rethrow;
    }
    var window = _Secondary(slot, token, process, dir);
    _windows[slot] = window;
    recorder.opened(entry.copyWith(audioDevice: settings?.audioDevice));
    _changed();
    unawaited(process.exited.then((_) => _onExit(window)));
  }

  void _onExit(_Secondary window) {
    window.exited = true;
    if (identical(_windows[window.slot], window)) {
      _windows.remove(window.slot);
      // 手动关的从这一组去掉；关全部、主窗口退出时关的留着（见 WindowSetRecorder）
      recorder.exited(window.slot);
    }
    server.removePeer(window.token);
    _changed();
    unawaited(_deleteLater(window.dir));
    // 没有副窗口了：本机服务也关掉，下次开窗口时换一个端口
    if (_windows.isEmpty && !_opening) {
      unawaited(server.close());
    }
  }

  Future<void> _deleteLater(Directory dir) async {
    // 进程刚退出时文件可能还没放开
    for (var i = 0; i < 5; i++) {
      try {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  void _changed() {
    MultiWindow.openCount.value = _windows.length;
    var any = _windows.isNotEmpty;
    ExitGuard.hold(ExitGuard.multiWindow, any);
    if (any) {
      ExitGuard.addTask(_closeOnExit);
    } else {
      ExitGuard.removeTask(_closeOnExit);
    }
  }

  /// 主窗口在退出：之后不再开新窗口（正在打开上次的一组时也停下）
  bool _exiting = false;

  Future<void> _closeOnExit() async {
    _exiting = true;
    await closeAll();
  }

  Future<int> closeAll({Duration grace = const Duration(seconds: 3)}) async {
    var list = _windows.values.toList();
    if (list.isEmpty) {
      return 0;
    }
    // 关之前把开着的这一组定下来，之后它们退出时不再从里面去掉
    await recorder.closingAll();
    for (var w in list) {
      server.requestClose(w.token);
    }
    await Future.wait([for (var w in list) w.process.exited])
        .timeout(grace, onTimeout: () => <void>[]);
    var killed = 0;
    for (var w in list) {
      if (!w.exited) {
        w.process.kill();
        killed++;
      }
    }
    if (killed > 0) {
      Log.w("多开窗口：$killed 个没有自己退出，已强制结束");
    }
    return list.length;
  }
}
