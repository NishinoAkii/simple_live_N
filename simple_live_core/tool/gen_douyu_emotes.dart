// 生成斗鱼内置表情表 lib/src/danmaku/douyu_emotes_table.dart。
//
// 斗鱼网页端的内置表情（“[名称]”和旧版“[emot:dyNNN]”）打包在直播间页面的
// live-next-player-aside_*.js 里（webpack 模块 e6b57），没有接口可以读。
// 这个脚本把那个 JS 当作文本解析（不执行），或者读之前解析好的 JSON，生成 Dart 常量。
//
// 用法（在 simple_live_core 目录下）：
//   dart run tool/gen_douyu_emotes.dart <live-next-player-aside_xxx.js | douyu_emotes.json>
//
// JS 的地址：打开任意直播间页面，在 service-module-declaration_*.js 里找
// live-next-player-aside 的地址（shark2.douyucdn.cn/front-publish/...）。
// JSON 的格式：{"source": "...", "named": {名称: 地址}, "legacy": {dyNNN: 地址}}。
//
// 图片地址带内容哈希，斗鱼重新构建前端后会变。App 运行时会自己扫当前的 JS
// （DouyuAside），这张表只是扫不到时的后备，隔一段时间重新生成即可。
import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/src/danmaku/douyu_aside.dart';

const _output = "lib/src/danmaku/douyu_emotes_table.dart";
const _base =
    "https://shark2.douyucdn.cn/front-publish/live-next-player-aside-master/assets/images/";

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      "用法：dart run tool/gen_douyu_emotes.dart "
      "<live-next-player-aside_xxx.js | douyu_emotes.json>",
    );
    exit(64);
  }
  var path = args.single;
  var text = File(path).readAsStringSync();
  late Map<String, String> named;
  late Map<String, String> legacy;
  late String source;
  if (path.toLowerCase().endsWith(".json")) {
    var data = json.decode(text) as Map;
    named = Map<String, String>.from(data["named"] as Map);
    legacy = Map<String, String>.from(data["legacy"] as Map);
    source = data["source"]?.toString() ?? File(path).uri.pathSegments.last;
  } else {
    (named, legacy) = _parseJs(text);
    var date = DateTime.now().toIso8601String().substring(0, 10);
    source =
        "shark2.douyucdn.cn ${File(path).uri.pathSegments.last} "
        "module e6b57 ($date)";
  }
  if (named.isEmpty || legacy.isEmpty) {
    stderr.writeln("没有解析出表情（named ${named.length}，legacy ${legacy.length}）");
    exit(1);
  }
  var keys = legacy.keys.toList()..sort();
  var buffer = StringBuffer()
    ..writeln("// 由 tool/gen_douyu_emotes.dart 生成，不要手改。")
    ..writeln("// 来源：$source")
    ..writeln()
    ..writeln("/// 内置表情图片的地址前缀（表里的值不是 http 开头时拼在它后面）")
    ..writeln("const String kDouyuEmoteImageBase =")
    ..writeln("    ${_quote(_base)};")
    ..writeln()
    ..writeln("/// 网页端内置表情：名称（聊天里是“[名称]”）→ 图片，")
    ..writeln("/// 按网页端合并的顺序去重（同名时前面的组优先），共 ${named.length} 个")
    ..writeln("const Map<String, String> kDouyuEmotes = {");
  for (var entry in named.entries) {
    buffer.writeln("  ${_quote(entry.key)}: ${_quote(_short(entry.value))},");
  }
  buffer
    ..writeln("};")
    ..writeln()
    ..writeln("/// 旧版表情：“[emot:dyNNN]”里的 dyNNN → 图片，共 ${legacy.length} 个")
    ..writeln("const Map<String, String> kDouyuLegacyEmotes = {");
  for (var key in keys) {
    buffer.writeln("  ${_quote(key)}: ${_quote(_short(legacy[key]!))},");
  }
  buffer.writeln("};");
  File(_output).writeAsStringSync(buffer.toString());
  stdout.writeln("写入 $_output：named ${named.length}，legacy ${legacy.length}");
}

String _short(String url) =>
    url.startsWith(_base) ? url.substring(_base.length) : url;

String _quote(String value) => json.encode(value).replaceAll(r"$", r"\$");

/// 解析和运行时扫描用同一份代码（lib/src/danmaku/douyu_aside.dart）
(Map<String, String>, Map<String, String>) _parseJs(String t) {
  var data = parseDouyuAside(t);
  return (data.named, data.legacy);
}
