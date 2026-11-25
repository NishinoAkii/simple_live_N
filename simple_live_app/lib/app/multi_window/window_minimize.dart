import 'dart:ffi';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/window_frame.dart';
import 'package:window_manager/window_manager.dart';

/// 这个进程自己的窗口怎么最小化、还原。测试里换成假的
abstract class WindowShow {
  bool get minimized;

  /// 用系统的贴靠排好了（还原要照系统的办法，回到贴靠的位置）
  bool get snapped;

  void minimize();

  /// 照系统的办法还原（和点任务栏一样，会拿到焦点）
  void restore();

  /// 回到最小化之前的大小、位置（最大化的还是最大化），不拿焦点
  void showNoActivate();

  /// 之后别的进程的窗口还原时可以拿到焦点（这个窗口在最前面时有效）
  void allowForeground();

  /// 最前面的窗口是哪个进程的，读不到时为 0
  int get foregroundPid;

  /// 把这个窗口放到最前面
  void focus();
}

typedef _IntPtrToInt = Int32 Function(IntPtr);
typedef _IntPtrToIntDart = int Function(int);
typedef _ShowWindowNative = Int32 Function(IntPtr, Int32);
typedef _ShowWindowDart = int Function(int, int);
typedef _PostMessageNative = Int32 Function(IntPtr, Uint32, IntPtr, IntPtr);
typedef _PostMessageDart = int Function(int, int, int, int);
typedef _AllowNative = Int32 Function(Uint32);
typedef _AllowDart = int Function(int);
typedef _ForegroundNative = IntPtr Function();
typedef _ForegroundDart = int Function();
typedef _ThreadPidNative = Uint32 Function(IntPtr, Pointer<Uint32>);
typedef _ThreadPidDart = int Function(int, Pointer<Uint32>);
typedef _LocalAllocNative = Pointer<Uint32> Function(Uint32, IntPtr);
typedef _LocalAllocDart = Pointer<Uint32> Function(int, int);

/// Windows 上自己的窗口。window_manager 的最小化在全屏时不做事，这里直接发系统命令
class Win32WindowShow implements WindowShow {
  Win32WindowShow._(this._hwnd, DynamicLibrary user32)
      : _isIconic =
            user32.lookupFunction<_IntPtrToInt, _IntPtrToIntDart>("IsIconic"),
        _isArranged = _arranged(user32),
        _showWindow = user32
            .lookupFunction<_ShowWindowNative, _ShowWindowDart>("ShowWindow"),
        _postMessage =
            user32.lookupFunction<_PostMessageNative, _PostMessageDart>(
                "PostMessageW"),
        _allow = user32.lookupFunction<_AllowNative, _AllowDart>(
            "AllowSetForegroundWindow"),
        _foreground = user32.lookupFunction<_ForegroundNative, _ForegroundDart>(
            "GetForegroundWindow"),
        _setForeground = user32.lookupFunction<_IntPtrToInt, _IntPtrToIntDart>(
            "SetForegroundWindow"),
        _threadPid = user32.lookupFunction<_ThreadPidNative, _ThreadPidDart>(
            "GetWindowThreadProcessId");

  final int _hwnd;
  final _IntPtrToIntDart _isIconic;
  final _IntPtrToIntDart? _isArranged;
  final _ShowWindowDart _showWindow;
  final _PostMessageDart _postMessage;
  final _AllowDart _allow;
  final _ForegroundDart _foreground;
  final _IntPtrToIntDart _setForeground;
  final _ThreadPidDart _threadPid;

  static const _wmSysCommand = 0x0112;
  static const _scMinimize = 0xF020;
  static const _scRestore = 0xF120;
  static const _swShowNoActivate = 4;
  static const _anyProcess = 0xFFFFFFFF;

  static Pointer<Uint32>? _pidOut;
  static Win32WindowShow? _instance;

  /// 这个进程的窗口；不是 Windows、找不到窗口时为 null
  static WindowShow? open() {
    if (!Platform.isWindows) {
      return null;
    }
    try {
      var hwnd = WindowFrame.instance.handle;
      if (hwnd == 0) {
        return null;
      }
      var opened = _instance;
      if (opened == null || opened._hwnd != hwnd) {
        opened = _instance = of(hwnd);
      }
      return opened;
    } catch (e) {
      Log.logPrint(e);
      return null;
    }
  }

