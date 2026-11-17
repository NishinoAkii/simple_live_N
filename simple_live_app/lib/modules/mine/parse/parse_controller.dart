import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 认出了平台但解析失败（如 YouTube 查不到频道），[message] 直接提示给用户
class ParseLinkError implements Exception {
  final String message;
  ParseLinkError(this.message);

  @override
  String toString() => message;
}

class ParseController extends GetxController {
  final TextEditingController roomJumpToController = TextEditingController();
  final TextEditingController getUrlController = TextEditingController();

  /// YouTube 链接（可能夹在分享文字中间）：youtube.com、m.youtube.com、youtu.be 等；
  /// 前面不能紧跟字母数字，避免把 notyoutube.com 之类当成 YouTube
  static final RegExp _youTubeUrl = RegExp(
    r"(?<![\w-])(?:https?://)?(?:[\w-]+\.)*(?:youtube\.com|youtu\.be)/[^\s]*",
    caseSensitive: false,
  );

  /// YouTube 频道的 @名称（handle），可以是中文等非拉丁字符
  static final RegExp _youTubeHandle = RegExp(r"^@[^\s/?#@]{3,100}$");

  /// YouTube 频道 ID（就是房间号），不用联网
  static final RegExp _youTubeChannelId = RegExp(r"^UC[\w-]{22}$");

  static bool isYouTubeHandle(String text) =>
      _youTubeHandle.hasMatch(text.trim());

  /// 输入的是否是 YouTube 链接、@名称或频道 ID
  static bool isYouTubeInput(String text) {
    var input = text.trim();
    return _youTubeUrl.hasMatch(input) ||
        _youTubeHandle.hasMatch(input) ||
        _youTubeChannelId.hasMatch(input);
  }

