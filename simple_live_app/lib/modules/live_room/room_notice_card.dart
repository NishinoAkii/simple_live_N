import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/room_notice.dart';

// 聊天区顶上的直播间公告卡片（和哔哩哔哩的一样）：标题、主播公告、开播时长。
// 卡片浮在聊天列表上面，消息从下面滚过；可以收起成小条（标题和开播时长），也可以关掉，
// 关掉后这次进直播间不再显示。收起与否各设备自己记。没开播时不显示时长。
// 直播间设置的“聊天区”里有总开关

/// 聊天页右上角那排浮动按钮（导出、排序、搜索，见 LiveChatSearchView）
/// 占的宽度和它们的下边；卡片给它们让位置
const double kChatFloatButtonsWidth = 136;
const double kChatFloatButtonsBottom = 48;

/// 浮动按钮是 44 见方的格子里一个 36 的圆，看得见的圆比格子四边各小这么多
const double _kButtonMargin = 4;

/// 字离浮动按钮的圆至少这么远
const double _kButtonGap = 6;

/// 公告没展开时最多显示几行
const int kRoomNoticeLines = 6;

/// 卡片在聊天区里怎么放
class RoomNoticeLayout {
  /// 卡片上边离聊天区顶部多远
  final double top;

  /// 卡片最宽、最高多少
  final double maxWidth;
  final double maxHeight;

  /// 展开的卡片右上角被浮动按钮挡住的宽和高（从卡片的右上角量）。
  /// 这一截高度里的字折得短一些，下面的行用整行；没挡住时都是 0
  final double floatWidth;
  final double floatHeight;

  const RoomNoticeLayout({
    required this.top,
    required this.maxWidth,
    required this.maxHeight,
    this.floatWidth = 0,
    this.floatHeight = 0,
  });

  /// 卡片左右各留的边
  static const double side = 8;

  /// 卡片最宽这么多，靠左放：侧栏很宽、手机横屏时不拉成一长条
  static const double maxCardWidth = 560;

  /// 浮动按钮左边空出的地方至少有这么宽（差不多是三个按钮看得见的宽度，
  /// 字放大时跟着放大），卡片就和按钮并排；不够时整张卡片排到按钮下面
  static const double minBesideRoom = 124;

  /// 聊天区比这还小时（比如手机上弹出了键盘）不显示卡片，地方留给消息
  static const double minAreaHeight = 120;
  static const double minAreaWidth = 200;

  /// 卡片下面至少给消息留这么高，留不出来时不显示卡片
  static const double minMessageRoom = 64;

  /// [area] 是聊天列表的大小；[buttonsWidth] 是右上角浮动按钮的宽度，没有时为 0。
  /// 地方太小、放不下时返回 null。
  ///
  /// 卡片在最上面、和浮动按钮并排：展开的卡片占满一行（最宽 [maxCardWidth]），
  /// 挨着按钮的那几行字让开按钮；收起的小条在按钮左边。
  /// 按钮左边空出的地方不到 [minBesideRoom] 时（很窄的侧栏），整张卡片排到按钮下面
  static RoomNoticeLayout? of(
    Size area, {
    required bool folded,
    double buttonsWidth = kChatFloatButtonsWidth,
    double textScale = 1,
  }) {
    if (area.height < minAreaHeight || area.width < minAreaWidth) {
      return null;
    }
    var width = area.width - side * 2;
    var cardWidth = math.min(width, maxCardWidth);
    // 浮动按钮的圆（再空一点）从右边伸进卡片那一行多宽
    var buttons = buttonsWidth <= 0
        ? 0.0
        : buttonsWidth - side - _kButtonMargin + _kButtonGap;
    var floatWidth = 0.0;
    var beside = true;
    if (buttons > 0) {
      var need = minBesideRoom * textScale;
      if (folded) {
        var pill = math.min(cardWidth, width - buttons);
        beside = pill >= need;
        if (beside) {
          cardWidth = pill;
        }
      } else {
        // 卡片没占满一行时按钮伸进来的少，或者碰不到卡片
        floatWidth = math.max(0.0, buttons - (width - cardWidth));
        beside = cardWidth - floatWidth >= need;
        if (!beside) {
          floatWidth = 0;
        }
      }
    }
    var top = beside ? 4.0 : kChatFloatButtonsBottom;
    // 卡片最高能有多高
    var room = area.height - top - minMessageRoom;
    // 展开的卡片里标题（最多两行）和时间那一行是固定的，公告在中间滚动；
    // 收起的小条是两行字，右边是两个按钮
    var need =
        folded ? math.max(52.0, 32 * textScale + 12) : 60 * textScale + 40;
    if (room < need) {
      return null;
    }
    return RoomNoticeLayout(
      top: top,
      maxWidth: cardWidth,
      // 最多占聊天区的六成，下面留给新消息
      maxHeight: math.max(need, math.min(room, (area.height - top) * 0.6)),
      floatWidth: floatWidth,
      // 到按钮的圆的下边为止
      floatHeight:
          floatWidth > 0 ? kChatFloatButtonsBottom - _kButtonMargin - top : 0,
    );
  }
}

