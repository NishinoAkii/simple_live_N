import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/name_color.dart';
import 'package:simple_live_app/modules/live_room/chat_log.dart';
import 'package:simple_live_core/simple_live_core.dart';

double lightnessOf(Color c) => HSLColor.fromColor(c).lightness;
double hueOf(Color c) => HSLColor.fromColor(c).hue;

void main() {
  test('没有名字颜色时用原来的灰色', () {
    expect(chatNameColor(null, dark: true), isNull);
  });

  test('深色背景上太暗的名字提亮到看得清，色相不变', () {
    // 纯蓝看着亮其实很暗，要提亮不少
    var blue = LiveMessageColor(0, 0, 255);
    var c = chatNameColor(blue, dark: true)!;
    expect(lightnessOf(c), greaterThanOrEqualTo(0.7));
    expect((c.computeLuminance() + 0.05) / 0.06, greaterThanOrEqualTo(4.5));
    expect(hueOf(c), closeTo(240, 1));
  });

  test('浅色背景上太亮的名字压暗；本来就合适的不变', () {
    var yellow = LiveMessageColor(255, 255, 0);
    expect(lightnessOf(chatNameColor(yellow, dark: false)!),
        lessThanOrEqualTo(0.43));
    var pink = LiveMessageColor(255, 105, 180); // lightness ~0.71
    var c = chatNameColor(pink, dark: true)!;
    expect(c.toARGB32() & 0xffffff, 0xff69b4);
  });

  test('聊天记录存到文件再读回来，名字颜色还在；没有的行不变长', () async {
    var store = MemoryChunkStore();
    var log =
        ChatLog(store: store, chunkSize: 4, hotChunks: 1, cachedChunks: 0);
    for (var i = 0; i < 20; i++) {
      log.add(
        LiveChatRecord(
          DateTime.fromMillisecondsSinceEpoch(1000 + i),
          LiveMessage(
            type: LiveMessageType.chat,
            userName: "u$i",
            message: "m$i",
            color: LiveMessageColor.white,
            nameColor: i.isEven ? LiveMessageColor(0x12, 0x34, 0x56) : null,
          ),
        ),
      );
    }
    for (var i = 0; i < 20; i++) {
      var m = log[i].message;
      expect(
        m.nameColor,
        i.isEven ? LiveMessageColor(0x12, 0x34, 0x56) : isNull,
        reason: "row $i",
      );
    }
  });
}
