import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';

/// 窗口组成 Windows 11 的贴靠分组时，Alt+Tab 里留下哪些
enum SwitcherMode {
  /// 和系统一样：分组、每个窗口都有
  all,

  /// 分组和主窗口
  main,

  /// 只有分组
  group;

  static SwitcherMode parse(String? text) => values.firstWhere(
        (e) => e.name == text,
        orElse: () => SwitcherMode.all,
      );
}

/// 一个窗口现在的样子
class SwitcherWindow {
  /// 窗口句柄
  final int id;

  /// 是主窗口
  final bool main;

  /// 用系统的贴靠排好了
  final bool snapped;

  /// 最小化了、在别的虚拟桌面上
  final bool away;
  final bool topmost;
  final int monitor;

  /// 看得见的框（物理像素）
  final Rect frame;

  const SwitcherWindow({
    required this.id,
    this.main = false,
    this.snapped = false,
    this.away = false,
    this.topmost = false,
    this.monitor = 0,
    this.frame = Rect.zero,
  });
}

/// 哪些窗口在同一个贴靠分组里。系统没有接口能问，按分组的规则推：同一块屏幕上贴靠着、
/// 互不重叠、没有置顶的两个以上的窗口
class SnapGroups {
  SnapGroups._();

  /// 相邻的两个窗口的边可能差这么几个像素
  static const double tolerance = 4;

  /// [windows] 里前面的在上面；[previous] 是之前算出来的：在组里时最小化的（分组还在）照旧算
  static Set<int> of(List<SwitcherWindow> windows, Set<int> previous) {
    var monitors = <int, List<SwitcherWindow>>{};
    for (var window in windows) {
      var list = monitors[window.monitor] ??= [];
      if (window.away) {
        if (previous.contains(window.id)) {
          list.add(window);
        }
      } else if (window.snapped &&
          !window.topmost &&
          list.every((e) => e.away || !_overlaps(e.frame, window.frame))) {
        list.add(window);
      }
    }
    return {
      for (var list in monitors.values)
        if (list.length >= 2)
          for (var window in list) window.id,
    };
  }

  static bool _overlaps(Rect a, Rect b) {
    var both = a.intersect(b);
    return both.width > tolerance && both.height > tolerance;
  }
}

/// 向系统读窗口、改窗口的属性。测试里换成假的
abstract class SwitcherSystem {
  /// Alt+Tab 里有贴靠分组（Windows 11，没有关掉）
  bool get grouping;

  /// Alt+Tab 正开着
  bool get switcherOpen;

  /// 这些进程的窗口，上面的在前；[main] 是主窗口的进程
  List<SwitcherWindow> read(int main, Set<int> pids);

  /// 在 Alt+Tab 里隐藏，失败时返回 false
  bool hide(int id);

  /// 隐藏已经生效：去掉只用来生效的那个属性
  void settle(int id);

  /// 恢复显示
  void show(int id);
}

/// 主窗口：窗口组成贴靠分组时，按设置在 Alt+Tab 里隐藏单个的窗口，只留分组。
/// 分组散了、关掉这一项、退出时恢复显示
class SnapGroupHider {
  SnapGroupHider({
    required this.pids,
    SwitcherSystem? system,
    this.main,
    this.every = const Duration(seconds: 1),
  }) : _system = system;

  /// 开着的多开窗口的进程
  final Iterable<int> Function() pids;

  /// 主窗口的进程，不给时是自己
  final int? main;

  /// 隔多久看一次
  final Duration every;
  SwitcherSystem? _system;

  Worker? _worker;
  Timer? _timer;
  Set<int> _group = {};

  /// 隐藏了的窗口；值为 true 的还没有生效（Alt+Tab 还没打开过）
  final Map<int, bool> _hidden = {};

  @visibleForTesting
  Set<int> get hidden => _hidden.keys.toSet();

  @visibleForTesting
  bool get running => _timer != null;

  void start() {
    _system ??= WindowsSwitcher.open();
    if (_system == null) {
      return;
    }
    _worker = ever<SwitcherMode>(MultiWindowPrefs.switcher, (_) => _arm());
    _arm();
  }

  void stop() {
    _worker?.dispose();
    _worker = null;
    _timer?.cancel();
    _timer = null;
    _showAll();
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (MultiWindowPrefs.switcher.value == SwitcherMode.all) {
      _showAll();
      return;
    }
    _timer = Timer.periodic(every, (_) => update());
    update();
  }

  void _showAll() {
    for (var id in _hidden.keys) {
      _system?.show(id);
    }
    _hidden.clear();
    _group = {};
  }

  /// 看一次：在组里的隐藏，不在了的恢复
  void update() {
    var system = _system;
    if (system == null) {
      return;
    }
    try {
      _update(system);
    } catch (e) {
      Log.logPrint(e);
    }
  }