/// 放在聊天列表的 Stack 里：卡片浮在列表顶上，自己量出高度记到
/// [RoomNoticeState.inset]，列表按它留出顶部
class RoomNoticeOverlay extends StatelessWidget {
  final LiveRoomController controller;
  const RoomNoticeOverlay({required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    var portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    var textScale = MediaQuery.textScalerOf(context).scale(10) / 10;
    var state = controller.roomNotice;
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, box) => Obx(() {
          var settings = AppSettingsController.instance;
          var notice = state.notice.value;
          // 用户自己收起的（记在设置里），或者这次聊天列表滚起来后自动收起的
          var folded =
              settings.chatNoticeFolded.value || state.autoFolded.value;
          var show = settings.chatNoticeCard.value &&
              !state.closed.value &&
              notice != null &&
              !notice.isEmpty;
          // 在播、平台给了开播时间时才有时间那一行
          var start =
              show && controller.liveStatus.value ? notice.liveStart : null;
          // 搜索栏展开时（横屏、电脑）右上角没有浮动按钮
          var searchBar = controller.chatSearchOpen.value && !portrait;
          var layout = show
              ? RoomNoticeLayout.of(
                  box.biggest,
                  folded: folded,
                  buttonsWidth: searchBar ? 0 : kChatFloatButtonsWidth,
                  textScale: textScale,
                )
              : null;
          Widget card = const SizedBox.shrink();
          if (layout != null) {
            card = Padding(
              padding: EdgeInsets.fromLTRB(
                RoomNoticeLayout.side,
                layout.top,
                RoomNoticeLayout.side,
                0,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: layout.maxWidth),
                // 时长每秒变一次，只重画卡片这一层
                child: RepaintBoundary(
                  child: RoomNoticeCard(
                    notice: notice!,
                    time: start == null
                        ? null
                        : Obx(() {
                            // 跟着播放器上的开播时长每秒刷新；数从开播时间算，
                            // 刚进直播间、刚换直播间的第一秒也是对的
                            controller.liveDuration.value;
                            return Text(roomLiveDurationText(start));
                          }),
                    folded: folded,
                    floatWidth: layout.floatWidth,
                    floatHeight: layout.floatHeight,
                    maxHeight: layout.maxHeight,
                    onFold: state.foldByHand,
                    onClose: () => state.closed.value = true,
                  ),
                ),
              ),
            );
          }
          return Align(
            alignment: Alignment.topLeft,
            child: SizeReporter(
              onSize: (size) => state.inset.value = size.height,
              child: card,
            ),
          );
        }),
      ),
    );
  }
}

/// 展开的卡片：收起按钮四周的边，收起和关闭按钮（点的范围）的大小
const double _kPad = 2;
const double _kButton = 32;

