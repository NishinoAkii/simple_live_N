import 'dart:ffi';
import 'dart:io';
import 'dart:ui' show Rect;

/// Windows 10/11 的窗口左、右、下有一圈看不见的拖动边框（100% 时 7 像素，150% 时 11 像素），
/// 上面没有。GetWindowRect（window_manager 的 getBounds/setBounds）是连着这圈边框的外框，
/// 看得见的部分是 DWM 的 EXTENDED_FRAME_BOUNDS。用 Windows 的贴靠（Snap）贴到屏幕边上、
/// 角上时，是看得见的部分贴着可用区域的边，外框伸出去一圈。
///
/// 所以多开窗口记位置时记看得见的部分，判断在不在屏幕里、往里挪也按它算；
/// 放回去时再按边框换回外框，看得见的边就又贴着屏幕边了
class FrameInsets {
  final double left;
  final double top;
  final double right;
  final double bottom;
  const FrameInsets(this.left, this.top, this.right, this.bottom);

  static const zero = FrameInsets(0, 0, 0, 0);

  /// 量不到时按 Windows 10/11 的样子估：左右下 7 像素（按缩放），上面没有
  factory FrameInsets.estimate(double scale) {
    var border = (7 * scale).roundToDouble();
    return FrameInsets(border, 0, border, border);
  }

  /// 外框和看得见的框差多少
  factory FrameInsets.between(Rect outer, Rect visible) => FrameInsets(
        visible.left - outer.left,
        visible.top - outer.top,
        outer.right - visible.right,
        outer.bottom - visible.bottom,
      );

  /// 量出来的不像边框（比如最小化时）：不用
  bool get isSane => [left, top, right, bottom].every((e) => e >= 0 && e <= 64);

  Rect outerOf(Rect visible) => Rect.fromLTRB(visible.left - left,
      visible.top - top, visible.right + right, visible.bottom + bottom);

  Rect visibleOf(Rect outer) => Rect.fromLTRB(outer.left + left,
      outer.top + top, outer.right - right, outer.bottom - bottom);

  @override
  bool operator ==(Object other) =>
      other is FrameInsets &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => "FrameInsets($left, $top, $right, $bottom)";
}

typedef _FindWindowExNative = IntPtr Function(
    IntPtr, IntPtr, Pointer<Uint16>, Pointer<Uint16>);
typedef _FindWindowExDart = int Function(
    int, int, Pointer<Uint16>, Pointer<Uint16>);
typedef _ThreadPidNative = Uint32 Function(IntPtr, Pointer<Uint32>);
typedef _ThreadPidDart = int Function(int, Pointer<Uint32>);
typedef _GetRectNative = Int32 Function(IntPtr, Pointer<Int32>);
typedef _GetRectDart = int Function(int, Pointer<Int32>);
typedef _DwmAttrNative = Int32 Function(IntPtr, Uint32, Pointer<Int32>, Uint32);
typedef _DwmAttrDart = int Function(int, int, Pointer<Int32>, int);
typedef _LocalAllocNative = Pointer<Uint8> Function(Uint32, IntPtr);
typedef _LocalAllocDart = Pointer<Uint8> Function(int, int);

/// 这个进程自己的窗口（Flutter 的 runner 窗口）现在的外框和看得见的框（物理像素）。
/// 只在 Windows 上有，别的系统、读不到时 [read] 返回 null
class WindowFrame {
  WindowFrame._();
  static final WindowFrame instance = WindowFrame._();

  static const _className = "FLUTTER_RUNNER_WIN32_WINDOW";

  bool _ready = false;
  bool _failed = false;
  int _hwnd = 0;
  late _FindWindowExDart _findWindowEx;
  late _ThreadPidDart _threadPid;
  late _GetRectDart _getWindowRect;
  _DwmAttrDart? _dwmAttr;
  late Pointer<Uint16> _name;
  late Pointer<Uint32> _pidOut;
  late Pointer<Int32> _rect;
  late Pointer<Int32> _frame;

  bool _init() {
    if (_ready) return true;
    if (_failed || !Platform.isWindows) return false;
    try {
      var user32 = DynamicLibrary.open("user32.dll");
      var kernel32 = DynamicLibrary.open("kernel32.dll");
      _findWindowEx =
          user32.lookupFunction<_FindWindowExNative, _FindWindowExDart>(
              "FindWindowExW");
      _threadPid = user32.lookupFunction<_ThreadPidNative, _ThreadPidDart>(
          "GetWindowThreadProcessId");
      _getWindowRect =
          user32.lookupFunction<_GetRectNative, _GetRectDart>("GetWindowRect");
      try {
        _dwmAttr = DynamicLibrary.open("dwmapi.dll")
            .lookupFunction<_DwmAttrNative, _DwmAttrDart>(
                "DwmGetWindowAttribute");
      } catch (_) {
        _dwmAttr = null;
      }
      var alloc = kernel32
          .lookupFunction<_LocalAllocNative, _LocalAllocDart>("LocalAlloc");
      // LPTR（清零的固定内存）。整个进程只分配这一次，不释放
      var memory = alloc(0x40, 256);
      if (memory.address == 0) {
        _failed = true;
        return false;
      }
      _name = memory.cast<Uint16>();
      for (var i = 0; i < _className.length; i++) {
        _name[i] = _className.codeUnitAt(i);
      }
      _name[_className.length] = 0;
      _pidOut = Pointer<Uint32>.fromAddress(memory.address + 128);
      _rect = Pointer<Int32>.fromAddress(memory.address + 160);
      _frame = Pointer<Int32>.fromAddress(memory.address + 192);
      _ready = true;
      return true;
    } catch (_) {
      _failed = true;
      return false;
    }
  }

  int _findOwnWindow() {
    var handle = 0;
    for (var i = 0; i < 256; i++) {
      handle = _findWindowEx(0, handle, _name, nullptr);
      if (handle == 0) return 0;
      _threadPid(handle, _pidOut);
      if (_pidOut.value == pid) return handle;
    }
    return 0;
  }

  /// (外框, 看得见的框)，物理像素。DWM 读不到时两个一样
  (Rect, Rect)? read() {
    if (!_init()) return null;
    if (_hwnd == 0) {
      _hwnd = _findOwnWindow();
      if (_hwnd == 0) return null;
    }
    if (_getWindowRect(_hwnd, _rect) == 0) {
      _hwnd = 0;
      return null;
    }
    var outer = Rect.fromLTRB(_rect[0].toDouble(), _rect[1].toDouble(),
        _rect[2].toDouble(), _rect[3].toDouble());
    var visible = outer;
    // DWMWA_EXTENDED_FRAME_BOUNDS = 9
    var dwm = _dwmAttr;
    if (dwm != null && dwm(_hwnd, 9, _frame, 16) == 0) {
      visible = Rect.fromLTRB(_frame[0].toDouble(), _frame[1].toDouble(),
          _frame[2].toDouble(), _frame[3].toDouble());
    }
    return (outer, visible);
  }

  /// 这个窗口现在的边框；读不到、不像边框时按 [scale] 估
  FrameInsets insets(double scale) {
    var frame = read();
    if (frame != null) {
      var measured = FrameInsets.between(frame.$1, frame.$2);
      // 全是 0 多半是 DWM 没读到
      if (measured.isSane && measured != FrameInsets.zero) return measured;
    }
    return FrameInsets.estimate(scale);
  }
}