  @visibleForTesting
  static Win32WindowShow of(int hwnd) {
    _pidOut ??= DynamicLibrary.open("kernel32.dll")
        .lookupFunction<_LocalAllocNative, _LocalAllocDart>("LocalAlloc")
        .call(0x40, 8);
    return Win32WindowShow._(hwnd, DynamicLibrary.open("user32.dll"));
  }

  /// Windows 10 早期版本没有
  static _IntPtrToIntDart? _arranged(DynamicLibrary user32) {
    try {
      return user32
          .lookupFunction<_IntPtrToInt, _IntPtrToIntDart>("IsWindowArranged");
    } catch (_) {
      return null;
    }
  }

  @override
  bool get minimized => _isIconic(_hwnd) != 0;

  @override
  bool get snapped => (_isArranged?.call(_hwnd) ?? 0) != 0;

  @override
  void minimize() => _postMessage(_hwnd, _wmSysCommand, _scMinimize, 0);

  @override
  void restore() => _postMessage(_hwnd, _wmSysCommand, _scRestore, 0);

  @override
  void showNoActivate() => _showWindow(_hwnd, _swShowNoActivate);

  @override
  void allowForeground() => _allow(_anyProcess);

  @override
  int get foregroundPid {
    var out = _pidOut;
    var window = _foreground();
    if (out == null || out.address == 0 || window == 0) {
      return 0;
    }
    out.value = 0;
    _threadPid(window, out);
    return out.value;
  }

  @override
  void focus() => _setForeground(_hwnd);
}

/// 主窗口：最小化了、又出来了时调用 [onChanged]。
///
/// 全屏时最小化没有 window_manager 的事件，另外看 App 的前后台变化；
/// 有变化时都再量一次，不只看事件
class MainMinimizeWatcher with WindowListener, WidgetsBindingObserver {
  MainMinimizeWatcher(this.onChanged, {bool? Function()? minimized})
      : _read = minimized ?? (() => Win32WindowShow.open()?.minimized);

  final void Function(bool minimized) onChanged;
  final bool? Function() _read;
  bool _minimized = false;

  void start() {
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    _minimized = _read() ?? false;
  }

  void stop() {
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
  }

  void check() {
    var now = _read();
    if (now == null || now == _minimized) {
      return;
    }
    _minimized = now;
    onChanged(now);
  }

  @override
  void onWindowMinimize() => check();
  @override
  void onWindowRestore() => check();

  /// 最小化之前是最大化的，还原时是这个
  @override
  void onWindowMaximize() => check();
  @override
  void onWindowFocus() => check();
  @override
  void onWindowBlur() => check();
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => check();
}

/// 副窗口：主窗口最小化时跟着最小化，主窗口出来时跟着还原。
/// 只还原跟着最小化的：自己最小化的、已经自己还原了的不动
class MinimizeFollower with WindowListener {
  MinimizeFollower({WindowShow? Function()? window})
      : _window = window ?? Win32WindowShow.open;

  final WindowShow? Function() _window;

  /// 现在的最小化是跟着主窗口的
  bool _following = false;

  /// 最小化之前贴靠着
  bool _snapped = false;

  void start() => windowManager.addListener(this);

  void follow(bool minimized) {
    var window = _window();
    if (window == null) {
      return;
    }
    if (minimized) {
      if (window.minimized) {
        return;
      }
      _snapped = window.snapped;
      _following = true;
      window.minimize();
      return;
    }
    if (!_following) {
      return;
    }
    _following = false;
    if (!window.minimized) {
      return;
    }
    // 贴靠的照系统的办法还原（会拿到焦点，见 WindowHost.mainMinimized）；别的不拿焦点
    if (_snapped) {
      window.restore();
    } else {
      window.showNoActivate();
    }
  }

  /// 自己还原了（点任务栏等）：之后主窗口出来不再动它
  void _seen() {
    if (_following && !(_window()?.minimized ?? true)) {
      _following = false;
    }
  }

  @override
  void onWindowRestore() => _seen();
  @override
  void onWindowMaximize() => _seen();
  @override
  void onWindowFocus() => _seen();
}
