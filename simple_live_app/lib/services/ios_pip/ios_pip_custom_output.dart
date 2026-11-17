// 画中画在后台时改用补丁版 libmpv 的 vo_simplelive：VideoToolbox 解码出的画面
// 不拷回内存、不软件渲染，直接交给原生端的小窗，后台 CPU 低很多（CPU 长时间偏高会被系统结束）。
// 什么时候切换由原生端（IosPictureInPictureController.swift）决定，这里只改 mpv 属性。
// 见 tools/libmpv/README.md
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/ios_pip/async_utils.dart';

/// 读写一个播放器的 mpv 属性；isCurrent 为 false 时（播放器已释放）不再读写
class IosPipPropertyBinding {
  const IosPipPropertyBinding({
    required this.handle,
    required this.isCurrent,
    required this.read,
    required this.write,
  });

  final int handle;
  final bool Function() isCurrent;
  final Future<String> Function(String name) read;
  final Future<void> Function(String name, String value) write;
}

class IosPipCustomOutput {
  IosPipCustomOutput({required this.resolveBinding});

  static const outputName = 'simplelive';

  final Future<IosPipPropertyBinding?> Function(int handle) resolveBinding;
  final AsyncSerialQueue _queue = AsyncSerialQueue();
  _SavedOutput? _saved;
  bool _disposed = false;

  /// 正在用 vo_simplelive
  bool get isActive => _saved != null;

  /// 切到 vo_simplelive；失败时换回原来的输出并返回 false
  Future<bool> enable(int handle) => _queue.run(() => _enable(handle));

  /// 换回原来的输出；没在用时直接返回 true
  Future<bool> disable(int handle) => _queue.run(() => _disable(handle));

  /// 页面关闭：播放器还在时换回原来的输出
  Future<void> dispose() {
    _disposed = true;
    return _queue.run(() async {
      var saved = _saved;
      if (saved != null) await _disable(saved.handle);
    });
  }

  Future<bool> _enable(int handle) async {
    var saved = _saved;
    if (saved != null) return saved.handle == handle;
    if (_disposed) return false;
    IosPipPropertyBinding? binding;
    _SavedOutput? original;
    var changed = false;
    try {
      binding = await resolveBinding(handle);
      if (binding == null || binding.handle != handle || !binding.isCurrent()) {
        return false;
      }
      var vid = await binding.read('vid');
      if (vid.isEmpty || vid == 'no') return false;
      original = _SavedOutput(
        handle: handle,
        vid: vid,
        vo: await binding.read('vo'),
        hwdec: await binding.read('hwdec'),
        imageFormat: await binding.read('hwdec-image-format'),
      );
      if (original.vo.isEmpty || original.vo == outputName) return false;

      // 先停用视频轨道：之后改 hwdec 和 vo 都不会各自重建一次，
      // 恢复轨道时只新建一次输出和解码器
      changed = true;
      await binding.write('vid', 'no');
      if (await binding.read('vid') != 'no') {
        await _restore(binding, original);
        return false;
      }
      // 不拷回内存的 VideoToolbox 解码；用户关掉了硬件解码时保持软件解码
      if (original.hwdec != 'no') {
        await binding.write('hwdec', 'videotoolbox');
      }
      // 10 位片源也输出 8 位 NV12，原生端才能把弹幕画进去
      await binding.write('hwdec-image-format', 'nv12');
      // 原版 libmpv 没有这个输出：设置会被拒绝，vo 保持不变
      await binding.write('vo', outputName);
      var selected = await binding.read('vo') == outputName;
      await binding.write('vid', vid);
      var current = binding.isCurrent() ? await binding.read('current-vo') : '';
      if (selected && current == outputName) {
        _saved = original;
        return true;
      }
      Log.logPrint(
        'iOS PiP: vo_simplelive unavailable (vo: $selected, current: $current)',
      );
      await _restore(binding, original);
      return false;
    } catch (error) {
      Log.logPrint('iOS PiP: vo_simplelive switch failed: $error');
      if (changed && binding != null && original != null) {
        await _restore(binding, original);
      }
      return false;
    }
  }

  Future<bool> _disable(int handle) async {
    var saved = _saved;
    if (saved == null) return true;
    if (saved.handle != handle) return false;
    _saved = null;
    try {
      var binding = await resolveBinding(handle);
      // 播放器已经释放：没有需要恢复的输出
      if (binding == null || binding.handle != handle) return true;
      return await _restore(binding, saved);
    } catch (error) {
      Log.logPrint('iOS PiP: vo_simplelive restoration failed: $error');
      return false;
    }
  }

  /// 换回原来的输出：同样先停用视频轨道，改回 vo 和 hwdec 后再恢复
  Future<bool> _restore(
    IosPipPropertyBinding binding,
    _SavedOutput original,
  ) async {
    try {
      if (!binding.isCurrent()) return false;
      await binding.write('vid', 'no');
      await binding.write('vo', original.vo);
      await binding.write(
        'hwdec-image-format',
        original.imageFormat.isEmpty ? 'no' : original.imageFormat,
      );
      if (original.hwdec.isNotEmpty) {
        await binding.write('hwdec', original.hwdec);
      }
      await binding.write('vid', original.vid);
      if (!binding.isCurrent()) return false;
      var vo = await binding.read('vo');
      var current = await binding.read('current-vo');
      var restored =
          vo == original.vo && current.isNotEmpty && current != outputName;
      if (!restored) {
        Log.logPrint(
          'iOS PiP: output restoration incomplete (vo: $vo, current: $current)',
        );
      }
      return restored;
    } catch (error) {
      Log.logPrint('iOS PiP: output restoration failed: $error');
      return false;
    }
  }
}

class _SavedOutput {
  const _SavedOutput({
    required this.handle,
    required this.vid,
    required this.vo,
    required this.hwdec,
    required this.imageFormat,
  });

  final int handle;
  final String vid;
  final String vo;
  final String hwdec;
  final String imageFormat;
}
