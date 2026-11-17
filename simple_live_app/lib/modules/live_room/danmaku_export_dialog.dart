import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_share.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/obs_bridge/danmaku_recorder.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 导出好以后显示保存位置：电脑上可以打开文件夹，手机上可以分享
Future<void> showExportedFile(
  File file, {
  required String title,
  required String summary,
}) async {
  var desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  var go = await Utils.showAlertDialog(
    "{summary}\n\n保存在：\n{path}".tf({"summary": summary, "path": file.path}),
    title: title,
    confirm: desktop ? "打开文件夹".t : "分享".t,
    cancel: "关闭".t,
    selectable: true,
  );
  if (!go) {
    return;
  }
  if (desktop) {
    await DanmakuAssRecorder.reveal(file);
    return;
  }
  try {
    await AppShare.share(ShareParams(files: [XFile(file.path)]));
  } catch (e) {
    Log.logPrint(e);
    SmartDialog.showToast("分享失败：{e}".tf({"e": e}));
  }
}

/// 直播间的“导出弹幕（ASS）”：选导出哪些内容、时间轴从哪里算
Future<void> showLiveExportDialog(LiveRoomController controller) async {
  var chatCount = controller.exportableChatCount;
  var scCount = controller.exportableSuperChatCount;
  var giftCount = controller.giftBook.records.length;
  var hasStart = controller.hasLiveStartTime;
  var chats = true;
  var superChats = true;
  var gifts = true;
  var alignLiveStart = hasStart;
  var ok = await Get.dialog<bool>(
    StatefulBuilder(
      builder: (context, setState) {
        Widget check(String title, bool value, ValueChanged<bool> onChanged) =>
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(title),
              value: value,
              onChanged: (e) => setState(() => onChanged(e ?? false)),
            );
        return AlertDialog(
          title: Text("导出弹幕（ASS）".t),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ("导出进入直播间后收到的内容，保存为 ASS 弹幕文件，"
                  "可在播放器中与视频一同加载。").t,
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                check("弹幕（{chatCount} 条）".tf({"chatCount": chatCount}), chats, (e) => chats = e),
                if (controller.supportsSuperChat)
                  check("SC（{scCount} 条）".tf({"scCount": scCount}), superChats, (e) => superChats = e),
                if (controller.supportsGifts)
                  check("礼物（{giftCount} 条）".tf({"giftCount": giftCount}), gifts, (e) => gifts = e),
                const Divider(),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text("按开播时间对齐".t),
                  // 有开播时间时标题已经说清楚了，没有时才加一句说明
                  subtitle: hasStart ? null : Text("平台未提供开播时间，以第一条记录为 0 秒".t),
                  value: alignLiveStart,
                  onChanged: hasStart
                      ? (e) => setState(() => alignLiveStart = e)
                      : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: false),
              child: Text("取消".t),
            ),
            TextButton(
              onPressed: () => Get.back(result: true),
              child: Text("导出".t),
            ),
          ],
        );
      },
    ),
  );
  if (ok != true) {
    return;
  }
  try {
    var result = await controller.exportDanmakuAss(
      chats: chats,
      superChats: controller.supportsSuperChat && superChats,
      gifts: controller.supportsGifts && gifts,
      alignLiveStart: alignLiveStart,
    );
    if (result == null) {
      return;
    }
    await showExportedFile(
      result.$1,
      title: "导出弹幕（ASS）".t,
      summary: result.$2,
    );
  } catch (e) {
    Log.logPrint(e);
    SmartDialog.showToast("导出失败：{e}".tf({"e": e}));
  }
}
