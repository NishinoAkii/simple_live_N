import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

/// 不加载 mpv 的播放器：记下暂停、播放、停止
class FakePlayer extends Fake implements Player {
  PlayerState current = const PlayerState();
  final playingController = StreamController<bool>.broadcast();
  final calls = <String>[];

  @override
  PlayerState get state => current;

  @override
  PlayerStream get stream => PlayerStream(
        const Stream.empty(),
        playingController.stream,
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
        const Stream.empty(),
      );

  void setPlaying(bool value) {
    current = current.copyWith(playing: value);
    playingController.add(value);
  }

  @override
  Future<void> pause() async {
    calls.add("pause");
    setPlaying(false);
  }

  @override
  Future<void> play() async {
    calls.add("play");
    setPlaying(true);
  }

  @override
  Future<void> stop() async {
    calls.add("stop");
    setPlaying(false);
  }
}
