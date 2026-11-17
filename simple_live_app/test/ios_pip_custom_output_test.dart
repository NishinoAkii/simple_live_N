import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/ios_pip/ios_pip_custom_output.dart';

/// 模拟 mpv 里和输出切换有关的属性：vid=no 时没有输出；恢复轨道时按 vo 新建输出
class _FakeMpv {
  _FakeMpv({
    this.hasCustomOutput = true,
    this.customOutputStarts = true,
    String hwdec = 'auto-copy',
  }) {
    properties['hwdec'] = hwdec;
  }

  /// 补丁版 libmpv 才有 vo=simplelive；原版设置时会被拒绝
  final bool hasCustomOutput;

  /// 应用没导出回调时 vo_simplelive 初始化失败，mpv 会停用视频轨道
  final bool customOutputStarts;
  bool disposed = false;
  final writes = <String>[];
  final properties = <String, String>{
    'vid': '1',
    'vo': 'libmpv',
    'hwdec-image-format': 'no',
    'current-vo': 'libmpv',
  };

  IosPipPropertyBinding binding(int handle) => IosPipPropertyBinding(
        handle: handle,
        isCurrent: () => !disposed,
        read: (name) async => properties[name] ?? '',
        write: write,
      );

  Future<void> write(String name, String value) async {
    writes.add('$name=$value');
    if (name == 'vo') {
      if (value == IosPipCustomOutput.outputName && !hasCustomOutput) return;
      properties['vo'] = value;
      if (properties['vid'] != 'no') _createOutput();
    } else if (name == 'vid') {
      properties['vid'] = value;
      if (value == 'no') {
        properties['current-vo'] = '';
      } else {
        _createOutput();
      }
    } else {
      properties[name] = value;
    }
  }

  void _createOutput() {
    var vo = properties['vo']!;
    if (vo == IosPipCustomOutput.outputName && !customOutputStarts) {
      properties['current-vo'] = '';
      properties['vid'] = 'no';
      return;
    }
    properties['current-vo'] = vo;
  }
}

void main() {
  const handle = 42;

  IosPipCustomOutput output(_FakeMpv mpv) => IosPipCustomOutput(
        resolveBinding: (expected) async =>
            expected == handle && !mpv.disposed ? mpv.binding(handle) : null,
      );

  test('switches with the video track disabled and restores everything',
      () async {
    var mpv = _FakeMpv();
    var custom = output(mpv);

    expect(await custom.enable(handle), isTrue);
    expect(custom.isActive, isTrue);
    expect(mpv.writes, [
      'vid=no',
      'hwdec=videotoolbox',
      'hwdec-image-format=nv12',
      'vo=simplelive',
      'vid=1',
    ]);
    expect(mpv.properties['current-vo'], 'simplelive');

    mpv.writes.clear();
    expect(await custom.disable(handle), isTrue);
    expect(custom.isActive, isFalse);
    expect(mpv.writes.first, 'vid=no');
    expect(mpv.writes.last, 'vid=1');
    expect(mpv.properties, {
      'vid': '1',
      'vo': 'libmpv',
      'hwdec-image-format': 'no',
      'current-vo': 'libmpv',
      'hwdec': 'auto-copy',
    });
  });

  test('stock libmpv rejects the output and nothing is left changed', () async {
    var mpv = _FakeMpv(hasCustomOutput: false);
    var custom = output(mpv);

    expect(await custom.enable(handle), isFalse);
    expect(custom.isActive, isFalse);
    expect(mpv.properties['vo'], 'libmpv');
    expect(mpv.properties['hwdec'], 'auto-copy');
    expect(mpv.properties['hwdec-image-format'], 'no');
    expect(mpv.properties['vid'], '1');
    expect(mpv.properties['current-vo'], 'libmpv');
  });

  test('a failing vo_simplelive (callbacks missing) falls back', () async {
    var mpv = _FakeMpv(customOutputStarts: false);
    var custom = output(mpv);

    expect(await custom.enable(handle), isFalse);
    expect(custom.isActive, isFalse);
    expect(mpv.properties['vo'], 'libmpv');
    expect(mpv.properties['vid'], '1');
    expect(mpv.properties['current-vo'], 'libmpv');
  });

  test('keeps software decoding when the user turned hwdec off', () async {
    var mpv = _FakeMpv(hwdec: 'no');
    var custom = output(mpv);

    expect(await custom.enable(handle), isTrue);
    expect(mpv.writes, isNot(contains('hwdec=videotoolbox')));
    expect(mpv.properties['hwdec'], 'no');
  });

  test('disable without enable and wrong handles are harmless', () async {
    var mpv = _FakeMpv();
    var custom = output(mpv);

    expect(await custom.disable(handle), isTrue);
    expect(await custom.enable(7), isFalse);
    expect(mpv.writes, isEmpty);
  });

  test('dispose restores the output and refuses later switches', () async {
    var mpv = _FakeMpv();
    var custom = output(mpv);

    expect(await custom.enable(handle), isTrue);
    await custom.dispose();
    expect(mpv.properties['vo'], 'libmpv');
    expect(mpv.properties['current-vo'], 'libmpv');
    expect(await custom.enable(handle), isFalse);
    expect(await custom.disable(handle), isTrue);
  });

  test('a disposed player is not touched', () async {
    var mpv = _FakeMpv();
    var custom = output(mpv);

    expect(await custom.enable(handle), isTrue);
    mpv.disposed = true;
    mpv.writes.clear();
    expect(await custom.disable(handle), isTrue);
    expect(mpv.writes, isEmpty);
  });
}
