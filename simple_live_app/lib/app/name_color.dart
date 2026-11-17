import 'dart:math';

import 'package:flutter/material.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 把颜色调到在当前背景上看得清：深色背景上太暗的提亮、浅色背景上太亮的压暗，
/// 只改亮度，色相不变（Twitch 网页对名字颜色也是这样做的）。
///
/// 按对比度算（和背景至少 [minContrast] 比 1，4.5 是无障碍标准里正文的要求），
/// 不按颜色本身的明暗：纯蓝看着亮，其实很暗，要比别的颜色多提亮不少才看得清。
/// 本来就看得清的颜色不动。
Color readableColor(
  Color color, {
  required bool dark,
  double minContrast = 4.5,
}) {
  // 背景的亮度：深色页面和视频按接近黑算，浅色页面按白算
  double contrastOf(Color c) {
    var luminance = c.computeLuminance();
    return dark ? (luminance + 0.05) / 0.06 : 1.05 / (luminance + 0.05);
  }

  if (contrastOf(color) >= minContrast) {
    return color;
  }
  var hsl = HSLColor.fromColor(color);
  var lightness = hsl.lightness;
  var result = color;
  for (var i = 0; i < 40; i++) {
    lightness =
        dark ? min(1.0, lightness + 0.025) : max(0.0, lightness - 0.025);
    result = hsl.withLightness(lightness).toColor();
    if (contrastOf(result) >= minContrast) {
      break;
    }
  }
  return result;
}

/// 聊天区里用户名的颜色：发言人自己选的颜色（Twitch、Kick），调到在当前背景上看得清。
/// 没有颜色时返回 null（用原来的灰色）。
Color? chatNameColor(LiveMessageColor? color, {required bool dark}) {
  if (color == null) return null;
  return readableColor(
    Color.fromARGB(255, color.r, color.g, color.b),
    dark: dark,
  );
}
