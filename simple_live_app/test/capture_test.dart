import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show MethodCall, MissingPluginException;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/capture/capture_compose.dart';
import 'package:simple_live_app/app/capture/capture_controller.dart';
import 'package:simple_live_app/app/capture/capture_flow.dart';
import 'package:simple_live_app/app/capture/capture_meta.dart';
import 'package:simple_live_app/app/capture/capture_settings.dart';
import 'package:simple_live_app/app/capture/capture_storage.dart';
import 'package:simple_live_app/app/capture/gif_recorder.dart';
import 'package:simple_live_app/app/capture/native_capture.dart';
import 'package:simple_live_app/app/capture/stream_recorder.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_compat.dart';

import 'fakes/fake_player.dart';
import 'fakes/memory_storage.dart';

/// 截图和录屏：拼图的顺序、文件名和图片信息、截图后的处理、流录制、设置和同步、
/// 最长录制时间（确认、到时自动保存）、范围
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.testMode = true;
    CaptureSettings.reset();
  });
  tearDown(() {
    CaptureSettings.reset();
    CaptureFeatures.debugStreamRecording = null;
    CaptureFeatures.debugScreenRecording = null;
    Get.reset();
  });

  group("拼图", () {
    const player = Rect.fromLTWH(100, 50, 800, 450);
    const overlays = {
      CaptureLayer.danmaku: [Rect.fromLTWH(100, 50, 800, 450)],
      CaptureLayer.videoStats: [Rect.fromLTWH(108, 58, 120, 80)],
      // 同时有两张 SC 卡片、一张礼物卡片
      CaptureLayer.superChat: [
        Rect.fromLTWH(124, 300, 240, 60),
        Rect.fromLTWH(124, 368, 240, 60),
      ],
      CaptureLayer.gifts: [Rect.fromLTWH(124, 436, 200, 32)],
    };

    test("默认只有视频和弹幕；选了的层按屏幕上的上下顺序画，侧栏放旁边", () {
      var plan = planCapture(
        player: player,
        chosen: {CaptureLayer.danmaku},
        overlays: overlays,
        panel: const Rect.fromLTWH(900, 50, 300, 450),
      );
      expect(plan.order, [CaptureLayer.player, CaptureLayer.danmaku]);
      expect(plan.size, const Size(800, 450));

      var all = planCapture(
        player: player,
        chosen: {
          CaptureLayer.sidePanel,
          CaptureLayer.gifts,
          CaptureLayer.superChat,
          CaptureLayer.videoStats,
          CaptureLayer.danmaku,
        },
        overlays: overlays,
        panel: const Rect.fromLTWH(900, 50, 300, 450),
      );
      expect(all.order, [
        CaptureLayer.player,
        CaptureLayer.danmaku,
        CaptureLayer.videoStats,
        CaptureLayer.superChat,
        CaptureLayer.superChat,
        CaptureLayer.gifts,
        CaptureLayer.sidePanel,
      ]);
      expect(all.pieces[4].index, 1);
      // 位置相对播放器；侧栏紧挨在右边
      expect(all.pieces[2].dst, const Rect.fromLTWH(8, 8, 120, 80));
      expect(all.pieces.last.dst, const Rect.fromLTWH(800, 0, 300, 450));
      expect(all.size, const Size(1100, 450));
    });

    test("手机竖屏：聊天区在下面，中间的主播信息不要；看不见的层不画", () {
      var plan = planCapture(
        player: const Rect.fromLTWH(0, 80, 400, 225),
        chosen: {CaptureLayer.sidePanel, CaptureLayer.videoStats},
        panel: const Rect.fromLTWH(0, 380, 400, 500),
      );
      expect(plan.order, [CaptureLayer.player, CaptureLayer.sidePanel]);
      expect(plan.pieces.last.dst, const Rect.fromLTWH(0, 225, 400, 500));
      expect(plan.size, const Size(400, 725));
    });

    test("截图范围：完整窗口时页面垫底、成图是整个页面，侧栏不另外拼", () {
      var plan = planCapture(
        player: player,
        chosen: {CaptureLayer.danmaku, CaptureLayer.sidePanel},
        overlays: overlays,
        panel: const Rect.fromLTWH(900, 50, 300, 450),
        page: const Rect.fromLTWH(0, 0, 1200, 600),
      );
      expect(plan.order, [
        CaptureLayer.page,
        CaptureLayer.player,
        CaptureLayer.danmaku,
      ]);
      expect(plan.size, const Size(1200, 600));
      expect(plan.player, player);
    });

    test("视频按原始清晰度放大，帧摆在播放器里（适应、16:9）", () {
      var plan = planCapture(
        player: player,
        chosen: const {},
        frame: const Size(1920, 1080),
        devicePixelRatio: 1.5,
      );
      expect(plan.scale, closeTo(2.4, 1e-9));
      expect(plan.videoDst, const Rect.fromLTWH(0, 0, 800, 450));
      var (src, dst) = videoRectIn(
        const Size(800, 450),
        const Size(1080, 1920),
      );
      expect(src, const Rect.fromLTWH(0, 0, 1080, 1920));
      expect(dst.height, 450);
      expect(dst.center, const Offset(400, 225));
    });

    test("像素上限：手机竖屏截 1080p 到原画；长边最多 8192，总像素最多 40 MP", () {
      // 手机竖屏：播放器宽 393，dpr 2.75，1080p 源
      const phone = Rect.fromLTWH(0, 80, 393, 393 * 9 / 16);
      var plan = planCapture(
        player: phone,
        chosen: const {},
        frame: const Size(1920, 1080),
        devicePixelRatio: 2.75,
      );
      expect((plan.pixelWidth, plan.pixelHeight), (1920, 1080));
      // 小窗口里的 4K 也到原画
      var tiny = planCapture(
        player: const Rect.fromLTWH(0, 0, 320, 180),
        chosen: const {},
        frame: const Size(3840, 2160),
      );
      expect((tiny.pixelWidth, tiny.pixelHeight), (3840, 2160));
      // 完整窗口很宽：长边到 8192 为止
      var wide = planCapture(
        player: const Rect.fromLTWH(0, 0, 320, 180),
        chosen: const {},
        page: const Rect.fromLTWH(0, 0, 2000, 400),
        frame: const Size(3840, 2160),
      );
      expect(wide.pixelWidth, 8192);
      expect(wide.pixelHeight, 1638);
      // 完整窗口又大又方：总像素到 40 MP 为止
      var big = planCapture(
        player: const Rect.fromLTWH(0, 0, 320, 180),
        chosen: const {},
        page: const Rect.fromLTWH(0, 0, 1200, 900),
        frame: const Size(3840, 2160),
      );
      expect(big.pixelWidth, lessThan(8192));
      expect(big.pixelWidth * big.pixelHeight, closeTo(40000000, 20000));
    });

    test("截图尺寸选“和屏幕一样”：只按屏幕的倍数", () {
      var plan = planCapture(
        player: const Rect.fromLTWH(0, 80, 393, 393 * 9 / 16),
        chosen: const {},
        frame: const Size(1920, 1080),
        devicePixelRatio: 2.75,
        imageSize: CaptureImageSize.screen,
      );
      expect(plan.scale, 2.75);
      expect((plan.pixelWidth, plan.pixelHeight), (1081, 608));
    });

    test("画的时候后画的盖住先画的（假图片）", () async {
      Future<ui.Image> solid(Color color, int w, int h) {
        var recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
            Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
            Paint()..color = color);
        return recorder.endRecording().toImage(w, h);
      }

      var plan = planCapture(
        player: const Rect.fromLTWH(0, 0, 40, 20),
        chosen: {
          CaptureLayer.danmaku,
          CaptureLayer.videoStats,
          CaptureLayer.sidePanel,
        },
        overlays: const {
          CaptureLayer.danmaku: [Rect.fromLTWH(0, 0, 20, 20)],
          CaptureLayer.videoStats: [Rect.fromLTWH(0, 0, 10, 10)],
        },
        panel: const Rect.fromLTWH(40, 0, 10, 20),
        frame: const Size(40, 20),
      );
      var image = await paintCapture(
        plan,
        video: await solid(const Color(0xFFFF0000), 40, 20),
        images: {
          plan.pieces[1]: await solid(const Color(0xFF00FF00), 20, 20),
          plan.pieces[2]: await solid(const Color(0xFF0000FF), 10, 10),
          plan.pieces[3]: await solid(const Color(0xFFFFFF00), 10, 20),
        },
      );
      expect(image.width, 50);
      var bytes = (await image.toByteData())!;
      int at(int x, int y) => bytes.getUint32((y * 50 + x) * 4);
      expect(at(5, 5), 0x0000FFFF); // 视频信息在最上面
      expect(at(15, 15), 0x00FF00FF); // 弹幕盖住视频
      expect(at(30, 10), 0xFF0000FF); // 只有视频
      expect(at(45, 10), 0xFFFF00FF); // 侧栏在右边
    });
  });

  group("文件名和图片信息", () {
    final meta = CaptureMeta(
      siteId: "bilibili",
      siteName: "哔哩哔哩",
      roomId: "21452505",
      title: "晚上好 / 一起看",
      streamer: "主播:小明?",
      url: "https://live.bilibili.com/21452505",
      time: DateTime(2026, 11, 19, 20, 3, 12),
      software: "Simple Live 1.25.0",
    );

    test("主播_平台_年月日_时分秒，去掉文件名里不能用的字符", () {
      expect(meta.baseName, "主播_小明_哔哩哔哩_20261119_200312");
      expect(safeFileName("  a<b>c|d  "), "a_b_c_d");
      var dir = Directory.systemTemp.createTempSync("capture_name");
      addTearDown(() => dir.deleteSync(recursive: true));
      var first = uniqueCaptureFile(dir, meta.baseName, "png")
        ..writeAsStringSync("x");
      expect(p.basename(first.path), "${meta.baseName}.png");
      expect(p.basename(uniqueCaptureFile(dir, meta.baseName, "png").path),
          "${meta.baseName}_2.png");
    });

    test("PNG 里写文字（中文用 iTXt）和 EXIF，都在图像数据前面", () async {
      var recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 2, 2),
          Paint()..color = const Color(0xFF123456));
      var image = await recorder.endRecording().toImage(2, 2);
      var png = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();

      var out = PngMeta.embedMeta(png, meta);
      // 每一块的 CRC（类型 + 数据）都对，严格的读图程序才不会丢掉这些块
      var at = 8;
      while (at + 12 <= out.length) {
        var view = ByteData.sublistView(out);
        var length = view.getUint32(at);
        var stored = view.getUint32(at + 8 + length);
        expect(stored, getCrc32(out.sublist(at + 4, at + 8 + length)),
            reason: String.fromCharCodes(out.sublist(at + 4, at + 8)));
        at += 12 + length;
      }
      expect(at, out.length);
      var types = [for (var (type, _) in PngMeta.chunks(out)) type];
      expect(types.first, "IHDR");
      expect(types.indexOf("eXIf"), lessThan(types.indexOf("IDAT")));
      expect(types, contains("iTXt"));
      expect(types.last, "IEND");

      var text = PngMeta.readText(out);
      expect(text["Title"], "晚上好 / 一起看");
      expect(text["Author"], "主播:小明?");
      expect(text["Software"], "Simple Live 1.25.0");
      expect(text["Platform"], "bilibili");
      expect(text["Room ID"], "21452505");
      expect(text["URL"], "https://live.bilibili.com/21452505");
      expect(text["Description"], contains("21452505"));
      expect(text["Creation Time"], startsWith("2026-11-19T20:03:12"));

      var exif = PngMeta.chunks(out).firstWhere((e) => e.$1 == "eXIf").$2;
      var ifd0 = Exif.readIfd(exif);
      String ascii(Uint8List b) => utf8.decode(b.sublist(0, b.length - 1));
      String ucs2(Uint8List b) => String.fromCharCodes([
            for (var i = 0; i + 3 < b.length; i += 2) b[i] | (b[i + 1] << 8),
          ]);
      expect(ascii(ifd0[Exif.tagSoftware]!), "Simple Live 1.25.0");
      expect(ascii(ifd0[Exif.tagArtist]!), "主播:小明?");
      expect(ascii(ifd0[Exif.tagDateTime]!), "2026:11:19 20:03:12");
      expect(ucs2(ifd0[Exif.tagXPTitle]!), "晚上好 / 一起看");
      var exifIfd = Exif.readIfd(exif, exifIfd: true);
      expect(ascii(exifIfd[Exif.tagDateTimeOriginal]!), "2026:11:19 20:03:12");
      expect(
          exifIfd[Exif.tagUserComment]!.sublist(0, 8), ascii8("UNICODE\u0000"));
    });
  });

  group("截图、录屏之后", () {
    late _Sink sink;
    late List<String> toasts;
    late List<CaptureResult> asked;
    CaptureChoice? answer;

    CaptureFlow flow() => CaptureFlow(
          sink: sink,
          toast: toasts.add,
          ask: (result, canCopy) async {
            asked.add(result);
            return answer;
          },
        );

    setUp(() {
      sink = _Sink();
      toasts = [];
      asked = [];
      answer = null;
    });

    final image = CaptureResult.image(Uint8List.fromList([1, 2, 3]),
        baseName: "a_b_20261119_200312");
    const video = CaptureResult.video(["/x/a.mkv", "/x/a.ass"], baseName: "a");

    test("直接保存、复制；复制不了或没成功时改成保存", () async {
      await flow().finish(image, CaptureAfterAction.save);
      expect(sink.calls, ["save"]);
      expect(toasts.last, "截图已保存：/saved");

      sink = _Sink(canCopy: true, copyOk: true);
      await flow().finish(image, CaptureAfterAction.copy);
      expect(sink.calls, ["copy"]);
      expect(toasts.last, "已复制到剪贴板");

      sink = _Sink(canCopy: true, copyOk: false);
      await flow().finish(image, CaptureAfterAction.copy);
      expect(sink.calls, ["copy", "save"]);
      expect(toasts.last, "复制没成功，已保存：/saved");

      sink = _Sink(canCopy: false);
      await flow().finish(video, CaptureAfterAction.copy);
      expect(sink.calls, ["save"]);
      expect(asked, isEmpty);
    });

    test("询问：选什么做什么；关掉窗口什么都不做；iOS 已存进相册时不问", () async {
      answer = CaptureChoice.delete;
      await flow().finish(video, CaptureAfterAction.ask);
      expect(asked, [video]);
      expect(sink.calls, ["delete"]);

      sink = _Sink();
      answer = null;
      await flow().finish(image, CaptureAfterAction.ask);
      expect(sink.calls, isEmpty);

      asked.clear();
      await flow().finish(
        const CaptureResult.video([], baseName: "a", savedToAlbum: true),
        CaptureAfterAction.ask,
      );
      expect(asked, isEmpty);
      expect(toasts.last, "录屏已存到相册");
    });

    test("GIF：原生端有 copyGif 时显示复制、用 copyGif（设成直接复制也是）；没有时复制文件；视频不变",
        () async {
      var messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = <MethodCall>[];
      var hasGif = true;
      messenger.setMockMethodCallHandler(NativeCapture.channel, (call) async {
        calls.add(call);
        if (call.method == "copyGif") {
          if (!hasGif) throw MissingPluginException();
          return (call.arguments as Map)["path"] != "";
        }
        return call.method != "recordActive";
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(NativeCapture.channel, null);
        NativeCapture.resetForTest();
      });
      NativeCapture.resetForTest();
      var offered = <bool>[];
      var flow = CaptureFlow(
        sink: DefaultCaptureSink(),
        toast: toasts.add,
        ask: (result, canCopy) async {
          offered.add(canCopy);
          return CaptureChoice.copy;
        },
      );
      const gif = CaptureResult.video(["/x/a.gif"], baseName: "a");
      List<String> sent() =>
          [for (var c in calls) "${c.method} ${c.arguments}"];

      await flow.finish(gif, CaptureAfterAction.ask);
      expect(offered, [true]);
      expect(sent(), [
        "recordActive null",
        "copyGif {path: }",
        "copyGif {path: /x/a.gif}",
      ]);
      expect(toasts.last, "已复制到剪贴板");

      calls.clear();
      await flow.finish(gif, CaptureAfterAction.copy);
      expect(sent(), ["copyGif {path: /x/a.gif}"]);

      calls.clear();
      await flow.finish(video, CaptureAfterAction.copy);
      expect(sent(), ["copyFiles {paths: [/x/a.mkv, /x/a.ass]}"]);

      // 旧版原生端没有 copyGif
      hasGif = false;
      NativeCapture.resetForTest();
      calls.clear();
      await flow.finish(gif, CaptureAfterAction.copy);
      expect(sent(), [
        "recordActive null",
        "copyGif {path: }",
        "copyFiles {paths: [/x/a.gif]}",
      ]);
    }, skip: Platform.isLinux ? "Linux 用 wl-copy、xclip，不走原生接口" : null);
  });

  group("流录制", () {
    test("开始、停止设 mpv 的 stream-record；弹幕文件和视频同名；重新打开流时换文件", () async {
      var dir = Directory.systemTemp.createTempSync("stream_record");
      addTearDown(() => dir.deleteSync(recursive: true));
      var calls = <(String, String)>[];
      var sidecars = <String>[];
      var stopped = <String>[];
      var reopened = StreamController<Object?>();
      var session = StreamRecordSession(
        setProperty: (name, value) async {
          calls.add((name, value));
          // 像 mpv 一样把收到的数据写进文件
          if (value.isNotEmpty) File(value).writeAsBytesSync([1, 2, 3]);
        },
        startSidecar: (path) async {
          sidecars.add(path);
          File(path).writeAsStringSync("[Script Info]");
          return _Sidecar(() => stopped.add(path));
        },
      );
      var video = p.join(dir.path, "主播_平台_20261119_200312.mkv");
      await session.start(video, reopened: reopened.stream);
      expect(calls, [("stream-record", video)]);
      expect(sidecars, [p.join(dir.path, "主播_平台_20261119_200312.ass")]);

      reopened.add(null);
      await Future<void>.delayed(Duration.zero);
      var second = p.join(dir.path, "主播_平台_20261119_200312_2.mkv");
      expect(calls.last, ("stream-record", second));
      expect(sidecars.last, StreamRecordSession.sidecarPath(second));
      expect(stopped, [sidecars.first]);

      var files = await session.stop();
      expect(calls.last, ("stream-record", ""));
      expect(stopped, sidecars);
      expect(files, [video, second, ...sidecars]);
      await reopened.close();
    });

    test("流录制只存视频：选了弹幕也不写 .ass，不调 startSidecar", () async {
      MemoryStorage.install();
      expect(CaptureSettings.instance.danmaku.value, isTrue);
      var dir = Directory.systemTemp.createTempSync("stream_no_ass");
      addTearDown(() => dir.deleteSync(recursive: true));
      var host = _Host();
      var recorder = StreamCaptureRecorder(
        host,
        setProperty: (name, value) async {
          if (value.isNotEmpty) File(value).writeAsBytesSync([1, 2, 3]);
        },
      );
      var video = p.join(dir.path, "a.mkv");
      expect(await recorder.start(video, const CaptureRecordRequest()), isTrue);
      var result = await recorder.stop("a");
      expect(result?.files, [video]);
      expect(host.sidecars, 0);
      expect(dir.listSync().map((e) => p.extension(e.path)), [".mkv"]);
    });
  });

  group("设置和同步", () {
    test("默认值；改了存下来；图层等进 WebDAV 的扩展部分，保存位置只在本机", () {
      var storage = MemoryStorage.install();
      var s = CaptureSettings.instance;
      // 默认只有弹幕
      expect(s.chosenLayers, {CaptureLayer.danmaku});
      expect(s.range.value, CaptureRange.player);
      expect(s.fullscreenButtons.value, isFalse);
      expect(s.maxSeconds.value, 120);
      expect(s.maxDuration, const Duration(minutes: 2));
      expect(s.recordFormat.value, CaptureRecordFormat.video);
      expect(s.metadata.value, isTrue);
      expect(s.afterAction.value, CaptureAfterAction.ask);
      expect(s.imageSize.value, CaptureImageSize.source);

      s.setLayer(CaptureLayer.sidePanel, true);
      s.setRange(CaptureRange.window);
      s.setImageSize(CaptureImageSize.screen);
      s.setFullscreenButtons(true);
      s.setSaveDir(r"D:\shots");
      s.setVideoStatsFields(["fps", "drops"]);
      CaptureSettings.reset();
      s = CaptureSettings.instance;
      expect(s.sidePanel.value, isTrue);
      expect(s.range.value, CaptureRange.window);
      expect(s.includes(CaptureLayer.page), isTrue);
      expect(s.imageSize.value, CaptureImageSize.screen);
      expect(storage.values, contains(CaptureSettings.kImageSize));
      expect(s.fullscreenButtons.value, isTrue);
      expect(s.videoStatsFields, ["fps", "drops"]);

      var settings = Map<String, dynamic>.from(storage.values);
      settings[LocalStorageService.kThemeMode] = 1;
      var ext = SyncCompat.extSettings(settings);
      var upstream = SyncCompat.upstreamSettings(settings);
      for (var key in CaptureSettings.syncKeys) {
        if (settings.containsKey(key)) {
          expect(ext, contains(key));
        }
        expect(upstream, isNot(contains(key)));
      }
      expect(ext, isNot(contains(CaptureSettings.kSaveDir)));
      expect(upstream, isNot(contains(CaptureSettings.kSaveDir)));
      var merged = SyncCompat.mergeRestoredSettings(
        {CaptureSettings.kSaveDir: r"D:\mine"},
        {},
        {CaptureSettings.kSaveDir: r"D:\theirs", CaptureSettings.kRange: 0},
      );
      expect(merged[CaptureSettings.kSaveDir], r"D:\mine");
      expect(merged[CaptureSettings.kRange], 0);
    });

    test("录屏方式：画面录制开着时默认画面录制（有原生录屏时），没有时自动用流录制", () async {
      CaptureFeatures.debugScreenRecording = true;
      MemoryStorage.install();
      var capture = CaptureController(
        host: _Host(),
        flow: CaptureFlow(
          sink: _Sink(),
          toast: (_) {},
          ask: (_, __) async => null,
        ),
        recordDir: () async => Directory.systemTemp,
      );
      expect(
          CaptureSettings.instance.recordMode.value, CaptureRecordMode.screen);
      expect(CaptureSettings.instance.danmaku.value, isTrue);
      // 没有原生接口（Linux、旧版原生端）
      NativeCapture.resetForTest();
      expect(await capture.effectiveMode(), CaptureRecordMode.stream);
      // 有原生接口
      var messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          NativeCapture.channel, (call) async => false);
      addTearDown(() {
        messenger.setMockMethodCallHandler(NativeCapture.channel, null);
        NativeCapture.resetForTest();
      });
      NativeCapture.resetForTest();
      expect(
          await capture.effectiveMode(),
          Platform.isLinux
              ? CaptureRecordMode.stream
              : CaptureRecordMode.screen);
      // 选了流录制就用流录制
      CaptureSettings.instance.setRecordMode(CaptureRecordMode.stream);
      expect(await capture.effectiveMode(), CaptureRecordMode.stream);
      // 画面录制关着（1.26.0）：选了、也有原生接口，还是流录制
      CaptureSettings.instance.setRecordMode(CaptureRecordMode.screen);
      CaptureFeatures.debugScreenRecording = false;
      expect(await capture.effectiveMode(), CaptureRecordMode.stream);
    });

    test("最长录制时间：只有 30 秒、1、2 分钟；存着的更长或以前的“不限”按 2 分钟", () {
      expect(CaptureSettings.maxSecondsOptions, [30, 60, 120]);
      expect(CaptureSettings.defaultMaxSeconds, 120);
      var storage = MemoryStorage.install();
      int load(Map<String, int> stored) {
        storage.values
          ..clear()
          ..addAll(stored);
        CaptureSettings.reset();
        return CaptureSettings.instance.maxSeconds.value;
      }

      expect(load({}), 120);
      // 以前的测试版存的是分钟
      expect(load({CaptureSettings.kMaxMinutes: 10}), 120);
      expect(load({CaptureSettings.kMaxMinutes: 0}), 120);
      expect(load({CaptureSettings.kMaxMinutes: 1}), 60);
      expect(load({CaptureSettings.kMaxSeconds: 600}), 120);
      expect(load({CaptureSettings.kMaxSeconds: 90}), 60);
      expect(load({CaptureSettings.kMaxSeconds: 30}), 30);
      expect(
        load(
            {CaptureSettings.kMaxSeconds: 30, CaptureSettings.kMaxMinutes: 10}),
        30,
      );

      // 只能改短
      load({});
      var s = CaptureSettings.instance;
      s.setMaxSeconds(30);
      expect(s.maxDuration, const Duration(seconds: 30));
      expect(storage.values[CaptureSettings.kMaxSeconds], 30);
      s.setMaxSeconds(300);
      expect(s.maxSeconds.value, 120);
      expect(storage.values[CaptureSettings.kMaxSeconds], 120);
      expect(CaptureSettings.syncKeys, contains(CaptureSettings.kMaxSeconds));
    });

    test("画面录制的范围：直播画面（加侧栏）或整个窗口", () {
      const view = Size(2400, 1350);
      var player = captureRecordRect(
        range: CaptureRange.player,
        fullscreen: false,
        player: const Rect.fromLTWH(0, 56, 1300, 731.25),
        panel: const Rect.fromLTWH(1300, 56, 300, 800),
        viewSize: view,
        devicePixelRatio: 1.5,
      );
      expect(player, const Rect.fromLTRB(0, 84, 2400, 1284));
      var window = captureRecordRect(
        range: CaptureRange.window,
        fullscreen: false,
        player: const Rect.fromLTWH(0, 56, 1300, 731.25),
        viewSize: view,
        devicePixelRatio: 1.5,
      );
      expect(window, Offset.zero & view);
    });
  });

  group("录屏开关", () {
    test("1.26.0 只有流录制：存着的画面录制也用流录制；两种都关着时什么都不做", () async {
      expect(CaptureFeatures.streamRecordingEnabled, isTrue);
      expect(CaptureFeatures.screenRecordingEnabled, isFalse);
      expect(CaptureFeatures.recording, isTrue);
      var storage = MemoryStorage.install();
      storage.values[CaptureSettings.kRecordMode] =
          CaptureRecordMode.screen.index;
      var recorder = _Recorder();
      var modes = <CaptureRecordMode>[];
      CaptureController build() => CaptureController(
            host: _Host(),
            flow: CaptureFlow(
              sink: _Sink(),
              toast: (_) {},
              ask: (_, __) async => null,
            ),
            recordDir: () async => Directory.systemTemp,
            recorderFor: (mode) {
              modes.add(mode);
              return recorder;
            },
            timer: (d, f) => Timer(Duration.zero, () {}),
          );

      var capture = build();
      await capture.startRecording();
      expect(capture.recording.value, isTrue);
      expect(modes, [CaptureRecordMode.stream]);
      await capture.stopRecording();

      CaptureFeatures.debugStreamRecording = false;
      expect(CaptureFeatures.recording, isFalse);
      recorder.request = null;
      capture = build();
      await capture.startRecording();
      expect(capture.recording.value, isFalse);
      expect(recorder.request, isNull);
      expect(storage.values[CaptureSettings.kRecordMode], 1);
    });
  });

  group("原生端自己停下录屏（onRecordStopped）", () {
    late _Sink sink;
    late List<String> toasts;
    late int asked;
    late CaptureController capture;

    setUp(() async {
      // 画面录制开着的版本
      CaptureFeatures.debugScreenRecording = true;
      MemoryStorage.install();
      sink = _Sink();
      toasts = [];
      asked = 0;
      capture = CaptureController(
        host: _Host(),
        flow: CaptureFlow(
          sink: sink,
          toast: toasts.add,
          ask: (_, __) async {
            asked++;
            return CaptureChoice.save;
          },
        ),
        recordDir: () async => Directory.systemTemp,
        recorderFor: (_) => _Recorder(native: true),
        timer: (d, f) => Timer(Duration.zero, () {}),
      );
      await capture.startRecording();
      expect(capture.recording.value, isTrue);
    });

    test("到了上限：直接保存，不问", () async {
      await capture.handleNativeStop({
        "reason": "limit",
        "path": "/x/a.mp4",
        "durationMs": 120000,
        "bytes": 1000,
        "audio": true,
      });
      expect(capture.recording.value, isFalse);
      expect(sink.calls, ["save"]);
      expect(asked, 0);
      expect(toasts.last, "已到最长录制时间，录屏已保存：/saved");
    });

    test("转屏等别的原因：说明停了的原因，再按设置问一下；没录到声音时也说", () async {
      await capture.handleNativeStop({
        "reason": "rotation",
        "path": "/x/a.mp4",
        "durationMs": 5000,
        "audio": false,
      });
      expect(capture.recording.value, isFalse);
      expect(toasts.first, "录屏已停止（屏幕旋转了），没有录到声音");
      expect(asked, 1);
      expect(sink.calls, ["save"]);
    });
  });

  group("到最长录制时间", () {
    test("自动停下并直接保存，不问（假的时钟）", () async {
      MemoryStorage.install();
      var dir = Directory.systemTemp.createTempSync("capture_limit");
      addTearDown(() => dir.deleteSync(recursive: true));
      var timers = <(Duration, void Function())>[];
      var clock = DateTime(2026, 11, 19, 20);
      var sink = _Sink();
      var toasts = <String>[];
      var asked = 0;
      var recorder = _Recorder();
      var capture = CaptureController(
        host: _Host(),
        flow: CaptureFlow(
          sink: sink,
          toast: toasts.add,
          ask: (_, __) async {
            asked++;
            return CaptureChoice.delete;
          },
        ),
        recordDir: () async => dir,
        recorderFor: (_) => recorder,
        timer: (d, f) {
          timers.add((d, f));
          return Timer(Duration.zero, () {});
        },
        now: () => clock,
      );

      await capture.startRecording();
      expect(capture.recording.value, isTrue);
      expect(recorder.request?.maxSeconds, 120);
      var limit = timers.firstWhere((e) => e.$1 == const Duration(minutes: 2));
      // 每秒的时间
      clock = clock.add(const Duration(seconds: 65));
      timers.firstWhere((e) => e.$1 == const Duration(seconds: 1)).$2();
      expect(capture.elapsedText, "01:05");

      clock = clock.add(const Duration(seconds: 55));
      limit.$2();
      await pumpEventQueue();
      expect(capture.recording.value, isFalse);
      expect(recorder.stopped, isTrue);
      expect(sink.calls, ["save"]);
      expect(asked, 0);
      expect(toasts.last, "已到最长录制时间，录屏已保存：/saved");
    });

    test("存成 GIF 时最长 1 分钟：设了 2 分钟也在 1 分钟时停下保存；设得更短按设置", () async {
      MemoryStorage.install();
      var s = CaptureSettings.instance;
      s.setRecordFormat(CaptureRecordFormat.gif);
      expect(s.maxSeconds.value, 120);
      expect(s.maxDuration, const Duration(minutes: 1));
      expect(s.recordLimit(gif: false), const Duration(minutes: 2));

      var timers = <(Duration, void Function())>[];
      var sink = _Sink();
      var toasts = <String>[];
      var recorder = _Recorder();
      var capture = CaptureController(
        host: _Host(),
        flow: CaptureFlow(
          sink: sink,
          toast: toasts.add,
          ask: (_, __) async => CaptureChoice.delete,
        ),
        recordDir: () async => Directory.systemTemp,
        recorderFor: (_) => recorder,
        timer: (d, f) {
          timers.add((d, f));
          return Timer(Duration.zero, () {});
        },
      );
      await capture.startRecording();
      expect(recorder.request?.maxSeconds, 60);
      var limit = timers.firstWhere((e) => e.$1 == const Duration(minutes: 1));
      expect(timers.where((e) => e.$1 == const Duration(minutes: 2)), isEmpty);
      limit.$2();
      await pumpEventQueue();
      expect(capture.recording.value, isFalse);
      expect(sink.calls, ["save"]);
      expect(toasts.last, "已到最长录制时间，录屏已保存：/saved");

      s.setMaxSeconds(30);
      expect(s.maxDuration, const Duration(seconds: 30));
      timers.clear();
      await capture.startRecording();
      expect(recorder.request?.maxSeconds, 30);
      expect(timers.map((e) => e.$1), contains(const Duration(seconds: 30)));
      await capture.stopRecording();
    });

    test("默认的录屏器：选了 GIF 时是 GifCaptureRecorder（.gif），否则流录制（.mkv）", () {
      MemoryStorage.install();
      var capture = CaptureController(
        host: _Host(),
        flow: CaptureFlow(
            sink: _Sink(), toast: (_) {}, ask: (_, __) async => null),
        recordDir: () async => Directory.systemTemp,
      );
      expect(capture.recorderFor(CaptureRecordMode.stream).extension, "mkv");
      CaptureSettings.instance.setRecordFormat(CaptureRecordFormat.gif);
      var gif = capture.recorderFor(CaptureRecordMode.stream);
      expect(gif, isA<GifCaptureRecorder>());
      expect(gif.extension, "gif");
    });
  });
}

