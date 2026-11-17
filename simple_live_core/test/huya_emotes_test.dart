import 'dart:io';
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/model/tars/get_expression_emoticon_package_resp.dart';
import 'package:tars_dart/tars/net/base_tars_http.dart';
import 'package:tars_dart/tars/tup/tup_response.dart';
import 'package:test/test.dart';

/// 实测的 wupui.getExpressionEmoticonPackage 返回
/// （房间 660000，精简成每个包几个表情，重新编码）
TupResponse<GetExpressionEmoticonPackageResp> decode() {
  var bytes = File(
    'test/fixtures/huya/emoticon_packages.bin',
  ).readAsBytesSync();
  return BaseTarsHttp("https://wup.huya.com", "wupui").tupResponseDecode(
    "getExpressionEmoticonPackage",
    Uint8List.fromList(bytes),
    GetExpressionEmoticonPackageResp(),
  );
}

List<HuyaExpressionEmoticonPackage> packages() => decode().response!.vPackage;

void main() {
  test('TARS 解码', () {
    expect(decode().code, 0);
    var list = packages();
    expect(list.map((e) => e.sName), [
      "LPL通行证梗表情",
      "梗表情",
      "虎牙默认表情",
      "贵族静态表情",
      "Lv.14专属表情",
      "Lv.22专属动态表情",
    ]);
    var huaji = list[2].vEmoticon.firstWhere((e) => e.sName == "[滑稽]");
    expect(huaji.sEscape, "/{hj");
    expect(huaji.sUrl, startsWith("http://cdnfile2.msstatic.com/"));
    expect(list[1].iType, 2);
  });

  group('表情包', () {
    var emoticons = parseHuyaEmoticonPackages(packages());

    test('小表情按名称和转义都能查到，地址升级成 https', () {
      var wh = emoticons.inline["/{lol_wh"]!;
      expect(wh.text, "/{lol_wh");
      expect(wh.url, startsWith("https://cdnfile2.msstatic.com/"));
      expect(emoticons.inline["[问]"]!.url, wh.url);
      // 等级、贵族表情也在
      expect(emoticons.inline.keys, containsAll(["[狗头]", "/{s_666", "[奥利给]"]));
      // 小表情不当作大表情
      expect(emoticons.stickers.containsKey("[问]"), isFalse);
    });

    test('梗表情用 _3 的图片，只当作整条的大表情', () {
      var bushi = emoticons.stickers["/{bushi"]!;
      expect(
        bushi.url,
        "https://fileserver.cdn.huya.com/web_admin_material_zip_url/"
        "809a798714164c70a3f24feb090043b4/expressconfig/steam_3.png",
      );
      expect(bushi.staticUrl, isNull);
      expect(emoticons.stickers["[不是哥们2]"]!.url, bushi.url);
      expect(emoticons.inline.containsKey("/{bushi"), isFalse);
      // 带了 sExtraFlexiUrl（webp）的也用 _3.png：实测它的 webp 是 404
      var jl = emoticons.stickers["[这回是真寄了]"]!;
      expect(jl.url, endsWith("/steam_3.png"));
      expect(jl.staticUrl, isNull);
    });

    test('整条消息是梗表情时是大表情', () {
      var sticker = huyaEmoteSticker("/{bushi", emoticons)!;
      expect(sticker.text, "/{bushi");
      expect(sticker.url, endsWith("/steam_3.png"));
      expect(huyaEmoteSticker("好/{bushi", emoticons), isNull);
      expect(huyaEmoteSticker("[问]", emoticons), isNull);
      expect(huyaEmoteSticker("/{bushi", null), isNull);
    });
  });

  group('消息里的表情', () {
    test('转义贪婪匹配后整个查表', () {
      var emoticons = parseHuyaEmoticonPackages(packages());
      var emotes = parseHuyaEmotes(
        "/{lol_wh 好/{dxabc[滑稽]/{dx",
        packages: emoticons,
      )!;
      expect(emotes.map((e) => e.text), ["/{lol_wh", "[滑稽]", "/{dx"]);
      // 表情包里有的用表情包的图片
      expect(emotes[2].url, startsWith("https://cdnfile2.msstatic.com/"));
      var parts = splitLiveEmotes("/{lol_wh 好/{dxabc[滑稽]/{dx", emotes);
      expect(parts.where((e) => e.isEmote).map((e) => e.text), [
        "/{lol_wh",
        "[滑稽]",
        "/{dx",
      ]);
    });

    test('没有表情包时用内置的默认表情', () {
      var emotes = parseHuyaEmotes("[赞][赞]/{dxabc /{dx[滑稽]")!;
      expect(emotes.map((e) => e.text), ["[赞]", "/{dx"]);
      expect(
        emotes.last.url,
        "https://a.msstatic.com/huya/main/emot_png/dx.png",
      );
      expect(parseHuyaEmotes("普通弹幕", packages: const HuyaEmoticons()), isNull);
    });

    test('直播间的表情包每个直播间读一次', () async {
      HuyaRoomEmotes.debugReset();
      addTearDown(HuyaRoomEmotes.debugReset);
      var calls = 0;
      Future<List<HuyaExpressionEmoticonPackage>> fetch() async {
        calls++;
        return packages();
      }

      await HuyaRoomEmotes.load(1346609715, fetch);
      await HuyaRoomEmotes.load(1346609715, fetch);
      expect(calls, 1);
      expect(HuyaRoomEmotes.of(1346609715)!.inline, contains("[滑稽]"));
      // 没有主播 uid 时不请求
      await HuyaRoomEmotes.load(0, fetch);
      expect(calls, 1);
      expect(HuyaRoomEmotes.of(0), isNull);
    });

    test('参数', () {
      var args = HuyaDanmakuArgs(ayyuid: 1, topSid: 2, subSid: 3);
      expect(args.presenterUid, 0);
      expect(args.toString(), contains('"gid":0'));
    });
  });
}
