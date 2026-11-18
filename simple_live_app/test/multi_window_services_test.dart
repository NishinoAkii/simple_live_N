import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/multi_window_widgets.dart';
import 'package:simple_live_app/app/multi_window/window_args.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/routes/app_pages.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/live_notify_service.dart';

// 多开：副窗口不启动的后台功能、只能看的页面

class _TestSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void becomeSecondary() => MultiWindow.launch = SecondaryLaunch(
        port: 1,
        token: WindowToken.generate(),
        dataDir: "/tmp/multi_window/w1-1",
        slot: 1,
        siteId: "douyu",
        roomId: "1",
      );

  tearDown(() {
    MultiWindow.launch = null;
    Get.reset();
  });

  test("副窗口不启动的后台功能", () {
    expect(MultiWindow.secondarySkips, {
      BackgroundTask.webdavAutoSync,
      BackgroundTask.lanSync,
      BackgroundTask.obsBridge,
      BackgroundTask.liveNotify,
      BackgroundTask.accountFollowQueue,
      BackgroundTask.liveSourceUpdateCheck,
      BackgroundTask.appUpdateCheck,
    });
    // 主窗口什么都不跳过
    for (var task in BackgroundTask.values) {
      expect(MultiWindow.skips(task), isFalse, reason: task.name);
    }
    becomeSecondary();
    for (var task in BackgroundTask.values) {
      expect(MultiWindow.skips(task), isTrue, reason: task.name);
    }
    // 副窗口不能再开新窗口
    expect(MultiWindow.canOpen, isFalse);
  });

  test("副窗口里不检查开播、不发通知；铃铛照常能点", () async {
    becomeSecondary();
    var settings = Get.put<AppSettingsController>(_TestSettings());
    settings.liveNotifyEnable.value = true;
    var sent = <LiveNotifyMessage>[];
    var notify = LiveNotifyService()..sendOverride = (m) async => sent.add(m);
    Get.put(notify);
    var item = FollowUser(
      id: "douyu_1",
      roomId: "1",
      siteId: "douyu",
      userName: "主播",
      face: "",
      addTime: DateTime(2026),
      notify: true,
    );
    notify.observe(item, false, null);
    notify.observe(item, true, null);
    await notify.send(LiveNotifyMessage.of(item, null));
    expect(sent, isEmpty);
  });

  test("副窗口里设置、同步页只能看，别的页照常", () {
    for (var name in [
      RoutePath.kSettingsPlay,
      RoutePath.kSettingsDanmuShield,
      RoutePath.kAppstyleSetting,
      RoutePath.kSettingsAccount,
      RoutePath.kBiliBiliQRLogin,
      RoutePath.kSync,
      RoutePath.kLocalSync,
      RoutePath.kRemoteSyncWebDav,
    ]) {
      expect(MultiWindowRoutes.isReadOnly(name), isTrue, reason: name);
    }
    for (var name in [
      RoutePath.kIndex,
      RoutePath.kLiveRoomDetail,
      RoutePath.kHistory,
      RoutePath.kFollowUser,
      RoutePath.kSearch,
      "/settingsx",
    ]) {
      expect(MultiWindowRoutes.isReadOnly(name), isFalse, reason: name);
    }
    // 主窗口原样
    expect(identical(MultiWindowRoutes.guard(AppPages.routes), AppPages.routes),
        isTrue);
    becomeSecondary();
    var guarded = MultiWindowRoutes.guard(AppPages.routes);
    expect(guarded.map((e) => e.name), AppPages.routes.map((e) => e.name));
    var play = guarded.firstWhere((e) => e.name == RoutePath.kSettingsPlay);
    expect(play.page(), isA<ReadOnlySettings>());
    var room = guarded.firstWhere((e) => e.name == RoutePath.kLiveRoomDetail);
    expect(room.page(), isNot(isA<ReadOnlySettings>()));
    expect(room.page(), isA<Widget>());
  });
}
