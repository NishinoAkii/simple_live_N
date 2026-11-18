import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/multi_window_widgets.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/mine/history/history_controller.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/page_list_view.dart';
import 'package:simple_live_app/widgets/site_logo.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class HistoryPage extends GetView<HistoryController> {
  const HistoryPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // 电脑上的主窗口：记着上次的一组多开窗口时，刷新旁边多一个“打开上次的窗口”
    return MultiWindow.canOpen
        ? Obx(() => buildScaffold(context, MultiWindow.restorableSet))
        : buildScaffold(context, null);
  }

  /// 只有直播的观看记录，不用标签栏
  Widget buildScaffold(BuildContext context, WindowSet? lastWindows) {
    return Scaffold(
      appBar: AppBar(
        // 返回键的位置和默认一样（56 宽的格子居中），刷新按钮排在它右边，
        // 再右边是“打开上次的窗口”（有的时候）
        leadingWidth: lastWindows == null ? 104 : 152,
        leading: Row(
          children: [
            const SizedBox(width: 56, child: Center(child: BackButton())),
            IconButton(
              tooltip: "刷新".t,
              icon: const Icon(Icons.refresh),
              onPressed: controller.refreshData,
            ),
            if (lastWindows != null) RestoreWindowsButton(windows: lastWindows),
          ],
        ),
        title: Text("观看记录".t),
        actions: [
          TextButton.icon(
            onPressed: controller.clean,
            icon: const Icon(Icons.delete_outline),
            label: Text("清空".t),
          ),
        ],
      ),
      body: buildLiveHistory(context),
    );
  }

  Widget buildLiveHistory(BuildContext context) {
    return PageListView(
      pageController: controller,
      firstRefresh: true,
      showPCRefreshButton: false,
      padding: AppStyle.edgeInsetsV12,
      separatorBuilder: (_, __) => AppStyle.vGap8,
      itemBuilder: (_, i) {
        var item = controller.list[i];
        return LiveHistoryItem(
          item: item,
          onRemove: () => controller.removeItem(item),
        );
      },
    );
  }
}

/// 一条直播观看记录：点击进入直播间，左滑或长按删除
class LiveHistoryItem extends StatefulWidget {
  final History item;
  final VoidCallback onRemove;
  const LiveHistoryItem({
    required this.item,
    required this.onRemove,
    super.key,
  });

  @override
  State<LiveHistoryItem> createState() => _LiveHistoryItemState();
}

class _LiveHistoryItemState extends State<LiveHistoryItem> {
  /// 有封面地址，但图片加载不出来（比如已经过期）
  var coverFailed = false;

  History get item => widget.item;

