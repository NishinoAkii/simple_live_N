import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/settings/other/other_settings_controller.dart';

void main() {
  test('导出日志：所有日志文件按原来的名字放进一个 zip', () {
    var zip = OtherSettingsController.buildLogZip({
      "2026-11-14 21-00-00.log": utf8.encode("第一份"),
      "2026-11-14 22-00-00.log": utf8.encode("第二份"),
    });
    var archive = ZipDecoder().decodeBytes(zip);
    expect(archive.files.map((e) => e.name).toSet(),
        {"2026-11-14 21-00-00.log", "2026-11-14 22-00-00.log"});
    var second = archive.files.firstWhere((e) => e.name.startsWith("2026-11-14 22"));
    expect(utf8.decode(second.content as List<int>), "第二份");
  });

  test('调试模式关着（没有写日志的文件）时什么都不写', () async {
    Log.disposeWriter();
    expect(Log.logFileWriter, isNull);
    Log.writeLog("不该写进去");
    await Log.flush();
    expect(Log.logFileWriter, isNull);
  });
}
