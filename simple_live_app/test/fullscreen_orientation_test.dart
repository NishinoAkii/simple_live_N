import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/play_prefs.dart';
import 'package:simple_live_app/modules/live_room/player/fullscreen_orientation.dart';

/// 全屏方向：选项、手机还是平板、视频横竖 → 转成什么方向
void main() {
  const smart = FullscreenOrientationMode.smart;
  const landscape = FullscreenOrientationMode.landscape;
  const system = FullscreenOrientationMode.system;

  test("决定表", () {
    OrientationRequest d(FullscreenOrientationMode mode, bool tablet, bool vertical) =>
        FullscreenOrientation.decide(
            mode: mode, tablet: tablet, verticalVideo: vertical);

    // 智能：手机转横屏，平板不强制
    expect(d(smart, false, false), OrientationRequest.landscape);
    expect(d(smart, true, false), OrientationRequest.free);
    // 强制横屏：手机、平板都转
    expect(d(landscape, false, false), OrientationRequest.landscape);
    expect(d(landscape, true, false), OrientationRequest.landscape);
    // 竖屏的直播：手机转回竖屏（修进了全屏才认出是竖屏时不转回来），平板不强制
    for (var mode in [smart, landscape]) {
      expect(d(mode, false, true), OrientationRequest.portrait);
      expect(d(mode, true, true), OrientationRequest.free);
    }
    // 跟随系统：都不改
    for (var tablet in [false, true]) {
      for (var vertical in [false, true]) {
        expect(d(system, tablet, vertical), OrientationRequest.free);
      }
    }
  });

  test("短边 600 以上算平板，横着竖着一样", () {
    expect(FullscreenOrientation.isTabletSize(const Size(360, 800)), isFalse);
    expect(FullscreenOrientation.isTabletSize(const Size(800, 360)), isFalse);
    expect(FullscreenOrientation.isTabletSize(const Size(599, 960)), isFalse);
    expect(FullscreenOrientation.isTabletSize(const Size(600, 960)), isTrue);
    expect(FullscreenOrientation.isTabletSize(const Size(1280, 800)), isTrue);
  });

  test("存的值不对时按智能", () {
    expect(FullscreenOrientationMode.fromValue(0), smart);
    expect(FullscreenOrientationMode.fromValue(1), landscape);
    expect(FullscreenOrientationMode.fromValue(2), system);
    expect(FullscreenOrientationMode.fromValue(7), smart);
    expect(FullscreenOrientationMode.fromValue(-1), smart);
  });

  group("全屏期间视频横竖变了", () {
    setUp(() => PlayPrefs.instance = PlayPrefs.forTest());
    tearDown(() => PlayPrefs.instance = null);

    /// 整块屏幕是一台手机（1080x2340，3 倍）
    void phone(WidgetTester tester) {
      tester.view.display.size = const Size(1080, 2340);
      tester.view.display.devicePixelRatio = 3;
      addTearDown(tester.view.display.reset);
    }

    testWidgets("平板（1600x2560，2 倍）：竖屏的直播不强制转", (tester) async {
      tester.view.display.size = const Size(1600, 2560);
      tester.view.display.devicePixelRatio = 2;
      addTearDown(tester.view.display.reset);
      expect(FullscreenOrientation.isTabletDevice, isTrue);
      var vertical = true;
      var orienter = FullscreenOrienter(
        vertical: () => vertical,
        active: () => true,
      );
      await orienter.apply();
      expect(orienter.applied, OrientationRequest.free);
      // 电脑上跑时按 iOS 那一套（相当于强制横屏）：横屏的直播转横屏
      vertical = false;
      orienter.videoChanged();
      await tester.pump(FullscreenOrienter.settle);
      expect(orienter.applied, OrientationRequest.landscape);
    });

    testWidgets("进了全屏才认出是竖屏：稍等一下转回竖屏；宽高清空时不动", (tester) async {
      phone(tester);
      bool? vertical;
      var active = true;
      var orienter = FullscreenOrienter(
        vertical: () => vertical,
        guess: () => false,
        active: () => active,
      );
      // 进全屏时还没读到宽高：按猜的（横屏）
      await orienter.apply();
      // 测试在电脑上跑：currentMode 是 iOS 那一套（横屏的直播都转横屏），这里不算平板
      expect(orienter.applied, OrientationRequest.landscape);

      // 换流：宽高先清空
      orienter.videoChanged();
      await tester.pump(FullscreenOrienter.settle);
      expect(orienter.applied, OrientationRequest.landscape);

      // 读到竖的宽高：等一会儿再转（中间又变了就按最后一次）
      vertical = false;
      orienter.videoChanged();
      await tester.pump(const Duration(milliseconds: 200));
      vertical = true;
      orienter.videoChanged();
      await tester.pump(const Duration(milliseconds: 200));
      expect(orienter.applied, OrientationRequest.landscape);
      await tester.pump(FullscreenOrienter.settle);
      expect(orienter.applied, OrientationRequest.portrait);

      // 退出全屏以后再变：不管
      active = false;
      orienter.reset();
      vertical = false;
      orienter.videoChanged();
      await tester.pump(FullscreenOrienter.settle * 2);
      expect(orienter.applied, isNull);
    });

    testWidgets("抖音默认竖屏：进全屏时还没读到宽高就按竖屏", (tester) async {
      phone(tester);
      var orienter = FullscreenOrienter(
        vertical: () => null,
        guess: () => true,
        active: () => true,
      );
      await orienter.apply();
      expect(orienter.applied, OrientationRequest.portrait);
      orienter.dispose();
    });
  });
}
