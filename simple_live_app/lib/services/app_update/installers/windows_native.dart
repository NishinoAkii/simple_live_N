import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:simple_live_app/app/log.dart';

final class _StartupInfo extends Struct {
  @Uint32()
  external int cb;
  external Pointer<Uint16> lpReserved;
  external Pointer<Uint16> lpDesktop;
  external Pointer<Uint16> lpTitle;
  @Uint32()
  external int dwX;
  @Uint32()
  external int dwY;
  @Uint32()
  external int dwXSize;
  @Uint32()
  external int dwYSize;
  @Uint32()
  external int dwXCountChars;
  @Uint32()
  external int dwYCountChars;
  @Uint32()
  external int dwFillAttribute;
  @Uint32()
  external int dwFlags;
  @Uint16()
  external int wShowWindow;
  @Uint16()
  external int cbReserved2;
  external Pointer<Uint8> lpReserved2;
  external Pointer<Void> hStdInput;
  external Pointer<Void> hStdOutput;
  external Pointer<Void> hStdError;
}

final class _ProcessInformation extends Struct {
  external Pointer<Void> hProcess;
  external Pointer<Void> hThread;
  @Uint32()
  external int dwProcessId;
  @Uint32()
  external int dwThreadId;
}

typedef _CreateProcessNative = Int32 Function(
  Pointer<Uint16>,
  Pointer<Uint16>,
  Pointer<Void>,
  Pointer<Void>,
  Int32,
  Uint32,
  Pointer<Void>,
  Pointer<Uint16>,
  Pointer<_StartupInfo>,
  Pointer<_ProcessInformation>,
);
typedef _CreateProcessDart = int Function(
  Pointer<Uint16>,
  Pointer<Uint16>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  int,
  Pointer<Void>,
  Pointer<Uint16>,
  Pointer<_StartupInfo>,
  Pointer<_ProcessInformation>,
);

/// 系统调用失败，[code] 是 GetLastError
class WindowsNativeError implements Exception {
  final String call;
  final int code;
  const WindowsNativeError(this.call, this.code);

  @override
  String toString() => "$call: $code";
}

/// 更新要用的几个 Windows 系统调用，只用 dart:ffi
class WindowsNative {
  WindowsNative._();

  static const int _createNoWindow = 0x08000000;
  static const int _createUnicodeEnvironment = 0x00000400;
  static const int _createBreakawayFromJob = 0x01000000;

  static final DynamicLibrary _kernel32 = DynamicLibrary.open("kernel32.dll");
  static final DynamicLibrary _user32 = DynamicLibrary.open("user32.dll");