  void _update(SwitcherSystem system) {
    var mode = MultiWindowPrefs.switcher.value;
    var others = pids().toSet();
    if (mode == SwitcherMode.all || others.isEmpty || !system.grouping) {
      _showAll();
      return;
    }
    if (system.switcherOpen) {
      // 打开时列表重新算过了，之前设的都生效了。正开着时不再改，下一次打开时生效
      for (var id in _hidden.keys.toList()) {
        if (_hidden[id]!) {
          system.settle(id);
          _hidden[id] = false;
        }
      }
      return;
    }
    var windows = system.read(main ?? pid, others);
    _group = SnapGroups.of(windows, _group);
    var want = {
      for (var window in windows)
        if (_group.contains(window.id) &&
            (mode == SwitcherMode.group || !window.main))
          window.id,
    };
    for (var id in _hidden.keys.toList()) {
      if (!want.contains(id)) {
        system.show(id);
        _hidden.remove(id);
      }
    }
    for (var id in want) {
      if (!_hidden.containsKey(id) && system.hide(id)) {
        _hidden[id] = true;
      }
    }
  }
}

typedef _IntPtrToInt = Int32 Function(IntPtr);
typedef _IntPtrToIntDart = int Function(int);
typedef _FindNative = IntPtr Function(
    IntPtr, IntPtr, Pointer<Uint16>, Pointer<Uint16>);
