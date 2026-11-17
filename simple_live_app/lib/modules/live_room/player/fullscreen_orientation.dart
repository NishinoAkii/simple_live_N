import 'dart:async';
import 'dart:io';

import 'package:auto_orientation_v2/auto_orientation_v2.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/play_prefs.dart';

/// 设置里的“全屏方向”（安卓）
enum FullscreenOrientationMode {
  /// 智能（默认）：手机转横屏，平板不强制
  smart,

  /// 强制横屏：手机、平板都转横屏
  landscape,

  /// 跟随系统：不改方向
  system;

  static FullscreenOrientationMode fromValue(int value) =>
      value >= 0 && value < values.length ? values[value] : smart;
}

/// 全屏时要的屏幕方向
enum OrientationRequest {
  landscape,
  portrait,

  /// 不限制，按系统（转屏锁、传感器）来
  free,
}

/// 全屏方向怎么定
class FullscreenOrientation {
  /// 短边不小于这个（逻辑像素）的算平板
  static const double tabletShortestSide = 600;

  static bool isTabletSize(Size logicalSize) =>
      logicalSize.shortestSide >= tabletShortestSide;

  /// 决定表：
  /// - 跟随系统：都不限制；
  /// - 竖屏的直播：手机转竖屏，平板不限制（任何选项都不把竖屏的画面横过来）；
  /// - 横屏的直播：智能时手机转横屏、平板不限制；强制横屏时都转横屏
  static OrientationRequest decide({
    required FullscreenOrientationMode mode,
    required bool tablet,
    required bool verticalVideo,
  }) {
    if (mode == FullscreenOrientationMode.system) {
      return OrientationRequest.free;
    }
    if (verticalVideo) {
      return tablet ? OrientationRequest.free : OrientationRequest.portrait;
    }
    if (mode == FullscreenOrientationMode.landscape || !tablet) {
      return OrientationRequest.landscape;
    }
    return OrientationRequest.free;
  }

  /// 现在用的选项：设置只在安卓上有；iOS 照原来的做法（横屏的直播都转横屏）
  static FullscreenOrientationMode get currentMode => Platform.isAndroid
      ? FullscreenOrientationMode.fromValue(
          PlayPrefs.instance.fullscreenOrientation.value)
      : FullscreenOrientationMode.landscape;

  /// 按整块屏幕算是不是平板（分屏、小窗里窗口变小也还是平板）
  static bool get isTabletDevice {
    try {
      var dispatcher = WidgetsBinding.instance.platformDispatcher;
      var view = dispatcher.implicitView ?? dispatcher.views.first;
      var display = view.display;
      if (display.size.isEmpty || display.devicePixelRatio <= 0) {
        return isTabletSize(view.physicalSize / view.devicePixelRatio);
      }
      return isTabletSize(display.size / display.devicePixelRatio);
    } catch (e) {
      Log.logPrint(e);
      return false;
    }
  }

  static bool? _beforeIOS16;

  /// iOS 16 以前 setPreferredOrientations 转不过去，要用 AutoOrientation
  static Future<bool> beforeIOS16() async {
    if (!Platform.isIOS) {
      return false;
    }
    if (_beforeIOS16 != null) {
      return _beforeIOS16!;
    }
    try {
      var info = await DeviceInfoPlugin().iosInfo;
      var major = int.tryParse(info.systemVersion.split('.').first) ?? 0;
      _beforeIOS16 = major < 16;
    } catch (e) {
      Log.logPrint(e);
      _beforeIOS16 = false;
    }
    return _beforeIOS16!;
  }

  /// 按要的方向设置。free 时所有方向都可以（和退出全屏时一样）
  static Future<void> apply(OrientationRequest request) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return;
    }
    var old = await beforeIOS16();
    switch (request) {
      case OrientationRequest.landscape:
        if (old) {
          AutoOrientation.landscapeAutoMode();
        } else {
          await SystemChrome.setPreferredOrientations([
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
        }
      case OrientationRequest.portrait:
        if (old) {
          AutoOrientation.portraitAutoMode();
        } else {
          await SystemChrome.setPreferredOrientations(
              [DeviceOrientation.portraitUp]);
        }
      case OrientationRequest.free:
        if (old) {
          AutoOrientation.fullAutoMode();
        } else {
          await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        }
    }
  }

  /// 视频是不是竖的；宽高还没读到时为 null
  static bool? verticalOf(Player player) {
    var width = player.state.width;
    var height = player.state.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return height > width;
  }
}

/// 手机、平板全屏时管屏幕方向：进全屏时按视频的横竖转，
/// 全屏期间视频的横竖变了（进了全屏才认出是竖屏的流）再转一次
class FullscreenOrienter {
  /// 视频是不是竖的；还没读到宽高时为 null
  final bool? Function() vertical;

  /// 进全屏时还没读到宽高，按这个猜（抖音默认竖屏）
  final bool Function() guess;

  /// 现在是不是在手机、平板的全屏里
  final bool Function() active;

  /// 换流时宽高会先清空再变：等这么久没再变才转
  static const settle = Duration(milliseconds: 600);

  FullscreenOrienter({
    required this.vertical,
    required this.active,
    bool Function()? guess,
  }) : guess = guess ?? (() => false);

  Timer? _timer;
  OrientationRequest? applied;

  /// 进全屏时调用
  Future<void> apply() async {
    _timer?.cancel();
    var request = FullscreenOrientation.decide(
      mode: FullscreenOrientation.currentMode,
      tablet: FullscreenOrientation.isTabletDevice,
      verticalVideo: vertical() ?? guess(),
    );
    applied = request;
    await FullscreenOrientation.apply(request);
  }

  /// 视频的横竖变了
  void videoChanged() {
    if (!active()) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(settle, () {
      var verticalVideo = vertical();
      // 宽高清空了（换流、停了）：先不动，等读到新的
      if (!active() || verticalVideo == null) {
        return;
      }
      var request = FullscreenOrientation.decide(
        mode: FullscreenOrientation.currentMode,
        tablet: FullscreenOrientation.isTabletDevice,
        verticalVideo: verticalVideo,
      );
      if (request != applied) {
        applied = request;
        FullscreenOrientation.apply(request);
      }
    });
  }

  /// 退出全屏时调用（方向由调用的地方恢复）
  void reset() {
    _timer?.cancel();
    applied = null;
  }

  void dispose() => reset();
}
