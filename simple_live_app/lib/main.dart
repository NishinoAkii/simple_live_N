import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:logger/logger.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/desktop_page_transition.dart';
import 'package:simple_live_app/app/desktop_shortcuts.dart';
import 'package:simple_live_app/app/gpu_preference.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/multi_window_widgets.dart';
import 'package:simple_live_app/app/multi_window/window_layout.dart';
import 'package:simple_live_app/app/player_lock.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/utils/listen_fourth_button.dart';
import 'package:simple_live_app/app/window_memory.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/other/debug_log_page.dart';
import 'package:simple_live_app/routes/app_pages.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/account_follow_service.dart';
import 'package:simple_live_app/services/app_update/app_update_service.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/live_notify_service.dart';
import 'package:simple_live_app/services/kick_account_service.dart';
import 'package:simple_live_app/services/live_source_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/native_http.dart';
import 'package:simple_live_app/services/obs_bridge/obs_bridge_service.dart';
import 'package:simple_live_app/services/shared_profile.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';
import 'package:simple_live_app/services/sync_service.dart';
import 'package:simple_live_app/services/webdav_sync_service.dart';
import 'package:simple_live_app/services/youtube_account_service.dart';
import 'package:simple_live_app/widgets/status/app_loadding_widget.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:window_manager/window_manager.dart';

import 'package:path/path.dart' as p;
import 'package:dynamic_color/dynamic_color.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // 图片缓存默认最多 1000 张、100 MB；封面和头像都按显示大小解码了，留 300 张、64 MB 足够，
  // 长时间挂着少占内存
  PaintingBinding.instance.imageCache
    ..maximumSize = 300
    ..maximumSizeBytes = 64 << 20;
  // 多开的副窗口：带着主窗口给的启动参数，读一份数据快照，不碰主窗口的数据文件
  await MultiWindow.init(args);
  if (!MultiWindow.isSecondary) {
    await moveOutOfSharedProfile();
    await migrateData();
    await waitForPreviousInstance();
  }
  await initWindow();
  MediaKit.ensureInitialized();
  await Hive.initFlutter(
    (!Platform.isAndroid && !Platform.isIOS)
        ? MultiWindow.launch?.dataDir ??
            (await getApplicationSupportDirectory()).path
        : null,
  );
  //初始化服务
  await initServices();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  //设置状态栏为透明
  SystemUiOverlayStyle systemUiOverlayStyle = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
  );
  SystemChrome.setSystemUIOverlayStyle(systemUiOverlayStyle);
  runApp(const MyApp());
  MultiWindow.startSecondary();
  // 主窗口：上次开着多开窗口时，问要不要都打开（按设置）
  scheduleStartupRestore();
  // 主窗口启动约 10 秒后检查新版本（一天最多一次）
  AppUpdateService.instance.scheduleStartupCheck();
}

/// Windows：第一次运行时搬出和官方版共用的数据文件夹，见 [SharedProfile]
Future moveOutOfSharedProfile() async {
  if (!Platform.isWindows) {
    return;
  }
  var own = await getApplicationSupportDirectory();
  var shared = SharedProfile.pendingMove(own);
  if (shared == null) {
    return;
  }
  // 官方版或旧版开着时搬不动，等它退出
  await _waitForDatabaseLock(shared);
  try {
    await SharedProfile.move(shared, own);
  } catch (e, stackTrace) {
    Log.e("搬数据文件夹失败：$e", stackTrace);
  }
}

/// 将Hive数据迁移到Application Support
Future migrateData() async {
  if (Platform.isAndroid || Platform.isIOS) {
    return;
  }
  var hiveFileList = [
    "followuser",
    //旧版本写错成hostiry了
    "hostiry",
    "followusertag",
    "localstorage",
    "danmushield",
  ];
  try {
    var newDir = await getApplicationSupportDirectory();
    var hiveFile = File(p.join(newDir.path, "followuser.hive"));
    if (await hiveFile.exists()) {
      return;
    }

    var oldDir = await getApplicationDocumentsDirectory();
    for (var element in hiveFileList) {
      var oldFile = File(p.join(oldDir.path, "$element.hive"));
      if (await oldFile.exists()) {
        var fileName = "$element.hive";
        if (element == "hostiry") {
          fileName = "history.hive";
        }
        await oldFile.copy(p.join(newDir.path, fileName));
        await oldFile.delete();
      }
      var lockFile = File(p.join(oldDir.path, "$element.lock"));
      if (await lockFile.exists()) {
        await lockFile.delete();
      }
    }
  } catch (e) {
    Log.logPrint(e);
  }
}

/// 关窗后进程还会留一会儿把存档传完。这时马上重新打开，数据库的锁还在它手里，
/// 打开数据库会失败，窗口就一直白屏。所以显示窗口之前先等它退出；
/// 一直等不到，说明真的还开着一个，这个就不开了。
Future waitForPreviousInstance() async {
  if (Platform.isAndroid || Platform.isIOS) {
    return;
  }
  await _waitForDatabaseLock(await getApplicationSupportDirectory());
}

