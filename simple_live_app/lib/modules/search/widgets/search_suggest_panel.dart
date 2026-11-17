import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/search/local_search.dart';
import 'package:simple_live_app/modules/search/search_controller.dart';
import 'package:simple_live_app/modules/search/search_merge.dart';
import 'package:simple_live_app/modules/search/widgets/search_cards.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 输入框下面的联想面板，只放直播相关的：本地匹配（关注、看过）→ 当前平台的主播卡片
/// （点了直接进直播间）；输入框为空时显示最近搜索。点空白处关闭
class SearchSuggestPanel extends StatelessWidget {
  final AppSearchController controller;
  const SearchSuggestPanel(this.controller, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: controller.closePanel,
            child: Container(color: Colors.black.withAlpha(40)),
          ),
        ),
        Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 720,
              maxHeight: MediaQuery.of(context).size.height * 0.65,
            ),
            child: Material(
              color: Theme.of(context).cardColor,
              elevation: 4,
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: Obx(() {
                var children = _buildChildren(context);
                if (children.isEmpty) {
                  return const SizedBox();
                }
                return ListView(
                  shrinkWrap: true,
                  padding: AppStyle.edgeInsetsV8,
                  children: children,
                );
              }),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildChildren(BuildContext context) {
    var suggest = controller.suggest;
    var query = suggest.query.value.trim();
    if (query.isEmpty) {
      return _buildHistory(context);
    }
    var local = suggest.localMatches.toList();
    var channels = suggest.channels.toList();
    return [
      ListTile(
        dense: true,
        leading: const Icon(Icons.search),
        title: Text("搜索“{query}”".tf({"query": query}), maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: controller.doSearch,
      ),
      if (local.isNotEmpty) ...[
        _header(
          context,
          "关注和看过".t,
          trailing: _platformToggle(context),
        ),
        for (var m in local) _localTile(context, m),
      ] else if (!suggest.allPlatforms.value)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: AppStyle.edgeInsetsH8,
            child: TextButton.icon(
              onPressed: suggest.toggleAllPlatforms,
              icon: const Icon(Icons.travel_explore, size: 18),
              label: Text("在全部平台的关注和看过里找".t),
            ),
          ),
        ),
      if (channels.isNotEmpty) ...[
        _header(context, "{name}的主播".tf({"name": controller.sites[controller.index].name})),
        for (var c in channels) _channelTile(context, c),
      ],
    ];
  }

  List<Widget> _buildHistory(BuildContext context) {
    var history = controller.suggest.history.toList();
    if (history.isEmpty) {
      return [
        ListTile(
          dense: true,
          leading: const Icon(Icons.lightbulb_outline),
          title: Text("输入主播名字、房间号或链接".t),
          subtitle: Text("拼音、首字母、繁体也能搜到关注和看过的主播".t),
        ),
      ];
    }
    return [
      _header(
        context,
        "最近搜索".t,
        trailing: TextButton(
          onPressed: controller.suggest.clearHistory,
          child: Text("清空".t),
        ),
      ),
      Padding(
        padding: AppStyle.edgeInsetsH12,
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (var h in history)
              InputChip(
                label: Text(h, maxLines: 1, overflow: TextOverflow.ellipsis),
                onPressed: () => controller.searchWord(h),
                onDeleted: () => controller.suggest.removeHistory(h),
                deleteIcon: const Icon(Icons.close, size: 16),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ),
    ];
  }

  Widget _header(BuildContext context, String text, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Colors.grey,
                  ),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _platformToggle(BuildContext context) {
    var all = controller.suggest.allPlatforms.value;
    return TextButton.icon(
      onPressed: controller.suggest.toggleAllPlatforms,
      icon: Icon(all ? Icons.public : Icons.filter_alt_outlined, size: 16),
      label: Text(all ? "全部平台".t : "当前平台".t),
    );
  }

  Widget _avatar(String url, bool? live, {bool record = false}) {
    return SizedBox(
      width: 36,
      height: 36,
      child: Stack(
        children: [
          NetImage(url, width: 36, height: 36, borderRadius: 18),
          if (live != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(1.5),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: SearchLiveDot(live: live, isRecord: record, size: 9),
              ),
            ),
        ],
      ),
    );
  }

  Widget _localTile(BuildContext context, LocalSearchMatch m) {
    var item = m.item;
    var siteName = Sites.allSites[item.siteId]?.name ?? item.siteId;
    var source = item.source == LocalSearchSource.follow ? "关注##tab".t : "看过".t;
    var live = item.liveStatus;
    return ListTile(
      dense: true,
      leading: _avatar(item.face, live),
      title: Text(item.userName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          source,
          siteName,
          if (live != null) searchStatusText(live, false),
        ].join(" · "),
        maxLines: 1,
      ),
      onTap: () => controller.openLocal(m),
    );
  }

  Widget _channelTile(BuildContext context, LiveSuggestion c) {
    var live = c.liveStatus;
    // 平台没给在播状态（YouTube 的频道）时不显示状态
    var info = [
      if (live != null) searchStatusText(live, c.isRecord),
      if (c.subtitle != null) c.subtitle!,
    ];
    return ListTile(
      dense: true,
      leading: _avatar(c.avatar ?? "", live, record: c.isRecord),
      title: Text(c.userName ?? c.text,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: info.isEmpty
          ? null
          : Text(
              info.join(" · "),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => controller.openChannel(c),
    );
  }
}
