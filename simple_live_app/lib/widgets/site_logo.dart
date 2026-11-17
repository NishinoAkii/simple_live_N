import 'dart:typed_data';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:simple_live_app/app/sites.dart';

/// 平台图标：自带平台用 assets 图片，直播源用网络图片或 data: URI，
/// 没有图标、加载失败或平台未安装（[site] 为 null）时显示占位图标
class SiteLogo extends StatelessWidget {
  final Site? site;
  final double width;

  /// 自带平台的图片不指定高度（和原来一样按宽度缩放）
  final double? height;
  const SiteLogo(
    this.site, {
    this.width = 20,
    this.height,
    super.key,
  });

  /// 同一个 data: URI 只解码一次
  static final Map<String, Uint8List?> _dataCache = {};

  static Uint8List? _decodeData(String uri) {
    if (_dataCache.containsKey(uri)) {
      return _dataCache[uri];
    }
    Uint8List? bytes;
    try {
      var data = UriData.parse(uri);
      // Image 不能显示 SVG
      if (!data.mimeType.contains("svg")) {
        bytes = data.contentAsBytes();
      }
    } catch (_) {
      bytes = null;
    }
    if (_dataCache.length > 64) {
      _dataCache.clear();
    }
    _dataCache[uri] = bytes;
    return bytes;
  }

  Widget _fallback(BuildContext context) {
    var size = height ?? width;
    return SizedBox(
      width: width,
      height: size,
      child: Icon(
        site == null ? Icons.extension_off_outlined : Icons.extension_outlined,
        size: size * 0.9,
        color: Colors.grey,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var site = this.site;
    if (site == null) {
      return _fallback(context);
    }
    if (site.logo.isNotEmpty) {
      return Image.asset(
        site.logo,
        width: width,
        height: height,
        errorBuilder: (context, _, __) => _fallback(context),
      );
    }
    var url = site.logoUrl?.trim() ?? "";
    var size = height ?? width;
    if (url.startsWith("data:")) {
      var bytes = _decodeData(url);
      if (bytes == null) {
        return _fallback(context);
      }
      return Image.memory(
        bytes,
        width: width,
        height: size,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (context, _, __) => _fallback(context),
      );
    }
    if (url.startsWith("//")) {
      url = "https:$url";
    }
    if (url.startsWith("http://") || url.startsWith("https://")) {
      return ExtendedImage.network(
        url,
        width: width,
        height: size,
        fit: BoxFit.contain,
        loadStateChanged: (state) {
          switch (state.extendedImageLoadState) {
            case LoadState.loading:
              return SizedBox(width: width, height: size);
            case LoadState.failed:
              return _fallback(context);
            case LoadState.completed:
              return null;
          }
        },
      );
    }
    return _fallback(context);
  }
}