/// 最后一行右边给 × 留的宽：图标和它前面的空
const double _kCloseRoom = 22;

/// 公告卡片本身。展开：左边是收起按钮，右边是标题、公告和开播时长，× 在最后一行的右边；
/// 挨着右上角浮动按钮的那几行字折得短一些，下面的行用整行。没有公告时只有标题那么宽。
/// 收起：一个小条，第一行标题、第二行开播时长，右边是关闭和展开。点卡片也能收起、展开。
/// 没有时长（没开播）时不显示那一行，小条只有标题
class RoomNoticeCard extends StatefulWidget {
  final RoomNotice notice;

  /// 时间那一行显示的内容（开播时长，一个每秒刷新的 Text）；为 null 时没有这一行
  final Widget? time;
  final bool folded;

  /// 展开时右上角被浮动按钮挡住的宽和高，见 [RoomNoticeLayout.floatWidth]
  final double floatWidth;
  final double floatHeight;

  /// 展开时最高多少，公告太长时在里面滚动
  final double maxHeight;
  final ValueChanged<bool> onFold;
  final VoidCallback onClose;

  const RoomNoticeCard({
    required this.notice,
    required this.time,
    required this.folded,
    required this.onFold,
    required this.onClose,
    this.floatWidth = 0,
    this.floatHeight = 0,
    this.maxHeight = double.infinity,
    super.key,
  });

  /// 展开时左边收起按钮那一列（连边）的宽，和字右边留的边
  static const double lead = _kPad + _kButton;
  static const double trail = 10;

  @override
  State<RoomNoticeCard> createState() => _RoomNoticeCardState();
}

class _RoomNoticeCardState extends State<RoomNoticeCard> {
  /// 点了“显示全部”：公告不再只显示前几行
  bool _full = false;