Future _waitForDatabaseLock(Directory dir) async {
  // Hive 的锁文件：盒子名小写加 .lock
  var lockFile = File(p.join(dir.path, "localstorage.lock"));
  for (var i = 0; i < 50; i++) {
    RandomAccessFile? file;
    try {
      file = await lockFile.open(mode: FileMode.write);
      await file.lock();
      await file.unlock();
      return;
    } on FileSystemException {
      await Future.delayed(const Duration(milliseconds: 300));
    } finally {
      await file?.close();
    }
  }
  await ServicesBinding.instance.exitApplication(AppExitType.required);
  await Future.delayed(const Duration(seconds: 3));
  exit(0);
}

Future initWindow() async {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return;
  }
  await windowManager.ensureInitialized();
  if (MultiWindow.isSecondary) {
    // 多开的副窗口：放到主窗口排好的位置
    windowManager.waitUntilReadyToShow(
      WindowOptions(
        minimumSize: WindowLayout.minSize,
        title: MultiWindow.windowTitle,
      ),
      () async {
        await MultiWindow.placeSelf();
        await windowManager.show();
        await windowManager.focus();
        await MultiWindow.fixPlacement();
        // 之后挪动、改大小时告诉主窗口（“打开上次的窗口”放回这里）
        MultiWindow.watchPlacement();
      },
    );
    return;
  }
  WindowOptions windowOptions = const WindowOptions(
    minimumSize: Size(280, 280),
    title: "Simple Live N",
  );
  // 放到上次的位置（或者正中间）、显示窗口要等读完设置：见 WindowMemory.restoreOnStart
  WindowMemory.instance.ready =
      windowManager.waitUntilReadyToShow(windowOptions);
}

Future initServices() async {
  Hive.registerAdapter(FollowUserAdapter());
  Hive.registerAdapter(HistoryAdapter());
  Hive.registerAdapter(FollowUserTagAdapter());

  //包信息
  Utils.packageInfo = await PackageInfo.fromPlatform();
  //本地存储
  Log.d("Init LocalStorage Service");
  await Get.put(LocalStorageService()).init();
  // 电脑端：窗口放回上次的位置再显示，快捷键，显卡偏好
  await WindowMemory.instance.restoreOnStart();
  DesktopShortcuts.instance.init();
  await GpuPreferenceSetting.instance.init();
  // 界面语言：要在别的服务生成文字之前定好
  await I18n.init(
    LocalStorageService.instance.getValue(
      LocalStorageService.kAppLanguage,
      I18n.followSystem,
    ),
    Directory(
      "${(await getApplicationSupportDirectory()).path}"
      "${Platform.pathSeparator}lang",
    ),
  );
  await Get.put(DBService()).init();
  // 屏蔽的人和备注
  await Get.put(ChatUsersService()).init();
  //初始化设置控制器
  Get.put(AppSettingsController());

  Get.put(BiliBiliAccountService());

  Get.put(DouyinAccountService());

  Get.put(DouyuAccountService());

  NativeHttp.install();
  Get.put(TwitchAccountService());

  Get.put(KickAccountService());

  Get.put(YouTubeAccountService());

  // 直播源（.live.js）：加载失败时当作没有直播源，不影响启动
  try {
    await Get.put(LiveSourceService()).init();
  } catch (e, stackTrace) {
    Log.e("直播源初始化失败：$e", stackTrace);
  }

  Get.put(SyncService());

  Get.put(FollowService());

  // 开播提醒：订阅的直播间开播时发通知
  Get.put(LiveNotifyService());

  // 账号关注：导入、手动同步、同步到账号的队列（本机的 Hive box）
  try {
    await Get.put(AccountFollowService()).init();
  } catch (e, stackTrace) {
    Get.delete<AccountFollowService>();
    Log.e("账号关注初始化失败：$e", stackTrace);
  }

  // 录屏接口（OBS 等），默认关闭
  Get.put(ObsBridgeService());

  // WebDAV 自动同步，默认关闭
  Get.put(WebDavSyncService());

  // 应用内更新（检查、下载）
  Get.put(AppUpdateService());

  initCoreLog();
  logD3DGuard();
}

/// Windows：启动时记一行 Direct3D 多线程保护有没有开启。它是在 windows/runner/d3d_guard.cpp
/// 里给 Flutter 的显卡设备开的，没开的话画面可能卡住或闪退；升级 Flutter 以后要看这一行
void logD3DGuard() {
  if (!Platform.isWindows) {
    return;
  }
  var state = Platform.environment["SIMPLE_LIVE_D3D_GUARD"] ?? "没有记录";
  if (RegExp(r"protected=[1-9]").hasMatch(state)) {
    Log.i("Direct3D 多线程保护已开启（$state）");
  } else {
    Log.w("Direct3D 多线程保护没有开启（$state）");
  }
}

