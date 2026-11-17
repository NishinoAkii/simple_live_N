import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/site_logo.dart';
import 'dart:ui' as ui;
import 'package:simple_live_app/i18n/i18n.dart';

class FollowUserItem extends StatelessWidget {
  final FollowUser item;
  final Function()? onRemove;
  final Function()? onTap;
  final Function()? onLongPress;

  /// 点铃铛：订阅或取消开播提醒。为 null 时不显示铃铛
  final Function()? onToggleNotify;
  final bool playing;
  const FollowUserItem({
    required this.item,
    this.onRemove,
    this.onTap,
    this.onLongPress,
    this.onToggleNotify,
    this.playing = false,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var site = Sites.allSites[item.siteId];
    if (site == null) {
      return _buildMissingSite(context);
    }
    return ListTile(
      contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 4),
      leading: NetImage(
        item.face,
        width: 48,
        height: 48,
        borderRadius: 24,
      ),
      title: Text.rich(
        TextSpan(
          text: item.userName,
          children: [
            WidgetSpan(
              alignment: ui.PlaceholderAlignment.middle,
              child: Obx(
                () => Offstage(
                  offstage: item.liveStatus.value == 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppStyle.hGap12,
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: item.liveStatus.value == 2
                              ? Colors.green
                              : Colors.grey,
                          borderRadius: AppStyle.radius12,
                        ),
                      ),
                      AppStyle.hGap4,
                      // 名字很长、状态单独换到一行还放不下时（英文、字体放大）省略，不超出
                      Flexible(
                        child: Text(
                          getStatus(item.liveStatus.value),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.normal,
                            color:
                                item.liveStatus.value == 2 ? null : Colors.grey,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      subtitle: Wrap(
        runSpacing: 1.0,
        children: [
          SiteLogo(
            site,
            width: 20,
          ),
          AppStyle.hGap4,
          Text(
            site.name,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.grey,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          if (playing)
            Padding(
              padding: AppStyle.edgeInsetsL8,
              child: Text(
                "正在观看".t,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          else if (item.liveStatus.value == 2 && item.liveStartTime != null)
            Padding(
              padding: AppStyle.edgeInsetsL8,
              child: Text(
                '开播了{formatLiveDuration}'.tf({
                  "formatLiveDuration": formatLiveDuration(item.liveStartTime)
                }),
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
            ),
        ],
      ),
      trailing: _buildTrailing(context),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  static bool get _showAllBells =>
      Get.isRegistered<AppSettingsController>() &&
      AppSettingsController.instance.liveNotifyShowBell.value;

  Widget? _buildTrailing(BuildContext context) {
    Widget? end = playing
        ? SizedBox(
            width: onToggleNotify == null ? 64 : 40,
            child: const Center(
              child: Icon(
                Icons.play_arrow,
              ),
            ),
          )
        : (onRemove == null
            ? null
            : IconButton(
                onPressed: () {
                  onRemove?.call();
                },
                icon: const Icon(Remix.dislike_line),
              ));
    if (onToggleNotify == null) {
      return end;
    }
    var bell = Obx(
      () {
        var on = item.notifyRx.value;
        // 设置里没打开“所有关注都显示铃铛”时，只有开了提醒的直播间显示
        if (!on && !_showAllBells) {
          return const SizedBox.shrink();
        }
        return IconButton(
          tooltip: on ? "开播提醒已开启，点击关闭".t : "开启开播提醒".t,
          onPressed: onToggleNotify,
          icon: Icon(
            on ? Icons.notifications_active : Icons.notifications_none,
            color: on ? Theme.of(context).colorScheme.primary : null,
          ),
        );
      },
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [bell, if (end != null) end],
    );
  }

  /// 平台已删除（如卸载了的直播源）：灰色显示，不能打开，仍可取消关注
  Widget _buildMissingSite(BuildContext context) {
    var text = Sites.missingSiteText(item.siteId);
    return Opacity(
      opacity: 0.5,
      child: ListTile(
        contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 4),
        leading: NetImage(
          item.face,
          width: 48,
          height: 48,
          borderRadius: 24,
        ),
        title: Text(item.userName),
        subtitle: Row(
          children: [
            const SiteLogo(null, width: 20),
            AppStyle.hGap4,
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        trailing: onRemove == null
            ? null
            : IconButton(
                onPressed: () {
                  onRemove?.call();
                },
                icon: const Icon(Remix.dislike_line),
              ),
        onTap: () =>
            SmartDialog.showToast("{text}，打不开这个直播间".tf({"text": text})),
        onLongPress: onLongPress,
      ),
    );
  }

  String getStatus(int status) {
    if (status == 0) {
      return "读取中".t;
    } else if (status == 1) {
      return "未开播".t;
    } else {
      return "直播中".t;
    }
  }

  String formatLiveDuration(String? startTimeStampString) {
    if (startTimeStampString == null ||
        startTimeStampString.isEmpty ||
        startTimeStampString == "0") {
      return "";
    }
    try {
      int startTimeStamp = int.parse(startTimeStampString);
      int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      int durationInSeconds = currentTimeStamp - startTimeStamp;

      int hours = durationInSeconds ~/ 3600;
      int minutes = (durationInSeconds % 3600) ~/ 60;

      String hourText = hours > 0 ? '{hours}小时'.tf({"hours": hours}) : '';
      String minuteText =
          minutes > 0 ? '{minutes}分钟'.tf({"minutes": minutes}) : '';

      if (hours == 0 && minutes == 0) {
        return "不足1分钟".t;
      }

      return '$hourText$minuteText';
    } catch (e) {
      Log.logPrint('格式化开播时长出错: $e');
      return "--小时--分钟".t;
    }
  }
}