List<int> ascii8(String s) => s.codeUnits;

class _Sink implements CaptureSink {
  final bool _canCopy;
  final bool copyOk;
  final calls = <String>[];
  _Sink({bool canCopy = false, this.copyOk = false}) : _canCopy = canCopy;

  @override
  Future<bool> canCopy(CaptureResult result) async => _canCopy;

  @override
  Future<bool> copy(CaptureResult result) async {
    calls.add("copy");
    return copyOk;
  }

  @override
  Future<void> delete(CaptureResult result) async => calls.add("delete");

  @override
  Future<String> save(CaptureResult result) async {
    calls.add("save");
    return "/saved";
  }
}

class _Sidecar implements CaptureSidecar {
  final void Function() onStop;
  _Sidecar(this.onStop);

  @override
  Future<void> stop() async => onStop();
}

class _Recorder implements CaptureRecorder {
  CaptureRecordRequest? request;
  bool stopped = false;

  @override
  final bool native;
  _Recorder({this.native = false});

  @override
  String get extension => "mkv";

  @override
  Future<bool> start(String path, CaptureRecordRequest request) async {
    this.request = request;
    return true;
  }

  @override
  Future<CaptureResult?> stop(String baseName) async {
    stopped = true;
    return CaptureResult.video(["/x/$baseName.mkv"], baseName: baseName);
  }
}

class _Host implements CaptureHost {
  @override
  final Player player = FakePlayer();

  @override
  CaptureMeta meta() => CaptureMeta(
        siteId: "test",
        siteName: "测试",
        roomId: "1",
        title: "标题",
        streamer: "主播",
        url: "",
        time: DateTime(2026, 11, 19, 20),
      );

  @override
  BoxFit get videoFit => BoxFit.contain;

  @override
  double? get videoAspectRatio => null;

  @override
  bool get fullscreen => false;

  @override
  Stream<Object?>? get reopened => null;

  /// 要过几次弹幕文件
  int sidecars = 0;

  @override
  Future<CaptureSidecar?> startSidecar(String assPath) async {
    sidecars++;
    return null;
  }
}
