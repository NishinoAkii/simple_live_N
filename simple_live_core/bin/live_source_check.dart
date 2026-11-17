// 直播源脚本（.live.js）检查工具，给写源的人用
//
//   cd simple_live_core
//   dart run bin/live_source_check.dart <file.live.js> [--room <id>] [--search <关键词>]
//       [--suggest <关键词>] [--resolve <输入>] [--danmaku <秒>] [--play] [--data <目录>]
//
// 依次输出：元数据和功能、推荐第 1 页、分类、搜索、直播间详情、清晰度、
// 播放地址（--play，隐去查询参数）、醒目留言、N 秒弹幕（--danmaku）。
// 没给 --room 时用推荐（或搜索）的第一个房间。任何一步失败时退出码为 1。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/script/script_metadata.dart';

const _usage = '''
用法：dart run bin/live_source_check.dart <file.live.js> [选项]

选项：
  --room <id>        检查这个房间（默认用推荐或搜索的第一个房间）
  --search <关键词>   搜索直播间（和主播，如果实现了 searchAnchors）
  --suggest <关键词>  搜索联想（suggest）
  --resolve <输入>    把输入（数字 ID、@名称等）解析成房间号（resolve），能解析时检查这个房间
  --danmaku <秒>     接收这么多秒弹幕并打印
  --play             读取每个清晰度的播放地址（查询参数会隐去）
  --data <目录>       Cookie、Storage 保存目录（默认 .dart_tool/live_source_check/<key>）
  --timeout <秒>     每次调用的超时（默认 20）
''';

int _failures = 0;
final Stopwatch _clock = Stopwatch()..start();

void _print(String text) => stdout.writeln(text);

String _time() {
  var now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, "0");
  return "${two(now.hour)}:${two(now.minute)}:${two(now.second)}";
}

String _short(Object? value, [int max = 160]) {
  var text = value is String ? value : jsonEncode(value);
  text = text.replaceAll(RegExp(r'\s+'), " ");
  return text.length <= max ? text : "${text.substring(0, max)}…";
}

/// 隐去查询参数的值（token、签名等）
String maskUrl(String url) {
  var uri = Uri.tryParse(url);
  if (uri == null || !uri.hasQuery) return url;
  var keys = uri.query
      .split("&")
      .where((e) => e.isNotEmpty)
      .map((e) => "${e.split("=").first}=***")
      .join("&");
  return "${url.substring(0, url.indexOf("?"))}?$keys";
}

Map<String, String> _maskHeaders(Map<String, String>? headers) {
  var out = <String, String>{};
  headers?.forEach((k, v) {
    var lower = k.toLowerCase();
    out[k] = lower == "cookie" || lower == "authorization" ? "***" : v;
  });
  return out;
}

Future<T?> _step<T>(String title, Future<T> Function() body) async {
  _print("\n▶ $title");
  var sw = Stopwatch()..start();
  try {
    var result = await body();
    _print("  ✓ ${sw.elapsedMilliseconds} ms");
    return result;
  } catch (e) {
    _failures++;
    _print("  ✗ ${e is CoreError ? e.message : e}");
    return null;
  }
}

void _printRooms(List<LiveRoomItem> rooms, bool hasMore) {
  for (var r in rooms.take(10)) {
    _print(
      "  - ${r.roomId}  ${r.userName}  ${_short(r.title, 40)}  在线 ${r.online}"
      "${r.cover.isEmpty ? "  （无封面）" : ""}",
    );
  }
  _print("  共 ${rooms.length} 个，hasMore = $hasMore");
  if (rooms.isEmpty) {
    _print("  ! 没有房间");
  }
}

