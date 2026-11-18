import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/capture/capture_settings.dart';

/// 一个页面（直播间）里截图和录屏要用到的图层。
///
/// 每一层用 [CaptureLayerBox] 包起来登记在这里：截图时按它在屏幕上的位置拼图，
/// 画面录制时按播放器（和侧栏）的位置告诉原生端录哪一块，并把没选的层暂时藏起来。
/// 普通视图和全屏页可能各有一份控制层，取当前页面里看得见的那一份
class CaptureScope {
  final Map<CaptureLayer, List<_CaptureLayerBoxState>> _boxes = {};

  /// 画面录制期间藏起来的层（没选进录屏的）；截完整窗口时没选的侧栏也暂时藏起来
  final RxSet<CaptureLayer> hidden = <CaptureLayer>{}.obs;

  /// 正在截完整窗口：页面上的视频换成截到的那一帧（页面截图里不能有视频纹理），
  /// 截图、录屏键藏起来
  final RxBool stillCapture = false.obs;

  /// [stillCapture] 时代替视频显示的那一帧
  ui.Image? freezeFrame;

  /// 画面录制时录到的范围里有截图、录屏键：键变透明（还能点）
  final RxBool buttonsHidden = false.obs;

  /// 截图时播放器上闪一下：每截一张加一（见 [CaptureFlash]）
  final ValueNotifier<int> flashes = ValueNotifier(0);

  void flash() => flashes.value++;

  void _add(CaptureLayer layer, _CaptureLayerBoxState state) {
    (_boxes[layer] ??= []).add(state);
  }

  void _remove(CaptureLayer layer, _CaptureLayerBoxState state) {
    _boxes[layer]?.remove(state);
  }

  /// 这一层现在看得见的那一份：后登记的优先，在最上面的页面里的优先
  /// （全屏页盖着普通视图时取全屏页的）；上面只盖着底部弹窗等时也算。
  /// 除了播放器本身，只取和播放器在同一个页面里的
  _CaptureLayerBoxState? _visible(CaptureLayer layer) {
    var player =
        layer == CaptureLayer.player ? null : _pick(CaptureLayer.player, null);
    if (layer != CaptureLayer.player && player == null) {
      return null;
    }
    return _pick(layer, player?.route);
  }

  _CaptureLayerBoxState? _pick(CaptureLayer layer, ModalRoute<Object?>? route) {
    var list = _boxes[layer];
    if (list == null) {
      return null;
    }
    bool sameRoute(_CaptureLayerBoxState s) =>
        route == null || s.route == route;
    for (var current in [true, false]) {
      for (var state in list.reversed) {
        if (sameRoute(state) &&
            state.showing &&
            (!current || state.route?.isCurrent != false)) {
          return state;
        }
      }
    }
    return null;
  }

  /// 这一层在屏幕上的位置（逻辑像素，相对 Flutter 视图），看不见时为 null
  Rect? rectOf(CaptureLayer layer) => _visible(layer)?.globalRect;

  /// 这一层看得见的每一个（SC、礼物卡片可能有好几张），和播放器在同一个页面里的
  List<CaptureLayerHandle> handlesOf(CaptureLayer layer) {
    var player = _pick(CaptureLayer.player, null);
    if (player == null) {
      return const [];
    }
    var route = player.route;
    return [
      for (var state in _boxes[layer] ?? const <_CaptureLayerBoxState>[])
        if (state.route == route && state.showing && state.globalRect != null)
          CaptureLayerHandle._(state),
    ];
  }

  BuildContext? contextOf(CaptureLayer layer) => _visible(layer)?.context;

  /// 把这一层截成图片（[pixelRatio] 倍），看不见时为 null。播放器这一层不截
  Future<ui.Image?> imageOf(CaptureLayer layer, double pixelRatio) async {
    if (layer == CaptureLayer.player) {
      return null;
    }
    var state = _visible(layer);
    var boundary = state?.boundary;
    if (boundary == null) {
      return null;
    }
    try {
      return await boundary.toImage(pixelRatio: pixelRatio);
    } catch (_) {
      return null;
    }
  }

  /// [global] 落在看得见的视频信息浮层上（双击浮层隐藏它）
  bool hitsVideoStats(Offset global, {bool shown = true}) {
    if (!shown) {
      return false;
    }
    var rect = rectOf(CaptureLayer.videoStats);
    return rect != null && !rect.isEmpty && rect.contains(global);
  }
}

/// 登记的一层里的一个：位置和截图
class CaptureLayerHandle {
  final _CaptureLayerBoxState _state;
  CaptureLayerHandle._(this._state);

  Rect get rect => _state.globalRect ?? Rect.zero;

  Future<ui.Image?> capture(double pixelRatio) async {
    var boundary = _state.boundary;
    if (boundary == null) {
      return null;
    }
    try {
      return await boundary.toImage(pixelRatio: pixelRatio);
    } catch (_) {
      return null;
    }
  }
}

/// 页面上的视频（完整窗口截图时换成截到的帧）。[fit] 用来摆这一帧
class CaptureVideoMask extends StatelessWidget {
  final CaptureScope? scope;
  final BoxFit fit;
  final Widget child;

