import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/player/picture_guard.dart';
import 'package:simple_live_app/modules/live_room/player/stream_tuning.dart';

/// 卡住 20 秒时：数据还在进来就再等等（最多再等 40 秒），没数据或者读不到速度就重连
void main() {
  const wait = LiveRoomController.keepWaitingForSlowNetwork;

  test('数据还在进来：再等', () {
    expect(wait(200 * 1024, const Duration(seconds: 20)), isTrue);
    expect(wait(16 * 1024, const Duration(seconds: 50)), isTrue);
  });

  test('没有数据、太慢或者读不到速度：重连', () {
    expect(wait(0, const Duration(seconds: 20)), isFalse);
    expect(wait(8 * 1024, const Duration(seconds: 20)), isFalse);
    expect(wait(null, const Duration(seconds: 20)), isFalse);
  });

  test('最多再等 40 秒', () {
    expect(wait(500 * 1024, const Duration(seconds: 59)), isTrue);
    expect(wait(500 * 1024, const Duration(seconds: 60)), isFalse);
  });

  test('线路的 CDN 节点名', () {
    expect(
        StreamTuning.lineNode(
            "https://d1--ov-gotcha03.bilivideo.com/live-bvc/1/index.m3u8?a=1"),
        "ov-gotcha03");
    expect(
        StreamTuning.lineNode(
            "https://xy1x2x3x4xy.mcdn.bilivideo.cn:486/live-bvc/1/index.m3u8"),
        "mcdn");
    expect(StreamTuning.lineNode("http://127.0.0.1:1234/hlsr/1/index.m3u8"), "");
    expect(StreamTuning.lineNode("not a url"), "");
  });

  group('花屏检测（PictureGuard）', () {
    late DateTime now;
    late PictureGuard guard;
    setUp(() {
      now = DateTime(2026, 11, 19, 12);
      guard = PictureGuard(clock: () => now)..opened();
    });
    PictureFault log(String prefix, String level, String text) =>
        guard.onLog(prefix, level, text);
    const missing = "h264: reference picture missing during reorder";

    test('刚打开的 5 秒内不算', () {
      for (var i = 0; i < 4; i++) {
        now = now.add(const Duration(seconds: 1));
        expect(log("ffmpeg/video", "error", missing), PictureFault.none);
      }
    });

    test('偶尔一下不算，8 秒里有 4 秒出错算持续花屏', () {
      now = now.add(const Duration(seconds: 10));
      expect(log("ffmpeg/video", "error", missing), PictureFault.none);
      expect(log("ffmpeg/video", "error", "h264: mmco: unref short failure"),
          PictureFault.none);
      now = now.add(const Duration(seconds: 10));
      expect(log("ffmpeg/video", "error", missing), PictureFault.none);
      now = now.add(const Duration(seconds: 2));
      expect(log("vd", "warn", "Error while decoding frame!"), PictureFault.none);
      now = now.add(const Duration(seconds: 2));
      expect(log("ffmpeg/video", "error", missing), PictureFault.none);
      now = now.add(const Duration(seconds: 2));
      expect(log("ffmpeg/video", "error", "h264: no frame!"), PictureFault.corrupt);
      // 处理过后重新计数
      now = now.add(const Duration(seconds: 1));
      expect(log("ffmpeg/video", "error", missing), PictureFault.none);
    });

    test('“Found duplicated MOOV Atom” 不算：直播 fMP4 每次刷新列表都会报', () {
      now = now.add(const Duration(seconds: 30));
      for (var i = 0; i < 10; i++) {
        now = now.add(const Duration(seconds: 1));
        expect(
          log("ffmpeg/demuxer", "warn",
              "mov,mp4,m4a,3gp,3g2,mj2: Found duplicated MOOV Atom. Skipped it"),
          PictureFault.none,
        );
      }
    });

    test('音频出错、网络警告、HLS 跳过分段以外的分离器警告都不算', () {
      now = now.add(const Duration(seconds: 10));
      for (var i = 0; i < 6; i++) {
        now = now.add(const Duration(seconds: 1));
        expect(log("ffmpeg/audio", "error", "aac: Input buffer exhausted"),
            PictureFault.none);
        expect(log("ffmpeg", "warn", "http: Will reconnect at 123 in 0 second(s)"),
            PictureFault.none);
        expect(log("ffmpeg/video", "warn", "h264: Increasing reorder buffer to 2"),
            PictureFault.none);
      }
      expect(
        PictureGuard.isPictureError("ffmpeg/demuxer", "warn",
            "hls: skipping 3 segments ahead, expired from playlists"),
        isTrue,
      );
    });

    test('处理顺序：重新拉流 → 换线路 → 软件解码 → 放弃', () {
      List<PictureFix> steps(bool soft, int lines) => [
            for (var i = 1; i <= 5; i++)
              PictureGuard.fixFor(i, canSoftware: soft, lineCount: lines),
          ];
      expect(steps(true, 3), [
        PictureFix.reopen,
        PictureFix.nextLine,
        PictureFix.software,
        PictureFix.giveUp,
        PictureFix.giveUp,
      ]);
      // 只有一条线路、已经是软件解码时跳过那一步
      expect(steps(false, 1).take(3),
          [PictureFix.reopen, PictureFix.giveUp, PictureFix.giveUp]);
    });
  });
}
