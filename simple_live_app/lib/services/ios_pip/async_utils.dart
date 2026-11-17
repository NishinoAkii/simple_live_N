import 'dart:async';

/// 同一时间只运行一个任务；运行中再次调用返回同一个结果
class AsyncSingleFlight<T> {
  Future<T>? _running;

  bool get isRunning => _running != null;

  Future<T> run(Future<T> Function() task) {
    var running = _running;
    if (running != null) {
      return running;
    }
    var future = task();
    _running = future;
    future.whenComplete(() {
      if (identical(_running, future)) {
        _running = null;
      }
    }).ignore();
    return future;
  }
}

/// 按顺序逐个执行任务
class AsyncSerialQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() task) {
    var result = _tail.then((_) => task());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}