  static final Pointer<Void> Function(int, int) _localAlloc = _kernel32
      .lookupFunction<Pointer<Void> Function(Uint32, IntPtr),
          Pointer<Void> Function(int, int)>("LocalAlloc");
  static final Pointer<Void> Function(Pointer<Void>) _localFree = _kernel32
      .lookupFunction<Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)>("LocalFree");
  static final _CreateProcessDart _createProcess = _kernel32
      .lookupFunction<_CreateProcessNative, _CreateProcessDart>(
          "CreateProcessW");
  static final int Function(Pointer<Void>) _closeHandle =
      _kernel32.lookupFunction<Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)>("CloseHandle");
  static final int Function() _getLastError =
      _kernel32.lookupFunction<Uint32 Function(), int Function()>(
    "GetLastError",
    isLeaf: true,
  );

  static Pointer<T> _alloc<T extends NativeType>(
    int bytes,
    List<Pointer<Void>> owned,
  ) {
    // LPTR：清零
    var memory = _localAlloc(0x40, bytes);
    owned.add(memory);
    return memory.cast<T>();
  }

  static Pointer<Uint16> _utf16(String text, List<Pointer<Void>> owned) {
    var units = text.codeUnits;
    var memory = _alloc<Uint16>((units.length + 1) * 2, owned);
    memory.asTypedList(units.length).setAll(0, units);
    return memory;
  }

  /// 一个参数写进命令行：照 CommandLineToArgvW 的规则加引号
  @visibleForTesting
  static String quote(String value) {
    if (value.isNotEmpty && !value.contains(RegExp(r'[\s"]'))) {
      return value;
    }
    var out = StringBuffer('"');
    var slashes = 0;
    for (var unit in value.codeUnits) {
      if (unit == 0x5C) {
        slashes++;
        continue;
      }
      // 引号前面的反斜杠要写两遍，引号自己前面再加一个
      out.write(r"\" * (unit == 0x22 ? slashes * 2 + 1 : slashes));
      slashes = 0;
      out.writeCharCode(unit);
    }
    out
      ..write(r"\" * (slashes * 2))
      ..write('"');
    return out.toString();
  }

  static String commandLine(String exe, List<String> args) =>
      [exe, ...args].map(quote).join(" ");

  /// 启动 [exe]：没有控制台窗口，不接它的输入输出，这个 App 退出后照常运行。返回进程编号，
  /// 启动不了时抛 [WindowsNativeError]。
  ///
  /// 不用 Process.start 的 detached：那样启动的进程没有控制台，Windows PowerShell 一启动就退出，
  /// 脚本一行都不跑（1.27.1 和以前的更新就停在这一步）；normal 会把输入输出接到这个 App 上，
  /// App 退出时断开
  static int startHidden(String exe, List<String> args, {String? directory}) {
    var owned = <Pointer<Void>>[];
    try {
      var startup = _alloc<_StartupInfo>(sizeOf<_StartupInfo>(), owned);
      startup.ref.cb = sizeOf<_StartupInfo>();
      var info = _alloc<_ProcessInformation>(
        sizeOf<_ProcessInformation>(),
        owned,
      );
      var program = _utf16(exe, owned);
      var folder = directory == null ? nullptr : _utf16(directory, owned);
      var code = 0;
      // 这个 App 在一个会跟着退出的任务组（Job）里时先试着脱离，不让脱离就照常启动
      for (var flags in const [_createBreakawayFromJob, 0]) {
        // CreateProcessW 会改命令行，每次给新的
        var line = _utf16(commandLine(exe, args), owned);
        var ok = _createProcess(
          program,
          line,
          nullptr,
          nullptr,
          0,
          _createNoWindow | _createUnicodeEnvironment | flags,
          nullptr,
          folder,
          startup,
          info,
        );
        if (ok != 0) {
          var pid = info.ref.dwProcessId;
          _closeHandle(info.ref.hThread);
          _closeHandle(info.ref.hProcess);
          return pid;
        }
        code = _getLastError();
      }
      throw WindowsNativeError("CreateProcess", code);
    } finally {
      for (var memory in owned) {
        _localFree(memory);
      }
    }
  }

  /// 让进程 [pid] 的窗口能到最前面（这个 App 正在最前面时有用）
  static void allowForeground(int pid) {
    try {
      _user32.lookupFunction<Int32 Function(Uint32), int Function(int)>(
        "AllowSetForegroundWindow",
      )(pid);
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 以 MSIX 安装时的包全名；压缩包解压出来的、系统太旧没有这个调用时为 null
  static String? packageFullName() {
    var owned = <Pointer<Void>>[];
    try {
      var call = _kernel32.lookupFunction<
          Int32 Function(Pointer<Uint32>, Pointer<Uint16>),
          int Function(Pointer<Uint32>, Pointer<Uint16>)>(
        "GetCurrentPackageFullName",
      );
      // PACKAGE_FULL_NAME_MAX_LENGTH 是 127
      const size = 256;
      var length = _alloc<Uint32>(4, owned)..value = size;
      var name = _alloc<Uint16>(size * 2, owned);
      if (call(length, name) != 0 || length.value <= 1) {
        return null;
      }
      return String.fromCharCodes(name.asTypedList(length.value - 1));
    } catch (_) {
      return null;
    } finally {
      for (var memory in owned) {
        _localFree(memory);
      }
    }
  }
}
