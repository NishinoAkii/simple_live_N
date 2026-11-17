import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/parse/parse_controller.dart';
import 'package:simple_live_app/services/youtube_account_service.dart';
import 'package:simple_live_app/widgets/superchat_card.dart';
import 'package:simple_live_core/simple_live_core.dart';

const channelId = "UCSJ4gkVC6NrvII8umztf0Ow";

void main() {
  group("YouTube 链接识别", () {
    test("recognises links, share text, @handles and channel ids", () {
      for (var input in [
        "https://www.youtube.com/watch?v=jfKfPfyJRdk",
        "https://m.youtube.com/@LofiGirl/live",
        "youtube.com/channel/$channelId",
        "https://youtu.be/jfKfPfyJRdk?si=abc",
        "看直播 https://youtu.be/jfKfPfyJRdk 快来",
        "https://www.youtube.com/live/jfKfPfyJRdk",
        "@LofiGirl",
        "  @中文频道名  ",
        channelId,
      ]) {
        expect(ParseController.isYouTubeInput(input), isTrue, reason: input);
      }
    });

    test("leaves other input alone", () {
      for (var input in [
        "https://www.twitch.tv/xqc",
        "https://live.bilibili.com/123",
        "https://notyoutube.com/watch?v=x",
        "英雄联盟",
        "@ab",
        "mail@example.com",
        "UC123",
      ]) {
        expect(ParseController.isYouTubeInput(input), isFalse, reason: input);
      }
      expect(ParseController.isYouTubeHandle("@LofiGirl"), isTrue);
      expect(ParseController.isYouTubeHandle("https://youtu.be/x"), isFalse);
    });

    test("channel ids need no network", () async {
      expect(await ParseController.resolveYouTube(" $channelId "), channelId);
      var result = await ParseController().parse(channelId);
      expect(result.first, channelId);
      expect((result[1] as Site).id, "youtube");
      expect(Sites.allSites["youtube"]!.liveSite, isA<YouTubeSite>());
      // 其它平台的链接不受影响
      var twitch = await ParseController().parse("https://www.twitch.tv/xqc");
      expect((twitch[1] as Site).id, "twitch");
    });
  });

  group("YouTube 账号", () {
    test("pasted cookies are cleaned up", () {
      expect(
        YouTubeAccountService.normalizeCookie(
            "Cookie: SID=1;\n SAPISID=abc/def ; ;HSID=2\r\n"),
        "SID=1; SAPISID=abc/def; HSID=2",
      );
      expect(YouTubeAccountService.normalizeCookie("  "), "");
    });

    test("cookies need SAPISID or __Secure-3PAPISID", () {
      expect(YouTubeAccountService.hasApiSid("SID=1; SAPISID=abc"), isTrue);
      expect(YouTubeAccountService.hasApiSid("__Secure-3PAPISID=x; SID=1"),
          isTrue);
      expect(YouTubeAccountService.hasApiSid("SID=1; APISID=2"), isFalse);
      expect(YouTubeAccountService.hasApiSid("XSAPISID=2"), isFalse);
      expect(YouTubeAccountService.hasApiSid("SAPISID="), isFalse);
    });

    test("token and channel round-trip through storage strings", () {
      var token = YouTubeOAuthToken(
        accessToken: "access",
        refreshToken: "refresh",
        expiresAt: DateTime.fromMillisecondsSinceEpoch(1800000000000),
      );
      var decoded =
          YouTubeAccountService.decodeToken(jsonEncode(token.toJson()))!;
      expect(decoded.accessToken, "access");
      expect(decoded.refreshToken, "refresh");
      expect(decoded.expiresAt, token.expiresAt);
      expect(YouTubeAccountService.decodeToken(""), isNull);
      expect(YouTubeAccountService.decodeToken("not json"), isNull);
      expect(YouTubeAccountService.decodeToken("{}"), isNull);

      const channel = YouTubeChannelInfo(
        id: channelId,
        title: "Lofi Girl",
        avatar: "https://yt3.ggpht.com/a=s88",
      );
      var restored = YouTubeAccountService.decodeChannel(
          YouTubeAccountService.encodeChannel(channel))!;
      expect(restored.id, channel.id);
      expect(restored.title, channel.title);
      expect(restored.avatar, channel.avatar);
      expect(YouTubeAccountService.encodeChannel(null), "");
      expect(YouTubeAccountService.decodeChannel(""), isNull);
    });
  });

  group("SC 金额", () {
    LiveSuperChatMessage superChat({String? priceText}) => LiveSuperChatMessage(
          backgroundBottomColor: "#E62117",
          backgroundColor: "#D00000",
          endTime: DateTime(2026, 1, 1, 0, 1),
          face: "",
          message: "hello",
          price: 30,
          startTime: DateTime(2026),
          userName: "viewer",
          priceText: priceText,
        );

    Future<void> pump(WidgetTester tester, LiveSuperChatMessage message) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(body: SuperChatCard(message, remaining: 10)),
        ));

    testWidgets("shows the amount with its currency when given",
        (tester) async {
      await pump(tester, superChat(priceText: r"$5.00"));
      expect(find.text(r"$5.00"), findsOneWidget);
      expect(find.text("￥30"), findsNothing);
    });

    testWidgets("falls back to yuan", (tester) async {
      await pump(tester, superChat());
      expect(find.text("￥30"), findsOneWidget);
    });
  });
}
