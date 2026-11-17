// 直播源订阅的发布者签名工具（Ed25519），见 doc/live_source_api.md §8
//
// 在 simple_live_core 目录里：
//   dart run bin/live_source_sign.dart keygen <私钥文件>
//   dart run bin/live_source_sign.dart pubkey <私钥文件>
//   dart run bin/live_source_sign.dart sign <私钥文件> <文件>...
//   dart run bin/live_source_sign.dart index <私钥文件> <index.json> [--dir <脚本目录>]
//   dart run bin/live_source_sign.dart verify <index.json> [--dir <脚本目录>]
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:simple_live_core/src/common/ed25519.dart';
import 'package:simple_live_core/src/script/live_source_signing.dart';

const _usage = '''
直播源签名工具（Ed25519）

  keygen <私钥文件>                     生成新的密钥，私钥写进文件（不要提交到仓库、不要上传），打印公钥
  pubkey <私钥文件>                     打印公钥和指纹
  sign <私钥文件> <文件>...              给文件签名，写出 <文件>.sig（Base64）
  index <私钥文件> <index.json> [--dir <脚本目录>]
                                         给订阅里每个源签名：写入 index.json 的 publicKey 和每一项的 signature
                                         （脚本按 url 的文件名找，默认在 index.json 所在的目录）
  verify <index.json> [--dir <脚本目录>]  用 index.json 里的公钥校验本地的脚本

签名的是脚本文件的字节（CRLF 先换成 LF），改了脚本要重新签名。
App 第一次添加订阅时记下公钥，之后公钥变了或签名不对都会拒绝更新。''';

Never _fail(String message) {
  stderr.writeln("✗ $message");
  exit(1);
}

List<int> _readSeed(String path) {
  var file = File(path);
  if (!file.existsSync()) _fail("找不到私钥文件：$path");
  try {
    var json = jsonDecode(file.readAsStringSync());
    var seed = base64.decode(json["seed"] as String);
    if (seed.length != 32) throw const FormatException();
    return seed;
  } catch (_) {
    _fail("私钥文件格式不对：$path");
  }
}

String _publicKey(List<int> seed) => base64.encode(ed25519PublicKey(seed));

/// 订阅项的 url → 本地脚本文件
File _scriptFile(String url, String dir) {
  var name = Uri.tryParse(url)?.pathSegments.lastOrNull ?? url;
  if (name.isEmpty) name = url;
  return File("$dir${Platform.pathSeparator}${Uri.decodeComponent(name)}");
}

(String, List<String>) _dirOption(List<String> args, String index) {
  var rest = <String>[];
  String? dir;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == "--dir" && i + 1 < args.length) {
      dir = args[++i];
    } else {
      rest.add(args[i]);
    }
  }
  return (dir ?? File(index).absolute.parent.path, rest);
}

Map<String, dynamic> _readIndex(String path) {
  try {
    var json = jsonDecode(File(path).readAsStringSync());
    if (json is Map<String, dynamic> && json["sources"] is List) return json;
  } catch (_) {}
  _fail("不是有效的订阅（index.json）：$path");
}

