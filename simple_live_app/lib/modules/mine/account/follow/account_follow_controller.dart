import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/account_follow/account_follow_models.dart';
import 'package:simple_live_app/services/account_follow/account_follow_platforms.dart';
import 'package:simple_live_app/services/account_follow_service.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/kick_account_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';
import 'package:simple_live_app/services/youtube_account_service.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 账号关注：各平台的导入、同步入口，“同步到账号”开关和待同步列表
class AccountFollowController extends GetxController {
  AccountFollowService? get service => AccountFollowService.maybe;

  /// 各平台的登录状态（响应式），没有登录功能的平台为 null
  ({RxBool logined, RxString name})? account(String siteId) {
    switch (siteId) {
      case Constant.kBiliBili:
        var s = BiliBiliAccountService.instance;
        return (logined: s.logined, name: s.name);
      case Constant.kDouyu:
        var s = DouyuAccountService.instance;
        return (logined: s.logined, name: s.name);
      case Constant.kKick:
        var s = KickAccountService.instance;
        return (logined: s.logined, name: s.name);
      case Constant.kTwitch:
        var s = TwitchAccountService.instance;
        return (logined: s.logined, name: s.name);
      case Constant.kYouTube:
        var s = YouTubeAccountService.instance;
        return (logined: s.logined, name: s.name);
    }
    return null;
  }

  bool canRead(String siteId) =>
      AccountFollowService.siteOf(siteId)?.canReadAccountFollows ?? false;

  bool _check(String siteId) {
    if (service == null) {
      SmartDialog.showToast("账号关注没能启动，请重启 App 再试".t);
      return false;
    }
    if (!canRead(siteId)) {
      SmartDialog.showToast(
        "请先在账号管理里登录{siteName}".tf({"siteName": AccountFollowService.siteName(siteId)}),
      );
      return false;
    }
    return true;
  }

  void openImport(String siteId) {
    if (_check(siteId)) {
      Get.toNamed(RoutePath.kAccountFollowImport, arguments: siteId);
    }
  }

  void openSync(String siteId) {
    if (_check(siteId)) {
      Get.toNamed(RoutePath.kAccountFollowSync, arguments: siteId);
    }
  }

  /// 打开“同步到账号”前说明风险，确认后才打开
  Future<void> toggleWriteBack(
      AccountFollowPlatform platform, bool value) async {
    var service = this.service;
    if (service == null) {
      return;
    }
    if (!value) {
      await service.setWriteBack(platform.siteId, false);
      var left = service.jobs.where((e) => e.siteId == platform.siteId).length;
      if (left > 0) {
        SmartDialog.showToast("还有 {left} 条没同步，打开开关会继续，也可在下面放弃".tf({"left": left}));
      }
      return;
    }
    var name = platform.name;
    if (!canRead(platform.siteId)) {
      SmartDialog.showToast("请先在账号管理里登录{name}".tf({"name": name}));
      return;
    }
    var word = platform.followWord;
    var youtube = platform.siteId == Constant.kYouTube &&
        YouTubeAccountService.instance.hasOAuth;
    var ok = await Get.dialog<bool>(
      AlertDialog(
        title: Text("同步到{name}账号".tf({"name": name})),
        content: SingleChildScrollView(
          child: Text(
            ("打开后，在 App 里{word}或取消{word}{name}主播时，"
            "会用你的{name}账号做同样的操作。\n\n"
            "· App 里马上生效，账号那边逐条同步，每条隔几秒；\n"
            "· 频繁{word}/取消{word}可能触发风控，触发时自动暂停；\n"
            "· 从账号导入、WebDAV/局域网恢复不会改动账号；\n"
            "· 取关时可选“仅在 App 里取消”。"
            "{p}").tf({"word": word, "name": name, "p": youtube ? "\n· 官方授权每条用 50 点配额（每天共 10000 点）。".t : ""}),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: Text("取消".t),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: Text("打开".t),
          ),
        ],
      ),
    );
    if (ok == true) {
      await service.setWriteBack(platform.siteId, true);
    }
  }

  /// 待同步的一条的状态文字
  String jobStatus(FollowWriteJob job) {
    var service = this.service;
    if (service == null) {
      return "";
    }
    if (service.isInFlight(job.id)) {
      return "正在同步".t;
    }
    if (job.state == FollowWriteState.failed) {
      return "失败：{lastError}".tf({"lastError": job.lastError});
    }
    if (!service.isWriteBackOn(job.siteId)) {
      return "同步开关已关闭".t;
    }
    var state = service.siteStates[job.siteId];
    if (state != null && state.isPaused(DateTime.now())) {
      return "已暂停".t;
    }
    var next = job.nextAttemptAt;
    if (next != null && next.isAfter(DateTime.now())) {
      return ("第 {attempts} 次没成功，{timeText} 重试"
          "{p}").tf({"attempts": job.attempts, "timeText": timeText(next), "p": job.lastError.isEmpty ? "" : "（{error}）".tf({"error": job.lastError})});
    }
    return "等待中".t;
  }

  static String timeText(DateTime time) {
    var now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, "0");
    var hm = "${two(time.hour)}:${two(time.minute)}";
    if (time.year == now.year &&
        time.month == now.month &&
        time.day == now.day) {
      return hm;
    }
    return "{month}月{day}日 {hm}".tf({"month": time.month, "day": time.day, "hm": hm});
  }

  /// 暂停说明，没有暂停时为 null
  String? pauseText(String siteId) {
    var state = service?.siteStates[siteId];
    if (state == null || !state.isPaused(DateTime.now())) {
      return null;
    }
    var until = state.pausedUntil;
    var text = state.message.isEmpty ? "已暂停".t : state.message;
    return until == null ? text : "{text}（暂停到 {timeText}）".tf({"text": text, "timeText": timeText(until)});
  }

  void retry(FollowWriteJob job) => service?.retry(job.id);

  void discard(FollowWriteJob job) {
    if (service?.isInFlight(job.id) ?? false) {
      SmartDialog.showToast("这一条正在同步，稍等一下".t);
      return;
    }
    service?.discard(job.id);
  }

  void resume(String siteId) => service?.resumeSite(siteId);
}