  @override
  void didUpdateWidget(RoomNoticeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notice != widget.notice ||
        oldWidget.folded != widget.folded) {
      _full = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);
    var dark = theme.brightness == Brightness.dark;
    // 半透明：深色主题下比背景亮一点，浅色主题下带一点灰蓝（和气泡样式一个色调）。
    // 消息从下面滚过，太透了卡片上的字看不清
    var background = Color.alphaBlend(
      dark ? Colors.white.withAlpha(26) : Colors.blueGrey.withAlpha(30),
      theme.scaffoldBackgroundColor,
    ).withAlpha(244);
    var colors = _CardColors(
      title: dark ? Colors.white : AppColors.black333,
      body: (dark ? Colors.white : AppColors.black333).withAlpha(217),
      faint: Colors.grey,
    );
    return Material(
      color: background,
      elevation: 1,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => widget.onFold(!widget.folded),
        child: widget.folded ? _buildFolded(colors) : _buildExpanded(colors),
      ),
    );
  }

  TextStyle _timeStyle(_CardColors colors, double size) => TextStyle(
        fontSize: size,
        color: colors.faint,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// 时间那一行：灰色小字，字放得很大时缩小一点，不截断
  Widget _timeLine(TextStyle style) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: DefaultTextStyle.merge(
        maxLines: 1,
        softWrap: false,
        style: style,
        child: widget.time!,
      ),
    );
  }

  Widget _buildFolded(_CardColors colors) {
    var notice = widget.notice;
    var timed = widget.time != null;
    // 没有标题时第一行用公告的第一行
    var line =
        notice.title.isNotEmpty ? notice.title : notice.body.split("\n").first;
    var title = Text(
      line,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.bold,
        color: colors.title,
      ),
    );
    var close = _CardButton(
      icon: Icons.close,
      tooltip: "关闭".t,
      color: colors.faint,
      height: timed ? 24 : 30,
      iconSize: 15,
      onTap: widget.onClose,
    );
    var expand = _CardButton(
      icon: Icons.keyboard_arrow_down,
      tooltip: "展开".t,
      color: colors.body,
      height: timed ? 22 : 30,
      iconSize: 18,
      onTap: () => widget.onFold(false),
    );
    if (!timed) {
      // 没开播：只有标题一行，右边是关闭和展开
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 1, 2, 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: title),
            const SizedBox(width: 4),
            close,
            expand,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 3, 2, 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                const SizedBox(height: 1),
                _timeLine(_timeStyle(colors, 11)),
              ],
            ),
          ),
          const SizedBox(width: 4),
          // 展开的箭头在右下角，关闭在它上面
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [close, expand],
          ),
        ],
      ),
    );
  }

  Widget _buildExpanded(_CardColors colors) {
    var notice = widget.notice;
    var titleStyle = TextStyle(
      fontSize: 14,
      height: 1.3,
      fontWeight: FontWeight.bold,
      color: colors.title,
    );
    var bodyStyle = TextStyle(fontSize: 12.5, height: 1.3, color: colors.body);
    var timeStyle = _timeStyle(colors, 11.5);
    var moreStyle = TextStyle(
      fontSize: 12,
      color: Theme.of(context).colorScheme.primary,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: LayoutBuilder(
        builder: (context, box) {
          var measure = _Measure(context);
          var lead = RoomNoticeCard.lead;
          var trail = RoomNoticeCard.trail;
          var titleText = notice.title.isNotEmpty ? notice.title : "公告".t;
          var timed = widget.time != null;
          var hasBody = notice.body.isNotEmpty;
          // 只有标题时 × 跟在标题后面，标题给它留出地方
          var room = !hasBody && !timed ? _kCloseRoom : 0.0;
          var width = box.maxWidth;
          var floatWidth = widget.floatWidth;
          if (!hasBody) {
            // 没有公告：卡片只有标题（和时长）那么宽，靠左，不伸到浮动按钮下面
            var limit = width - floatWidth;
            var content = room +
                measure.longestLine(
                    titleText, titleStyle, 2, limit - lead - trail - room);
            if (timed) {
              content = math.max(
                content,
                measure.longestLine("00:00:00", timeStyle, 1) + _kCloseRoom,
              );
            }
            width = math.min(limit, lead + content + trail + 1);
            floatWidth = 0;
          }
          // 收起按钮右边那一列多宽；一行字最宽多少：整行的，和挨着浮动按钮的
          var row = width - lead;
          var full = row - trail;
          var narrow = math.min(full, row - floatWidth);
          var band = floatWidth > 0 ? widget.floatHeight : 0.0;
          // 下面的 y 都从卡片上边量。标题第一行和收起按钮对齐
          var top = math.max(
            _kPad,
            _kPad + (_kButton - measure.height("国", titleStyle)) / 2,
          );
          var title = _FloatText.layout(
            titleText,
            measure.painter(titleStyle),
            full: full - room,
            narrow: narrow - room,
            top: top,
            band: band,
            maxLines: 2,
          );
          var y = top + title.height;
          _FloatText? body;
          if (hasBody) {
            y += 2;
            body = _FloatText.layout(
              notice.body,
              measure.painter(bodyStyle),
              full: full,
              narrow: narrow,
              top: y,
              band: band,
              maxLines: _full ? null : kRoomNoticeLines,
            );
            y += body.height;
          }
          var clipped = body?.exceeded ?? false;
          var last = body ?? title;

          // × 在最后一行的右边：在播时是时间那一行，公告显示不全时是“显示全部”那一行，
          // 其余时候跟在最后一行字后面；那里放不下，或者公告要在卡片里滚动时，自己占一行
          Widget? bottom;
          double line;
          bool closeNarrow;
          if (timed || clipped) {
            var more = measure.height("显示全部".t, moreStyle) + 4;
            line = timed
                ? math.max(
                    measure.height("00:00:00", timeStyle), clipped ? more : 0)
                : more;
            y += 2;
            closeNarrow = y < band;
            bottom = SizedBox(
              height: line,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (timed) Expanded(child: _timeLine(timeStyle)),
                  // 最多占一半，时间排在左边
                  if (clipped)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: narrow / 2),
                      child: InkWell(
                        onTap: () => setState(() => _full = true),
                        borderRadius: AppStyle.radius4,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Text(
                            "显示全部".t,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: moreStyle,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(width: _kCloseRoom),
                ],
              ),
            );
          } else {
            line = last.lastHeight;
            var lineWidth = last.lastNarrow ? narrow : full;
            var fits =
                room > 0 || last.lastRight + _kCloseRoom <= lineWidth + 0.5;
            var height = math.max(
              _kPad * 2 + _kButton,
              y + math.max(6.0, _kButton / 2 - line / 2),
            );
            if (fits && height <= box.maxHeight) {
              closeNarrow = last.lastNarrow;
            } else {
              closeNarrow = y < band;
              bottom = SizedBox(height: line);
            }
          }
          if (bottom != null) {
            bottom = Padding(
              padding: EdgeInsets.only(
                right: closeNarrow ? row - narrow : trail,
              ),
              child: bottom,
            );
            y += line;
          }

          // 下边：最后一行下面至少空 6，× 点的范围不伸出卡片；收起按钮比字高时按它算
          var content = math.max(_kPad * 2 + _kButton, y);
          var padBottom = math.max(
              0.0, y + math.max(6.0, _kButton / 2 - line / 2) - content);
          var closeBottom = padBottom + content - y + line / 2 - _kButton / 2;

          Widget text(String s, TextStyle style, int? lines) => Text(
                s,
                maxLines: lines,
                overflow: lines == null ? null : TextOverflow.ellipsis,
                style: style,
              );
          Widget part(String s, TextStyle style, double width, int? lines) =>
              Padding(
                padding: EdgeInsets.only(right: row - width),
                child: text(s, style, lines),
              );
          var card = Stack(
            children: [
              Padding(
                padding: EdgeInsets.only(bottom: padBottom),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      // 右边不留：字从 [RoomNoticeCard.lead] 开始
                      padding:
                          const EdgeInsets.fromLTRB(_kPad, _kPad, 0, _kPad),
                      child: _CardButton(
                        icon: Icons.keyboard_arrow_up,
                        tooltip: "收起".t,
                        color: colors.body,
                        width: _kButton,
                        height: _kButton,
                        iconSize: 18,
                        onTap: () => widget.onFold(true),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(top: top),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (title.head.isNotEmpty)
                              part(title.head, titleStyle, title.narrow,
                                  title.headLines),
                            if (title.tail.isNotEmpty)
                              part(title.tail, titleStyle, title.full,
                                  title.tailLines),
                            if (body != null) ...[
                              const SizedBox(height: 2),
                              // 挨着按钮的几行不跟着滚，滚动的部分始终在按钮下面
                              if (body.head.isNotEmpty)
                                part(body.head, bodyStyle, body.narrow,
                                    body.headLines),
                              if (body.tail.isNotEmpty)
                                Flexible(
                                  child: SingleChildScrollView(
                                    padding: EdgeInsets.only(
                                      right: row - body.full,
                                    ),
                                    child: text(
                                        body.tail, bodyStyle, body.tailLines),
                                  ),
                                ),
                            ],
                            if (timed || clipped) const SizedBox(height: 2),
                            if (bottom != null) bottom,
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                right:
                    (closeNarrow ? row - narrow : trail) - (_kButton - 16) / 2,
                bottom: closeBottom,
                child: _CardButton(
                  icon: Icons.close,
                  tooltip: "关闭".t,
                  color: colors.faint,
                  width: _kButton,
                  height: _kButton,
                  iconSize: 16,
                  onTap: widget.onClose,
                ),
              ),
            ],
          );
          return width < box.maxWidth
              ? SizedBox(width: width, child: card)
              : card;
        },
      ),
    );
  }
}

