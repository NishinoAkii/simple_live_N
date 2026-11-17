import 'package:simple_live_core/src/model/live_play_url.dart';

/// 是不是 HLS 播放列表地址：http(s)，路径以 .m3u8 结尾，或是 YouTube 的 hls_playlist 地址。
/// iOS 系统画中画（AVPlayer）只能播 HLS 和 MP4，不能播 FLV
bool isHlsPlayUrl(String url) {
  var uri = Uri.tryParse(url.trim());
  if (uri == null ||
      (uri.scheme != "http" && uri.scheme != "https") ||
      uri.host.isEmpty) {
    return false;
  }
  var path = uri.path.toLowerCase();
  return path.endsWith(".m3u8") || path.contains("/hls_playlist/");
}

/// 只保留 [play] 里的 HLS 地址（顺序和请求头不变），给 AVPlayer 用；一个都没有时返回 null
LivePlayUrl? hlsOnlyPlayUrl(LivePlayUrl play) {
  var urls = play.urls.where(isHlsPlayUrl).toList();
  if (urls.isEmpty) {
    return null;
  }
  return LivePlayUrl(urls: urls, headers: play.headers);
}