Future<void> main(List<String> argv) async {
  _clock.reset(); // 顶层变量第一次用到时才创建，这里让计时从启动开始
  String? file;
  String? roomId;
  String? keyword;
  String? suggestKeyword;
  String? resolveInput;
  String? dataDir;
  var danmakuSeconds = 0;
  var play = false;
  for (var i = 0; i < argv.length; i++) {
    var a = argv[i];
    String next() {
      if (i + 1 >= argv.length) {
        stderr.writeln("$a 需要一个参数\n\n$_usage");
        exit(2);
      }
      return argv[++i];
    }

    switch (a) {
      case "--room":
        roomId = next();
        break;
      case "--search":
        keyword = next();
        break;
      case "--suggest":
        suggestKeyword = next();
        break;
      case "--resolve":
        resolveInput = next();
        break;
      case "--danmaku":
        danmakuSeconds = int.tryParse(next()) ?? 10;
        break;
      case "--play":
        play = true;
        break;
      case "--data":
        dataDir = next();
        break;
      case "--timeout":
        ScriptLiveSite.callTimeout = Duration(
          seconds: int.tryParse(next()) ?? 20,
        );
        break;
      case "-h":
      case "--help":
        _print(_usage);
        exit(0);
      default:
        if (a.startsWith("-") || file != null) {
          stderr.writeln("不认识的参数：$a\n\n$_usage");
          exit(2);
        }
        file = a;
    }
  }
  if (file == null) {
    stderr.writeln(_usage);
    exit(2);
  }

  // 脚本的 log() 和运行时日志直接打印
  CoreLog.onPrintLog = (level, message) {
    _print("  [${level.name}] ${message.replaceAll("\n", "\n    ")}");
  };

  var path = File(file).absolute.path;
  String code;
  try {
    code = File(path).readAsStringSync();
  } catch (e) {
    stderr.writeln("读取文件失败：$path");
    exit(2);
  }

  LiveSourceMeta meta;
  try {
    meta = parseLiveSourceScript(
      code,
      filename: path.split(RegExp(r'[\\/]')).last,
      appVersion: "check",
    );
  } on CoreError catch (e) {
    _print("✗ 加载失败：${e.message}");
    exit(1);
  }

  var info = meta.toInfo(path);
  _print("名称      ${meta.name}");
  _print("key       ${meta.key}（App 里的平台 id：${info.siteId}）");
  _print("版本      ${meta.version}（接口版本 ${meta.apiVersion}）");
  _print("更新地址  ${meta.url ?? "（无）"}");
  _print("图标      ${meta.icon == null ? "（无）" : _short(meta.icon, 80)}");
  if (meta.description != null) _print("说明      ${meta.description}");
  _print(
    "domains   ${meta.domains.isEmpty ? "（空：不能发任何请求）" : meta.domains.join(", ")}",
  );
  _print("links     ${meta.links.isEmpty ? "（无）" : meta.links.join("  ")}");
  _print("功能      ${meta.capabilities.join(", ")}");
  var sensitive = meta.capabilities
      .where(kLiveSourceSensitiveCapabilities.contains)
      .map(liveSourceCapabilityLabel);
  if (sensitive.isNotEmpty) {
    _print("敏感功能  ${sensitive.join("；")}（安装时给用户看，更新时新增要用户确认）");
  }
  for (var s in meta.settings) {
    _print(
      "设置项    ${s.key}（${s.type}）${s.label}，默认 ${jsonEncode(s.defaultValue)}",
    );
  }
  if (info.overrides != null) {
    // 内置平台的修正：没实现的函数用 App 内置的代码，不是错
    for (var line in describeLiveSourceOverride(
      info.overrides!,
      info.overrideFunctions,
      useAccount: info.useAccount,
    )) {
      _print("修正      $line");
    }
  } else {
    for (var required in const ["room", "qualities", "playUrls"]) {
      if (!meta.methods.contains(required)) {
        _print("! 没有实现 $required()，App 打不开直播间");
      }
    }
  }
  if (meta.methods.contains("categories") !=
      meta.methods.contains("categoryRooms")) {
    _print("! categories() 和 categoryRooms() 要一起实现，App 才显示分类");
  }

  var dataDirectory =
      dataDir ??
      "${Directory.current.path}${Platform.pathSeparator}.dart_tool"
          "${Platform.pathSeparator}live_source_check${Platform.pathSeparator}${meta.key}";
  var site = ScriptLiveSite(
    info,
    dataDirectory: dataDirectory,
    appVersion: "check",
  );
  _print("数据目录  $dataDirectory");

  try {
    if (site.hasRecommend) {
      var rec = await _step("推荐 第 1 页", () => site.getRecommendRooms(page: 1));
      if (rec != null) {
        _printRooms(rec.items, rec.hasMore);
        roomId ??= rec.items.firstOrNull?.roomId;
      }
    }

    if (site.hasCategories) {
      var cats = await _step("分类", () => site.getCategores());
      if (cats != null) {
        for (var c in cats.take(5)) {
          _print(
            "  - ${c.id} ${c.name}：${c.children.take(6).map((e) => e.name).join("、")}"
            "${c.children.length > 6 ? " 等 ${c.children.length} 个" : ""}",
          );
        }
        _print("  共 ${cats.length} 个大类");
        var sub = cats.expand((e) => e.children).firstOrNull;
        if (sub != null) {
          var rooms = await _step(
            "分类「${sub.name}」第 1 页",
            () => site.getCategoryRooms(sub, page: 1),
          );
          if (rooms != null) _printRooms(rooms.items, rooms.hasMore);
        }
      }
    }

    if (keyword != null) {
      if (site.hasSearch) {
        var result = await _step(
          "搜索「$keyword」",
          () => site.searchRooms(keyword!, page: 1),
        );
        if (result != null) {
          _printRooms(result.items, result.hasMore);
          roomId ??= result.items.firstOrNull?.roomId;
        }
      } else {
        _print("\n（没有实现 search）");
      }
      if (site.hasSearchAnchors) {
        var result = await _step(
          "搜索主播「$keyword」",
          () => site.searchAnchors(keyword!, page: 1),
        );
        if (result != null) {
          for (var a in result.items.take(10)) {
            _print(
              "  - ${a.roomId}  ${a.userName}  ${a.liveStatus ? "直播中" : "未开播"}",
            );
          }
          _print("  共 ${result.items.length} 个，hasMore = ${result.hasMore}");
        }
      }
    }

    if (suggestKeyword != null) {
      if (site.hasSuggest) {
        var items = await _step(
          "联想「$suggestKeyword」",
          () => site.getSearchSuggestions(suggestKeyword!),
        );
        if (items != null) {
          for (var e in items.take(10)) {
            var live = e.liveStatus == null
                ? ""
                : (e.liveStatus! ? "  直播中" : "  未开播");
            _print(
              e.isRoom
                  ? "  - [主播] ${e.roomId}  ${e.text}$live"
                  : "  - ${e.text}（只有词，没有 roomId，App 不显示）",
            );
          }
          if (items.isEmpty) _print("  （没有联想）");
        }
      } else {
        _print("\n（没有实现 suggest）");
      }
    }

    if (resolveInput != null) {
      if (site.hasResolve) {
        var id = await _step(
          "解析「$resolveInput」",
          () => site.resolveRoomId(resolveInput!),
        );
        _print("  房间号：${id ?? "（认不出）"}");
        if (id != null) roomId ??= id;
      } else {
        _print("\n（没有实现 resolve）");
      }
    }

    if (roomId == null) {
      _print("\n（没有房间可检查：用 --room <id> 指定）");
    } else {
      var id = roomId;
      var detail = await _step("直播间 $id", () => site.getRoomDetail(roomId: id));
      if (detail != null) {
        _print("  标题      ${detail.title}");
        _print("  主播      ${detail.userName}");
        _print("  在线      ${detail.online}");
        _print("  直播中    ${detail.status}");
        _print("  网页      ${detail.url}");
        _print("  封面      ${_short(detail.cover, 100)}");
        _print("  头像      ${_short(detail.userAvatar, 100)}");
        if (detail.introduction != null) {
          _print("  简介      ${_short(detail.introduction, 100)}");
        }
        if (detail.notice != null) {
          _print("  公告      ${_short(detail.notice, 100)}");
        }
        _print("  data      ${_short(detail.data)}");
        var dm = detail.danmakuData;
        _print("  弹幕参数  ${_short(dm is ScriptDanmakuArgs ? dm.data : dm)}");

        var viaRoom = !info.capabilities.contains("liveStatus");
        await _step(
          "liveStatus($id)${viaRoom ? "（没有实现，读 room().live）" : ""}",
          () async {
            var live = await site.getLiveStatus(roomId: id);
            _print("  $live");
            return live;
          },
        );

        var qualities = await _step(
          "清晰度",
          () => site.getPlayQualites(detail: detail),
        );
        if (qualities != null) {
          for (var q in qualities) {
            _print(
              "  - ${q.quality}  sort=${q.sort}  data=${_short(q.data, 100)}",
            );
          }
          if (qualities.isEmpty) _print("  ! 没有清晰度（未开播？）");
        }

        if (play && qualities != null) {
          for (var q in qualities) {
            var urls = await _step(
              "播放地址（${q.quality}）",
              () => site.getPlayUrls(detail: detail, quality: q),
            );
            if (urls != null) {
              for (var u in urls.urls) {
                _print("  - ${maskUrl(u)}");
              }
              if (urls.headers != null) {
                _print("  headers ${_maskHeaders(urls.headers)}");
              }
              if (urls.urls.isEmpty) _print("  ! 没有地址");
            }
            if (site.hasAvPlayer) {
              var av = await _step(
                "iOS 系统播放器地址（${q.quality}）",
                () => site.getAvPlayerUrls(detail: detail, quality: q),
              );
              if (av == null) {
                _print("  （null：App 改用 mpv 小窗）");
              } else {
                for (var u in av.urls) {
                  _print("  - ${maskUrl(u)}");
                }
              }
            }
          }
        }

        if (site.hasSuperChat) {
          var sc = await _step(
            "醒目留言",
            () => site.getSuperChatMessage(roomId: id),
          );
          if (sc != null) {
            for (var m in sc.take(3)) {
              _print(
                "  - ${m.priceText ?? "￥${m.price}"} ${m.userName}：${_short(m.message, 60)}",
              );
            }
            _print("  共 ${sc.length} 条");
          }
        }

        if (danmakuSeconds > 0) {
          if (!site.hasDanmaku) {
            _print("\n（没有实现 danmaku）");
          } else {
            await _danmaku(site, detail, danmakuSeconds);
          }
        }
      }
    }
  } finally {
    await site.dispose();
  }
  _print(
    "\n${_failures == 0 ? "全部通过" : "$_failures 步失败"}（${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒）",
  );
  exit(_failures == 0 ? 0 : 1);
}

