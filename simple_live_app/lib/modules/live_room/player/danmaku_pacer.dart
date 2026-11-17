import 'dart:async';
import 'dart:collection';
import 'dart:math';

/// 把一阵一阵到的弹幕匀开上屏（设置里的“弹幕缓冲增强”）。
///
/// 平台常常一阵一阵地给弹幕。实测 Twitch 的大直播间大约 3 秒一个周期：2 秒有消息，
/// 接着 1～2 秒一条没有（服务器就是这样发的，同一个频道开几条连接收到的完全一样，
/// 不是网络问题）。到了就放的话，画面上是一坨弹幕、一段空白、又一坨，空白那一两秒
/// 看起来就像卡住了。光把空白填上还不够：放得时快时慢，弹幕又是先占上面的行，
/// 快的时候才用到下面的行，下面几行看着还是一块一块的。所以要放得尽量匀速。
///
/// 做法：放出的速度 = 最近一段时间（窗口）里到的条数 ÷ 窗口长度，也就是对到达的
/// 速度做滑动平均。窗口比空档长，速度就不会掉到零；窗口正好是一个周期时，速度是
/// 恒定的。每条弹幕最多晚一个窗口那么久。手里存着的比照这个放法应该剩下的少了
/// 就放慢一点、多了就放快一点，不会越差越多。YouTube 的聊天区、B 站的弹幕引擎
/// 也是先攒一会儿再放。
///
/// 窗口跟着直播间自己的节奏定：
/// - 记下最近 [gapWindow] 里的空档（明显比平均间隔长、8 倍以上的才算，聊天本来就
///   稀稀拉拉的不算）。空档来得有规律时窗口取一个周期，否则取最长空档的两倍，
///   最长 [maxDelay]；
/// - 刚进直播间还不知道它是不是一阵一阵的，前 [warmUp] 先按 [warmWindow] 来，
///   头一次空档也不会空；之后没见过空档的话，在 [warmFade] 里逐渐回到到了就放；
/// - 聊天不多（平均每秒不到 [minRate] 条，设置里可以改）时不用匀，到了就放，
///   只把同时到的一批稍微错开。
///
/// 所以一阵一阵的直播间弹幕晚一两秒（视频本身比聊天晚好几秒，弹幕晚一点反而更
/// 对得上），消息本来就连续的直播间只在刚进去的头二十几秒晚一点。
///
/// [smoothing] 返回 false 时（设置里关了“弹幕缓冲增强”）一律到了就放。
/// 每次最多放 [maxPerTick] 条：每条上屏都要排版，攒在同一帧里会让那一帧变慢。
/// 积压超过 [maxQueue] 条时丢掉最早的（聊天区照样有，只是不上视频）。
class DanmakuPacer<T> {
  DanmakuPacer(
    this.emit, {
    this.tick = const Duration(milliseconds: 16),
    this.maxPerTick = 3,
    this.rateWindow = const Duration(seconds: 8),
    this.gapWindow = const Duration(seconds: 30),
    this.maxDelay = const Duration(seconds: 4),
    this.warmUp = const Duration(seconds: 20),
    this.warmFade = const Duration(seconds: 5),
    this.warmWindow = const Duration(seconds: 3),
    this.minRate = 2,
    this.minRateOf,
    this.maxQueue = 600,
    this.smoothing,
    int Function()? now,
  }) : _now = now ?? _stopwatchNow();

  final void Function(T item) emit;
  final Duration tick;
  final int maxPerTick;

  /// 算“聊天多不多”用的时间范围，也是到达时间保留多久（不短于 [maxDelay]）
  final Duration rateWindow;
  final Duration gapWindow;

  /// 窗口最长多久，也就是弹幕最多晚多久
  final Duration maxDelay;

  /// 刚进直播间的这段时间里，没见过空档也按 [warmWindow] 匀
  final Duration warmUp;

  /// [warmUp] 过后用这么久逐渐回到到了就放
  final Duration warmFade;
  final Duration warmWindow;

  /// 平均每秒少于这么多条时不匀，到了就放
  final double minRate;

  /// 不为空时用它返回的门槛（设置里的“缓冲增强的起始弹幕量”）
  final double Function()? minRateOf;
  final int maxQueue;

  /// 要不要匀（设置里的“弹幕缓冲增强”）；为空时一直匀
  final bool Function()? smoothing;

  /// 当前时间（毫秒），测试时换成假的
  final int Function() _now;

