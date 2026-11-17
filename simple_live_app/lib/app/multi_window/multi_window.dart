import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:simple_live_app/app/exit_guard.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/window_apply.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/app/multi_window/window_changes.dart';
import 'package:simple_live_app/app/multi_window/window_layout.dart';
import 'package:simple_live_app/app/multi_window/window_link.dart';
import 'package:simple_live_app/app/multi_window/window_server.dart';
import 'package:simple_live_app/app/multi_window/window_snapshot.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/routes/route_path.dart';
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
}

/// 电脑上多开：一个直播间一个窗口，每个窗口是单独的进程。
///
/// - 主窗口：平常打开的那个。开副窗口、收副窗口交来的改动（[WindowServer]）、
///   退出时把副窗口一起关掉。
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

  static bool get supported => !kIsWeb && Platform.isWindows;

  /// 能不能开新窗口（只有主窗口能开）
  static bool get canOpen => supported && !isSecondary;

  static const secondarySkips = {
    BackgroundTask.webdavAutoSync,
    BackgroundTask.lanSync,
    BackgroundTask.obsBridge,
    BackgroundTask.liveNotify,
    BackgroundTask.accountFollowQueue,
    BackgroundTask.liveSourceUpdateCheck,
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
      return;
    }
    var support = (await getApplicationSupportDirectory()).path;
    if (!parsed.dataDirUnder(support) ||
        !await Directory(parsed.dataDir).exists()) {
      return;
    }
    launch = parsed;
    Log.fileTag = "-w${parsed.slot}";
    // 启动时各个服务就可能交改动过来（比如清掉到期的屏蔽），先准备好，连接在第一次发时才建
    link = MainWindowLink(
      port: parsed.port,
      token: parsed.token,
      onUnsaved: _onUnsaved,
      onMainGone: () => mainGone.value = true,
    );
  }

  /// 副窗口的标题
  static String get windowTitle =>
      "Simple Live N · ${"多开窗口 {slot}".tf({"slot": launch!.slot})}";

  /// 副窗口：按现在的缩放挪到主窗口算好的位置（到了缩放不同的屏幕上，显示后由 [fixPlacement] 再摆一次）
  static Future<void> placeSelf() async {
    var bounds = launch?.bounds;
    if (bounds == null) {
      await windowManager.center();
      return;
    }
    await windowManager.setBounds(_toLogical(bounds));
  }

  /// 显示以后调用：窗口到了缩放不同的屏幕上，系统会按新缩放改大小，这里再摆一次
  static Future<void> fixPlacement() async {
    var bounds = launch?.bounds;
    if (bounds == null) {
      return;
    }
    var target = launch!.scale;
    for (var i = 0; i < 20 && (_dpr() - target).abs() > 0.01; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    var current = await windowManager.getBounds();
    var want = _toLogical(bounds);
    if ((current.left - want.left).abs() > 1 ||
        (current.top - want.top).abs() > 1 ||
        (current.width - want.width).abs() > 1 ||
        (current.height - want.height).abs() > 1) {
      await windowManager.setBounds(want);
    }
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
    unawaited(l.ping().then((ok) {
      if (ok) {
        unawaited(l.watch(onClose: _closeSelf));
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

  static Future<void> _closeSelf() async {
    Log.i("主窗口要求关闭");
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

  static WindowHost get host => _host ??= WindowHost(AppWindowChangeSink());

  /// 在新窗口里打开这个直播间
  static Future<bool> openRoom(Site site, String roomId) async {
    if (!canOpen) {
      return false;
    }
    return host.open(site.id, roomId);
  }

  /// 关掉全部副窗口：先请它们自己退出，3 秒后还没退的强制结束。返回关了几个
  static Future<int> closeAll() async {
    var host = _host;
    if (host == null) {
      return 0;
    }
    return host.closeAll();
  }
}

class _Secondary {
  _Secondary(this.slot, this.token, this.process, this.dir);
  final int slot;
  final String token;
  final Process process;
  final Directory dir;
  bool exited = false;
}

/// 主窗口这边：开副窗口、记着它们、关掉它们
class WindowHost {
  WindowHost(WindowChangeSink sink) : server = WindowServer(sink);

  final WindowServer server;
  final Map<int, _Secondary> _windows = {};
  bool _opening = false;

  Future<bool> open(String siteId, String roomId) async {
    if (_opening) {
      return false;
    }
    _opening = true;
    try {
      return await _open(siteId, roomId);
    } catch (e, stackTrace) {
      Log.e("打开多开窗口失败：$e", stackTrace);
      SmartDialog.showToast("新窗口打开失败：{error}".tf({"error": e}));
      return false;
    } finally {
      _opening = false;
    }
  }

  Future<bool> _open(String siteId, String roomId) async {
    if (_windows.length >= SecondaryLaunch.maxWindows) {
      SmartDialog.showToast(
          "多开窗口最多 {count} 个".tf({"count": SecondaryLaunch.maxWindows}));
      return false;
    }
    // 摆放：主窗口所在的屏幕
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
      // 屏幕信息是按缩放四舍五入过的逻辑像素，换回物理像素时往里收一点，免得超出
      var edge = scale.ceilToDouble();
      screens.add(ScreenArea(
        Rect.fromLTWH(pos.dx * scale + edge, pos.dy * scale + edge,
            size.width * scale - edge * 2, size.height * scale - edge * 2),
        scale,
      ));
    }
    var screen = WindowLayout.screenOf(screens, mainPhysical);
    Rect? bounds;
    var scale = dpr;
    int? index;
    var used = _windows.keys.map((e) => e - 1).toSet();
    if (screen != null) {
      var slots = WindowLayout.slots(screen);
      index = WindowLayout.pickSlot(slots, used, mainPhysical);
      if (index == null) {
        SmartDialog.showToast("多开窗口最多 {count} 个".tf({"count": slots.length}));
        return false;
      }
      bounds = slots[index];
      scale = screen.scale;
    } else {
      for (var i = 0; i < SecondaryLaunch.maxWindows; i++) {
        if (!used.contains(i)) {
          index = i;
          break;
        }
      }
    }
    var slot = (index ?? 0) + 1;

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
    var args = SecondaryLaunch(
      port: server.port,
      token: token,
      dataDir: dir.path,
      slot: slot,
      siteId: siteId,
      roomId: roomId,
      bounds: bounds,
      scale: scale,
      mainPid: pid,
    ).toArgs();
    Process process;
    try {
      process = await Process.start(Platform.resolvedExecutable, args);
    } catch (e) {
      server.removePeer(token);
      await _deleteLater(dir);
      rethrow;
    }
    // 副窗口没有控制台，输出不读会堵住
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    var window = _Secondary(slot, token, process, dir);
    _windows[slot] = window;
    _changed();
    unawaited(process.exitCode.then((_) => _onExit(window)));
    SmartDialog.showToast("已在新窗口打开".t);
    return true;
  }

  void _onExit(_Secondary window) {
    window.exited = true;
    if (identical(_windows[window.slot], window)) {
      _windows.remove(window.slot);
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

  Future<void> _closeOnExit() async {
    await closeAll();
  }

  Future<int> closeAll({Duration grace = const Duration(seconds: 3)}) async {
    var list = _windows.values.toList();
    if (list.isEmpty) {
      return 0;
    }
    for (var w in list) {
      server.requestClose(w.token);
    }
    await Future.wait([for (var w in list) w.process.exitCode])
        .timeout(grace, onTimeout: () => <int>[]);
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
