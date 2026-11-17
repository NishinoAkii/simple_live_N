import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:webdav_client/webdav_client.dart';

class DAVClient {
  late Client client;
  Completer<bool> pingCompleter = Completer();

  DAVClient(
    String webDAVUri,
    String webDAVUser,
    String webDAVPassword,
  ) {
    client = newClient(
      webDAVUri,
      user: webDAVUser,
      password: webDAVPassword,
    );
    client.setHeaders(
      {
        'accept-charset': 'utf-8',
        'Content-Type': 'text/xml',
      },
    );
    client.setConnectTimeout(8000);
    client.setSendTimeout(8000);
    client.setReceiveTimeout(8000);
    pingCompleter.complete(_ping());
  }

  Future<bool> _ping() async {
    try {
      await client.ping();
      return true;
    } catch (_) {
      return false;
    }
  }

  // 强制统一
  get root => "/simple_live_app";

  get backupFile => "$root/backup.zip";

  // 每个操作都先等 ping 结束。这个库第一次请求不带账号，收到 401 才换成带账号的再试；
  // 两个请求同时收到 401 时，第二个发现已经换过了就直接报错。
  // 手动上传没事，是因为打开页面时 ping 早就结束了。

  backup(Uint8List data) async {
    await pingCompleter.future;
    await client.mkdir("$root");
    await client.write("$backupFile", data);
    return true;
  }

  /// 和 Venera 一样在云端留几份旧存档，传错了还能找回来：每天一份，当天的覆盖，
  /// 最多 [keep] 份。旧版和手动恢复只读 backup.zip，不受影响
  Future<void> keepDailyCopy(
    Uint8List data,
    DateTime day, {
    int keep = 10,
  }) async {
    String two(int value) => value.toString().padLeft(2, "0");
    var name = "backup-${day.year}${two(day.month)}${two(day.day)}.zip";
    await client.write("$root/$name", data);
    var copies = [
      for (var file in await client.readDir(root))
        if (RegExp(r"^backup-\d{8}\.zip$").hasMatch(file.name ?? ""))
          file.name!,
    ]..sort();
    while (copies.length > keep) {
      await client.remove("$root/${copies.removeAt(0)}");
    }
  }

  /// 读取备份，云端没有时返回 null（只是看一眼，不创建目录）
  Future<List<int>?> readBackup() async {
    await pingCompleter.future;
    try {
      return await client.read(backupFile);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  /// 云端备份的修改时间，读不到时返回 null。
  /// 列文件夹而不是 readProps：它给文件路径多加一个斜杠，严格的服务器回 404
  Future<DateTime?> backupTime() async {
    await pingCompleter.future;
    try {
      var files = await client.readDir(root);
      for (var file in files) {
        if (file.name == "backup.zip") {
          return file.mTime;
        }
      }
    } catch (_) {}
    return null;
  }

  /// 备份的版本（修改时间和大小），和上次看到的一样就不用下载。
  /// 没有备份、服务器不让列目录时返回 null；连不上、账号不对时抛出异常
  Future<String?> backupVersion() async {
    await pingCompleter.future;
    try {
      for (var file in await client.readDir(root)) {
        if (file.name == "backup.zip" && file.mTime != null) {
          return "${file.mTime!.millisecondsSinceEpoch}|${file.size}";
        }
      }
      return null;
    } on DioException catch (e) {
      var code = e.response?.statusCode;
      if (code == null || code == 401) {
        rethrow;
      }
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<List<int>> recovery() async {
    await pingCompleter.future;
    await client.mkdir("$root");
    final data = await client.read(backupFile);
    return data;
  }
}