  static int Function() _stopwatchNow() {
    var watch = Stopwatch()..start();
    return () => watch.elapsedMilliseconds;
  }

  /// 两条消息隔了这么久（毫秒）才记成一次空档
  static const int _minGap = 100;

  /// 隔得比这还久（毫秒）是聊天停了，不是节奏
  static const int _maxGap = 3000;

  /// 不匀的时候最慢也按这个速度放（条/毫秒），同时到的一批错开一点，不排成一竖列
  static const double _immediatePace = 0.02;

  /// 排队的弹幕和进队时间
  final Queue<(T, int)> _queue = Queue<(T, int)>();

  /// 最近 [rateWindow] 里每条弹幕到达的时间（从早到晚）
  final List<int> _times = [];

  /// 最近 [gapWindow] 里的空档：（结束的时间，长度）
  final Queue<(int, int)> _gaps = Queue<(int, int)>();

  /// [_times] 从空到有的时间：刚开始时范围没满，速度按实际经过的时间算
  int _epoch = 0;

  /// 进直播间（或清空）后第一条弹幕到的时间
  int? _joined;
  int? _lastArrival;
  int? _lastAccrue;
  Timer? _timer;

  /// 现在可以放出的条数（按速度累积，可以是小数）
  double _budget = 1;

  /// 现在的窗口（毫秒）和上次更新它的时间；变长马上变，变短慢慢变
  double _window = 0;
  int? _windowAt;

  /// 聊天够多、正在匀。在门槛上下晃的时候不来回切换
  bool _busy = false;

  /// 还在排队的条数
  int get pending => _queue.length;

  /// 现在按多长的窗口在匀（毫秒），0 是到了就放
  int get window => _updateWindow(_now()).round();

  /// 聊天够多（过了起始弹幕量），在缓冲
  bool get busy {
    _updateWindow(_now());
    return _busy;
  }

  void add(T item) {
    var now = _now();
    var last = _lastArrival;
    if (last != null) {
      var gap = now - last;
      if (gap >= _minGap && gap <= _maxGap) {
        _gaps.add((now, gap));
      }
    }
    _trim(now);
    _joined ??= now;
    if (_times.isEmpty) {
      _epoch = now;
    }
    _times.add(now);
    _lastArrival = now;
    _accrue(now);
    if (_queue.isEmpty && _budget >= 1) {
      // 前面没有排队的、也没有放得太密：马上上屏
      _budget -= 1;
      emit(item);
      return;
    }
    _queue.add((item, now));
    while (_queue.length > maxQueue) {
      _queue.removeFirst();
    }
    _timer ??= Timer.periodic(tick, (_) => _drain());
  }