void initCoreLog() {
  //日志信息
  CoreLog.enableLog =
      !kReleaseMode || AppSettingsController.instance.logEnable.value;
  CoreLog.requestLogType = RequestLogType.short;
  CoreLog.onPrintLog = (level, msg) {
    switch (level) {
      case Level.debug:
        Log.d(msg);
        break;
      case Level.error:
        Log.e(msg, StackTrace.current);
        break;
      case Level.info:
        Log.i(msg);
        break;
      case Level.warning:
        Log.w(msg);
        break;
      default:
        Log.logPrint(msg);
    }
  };
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    bool isDynamicColor = AppSettingsController.instance.isDynamic.value;
    Color styleColor = Color(AppSettingsController.instance.styleColor.value);
    return DynamicColorBuilder(
        builder: ((ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
      ColorScheme? lightColorScheme;
      ColorScheme? darkColorScheme;
      if (lightDynamic != null && darkDynamic != null && isDynamicColor) {
        lightColorScheme = lightDynamic;
        darkColorScheme = darkDynamic;
      } else {
        lightColorScheme = ColorScheme.fromSeed(
          seedColor: styleColor,
          brightness: Brightness.light,
        );
        darkColorScheme = ColorScheme.fromSeed(
            seedColor: styleColor, brightness: Brightness.dark);
      }
      return GetMaterialApp(
        title: "Simple Live N",
        theme: AppStyle.lightTheme.copyWith(colorScheme: lightColorScheme),
        darkTheme: AppStyle.darkTheme.copyWith(colorScheme: darkColorScheme),
        themeMode:
            ThemeMode.values[Get.find<AppSettingsController>().themeMode.value],
        initialRoute: RoutePath.kIndex,
        // 多开的副窗口里设置页只能看
        getPages: MultiWindowRoutes.guard(AppPages.routes),
        //国际化
        locale: I18n.flutterLocale(I18n.current.value),
        fallbackLocale: const Locale("en"),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: I18n.flutterLocales,
        logWriterCallback: (text, {bool? isError}) {
          Log.addDebugLog(text, (isError ?? false) ? Colors.red : Colors.grey);
          Log.writeLog(text, (isError ?? false) ? Level.error : Level.info);
        },
        // 升级后Android页面过渡动画似乎有BUG
        defaultTransition: Platform.isAndroid ? Transition.cupertino : null,
        // 桌面端默认的缩放转场会给视频画面做快照，在 Windows 上导致闪退
        customTransition: Platform.isWindows || Platform.isLinux
            ? DesktopPageTransition()
            : null,
        //debugShowCheckedModeBanner: false,
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(
          loadingBuilder: ((msg) => const AppLoaddingWidget()),
          //字体大小不跟随系统变化
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.0)),
            child: Stack(
              children: [
                //侧键返回
                RawGestureDetector(
                  excludeFromSemantics: true,
                  gestures: <Type, GestureRecognizerFactory>{
                    FourthButtonTapGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                            FourthButtonTapGestureRecognizer>(
                      () => FourthButtonTapGestureRecognizer(),
                      (FourthButtonTapGestureRecognizer instance) {
                        instance.onTapDown = (TapDownDetails details) async {
                          // 播放器锁定时不退出
                          if (PlayerLock.locked.value) {
                            PlayerLock.showTip();
                            return;
                          }
                          //如果处于全屏状态，退出全屏
                          if (!Platform.isAndroid && !Platform.isIOS) {
                            if (await windowManager.isFullScreen()) {
                              await windowManager.setFullScreen(false);
                              return;
                            }
                          }
                          Get.back();
                        };
                      },
                    ),
                  },
                  child: KeyboardListener(
                    focusNode: FocusNode(),
                    onKeyEvent: (KeyEvent event) async {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.escape) {
                        // 播放器锁定时不退出全屏
                        if (PlayerLock.locked.value) {
                          PlayerLock.showTip();
                          return;
                        }
                        // ESC退出全屏
                        // 如果处于全屏状态，退出全屏
                        if (!Platform.isAndroid && !Platform.isIOS) {
                          if (await windowManager.isFullScreen()) {
                            await windowManager.setFullScreen(false);
                            return;
                          }
                        }
                      }
                    },
                    // 多开的副窗口：主窗口关了时顶上有提示
                    child: MultiWindowFrame(child: child!),
                  ),
                ),

                //查看DEBUG日志按钮
                //只在Debug、Profile模式显示
                Visibility(
                  visible: !kReleaseMode,
                  child: Positioned(
                    right: 12,
                    bottom: 100 + context.mediaQueryViewPadding.bottom,
                    child: Opacity(
                      opacity: 0.4,
                      child: ElevatedButton(
                        child: const Text("DEBUG LOG"),
                        onPressed: () {
                          Get.bottomSheet(
                            const DebugLogPage(),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }));
  }
}
