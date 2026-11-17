import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/windows_version.dart';

void main() {
  test("按引号后面的版本号判断 Windows 7", () {
    expect(
        WindowsVersion.isWindows7Text(
            '"Windows 7 Ultimate" 6.1 (Build 7601: Service Pack 1)'),
        isTrue);
    expect(WindowsVersion.isWindows7Text('"Windows Vista" 6.0 (Build 6002)'),
        isTrue);
    // 产品名里的 8.1 不算版本号
    expect(WindowsVersion.isWindows7Text('"Windows 8.1 Pro" 6.3 (Build 9600)'),
        isFalse);
    expect(
        WindowsVersion.isWindows7Text('"Windows 8" 6.2 (Build 9200)'), isFalse);
    expect(WindowsVersion.isWindows7Text('"Windows 10 Pro" 10.0 (Build 19045)'),
        isFalse);
    expect(WindowsVersion.isWindows7Text('"Windows 11 Pro" 10.0 (Build 26100)'),
        isFalse);
    expect(WindowsVersion.isWindows7Text("6.1.7601"), isTrue);
    expect(WindowsVersion.isWindows7Text(""), isFalse);
  });
}
