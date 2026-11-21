import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/log.dart';

/// 按直播流的类型调整 mpv 的网络参数。
///
/// HLS（Twitch、Kick 等）按整段（2~6 秒）下载，播放列表也要反复刷新：
/// - media_kit 默认 5 秒网络超时，跨洋的播放列表服务器（如 Kick 的亚太区）偶尔慢一点
///   就会报错断开，再由重连逻辑重新打开，看起来就是“断流”；
/// - 卡顿后默认缓冲 1 秒就继续播，一段 4 秒的分段下载完之前又会卡住，变成一卡一卡；
///   改为缓冲 5 秒（约两段，与 ExoPlayer 卡顿后的默认值相同）再播，一次停得稍久，之后不再连续卡；
/// - 分段和播放列表失败时多重试几次，并允许并行下载下一段。
/// 连续的流（FLV 等）保持原来的参数，断线时尽快重连。
class StreamTuning {
  static bool isHls(String url) {
    var path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.endsWith('.m3u8') || url.toLowerCase().contains('.m3u8?');
  }

  /// 线路列表里显示的 CDN 节点名：主机名的第一段（d1--ov-gotcha03 → ov-gotcha03），
  /// B 站的 mcdn（PCDN）节点名是随机串，统一写 mcdn
  static String lineNode(String url) {
    var host = Uri.tryParse(url)?.host ?? "";
    if (host.isEmpty || host == "127.0.0.1") {
      return "";
    }
    if (host.contains(".mcdn.")) {
      return "mcdn";
    }
    var label = host.split(".").first;
    var dash = label.indexOf("--");
    if (dash >= 0 && dash < label.length - 2) {
      label = label.substring(dash + 2);
    }
    return label.length > 20 ? label.substring(0, 20) : label;
  }

  /// 网络直播的协议白名单（ffmpeg 打开 HLS 分段、子列表、密钥时只能用这些协议）。
  ///
  /// media_kit 默认是 udp,rtp,tcp,tls,data,file,http,https,crypto。直播只需要 http(s)
  /// （和它下面的 tcp、tls），AES-128 加密的 HLS 还要 crypto。去掉 file、data（以及用不到的
  /// udp、rtp）：播放地址和列表来自网络（平台接口、直播源脚本），列表里写 file:///…、data:、
  /// concat:、subfile: 之类的地址时 ffmpeg 直接拒绝，不会去读本机文件（已知的 HLS 攻击手法）。
  /// 本机中转（127.0.0.1 上的 HlsFixRelay、YouTubeHlsRelay）用 http，不受影响。
  static const protocolWhitelist = 'tcp,tls,http,https,crypto';

  static Map<String, String> mpvOptions({required bool hls}) => {
        'network-timeout': hls ? '15' : '5',
        'cache-pause-wait': hls ? '5' : '1',
        // 开播时也先缓冲 cache-pause-wait 秒再播。YouTube 低延迟直播每段只有 1 秒、
        // 播放列表里只有 3 段，从最前面开播时缓冲最多 3 秒，网络稍有波动就卡；
        // 先攒几秒，播放点比直播稍晚几秒，之后就有余量。Twitch、Kick 的列表本身有
        // 十几秒内容，开播时缓冲马上就够，几乎不受影响
        'cache-pause-initial': hls ? 'yes' : 'no',
        // 直播的缓存只放内存、按大小和时间封顶，不留往回的缓存（VLC、MPC 也是这样）。
        // media_kit 默认把缓存写进临时文件：文件只增不减，内存上限也只管元数据，
        // 挂得越久占得越多。实测这样每路直播少占约 36 MB，临时文件也不再变大
        'cache-on-disk': 'no',
        'demuxer-max-bytes': '${32 * 1024 * 1024}',
        'cache-secs': '20',
        'demuxer-max-back-bytes': '0',
        'demuxer-donate-buffer': 'no',
        'demuxer-lavf-o': [
          'seg_max_retry=${hls ? 10 : 5}',
          if (hls) 'max_reload=20',
          if (hls) 'http_persistent=1',
          if (hls) 'http_multiple=1',
          'strict=experimental',
          // 分段地址没有扩展名的要用：Steam（…/segment/video/10/）、YouTube 本机中转
          // （/yt/<编号>/seg/<序号>）。较新的 ffmpeg 对 http 分段也检查扩展名；旧版只限制
          // file: 分段——file 已经不在白名单里，所以保留它不会放开本机文件
          'allowed_extensions=ALL',
          'protocol_whitelist=[$protocolWhitelist]',
        ].join(','),
      };

  /// 打开新的地址前调用；同一个播放器会在不同平台的直播间之间切换，每次都要重新设置
  static Future<void> apply(Player player, List<String> urls) async {
    var native = player.platform;
    if (native is! NativePlayer) return;
    var hls = urls.isNotEmpty && urls.every(isHls);
    for (var entry in mpvOptions(hls: hls).entries) {
      try {
        await native.setProperty(entry.key, entry.value);
      } catch (e) {
        Log.logPrint("mpv option ${entry.key}: $e");
      }
    }
  }
}