  @override
  void didUpdateWidget(LiveHistoryItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.cover != item.cover) {
      coverFailed = false;
    }
  }

  void onCoverFailed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => coverFailed = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 平台未安装（已删除的直播源）时灰色显示，不能打开，仍可删除
    var site = Sites.allSites[item.siteId];
    var siteName = site?.name ?? Sites.missingSiteText(item.siteId);
    // 取不到封面就和老版本一样，不留封面的位置
    var hasCover = !coverFailed && (item.cover ?? "").isNotEmpty;
    var hasTitle = (item.title ?? "").isNotEmpty;
    var titleOnOwnLine = hasCover && hasTitle;
    var siteRow = _SiteAndArea(
      site: site,
      siteName: siteName,
      area: item.area ?? "",
    );
    return Dismissible(
      key: ValueKey("live_${item.id}"),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        padding: AppStyle.edgeInsetsA12,
        alignment: Alignment.centerRight,
        child: const Icon(
          Icons.delete,
          color: Colors.white,
        ),
      ),
      confirmDismiss: (direction) async {
        return await Utils.showAlertDialog("确定删除这条记录吗？".t, title: "删除记录".t);
      },
      onDismissed: (_) {
        widget.onRemove();
      },
      child: Opacity(
        opacity: site == null ? 0.5 : 1,
        child: InkWell(
          onTap: () {
            if (site == null) {
              SmartDialog.showToast("{siteName}，无法打开".tf({"siteName": siteName}));
              return;
            }
            // 上次和几个多开窗口一起关的主窗口直播间：打开后问要不要把那几个也打开
            openHistoryRoom(site, item.roomId);
          },
          onLongPress: () async {
            var group = site == null
                ? null
                : MultiWindow.groupFor(site.id, item.roomId);
            if (site != null && group != null) {
              var open = await showHistoryGroupSheet(context, group);
              if (open == true) {
                await openHistoryGroup(site, item.roomId, group);
                return;
              }
              if (open == null) {
                return;
              }
            }
            var result =
                await Utils.showAlertDialog("确定删除这条记录吗？".t, title: "删除记录".t);
            if (!result) {
              return;
            }
            widget.onRemove();
          },
          child: Row(
            children: [
              if (hasCover)
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: SizedBox(
                    // 边距和老版本一样，手机上靠封面让出宽度
                    width: min(140, MediaQuery.of(context).size.width * 0.26),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: NetImage(
                        item.cover!,
                        borderRadius: 8,
                        onLoadFailed: onCoverFailed,
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: ListTile(
                  // 时间比默认的位置再往左一点
                  contentPadding:
                      const EdgeInsetsDirectional.only(start: 16, end: 32),
                  // 多一行标题时上下留的空和老版本的行差不多
                  minVerticalPadding: titleOnOwnLine ? 13 : null,
                  leading: NetImage(
                    item.face,
                    width: 48,
                    height: 48,
                    borderRadius: 24,
                  ),
                  title: Transform.translate(
                    offset: Offset(0, hasTitle && !hasCover ? -7.33 : 0),
                    child: Text(
                      item.userName,
                      maxLines: hasTitle ? 1 : null,
                      overflow: hasTitle ? TextOverflow.ellipsis : null,
                    ),
                  ),
                  subtitle: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (titleOnOwnLine) ...[
                        Text(
                          item.title!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        // 量过：主播名到标题和标题到平台，文字间距都是 10
                        const SizedBox(height: 3),
                      ],
                      Row(
                        children: [
                          Expanded(
                            // 没有封面时行高和时间的位置都和老版本一样：标题在这一行的正中，
                            // 主播名和平台排在两侧，间距用老版本主播名到平台圆圈的距离。
                            // 只挪绘制位置，不占布局的高度
                            child: hasTitle && !hasCover
                                ? Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      Transform.translate(
                                        offset: const Offset(0, 9.33),
                                        child: siteRow,
                                      ),
                                      Positioned.fill(
                                        top: -22,
                                        right: 8,
                                        child: IgnoreBaseline(
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              item.title!,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  )
                                : siteRow,
                          ),
                          // 文字框的宽度会向上取整，靠右才能每行都贴紧同一条线
                          Text(
                            Utils.parseTime(item.updateTime),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 长按一组的主窗口直播间：打开上次一起看的直播间，或者删除记录。
/// 返回 true 打开、false 删除、null 没选
Future<bool?> showHistoryGroupSheet(BuildContext context, WindowSet group) {
  return showModalBottomSheet<bool>(
    context: context,
    constraints: const BoxConstraints(maxWidth: 600),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.filter_none),
            title: Text("打开上次一起看的直播间".t),
            subtitle: Text(group.labels,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.of(sheetContext).pop(true),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text("删除记录".t),
            onTap: () => Navigator.of(sheetContext).pop(false),
          ),
        ],
      ),
    ),
  );
}

/// 灰色那行里时间左边的部分：平台图标、平台名和分区（分区是平台的原文，不翻译）
class _SiteAndArea extends StatelessWidget {
  final Site? site;
  final String siteName;

  /// 没有分区（旧记录、平台没给）时是空的，这时和老版本一样
  final String area;
  const _SiteAndArea({
    required this.site,
    required this.siteName,
    required this.area,
  });

  static const _style = TextStyle(fontSize: 12, color: Colors.grey);

  /// 比这窄（手机上有封面的行）放不下平台名和分区，只留图标和分区。
  /// 170：图标、四个字的平台名、分隔号之外还放得下六个字
  static const _bothWidth = 170.0;

  @override
  Widget build(BuildContext context) {
    var name = Text(siteName, style: _style, overflow: TextOverflow.ellipsis);
    if (area.isEmpty) {
      return Row(
        children: [
          SiteLogo(site, width: 20),
          AppStyle.hGap4,
          Flexible(child: name),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          SiteLogo(site, width: 20),
          AppStyle.hGap4,
          if (constraints.maxWidth >= _bothWidth) ...[
            // 平台名都很短；分区占剩下的宽度，放不下时省略
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 96),
              child: name,
            ),
            const Text(" · ", style: _style),
          ],
          Flexible(
            child: Padding(
              // 省略时不贴着时间；再宽的话手机上五个字的分区就放不下了
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                area,
                style: _style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
