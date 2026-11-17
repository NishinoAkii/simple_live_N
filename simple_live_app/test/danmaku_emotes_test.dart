import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/danmaku_emotes.dart';
import 'package:simple_live_app/widgets/emote_text.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 不读本地存储的设置
class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

int _handles(ui.Image image) => image.debugGetOpenHandleStackTraces()!.length;

/// 直播间：记下上到视频的弹幕（不需要播放器）
class _Room extends LiveRoomController {
  _Room()
      : super(
          pSite: Site(id: "test", liveSite: LiveSite(), logo: "", name: "测试"),
          pRoomId: "1",
        );
  final onVideo = <String>[];
  @override
  void addDanmaku(List<DanmakuContentItem> items) =>
      onVideo.addAll(items.map((e) => e.text));
}

void main() {
  // 测试里的网络请求都返回 400，不会真的访问网络
  TestWidgetsFlutterBinding.ensureInitialized();
  late _TestSettings settings;
  setUp(() {
    Get.testMode = true;
    settings = Get.put<AppSettingsController>(_TestSettings()) as _TestSettings;
    settings.danmuSize.value = 16;
    settings.danmuEmoteImage.value = true;
  });
  tearDown(() {
    DanmakuEmotes.instance.clear();
    Get.reset();
  });

  const doge = LiveEmote(text: "[doge]", url: "https://e/doge.png");
  const sticker = LiveEmote(
    text: "很蓝的啦",
    url: "https://e/big.png",
    width: 198,
    height: 60,
  );

  group('DanmakuEmotes', () {
    test('图片没解码好时是纯文字', () {
      var cache = DanmakuEmotes.instance;
      expect(cache.isReady("好[doge]", emotes: [doge]), isFalse);
      var item = cache.build("好[doge]", emotes: [doge]);
      expect(item.text, "好[doge]");
      expect(item.segments, isNull);
      expect(cache.isReady("没有表情"), isTrue);
    });

    testWidgets('解码好的表情排成图文段，大表情单独一张', (tester) async {
      var cache = DanmakuEmotes.instance;
      var image = await tester.runAsync(
        () => createTestImage(width: 40, height: 40),
      );
      var big = await tester.runAsync(
        () => createTestImage(width: 120, height: 36),
      );
      cache.debugPut(doge.url, image!);
      cache.debugPut(sticker.url, big!, sticker: true);

      expect(cache.isReady("好[doge]呀[doge]", emotes: [doge]), isTrue);
      var item = cache.build("好[doge]呀[doge]", emotes: [doge]);
      expect(item.segments!.map((e) => e.isImage), [
        false,
        true,
        false,
        true,
      ]);
      expect(item.segments!.first.text, "好");
      expect(item.sticker, isFalse);

      var stickerItem = cache.build(sticker.text, sticker: sticker);
      expect(stickerItem.sticker, isTrue);
      expect(stickerItem.segments!.single.aspectRatio, closeTo(120 / 36, 1e-6));

      // 关闭开关后是纯文字
      settings.danmuEmoteImage.value = false;
      expect(cache.build("好[doge]", emotes: [doge]).segments, isNull);
    });

    test('视频弹幕优先解码静态图', () {
      // 平台给出了静态图
      expect(
        DanmakuEmotes.frameUrl(
          const LiveEmote(
            text: "reeferSad",
            url: "https://cdn.7tv.app/emote/1/2x.webp",
            staticUrl: "https://cdn.7tv.app/emote/1/2x_static.webp",
          ),
        ),
        "https://cdn.7tv.app/emote/1/2x_static.webp",
      );
      // Twitch 原生表情改写成 /static/
      expect(
        DanmakuEmotes.frameUrl(
          const LiveEmote(
            text: "xqcSlam",
            url: "https://static-cdn.jtvnw.net/emoticons/v2/1/default/dark/2.0",
          ),
        ),
        "https://static-cdn.jtvnw.net/emoticons/v2/1/static/dark/2.0",
      );
      expect(DanmakuEmotes.frameUrl(doge), doge.url);
      // 没有缓存键时按地址缓存
      expect(emoteCacheKey(doge), isNull);
      expect(
        emoteCacheKey(
          const LiveEmote(
              text: "[捂脸]", url: "https://e/1?sig=a", cacheKey: "a/b"),
        ),
        hasLength(32),
      );
    });

    testWidgets('按静态图的地址取解码好的图片', (tester) async {
      var cache = DanmakuEmotes.instance;
      const animated = LiveEmote(
        text: "YESIDOTHINKSOr",
        url: "https://cdn.betterttv.net/emote/6/2x.webp",
        staticUrl: "https://cdn.betterttv.net/emote/6/static/2x.webp",
        spaced: true,
      );
      var image = await tester.runAsync(
        () => createTestImage(width: 40, height: 40),
      );
      cache.debugPut(animated.staticUrl!, image!);
      expect(cache.isReady("hi YESIDOTHINKSOr", emotes: [animated]), isTrue);
      var item = cache.build("hi YESIDOTHINKSOr", emotes: [animated]);
      expect(item.segments!.map((e) => e.isImage), [false, true]);
      // 动图地址本身没有解码过
      const other = LiveEmote(
        text: "YESIDOTHINKSOr",
        url: "https://cdn.betterttv.net/emote/6/2x.webp",
        spaced: true,
      );
      expect(cache.isReady("hi YESIDOTHINKSOr", emotes: [other]), isFalse);
    });

    test('一批弹幕里的表情比同时下载的多时排队，都能显示为图片', () async {
      // Steam 的聊天每 4 秒到一批，里面常有很多种没见过的表情
      var cache = DanmakuEmotes.instance;
      var image = await createTestImage(width: 40, height: 40, cache: false);
      var started = <String>[];
      var gate = Completer<void>();
      DanmakuEmotes.debugDecode = (url, px) async {
        started.add(url);
        await gate.future;
        return image.clone();
      };
      addTearDown(() {
        DanmakuEmotes.debugDecode = null;
        image.dispose();
      });
      var emotes = [
        for (var i = 0; i < 8; i++)
          LiveEmote(
            text: ":steam$i:",
            url:
                "https://community.fastly.steamstatic.com/economy/emoticonlarge/steam$i",
          ),
      ];
      var text = "gg ${emotes.map((e) => e.text).join("")}";
      var ready = cache.prepare(text, emotes: emotes);
      await Future<void>.delayed(Duration.zero);
      expect(started, hasLength(DanmakuEmotes.maxLoading));
      gate.complete();
      await ready;
      expect(started, hasLength(8));
      var item = cache.build(text, emotes: emotes);
      expect(item.segments!.where((e) => e.isImage), hasLength(8));
    });

    test('历史消息只进聊天区，不上视频弹幕', () {
      var room = _Room()..liveStatus.value = true;
      LiveMessage chat(String text, {bool history = false}) => LiveMessage(
            type: LiveMessageType.chat,
            userName: "a",
            message: text,
            color: LiveMessageColor.white,
            history: history,
          );
      room.onWSMessage(chat("进直播间之前的", history: true));
      room.onWSMessage(chat("新的"));
      expect(room.chatLog.length, 2);
      expect(room.onVideo, ["新的"]);
    });

    testWidgets('超过数量上限时淘汰最早的并释放', (tester) async {
      var cache = DanmakuEmotes.instance;
      var images = await tester.runAsync(() async {
        return [
          for (var i = 0; i <= DanmakuEmotes.maxEntries; i++)
            await createTestImage(width: 2, height: 2),
        ];
      });
      for (var i = 0; i < images!.length; i++) {
        cache.debugPut("https://e/$i.png", images[i]);
      }
      expect(cache.debugLength, DanmakuEmotes.maxEntries);
      expect(images.first.debugDisposed, isTrue);
      expect(images.last.debugDisposed, isFalse);
    });
  });

  testWidgets('弹幕上屏时 clone 图片，清空时释放', (tester) async {
    var image = await tester.runAsync(
      () => createTestImage(width: 40, height: 40, cache: false),
    );
    DanmakuController? controller;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 400,
          child: DanmakuScreen(
            createdController: (c) => controller = c,
            option: DanmakuOption(fontSize: 16),
          ),
        ),
      ),
    );
    expect(_handles(image!), 1);
    // 缓存持有的那一份
    var source = image.clone();
    controller!.addDanmaku(
      DanmakuContentItem(
        "好[doge]",
        segments: [
          const DanmakuSegment.text("好"),
          DanmakuSegment.image(source),
        ],
      ),
    );
    controller!.addDanmaku(
      DanmakuContentItem(
        "大表情",
        sticker: true,
        segments: [DanmakuSegment.image(source)],
      ),
    );
    controller!.addDanmaku(
      DanmakuContentItem("普通弹幕", type: DanmakuItemType.top),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    // 两条弹幕各持有一份
    expect(_handles(image), 4);

    // 缓存淘汰了它，屏幕上的弹幕照常画
    source.dispose();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(_handles(image), 3);

    controller!.clear();
    await tester.pump(const Duration(milliseconds: 16));
    expect(_handles(image), 1);
    image.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('图片画在弹幕文字后面', (tester) async {
    var red = await tester.runAsync(() {
      var completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        Uint8List.fromList([
          for (var i = 0; i < 32 * 32; i++) ...[255, 0, 0, 255],
        ]),
        32,
        32,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      return completer.future;
    });
    DanmakuController? controller;
    var key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 400,
              height: 200,
              child: DanmakuScreen(
                createdController: (c) => controller = c,
                option: DanmakuOption(fontSize: 20),
              ),
            ),
          ),
        ),
      ),
    );
    // 顶部弹幕居中显示，不随时间移动
    controller!.addDanmaku(
      DanmakuContentItem(
        "表情",
        type: DanmakuItemType.top,
        segments: [
          const DanmakuSegment.text("表情"),
          DanmakuSegment.image(red!),
        ],
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    var boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    var pixels = await tester.runAsync(() async {
      var image = await boundary.toImage();
      var data = await image.toByteData();
      image.dispose();
      return data!;
    });
    var redCount = 0;
    for (var i = 0; i < pixels!.lengthInBytes; i += 4) {
      if (pixels.getUint8(i) > 200 &&
          pixels.getUint8(i + 1) < 60 &&
          pixels.getUint8(i + 2) < 60) {
        redCount++;
      }
    }
    // 表情约 23×23（字号 20 的 1.15 倍）
    expect(redCount, greaterThan(300));
    controller!.clear();
    red.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 200));
  });

  test('聊天栏的大表情默认三行高，单独调整时按表情大小', () {
    EmoteImage image() =>
        emoteStickerSpan(sticker, fontSize: 14)!.child as EmoteImage;
    expect(image().height, 14 * 3);
    // 只调了大小、没打开单独调整：仍然随文字大小
    settings.emoteScale.value = 2.0;
    expect(image().height, 14 * 3);
    settings.emoteSizeSeparate.value = true;
    expect(image().height, 14 * 3 * 2.0);
    expect(settings.effectiveEmoteScale, 2.0);
  });

  testWidgets('聊天栏的表情显示为图片，关闭后是文字', (tester) async {
    Widget build() => MaterialApp(
          home: Material(
            child: Obx(
              () => Text.rich(
                emoteTextSpan("好[doge]", const [doge], fontSize: 14),
              ),
            ),
          ),
        );
    await tester.pumpWidget(build());
    expect(find.byType(EmoteImage), findsOneWidget);
    settings.danmuEmoteImage.value = false;
    await tester.pump();
    expect(find.byType(EmoteImage), findsNothing);
    expect(find.text("好[doge]", findRichText: true), findsOneWidget);
  });
}
