import 'dart:async';
import 'dart:io';
import 'package:auto_orientation_v2/auto_orientation_v2.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:floating/floating.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:simple_live_app/app/active_players.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/custom_throttle.dart';
import 'package:simple_live_app/app/player_drag_adjust.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';
import 'package:simple_live_app/app/player_lock.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/window_geometry.dart';
import 'package:simple_live_app/app/window_memory.dart';
import 'package:simple_live_app/app/window_pin.dart';
import 'package:simple_live_app/modules/live_room/player/danmaku_pacer.dart';
import 'package:simple_live_app/modules/live_room/player/fullscreen_orientation.dart';
import 'package:simple_live_app/services/ios_pip/ios_pip_session.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:simple_live_app/i18n/i18n.dart';

mixin PlayerMixin {
  GlobalKey<VideoState> globalPlayerKey = GlobalKey<VideoState>();
  GlobalKey globalDanmuKey = GlobalKey();

  /// 播放器实例
  late final player = Player(
    configuration: PlayerConfiguration(
      title: "Simple Live Player",
      // 至少要 warn：HLS 换初始化段、跳过分段都是警告，花屏检测（PictureGuard）要用
      logLevel: AppSettingsController.instance.logEnable.value
          ? MPVLogLevel.info
          : MPVLogLevel.warn,
    ),
  );

  /// 初始化播放器并设置 ao 参数
  Future<void> initializePlayer() async {
    ActivePlayers.add(player);
    var pp = player.platform as NativePlayer;
    // 设置音频输出驱动
    if (AppSettingsController.instance.customPlayerOutput.value) {
      if (player.platform is NativePlayer) {
        await (player.platform as dynamic).setProperty(
          'ao',
          AppSettingsController.instance.audioOutputDriver.value,
        );
      }
    }
    // media_kit 仓库更新导致的问题，临时解决办法
    if (Platform.isAndroid) {
      await pp.setProperty('force-seekable', 'yes');
    }
  }

  /// 视频控制器
  late final videoController = VideoController(
    player,
    configuration: AppSettingsController.instance.customPlayerOutput.value
        ? VideoControllerConfiguration(
            vo: AppSettingsController.instance.videoOutputDriver.value,
            hwdec: iosPipHwdec(
              AppSettingsController.instance.videoHardwareDecoder.value,
              hardware: true,
            ),
          )
        : AppSettingsController.instance.playerCompatMode.value
            ? const VideoControllerConfiguration(
                vo: 'mediacodec_embed',
                hwdec: 'mediacodec',
              )
            : VideoControllerConfiguration(
                enableHardwareAcceleration:
                    AppSettingsController.instance.hardwareDecode.value,
                androidAttachSurfaceAfterVideoParameters: false,
                // iOS 画中画需要拷回内存的硬件解码
                hwdec: iosPipHwdec(
                  null,
                  hardware: AppSettingsController.instance.hardwareDecode.value,
                ),
              ),
  );
}

