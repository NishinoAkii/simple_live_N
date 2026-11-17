import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/douyu_aside.dart';
import 'package:simple_live_core/src/danmaku/douyu_emotes.dart';
import 'package:simple_live_core/src/danmaku/douyu_gifts.dart';
import 'package:test/test.dart';

// 按斗鱼网页的写法编的几段文本（地址的格式和 2026-11-13 的网页一样，版本号是编的）
const String _room =
    '<script src="https://shark2.douyucdn.cn/front-publish/'
    'smf-live-next-master/service-module-declaration_nc_abc1234.js"></script>';
const String _declaration =
    'e.exports={"live-next-player-aside":'
    '"https://shark2.douyucdn.cn/front-publish/live-next-player-aside-master/'
    'js/live-next-player-aside_feed123.js"}';
const String _img =
    "https://shark2.douyucdn.cn/front-publish/live-next-player-aside-master/assets/images/";
const String _aside =
    'a:function(e,t){e.exports="${_img}diamond-icon_1111111.png"},'
    'b:function(e,t){e.exports="${_img}noble-level5_2222222.png"},'
    'c:function(e,t){e.exports="${_img}noble-level10_3333333.gif"}';

void main() {
  setUp(() {
    CoreLog.enableLog = false;
    DouyuAside.debugReset();
  });
  tearDown(() {
    DouyuAside.debugFetch = null;
    DouyuAside.debugReset();
  });

  test('房间页 → 声明脚本 → aside JS，按名字扫出带版本号的图片', () async {
    var requested = <String>[];
    DouyuAside.debugFetch = (url) async {
      requested.add(url);
      if (url == "https://www.douyu.com/9999") return _room;
      if (url.contains("service-module-declaration")) return _declaration;
      if (url.contains("live-next-player-aside_feed123.js")) return _aside;
      throw StateError("unexpected $url");
    };
    await DouyuAside.ensure("9999");
    expect(requested.length, 3);
    expect(DouyuAside.image("diamond-icon"), "${_img}diamond-icon_1111111.png");
    // 新版的文件名代替内置的；新出的等级也认得
    expect(douyuDiamondFansIcon().url, endsWith("diamond-icon_1111111.png"));
    expect(douyuNobleIconUrl("5"), endsWith("noble-level5_2222222.png"));
    expect(douyuNobleIconUrl("10"), endsWith("noble-level10_3333333.gif"));
    // 12 小时内不再读
    await DouyuAside.ensure("9999");
    expect(requested.length, 3);
  });

  test('读不到时用内置的地址，不报错', () async {
    DouyuAside.debugFetch = (url) async => throw StateError("offline");
    await DouyuAside.ensure("9999");
    expect(DouyuAside.data, isNull);
    expect(douyuDiamondFansIcon().url, endsWith("diamond-icon_0531e5c.png"));
    expect(douyuNobleIconUrl("5"), endsWith("noble-level5_098f64b.png"));
    expect(douyuNobleIconUrl("10"), isNull);
    // 内置表情照常能用
    var emotes = parseDouyuEmotes("[666]");
    expect(emotes?.single.url, contains("liuliuliu"));
  });

  test('找地址：房间页里直接写着 aside JS 时也认', () {
    expect(
      findDouyuAsideUrl(_declaration),
      "https://shark2.douyucdn.cn/front-publish/live-next-player-aside-master/"
      "js/live-next-player-aside_feed123.js",
    );
    expect(
      findDouyuDeclarationUrls(_room).single,
      contains("service-module-declaration_nc_abc1234.js"),
    );
    expect(findDouyuAsideUrl("<html></html>"), isNull);
  });
}
