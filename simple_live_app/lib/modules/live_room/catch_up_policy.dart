/// 追帧倍速的计算规则
///
/// - 缓冲比目标多 1 秒以上才开始加速，追到目标以内才停止（避免来回切换）；
/// - 落后越多加速越快：比目标多 5 秒约为 2 倍，不超过设置的最高倍速；
/// - 倍速按 0.01 取整。
///
/// 传入的 [ahead] 应是一段时间内缓冲的最低值（见 [BufferFloor]）：
/// HLS（Twitch、Kick 等）按整段下载，每来一段缓冲就跳高几秒再慢慢降低，
/// 用当前值判断会在每段到达时加速、把缓冲耗光后卡住。
class CatchUpPolicy {
  /// 开始加速的余量（秒）
  static const double startMargin = 1.0;

  /// 每多落后 1 秒增加的倍速
  static const double gain = 0.2;

  /// HLS 至少保留的缓冲（秒）：Kick 一段约 4 秒，留得比一段少时，
  /// 网络稍慢一点下一段就接不上
  static const double hlsMinTarget = 4.0;

  /// 实际使用的目标缓冲
  static double targetFor(double target, {required bool hls}) =>
      hls && target < hlsMinTarget ? hlsMinTarget : target;

  static ({double rate, bool catchingUp}) decide({
    required double ahead,
    required double target,
    required double maxRate,
    required bool catchingUp,
  }) {
    if (!catchingUp && ahead > target + startMargin) {
      catchingUp = true;
    } else if (catchingUp && ahead <= target) {
      catchingUp = false;
    }
    if (!catchingUp) {
      return (rate: 1.0, catchingUp: false);
    }
    var rate = (1 + (ahead - target) * gain).clamp(1.01, maxRate).toDouble();
    return (rate: (rate * 100).round() / 100, catchingUp: true);
  }
}

/// 最近一段时间内缓冲时长的最低值，即“始终多出来”的那部分延迟。
///
/// 连续的流（FLV）最低值≈当前值；分段的流（HLS）最低值是下一段到达前的谷底。
class BufferFloor {
  BufferFloor({this.window = const Duration(seconds: 10)});

  /// 统计的时间窗口，要比一个分段长
  final Duration window;
  final List<(DateTime, double)> _samples = [];

  void add(double ahead, {DateTime? now}) {
    now ??= DateTime.now();
    _samples.add((now, ahead));
    var cutoff = now.subtract(window);
    _samples.removeWhere((e) => e.$1.isBefore(cutoff));
  }

  /// 窗口内样本不足一半时返回 null（刚开始播放或刚卡顿过，先不加速）
  double? floor({DateTime? now}) {
    if (_samples.isEmpty) return null;
    now ??= DateTime.now();
    var covered = now.difference(_samples.first.$1);
    if (covered * 2 < window) return null;
    return _samples.map((e) => e.$2).reduce((a, b) => a < b ? a : b);
  }

  void clear() => _samples.clear();
}
