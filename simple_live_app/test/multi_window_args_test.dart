import 'dart:io';
import 'dart:math';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simple_live_app/app/multi_window/window_args.dart';

// 多开：副窗口的启动参数和口令

void main() {
  var support = p.join(Directory.systemTemp.path, "sl_support");
  var dataDir = p.join(support, "multi_window", "w2-1700000000000");

  SecondaryLaunch sample({Rect? bounds}) => SecondaryLaunch(
        port: 50123,
        token: WindowToken.generate(Random(1)),
        dataDir: dataDir,
        slot: 2,
        siteId: "douyu",
        roomId: "9999 房间",
        bounds: bounds ?? const Rect.fromLTWH(1928, 8, 948, 508),
        scale: 1.5,
        mainPid: 4321,
      );

  group("口令", () {
    test("随机生成，43 个字符，每次不一样", () {
      var a = WindowToken.generate();
      var b = WindowToken.generate();
      expect(a.length, 43);
      expect(WindowToken.isWellFormed(a), isTrue);
      expect(a, isNot(b));
    });

    test("比较：一样才算对，长度不同、差一位、空的都不对", () {
      var t = WindowToken.generate();
      expect(WindowToken.equals(t, t), isTrue);
      expect(WindowToken.equals("${t}x", t), isFalse);
      expect(WindowToken.equals(t.substring(0, 42), t), isFalse);
      var last = t.substring(42) == "A" ? "B" : "A";
      expect(WindowToken.equals(t.substring(0, 42) + last, t), isFalse);
      expect(WindowToken.equals("", t), isFalse);
    });

    test("格式不对的不认", () {
      expect(WindowToken.isWellFormed(null), isFalse);
      expect(WindowToken.isWellFormed("short"), isFalse);
      expect(WindowToken.isWellFormed("${"a" * 42}="), isFalse);
      expect(WindowToken.isWellFormed("${"a" * 42}/"), isFalse);
    });
  });

  group("启动参数", () {
    test("写出去再读回来一样", () {
      var launch = sample();
      var parsed = SecondaryLaunch.parse(launch.toArgs())!;
      expect(parsed.port, 50123);
      expect(parsed.token, launch.token);
      expect(parsed.dataDir, dataDir);
      expect(parsed.slot, 2);
      expect(parsed.siteId, "douyu");
      expect(parsed.roomId, "9999 房间");
      expect(parsed.bounds, const Rect.fromLTWH(1928, 8, 948, 508));
      expect(parsed.scale, 1.5);
      expect(parsed.mainPid, 4321);
    });

    test("第 5、6 个窗口也能开", () {
      for (var slot in [5, 6]) {
        var args = sample()
            .toArgs()
            .where((e) => !e.startsWith("--sl-slot="))
            .toList()
          ..add("--sl-slot=$slot");
        expect(SecondaryLaunch.parse(args)?.slot, slot);
      }
    });

    test("打开上次的窗口：上次的位置和缩放原样带过去（负坐标的左边副屏、150%）", () {
      // 主窗口算好的位置都是整数像素；左边副屏的坐标是负的
      for (var (bounds, scale) in [
        (const Rect.fromLTWH(-2548, 12, 837, 746), 1.5),
        (const Rect.fromLTWH(1932, -188, 1200, 700), 1.25),
        (const Rect.fromLTWH(0, 0, 400, 300), 2.0),
      ]) {
        var launch = SecondaryLaunch(
          port: 50123,
          token: WindowToken.generate(),
          dataDir: dataDir,
          slot: 6,
          siteId: "bilibili",
          roomId: "21452505",
          bounds: bounds,
          scale: scale,
        );
        var parsed = SecondaryLaunch.parse(launch.toArgs())!;
        expect(parsed.bounds, bounds);
        expect(parsed.scale, scale);
        expect(parsed.slot, 6);
      }
      // 带小数的位置按整数像素传
      var fractional =
          sample(bounds: const Rect.fromLTWH(10.4, 20.6, 300.5, 200));
      expect(SecondaryLaunch.parse(fractional.toArgs())!.bounds,
          const Rect.fromLTWH(10, 21, 301, 200));
    });

    test("主窗口置顶时开的：带着置顶，显示之前就设好；没置顶时不带", () {
      var plain = sample();
      expect(plain.toArgs().any((e) => e.startsWith("--sl-pinned")), isFalse);
      expect(SecondaryLaunch.parse(plain.toArgs())!.pinned, isFalse);
      var pinned = SecondaryLaunch(
        port: 50123,
        token: WindowToken.generate(),
        dataDir: dataDir,
        slot: 3,
        siteId: "douyu",
        roomId: "1",
        bounds: const Rect.fromLTWH(-2548, 12, 837, 746),
        scale: 1.5,
        pinned: true,
      );
      var parsed = SecondaryLaunch.parse(pinned.toArgs())!;
      expect(parsed.pinned, isTrue);
      expect(parsed.bounds, const Rect.fromLTWH(-2548, 12, 837, 746));
      expect(
          SecondaryLaunch.parse([...plain.toArgs(), "--sl-pinned=0"])!.pinned,
          isFalse);
      expect(SecondaryLaunch.parse([...plain.toArgs(), "--sl-pinned=yes"]),
          isNull);
    });

    test("没有 --sl-secondary 就是普通启动", () {
      var args = sample().toArgs()..remove(SecondaryLaunch.flag);
      expect(SecondaryLaunch.parse(args), isNull);
      expect(SecondaryLaunch.parse(const []), isNull);
    });

    test("别的参数不影响", () {
      var args = ["--some-flag", ...sample().toArgs(), "file.txt"];
      expect(SecondaryLaunch.parse(args), isNotNull);
    });

    test("没有位置时居中（bounds 为空）", () {
      var args = sample()
          .toArgs()
          .where((e) => !e.startsWith("--sl-bounds="))
          .toList();
      var parsed = SecondaryLaunch.parse(args)!;
      expect(parsed.bounds, isNull);
    });

    List<String> replace(String key, String? value) {
      var args =
          sample().toArgs().where((e) => !e.startsWith("--sl-$key=")).toList();
      if (value != null) {
        args.add("--sl-$key=$value");
      }
      return args;
    }

    test("有一项不对就不认", () {
      var bad = <List<String>>[
        replace("port", "0"),
        replace("port", "70000"),
        replace("port", "abc"),
        replace("port", null),
        replace("token", "short"),
        replace("token", null),
        replace("data", "relative/dir"),
        replace("data", ""),
        replace("slot", "0"),
        replace("slot", "7"),
        replace("site", ""),
        replace("room", ""),
        replace("room", "a" * 300),
        replace("bounds", "1,2,3"),
        replace("bounds", "1,2,0,4"),
        replace("bounds", "1,2,-3,4"),
        replace("bounds", "x,2,3,4"),
        replace("scale", "0"),
        replace("scale", "nan"),
        [...sample().toArgs(), "--sl-unknown=1"],
        [...sample().toArgs(), "--sl-port=50124"], // 重复
        [...sample().toArgs(), "--sl-port"], // 没有值
      ];
      for (var args in bad) {
        expect(SecondaryLaunch.parse(args), isNull, reason: args.join(" "));
      }
    });

    test("数据目录必须在应用数据目录的 multi_window 里", () {
      expect(sample().dataDirUnder(support), isTrue);
      var outside = SecondaryLaunch(
        port: 1,
        token: WindowToken.generate(),
        dataDir: p.join(support, "elsewhere"),
        slot: 1,
        siteId: "a",
        roomId: "b",
      );
      expect(outside.dataDirUnder(support), isFalse);
      var escape = SecondaryLaunch(
        port: 1,
        token: WindowToken.generate(),
        dataDir: p.join(support, "multi_window", "..", "x"),
        slot: 1,
        siteId: "a",
        roomId: "b",
      );
      expect(escape.dataDirUnder(support), isFalse);
      // 快照根目录本身不行
      var root = SecondaryLaunch(
        port: 1,
        token: WindowToken.generate(),
        dataDir: p.join(support, "multi_window"),
        slot: 1,
        siteId: "a",
        roomId: "b",
      );
      expect(root.dataDirUnder(support), isFalse);
    });
  });
}
