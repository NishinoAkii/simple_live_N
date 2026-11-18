import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:simple_live_app/app/capture/capture_settings.dart';
import 'package:simple_live_app/app/log.dart';

/// 副窗口的进程。
///
/// Windows 上不让它当主窗口进程的子进程，而是由 runner 挂到桌面外壳（explorer）下面启动：
/// 系统按进程树录应用的声音，这样主窗口录屏时不会把副窗口的声音也录进去。
/// 只在画面录制打开时这样做（[CaptureFeatures.screenRecording]）；关着时和以前一样直接启动。
/// 其他平台照旧用 [Process.start]。
abstract class SecondaryProcess {
  /// 进程退出时完成
  Future<void> get exited;

  /// 强制结束
  void kill();

  static const _channel = MethodChannel("simple_live/capture");

  static Future<SecondaryProcess> start(
      String executable, List<String> arguments) async {
    if (Platform.isWindows && CaptureFeatures.screenRecording) {
      try {
        var result = await _channel.invokeMapMethod<String, dynamic>(
          "launchDetached",
          {"exe": executable, "args": arguments},
        );
        var pid = result?["pid"];
        if (pid is int && pid > 0) {
          if (result?["reparented"] != true) {
            Log.w("多开窗口：没能放到主窗口的进程树外（${result?["note"]}），"
                "主窗口录屏会带上它的声音");
          }
          return _DetachedProcess(pid);
        }
      } on MissingPluginException {
        // runner 里没有这个方法（比如测试）：照旧启动
      }
    }
    var process = await Process.start(executable, arguments);
    // 副窗口没有控制台，输出不读会堵住
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    return _ChildProcess(process);
  }
}

class _ChildProcess implements SecondaryProcess {
  _ChildProcess(this._process);

  final Process _process;

  @override
  Future<void> get exited => _process.exitCode;

  @override
  void kill() => _process.kill();
}

/// runner 启动的进程：退出由 runner 等着（waitPid），强制结束也交给它（killPid，
/// 只结束同一个 exe 的进程，pid 被别的进程重用时不会误杀）
class _DetachedProcess implements SecondaryProcess {
  _DetachedProcess(this.pid)
      : exited = SecondaryProcess._channel
            .invokeMethod<Object?>("waitPid", {"pid": pid})
            .then<void>((_) {}, onError: (Object e) => Log.logPrint(e));

  final int pid;

  @override
  final Future<void> exited;

  @override
  void kill() {
    unawaited(SecondaryProcess._channel
        .invokeMethod<bool>("killPid", {"pid": pid}).then((killed) {
      if (killed != true) {
        Log.w("多开窗口：进程 $pid 没能结束");
      }
    }, onError: (Object e) => Log.logPrint(e)));
  }
}
