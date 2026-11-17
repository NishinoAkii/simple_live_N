/// HLS 多码率主播放列表中的一路码流
class HlsVariant {
  /// 显示名称，如 1080p60、720p
  final String name;

  /// 码流稳定标识，用于重新获取地址后找回同一清晰度
  final String id;

  /// 码流播放列表地址
  final String url;

  /// 带宽（bit/s）
  final int bandwidth;

  /// 是否仅音频
  final bool audioOnly;

  HlsVariant({
    required this.name,
    required this.id,
    required this.url,
    required this.bandwidth,
    required this.audioOnly,
  });
}

/// 解析 HLS 主播放列表，按带宽从高到低返回各路码流，仅音频排在最后
List<HlsVariant> parseHlsMaster(String text, Uri base) {
  var mediaNames = <String, String>{};
  var variants = <HlsVariant>[];
  Map<String, String>? pending;
  for (var raw in text.split('\n')) {
    var line = raw.trim();
    if (line.isEmpty) {
      continue;
    }
    if (line.startsWith('#EXT-X-MEDIA:')) {
      var attrs = _parseAttributes(line.substring('#EXT-X-MEDIA:'.length));
      var group = attrs['GROUP-ID'];
      var name = attrs['NAME'];
      if (group != null && name != null && attrs['TYPE'] == 'VIDEO') {
        mediaNames[group] = name;
      }
    } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
      pending = _parseAttributes(line.substring('#EXT-X-STREAM-INF:'.length));
    } else if (!line.startsWith('#') && pending != null) {
      var attrs = pending;
      pending = null;
      var codecs = attrs['CODECS'] ?? '';
      var audioOnly =
          !attrs.containsKey('RESOLUTION') &&
          codecs.isNotEmpty &&
          !codecs.contains('avc') &&
          !codecs.contains('hvc') &&
          !codecs.contains('hev') &&
          !codecs.contains('av01');
      var id =
          attrs['STABLE-VARIANT-ID'] ??
          attrs['IVS-NAME'] ??
          attrs['VIDEO'] ??
          attrs['RESOLUTION'] ??
          attrs['BANDWIDTH'] ??
          line;
      var name =
          attrs['IVS-NAME'] ??
          mediaNames[attrs['VIDEO']] ??
          _nameFromResolution(attrs) ??
          id;
      variants.add(
        HlsVariant(
          name: audioOnly ? 'audio_only' : name,
          id: id,
          url: base.resolve(line).toString(),
          bandwidth: int.tryParse(attrs['BANDWIDTH'] ?? '') ?? 0,
          audioOnly: audioOnly,
        ),
      );
    }
  }
  variants.sort((a, b) {
    if (a.audioOnly != b.audioOnly) {
      return a.audioOnly ? 1 : -1;
    }
    return b.bandwidth.compareTo(a.bandwidth);
  });
  return variants;
}

String? _nameFromResolution(Map<String, String> attrs) {
  var resolution = attrs['RESOLUTION'];
  if (resolution == null || !resolution.contains('x')) {
    return null;
  }
  var height = resolution.split('x').last;
  var fps = double.tryParse(attrs['FRAME-RATE'] ?? '')?.round() ?? 0;
  return fps > 30 ? '${height}p$fps' : '${height}p';
}

Map<String, String> _parseAttributes(String text) {
  var result = <String, String>{};
  var pattern = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');
  for (var match in pattern.allMatches(text)) {
    var value = match.group(2)!;
    if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
      value = value.substring(1, value.length - 1);
    }
    result[match.group(1)!] = value;
  }
  return result;
}
