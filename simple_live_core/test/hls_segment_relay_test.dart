import 'dart:async';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 本机的假上游：滑动的直播列表（每次 3 段），可以换初始化分段
class _Upstream {
  late HttpServer server;
  int first = 100;
  String init = "h1.mp4";
  final List<String> referers = [];
  int segmentRequests = 0;
  String? master;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      referers.add(request.headers.value("referer") ?? "");
      var path = request.uri.path;
      var response = request.response;
      if (path == "/live/index.m3u8") {
        response.write(master ??
            [
              "#EXTM3U",
              "#EXT-X-VERSION:7",
              "#EXT-X-TARGETDURATION:1",
              "#EXT-X-MEDIA-SEQUENCE:$first",
              '#EXT-X-MAP:URI="$init"',
              for (var n = first; n < first + 3; n++) ...[
                "#EXTINF:1.000,",
                "$n.m4s",
              ],
            ].join("\n"));
      } else if (path.endsWith(".m4s")) {
        segmentRequests++;
        response.write("segment ${path.split("/").last}");
      } else if (path.endsWith(".mp4")) {
        response.write("init ${path.split("/").last}");
      } else {
        response.statusCode = 404;
      }
      await response.close();
    });
  }

  String get url => "http://127.0.0.1:${server.port}/live/index.m3u8";
}

Future<String> _get(String url) async {
  var client = HttpClient();
  try {
    var request = await client.getUrl(Uri.parse(url));
    var response = await request.close();
    var text = await response.transform(const SystemEncoding().decoder).join();
    if (response.statusCode != 200) throw "HTTP ${response.statusCode}";
    return text;
  } finally {
    client.close(force: true);
  }
}

void main() {
  late _Upstream upstream;
  setUp(() async {
    upstream = _Upstream();
    await upstream.start();
  });
  tearDown(() => upstream.server.close(force: true));

  test('列表改成本机地址，分段和初始化分段从这里取，带上请求头', () async {
    var local = await HlsSegmentRelay.instance
        .register(upstream.url, headers: {"referer": "https://live.bilibili.com"});
    expect(HlsSegmentRelay.isRelayUrl(local), isTrue);
    var text = await _get(local);
    expect(text, contains("#EXT-X-MEDIA-SEQUENCE:100"));
    expect(text, contains('#EXT-X-MAP:URI="init/'));
    expect(text, contains("seg/102.m4s"));
    expect(text, isNot(contains("127.0.0.1:${upstream.server.port}")));
    var base = local.substring(0, local.lastIndexOf("/") + 1);
    expect(await _get("${base}seg/101.m4s"), "segment 101.m4s");
    var init = RegExp(r'URI="([^"]+)"').firstMatch(text)!.group(1)!;
    expect(await _get("$base$init"), "init h1.mp4");
    expect(upstream.referers.toSet(), {"https://live.bilibili.com"});
  });

  test('新分段一出现就下载；上游丢掉的分段还留在列表里', () async {
    var local = await HlsSegmentRelay.instance.register(upstream.url);
    await _get(local);
    // 列表里的 3 段在后台下载
    await Future.delayed(const Duration(milliseconds: 300));
    expect(upstream.segmentRequests, 3);
    upstream.first = 105;
    var text = await _get(local);
    expect(text, contains("#EXT-X-MEDIA-SEQUENCE:100"));
    expect(text, contains("seg/107.m4s"));
    var base = local.substring(0, local.lastIndexOf("/") + 1);
    // 上游已经没有 101 了，这里还有（已经下载过）
    expect(await _get("${base}seg/101.m4s"), "segment 101.m4s");
  });

  test('初始化分段换了：通知一次重新打开；重新登记后从新的开始', () async {
    var restarts = 0;
    var local = await HlsSegmentRelay.instance
        .register(upstream.url, onRestart: () => restarts++);
    await _get(local);
    upstream.init = "h2.mp4";
    upstream.first = 101;
    await _get(local);
    await _get(local);
    await Future<void>.delayed(Duration.zero);
    expect(restarts, 1);

    local = await HlsSegmentRelay.instance
        .register(upstream.url, onRestart: () => restarts++);
    var text = await _get(local);
    var base = local.substring(0, local.lastIndexOf("/") + 1);
    var init = RegExp(r'URI="([^"]+)"').firstMatch(text)!.group(1)!;
    expect(await _get("$base$init"), "init h2.mp4");
    expect(restarts, 1);
  });

  test('主列表：原样转交，地址改成绝对地址', () async {
    upstream.master = [
      "#EXTM3U",
      "#EXT-X-STREAM-INF:BANDWIDTH=8000000",
      "hd/index.m3u8",
    ].join("\n");
    var local = await HlsSegmentRelay.instance.register(upstream.url);
    var text = await _get(local);
    expect(text,
        contains("http://127.0.0.1:${upstream.server.port}/live/hd/index.m3u8"));
  });
}
