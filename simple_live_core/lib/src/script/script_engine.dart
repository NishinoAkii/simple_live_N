// 直播源脚本的 QuickJS 引擎
//
// 直接用 dart_quickjs 生成的 FFI 绑定（同一个原生库），没有用它的 JsRuntime，原因：
// 1. JsRuntime 的栈上限按创建时所在线程的栈顶计算。isolate 每次从事件循环醒来都可能
//    换到另一个线程，之后的调用大多报“Maximum call stack size exceeded”（实测 3 个
//    isolate 各 300 次调用失败约 80%）。这里每次进入引擎前调用 JS_UpdateStackTop。
// 2. JsRuntime 把 Dart 字符串的 UTF-16 长度当作 UTF-8 字节数传给 JS_Eval /
//    JS_NewStringLen，含中文的脚本和字符串会被截断。
// 3. 装上中断回调（JS_SetInterruptHandler），同步死循环到期后被打断，
//    抛出不可捕获的 InternalError: interrupted，引擎仍可继续使用。
//
// ignore_for_file: implementation_imports, non_constant_identifier_names

import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:dart_quickjs/src/quickjs_bindings.g.dart';
import 'package:ffi/ffi.dart';
import 'package:simple_live_core/src/common/core_text.dart';

const String _kAsset = 'package:dart_quickjs/src/quickjs_bindings.g.dart';

typedef _InterruptNative =
    ffi.Int32 Function(ffi.Pointer<JSRuntime>, ffi.Pointer<ffi.Void>);

@ffi.Native<ffi.Void Function(ffi.Pointer<JSRuntime>)>(
  symbol: 'JS_UpdateStackTop',
  assetId: _kAsset,
)
external void _jsUpdateStackTop(ffi.Pointer<JSRuntime> rt);

@ffi.Native<
  ffi.Void Function(
    ffi.Pointer<JSRuntime>,
    ffi.Pointer<ffi.NativeFunction<_InterruptNative>>,
    ffi.Pointer<ffi.Void>,
  )
>(symbol: 'JS_SetInterruptHandler', assetId: _kAsset)
external void _jsSetInterruptHandler(
  ffi.Pointer<JSRuntime> rt,
  ffi.Pointer<ffi.NativeFunction<_InterruptNative>> cb,
  ffi.Pointer<ffi.Void> opaque,
);

/// 脚本执行出错（语法错误、抛出异常、被中断）
class ScriptEngineException implements Exception {
  final String message;
  final String? stack;

  /// 同步执行超过期限被中断
  final bool interrupted;

  ScriptEngineException(this.message, {this.stack, this.interrupted = false});

  @override
  String toString() => message;
}

// 中断回调读的是 isolate 内的静态变量：同一 isolate 里同一时刻只有一个引擎在执行
final Stopwatch _clock = Stopwatch()..start();
int _deadline = 0;
bool _interruptFired = false;

int _onInterrupt(ffi.Pointer<JSRuntime> rt, ffi.Pointer<ffi.Void> opaque) {
  if (_deadline != 0 && _clock.elapsedMilliseconds > _deadline) {
    _interruptFired = true;
    return 1;
  }
  return 0;
}

final ffi.Pointer<ffi.NativeFunction<_InterruptNative>> _interruptPointer =
    ffi.Pointer.fromFunction<_InterruptNative>(_onInterrupt, 0);

/// 一个 QuickJS 运行时 + 上下文，只在创建它的 isolate 里同步使用
class ScriptEngine {
  late final ffi.Pointer<JSRuntime> _rt;
  late final ffi.Pointer<JSContext> _ctx;
  final Map<String, JSValue> _functions = {};
  bool _disposed = false;

  /// 单次同步执行（一次 eval / call / 一轮 Promise 任务）的期限
  Duration sliceTimeout;

