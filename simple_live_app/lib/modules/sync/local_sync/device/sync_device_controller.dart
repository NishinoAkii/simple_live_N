import 'dart:convert';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/sync_client_info_model.dart';
import 'package:simple_live_app/requests/sync_client_request.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/live_source_service.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_app/services/sync_service.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class SyncDeviceController extends BaseController {
  final SyncClinet client;
  final SyncClientInfoModel info;
  SyncDeviceController({required this.client, required this.info});
  late final SyncClientRequest request =
      SyncClientRequest(peerKey: info.encKey);

  /// 对方是否支持新平台数据（官方版不支持，只发送官方版认识的平台）
  bool get peerSupportsExt => info.extSites.isNotEmpty;

  /// 对方是否能接收直播源（订阅与已安装的源）
  bool get peerSupportsLiveSources =>
      info.features.contains(kSyncFeatureLiveSources);

  Future<bool> showOverlayDialog() async {
    var overlay = await Utils.showAlertDialog(
      "要用本机数据覆盖对方设备上的数据吗？".t,
      title: "覆盖数据".t,
      confirm: "覆盖".t,
      cancel: "不覆盖".t,
    );
    return overlay;
  }

  void syncFollowAndTag() async {
    try {
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "同步中...".t);
      var ext = peerSupportsExt;
      var users = DBService.instance.getFollowList();
      var tags = DBService.instance.getFollowTagList();
      // 按对方声明支持的平台过滤（官方版只收官方平台）
      var sendUsers = SyncCompat.followsForPeer(users, info.extSites);
      var sendTags = SyncCompat.tagsForPeer(tags, info.extSites);
      var data = json.encode(sendUsers.map((e) => e.toJson()).toList());
      var dataT = json.encode(sendTags.map((e) => e.toJson()).toList());
      // js=1：本机支持直播源，对方覆盖时可以清掉它的直播源平台关注
      await request.syncFollow(client, data,
          overlay: overlay, ext: ext, js: ext);
      // 标签和关注必须同时同步
      await request.syncTag(client, dataT, overlay: overlay, ext: ext, js: ext);
      SmartDialog.showToast("已同步关注列表和标签".t);
    } catch (e) {
      SmartDialog.showToast("同步失败：{e}".tf({"e": e}));
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncHistory() async {
    try {
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "同步中...".t);
      var ext = peerSupportsExt;
      var histores = DBService.instance.getHistores();
      var sendHistories = SyncCompat.historiesForPeer(histores, info.extSites);
      var data = json.encode(sendHistories.map((e) => e.toJson()).toList());
      await request.syncHistory(client, data,
          overlay: overlay, ext: ext, js: ext);
      SmartDialog.showToast("已同步历史记录".t);
    } catch (e) {
      SmartDialog.showToast("同步失败：{e}".tf({"e": e}));
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncBlockedWord() async {
    try {
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "同步中...".t);
      // 发全局的关键词（开着直播间单独设置时也不发那个直播间的）
      var data = json.encode(AppSettingsController.instance.globalShieldList);
      await request.syncBlockedWord(client, data, overlay: overlay);
      // 屏蔽的人（永久的）和备注只发给支持的设备（本版本的新版）
      var users = ChatUsersService.maybeInstance;
      if (users != null && info.features.contains(kSyncFeatureChatUsers)) {
        await request.syncChatUsers(
          client,
          json.encode(users.exportSync()),
          overlay: overlay,
        );
      }
      SmartDialog.showToast("已同步屏蔽词".t);
    } catch (e) {
      SmartDialog.showToast("同步失败：{e}".tf({"e": e}));
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  /// 把本机的订阅和已安装的源（地址）发给对方，对方补上没有的，不会删除
  void syncLiveSources() async {
    if (!peerSupportsLiveSources) {
      SmartDialog.showToast("对方设备不支持同步直播源".t);
      return;
    }
    if (!LiveSourceService.registered) {
      return;
    }
    var data = LiveSourceService.instance.exportSyncData();
    if (LiveSourceSyncData.fromJson(data).isEmpty) {
      SmartDialog.showToast("本机没有直播源".t);
      return;
    }
    try {
      SmartDialog.showLoading(msg: "同步中...".t);
      await request.syncLiveSources(client, json.encode(data));
      SmartDialog.showToast("已发送直播源，对方正在安装".t);
    } catch (e) {
      SmartDialog.showToast("同步失败：{e}".tf({"e": e}));
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncBiliAccount() async {
    try {
      if (!BiliBiliAccountService.instance.logined.value) {
        SmartDialog.showToast("本机还没登录哔哩哔哩".t);
        return;
      }
      if (info.encKey == null) {
        SmartDialog.showToast("对方是官方版或旧版本，不能加密，账号不会发送".t);
        return;
      }
      SmartDialog.showLoading(msg: "同步中...".t);

      await request.syncBiliAccount(
          client, BiliBiliAccountService.instance.cookie);
      SmartDialog.showToast("已同步哔哩哔哩账号".t);
    } catch (e) {
      SmartDialog.showToast("同步失败：{e}".tf({"e": e}));
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }
}
