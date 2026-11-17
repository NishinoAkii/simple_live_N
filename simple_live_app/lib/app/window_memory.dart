import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:get/get.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/window_geometry.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:window_manager/window_manager.dart';

/// 记住窗口：主窗口的大小、位置、是否最大化，直播间小窗的大小和位置。默认开。
///
/// 都只存在本机（见 SyncCompat.localOnlySettingKeys）。位置统一记成物理像素，
/// 连同当时屏幕的缩放，换到缩放不同的屏幕（100% 和 150%）时按逻辑大小换算；
/// 记下的位置已经不在任何屏幕上（比如拔了副屏）时放到屏幕正中间
class WindowMemory with WindowListener {
  static WindowMemory instance = WindowMemory();

  /// 开关（默认开）
  static const String kEnabled = "WindowMemory";
  static const String kMain = "WindowMainPlacement";
  static const String kSmall = "WindowSmallPlacement";
  static const List<String> storageKeys = [kEnabled, kMain, kSmall];

  static bool get supported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  final enabled = true.obs;

  /// main.dart 里 window_manager 准备好了（waitUntilReadyToShow）
  Future<void>? ready;

  /// 直播间的小窗开着：这时窗口的位置记成小窗的
  bool _small = false;
  Timer? _saveTimer;
  bool _listening = false;

  static LocalStorageService? get _storage =>
      Get.isRegistered<LocalStorageService>()
          ? LocalStorageService.instance
          : null;

  void load() {
    enabled.value = _storage?.getValue<bool>(kEnabled, true) ?? true;
  }

  void setEnabled(bool value) {
    enabled.value = value;
    _storage?.setValue<bool>(kEnabled, value);
    if (value) {
      _scheduleSave();
    }
  }

  WindowPlacement? _read(String key) =>
      WindowPlacement.decode(_storage?.getValue<String>(key, ""));

  /// Windows 上 window_manager 的坐标是物理像素除以窗口现在所在屏幕的缩放，
  /// 别的平台本来就是全局的逻辑坐标（按 1 算）
  static double get windowScale => Platform.isWindows
      ? (PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1.0)
      : 1.0;

  static DisplayArea areaOf(Display display) {
    var scale =
        Platform.isWindows ? (display.scaleFactor?.toDouble() ?? 1.0) : 1.0;
    var position = display.visiblePosition ?? Offset.zero;
    var size = display.visibleSize ?? display.size;
    return DisplayArea(
      Rect.fromLTWH(position.dx * scale, position.dy * scale,
          size.width * scale, size.height * scale),
      scale,
    );
  }

  static Future<List<DisplayArea>> displays() async {
    var list = await screenRetriever.getAllDisplays();
    return [for (var d in list) areaOf(d)];
  }

  /// 窗口现在的位置（物理像素）
  static Future<Rect> bounds() async {
    var b = await windowManager.getBounds();
    var s = windowScale;
    return Rect.fromLTWH(b.left * s, b.top * s, b.width * s, b.height * s);
  }

  /// 把窗口放到 [rect]（物理像素）。挪到缩放不同的屏幕上时，Windows 会按新屏幕的缩放
  /// 把窗口再放大或缩小一次，所以等缩放换过来以后按新的缩放再设一次
  static Future<void> applyBounds(Rect rect, double targetScale) async {
    for (var i = 0; i < 3; i++) {
      var s = windowScale;
      await windowManager.setBounds(Rect.fromLTWH(
          rect.left / s, rect.top / s, rect.width / s, rect.height / s));
      if (!Platform.isWindows || (targetScale - s).abs() < 0.01) {
        return;
      }
      if (!await _scaleChanged(s)) {
        return;
      }
    }
  }

  static Future<bool> _scaleChanged(double from) async {
    for (var i = 0; i < 25; i++) {
      await Future.delayed(const Duration(milliseconds: 20));
      if ((windowScale - from).abs() >= 0.01) {
        return true;
      }
    }
    return false;
  }

