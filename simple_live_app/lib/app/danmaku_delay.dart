import 'dart:async';

/// 弹幕延迟（设置里每个平台一个值）：视频上的弹幕晚一点再放，和画面对上。
///
/// 收到的弹幕按到达的先后排成一个队列，只用一个计时器，定在队头到时间的那一刻；
/// 到了就把所有到时间的一起放出，再把计时器定到新的队头。不是每条弹幕开一个计时器。
/// 延迟用的是现在的设置（[delayMs] 每次都读）：所有弹幕的延迟相同，按到达排的队
/// 也就是按放出时间排好的。调小延迟后，下一条进来时就按新的值放；调大后，
/// 计时器到点时发现队头还没到时间，再往后定。
///
/// 计时器至少隔 [minTick]：大直播间每秒几百条时，一次放出一批，不会每条都重新定一次。
/// 放出以后交给“弹幕缓冲增强”（DanmakuPacer），两段等待会叠加。
/// 积压超过 [maxQueue] 条时丢掉最早的。
class DanmakuDelayQueue<T> {
  DanmakuDelayQueue(
    this.emit, {
    required this.delayMs,
    this.minTick = const Duration(milliseconds: 16),
    this.maxQueue = 5000,
    int Function()? now,
  }) : _now = now ?? _stopwatchNow();

  /// 到时间后放出一条
  final void Function(T item) emit;

  /// 现在的延迟（毫秒），0 是不延迟
  final int Function() delayMs;
  final Duration minTick;
  final int maxQueue;
  final int Function() _now;

  static int Function() _stopwatchNow() {
    var watch = Stopwatch()..start();
    return () => watch.elapsedMilliseconds;
  }

  List<T?> _items = List<T?>.filled(64, null);
  List<int> _times = List<int>.filled(64, 0);
  int _head = 0;
  int _length = 0;

  Timer? _timer;

  /// 计时器定在什么时候响（毫秒，和 [_now] 一样的时钟）
  int _timerAt = 0;

  /// 还在等的条数
  int get pending => _length;

  /// 有没有计时器在走（测试用）
  bool get timerActive => _timer != null;

  /// 一共定过几次计时器（测试用）
  int get timersStarted => _timersStarted;
  int _timersStarted = 0;

  /// 排一条。[immediate]（自己发的弹幕）不延迟，马上放出，不等前面排着的
  void add(T item, {bool immediate = false}) {
    if (immediate) {
      emit(item);
      return;
    }
    var now = _now();
    var delay = delayMs();
    if (delay <= 0 && _length == 0) {
      emit(item);
      return;
    }
    if (_length >= maxQueue) {
      _popFront();
    }
    _push(item, now);
    if (_times[_head] + delay <= now) {
      // 延迟调小了，前面排着的已经到时间
      _drain();
      return;
    }
    _schedule(now, delay);
  }

  void _schedule(int now, int delay) {
    if (_length == 0) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    var due = _times[_head] + delay;
    var at = due - now;
    var tick = minTick.inMilliseconds;
    if (at < tick) {
      at = tick;
    }
    var fireAt = now + at;
    var timer = _timer;
    if (timer != null && _timerAt <= fireAt) {
      // 已经定好的不晚于需要的：等它响
      return;
    }
    timer?.cancel();
    _timerAt = fireAt;
    _timersStarted++;
    _timer = Timer(Duration(milliseconds: at), _onTimer);
  }

  void _onTimer() {
    _timer = null;
    _drain();
  }

  /// 放出所有到时间的，再把计时器定到新的队头
  void _drain() {
    var now = _now();
    var delay = delayMs();
    if (delay < 0) {
      delay = 0;
    }
    while (_length > 0 && _times[_head] + delay <= now) {
      emit(_popFront() as T);
    }
    _schedule(now, delay);
  }

  void _push(T item, int now) {
    var capacity = _items.length;
    if (_length == capacity) {
      var items = List<T?>.filled(capacity * 2, null);
      var times = List<int>.filled(capacity * 2, 0);
      for (var i = 0; i < _length; i++) {
        var from = (_head + i) & (capacity - 1);
        items[i] = _items[from];
        times[i] = _times[from];
      }
      _items = items;
      _times = times;
      _head = 0;
      capacity *= 2;
    }
    var index = (_head + _length) & (capacity - 1);
    _items[index] = item;
    _times[index] = now;
    _length++;
  }

  T? _popFront() {
    var item = _items[_head];
    _items[_head] = null;
    _head = (_head + 1) & (_items.length - 1);
    _length--;
    return item;
  }

  /// 清空还在等的弹幕（换直播间、清屏、切到后台、关闭）
  void clear() {
    _timer?.cancel();
    _timer = null;
    if (_items.length > 64) {
      _items = List<T?>.filled(64, null);
      _times = List<int>.filled(64, 0);
    } else {
      _items.fillRange(0, _items.length, null);
    }
    _head = 0;
    _length = 0;
  }
}
