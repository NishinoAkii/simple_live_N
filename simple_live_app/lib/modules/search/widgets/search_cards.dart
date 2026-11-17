import 'package:flutter/material.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/search/search_direct.dart';
import 'package:simple_live_app/modules/search/search_merge.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/widgets/live_room_card.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/shadow_card.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 直播状态的小圆点：直播中绿色，轮播橙色，未开播灰色
class SearchLiveDot extends StatelessWidget {
  final bool live;
  final bool isRecord;
  final double size;
  const SearchLiveDot({
    required this.live,
    this.isRecord = false,
    this.size = 8,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: live ? Colors.green : (isRecord ? Colors.orange : Colors.grey),
        borderRadius: AppStyle.radius12,
      ),
    );
  }
}

/// 结果来源的小标签（如“按拼音匹配”）
class SearchTag extends StatelessWidget {
  final String text;
  const SearchTag(this.text, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var color = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: AppStyle.radius4,
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

/// 主播卡片：头像、名字、状态（直播中/轮播/未开播）、粉丝数、上次直播
class SearchAnchorCard extends StatelessWidget {
  final Site site;
  final LiveAnchorItem item;
  final String? tag;
  const SearchAnchorCard(this.site, this.item, {this.tag, Key? key})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    var last = searchLastLiveText(item);
    var followers = item.followers;
    return ShadowCard(
      onTap: () {
        AppNavigator.toLiveRoomDetail(site: site, roomId: item.roomId);
      },
      child: Padding(
        padding: AppStyle.edgeInsetsA8,
        child: Row(
          children: [
            NetImage(
              item.avatar,
              width: 44,
              height: 44,
              borderRadius: 22,
            ),
            AppStyle.hGap8,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.userName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  AppStyle.vGap4,
                  Row(
                    children: [
                      SearchLiveDot(
                        live: item.liveStatus,
                        isRecord: item.isRecord,
                      ),
                      AppStyle.hGap4,
                      Text(
                        searchStatusText(item.liveStatus, item.isRecord),
                        style: TextStyle(
                          fontSize: 12,
                          color: item.liveStatus ? null : Colors.grey,
                        ),
                      ),
                      if (followers != null && followers > 0)
                        Flexible(
                          child: Text(
                            " · 粉丝 {onlineToString}".tf({"onlineToString": Utils.onlineToString(followers)}),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (last != null)
                    Padding(
                      padding: AppStyle.edgeInsetsT4,
                      child: Text(
                        last,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  if (tag != null)
                    Padding(
                      padding: AppStyle.edgeInsetsT4,
                      child: SearchTag(tag!),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 综合搜索的一项：有直播间时用直播间卡片，否则用主播卡片
class SearchEntryCard extends StatelessWidget {
  final Site site;
  final SearchEntry entry;
  const SearchEntryCard(this.site, this.entry, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var room = entry.room;
    if (room == null) {
      return SearchAnchorCard(site, entry.anchor!, tag: entry.tag);
    }
    var tag = entry.tag;
    if (tag == null) {
      return LiveRoomCard(site, room);
    }
    return Stack(
      children: [
        LiveRoomCard(site, room),
        Positioned(top: 6, left: 6, child: SearchTag(tag)),
      ],
    );
  }
}

/// 直达卡片：输入的房间号能打开时显示在结果最上面
class SearchDirectCard extends StatelessWidget {
  final Site site;
  final SearchDirectResult result;
  const SearchDirectCard(this.site, this.result, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var detail = result.detail;
    var live = detail.status;
    var record = detail.isRecord;
    return ShadowCard(
      onTap: () {
        AppNavigator.toLiveRoomDetail(site: site, roomId: detail.roomId);
      },
      child: Padding(
        padding: AppStyle.edgeInsetsA8,
        child: Row(
          children: [
            NetImage(
              detail.userAvatar,
              width: 44,
              height: 44,
              borderRadius: 22,
            ),
            AppStyle.hGap8,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SearchTag("直达".t),
                      AppStyle.hGap4,
                      Flexible(
                        child: Text(
                          detail.userName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  AppStyle.vGap4,
                  Row(
                    children: [
                      SearchLiveDot(live: live, isRecord: record),
                      AppStyle.hGap4,
                      Flexible(
                        child: Text(
                          [
                            searchStatusText(live, record),
                            result.label,
                            if (detail.title.isNotEmpty &&
                                detail.title != detail.userName)
                              detail.title,
                          ].join(" · "),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