typedef _FindDart = int Function(int, int, Pointer<Uint16>, Pointer<Uint16>);
typedef _ThreadPidNative = Uint32 Function(IntPtr, Pointer<Uint32>);
typedef _ThreadPidDart = int Function(int, Pointer<Uint32>);
typedef _DwmNative = Int32 Function(IntPtr, Uint32, Pointer<Int32>, Uint32);
typedef _DwmDart = int Function(int, int, Pointer<Int32>, int);
typedef _MonitorNative = IntPtr Function(IntPtr, Uint32);
typedef _MonitorDart = int Function(int, int);
typedef _LongNative = Int32 Function(IntPtr, Int32);
typedef _LongDart = int Function(int, int);
typedef _SetPropNative = Int32 Function(IntPtr, IntPtr, IntPtr);
typedef _SetPropDart = int Function(int, int, int);
typedef _RemovePropNative = IntPtr Function(IntPtr, IntPtr);
typedef _RemovePropDart = int Function(int, int);
typedef _ForegroundNative = IntPtr Function();
typedef _ForegroundDart = int Function();
typedef _ClassNameNative = Int32 Function(IntPtr, Pointer<Uint16>, Int32);
typedef _ClassNameDart = int Function(int, Pointer<Uint16>, int);
typedef _RegNative = Int32 Function(IntPtr, Pointer<Uint16>, Pointer<Uint16>,
    Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _RegDart = int Function(int, Pointer<Uint16>, Pointer<Uint16>, int,
    Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _AllocNative = Pointer<Uint8> Function(Uint32, IntPtr);
typedef _AllocDart = Pointer<Uint8> Function(int, int);

/// Windows 11 的 Alt+Tab。系统没有公开的接口，用的是它自己给标签页用的两个窗口属性
/// （在 26100、26300 上实测，系统更新后可能失效，失效时只是不隐藏）：
/// - 0xA921：加进 Alt+Tab 的列表时，有它的不加。贴靠分组、任务栏不看它；
/// - 0xA920：打开 Alt+Tab 时，有它的从列表里拿出来重新加（列表平时不重新算）。
///   它的值是一个窗口的句柄，这里是自己；生效以后去掉
class WindowsSwitcher implements SwitcherSystem {
  WindowsSwitcher._(DynamicLibrary user32, DynamicLibrary dwm,
      DynamicLibrary advapi32, this._memory)
      : _isIconic =
            user32.lookupFunction<_IntPtrToInt, _IntPtrToIntDart>("IsIconic"),
        _isArranged = user32
            .lookupFunction<_IntPtrToInt, _IntPtrToIntDart>("IsWindowArranged"),
        _find = user32.lookupFunction<_FindNative, _FindDart>("FindWindowExW"),
        _threadPid = user32.lookupFunction<_ThreadPidNative, _ThreadPidDart>(
            "GetWindowThreadProcessId"),
        _monitor = user32
            .lookupFunction<_MonitorNative, _MonitorDart>("MonitorFromWindow"),
        _long = user32.lookupFunction<_LongNative, _LongDart>("GetWindowLongW"),
        _setProp =
            user32.lookupFunction<_SetPropNative, _SetPropDart>("SetPropW"),
        _removeProp = user32
            .lookupFunction<_RemovePropNative, _RemovePropDart>("RemovePropW"),
        _foreground = user32.lookupFunction<_ForegroundNative, _ForegroundDart>(
            "GetForegroundWindow"),
        _className = user32
            .lookupFunction<_ClassNameNative, _ClassNameDart>("GetClassNameW"),
        _dwm =
            dwm.lookupFunction<_DwmNative, _DwmDart>("DwmGetWindowAttribute"),
        _reg = advapi32.lookupFunction<_RegNative, _RegDart>("RegGetValueW") {
    _write(_runner, "FLUTTER_RUNNER_WIN32_WINDOW");
    _write(
        _key, r"Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced");
    _write(_value, "EnableTaskGroups");
  }

  final _IntPtrToIntDart _isIconic;
  final _IntPtrToIntDart _isArranged;
  final _FindDart _find;
  final _ThreadPidDart _threadPid;
  final _MonitorDart _monitor;
  final _LongDart _long;
  final _SetPropDart _setProp;
  final _RemovePropDart _removeProp;
  final _ForegroundDart _foreground;
  final _ClassNameDart _className;
  final _DwmDart _dwm;
  final _RegDart _reg;

  /// 整个进程只分配一次，不释放
  final Pointer<Uint8> _memory;
  static const int _memorySize = 1024;
  Pointer<Uint16> get _runner => _memory.cast();
  Pointer<Uint16> get _key => Pointer.fromAddress(_memory.address + 128);
  Pointer<Uint16> get _value => Pointer.fromAddress(_memory.address + 320);
  Pointer<Uint16> get _text => Pointer.fromAddress(_memory.address + 384);
  Pointer<Uint32> get _out => Pointer.fromAddress(_memory.address + 896);
  Pointer<Uint32> get _size => Pointer.fromAddress(_memory.address + 912);
  Pointer<Int32> get _rect => Pointer.fromAddress(_memory.address + 928);

  static const int hideProp = 0xA921;
  static const int againProp = 0xA920;
  static const _gwlExStyle = -20;
  static const _wsExTopmost = 0x8;
  static const _monitorNearest = 2;
  static const _dwmFrame = 9;
  static const _dwmCloaked = 14;
  static const _currentUser = -2147483647;
  static const _regDword = 0x10;

  static void _write(Pointer<Uint16> to, String text) {
    for (var i = 0; i < text.length; i++) {
      to[i] = text.codeUnitAt(i);
    }
    to[text.length] = 0;
  }

  static WindowsSwitcher? _instance;

  /// Windows 11（有贴靠分组）；别的系统没有
  static bool get supported =>
      Platform.isWindows && buildOf(Platform.operatingSystemVersion) >= 22000;

  /// “"Windows 11 Pro" 10.0 (Build 26300)”里的 26300，认不出来时为 0
  static int buildOf(String version) =>
      int.tryParse(
        RegExp(r"Build (\d+)").firstMatch(version)?.group(1) ?? "",
      ) ??
      0;

  static WindowsSwitcher? open() {
    if (!supported) {
      return null;
    }
    try {
      return _instance ??= create();
    } catch (e) {
      Log.logPrint(e);
      return null;
    }
  }

  @visibleForTesting
  static WindowsSwitcher? create() {
    var memory = DynamicLibrary.open("kernel32.dll")
        .lookupFunction<_AllocNative, _AllocDart>("LocalAlloc")
        .call(0x40, _memorySize);
    if (memory.address == 0) {
      return null;
    }
    return WindowsSwitcher._(
      DynamicLibrary.open("user32.dll"),
      DynamicLibrary.open("dwmapi.dll"),
      DynamicLibrary.open("advapi32.dll"),
      memory,
    );
  }

  /// 系统设置里的“按 Alt+Tab 时显示贴靠的窗口”：没改过、不是 0 时开着
  @override
  bool get grouping {
    _size.value = 4;
    var error =
        _reg(_currentUser, _key, _value, _regDword, nullptr, _out, _size);
    return error != 0 || _out.value != 0;
  }

  @override
  bool get switcherOpen {
    var length = _className(_foreground(), _text, 200);
    return String.fromCharCodes([for (var i = 0; i < length; i++) _text[i]]) ==
        "XamlExplorerHostIslandWindow";
  }

  @override
  List<SwitcherWindow> read(int main, Set<int> pids) {
    var found = <SwitcherWindow>[];
    var handle = 0;
    for (var i = 0; i < 256; i++) {
      handle = _find(0, handle, _runner, nullptr);
      if (handle == 0) {
        break;
      }
      _threadPid(handle, _out);
      var owner = _out.value;
      if (owner == main || pids.contains(owner)) {
        found.add(windowOf(handle, main: owner == main));
      }
    }
    return found;
  }

  @visibleForTesting
  SwitcherWindow windowOf(int handle, {bool main = false}) {
    var cloaked = _dwm(handle, _dwmCloaked, _rect, 4) == 0 && _rect[0] != 0;
    var frame = Rect.zero;
    if (_dwm(handle, _dwmFrame, _rect, 16) == 0) {
      frame = Rect.fromLTRB(_rect[0].toDouble(), _rect[1].toDouble(),
          _rect[2].toDouble(), _rect[3].toDouble());
    }
    return SwitcherWindow(
      id: handle,
      main: main,
      snapped: _isArranged(handle) != 0,
      away: cloaked || _isIconic(handle) != 0,
      topmost: _long(handle, _gwlExStyle) & _wsExTopmost != 0,
      monitor: _monitor(handle, _monitorNearest),
      frame: frame,
    );
  }

  @override
  bool hide(int id) {
    if (_setProp(id, hideProp, 1) == 0) {
      return false;
    }
    if (_setProp(id, againProp, id) == 0) {
      _removeProp(id, hideProp);
      return false;
    }
    return true;
  }

  @override
  void settle(int id) => _removeProp(id, againProp);

  @override
  void show(int id) {
    _removeProp(id, againProp);
    _removeProp(id, hideProp);
  }
}