  /// 启动时（读完设置以后、显示窗口之前）调用：放回上次的位置，再显示窗口
  Future<void> restoreOnStart() async {
    // 多开的副窗口由 MultiWindow 摆放，不用、也不改主窗口记下的位置
    if (!supported || MultiWindow.isSecondary) return;
    (Rect, double)? placed;
    try {
      await ready;
      load();
      var saved = enabled.value ? _read(kMain) : null;
      var list = saved == null ? const <DisplayArea>[] : await displays();
      if (saved == null || list.isEmpty) {
        await windowManager.center();
      } else {
        var current = await bounds();
        var fallback = WindowGeometry.displayOf(current, list) ?? list.first;
        var (rect, display) = WindowGeometry.restore(saved, list, fallback);
        await applyBounds(rect, display.scale);
        if (saved.maximized) {
          await windowManager.maximize();
        } else {
          placed = (rect, display.scale);
        }
      }
    } catch (e, stackTrace) {
      Log.e("恢复窗口位置失败：$e", stackTrace);
    }
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      Log.logPrint(e);
    }
    if (!_listening) {
      _listening = true;
      windowManager.addListener(this);
    }
    if (placed != null) {
      unawaited(_settle(placed.$1, placed.$2));
    }
  }

  /// 显示出来以后再对一次：窗口隐藏着挪到别的屏幕时，缩放可能还没换过来
  Future<void> _settle(Rect target, double scale) async {
    await Future.delayed(const Duration(milliseconds: 800));
    try {
      if (_small || await windowManager.isMaximized()) return;
      var now = await bounds();
      bool off(double a, double b) => (a - b).abs() > 2;
      if (off(now.left, target.left) ||
          off(now.top, target.top) ||
          off(now.width, target.width) ||
          off(now.height, target.height)) {
        await applyBounds(target, scale);
      }
    } catch (e) {
      Log.logPrint(e);
    }
  }

  @override
  void onWindowMoved() => _scheduleSave();
  @override
  void onWindowMove() => _scheduleSave();
  @override
  void onWindowResized() => _scheduleSave();
  @override
  void onWindowResize() => _scheduleSave();
  @override
  void onWindowMaximize() => _scheduleSave();
  @override
  void onWindowUnmaximize() => _scheduleSave();

  void _scheduleSave() {
    if (!enabled.value) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      unawaited(save());
    });
  }

  /// 记下现在的位置。全屏、最小化时不记；最大化时只记“最大化”，
  /// 还原后的大小用上次记的
  Future<void> save() async {
    var storage = _storage;
    if (storage == null || !enabled.value || MultiWindow.isSecondary) return;
    try {
      if (await windowManager.isFullScreen() ||
          await windowManager.isMinimized()) {
        return;
      }
      var rect = await bounds();
      var scale = windowScale;
      if (_small) {
        await storage.setValue<String>(
            kSmall, WindowPlacement(rect, scale).encode());
        return;
      }
      if (await windowManager.isMaximized()) {
        var old = _read(kMain) ?? WindowPlacement(rect, scale);
        await storage.setValue<String>(
            kMain, old.copyWith(maximized: true).encode());
        return;
      }
      await storage.setValue<String>(
          kMain, WindowPlacement(rect, scale).encode());
    } catch (e) {
      Log.logPrint(e);
    }
  }

  // ---------------- 直播间的小窗 ----------------

  /// 进入小窗前调用：记下主窗口，退出时用它放回去
  Future<WindowPlacement> enterSmall() async {
    _saveTimer?.cancel();
    var maximized = await windowManager.isMaximized();
    var main =
        WindowPlacement(await bounds(), windowScale, maximized: maximized);
    _small = true;
    if (maximized) {
      await windowManager.unmaximize();
    }
    return main;
  }

  /// 小窗的位置和大小。记过的用记过的（换到宽高比不同的视频时面积不变），
  /// 没记过时大小用 [defaultSize]（逻辑像素），位置不动
  Future<void> placeSmall(Size defaultSize, double aspectRatio) async {
    var saved = enabled.value ? _read(kSmall) : null;
    var list = saved == null ? const <DisplayArea>[] : await displays();
    if (saved == null || list.isEmpty) {
      await windowManager.setSize(defaultSize);
      return;
    }
    var logical =
        WindowGeometry.keepArea(saved.rect.size / saved.scale, aspectRatio);
    var resized = WindowPlacement(
        saved.rect.topLeft & logical * saved.scale, saved.scale);
    var fallback = WindowGeometry.displayOf(await bounds(), list) ?? list.first;
    var (rect, display) = WindowGeometry.restore(resized, list, fallback);
    await applyBounds(rect, display.scale);
  }

  /// 退出小窗：先记下小窗（标题栏改回来之前），之后用 [restoreMain] 放回主窗口
  Future<void> leaveSmall() async {
    _saveTimer?.cancel();
    if (_small && enabled.value) {
      await save();
    }
    _small = false;
  }

  Future<void> restoreMain(WindowPlacement? main) async {
    if (main == null) return;
    try {
      var list = await displays();
      var display = WindowGeometry.displayOf(main.rect, list);
      await applyBounds(main.rect, display?.scale ?? main.scale);
      if (main.maximized) {
        await windowManager.maximize();
      }
    } catch (e) {
      Log.logPrint(e);
    }
  }
}
