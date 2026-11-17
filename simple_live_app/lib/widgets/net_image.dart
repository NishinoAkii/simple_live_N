import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';

class NetImage extends StatelessWidget {
  final String picUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final double borderRadius;

  /// 图片加载失败时调用（在 build 期间）
  final VoidCallback? onLoadFailed;
  const NetImage(this.picUrl,
      {this.width,
      this.height,
      this.fit = BoxFit.cover,
      this.borderRadius = 0,
      this.onLoadFailed,
      Key? key})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (picUrl.isEmpty) {
      return Image.asset(
        'assets/images/logo.png',
        width: width,
        height: height,
      );
    }
    var pic = picUrl;
    if (pic.startsWith("//")) {
      pic = 'https:$pic';
    }
    if (width != null && width!.isFinite) {
      return _image(context, pic, width);
    }
    // 没给宽度（封面铺满卡片）时按排版出来的宽度解码
    return LayoutBuilder(
      builder: (context, constraints) =>
          _image(context, pic, constraints.maxWidth),
    );
  }

  /// 按显示宽度解码，不按原图：1080p 的封面原样解码要 8 MB 左右，
  /// 卡片只有几百像素宽。首页满屏封面、聊天里的头像都省内存和解码时间
  Widget _image(BuildContext context, String pic, double? displayWidth) {
    int? cacheWidth;
    if (displayWidth != null && displayWidth.isFinite && displayWidth > 0) {
      var dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
      cacheWidth = (displayWidth * dpr).ceil().clamp(1, 2048);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: ExtendedImage.network(
        pic,
        fit: fit,
        height: height,
        width: width,
        cacheWidth: cacheWidth,
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(borderRadius),
        loadStateChanged: (e) {
          if (e.extendedImageLoadState == LoadState.loading) {
            return const Icon(
              Icons.image,
              color: Colors.grey,
              size: 24,
            );
          }
          if (e.extendedImageLoadState == LoadState.failed) {
            onLoadFailed?.call();
            return const Icon(
              Icons.broken_image,
              color: Colors.grey,
              size: 24,
            );
          }
          return null;
        },
      ),
    );
  }
}