mixin PlayerStateMixin on PlayerMixin {
  ///音量控制条计时器
  Timer? hidevolumeTimer;

  /// 是否进入桌面端小窗
  RxBool smallWindowState = false.obs;

  /// 是否在桌面端窗口全屏：画面占满当前窗口，不是系统全屏。
  /// 这时 [fullScreenState] 也是 true（页面只有播放器）
  RxBool windowFullState = false.obs;

  /// 是否显示弹幕
  RxBool showDanmakuState = false.obs;

  /// 是否显示控制器
  RxBool showControlsState = false.obs;

  /// 是否显示设置窗口
  RxBool showSettingState = false.obs;

  /// 是否显示弹幕设置窗口
  RxBool showDanmakuSettingState = false.obs;

  /// 是否处于锁定控制器状态
  RxBool lockControlsState = false.obs;

  /// 是否处于全屏状态
  RxBool fullScreenState = false.obs;

  /// 是否在安卓系统小窗（画中画）里：小窗里的弹幕还是这个页面画的
  RxBool systemPipState = false.obs;

  /// 显示手势Tip
  RxBool showGestureTip = false.obs;

  /// 手势Tip文本
  RxString gestureTipText = "".obs;

  /// 显示提示底部Tip
  RxBool showBottomTip = false.obs;

  /// 提示底部Tip文本
  RxString bottomTipText = "".obs;

  /// 自动隐藏控制器计时器
  Timer? hideControlsTimer;

  /// 自动隐藏提示计时器
  Timer? hideSeekTipTimer;

  /// 是否为竖屏直播间
  var isVertical = false.obs;

  Widget? danmakuView;

  var showQualites = false.obs;
  var showLines = false.obs;

  /// 隐藏控制器
  void hideControls() {
    showControlsState.value = false;
    hideControlsTimer?.cancel();
  }

  void setLockState() {
    lockControlsState.value = !lockControlsState.value;
    PlayerLock.locked.value = lockControlsState.value;
    if (lockControlsState.value) {
      showControlsState.value = false;
    } else {
      showControlsState.value = true;
    }
  }

  /// 显示控制器
  void showControls() {
    showControlsState.value = true;
    resetHideControlsTimer();
  }

  /// 开始隐藏控制器计时
  /// - 当点击控制器上时功能时需要重新计时
  void resetHideControlsTimer() {
    hideControlsTimer?.cancel();

    hideControlsTimer = Timer(
      const Duration(
        seconds: 5,
      ),
      hideControls,
    );
  }

  void updateScaleMode() {
    var boxFit = BoxFit.contain;
    double? aspectRatio;
    if (player.state.width != null && player.state.height != null) {
      aspectRatio = player.state.width! / player.state.height!;
    }

    if (AppSettingsController.instance.scaleMode.value == 0) {
      boxFit = BoxFit.contain;
    } else if (AppSettingsController.instance.scaleMode.value == 1) {
      boxFit = BoxFit.fill;
    } else if (AppSettingsController.instance.scaleMode.value == 2) {
      boxFit = BoxFit.cover;
    } else if (AppSettingsController.instance.scaleMode.value == 3) {
      boxFit = BoxFit.contain;
      aspectRatio = 16 / 9;
    } else if (AppSettingsController.instance.scaleMode.value == 4) {
      boxFit = BoxFit.contain;
      aspectRatio = 4 / 3;
    }
    globalPlayerKey.currentState?.update(
      aspectRatio: aspectRatio,
      fit: boxFit,
    );
  }
}
mixin PlayerDanmakuMixin on PlayerStateMixin {
  /// 弹幕控制器
  DanmakuController? danmakuController;

  /// 一阵一阵到的弹幕匀开上屏，不排成一竖列、也不一下子排版太多掉帧（见 [DanmakuPacer]）
  late final DanmakuPacer<DanmakuContentItem> danmakuPacer = DanmakuPacer(
    (item) {
      if (showDanmakuState.value) {
        danmakuController?.addDanmaku(item);
      }
    },
    // 设置里的“弹幕缓冲增强”，关掉后到了就放；弹幕少于起始量时也不缓冲
    smoothing: () => AppSettingsController.instance.danmuBufferBoost.value,
    minRateOf: () =>
        AppSettingsController.instance.danmuBufferMinRate.value.toDouble(),
  );

  /// 清掉屏上的弹幕和还在排队的
  void clearDanmaku() {
    danmakuPacer.clear();
    danmakuController?.clear();
  }

  void initDanmakuController(DanmakuController e) {
    danmakuController = e;
    // danmakuController?.updateOption(
    //   DanmakuOption(
    //     fontSize: AppSettingsController.instance.danmuSize.value,
    //     area: AppSettingsController.instance.danmuArea.value,
    //     duration: AppSettingsController.instance.danmuSpeed.value,
    //     opacity: AppSettingsController.instance.danmuOpacity.value,
    //     strokeWidth: AppSettingsController.instance.danmuStrokeWidth.value,
    //     fontWeight: FontWeight
    //         .values[AppSettingsController.instance.danmuFontWeight.value],
    //   ),
    // );
  }

  void updateDanmuOption(DanmakuOption? option) {
    if (danmakuController == null || option == null) return;
    danmakuController!.updateOption(option);
  }

  /// 弹幕现在显示在哪里：非全屏、全屏、安卓小窗
  DanmakuViewMode get danmakuViewMode {
    if (systemPipState.value) return DanmakuViewMode.pip;
    return fullScreenState.value
        ? DanmakuViewMode.fullscreen
        : DanmakuViewMode.normal;
  }

  /// 按显示位置套用那一套弹幕大小和速度（手机、平板上各是一套），以及表情大小
  void applyDanmakuViewMode() {
    var option = danmakuController?.option;
    if (option == null) return;
    var settings = AppSettingsController.instance;
    var mode = danmakuViewMode;
    var fontSize = settings.danmuSizeFor(mode);
    var duration = settings.danmuSpeedFor(mode);
    var emoteScale = settings.effectiveEmoteScale;
    if (option.fontSize == fontSize &&
        option.duration == duration &&
        option.emoteScale == emoteScale) {
      return;
    }
    danmakuController!.updateOption(
      option.copyWith(
        fontSize: fontSize,
        duration: duration,
        emoteScale: emoteScale,
      ),
    );
  }

  void disposeDanmakuController() {
    clearDanmaku();
  }

  void addDanmaku(List<DanmakuContentItem> items) {
    if (!showDanmakuState.value) {
      return;
    }
    for (var item in items) {
      danmakuPacer.add(item);
    }
  }
}
mixin PlayerSystemMixin on PlayerMixin, PlayerStateMixin, PlayerDanmakuMixin {
  final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

  final pip = Floating();
  StreamSubscription<PiPStatus>? _pipSubscription;

  /// 手机、平板全屏时的屏幕方向（按设置里的“全屏方向”和视频的横竖）
  late final orienter = FullscreenOrienter(
    vertical: () => FullscreenOrientation.verticalOf(player),
    guess: () => isVertical.value,
    active: () =>
        fullScreenState.value &&
        !smallWindowState.value &&
        (Platform.isAndroid || Platform.isIOS),
  );

  //final VolumeController volumeController = VolumeController();

  /// 初始化一些系统状态
  void initSystem() async {
    if (Platform.isAndroid || Platform.isIOS) {
      VolumeController.instance.showSystemUI = false;
    }

    // 屏幕常亮
    //WakelockPlus.enable();

    // 开始隐藏计时
    resetHideControlsTimer();

    // 进入全屏模式
    if (AppSettingsController.instance.autoFullScreen.value) {
      enterFullScreen();
    }
  }

  /// 释放一些系统状态
  Future resetSystem() async {
    _pipSubscription?.cancel();
    //pip.dispose();
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );

    await setPortraitOrientation();
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      // 亮度重置,桌面平台可能会报错,暂时不处理桌面平台的亮度
      try {
        await ScreenBrightness.instance.resetApplicationScreenBrightness();
      } catch (e) {
        Log.logPrint(e);
      }
    } else {
      await PlayerDragAdjust.resetBrightness();
    }

    await WakelockPlus.disable();
  }

  /// 进入全屏
  void enterFullScreen() {
    fullScreenState.value = true;
    if (Platform.isAndroid || Platform.isIOS) {
      //全屏
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      orienter.apply();
    } else if (windowFullState.value) {
      // 从窗口全屏进系统全屏：先换回系统标题栏，退出全屏时回到普通页面
      windowFullState.value = false;
      () async {
        await _setTitleBar(TitleBarStyle.normal);
        await windowManager.setFullScreen(true);
      }();
    } else {
      windowManager.setFullScreen(true);
    }
    //danmakuController?.clear();
  }

  /// 退出全屏
  void exitFull() {
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge,
          overlays: SystemUiOverlay.values);
      orienter.reset();
      setPortraitOrientation();
    } else if (windowFullState.value) {
      // 窗口全屏：换回系统标题栏，窗口的位置和大小不变
      windowFullState.value = false;
      _setTitleBar(TitleBarStyle.normal);
    } else {
      windowManager.setFullScreen(false);
    }
    fullScreenState.value = false;
    // 锁定只在全屏时有效：退出全屏（如开小窗、页面关闭）时一并解锁
    if (lockControlsState.value) {
      lockControlsState.value = false;
      PlayerLock.locked.value = false;
    }

    //danmakuController?.clear();
  }

  /// 进小窗前主窗口的位置（物理像素）。小窗挪到缩放不同的屏幕上以后，
  /// 退出时也能放回原处、原来的大小
  WindowPlacement? _mainBeforeSmall;

  ///小窗模式()
  void enterSmallWindow() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      fullScreenState.value = true;
      smallWindowState.value = true;
      // 从窗口全屏进小窗：退出小窗时回到普通页面
      windowFullState.value = false;

      // 记下主窗口
      _mainBeforeSmall = await WindowMemory.instance.enterSmall();

      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      // 获取视频窗口大小
      var width = player.state.width ?? 16;
      var height = player.state.height ?? 9;

      // 横屏还是竖屏
      Size size;
      if (height > width) {
        var aspectRatio = width / height;
        size = Size(400, 400 / aspectRatio);
      } else {
        var aspectRatio = height / width;
        size = Size(280 / aspectRatio, 280);
      }
      // 记住了上次小窗的位置和大小时用上次的
      await WindowMemory.instance.placeSmall(size, width / height);

      windowManager.setAlwaysOnTop(true);
    }
  }

  ///退出小窗模式()
  void exitSmallWindow() {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      fullScreenState.value = false;
      smallWindowState.value = false;
      var main = _mainBeforeSmall;
      _mainBeforeSmall = null;
      () async {
        // 先记下小窗，再改回标题栏、放回主窗口
        await WindowMemory.instance.leaveSmall();
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await WindowMemory.instance.restoreMain(main);
        // 小窗总在最前面；回到主窗口后按图钉的状态，没置顶就回到正常层
        await windowManager.setAlwaysOnTop(WindowPin.instance.pinned.value);
      }();
    }
  }

  /// 窗口全屏（电脑）：画面占满当前窗口，窗口的位置和大小不变。系统标题栏换成画面上
  /// 透明的一条（WindowFullFrame），能拖动窗口，置顶、最小化、最大化、关闭还在。
  /// 再点一下、点返回键或双击画面退出（[exitFull]）
  void enterWindowFull() {
    if (!WindowPin.supported || fullScreenState.value) {
      return;
    }
    windowFullState.value = true;
    fullScreenState.value = true;
    _setTitleBar(TitleBarStyle.hidden);
  }

  /// 底栏的窗口全屏键：普通页面时进入，窗口全屏时退出，系统全屏时换成窗口全屏
  Future<void> toggleWindowFull() async {
    if (windowFullState.value) {
      exitFull();
      return;
    }
    if (!WindowPin.supported || smallWindowState.value) {
      return;
    }
    if (!fullScreenState.value) {
      enterWindowFull();
      return;
    }
    windowFullState.value = true;
    try {
      await windowManager.setFullScreen(false);
    } catch (e) {
      Log.logPrint(e);
    }
    await _setTitleBar(TitleBarStyle.hidden);
  }

  Future<void> _setTitleBar(TitleBarStyle style) async {
    try {
      await windowManager.setTitleBarStyle(style);
    } catch (e) {
      // 测试里没有窗口插件
      Log.logPrint(e);
    }
  }

  /// 设置横屏
  Future setLandscapeOrientation() async {
    if (await beforeIOS16()) {
      AutoOrientation.landscapeAutoMode();
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  /// 设置竖屏
  Future setPortraitOrientation() async {
    if (await beforeIOS16()) {
      AutoOrientation.portraitAutoMode();
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  /// 是否是IOS16以下
  Future<bool> beforeIOS16() async {
    if (Platform.isIOS) {
      var info = await deviceInfo.iosInfo;
      var version = info.systemVersion;
      var versionInt = int.tryParse(version.split('.').first) ?? 0;
      return versionInt < 16;
    } else {
      return false;
    }
  }

  Future saveScreenshot() async {
    try {
      SmartDialog.showLoading(msg: "正在保存截图".t);
      //检查相册权限,仅iOS需要
      var permission = await Utils.checkPhotoPermission();
      if (!permission) {
        SmartDialog.showToast("没有相册权限".t);
        SmartDialog.dismiss(status: SmartStatus.loading);
        return;
      }

      var imageData = await player.screenshot();
      if (imageData == null) {
        SmartDialog.showToast("截图失败，没截到画面".t);
        SmartDialog.dismiss(status: SmartStatus.loading);
        return;
      }

      if (Platform.isIOS || Platform.isAndroid) {
        await ImageGallerySaverPlus.saveImage(
          imageData,
        );
        SmartDialog.showToast("截图已保存到相册".t);
      } else {
        //选择保存文件夹
        var path = await FilePicker.platform.saveFile(
          allowedExtensions: ["jpg"],
          type: FileType.image,
          fileName: "${DateTime.now().millisecondsSinceEpoch}.jpg",
        );
        if (path == null) {
          SmartDialog.showToast("已取消保存".t);
          SmartDialog.dismiss(status: SmartStatus.loading);
          return;
        }
        var file = File(path);
        await file.writeAsBytes(imageData);
        SmartDialog.showToast("截图已保存到 {path}".tf({"path": file.path}));
      }
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("截图失败".t);
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 开启小窗播放前弹幕状态
  bool danmakuStateBeforePIP = false;

  /// iOS 画中画会话（直播间控制器创建）
  IosPipSession? iosPip;

  Future enablePIP() async {
    if (Platform.isIOS) {
      await iosPip?.enter();
      return;
    }
    if (!Platform.isAndroid) {
      return;
    }
    if (await pip.isPipAvailable == false) {
      SmartDialog.showToast("这台设备不支持小窗播放".t);
      return;
    }
    danmakuStateBeforePIP = showDanmakuState.value;
    //关闭并清除弹幕
    if (AppSettingsController.instance.pipHideDanmu.value &&
        danmakuStateBeforePIP) {
      showDanmakuState.value = false;
    }
    clearDanmaku();
    //关闭控制器
    showControlsState.value = false;

    //监听事件
    var width = player.state.width ?? 0;
    var height = player.state.height ?? 0;
    Rational ratio = const Rational.landscape();
    if (height > width) {
      ratio = const Rational.vertical();
    } else {
      ratio = const Rational.landscape();
    }
    var status = await pip.enable(
      ImmediatePiP(
        aspectRatio: ratio,
      ),
    );
    // 小窗里换成小窗那一套弹幕大小和速度
    systemPipState.value = status == PiPStatus.enabled;

    _pipSubscription ??= pip.pipStatusStream.listen((event) {
      if (event == PiPStatus.enabled) {
        systemPipState.value = true;
      }
      if (event == PiPStatus.disabled) {
        systemPipState.value = false;
        clearDanmaku();
        showDanmakuState.value = danmakuStateBeforePIP;
      }
      Log.w(event.toString());
    });
  }
}
mixin PlayerGestureControlMixin
    on PlayerStateMixin, PlayerMixin, PlayerSystemMixin {
  /// 单击显示/隐藏控制器
  void onTap() {
    if (showControlsState.value) {
      hideControls();
    } else {
      showControls();
    }
  }

  //桌面端操控
  void onEnter(PointerEnterEvent event) {
    if (!showControlsState.value) {
      showControls();
    }
  }

  void onExit(PointerExitEvent event) {
    if (showControlsState.value) {
      hideControls();
    }
  }

  void onHover(PointerHoverEvent event, BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final targetPosition = screenHeight * 0.25; // 计算屏幕顶部25%的位置
    if (event.position.dy <= targetPosition ||
        event.position.dy >= targetPosition * 3) {
      if (!showControlsState.value) {
        showControls();
      }
    }
  }

  /// 双击全屏/退出全屏
  void onDoubleTap(TapDownDetails details) {
    if (lockControlsState.value) {
      return;
    }
    if (fullScreenState.value) {
      exitFull();
    } else {
      enterFullScreen();
    }
  }

  bool verticalDragging = false;
  bool leftVerticalDrag = false;
  var _currentVolume = 0.0;
  var _currentBrightness = 1.0;
  var verStartPosition = 0.0;
  var _dragRange = 1.0;
  var _brightnessReady = false;

  DelayedThrottle? throttle;

  /// 竖向手势开始。手机按整个屏幕算；电脑上画面只占窗口的一部分，按 [area] 算，
  /// 只有手指和触控笔能触发
  void onVerticalDragStart(DragStartDetails details, {Size? area}) async {
    if (lockControlsState.value && fullScreenState.value) {
      return;
    }
    if (!PlayerDragAdjust.accepts(details.kind)) {
      return;
    }

    final mobile = Platform.isAndroid || Platform.isIOS;
    final position = mobile ? details.globalPosition : details.localPosition;
    final height = mobile ? Get.height : (area?.height ?? Get.height);
    final width = mobile ? Get.width : (area?.width ?? Get.width);
    final dy = position.dy;
    // 开始位置必须是中间2/4的位置
    if (dy < height * 0.25 || dy > height * 0.75) {
      return;
    }

    verStartPosition = dy;
    _dragRange = height * 0.5;
    leftVerticalDrag = position.dx < width / 2;

    throttle = DelayedThrottle(200);

    verticalDragging = true;
    showGestureTip.value = true;
    if (PlayerDragAdjust.usesSystemVolume) {
      _currentVolume = await VolumeController.instance.getVolume();
    } else {
      _currentVolume = AppSettingsController.instance.playerVolume.value / 100;
    }
    if (leftVerticalDrag) {
      _brightnessReady = false;
      var brightness = await PlayerDragAdjust.readBrightness();
      if (brightness == null) {
        gestureTipText.value = "这台设备不能调亮度".t;
        return;
      }
      _currentBrightness = brightness;
      _brightnessReady = true;
    }
  }

  /// 竖向手势更新
  void onVerticalDragUpdate(DragUpdateDetails e) async {
    if (lockControlsState.value && fullScreenState.value) {
      return;
    }
    if (verticalDragging == false) return;
    final mobile = Platform.isAndroid || Platform.isIOS;
    final dy = mobile ? e.globalPosition.dy : e.localPosition.dy;
    //String text = "";
    //double value = 0.0;

    Log.logPrint("$verStartPosition/$dy");

    if (leftVerticalDrag) {
      setGestureBrightness(dy);
    } else {
      setGestureVolume(dy);
    }
  }

  int lastVolume = -1; // it's ok to be -1

  void setGestureVolume(double dy) {
    double value = 0.0;
    double seek;
    if (dy > verStartPosition) {
      value = ((dy - verStartPosition) / _dragRange);

      seek = _currentVolume - value;
      if (seek < 0) {
        seek = 0;
      }
    } else {
      value = ((dy - verStartPosition) / _dragRange);
      seek = value.abs() + _currentVolume;
      if (seek > 1) {
        seek = 1;
      }
    }
    int volume = _convertVolume((seek * 100).round());
    if (volume == lastVolume) {
      return;
    }
    lastVolume = volume;
    // update UI outside throttle to make it more fluent
    gestureTipText.value = "音量 {volume}%".tf({"volume": volume});
    throttle?.invoke(() async => await _realSetVolume(volume));
  }

  // 0 to 100, 5 step each
  int _convertVolume(int volume) {
    return (volume / 5).round() * 5;
  }

  Future _realSetVolume(int volume) async {
    Log.logPrint(volume);
    if (PlayerDragAdjust.usesSystemVolume) {
      VolumeController.instance.setVolume(volume / 100);
    } else {
      AppSettingsController.instance.setPlayerVolume(volume.toDouble());
      player.setVolume(volume.toDouble());
      if (this is PlayerController) {
        (this as PlayerController).muted.value = false;
      }
    }
  }

  void setGestureBrightness(double dy) {
    if (!_brightnessReady) {
      return;
    }
    double value = 0.0;
    if (dy > verStartPosition) {
      value = ((dy - verStartPosition) / _dragRange);

      var seek = _currentBrightness - value;
      if (seek < 0) {
        seek = 0;
      }
      PlayerDragAdjust.applyBrightness(seek, throttle);

      gestureTipText.value = "亮度 {p}%".tf({"p": (seek * 100).toInt()});
      Log.logPrint(value);
    } else {
      value = ((dy - verStartPosition) / _dragRange);
      var seek = value.abs() + _currentBrightness;
      if (seek > 1) {
        seek = 1;
      }

      PlayerDragAdjust.applyBrightness(seek, throttle);
      gestureTipText.value = "亮度 {p}%".tf({"p": (seek * 100).toInt()});
      Log.logPrint(value);
    }
  }

  /// 竖向手势完成
  void onVerticalDragEnd(DragEndDetails details) async {
    if (lockControlsState.value && fullScreenState.value) {
      return;
    }
    throttle = null;
    verticalDragging = false;
    leftVerticalDrag = false;
    showGestureTip.value = false;
  }
}

class PlayerController extends BaseController
    with
        PlayerMixin,
        PlayerStateMixin,
        PlayerDanmakuMixin,
        PlayerSystemMixin,
        PlayerGestureControlMixin {
  /// 电脑上的静音（多开窗口默认静音）：不改记住的音量，取消时回到原来的音量
  final RxBool muted = false.obs;

  void setMuted(bool value) {
    muted.value = value;
    player.setVolume(
        value ? 0 : AppSettingsController.instance.playerVolume.value);
  }

  /// 现在用的声音输出设备（mpv 的 audio-device 名字，auto 是默认设备）
  final RxString audioDevice = "auto".obs;

  /// 能选的声音输出设备（播放器刚建好时可能还没列出来，等一会儿）
  Future<List<AudioDevice>> audioDevices(
      {Duration wait = const Duration(seconds: 3)}) async {
    var list = player.state.audioDevices;
    if (list.isNotEmpty) {
      return list;
    }
    try {
      return await player.stream.audioDevices
          .firstWhere((e) => e.isNotEmpty)
          .timeout(wait);
    } catch (_) {
      return player.state.audioDevices;
    }
  }

  Future<void> setAudioDevice(AudioDevice device) async {
    try {
      await player.setAudioDevice(device);
      audioDevice.value = device.name;
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 用记下的声音输出设备：还在就用它；不在了用默认设备，返回 false（要提示一下）。
  /// 设备列表一直读不到时不动
  Future<bool> restoreAudioDevice(String? saved) async {
    var list = await audioDevices();
    if (list.isEmpty) {
      return true;
    }
    var pick = pickAudioDevice(saved, [for (var e in list) e.name]);
    var device = list.firstWhere((e) => e.name == pick.device,
        orElse: () => AudioDevice.auto());
    await setAudioDevice(device);
    return !pick.missing;
  }

  @override
  void onInit() {
    initSystem();
    initStream();
    // 进了全屏才认出视频是竖的（或横的）：再转一次
    _orientationWorker = ever<bool>(isVertical, (_) => orienter.videoChanged());
    //设置音量
    player.setVolume(AppSettingsController.instance.playerVolume.value);
    super.onInit();
  }

  StreamSubscription<String>? _errorSubscription;
  StreamSubscription? _completedSubscription;
  StreamSubscription? _widthSubscription;
  StreamSubscription? _heightSubscription;
  StreamSubscription? _logSubscription;
  StreamSubscription? _playingSubscription;
  Worker? _orientationWorker;

  void initStream() {
    _errorSubscription = player.stream.error.listen((event) {
      Log.d("播放器错误：$event");
      // 跳过无音频输出的错误
      // Could not open/initialize audio device -> no sound.
      if (event.contains('no sound.')) {
        return;
      }
      //SmartDialog.showToast(event);
      mediaError(event);
    });

    _playingSubscription = player.stream.playing.listen((event) {
      if (event) {
        WakelockPlus.enable();
        Log.d("Playing");
      }
    });

    _completedSubscription = player.stream.completed.listen((event) {
      if (event) {
        mediaEnd();
      }
    });
    _logSubscription = player.stream.log.listen((event) {
      Log.d("播放器日志：$event");
      onPlayerLog(event);
    });
    _widthSubscription = player.stream.width.listen((event) {
      Log.d(
          'width:$event  W:${(player.state.width)}  H:${(player.state.height)}');
      isVertical.value =
          (player.state.height ?? 9) > (player.state.width ?? 16);
    });
    _heightSubscription = player.stream.height.listen((event) {
      Log.d(
          'height:$event  W:${(player.state.width)}  H:${(player.state.height)}');
      isVertical.value =
          (player.state.height ?? 9) > (player.state.width ?? 16);
    });
  }

  void disposeStream() {
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _widthSubscription?.cancel();
    _heightSubscription?.cancel();
    _logSubscription?.cancel();
    _pipSubscription?.cancel();
    _playingSubscription?.cancel();
    _orientationWorker?.dispose();
    orienter.dispose();
  }

  void mediaEnd() {
    WakelockPlus.disable();
  }

  /// mpv 的每一行日志（直播间用来检测花屏）
  void onPlayerLog(PlayerLog event) {}

  void mediaError(String error) {
    WakelockPlus.disable();
  }

  void showDebugInfo() {
    Utils.showBottomSheet(
      title: "播放信息".t,
      child: ListView(
        children: [
          ListTile(
            title: const Text("Resolution"),
            subtitle: Text('${player.state.width}x${player.state.height}'),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text:
                      "Resolution\n${player.state.width}x${player.state.height}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("VideoParams"),
            subtitle: Text(player.state.videoParams.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "VideoParams\n${player.state.videoParams}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("AudioParams"),
            subtitle: Text(player.state.audioParams.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "AudioParams\n${player.state.audioParams}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("Media"),
            subtitle: Text(player.state.playlist.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "Media\n${player.state.playlist}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("AudioTrack"),
            subtitle: Text(player.state.track.audio.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "AudioTrack\n${player.state.track.audio}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("VideoTrack"),
            subtitle: Text(player.state.track.video.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "VideoTrack\n${player.state.track.audio}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("AudioBitrate"),
            subtitle: Text(player.state.audioBitrate.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "AudioBitrate\n${player.state.audioBitrate}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("Volume"),
            subtitle: Text(player.state.volume.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "Volume\n${player.state.volume}",
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  void onClose() async {
    Log.w("播放器关闭");
    if (lockControlsState.value) {
      PlayerLock.locked.value = false;
    }
    if (smallWindowState.value) {
      exitSmallWindow();
    } else if (windowFullState.value) {
      // 窗口全屏时关掉直播间：换回系统标题栏
      exitFull();
    }
    disposeStream();
    disposeDanmakuController();
    await resetSystem();
    ActivePlayers.remove(player);
    await player.dispose();
    super.onClose();
  }
}
