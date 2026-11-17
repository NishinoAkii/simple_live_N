import 'package:canvas_danmaku/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'models/danmaku_item.dart';
import 'scroll_danmaku_painter.dart';
import 'special_danmaku_painter.dart';
import 'static_danmaku_painter.dart';
import 'danmaku_controller.dart';
import 'dart:ui' as ui;
import 'models/danmaku_option.dart';
import '/models/danmaku_content_item.dart';
import 'dart:math';

class DanmakuScreen extends StatefulWidget {
  // 创建Screen后返回控制器
  final Function(DanmakuController) createdController;
  final DanmakuOption option;

  const DanmakuScreen({
    required this.createdController,
    required this.option,
    super.key,
  });

  @override
  State<DanmakuScreen> createState() => _DanmakuScreenState();
}

class _DanmakuScreenState extends State<DanmakuScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  /// 视图宽度
  double _viewWidth = 0;

  /// 弹幕控制器
  late DanmakuController _controller;

  /// 弹幕动画控制器
  late AnimationController _animationController;

  /// 静态弹幕动画控制器
  late AnimationController _staticAnimationController;

  /// SimpleLive: 顶部、底部弹幕有变化时只重画那一层。原来每 100 毫秒对整个弹幕层
  /// setState，连带重新布局、重新测量行高，滚动弹幕层也跟着重建
  final _staticRepaint = _RepaintSignal();

  /// 弹幕配置
  DanmakuOption _option = DanmakuOption();

  /// 滚动弹幕
  final List<DanmakuItem> _scrollDanmakuItems = [];

  /// 顶部弹幕
  final List<DanmakuItem> _topDanmakuItems = [];

  /// 底部弹幕
  final List<DanmakuItem> _bottomDanmakuItems = [];

  /// 高级弹幕
  final List<DanmakuItem> _specialDanmakuItems = [];

  /// 弹幕高度
  late double _danmakuHeight;

  /// 弹幕轨道数
  late int _trackCount;

  /// 弹幕轨道位置
  final List<double> _trackYPositions = [];

  late final _random = Random();

  /// 内部计时器
  int get _tick => _stopwatch.elapsedMilliseconds;

  final _stopwatch = Stopwatch();

  /// 运行状态
  bool _running = true;

  @override
  void initState() {
    super.initState();
    // 计时器初始化
    _startTick();
    _option = widget.option;
    _controller = DanmakuController(
      onAddDanmaku: addDanmaku,
      onUpdateOption: updateOption,
      onPause: pause,
      onResume: resume,
      onClear: clearDanmakus,
    );
    _controller.option = _option;
    widget.createdController.call(
      _controller,
    );

    _animationController = AnimationController(
      vsync: this,
      duration: Duration(seconds: _option.duration),
    )..repeat();

    _staticAnimationController = AnimationController(
      vsync: this,
      duration: Duration(seconds: _option.duration),
    );

    WidgetsBinding.instance.addObserver(this);
  }

  /// SimpleLive: 因为切到后台暂停的，回到前台时恢复
  bool _pausedInBackground = false;

  /// 处理 Android/iOS 应用后台或熄屏导致的动画问题
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      if (_running) {
        pause();
        _pausedInBackground = true;
      }
    } else if (state == AppLifecycleState.resumed && _pausedInBackground) {
      // SimpleLive: 原来只暂停不恢复，回到前台后新弹幕一直被丢弃
      _pausedInBackground = false;
      resume();
    }
  }

  @override
  void dispose() {
    _running = false;
    WidgetsBinding.instance.removeObserver(this);
    _animationController.dispose();
    _staticAnimationController.dispose();
    _staticRepaint.dispose();
    _stopwatch.stop();
    DanmakuItem.disposeAll(_scrollDanmakuItems);
    DanmakuItem.disposeAll(_topDanmakuItems);
    DanmakuItem.disposeAll(_bottomDanmakuItems);
    DanmakuItem.disposeAll(_specialDanmakuItems);
    super.dispose();
  }

  /// 添加弹幕
  void addDanmaku(DanmakuContentItem content) {
    if (!_running || !mounted) {
      return;
    }

    if (content.type == DanmakuItemType.special) {
      if (!_option.hideSpecial) {
        (content as SpecialDanmakuContentItem).painterCache = TextPainter(
          text: TextSpan(
            text: content.text,
            style: TextStyle(
              color: content.color,
              fontSize: content.fontSize,
              fontWeight: FontWeight.values[_option.fontWeight],
              shadows: content.hasStroke
                  ? [
                      Shadow(
                          color: Colors.black.withOpacity(
                              content.alphaTween?.begin ??
                                  content.color.opacity),
                          blurRadius: 2)
                    ]
                  : null,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        _specialDanmakuItems.add(DanmakuItem(
          width: 0,
          height: 0,
          creationTime: _tick,
          content: content,
          paragraph: null,
          strokeParagraph: null,
        ));
      } else {
        return;
      }
    } else {
      // SimpleLive: 还没有布局（没有轨道）时放不下，直接丢弃
      if (_trackYPositions.isEmpty) {
        return;
      }
      // SimpleLive: 放不下的先丢，不排版。弹幕多的直播间大部分弹幕放不下，
      // 原来排完版才发现没地方，再扔掉，白白占用主线程
      if (_noRoomFor(content)) {
        return;
      }
      // SimpleLive: 图文弹幕（表情显示为图片）。图片先 clone 一份给这条弹幕，
      // 没能上屏时立即释放。滚动的大表情默认占两条轨道，行内表情约一行高，
      // 都按 emoteScale 缩放；滚动弹幕放不下一行时多占几条轨道，
      // 顶部、底部弹幕的表情不超过一行
      final images = content.hasImages ? _cloneImages(content) : null;
      final scroll = content.type == DanmakuItemType.scroll;
      final maxSpan = max(1, _trackCount);
      var span = 1;
      final double danmakuWidth;
      final double danmakuHeight;
      final ui.Paragraph paragraph;
      double stickerHeight = 0;
      var emoteFactor = Utils.emoteScale * _option.emoteScale;
      if (!scroll) {
        emoteFactor = min(
          emoteFactor,
          max(Utils.emoteScale, (_danmakuHeight - 2) / _option.fontSize),
        );
      }
      if (images != null) {
        if (content.sticker) {
          if (scroll && _trackCount >= 3) {
            span = (2 * _option.emoteScale).round().clamp(1, maxSpan);
          }
          stickerHeight = _danmakuHeight * span - 2;
        }
        paragraph = Utils.generateParagraph(
            content, double.infinity, _option.fontSize, _option.fontWeight,
            stickerHeight: stickerHeight,
            emoteHeight: _option.fontSize * emoteFactor);
        danmakuWidth = paragraph.maxIntrinsicWidth.ceilToDouble();
        paragraph.layout(ui.ParagraphConstraints(width: danmakuWidth));
        if (!content.sticker && scroll) {
          span = (paragraph.height / _danmakuHeight - 0.15)
              .ceil()
              .clamp(1, maxSpan);
        }
        danmakuHeight = content.sticker
            ? _danmakuHeight * span
            : max(paragraph.height, _danmakuHeight * span);
      } else {
        // 在这里提前创建 Paragraph 缓存防止卡顿。
        // SimpleLive: 宽度直接从这段文字本身量（原来另用 TextPainter 再排一遍）
        paragraph = Utils.generateParagraph(
            content, double.infinity, _option.fontSize, _option.fontWeight);
        danmakuWidth = paragraph.maxIntrinsicWidth.ceilToDouble();
        paragraph.layout(ui.ParagraphConstraints(width: danmakuWidth));
        danmakuHeight = paragraph.height;
      }

      ui.Paragraph? strokeParagraph;
      if (_option.showStroke) {
        strokeParagraph = Utils.generateStrokeParagraph(
            content, danmakuWidth, _option.fontSize, _option.fontWeight,
            stickerHeight: stickerHeight,
            emoteHeight: _option.fontSize * emoteFactor);
      }

      DanmakuItem makeItem(double yPosition) => DanmakuItem(
          yPosition: yPosition,
          xPosition: _viewWidth,
          width: danmakuWidth,
          height: danmakuHeight,
          creationTime: _tick,
          content: content,
          paragraph: paragraph,
          strokeParagraph: strokeParagraph,
          images: images,
          trackSpan: span,
          emoteFactor: emoteFactor);

      final countBefore = _scrollDanmakuItems.length +
          _topDanmakuItems.length +
          _bottomDanmakuItems.length;
      int idx = 1;
      for (double yPosition in _trackYPositions) {
        if (content.type == DanmakuItemType.scroll && !_option.hideScroll) {
          // 占两条轨道时最后一条放不下
          bool scrollCanAddToTrack = idx - 1 + span <= _trackCount &&
              _scrollCanAddToTrack(yPosition, danmakuWidth, span);

          if (scrollCanAddToTrack) {
            _scrollDanmakuItems.add(makeItem(yPosition));
            break;
          }

          /// 无法填充自己发送的弹幕时强制添加
          if (content.selfSend && idx == _trackCount) {
            _scrollDanmakuItems.add(makeItem(_trackYPositions[0]));
            break;
          }

          /// 海量弹幕启用时进行随机添加
          if (_option.massiveMode && idx == _trackCount) {
            var randomYPosition = _trackYPositions[
                _random.nextInt(_trackYPositions.length - span + 1)];
            _scrollDanmakuItems.add(makeItem(randomYPosition));
            break;
          }
        }

        if (content.type == DanmakuItemType.top && !_option.hideTop) {
          bool topCanAddToTrack = _topCanAddToTrack(yPosition);

          if (topCanAddToTrack) {
            _topDanmakuItems.add(makeItem(yPosition));
            break;
          }
        }

        if (content.type == DanmakuItemType.bottom && !_option.hideBottom) {
          bool bottomCanAddToTrack = _bottomCanAddToTrack(yPosition);

          if (bottomCanAddToTrack) {
            _bottomDanmakuItems.add(makeItem(yPosition));
            break;
          }
        }
        idx++;
      }
      if (_scrollDanmakuItems.length +
              _topDanmakuItems.length +
              _bottomDanmakuItems.length ==
          countBefore) {
        // 没有轨道放得下，丢弃
        paragraph.dispose();
        strokeParagraph?.dispose();
        if (images != null) {
          for (final image in images) {
            image.dispose();
          }
        }
        return;
      }
    }

    switch (content.type) {
      case DanmakuItemType.top:
      case DanmakuItemType.bottom:
        // 重绘静态弹幕
        _staticRepaint.ping();
        break;
      case DanmakuItemType.scroll:
      case DanmakuItemType.special:
        if (!_animationController.isAnimating &&
            (_scrollDanmakuItems.isNotEmpty ||
                _specialDanmakuItems.isNotEmpty)) {
          _animationController.repeat();
        }
        break;
    }
  }

  /// SimpleLive: clone 弹幕里的图片，给这条弹幕自己持有。
  /// 调用方的图片已被释放时返回 null，按纯文字显示
  List<ui.Image>? _cloneImages(DanmakuContentItem content) {
    final images = <ui.Image>[];
    try {
      for (final segment in content.segments!) {
        if (segment.isImage) {
          images.add(segment.image!.clone());
        }
      }
      return images;
    } catch (_) {
      for (final image in images) {
        image.dispose();
      }
      return null;
    }
  }

  /// 暂停
  void pause() {
    if (!mounted) return;
    // SimpleLive: 手动暂停的，回到前台不自动恢复
    _pausedInBackground = false;
    if (_running) {
      setState(() {
        _running = false;
      });
      if (_animationController.isAnimating) {
        _animationController.stop();
      }
      if (_stopwatch.isRunning) {
        _stopwatch.stop();
      }
    }
  }

  /// 恢复
  void resume() {
    if (!mounted) return;
    if (!_running) {
      setState(() {
        _running = true;
      });
      if (!_animationController.isAnimating) {
        // SimpleLive: 停着的这段时间不算，从停下的位置接着走
        for (final item in _scrollDanmakuItems) {
          item.lastDrawTick = null;
        }
        _animationController.repeat();
        // 重启计时器
        _startTick();
      }
    }
  }

  /// 更新弹幕设置
  void updateOption(DanmakuOption option) {
    bool needRestart = false;
    bool needClearParagraph = false;
    if (_animationController.isAnimating) {
      _animationController.stop();
      needRestart = true;
    }

    if (option.fontSize != _option.fontSize) {
      needClearParagraph = true;
    }

    /// 需要隐藏弹幕时清理已有弹幕
    if (option.hideScroll && !_option.hideScroll) {
      DanmakuItem.disposeAll(_scrollDanmakuItems);
    }
    if (option.hideTop && !_option.hideTop) {
      DanmakuItem.disposeAll(_topDanmakuItems);
    }
    if (option.hideBottom && !_option.hideBottom) {
      DanmakuItem.disposeAll(_bottomDanmakuItems);
    }
    _option = option;
    _controller.option = _option;

    /// 清理已经存在的 Paragraph 缓存
    if (needClearParagraph) {
      for (DanmakuItem item in [
        ..._scrollDanmakuItems,
        ..._topDanmakuItems,
        ..._bottomDanmakuItems,
      ]) {
        item.paragraph?.dispose();
        item.paragraph = null;
        item.strokeParagraph?.dispose();
        item.strokeParagraph = null;
        item.imageRects = null;
      }
    }
    if (needRestart) {
      _animationController.repeat();
    }
    setState(() {});
  }

  /// 清空弹幕
  void clearDanmakus() {
    if (!mounted) return;
    setState(() {
      DanmakuItem.disposeAll(_scrollDanmakuItems);
      DanmakuItem.disposeAll(_topDanmakuItems);
      DanmakuItem.disposeAll(_bottomDanmakuItems);
      DanmakuItem.disposeAll(_specialDanmakuItems);
    });
    _animationController.stop();
  }

  /// SimpleLive: 两条弹幕是否占用同一条轨道（大表情占两条）
  bool _sharesTrack(DanmakuItem item, double yPosition, int span) {
    if (item.trackSpan == 1 && span == 1) {
      return item.yPosition == yPosition;
    }
    final bottom = yPosition + span * _danmakuHeight;
    final itemBottom = item.yPosition + item.trackSpan * _danmakuHeight;
    return item.yPosition < bottom - 0.5 && yPosition < itemBottom - 0.5;
  }

  /// 确定滚动弹幕是否可以添加
  bool _scrollCanAddToTrack(double yPosition, double newDanmakuWidth,
      [int span = 1]) {
    for (var item in _scrollDanmakuItems) {
      if (_sharesTrack(item, yPosition, span)) {
        final existingEndPosition = item.xPosition + item.width;
        // 首先保证进入屏幕时不发生重叠，其次保证知道移出屏幕前不与速度慢的弹幕(弹幕宽度较小)发生重叠
        if (_viewWidth - existingEndPosition < 0) {
          return false;
        }
        if (item.width < newDanmakuWidth) {
          if ((1 -
                  ((_viewWidth - item.xPosition) / (item.width + _viewWidth))) >
              ((_viewWidth) / (_viewWidth + newDanmakuWidth))) {
            return false;
          }
        }
      }
    }
    return true;
  }

  /// SimpleLive: 这条弹幕肯定放不下：滚动弹幕时每条轨道上都还有没完全进屏的弹幕
  /// （自己发的和海量模式照旧硬塞）；隐藏的类型也不用排版
  bool _noRoomFor(DanmakuContentItem content) {
    switch (content.type) {
      case DanmakuItemType.scroll:
        if (_option.hideScroll) return true;
        if (content.selfSend || _option.massiveMode) return false;
        final busy = List<bool>.filled(_trackCount, false);
        for (final item in _scrollDanmakuItems) {
          if (_viewWidth - (item.xPosition + item.width) >= 0) continue;
          final first = (item.yPosition / _danmakuHeight).round();
          for (var i = first; i < first + item.trackSpan; i++) {
            if (i >= 0 && i < busy.length) busy[i] = true;
          }
        }
        return !busy.contains(false);
      case DanmakuItemType.top:
        return _option.hideTop;
      case DanmakuItemType.bottom:
        return _option.hideBottom;
      case DanmakuItemType.special:
        return false;
    }
  }

  /// SimpleLive: 这一帧的时间戳（毫秒）。帧外调用时没有，用钟点代替
  double _frameTime() {
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.idle) {
      return _stopwatchOffset + _stopwatch.elapsedMicroseconds / 1000.0;
    }
    final now = binding.currentFrameTimeStamp.inMicroseconds / 1000.0;
    // 记下两个时钟的差，帧外取到的也接得上
    _stopwatchOffset = now - _stopwatch.elapsedMicroseconds / 1000.0;
    return now;
  }

  double _stopwatchOffset = 0;

  /// 确定顶部弹幕是否可以添加
  bool _topCanAddToTrack(double yPosition) {
    for (var item in _topDanmakuItems) {
      if (item.yPosition == yPosition) {
        return false;
      }
    }
    return true;
  }

  /// 确定底部弹幕是否可以添加
  bool _bottomCanAddToTrack(double yPosition) {
    for (var item in _bottomDanmakuItems) {
      if (item.yPosition == yPosition) {
        return false;
      }
    }
    return true;
  }

  // 基于Stopwatch的计时器同步
  void _startTick() async {
    // _stopwatch.reset();
    _stopwatch.start();

    final staticDuration = _option.duration * 1000;

    while (_running && mounted) {
      await Future.delayed(const Duration(milliseconds: 100));
      // 移除屏幕外滚动弹幕
      DanmakuItem.removeWhere(
          _scrollDanmakuItems, (item) => item.xPosition + item.width < 0);
      // SimpleLive: 有顶部或底部弹幕时才需要重画那一层（到时间的要擦掉）
      final hadStatic =
          _topDanmakuItems.isNotEmpty || _bottomDanmakuItems.isNotEmpty;
      // 移除顶部弹幕
      DanmakuItem.removeWhere(_topDanmakuItems,
          (item) => (_tick - item.creationTime) >= staticDuration);
      // 移除底部弹幕
      DanmakuItem.removeWhere(_bottomDanmakuItems,
          (item) => (_tick - item.creationTime) >= staticDuration);
      // 移除高级弹幕
      DanmakuItem.removeWhere(
          _specialDanmakuItems,
          (item) =>
              (_tick - item.creationTime) >=
              (item.content as SpecialDanmakuContentItem).duration);
      // 暂停动画
      if (_scrollDanmakuItems.isEmpty &&
          _specialDanmakuItems.isEmpty &&
          _animationController.isAnimating) {
        _animationController.stop();
      }

      /// 重绘静态弹幕
      if (mounted && hadStatic) {
        _staticRepaint.ping();
      }
    }

    _stopwatch.stop();
  }

  @override
  Widget build(BuildContext context) {
    /// 计算弹幕轨道
    final textPainter = TextPainter(
      text: TextSpan(text: '弹幕', style: TextStyle(fontSize: _option.fontSize)),
      textDirection: TextDirection.ltr,
    )..layout();
    _danmakuHeight = textPainter.height;
    textPainter.dispose();
    // SimpleLive: 弹幕层不参与无障碍（读屏）
    // SimpleLive: 弹幕层自成一层，每帧的动画不连带外面的页面重画
    return RepaintBoundary(child:
        ExcludeSemantics(child: LayoutBuilder(builder: (context, constraints) {
      /// 计算视图宽度
      if (constraints.maxWidth != _viewWidth) {
        _viewWidth = constraints.maxWidth;
      }

      _trackCount =
          (constraints.maxHeight * _option.area / _danmakuHeight).floor();

      /// 为字幕留出余量
      if (_option.safeArea && _option.area == 1.0) {
        _trackCount = _trackCount - 1;
      }

      // SimpleLive: 播放器很矮（竖屏小窗口）、显示区域又很小时算出来不到一行，
      // 弹幕全被丢弃；放得下一行就至少留一行
      if (_trackCount < 1 &&
          _option.area > 0 &&
          constraints.maxHeight >= _danmakuHeight) {
        _trackCount = 1;
      }

      _trackYPositions.clear();
      for (int i = 0; i < _trackCount; i++) {
        _trackYPositions.add(i * _danmakuHeight);
      }
      return ClipRect(
        child: IgnorePointer(
          child: Opacity(
            opacity: _option.opacity,
            child: Stack(children: [
              // SimpleLive: 画笔跟着动画自己重画（repaint），不再每帧重建组件；
              // 每帧重建会连带外面的 LayoutBuilder 重新布局
              RepaintBoundary(
                child: CustomPaint(
                  painter: ScrollDanmakuPainter(
                      _animationController.value,
                      _scrollDanmakuItems,
                      _option.duration,
                      _option.fontSize,
                      _option.fontWeight,
                      _option.showStroke,
                      _danmakuHeight,
                      _running,
                      _frameTime,
                      repaint: _animationController),
                  child: const SizedBox.expand(),
                ),
              ),
              RepaintBoundary(
                  child: AnimatedBuilder(
                animation: _staticRepaint,
                builder: (context, child) {
                  return CustomPaint(
                    painter: StaticDanmakuPainter(
                        _staticAnimationController.value,
                        _topDanmakuItems,
                        _bottomDanmakuItems,
                        _option.duration,
                        _option.fontSize,
                        _option.fontWeight,
                        _option.showStroke,
                        _danmakuHeight,
                        _running,
                        _tick),
                    child: Container(),
                  );
                },
              )),
              RepaintBoundary(
                child: CustomPaint(
                  // 与滚动弹幕共用控制器
                  painter: SpecialDanmakuPainter(
                      _animationController.value,
                      _specialDanmakuItems,
                      _option.fontSize,
                      _option.fontWeight,
                      _running,
                      () => _tick,
                      repaint: _animationController),
                  child: const SizedBox.expand(),
                ),
              ),
            ]),
          ),
        ),
      );
    })));
  }
}

/// SimpleLive: 通知静态弹幕层重画
class _RepaintSignal extends ChangeNotifier {
  void ping() => notifyListeners();
}
