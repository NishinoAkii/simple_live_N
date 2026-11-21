import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_app/widgets/video_stats_overlay.dart';

void main() {
  group('bitrate (bit/s)', () {
    test('kbps below 1000, Mbps above with two decimals', () {
      expect(VideoStats.bitrate("128000"), "128 kbps");
      expect(VideoStats.bitrate("5847264"), "5.85 Mbps");
      expect(VideoStats.bitrate("1000000"), "1.00 Mbps");
      // 999.6 kbps 四舍五入后是 1000，改用 Mbps
      expect(VideoStats.bitrate("999600"), "1.00 Mbps");
      expect(VideoStats.bitrate("999400"), "999 kbps");
    });

    test('small values and missing values', () {
      expect(VideoStats.bitrate("640"), "640 bps");
      expect(VideoStats.bitrate("0"), "0 bps");
      expect(VideoStats.bitrate(""), "-");
      expect(VideoStats.bitrate(null), "-");
      expect(VideoStats.bitrate("n/a"), "-");
      expect(VideoStats.bitrate("-1"), "-");
    });
  });

  group('fps', () {
    test('estimated output fps, trailing zeros removed', () {
      expect(VideoStats.fps("59.940060", "60.000000"), "59.94 fps");
      expect(VideoStats.fps("60.000000", ""), "60 fps");
      expect(VideoStats.fps("29.900000", ""), "29.9 fps");
      expect(VideoStats.fps("23.976024", ""), "23.98 fps");
    });

    test('falls back to container fps, then "-"', () {
      expect(VideoStats.fps("", "30.000000"), "30 fps");
      expect(VideoStats.fps("0.000000", "25"), "25 fps");
      expect(VideoStats.fps(null, null), "-");
      expect(VideoStats.fps("", "0"), "-");
    });
  });

  group('download speed (bytes/s)', () {
    test('B/s, KB/s and MB/s', () {
      expect(VideoStats.speed("512"), "512 B/s");
      expect(VideoStats.speed("1536"), "1.5 KB/s");
      expect(VideoStats.speed("204800"), "200 KB/s");
      expect(VideoStats.speed("1258291"), "1.20 MB/s");
      expect(VideoStats.speed("0"), "0 B/s");
    });

    test('missing values', () {
      expect(VideoStats.speed(""), "-");
      expect(VideoStats.speed(null), "-");
    });
  });

  group('buffer duration (seconds)', () {
    test('one decimal under 10 s, whole seconds above', () {
      expect(VideoStats.seconds("3.214000"), "3.2s");
      expect(VideoStats.seconds("0.000000"), "0.0s");
      expect(VideoStats.seconds("12.600000"), "13s");
      expect(VideoStats.seconds("125"), "125s");
    });

    test('missing values', () {
      expect(VideoStats.seconds(""), "-");
      expect(VideoStats.seconds(null), "-");
    });
  });

  test('resolution', () {
    expect(VideoStats.resolution("1920", "1080"), "1920×1080");
    expect(VideoStats.resolution("", "1080"), "-");
    expect(VideoStats.resolution("0", "0"), "-");
  });

  test('codec and decoder', () {
    expect(VideoStats.codec("h264", "", "d3d11va"), "h264 · d3d11va");
    expect(VideoStats.codec("hevc", "", "no"), "hevc · 软解");
    expect(
      VideoStats.codec(
          "", "h264 (H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10)", ""),
      "h264",
    );
    expect(VideoStats.codec("", "", "videotoolbox"), "videotoolbox");
    expect(VideoStats.codec(null, null, null), "-");
  });

  test('dropped frames: output + decoder', () {
    expect(VideoStats.drops("3", "12"), "15");
    expect(VideoStats.drops("4", ""), "4");
    expect(VideoStats.drops("", ""), "-");
  });

  test('lines: one item per line, "-" for everything unreadable', () {
    var empty = VideoStats.lines(const {});
    expect(empty.map((e) => e.$1),
        ["分辨率", "帧率", "视频码率", "音频码率", "编解码", "格式", "丢帧", "缓冲", "下载速度"]);
    expect(empty.every((e) => e.$2 == "-"), isTrue);

    var lines = Map.fromEntries(VideoStats.lines({
      "video-params/w": "1280",
      "video-params/h": "720",
      "estimated-vf-fps": "",
      "container-fps": "30.000000",
      "video-bitrate": "2500000",
      "audio-bitrate": "128000",
      "video-format": "h264",
      "hwdec-current": "mediacodec",
      "file-format": "flv",
      "frame-drop-count": "1",
      "decoder-frame-drop-count": "0",
      "demuxer-cache-duration": "4.5",
      "cache-speed": "409600",
    }).map((e) => MapEntry(e.$1, e.$2)));
    expect(lines["分辨率"], "1280×720");
    expect(lines["帧率"], "30 fps");
    expect(lines["视频码率"], "2.50 Mbps");
    expect(lines["音频码率"], "128 kbps");
    expect(lines["编解码"], "h264 · mediacodec");
    expect(lines["格式"], "FLV");
    expect(VideoStats.format("hls"), "HLS");
    expect(VideoStats.format("mov,mp4,m4a,3gp,3g2,mj2"), "MP4");
    expect(lines["丢帧"], "1");
    expect(lines["缓冲"], "4.5s");
    expect(lines["下载速度"], "400 KB/s");
  });

  test('the setting stays in the fork-only (ext) part of WebDAV sync', () {
    var settings = {
      LocalStorageService.kPlayerVideoStats: true,
      "DanmuSize": 16.0,
    };
    expect(
      SyncCompat.upstreamSettings(settings)
          .containsKey(LocalStorageService.kPlayerVideoStats),
      isFalse,
    );
    expect(
      SyncCompat.extSettings(settings)[LocalStorageService.kPlayerVideoStats],
      isTrue,
    );
  });
}