  ScriptEngine({
    int memoryLimit = 64 * 1024 * 1024,
    int? stackSize,
    this.sliceTimeout = const Duration(seconds: 10),
  }) {
    _rt = JS_NewRuntime();
    if (_rt == ffi.nullptr) {
      throw ScriptEngineException('创建 JS 引擎失败'.t);
    }
    JS_SetMemoryLimit(_rt, memoryLimit);
    // Dart 的工作线程栈为 1 MB（32 位为 512 KB），JS 的上限要留出 Dart 自己用的部分
    JS_SetMaxStackSize(
      _rt,
      stackSize ?? (ffi.sizeOf<ffi.IntPtr>() == 8 ? 512 : 192) * 1024,
    );
    _ctx = JS_NewContext(_rt);
    if (_ctx == ffi.nullptr) {
      JS_FreeRuntime(_rt);
      throw ScriptEngineException('创建 JS 上下文失败'.t);
    }
    _jsSetInterruptHandler(_rt, _interruptPointer, ffi.nullptr);
  }

  bool get isDisposed => _disposed;

  /// 执行一段全局代码，返回结果的字符串形式（undefined / null 为 null）
  String? eval(String code, {String filename = '<eval>', Duration? timeout}) {
    _checkDisposed();
    var bytes = utf8.encode(code);
    var input = calloc<ffi.Uint8>(bytes.length + 1);
    var name = filename.toNativeUtf8();
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      input[bytes.length] = 0;
      return _enter(timeout, () {
        var value = JS_Eval(_ctx, input.cast(), bytes.length, name, 0);
        return _takeString(value);
      });
    } finally {
      calloc.free(input);
      calloc.free(name);
    }
  }

  /// 调用全局函数，参数都是字符串，返回结果的字符串形式
  String? call(String function, List<String> args, {Duration? timeout}) {
    _checkDisposed();
    var fn = _function(function);
    var argv = calloc<JSValue>(args.isEmpty ? 1 : args.length);
    var created = 0;
    try {
      for (var i = 0; i < args.length; i++) {
        argv[i] = _newString(args[i]);
        created++;
      }
      var thisValue = ffi.Struct.create<JSValue>()
        ..tag = JsTag.undefined
        ..u = 0;
      return _enter(timeout, () {
        var value = JS_Call(_ctx, fn, thisValue, args.length, argv);
        return _takeString(value);
      });
    } finally {
      for (var i = 0; i < created; i++) {
        JS_FreeValue(_ctx, argv[i]);
      }
      calloc.free(argv);
    }
  }

  /// 执行排队的 Promise 任务，直到没有或超过期限；返回任务里抛出的错误
  List<ScriptEngineException> runJobs({Duration? timeout}) {
    _checkDisposed();
    var errors = <ScriptEngineException>[];
    var pctx = calloc<ffi.Pointer<JSContext>>();
    try {
      _enter(timeout, () {
        while (JS_IsJobPending(_rt)) {
          if (_clock.elapsedMilliseconds > _deadline) {
            _interruptFired = true;
            errors.add(
              ScriptEngineException(_timeoutMessage, interrupted: true),
            );
            break;
          }
          var ret = JS_ExecutePendingJob(_rt, pctx);
          if (ret < 0) {
            errors.add(_takeException());
          }
        }
        return null;
      });
    } finally {
      calloc.free(pctx);
    }
    return errors;
  }

  bool get hasPendingJobs => !_disposed && JS_IsJobPending(_rt);

  void runGC() {
    _checkDisposed();
    JS_RunGC(_rt);
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (var value in _functions.values) {
      JS_FreeValue(_ctx, value);
    }
    _functions.clear();
    JS_FreeContext(_ctx);
    JS_FreeRuntime(_rt);
  }

  // ---------------------------------------------------------------------

  Duration _current = Duration.zero;

  String get _timeoutMessage =>
      '脚本执行超时（同步执行超过 {p} 秒，可能有死循环）'.tf({"p": _current.inMilliseconds / 1000});

  T _enter<T>(Duration? timeout, T Function() body) {
    _jsUpdateStackTop(_rt);
    var saved = _deadline;
    _current = timeout ?? sliceTimeout;
    _deadline = _clock.elapsedMilliseconds + _current.inMilliseconds;
    _interruptFired = false;
    try {
      return body();
    } finally {
      _deadline = saved;
    }
  }

  JSValue _function(String name) {
    var cached = _functions[name];
    if (cached != null) {
      return cached;
    }
    var global = JS_GetGlobalObject(_ctx);
    var namePtr = name.toNativeUtf8();
    try {
      var value = JS_GetPropertyStr(_ctx, global, namePtr);
      if (!JS_IsFunction(_ctx, value)) {
        if (value.tag < 0) {
          JS_FreeValue(_ctx, value);
        }
        throw ScriptEngineException('JS 里没有函数 {name}'.tf({"name": name}));
      }
      _functions[name] = value;
      return value;
    } finally {
      calloc.free(namePtr);
      JS_FreeValue(_ctx, global);
    }
  }

  JSValue _newString(String value) {
    var bytes = utf8.encode(value);
    var ptr = calloc<ffi.Uint8>(bytes.length + 1);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      ptr[bytes.length] = 0;
      var result = JS_NewStringLen(_ctx, ptr.cast(), bytes.length);
      if (result.tag == JsTag.exception) {
        throw _takeException();
      }
      return result;
    } finally {
      calloc.free(ptr);
    }
  }

  /// 读出值的字符串形式并释放它；异常转为 [ScriptEngineException]
  String? _takeString(JSValue value) {
    if (value.tag == JsTag.exception) {
      throw _takeException();
    }
    try {
      if (value.tag == JsTag.undefined || value.tag == JsTag.null_) {
        return null;
      }
      return _readString(value);
    } finally {
      if (value.tag < 0) {
        JS_FreeValue(_ctx, value);
      }
    }
  }

  String _readString(JSValue value) {
    var plen = calloc<ffi.Size>();
    try {
      var cstr = JS_ToCStringLen2(_ctx, plen, value, false);
      if (cstr == ffi.nullptr) {
        // ToString 本身抛了异常（如 Symbol）
        var e = JS_GetException(_ctx);
        if (e.tag < 0) {
          JS_FreeValue(_ctx, e);
        }
        return '';
      }
      try {
        return utf8.decode(
          cstr.cast<ffi.Uint8>().asTypedList(plen.value),
          allowMalformed: true,
        );
      } finally {
        JS_FreeCString(_ctx, cstr);
      }
    } finally {
      calloc.free(plen);
    }
  }

  ScriptEngineException _takeException() {
    var interrupted = _interruptFired;
    var exception = JS_GetException(_ctx);
    try {
      String message;
      String? stack;
      if (exception.tag == JsTag.object) {
        message = _property(exception, 'message') ?? _readString(exception);
        stack = _property(exception, 'stack');
        var name = _property(exception, 'name');
        if (name != null && name != 'Error' && !interrupted) {
          message = '$name: $message';
        }
      } else {
        message = _readString(exception);
      }
      if (interrupted) {
        message = _timeoutMessage;
      }
      return ScriptEngineException(
        message,
        stack: stack,
        interrupted: interrupted,
      );
    } finally {
      if (exception.tag < 0) {
        JS_FreeValue(_ctx, exception);
      }
    }
  }

  String? _property(JSValue object, String name) {
    var namePtr = name.toNativeUtf8();
    try {
      var value = JS_GetPropertyStr(_ctx, object, namePtr);
      try {
        if (value.tag == JsTag.undefined ||
            value.tag == JsTag.null_ ||
            value.tag == JsTag.exception) {
          return null;
        }
        return _readString(value);
      } finally {
        if (value.tag < 0) {
          JS_FreeValue(_ctx, value);
        }
      }
    } finally {
      calloc.free(namePtr);
    }
  }

  void _checkDisposed() {
    if (_disposed) {
      throw ScriptEngineException('JS 引擎已关闭'.t);
    }
  }
}