Future<void> _danmaku(
  ScriptLiveSite site,
  LiveRoomDetail detail,
  int seconds,
) async {
  _print("\n▶ 弹幕 $seconds 秒");
  var danmaku = site.getDanmaku() as ScriptLiveDanmaku;
  var counts = <String, int>{};
  var ready = false;
  void count(String type) => counts[type] = (counts[type] ?? 0) + 1;
  danmaku.onReady = () {
    ready = true;
    _print("  [${_time()}] 就绪");
  };
  danmaku.onClose = (msg) {
    count("断开");
    _print("  [${_time()}] 断开：$msg");
  };
  danmaku.onSystemMessage = (text) {
    count("系统");
    _print("  [${_time()}] 系统  $text");
  };
  danmaku.onMessage = (m) {
    switch (m.type) {
      case LiveMessageType.chat:
        count("聊天");
        _print("  [${_time()}] ${m.userName}：${m.message}  ${m.color}");
        break;
      case LiveMessageType.online:
        count("在线");
        _print("  [${_time()}] 在线 ${m.data}");
        break;
      case LiveMessageType.superChat:
        count("醒目留言");
        var sc = m.data as LiveSuperChatMessage;
        _print(
          "  [${_time()}] 醒目留言 ${sc.priceText ?? "￥${sc.price}"} ${sc.userName}：${sc.message}",
        );
        break;
      case LiveMessageType.gift:
        count("礼物");
        break;
      case LiveMessageType.linkMic:
        count("连麦");
        var state = m.data as LiveLinkMicState;
        _print("  [${_time()}] ${state.summary}  排队 ${state.waiting}");
        break;
      case LiveMessageType.stats:
        count("统计");
        break;
      case LiveMessageType.rank:
        count("榜单");
        break;
      case LiveMessageType.voiceRoom:
      case LiveMessageType.voiceCaption:
        count("语聊房");
        break;
    }
  };
  await danmaku.start(detail.danmakuData);
  await Future.delayed(Duration(seconds: seconds));
  await danmaku.stop();
  _print(
    "  统计：${counts.isEmpty ? "没有消息" : counts.entries.map((e) => "${e.key} ${e.value}").join("，")}",
  );
  if (!ready) {
    _failures++;
    _print("  ✗ 弹幕没有就绪（没有调用 session.ready()，也没有收到消息）");
  }
}