  /// [_times] 里第一个不早于 [time] 的位置
  int _indexFrom(num time) {
    var lo = 0, hi = _times.length;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      if (_times[mid] < time) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void _trim(int now) {
    var cut = _indexFrom(now - rateWindow.inMilliseconds);
    if (cut > 0) {
      _times.removeRange(0, cut);
    }
    var gapSince = now - gapWindow.inMilliseconds;
    while (_gaps.isNotEmpty && _gaps.first.$1 < gapSince) {
      _gaps.removeFirst();
    }
  }

  /// 最近的平均速度（条/毫秒），用来判断聊天多不多。刚开始按至少 1 秒算
  double _rate(int now) {
    if (_times.isEmpty) return 0;
    var span = (now - _epoch).clamp(1000, rateWindow.inMilliseconds);
    return _times.length / span;
  }

  /// 这个直播间现在该用多长的窗口（毫秒），0 是不用匀
  double _targetWindow(int now, double rate) {
    if (smoothing?.call() == false) return 0;
    // 到了门槛才开始匀，掉到门槛的七成以下才停。和门槛比的是至少 4 秒的平均：
    // 一阵一阵的直播间只看头一两秒会高估
    var threshold = minRateOf?.call() ?? minRate;
    var span = (now - _epoch).clamp(4000, rateWindow.inMilliseconds);
    var perSecond = _times.length * 1000 / span;
    _busy = perSecond >= (_busy ? threshold * 0.7 : threshold);
    if (!_busy) return 0;
    var limit = maxDelay.inMilliseconds.toDouble();
    // 比平均间隔长 8 倍以上的才算空档：随机到达的消息几乎不会隔这么久
    var floor = 8 / rate;
    var longest = 0;
    var ends = <int>[];
    for (var gap in _gaps) {
      if (gap.$2 >= floor) {
        ends.add(gap.$1);
        if (gap.$2 > longest) longest = gap.$2;
      }
    }
    var target = 0.0;
    if (longest > 0) {
      target = 2.0 * longest;
      if (ends.length >= 3) {
        // 空档来得有规律：窗口取一个周期，放出的速度就是恒定的
        var steps = [
          for (var i = 1; i < ends.length; i++) ends[i] - ends[i - 1]
        ]..sort();
        var period = steps[steps.length ~/ 2];
        if (period >= longest * 1.2 && period <= limit * 1.15) {
          target = period.toDouble();
        }
      }
      target = min(max(target, longest * 1.3), limit);
    }
    return max(target, _warmWindow(now));
  }

  /// 刚进直播间时先用的窗口：前 [warmUp] 是 [warmWindow]，之后逐渐减到 0
  double _warmWindow(int now) {
    var joined = _joined;
    if (joined == null) return 0;
    var full = warmWindow.inMilliseconds.toDouble();
    var past = now - joined - warmUp.inMilliseconds;
    if (past <= 0) return full;
    var fade = warmFade.inMilliseconds;
    if (past >= fade) return 0;
    return full * (1 - past / fade);
  }

  /// 把窗口更新到现在：变长马上变；变短最多每毫秒短半毫秒，
  /// 不然窗口一缩，存着的弹幕会一下子涌出来
  double _updateWindow(int now) {
    var target = _targetWindow(now, _rate(now));
    var elapsed = now - (_windowAt ?? now);
    _windowAt = now;
    _window = target >= _window ? target : max(target, _window - 0.5 * elapsed);
    return _window;
  }

  /// 现在该按多快放（条/毫秒）
  double _pace(int now) {
    var window = _updateWindow(now);
    var rate = _rate(now);
    if (window < 200) {
      return max(2 * rate, _immediatePace);
    }
    // 窗口里到了多少条，就在一个窗口那么久里放完
    var from = _indexFrom(now - window);
    var count = _times.length - from;
    var pace = count / window;
    if (count > 0) {
      // 照这个放法，手里现在应该还剩多少条：窗口里的每一条，过了窗口的几分之几
      // 就算放了几分之几。实际剩得少（比如开始匀之前那几条是直接放掉的），到了空档
      // 会提前放空，所以放慢一点攒回来；剩得多就放快一点
      var ages = 0;
      for (var i = from; i < _times.length; i++) {
        ages += now - _times[i];
      }
      var should = count - ages / window;
      pace *= ((_queue.length + 1) / (should + 1)).clamp(0.5, 1.6);
    }
    if (_queue.isNotEmpty && now - _queue.first.$2 > window + 1000) {
      // 等得比窗口久得多：加快
      pace = max(pace, rate * 2);
    }
    return pace;
  }

  /// 按经过的时间累积可以放出的条数。停了很久（比如窗口卡住）不会攒出一大堆
  void _accrue(int now) {
    var last = _lastAccrue;
    _lastAccrue = now;
    if (last == null) {
      _budget = 1;
      _updateWindow(now);
      return;
    }
    var elapsed = min(now - last, 250);
    var cap = _queue.isEmpty ? 1.0 : maxPerTick.toDouble();
    _budget = min(_budget + _pace(now) * elapsed, cap);
  }

  void _drain() {
    var now = _now();
    _trim(now);
    _accrue(now);
    if (_queue.isEmpty) {
      // 放完了：停表，下一条来时再说
      _timer?.cancel();
      _timer = null;
      return;
    }
    var sent = 0;
    while (_queue.isNotEmpty && sent < maxPerTick && _budget >= 1) {
      emit(_queue.removeFirst().$1);
      _budget -= 1;
      sent++;
    }
  }

  /// 把排队的马上全放出来，顺序不变（要插一条不用排队的之前，或切到后台时）
  void flush() {
    while (_queue.isNotEmpty) {
      emit(_queue.removeFirst().$1);
    }
    _timer?.cancel();
    _timer = null;
    _budget = 0;
  }

  /// 清空排队的弹幕（清屏、切到后台、关闭弹幕、离开直播间）
  void clear() {
    _queue.clear();
    _times.clear();
    _gaps.clear();
    _timer?.cancel();
    _timer = null;
    _joined = null;
    _lastArrival = null;
    _lastAccrue = null;
    _budget = 1;
    _window = 0;
    _windowAt = null;
    _busy = false;
  }
}