/// 量字用的 TextPainter，设置和 Text 组件画字时一样（默认字体、缩放、语言、粗体）
class _Measure {
  final TextStyle base;
  final TextScaler scaler;
  final TextDirection direction;
  final Locale? locale;
  final TextHeightBehavior? heightBehavior;
  final TextWidthBasis widthBasis;

  _Measure._(
    this.base,
    this.scaler,
    this.direction,
    this.locale,
    this.heightBehavior,
    this.widthBasis,
  );

  factory _Measure(BuildContext context) {
    var defaults = DefaultTextStyle.of(context);
    var base = defaults.style;
    if (MediaQuery.boldTextOf(context)) {
      base = base.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    return _Measure._(
      base,
      MediaQuery.textScalerOf(context),
      Directionality.of(context),
      Localizations.maybeLocaleOf(context),
      defaults.textHeightBehavior ?? DefaultTextHeightBehavior.maybeOf(context),
      defaults.textWidthBasis,
    );
  }

  /// 给 [_FloatText.layout] 用：[maxLines] 不为 null 时和 Text 一样末尾加省略号
  _Painter painter(TextStyle style) {
    var effective = base.merge(style);
    return (text, maxLines) => TextPainter(
          text: TextSpan(text: text, style: effective),
          maxLines: maxLines,
          ellipsis: maxLines == null ? null : "…",
          textDirection: direction,
          textScaler: scaler,
          locale: locale,
          textHeightBehavior: heightBehavior,
          textWidthBasis: widthBasis,
        );
  }

  /// [text] 在 [width] 宽里最多排 [maxLines] 行时，最长的一行多宽
  double longestLine(
    String text,
    TextStyle style,
    int maxLines, [
    double width = double.infinity,
  ]) {
    var p = painter(style)(text, maxLines)
      ..layout(maxWidth: math.max(0.0, width));
    var longest = 0.0;
    for (var line in p.computeLineMetrics()) {
      longest = math.max(longest, line.left + line.width);
    }
    p.dispose();
    return longest;
  }

  /// 一行 [text] 多高
  double height(String text, TextStyle style) {
    var p = painter(style)(text, 1)..layout();
    var h = p.height;
    p.dispose();
    return h;
  }
}

typedef _Painter = TextPainter Function(String text, int? maxLines);

/// 一段字绕开右上角的浮动按钮排（像网页里的 float）：从 top 往下排，
/// 上边落在 band 以内的行按窄的宽度折行，下面的行用整行宽度。
/// 拆成上下两段，各用一个 Text 画，同样的字体，看不出接缝
class _FloatText {
  /// 挨着按钮、按窄的宽度排的几行，和下面整行宽的部分（都可能是空的）
  final String head;
  final String tail;