  const CaptureVideoMask({
    required this.scope,
    required this.child,
    this.fit = BoxFit.contain,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    var scope = this.scope;
    if (scope == null) {
      return child;
    }
    return Obx(() {
      var masked = scope.stillCapture.value;
      var frame = scope.freezeFrame;
      return Stack(
        fit: StackFit.passthrough,
        children: [
          Opacity(opacity: masked ? 0 : 1, child: child),
          if (masked && frame != null)
            Positioned.fill(
              child: ColoredBox(
                color: const Color(0xFF000000),
                child: RawImage(image: frame, fit: fit),
              ),
            ),
        ],
      );
    });
  }
}

/// 截图、录屏键：截完整窗口时藏起来，画面录制录到它们时变透明（还能点）
class CaptureButtonVisibility extends StatelessWidget {
  final CaptureScope? scope;
  final Widget child;
  const CaptureButtonVisibility({
    required this.scope,
    required this.child,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    var scope = this.scope;
    if (scope == null) {
      return child;
    }
    return Obx(
      () => Opacity(
        opacity: scope.stillCapture.value || scope.buttonsHidden.value ? 0 : 1,
        child: child,
      ),
    );
  }
}

/// 登记一层：截图时截它，画面录制时没选它就暂时藏起来（透明，不停掉里面的东西）。
/// [scope] 为 null 时就是 [child]
class CaptureLayerBox extends StatefulWidget {
  final CaptureScope? scope;
  final CaptureLayer layer;
  final Widget child;

  const CaptureLayerBox({
    required this.scope,
    required this.layer,
    required this.child,
    super.key,
  });

  @override
  State<CaptureLayerBox> createState() => _CaptureLayerBoxState();
}

class _CaptureLayerBoxState extends State<CaptureLayerBox> {
  final GlobalKey _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    widget.scope?._add(widget.layer, this);
  }

  @override
  void didUpdateWidget(CaptureLayerBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope || oldWidget.layer != widget.layer) {
      oldWidget.scope?._remove(oldWidget.layer, this);
      widget.scope?._add(widget.layer, this);
    }
  }

  @override
  void dispose() {
    widget.scope?._remove(widget.layer, this);
    super.dispose();
  }

  RenderBox? get _box {
    var object = _key.currentContext?.findRenderObject();
    return object is RenderBox && object.attached && object.hasSize
        ? object
        : null;
  }

  RenderRepaintBoundary? get boundary {
    var object = _key.currentContext?.findRenderObject();
    return object is RenderRepaintBoundary ? object : null;
  }

  ModalRoute<Object?>? get route => mounted ? ModalRoute.of(context) : null;

  /// 页面还在、没被 Offstage 收起、有大小
  bool get showing {
    if (!mounted) {
      return false;
    }
    var box = _box;
    if (box == null || box.size.isEmpty) {
      return false;
    }
    if (route?.isActive == false) {
      return false;
    }
    RenderObject? node = box;
    while (node != null) {
      if (node is RenderOffstage && node.offstage) {
        return false;
      }
      node = node.parent;
    }
    return true;
  }

  Rect? get globalRect {
    var box = _box;
    if (box == null) {
      return null;
    }
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    var scope = widget.scope;
    if (scope == null) {
      return widget.child;
    }
    // 播放器这一层只量位置，不用单独的图层；页面整个截（里面的视频截图时会换成帧）。
    // 上面盖一层截图时的闪光
    if (widget.layer == CaptureLayer.player) {
      return KeyedSubtree(
        key: _key,
        child: Stack(
          alignment: Alignment.topLeft,
          fit: StackFit.passthrough,
          children: [
            widget.child,
            Positioned.fill(child: CaptureFlash(scope: scope)),
          ],
        ),
      );
    }
    return RepaintBoundary(
      key: _key,
      child: Obx(
        () => Opacity(
          opacity: scope.hidden.contains(widget.layer) ? 0 : 1,
          child: widget.child,
        ),
      ),
    );
  }
}

/// 截图时盖在播放器上的闪光：白色，约 150 毫秒淡出，不挡点击。
/// 截完整窗口的那一帧不显示，所以不会进截图
class CaptureFlash extends StatefulWidget {
  final CaptureScope scope;
  const CaptureFlash({required this.scope, super.key});

  static const Duration duration = Duration(milliseconds: 150);

  @override
  State<CaptureFlash> createState() => _CaptureFlashState();
}

class _CaptureFlashState extends State<CaptureFlash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation =
      AnimationController(vsync: this, duration: CaptureFlash.duration);

  @override
  void initState() {
    super.initState();
    widget.scope.flashes.addListener(_start);
  }

  @override
  void didUpdateWidget(CaptureFlash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) {
      oldWidget.scope.flashes.removeListener(_start);
      widget.scope.flashes.addListener(_start);
    }
  }

  @override
  void dispose() {
    widget.scope.flashes.removeListener(_start);
    _animation.dispose();
    super.dispose();
  }

  void _start() {
    if (mounted) {
      _animation.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Obx(() {
        var still = widget.scope.stillCapture.value;
        return AnimatedBuilder(
          animation: _animation,
          builder: (_, __) {
            if (still || !_animation.isAnimating) {
              return const SizedBox.shrink();
            }
            var t = Curves.easeOut.transform(_animation.value);
            return ColoredBox(
              color: Color.fromARGB((77 * (1 - t)).round(), 255, 255, 255),
            );
          },
        );
      }),
    );
  }
}
