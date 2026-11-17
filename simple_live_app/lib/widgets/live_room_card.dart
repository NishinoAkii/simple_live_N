import 'package:flutter/material.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/multi_window_widgets.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/shadow_card.dart';
import 'package:simple_live_core/simple_live_core.dart';

class LiveRoomCard extends StatelessWidget {
  final Site site;
  final LiveRoomItem item;
  const LiveRoomCard(this.site, this.item, {Key? key}) : super(key: key);

  static const StrutStyle _nameStrut =
      StrutStyle(fontSize: 12, height: 1.4, forceStrutHeight: true);

  @override
  Widget build(BuildContext context) {
    // 电脑上的主窗口：长按或右键可以在新窗口打开
    void windowSheet() =>
        showRoomWindowSheet(site, item.roomId, item.userName);
    var multi = MultiWindow.canOpen;
    return ShadowCard(
      onTap: () {
        AppNavigator.toLiveRoomDetail(site: site, roomId: item.roomId);
      },
      onLongPress: multi ? windowSheet : null,
      onSecondaryTap: multi ? windowSheet : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                ),
                child: NetImage(
                  item.cover,
                  fit: BoxFit.cover,
                  height: 110,
                  width: double.infinity,
                ),
              ),
              Positioned(
                right: 0,
                left: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black87,
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      const Icon(
                        Remix.fire_fill,
                        color: Colors.white,
                        size: 14,
                      ),
                      AppStyle.hGap4,
                      Text(
                        Utils.onlineToString(item.online),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                        ),
                      )
                    ],
                  ),
                ),
              ),
            ],
          ),
          // 行高固定：标题、名字里有特殊字符（用别的字体画）时卡片不会变高
          Padding(
            padding: AppStyle.edgeInsetsA8.copyWith(bottom: 4),
            child: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              strutStyle: StrutStyle.fromTextStyle(
                DefaultTextStyle.of(context).style,
                forceStrutHeight: true,
              ),
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsH8.copyWith(bottom: 8),
            child: Text(
              item.userName,
              maxLines: 1,
              strutStyle: _nameStrut,
              style: const TextStyle(
                  height: 1.4, fontSize: 12, color: Colors.grey),
            ),
          )
        ],
      ),
    );
  }
}
