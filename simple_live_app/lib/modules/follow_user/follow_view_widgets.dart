import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/follow_view_settings.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/follow_user/follow_view.dart';
import 'package:simple_live_app/widgets/live_room_card.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/site_logo.dart';
import 'package:simple_live_core/simple_live_core.dart' show LiveRoomItem;

/// 关注页分组、紧凑和卡片样式的几段。
///
/// [groups] 不分组时只有一组；[headers] 为 false 时不画组标题。
/// 折叠了的组只画标题。卡片样式：组里直播中的排成卡片（封面滚到才加载），
/// 其他的还是列表的一行，排在卡片下面
List<Widget> followSectionSlivers({
  required List<FollowGroup> groups,
  required bool headers,
  required String style,
  required Set<String> collapsed,
  required int columns,
  required int cardColumns,
  required Widget Function(FollowUser item) row,
  required Widget Function(FollowUser item) compact,
  required Widget Function(FollowUser item) card,
  required Widget Function(FollowGroup group, bool collapsed) header,
  double bottom = 0,
}) {
  Widget rows(List<FollowUser> items) => SliverAlignedGrid.count(
        crossAxisCount: columns,
        crossAxisSpacing: 12,
        itemCount: items.length,
        itemBuilder: (_, i) => row(items[i]),
      );

  var slivers = <Widget>[];
  for (var group in groups) {
    var folded = headers && collapsed.contains(group.key);
    if (headers) {
      slivers.add(SliverToBoxAdapter(child: header(group, folded)));
    }
    if (folded) continue;
    var items = group.members;
    if (style == FollowViewSettings.styleCompact) {
      slivers.add(SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 12,
          mainAxisExtent: FollowCompactRow.height,
        ),
        delegate: SliverChildBuilderDelegate(
          (_, i) => compact(items[i]),
          childCount: items.length,
        ),
      ));
    } else if (style == FollowViewSettings.styleCard) {
      var live = items.where((e) => e.liveStatus.value == 2).toList();
      var rest = items.where((e) => e.liveStatus.value != 2).toList();
      if (live.isNotEmpty) {
        slivers.add(SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          sliver: SliverAlignedGrid.count(
            crossAxisCount: cardColumns,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            itemCount: live.length,
            itemBuilder: (_, i) => card(live[i]),
          ),
        ));
      }
      if (rest.isNotEmpty) slivers.add(rows(rest));
    } else {
      slivers.add(rows(items));
    }
  }
  if (bottom > 0) {
    slivers.add(SliverToBoxAdapter(child: SizedBox(height: bottom)));
  }
  return slivers;
}

/// 组标题：点一下折叠或展开；右边是“刷新这一组”
class FollowGroupHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool collapsed;
  final Widget? leading;
  final VoidCallback onToggle;

  /// 为 null 时刷新按钮是灰的（正在刷新别的）
  final VoidCallback? onRefresh;
  final bool refreshing;
  const FollowGroupHeader({
    required this.title,
    required this.count,
    required this.collapsed,
    required this.onToggle,
    this.leading,
    this.onRefresh,
    this.refreshing = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    var grey = Theme.of(context).colorScheme.onSurfaceVariant;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onToggle,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                Icon(
                  collapsed
                      ? Remix.arrow_right_s_line
                      : Remix.arrow_down_s_line,
                  size: 20,
                  color: grey,
                ),
                AppStyle.hGap4,
                if (leading != null) ...[leading!, AppStyle.hGap8],
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                AppStyle.hGap8,
                Text(
                  "$count",
                  style: TextStyle(fontSize: 12, color: grey),
                ),
                const Spacer(),
                if (refreshing)
                  const SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else
                  IconButton(
                    tooltip: "刷新这一组".t,
                    visualDensity: VisualDensity.compact,
                    iconSize: 20,
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 紧凑样式的一行：行高固定，只有头像、名字、开播的点、平台图标和铃铛。
/// 取消关注、设置标签在长按里
class FollowCompactRow extends StatelessWidget {
  static const double height = 48;

  final FollowUser item;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 点铃铛：订阅或取消开播提醒。为 null 时不显示铃铛
  final VoidCallback? onToggleNotify;
  const FollowCompactRow({
    required this.item,
    this.onTap,
    this.onLongPress,
    this.onToggleNotify,
    super.key,
  });

  static bool get _showAllBells =>
      Get.isRegistered<AppSettingsController>() &&
      AppSettingsController.instance.liveNotifyShowBell.value;

  @override
  Widget build(BuildContext context) {
    var site = Sites.allSites[item.siteId];
    var row = InkWell(
      onTap: site == null
          ? () => SmartDialog.showToast("{text}，打不开这个直播间"
              .tf({"text": Sites.missingSiteText(item.siteId)}))
          : onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          children: [
            NetImage(item.face, width: 32, height: 32, borderRadius: 16),
            AppStyle.hGap12,
            Expanded(
              child: Text(
                item.userName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            AppStyle.hGap8,
            Obx(() {
              var status = item.liveStatus.value;
              if (status == 0) return const SizedBox.shrink();
              return Tooltip(
                message: status == 2 ? "直播中".t : "未开播".t,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: status == 2 ? Colors.green : Colors.grey,
                    shape: BoxShape.circle,
                  ),
                ),
              );
            }),
            AppStyle.hGap8,
            SiteLogo(site, width: 16),
            if (onToggleNotify == null)
              AppStyle.hGap12
            else
              Obx(() {
                var on = item.notifyRx.value;
                if (!on && !_showAllBells) return AppStyle.hGap12;
                return IconButton(
                  tooltip: on ? "开播提醒已开启，点击关闭".t : "开启开播提醒".t,
                  visualDensity: VisualDensity.compact,
                  iconSize: 20,
                  onPressed: onToggleNotify,
                  icon: Icon(
                    on ? Icons.notifications_active : Icons.notifications_none,
                    color: on ? Theme.of(context).colorScheme.primary : null,
                  ),
                );
              }),
          ],
        ),
      ),
    );
    return SizedBox(
      height: height,
      child: site == null ? Opacity(opacity: 0.5, child: row) : row,
    );
  }
}

/// 卡片样式里直播中的一个：首页那样的卡片，点开进直播间，长按是关注的操作
class FollowLiveCard extends StatelessWidget {
  final FollowUser item;
  final Site site;
  final String cover;
  final String title;
  final VoidCallback? onLongPress;
  const FollowLiveCard({
    required this.item,
    required this.site,
    required this.cover,
    required this.title,
    this.onLongPress,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: onLongPress,
      child: LiveRoomCard(
        site,
        LiveRoomItem(
          roomId: item.roomId,
          title: title,
          cover: cover,
          userName: item.userName,
          online: item.liveOnline,
        ),
      ),
    );
  }
}

/// 顶栏里的搜索框（菜单里点“搜索”以后）：按名字或拼音首字母找，Esc 或右边的叉关掉
class FollowSearchField extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;
  const FollowSearchField({
    required this.onChanged,
    required this.onClose,
    this.initial = "",
    super.key,
  });

  @override
  State<FollowSearchField> createState() => _FollowSearchFieldState();
}

class _FollowSearchFieldState extends State<FollowSearchField> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: TextField(
        controller: _text,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onChanged: widget.onChanged,
        decoration: InputDecoration(
          hintText: "搜索名字或拼音首字母".t,
          border: InputBorder.none,
          isDense: true,
          suffixIcon: IconButton(
            tooltip: "关闭搜索".t,
            onPressed: widget.onClose,
            icon: const Icon(Icons.close),
          ),
        ),
      ),
    );
  }
}
