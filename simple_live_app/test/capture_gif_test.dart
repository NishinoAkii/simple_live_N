import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/capture/capture_controller.dart';
import 'package:simple_live_app/app/capture/gif_recorder.dart';

/// 纯色的 BGR0 帧（每行多 16 字节，和 mpv 的 stride 一样可能比宽大）
RawVideoFrame _frame(int r, int g, int b, {int width = 960, int height = 540}) {
  var stride = width * 4 + 16;
  var bytes = Uint8List(stride * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var i = y * stride + x * 4;
      bytes[i] = b;
      bytes[i + 1] = g;
      bytes[i + 2] = r;
    }
  }
  return RawVideoFrame(bytes, width, height, stride);
}

/// 文件里每个图形控制扩展（21 F9 04）记的显示时间（1/100 秒）
List<int> _delays(Uint8List gif) => [
      for (var i = 0; i + 5 < gif.length; i++)
        if (gif[i] == 0x21 && gif[i + 1] == 0xF9 && gif[i + 2] == 0x04)
          gif[i + 4] | (gif[i + 5] << 8),
    ];

void _expectAnimatedGif(File file) {
  var bytes = file.readAsBytesSync();
  expect(String.fromCharCodes(bytes.take(6)), "GIF89a");
  expect(String.fromCharCodes(bytes), contains("NETSCAPE2.0"));
  expect(bytes.last, 0x3B);
  // 每帧 10 = 100 毫秒，10 fps 的速度
  expect(_delays(bytes), [10, 10, 10]);
  var gif = img.decodeGif(bytes)!;
  expect(gif.numFrames, 3);
  expect(gif.loopCount, 0);
  // 960×540 缩到 480 宽，比例不变
  expect((gif.width, gif.height), (480, 270));
  expect(gif.frames.map((f) => f.frameDuration), [100, 100, 100]);
  // 每帧单独配色：红、绿、蓝都对（量化后差几个色阶以内）
  const want = [
    [250, 0, 0],
    [0, 200, 0],
    [0, 0, 150],
  ];
  for (var i = 0; i < 3; i++) {
    var pixel = gif.frames[i].getPixel(240, 135);
    var got = [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
    for (var c = 0; c < 3; c++) {
      expect(got[c], closeTo(want[i][c], 4), reason: "frame $i: $got");
    }
  }
}

/// 录屏存成 GIF：缩小、每帧的显示时间、边录边写、后台 isolate
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync("capture_gif"));
  tearDown(() => dir.deleteSync(recursive: true));

  test("三帧编成循环的 GIF：480 宽、每帧 100 毫秒", () {
    var path = p.join(dir.path, "a.gif");
    var writer = GifFileWriter(path);
    writer.add(_frame(250, 0, 0), 0);
    writer.add(_frame(0, 200, 0), 100);
    writer.add(_frame(0, 0, 150), 200);
    var result = writer.finish();
    expect(result.frames, 3);
    expect(result.durationMs, 300);
    _expectAnimatedGif(File(path));
  });

  test("后台 isolate 编码：发三帧、收尾，文件一样", () async {
    var path = p.join(dir.path, "b.gif");
    var worker = await GifEncodeWorker.spawn(path);
    worker.add(_frame(250, 0, 0), 0);
    worker.add(_frame(0, 200, 0), 100);
    worker.add(_frame(0, 0, 150), 200);
    var result = await worker.finish();
    expect(result.frames, 3);
    expect(worker.pending, 0);
    _expectAnimatedGif(File(path));
  });

  test("丢了帧也按实际时间记，播放速度不变", () {
    var path = p.join(dir.path, "c.gif");
    var writer = GifFileWriter(path);
    writer.add(_frame(250, 0, 0), 0);
    // 中间少了一帧
    writer.add(_frame(0, 200, 0), 200);
    writer.add(_frame(0, 0, 150), 296);
    writer.finish();
    expect(_delays(File(path).readAsBytesSync()), [20, 10, 10]);
  });
}