  /// 把 YouTube 输入解析成频道 ID。
  ///
  /// 视频链接和 @名称要联网查所属频道，期间显示加载中；
  /// 查不到或出错时抛出 [ParseLinkError]，不能当成“无法解析”默默跳过。
  static Future<String> resolveYouTube(String text) async {
    var input = text.trim();
    if (_youTubeChannelId.hasMatch(input)) {
      return input;
    }
    var link = _youTubeUrl.firstMatch(input)?.group(0) ?? input;
    String? id;
    SmartDialog.showLoading(msg: "");
    try {
      id = await YouTubeSite.resolveRoomId(link);
    } catch (e) {
      Log.logPrint(e);
      throw ParseLinkError("读取 YouTube 频道失败：{p}".tf({"p": e is CoreError ? e.message : e}));
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
    if (id == null || id.isEmpty) {
      throw ParseLinkError(
        isYouTubeHandle(input) ? "找不到 YouTube 频道 {input}".tf({"input": input}) : "认不出这个 YouTube 链接".t,
      );
    }
    return id;
  }

  /// 解析链接；YouTube 等解析失败时提示具体原因并返回 null（调用方不用再提示）
  Future<List?> _parseWithToast(String url) async {
    try {
      return await parse(url);
    } on ParseLinkError catch (e) {
      SmartDialog.showToast(e.message);
      return null;
    }
  }

  void jumpToRoom(String e) async {
    if (e.isEmpty) {
      SmartDialog.showToast("请先输入链接".t);
      return;
    }
    // 隐藏键盘
    FocusManager.instance.primaryFocus?.unfocus();

    var parseResult = await _parseWithToast(e);
    if (parseResult == null) {
      return;
    }
    if (parseResult.isEmpty || parseResult.first == "") {
      SmartDialog.showToast("认不出这个链接".t);
      return;
    }

    // 延迟200ms跳转，等待键盘隐藏
    Future.delayed(const Duration(milliseconds: 200), () {
      Site site = parseResult[1];
      AppNavigator.toLiveRoomDetail(site: site, roomId: parseResult.first);
    });
  }

  void getPlayUrl(String e) async {
    if (e.isEmpty) {
      SmartDialog.showToast("请先输入链接".t);
      return;
    }
    var parseResult = await _parseWithToast(e);
    if (parseResult == null) {
      return;
    }
    if (parseResult.isEmpty || parseResult.first == "") {
      SmartDialog.showToast("认不出这个链接".t);
      return;
    }
    Site site = parseResult[1];
    try {
      SmartDialog.showLoading(msg: "");
      var detail = await site.liveSite.getRoomDetail(roomId: parseResult.first);
      var qualites = await site.liveSite.getPlayQualites(detail: detail);
      SmartDialog.dismiss(status: SmartStatus.loading);
      if (qualites.isEmpty) {
        SmartDialog.showToast("获取直链失败，没有读到清晰度".t);

        return;
      }
      var result = await Get.dialog(SimpleDialog(
        title: Text("选择清晰度".t),
        children: qualites
            .map(
              (e) => ListTile(
                title: Text(
                  e.quality.t,
                  textAlign: TextAlign.center,
                ),
                onTap: () {
                  Get.back(result: e);
                },
              ),
            )
            .toList(),
      ));
      if (result == null) {
        return;
      }
      SmartDialog.showLoading(msg: "");
      var playUrl =
          await site.liveSite.getPlayUrls(detail: detail, quality: result);
      SmartDialog.dismiss(status: SmartStatus.loading);
      await Get.dialog(SimpleDialog(
        title: Text("选择线路".t),
        children: playUrl.urls
            .map(
              (e) => ListTile(
                title: Text(
                  "线路{p}".tf({"p": playUrl.urls.indexOf(e) + 1}),
                ),
                subtitle: Text(
                  e,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: e));
                  Get.back();
                  SmartDialog.showToast("已复制直链".t);
                },
              ),
            )
            .toList(),
      ));
    } catch (e) {
      SmartDialog.showToast("获取直链失败".t);
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 解析直播间链接，返回 [房间号, 平台]，认不出时返回空列表；
  /// YouTube 要联网查所属频道，查不到或出错时抛出 [ParseLinkError]
  Future<List> parse(String url) async {
    var id = "";
    if (url.contains("bilibili.com")) {
      var regExp = RegExp(r"bilibili\.com/([\d|\w]+)");
      id = regExp.firstMatch(url)?.group(1) ?? "";
      return [id, Sites.allSites[Constant.kBiliBili]!];
    }

    if (url.contains("b23.tv")) {
      var btvReg = RegExp(r"https?:\/\/b23.tv\/[0-9a-z-A-Z]+");
      var u = btvReg.firstMatch(url)?.group(0) ?? "";
      var location = await getLocation(u);

      return await parse(location);
    }

    if (url.contains("douyu.com")) {
      var regExp = RegExp(r"douyu\.com/([\d|\w]+)");
      // 适配 topic_url
      if (url.contains("topic")) {
        regExp = RegExp(r"[?&]rid=([\d]+)");
      }
      id = regExp.firstMatch(url)?.group(1) ?? "";

      return [id, Sites.allSites[Constant.kDouyu]!];
    }
    if (url.contains("huya.com")) {
      var regExp = RegExp(r"huya\.com/([\d|\w]+)");
      id = regExp.firstMatch(url)?.group(1) ?? "";

      return [id, Sites.allSites[Constant.kHuya]!];
    }
    if (url.contains("live.douyin.com")) {
      var regExp = RegExp(r"live\.douyin\.com/([\d|\w]+)");
      id = regExp.firstMatch(url)?.group(1) ?? "";

      return [id, Sites.allSites[Constant.kDouyin]!];
    }
    if (url.contains("webcast.amemv.com")) {
      var regExp = RegExp(r"reflow/(\d+)");
      id = regExp.firstMatch(url)?.group(1) ?? "";
      return [id, Sites.allSites[Constant.kDouyin]!];
    }
    if (url.contains("v.douyin.com")) {
      var regExp = RegExp(r"http.?://v.douyin.com/[\d\w]+/");
      var u = regExp.firstMatch(url)?.group(0) ?? "";
      var location = await getLocation(u);
      return await parse(location);
    }
    if (url.contains("twitch.tv")) {
      // www.twitch.tv/<login>、m.twitch.tv/<login>，排除目录、视频等页面
      var regExp = RegExp(r"twitch\.tv/(?:popout/)?([A-Za-z0-9_]{2,25})",
          caseSensitive: false);
      id = regExp.firstMatch(url)?.group(1)?.toLowerCase() ?? "";
      const reserved = {
        "directory",
        "videos",
        "settings",
        "login",
        "signup",
        "search",
        "downloads",
        "p",
        "subscriptions",
        "wallet",
        "inventory",
        "drops",
      };
      if (reserved.contains(id)) {
        id = "";
      }
      return [id, Sites.allSites[Constant.kTwitch]!];
    }
    if (url.contains("kick.com")) {
      var regExp = RegExp(r"kick\.com/(?:popout/)?([A-Za-z0-9_-]+)",
          caseSensitive: false);
      id = regExp.firstMatch(url)?.group(1)?.toLowerCase() ?? "";
      const reserved = {"category", "categories", "browse", "search", "video"};
      if (reserved.contains(id)) {
        id = "";
      }
      return [id, Sites.allSites[Constant.kKick]!];
    }
    // YouTube 放在最后：@名称、频道 ID 没有域名，先排除其它平台的链接
    if (isYouTubeInput(url)) {
      id = await resolveYouTube(url);
      return [id, Sites.allSites[Constant.kYouTube]!];
    }
    // 已安装的直播源：脚本里的 links 正则，第 1 组为房间号
    var script = Sites.matchScriptLink(url);
    if (script != null) {
      return [script.$1, script.$2];
    }

    return [];
  }

  Future<String> getLocation(String url) async {
    try {
      if (url.isEmpty) return "";
      await Dio().get(
        url,
        options: Options(
          followRedirects: false,
        ),
      );
    } on DioException catch (e) {
      if (e.response!.statusCode == 302) {
        var redirectUrl = e.response!.headers.value("Location");
        if (redirectUrl != null) {
          return redirectUrl;
        }
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return "";
  }
}
