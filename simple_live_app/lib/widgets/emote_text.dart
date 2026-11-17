import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/services/danmaku_emotes.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 聊天栏、SC 里的表情图片。
///
/// 行内表情约一行高（字号的 1.4 倍，平台标明的大表情 2.6 倍），
/// 整条的大表情（表情包弹幕、付费贴纸）约三行高；都随文字大小变化，
/// 再乘“表情大小”设置。
/// 关闭了“弹幕显示表情图片”或平台没有给出图片时显示文字。
/// 都在 Obx 中调用，开关变化时会刷新。

/// 是否显示表情图片
bool get emoteImagesEnabled =>
    AppSettingsController.instance.danmuEmoteImage.value;

/// “表情大小”设置（相对文字大小的倍数；没有单独调整时为 1）
double get _emoteScale => AppSettingsController.instance.effectiveEmoteScale;

/// 消息正文：表情显示为图片（WidgetSpan），其余是文字。
///
/// [style] 是正文的样式（颜色等），[fontSize] 是正文字号；
/// 图片加载失败时显示表情的文字，用同样的样式。
InlineSpan emoteTextSpan(
  String text,
  List<LiveEmote>? emotes, {
  required double fontSize,
  TextStyle? style,
}) {
  // 没有表情时不读开关（不依赖设置）；在 Obx 里只有表情时才订阅开关，
  // 所以调用方的 Obx 要另有可观察的值，或只在有表情时才用 Obx
  if (emotes == null || emotes.isEmpty || !emoteImagesEnabled) {
    return TextSpan(text: text, style: style);
  }
  var parts = splitLiveEmotes(text, emotes);
  if (!parts.any((e) => e.isEmote)) {
    return TextSpan(text: text, style: style);
  }
  var fallback = (style ?? const TextStyle()).copyWith(fontSize: fontSize);
  var scale = _emoteScale;
  return TextSpan(
    style: style,
    children: [
      for (var part in parts)
        if (part.isEmote)
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: EmoteImage(
              part.emote!,
              height: fontSize * (part.emote!.height >= 36 ? 2.6 : 1.4) * scale,
              fallbackStyle: fallback,
            ),
          )
        else
          TextSpan(text: part.text),
    ],
  );
}

/// 整条消息是一张大表情时的图片（WidgetSpan），关闭了表情图片时为 null
WidgetSpan? emoteStickerSpan(
  LiveEmote? sticker, {
  required double fontSize,
  TextStyle? style,
}) {
  if (sticker == null || !emoteImagesEnabled) {
    return null;
  }
  var scale = _emoteScale;
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: EmoteImage(
      sticker,
      height: fontSize * 3 * scale,
      maxWidth: fontSize * 12 * scale,
      fallbackStyle: (style ?? const TextStyle()).copyWith(fontSize: fontSize),
    ),
  );
}

/// 一张表情图片：加载中按图片大小留出位置，失败时显示表情的文字
class EmoteImage extends StatelessWidget {
  final LiveEmote emote;

  /// 显示高度；平台给出了宽高时按比例算出宽度，超过 [maxWidth] 时整体缩小
  final double height;
  final double? maxWidth;
  final TextStyle? fallbackStyle;

  const EmoteImage(
    this.emote, {
    required this.height,
    this.maxWidth,
    this.fallbackStyle,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    var ratio = emote.aspectRatio;
    var h = height;
    double? w = ratio == null ? null : h * ratio;
    var limit = maxWidth;
    if (w != null && limit != null && w > limit) {
      w = limit;
      h = limit / ratio!;
    }
    var dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2;
    // 默认只显示第一帧（和视频弹幕一样）：动图不按显示大小解码、一直在播，
    // 聊天刷得快时很占 CPU 和内存
    var url = AppSettingsController.instance.chatAnimatedEmotes.value
        ? emote.url
        : DanmakuEmotes.frameUrl(emote);
    return ExtendedImage.network(
      url,
      cacheKey: url == emote.url ? emoteCacheKey(emote) : null,
      width: w,
      height: h,
      fit: BoxFit.contain,
      // 按显示大小解码，大图（如 Kick 的 fullsize）不占多余内存。
      // 实际比例可能和平台给的不同，按不缩小时的高度解码
      cacheHeight: (height * dpr).ceil(),
      loadStateChanged: (state) {
        switch (state.extendedImageLoadState) {
          case LoadState.loading:
            return SizedBox(width: w ?? h, height: h);
          case LoadState.failed:
            return Text(emote.text, style: fallbackStyle);
          case LoadState.completed:
            // 平台给的宽高和图片实际的比例不一定一样（B站的表情包常常更窄），
            // 按实际比例算宽度，不然图片两侧会留出空白
            var image = state.extendedImageInfo?.image;
            if (image == null || image.width == 0 || image.height == 0) {
              return null;
            }
            var real = image.width / image.height;
            var rh = height;
            var rw = rh * real;
            if (limit != null && rw > limit) {
              rw = limit;
              rh = limit / real;
            }
            return ExtendedRawImage(
              image: image,
              width: rw,
              height: rh,
              fit: BoxFit.contain,
            );
        }
      },
    );
  }
}
