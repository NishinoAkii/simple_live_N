import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/player/stream_tuning.dart';

void main() {
  test("网络直播的协议白名单：只有 http(s)、tcp、tls、crypto", () {
    for (var hls in [true, false]) {
      var lavf = StreamTuning.mpvOptions(hls: hls)['demuxer-lavf-o']!;
      var list = RegExp(r'protocol_whitelist=\[([^\]]*)\]')
          .firstMatch(lavf)![1]!
          .split(',');
      expect(list, unorderedEquals(['tcp', 'tls', 'http', 'https', 'crypto']));
      for (var p in ['file', 'data', 'concat', 'subfile', 'udp', 'rtp']) {
        expect(list, isNot(contains(p)));
      }
      // 分段没有扩展名的平台（Steam、YouTube 中转）要用；file 不在白名单里
      expect(lavf, contains('allowed_extensions=ALL'));
    }
  });
}
