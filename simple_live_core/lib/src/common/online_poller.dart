import 'dart:async';

/// 平台不在弹幕连接里推送在线人数时，隔一段时间读一次（Twitch、Kick）。
/// 读不到（没开播、网络出错）就等下一次，不报错
class OnlinePoller {
  /// 读现在的在线人数，读不到返回 null
  final Future<int?> Function() read;
  final void Function(int online) onOnline;
  final Duration interval;

  OnlinePoller({
    required this.read,
    required this.onOnline,
    this.interval = const Duration(seconds: 60),
  });

  Timer? _timer;
  int _generation = 0;

  /// 开始定时读；进直播间时房间信息里已经有一个数，所以第一次在 [interval] 之后
  void start() {
    stop();
    _timer = Timer.periodic(interval, (_) => poll());
  }

  /// 读一次。[stop] 之后才回来的结果不要
  Future<void> poll() async {
    var generation = _generation;
    int? online;
    try {
      online = await read();
    } catch (_) {
      return;
    }
    if (generation == _generation && online != null && online > 0) {
      onOnline(online);
    }
  }

  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }
}
