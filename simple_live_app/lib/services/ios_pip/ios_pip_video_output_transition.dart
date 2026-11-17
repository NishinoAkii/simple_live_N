// 切换渲染方式前后暂停/恢复 mpv 的视频轨道。
// Adapted from Kazumi (GPL-3.0), Predidit/Kazumi PR #2646.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/ios_pip/async_utils.dart';

/// 绑定一个播放器和它的纹理 ID，避免迟到的切换写到新的播放器上
class IosPipVideoOutputBinding {
  const IosPipVideoOutputBinding({
    required this.handle,
    required this.textureId,
    required this.isCurrent,
    required this.readVid,
    required this.writeVid,
  });

  final int handle;
  final ValueListenable<int?> textureId;
  final bool Function() isCurrent;
  final Future<String> Function() readVid;
  final Future<void> Function(String value) writeVid;
}

/// 原生层释放渲染上下文前，mpv 必须先停用视频输出（vid=no）；
/// 声音和播放器本身保持不变。
class IosPipVideoOutputTransition {
  IosPipVideoOutputTransition({
    required this.resolveBinding,
    this.registrationTimeout = const Duration(seconds: 3),
  });

  final Future<IosPipVideoOutputBinding?> Function(int handle) resolveBinding;
  final Duration registrationTimeout;
  final AsyncSingleFlight<bool> _suspension = AsyncSingleFlight();
  bool _disposed = false;
  _VideoOutputChange? _change;

  Future<bool> suspendVideo(int handle) async {
    if (_disposed || _suspension.isRunning || _change != null) return false;
    return _suspension.run(() => _suspend(handle));
  }

  Future<bool> _suspend(int handle) async {
    _VideoOutputChange? change;
    try {
      var binding = await resolveBinding(handle);
      if (_disposed ||
          binding == null ||
          binding.handle != handle ||
          !binding.isCurrent()) {
        return false;
      }
      var vid = await binding.readVid();
      if (_disposed || !binding.isCurrent() || vid.isEmpty) return false;
      change = _VideoOutputChange(binding, vid, binding.textureId.value);
      _change = change;
      var current = change;
      var activeVid = await current.operations.run(() async {
        if (_disposed || !binding.isCurrent()) return '';
        await binding.writeVid('no');
        return binding.isCurrent() ? await binding.readVid() : '';
      });
      if (_disposed || !binding.isCurrent() || activeVid != 'no') {
        await _restoreVid(current);
        _clear(current);
        return false;
      }
      return true;
    } catch (error) {
      Log.logPrint('iOS PiP: output suspension failed: $error');
      if (change != null) {
        await _restoreVid(change);
        _clear(change);
      }
      return false;
    }
  }

  Future<bool> resumeVideo(int handle, {bool waitForTexture = true}) async {
    var change = _change;
    if (_disposed || change == null || change.binding.handle != handle) {
      return false;
    }
    return change.resuming.run(() => _resume(change, waitForTexture));
  }

  Future<bool> _resume(_VideoOutputChange change, bool waitForTexture) async {
    var registered = false;
    var restored = false;
    try {
      // 只有原生输出确实更换时才需要等新纹理
      registered = !waitForTexture || await _waitForRegistration(change);
    } catch (error) {
      Log.logPrint('iOS PiP: texture registration failed: $error');
    } finally {
      // 超时或失败也要恢复视频轨道，否则关闭小窗后画面一直是黑的
      restored = await _restoreVid(change);
      _clear(change);
    }
    return registered && restored && !_disposed && change.binding.isCurrent();
  }

  Future<bool> _waitForRegistration(_VideoOutputChange change) async {
    var binding = change.binding;
    bool registered() =>
        binding.textureId.value != null &&
        binding.textureId.value != change.oldTextureId;
    if (_disposed || !binding.isCurrent()) return false;
    if (registered()) return true;

    var result = Completer<bool>();
    void complete(bool value) {
      if (!result.isCompleted) result.complete(value);
    }

    void listener() {
      if (_disposed || !binding.isCurrent()) {
        complete(false);
      } else if (registered()) {
        complete(true);
      }
    }

    var timer = Timer(registrationTimeout, () => complete(false));
    change.cancelWait = () => complete(false);
    binding.textureId.addListener(listener);
    try {
      listener();
      return await result.future;
    } finally {
      timer.cancel();
      binding.textureId.removeListener(listener);
      change.cancelWait = null;
    }
  }

  Future<bool> _restoreVid(_VideoOutputChange change) {
    return change.restoring ??= change.operations.run(() async {
      if (!change.binding.isCurrent()) return false;
      try {
        await change.binding.writeVid(change.vid);
        if (!change.binding.isCurrent()) return false;
        var actual = await change.binding.readVid();
        return change.binding.isCurrent() &&
            (actual == change.vid ||
                (change.vid == 'auto' && actual.isNotEmpty && actual != 'no'));
      } catch (error) {
        Log.logPrint('iOS PiP: video track restoration failed: $error');
        return false;
      }
    });
  }

  void _clear(_VideoOutputChange change) {
    if (identical(_change, change)) _change = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    var change = _change;
    if (change == null) return;
    change.cancelWait?.call();
    await _restoreVid(change);
    _clear(change);
  }
}

class _VideoOutputChange {
  _VideoOutputChange(this.binding, this.vid, this.oldTextureId);

  final IosPipVideoOutputBinding binding;
  final String vid;
  final int? oldTextureId;
  final AsyncSerialQueue operations = AsyncSerialQueue();
  final AsyncSingleFlight<bool> resuming = AsyncSingleFlight();
  Future<bool>? restoring;
  void Function()? cancelWait;
}
