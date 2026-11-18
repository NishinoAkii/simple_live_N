import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Rect;

import 'package:path/path.dart' as p;

/// 多开窗口的口令：每开一个副窗口生成一个，32 字节随机数（base64url，43 个字符）。
/// 副窗口关了就作废
class WindowToken {
  WindowToken._();

  static final _format = RegExp(r"^[A-Za-z0-9_-]{43}$");

  static String generate([Random? random]) {
    var r = random ?? Random.secure();
    var bytes = List<int>.generate(32, (_) => r.nextInt(256));
    return base64Url.encode(bytes).replaceAll("=", "");
  }

  static bool isWellFormed(String? value) =>
      value != null && _format.hasMatch(value);

  /// 比较口令，用时和哪一位不同无关
  static bool equals(String given, String expected) {
    var a = utf8.encode(given);
    var b = utf8.encode(expected);
    var diff = a.length ^ b.length;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ (i < b.length ? b[i] : 0);
    }
    return diff == 0;
  }
}

/// 主窗口开副窗口时带的启动参数。副窗口据此知道自己是第几个、读哪份数据、
/// 打开哪个直播间、放在哪里，以及把要保存的改动交给谁（本机端口和口令）。
///
/// 参数都写成 `--sl-名字=值`；有一项不对就当作没有（[parse] 返回 null），
/// 程序按普通方式启动
class SecondaryLaunch {
  static const flag = "--sl-secondary";

  /// 最多同时开几个副窗口
  static const maxWindows = 6;

  /// 副窗口的数据快照放在应用数据目录下的这个文件夹里
  static const snapshotFolder = "multi_window";

  final int port;
  final String token;

  /// 数据快照的目录（Hive 文件）
  final String dataDir;

  /// 第几个位置（1 到 [maxWindows]）
  final int slot;
  final String siteId;
  final String roomId;

  /// 窗口位置和大小（物理像素），为空时居中。平常是这个编号记住的位置（第一次用时错开放），
  /// “打开上次的窗口”时是上次的位置（显示之前就放好，不会先出现在别处再跳过去）
  final Rect? bounds;

  /// 目标屏幕的缩放（1.0 = 96 DPI）
  final double scale;

  /// 主窗口的进程号（只写进日志）
  final int mainPid;

  /// 一开始就置顶（主窗口置顶时开的窗口），显示之前就设好
  final bool pinned;

  const SecondaryLaunch({
    required this.port,
    required this.token,
    required this.dataDir,
    required this.slot,
    required this.siteId,
    required this.roomId,
    this.bounds,
    this.scale = 1.0,
    this.mainPid = 0,
    this.pinned = false,
  });

  List<String> toArgs() => [
        flag,
        "--sl-port=$port",
        "--sl-token=$token",
        "--sl-data=$dataDir",
        "--sl-slot=$slot",
        "--sl-site=$siteId",
        "--sl-room=$roomId",
        if (bounds != null)
          "--sl-bounds=${bounds!.left.round()},${bounds!.top.round()},"
              "${bounds!.width.round()},${bounds!.height.round()}",
        "--sl-scale=$scale",
        "--sl-main-pid=$mainPid",
        if (pinned) "--sl-pinned=1",
      ];

  static const _keys = {
    "port",
    "token",
    "data",
    "slot",
    "site",
    "room",
    "bounds",
    "scale",
    "main-pid",
    "pinned",
  };

  /// 没有 [flag] 或者有一项不对时返回 null
  static SecondaryLaunch? parse(List<String> args) {
    if (!args.contains(flag)) {
      return null;
    }
    var values = <String, String>{};
    for (var arg in args) {
      if (!arg.startsWith("--sl-") || arg == flag) {
        continue;
      }
      var eq = arg.indexOf("=");
      if (eq < 0) {
        return null;
      }
      var key = arg.substring(5, eq);
      if (!_keys.contains(key) || values.containsKey(key)) {
        return null;
      }
      values[key] = arg.substring(eq + 1);
    }
    var port = int.tryParse(values["port"] ?? "");
    var token = values["token"];
    var dataDir = values["data"] ?? "";
    var slot = int.tryParse(values["slot"] ?? "");
    var siteId = values["site"] ?? "";
    var roomId = values["room"] ?? "";
    var scale = double.tryParse(values["scale"] ?? "1");
    var mainPid = int.tryParse(values["main-pid"] ?? "0");
    var pinned = values["pinned"] ?? "0";
    if (port == null ||
        port < 1 ||
        port > 65535 ||
        !WindowToken.isWellFormed(token) ||
        dataDir.isEmpty ||
        !p.isAbsolute(dataDir) ||
        slot == null ||
        slot < 1 ||
        slot > maxWindows ||
        !_text(siteId) ||
        !_text(roomId) ||
        scale == null ||
        !(scale >= 0.5 && scale <= 8) ||
        mainPid == null ||
        (pinned != "0" && pinned != "1")) {
      return null;
    }
    Rect? bounds;
    if (values["bounds"] case var text?) {
      bounds = _parseBounds(text);
      if (bounds == null) {
        return null;
      }
    }
    return SecondaryLaunch(
      port: port,
      token: token!,
      dataDir: dataDir,
      slot: slot,
      siteId: siteId,
      roomId: roomId,
      bounds: bounds,
      scale: scale,
      mainPid: mainPid,
      pinned: pinned == "1",
    );
  }

  static bool _text(String value) =>
      value.isNotEmpty && value.length <= 256 && !value.contains("\n");

  static Rect? _parseBounds(String text) {
    var parts = text.split(",");
    if (parts.length != 4) {
      return null;
    }
    var n = parts.map(int.tryParse).toList();
    if (n.any((e) => e == null)) {
      return null;
    }
    var (x, y, w, h) = (n[0]!, n[1]!, n[2]!, n[3]!);
    const limit = 100000;
    if (x.abs() > limit || y.abs() > limit || w <= 0 || h <= 0) {
      return null;
    }
    if (w > limit || h > limit) {
      return null;
    }
    return Rect.fromLTWH(
        x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());
  }

  /// 数据目录要在应用数据目录的 [snapshotFolder] 里，不能指到别处
  bool dataDirUnder(String supportDir) => p.isWithin(
        p.normalize(p.join(supportDir, snapshotFolder)),
        p.normalize(dataDir),
      );
}