  /// 两段各自最多几行（null 是不限）
  final int? headLines;
  final int? tailLines;

  /// 整行和挨着按钮的宽度
  final double full;
  final double narrow;

  /// 一共多高；最后一行多高、右端在哪、是不是挨着按钮
  final double height;
  final double lastHeight;
  final double lastRight;
  final bool lastNarrow;

  /// 超过了最多的行数（显示不全）
  final bool exceeded;

  const _FloatText({
    required this.head,
    required this.tail,
    required this.headLines,
    required this.tailLines,
    required this.full,
    required this.narrow,
    required this.height,
    required this.lastHeight,
    required this.lastRight,
    required this.lastNarrow,
    required this.exceeded,
  });

  static _FloatText layout(
    String text,
    _Painter painter, {
    required double full,
    required double narrow,
    required double top,
    required double band,
    int? maxLines,
  }) {
    // 整段一个宽度
    _FloatText whole(bool isNarrow) {
      var p = painter(text, maxLines)
        ..layout(maxWidth: isNarrow ? narrow : full);
      var lines = p.computeLineMetrics();
      var result = _FloatText(
        head: isNarrow ? text : "",
        tail: isNarrow ? "" : text,
        headLines: maxLines,
        tailLines: maxLines,
        full: full,
        narrow: narrow,
        height: p.height,
        lastHeight: lines.isEmpty ? p.height : lines.last.height,
        lastRight: lines.isEmpty ? 0 : lines.last.left + lines.last.width,
        lastNarrow: isNarrow,
        exceeded: p.didExceedMaxLines,
      );
      p.dispose();
      return result;
    }

    if (narrow >= full || top >= band || text.isEmpty) {
      return whole(false);
    }
    var all = painter(text, null)..layout(maxWidth: narrow);
    var lines = all.computeLineMetrics();
    // 有几行的上边在按钮那一截里
    var n = 0;
    var y = top;
    while (n < lines.length && y < band) {
      y += lines[n].height;
      n++;
    }
    if (n >= lines.length || (maxLines != null && n >= maxLines)) {
      all.dispose();
      return whole(true);
    }
    // 第 n 行从哪个字开始（行尾的空格、换行算上一行的）
    var next = lines[n];
    var at = all.getPositionForOffset(
      Offset(next.left + next.width / 2, y - top + next.height / 2),
    );
    var start = all.getLineBoundary(at).start;
    all.dispose();
    if (start <= 0 || start >= text.length) {
      return whole(true);
    }
    var head = text.substring(0, start);
    if (head.endsWith("\n")) {
      head = head.substring(0, head.length - 1);
    }
    if (head.endsWith("\r")) {
      head = head.substring(0, head.length - 1);
    }
    var tail = text.substring(start);
    var headPainter = painter(head, null)..layout(maxWidth: narrow);
    var headHeight = headPainter.height;
    var same = head.isNotEmpty && headPainter.computeLineMetrics().length == n;
    headPainter.dispose();
    // 单独排上一段时和整段排的前几行不一样（不应该）：整段都按窄的排，总不会挡住按钮
    if (!same) {
      return whole(true);
    }
    var rest = maxLines == null ? null : maxLines - n;
    var tailPainter = painter(tail, rest)..layout(maxWidth: full);
    var tailLines = tailPainter.computeLineMetrics();
    var result = _FloatText(
      head: head,
      tail: tail,
      headLines: null,
      tailLines: rest,
      full: full,
      narrow: narrow,
      height: headHeight + tailPainter.height,
      lastHeight:
          tailLines.isEmpty ? tailPainter.height : tailLines.last.height,
      lastRight:
          tailLines.isEmpty ? 0 : tailLines.last.left + tailLines.last.width,
      lastNarrow: false,
      exceeded: tailPainter.didExceedMaxLines,
    );
    tailPainter.dispose();
    return result;
  }
}

class _CardColors {
  final Color title;
  final Color body;
  final Color faint;
  const _CardColors({
    required this.title,
    required this.body,
    required this.faint,
  });
}

/// 卡片里的小按钮（收起、展开、关闭）
class _CardButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final double width;
  final double height;
  final double iconSize;
  final VoidCallback onTap;
  const _CardButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.height,
    required this.onTap,
    this.width = 30,
    this.iconSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 16,
        child: SizedBox(
          width: width,
          height: height,
          child: Center(child: Icon(icon, size: iconSize, color: color)),
        ),
      ),
    );
  }
}

/// 把子组件的大小报出来（布局完、这一帧画完以后）；大小没变不报
class SizeReporter extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onSize;
  const SizeReporter({required this.onSize, super.child, super.key});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReporter(onSize);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderSizeReporter).onSize = onSize;
  }
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onSize);

  ValueChanged<Size> onSize;
  Size? _reported;

  @override
  void performLayout() {
    super.performLayout();
    if (_reported == size) {
      return;
    }
    _reported = size;
    // 布局中不能改状态，等这一帧画完
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached && _reported != null) {
        onSize(_reported!);
      }
    });
  }
}