void main(List<String> args) {
  if (args.isEmpty || args.first == "-h" || args.first == "--help") {
    stdout.writeln(_usage);
    return;
  }
  var command = args.first;
  var rest = args.sublist(1);
  switch (command) {
    case "keygen":
      if (rest.length != 1) _fail("用法：keygen <私钥文件>");
      var file = File(rest[0]);
      if (file.existsSync()) _fail("文件已存在，不覆盖：${rest[0]}");
      var random = Random.secure();
      var seed = List<int>.generate(32, (_) => random.nextInt(256));
      var publicKey = _publicKey(seed);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        "${const JsonEncoder.withIndent("  ").convert({"alg": "ed25519", "seed": base64.encode(seed), "publicKey": publicKey})}\n",
      );
      stdout.writeln("已生成私钥：${file.absolute.path}（妥善保管，不要提交、不要上传）");
      stdout.writeln("公钥：$publicKey");
      stdout.writeln("指纹：${liveSourceKeyFingerprint(publicKey)}");
      break;
    case "pubkey":
      if (rest.length != 1) _fail("用法：pubkey <私钥文件>");
      var publicKey = _publicKey(_readSeed(rest[0]));
      stdout.writeln(publicKey);
      stdout.writeln("指纹：${liveSourceKeyFingerprint(publicKey)}");
      break;
    case "sign":
      if (rest.length < 2) _fail("用法：sign <私钥文件> <文件>...");
      var seed = _readSeed(rest[0]);
      for (var path in rest.sublist(1)) {
        var file = File(path);
        if (!file.existsSync()) _fail("找不到文件：$path");
        var sig = liveSourceSign(seed, file.readAsBytesSync());
        File("$path.sig").writeAsStringSync("$sig\n");
        stdout.writeln("✓ $path.sig");
      }
      break;
    case "index":
      if (rest.length < 2) _fail("用法：index <私钥文件> <index.json> [--dir <脚本目录>]");
      var seed = _readSeed(rest[0]);
      var (dir, files) = _dirOption(rest.sublist(1), rest[1]);
      var indexPath = files.first;
      var index = _readIndex(indexPath);
      var publicKey = _publicKey(seed);
      if (index["publicKey"] != null && index["publicKey"] != publicKey) {
        stderr.writeln(
          "! index.json 里原来的公钥和这把私钥不一样：已经添加过订阅的 App 会拒绝更新（要删除订阅后重新添加）",
        );
      }
      // publicKey 放在 name 后面，其余字段保持原来的顺序
      var out = <String, dynamic>{};
      for (var e in index.entries) {
        if (e.key == "publicKey") continue;
        out[e.key] = e.value;
        if (e.key == "name") out["publicKey"] = publicKey;
      }
      out.putIfAbsent("publicKey", () => publicKey);
      var count = 0;
      for (var item in out["sources"] as List) {
        if (item is! Map || item["url"] == null) continue;
        var file = _scriptFile(item["url"].toString(), dir);
        if (!file.existsSync()) _fail("找不到 ${item["key"]} 的脚本：${file.path}");
        item["signature"] = liveSourceSign(seed, file.readAsBytesSync());
        item.remove("sig");
        count++;
        stdout.writeln("✓ ${item["key"]}（${file.path}）");
      }
      File(indexPath).writeAsStringSync(
        "${const JsonEncoder.withIndent("  ").convert(out)}\n",
      );
      stdout.writeln(
        "已签名 $count 个源，公钥指纹 ${liveSourceKeyFingerprint(publicKey)}",
      );
      break;
    case "verify":
      if (rest.isEmpty) _fail("用法：verify <index.json> [--dir <脚本目录>]");
      var (dir, files) = _dirOption(rest, rest[0]);
      var index = _readIndex(files.first);
      var publicKey = index["publicKey"]?.toString();
      if (liveSourceDecodePublicKey(publicKey) == null) {
        _fail("index.json 没有有效的 publicKey");
      }
      var bad = 0;
      for (var item in index["sources"] as List) {
        if (item is! Map || item["url"] == null) continue;
        var file = _scriptFile(item["url"].toString(), dir);
        var sig =
            item["signature"]?.toString() ??
            (File("${file.path}.sig").existsSync()
                ? File("${file.path}.sig").readAsStringSync().trim()
                : null);
        var ok =
            file.existsSync() &&
            sig != null &&
            liveSourceVerify(publicKey!, file.readAsBytesSync(), sig);
        if (!ok) bad++;
        stdout.writeln("${ok ? "✓" : "✗"} ${item["key"]}（${file.path}）");
      }
      if (bad > 0) _fail("$bad 个源的签名不对（改了脚本要重新签名）");
      stdout.writeln("全部签名正确，公钥指纹 ${liveSourceKeyFingerprint(publicKey!)}");
      break;
    default:
      stdout.writeln(_usage);
      exit(64);
  }
}
