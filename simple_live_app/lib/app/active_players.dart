import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// 正在用的播放器。退出时要先把存档传上去，窗口藏起来之后声音不能还在响
class ActivePlayers {
  static final Set<Player> _players = {};

  static final List<void Function()> _idleListeners = [];

  static void add(Player player) => _players.add(player);

  static void remove(Player player) {
    _players.remove(player);
    if (_players.isEmpty) {
      for (var listener in List.of(_idleListeners)) {
        listener();
      }
    }
  }

  /// 有直播间正在播放
  static bool get isPlaying => _players.isNotEmpty;

  /// 最后一个播放器关掉时调用（离开直播间）
  static void addIdleListener(void Function() listener) =>
      _idleListeners.add(listener);

  static void removeIdleListener(void Function() listener) =>
      _idleListeners.remove(listener);

  static Future<void> pauseAll() async {
    await Future.wait(_players.map((player) async {
      try {
        await player.pause().timeout(const Duration(seconds: 1));
      } catch (_) {}
    }));
  }
}
