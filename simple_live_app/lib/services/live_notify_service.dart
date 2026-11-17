import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/windows_version.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_core/simple_live_core.dart' show LiveRoomDetail;
import 'package:window_manager/window_manager.dart';

/// 一条开播通知的内容
class LiveNotifyMessage {
  final String siteId;
  final String roomId;
  final String followId;

  /// 主播名
  final String name;

  /// 直播间标题
  final String title;

  /// 头像地址
  final String avatar;
  const LiveNotifyMessage({
    required this.siteId,
    required this.roomId,
    required this.followId,
    required this.name,
    required this.title,
    required this.avatar,
  });

  /// 房间信息读不到时用关注列表里存的名字和头像
  factory LiveNotifyMessage.of(FollowUser item, LiveRoomDetail? detail) {
    String pick(String? value, String fallback) =>
        value == null || value.isEmpty || value == "null" ? fallback : value;
    return LiveNotifyMessage(
      siteId: item.siteId,
      roomId: item.roomId,
      followId: item.id,
      name: pick(detail?.userName, item.userName),
      title: pick(detail?.title, ""),
      avatar: pick(detail?.userAvatar, item.face),
    );
  }

  String get payload => "$siteId\n$roomId";

  /// 同一个直播间用同一个编号：再开播时替换上一条
  int get id => followId.hashCode & 0x7fffffff;
}

/// 开播提醒：在关注列表里点铃铛订阅，订阅的直播间从没开播变成开播时发系统通知，
/// 带主播头像、名字和直播间标题，点一下进直播间。
///
/// 只在 App 运行时检查：桌面上一直有效；手机切到后台久了系统会暂停 App，
/// 那段时间收不到，回到前台时补查一次。
/// 每次查到的状态和上一次比：第一次查到（刚打开 App、刚订阅）只记下，不提醒
class LiveNotifyService extends GetxService with WidgetsBindingObserver {
  /// 能不能发系统通知：Windows 7 没有（要 WinRT），那里不初始化插件，也不去查开播
  static bool get supported => !WindowsVersion.isWindows7;

  static LiveNotifyService get instance => Get.find<LiveNotifyService>();
  static LiveNotifyService? get maybe =>
      Get.isRegistered<LiveNotifyService>() ? instance : null;

  /// 打开 App 后多久做第一次检查（记下订阅的直播间现在开没开播）
  static const firstCheckDelay = Duration(seconds: 20);

  /// 测试用：替换真正发通知的那一步
  @visibleForTesting
  Future<void> Function(LiveNotifyMessage message)? sendOverride;

  /// 测试用：不开定时器
  @visibleForTesting
  bool timers = true;

  final _plugin = FlutterLocalNotificationsPlugin();
  Future<bool>? _ready;

  /// 每个直播间上一次查到的状态：true 在播，false 没播
  final _known = <String, bool>{};
  Timer? _timer;
  Timer? _firstCheck;
  bool _checking = false;
  DateTime? _lastCheck;
  final _workers = <Worker>[];

  AppSettingsController get _settings => AppSettingsController.instance;

  bool get enabled => _settings.liveNotifyEnable.value;

  /// 多开的副窗口里不检查也不发通知（主窗口在做）；铃铛照常能点，开关交给主窗口保存
  bool get _passive => MultiWindow.skips(BackgroundTask.liveNotify);

  @override
  void onInit() {
    super.onInit();
    if (_passive) {
      return;
    }
    _workers.addAll([
      ever<bool>(_settings.liveNotifyEnable, (_) => _restartTimer()),
      ever<int>(_settings.liveNotifyInterval, (_) => _restartTimer()),
    ]);
    WidgetsBinding.instance.addObserver(this);
    _restartTimer();
    // 有订阅时启动就准备好：点了之前的通知打开 App 时要能进直播间。
    // Windows 不在启动时做（见 [windowsInitAfter]）；电脑上 App 没开着时本来也不会有新通知
    if (_hasSubscriptions() && !Platform.isWindows) {
      unawaited(_ensureReady().then((ok) {
        if (ok) unawaited(_openFromLaunch());
      }));
    }
  }

  bool _hasSubscriptions() {
    try {
      return DBService.instance.followBox.values.any((e) => e.notify);
    } catch (_) {
      return false;
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    _firstCheck?.cancel();
    _timer = null;
    _firstCheck = null;
    if (!enabled || !timers) {
      return;
    }
    var minutes = _settings.liveNotifyInterval.value.clamp(1, 120);
    _timer = Timer.periodic(
      Duration(minutes: minutes),
      (_) => unawaited(checkSubscribed()),
    );
    _firstCheck = Timer(firstCheckDelay, () => unawaited(checkSubscribed()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !enabled) {
      return;
    }
    // 手机在后台时定时器可能没跑：回来时离上次检查超过一个间隔就补查
    var last = _lastCheck;
    var interval = Duration(minutes: _settings.liveNotifyInterval.value);
    if (last == null || DateTime.now().difference(last) >= interval) {
      unawaited(checkSubscribed());
    }
  }

  /// 关注列表每查到一个直播间的状态都会调用这里
  void observe(FollowUser item, bool live, LiveRoomDetail? detail) {
    var was = _known[item.id];
    _known[item.id] = live;
    if (!live || was != false || !item.notify || !enabled || _passive) {
      return;
    }
    unawaited(send(LiveNotifyMessage.of(item, detail)));
  }

  /// 刚订阅或取消：已经知道的状态记下来，从下一次变成开播开始提醒
  void onSubscriptionChanged(FollowUser item) {
    if (!item.notify || _passive) {
      return;
    }
    var status = item.liveStatus.value;
    if (status != 0) {
      _known[item.id] = status == 2;
    }
    unawaited(_ensureReady());
  }

  /// 关注列表里点了铃铛
  Future<void> toggleSubscription(FollowUser item) async {
    var on = !item.notify;
    await FollowService.instance.setNotify(item, on);
    if (!on) {
      SmartDialog.showToast("不再提醒{name}开播".tf({"name": item.userName}));
      return;
    }
    if (!supported) {
      SmartDialog.showToast("Windows 7 不支持系统通知，开播时不会提醒".t);
    } else if (!_passive && !await ensurePermission()) {
      SmartDialog.showToast("已开启，但没有通知权限，请在系统设置中开启".t);
    } else if (!enabled) {
      SmartDialog.showToast("已开启，但“开播时发通知”已关闭，请在“我的 → 关注设置”中开启".t);
    } else {
      SmartDialog.showToast("{name}开播时会通知你".tf({"name": item.userName}));
    }
  }

  /// 只查订阅了的直播间（几个请求，看直播时也查）。整个关注列表正在刷新时不查
  Future<void> checkSubscribed() async {
    if (_checking || !enabled || _passive || !supported) {
      return;
    }
    var follow = FollowService.instance;
    if (follow.updating.value) {
      return;
    }
    if (follow.followList.isEmpty && DBService.instance.followBox.isNotEmpty) {
      await follow.loadData(updateStatus: false);
    }
    var items = follow.followList.where((e) => e.notify).toList();
    _lastCheck = DateTime.now();
    if (items.isEmpty) {
      return;
    }
    _checking = true;
    try {
      var before = {for (var e in items) e.id: e.liveStatus.value};
      for (var item in items) {
        await follow.updateLiveStatus(item);
      }
      if (items.any((e) => e.liveStatus.value != before[e.id])) {
        follow.filterData();
      }
    } finally {
      _checking = false;
    }
  }

  // ---------------------------------------------------------------------
  // 系统通知
  // ---------------------------------------------------------------------

  /// Windows 上通知要一个应用标识。测试版的产品名不一样，用自己的一套，
  /// 不和正式版的混在一起
  static String windowsAppId(String productName) {
    var name = productName.replaceAll(RegExp(r"[^A-Za-z0-9_.]"), "_");
    return "com.xycz.${name.isEmpty ? "simple_live" : name}";
  }

  static String windowsGuid(String productName) =>
      productName.toLowerCase().contains("test")
          ? "3d9e2b71-c4a5-4e8f-b6d0-17f2a9c58e43"
          : "a8f3c1d2-6b4e-4f7a-9c2d-5e1b7a3f0c64";

  /// Windows 上刚启动就初始化通知，偶尔会让程序直接崩溃（2026-11-14 在这台电脑上：
  /// 启动时初始化 14 次崩了 3 次，不初始化 8 次一次没崩，和带不带图标无关）。
  /// 所以电脑上第一次要用（点铃铛、测试通知、发开播通知）时才初始化，并且离启动至少这么久
  static const windowsInitAfter = Duration(seconds: 10);
  final DateTime _started = DateTime.now();

  Future<bool> _ensureReady() => _ready ??= _initWhenSafe();

  Future<bool> _initWhenSafe() async {
    if (Platform.isWindows) {
      var wait = windowsInitAfter - DateTime.now().difference(_started);
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
    }
    return _init();
  }

  Future<bool> _init() async {
    if (!supported) {
      Log.i("Windows 7 没有系统通知，开播提醒不可用");
      return false;
    }
    try {
      var productName = Utils.packageInfo.appName;
      var logo = p.join(
        File(Platform.resolvedExecutable).parent.path,
        "data",
        "flutter_assets",
        "assets",
        "images",
        "logo.png",
      );
      var settings = InitializationSettings(
        android: const AndroidInitializationSettings("ic_stat_live"),
        iOS: const DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        macOS: const DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        linux: LinuxInitializationSettings(defaultActionName: "打开直播间".t),
        windows: WindowsInitializationSettings(
          appName: "Simple Live N",
          appUserModelId: windowsAppId(productName),
          guid: windowsGuid(productName),
          iconPath: Platform.isWindows && File(logo).existsSync() ? logo : null,
        ),
      );
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (response) =>
            openRoom(response.payload),
      );
      unawaited(_cleanAvatars());
      return true;
    } catch (e, stackTrace) {
      Log.e("开播提醒初始化失败：$e", stackTrace);
      _ready = null;
      return false;
    }
  }

  /// 要通知权限（安卓 13 以上、iOS、macOS 会弹系统的确认框；电脑上不用）。
  /// 返回是否能发通知
  Future<bool> ensurePermission() async {
    if (!await _ensureReady()) {
      return false;
    }
    try {
      if (Platform.isAndroid) {
        return await _plugin
                .resolvePlatformSpecificImplementation<
                    AndroidFlutterLocalNotificationsPlugin>()
                ?.requestNotificationsPermission() ??
            true;
      }
      if (Platform.isIOS) {
        return await _plugin
                .resolvePlatformSpecificImplementation<
                    IOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, sound: true) ??
            false;
      }
      if (Platform.isMacOS) {
        return await _plugin
                .resolvePlatformSpecificImplementation<
                    MacOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, sound: true) ??
            false;
      }
    } catch (e) {
      Log.logPrint(e);
      return false;
    }
    return true;
  }

  /// 点了通知：进那个直播间。已经在直播间里时直接换过去，不再开一个
  void openRoom(String? payload) {
    var parts = payload?.split("\n");
    if (parts == null || parts.length != 2) {
      return;
    }
    var site = Sites.allSites[parts[0]];
    if (site == null) {
      return;
    }
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      unawaited(windowManager.show().then((_) => windowManager.focus()));
    }
    if (Get.currentRoute == RoutePath.kLiveRoomDetail &&
        Get.isRegistered<LiveRoomController>()) {
      Get.find<LiveRoomController>().resetRoomOf(parts[0], parts[1]);
    } else {
      AppNavigator.toLiveRoomDetail(site: site, roomId: parts[1]);
    }
  }

  Future<void> _openFromLaunch() async {
    try {
      var details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        var payload = details!.notificationResponse?.payload;
        // 等首页出来再跳
        Future.delayed(const Duration(seconds: 1), () => openRoom(payload));
      }
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 发一条开播通知
  Future<void> send(LiveNotifyMessage message) async {
    if (_passive) {
      return;
    }
    var override = sendOverride;
    if (override != null) {
      return override(message);
    }
    if (!await _ensureReady()) {
      return;
    }
    var avatar = await _avatarFile(message);
    var title = "{name} 开播了".tf({"name": message.name});
    var body = message.title.isEmpty
        ? (Sites.allSites[message.siteId]?.name ?? "")
        : message.title;
    if (Platform.isWindows) {
      await _showWindows(message, title, body, avatar);
      return;
    }
    try {
      await _plugin.show(
        id: message.id,
        title: title,
        body: body,
        notificationDetails: _details(message, avatar, body),
        payload: message.payload,
      );
    } catch (e) {
      if (avatar == null) {
        rethrow;
      }
      // 头像不被系统接受时不带头像再发一次
      Log.logPrint("开播通知带头像发送失败：$e");
      await _plugin.show(
        id: message.id,
        title: title,
        body: body,
        notificationDetails: _details(message, null, body),
        payload: message.payload,
      );
    }
  }

  /// Windows：自己写通知的内容。插件写的正文没有行数设置，
  /// 长的直播间标题只显示一行、后面被截掉；这里标题最多两行、正文最多三行
  Future<void> _showWindows(
    LiveNotifyMessage message,
    String title,
    String body,
    String? avatar,
  ) async {
    var windows = _plugin.resolvePlatformSpecificImplementation<
        FlutterLocalNotificationsWindows>();
    if (windows == null) {
      return;
    }
    String xml(String? image) => windowsToastXml(
          title: title,
          body: body,
          payload: message.payload,
          name: message.name,
          avatar: image,
        );
    try {
      await windows.showRawXml(id: message.id, xml: xml(avatar));
    } catch (e) {
      if (avatar == null) {
        rethrow;
      }
      Log.logPrint("开播通知带头像发送失败：$e");
      await windows.showRawXml(id: message.id, xml: xml(null));
    }
  }

  /// Windows 通知的 XML：标题、正文（可以折行）、圆形头像，点了带上直播间
  static String windowsToastXml({
    required String title,
    required String body,
    required String payload,
    required String name,
    String? avatar,
  }) {
    String esc(String text) => text
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&apos;")
        .replaceAll("\n", "&#xA;");
    var image = avatar == null
        ? ""
        : '<image placement="appLogoOverride" hint-crop="circle" '
            'src="${esc(Uri.file(avatar, windows: true).toString())}" '
            'alt="${esc(name)}"/>';
    return '<toast launch="${esc(payload)}">'
        '<visual><binding template="ToastGeneric">'
        '<text hint-maxLines="2">${esc(title)}</text>'
        '<text hint-maxLines="3">${esc(body)}</text>'
        '$image'
        '</binding></visual>'
        '</toast>';
  }

  NotificationDetails _details(
    LiveNotifyMessage message,
    String? avatar,
    String body,
  ) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        "live_notify",
        "开播提醒".t,
        channelDescription: "开启了提醒的直播间开播时发送通知".t,
        icon: "ic_stat_live",
        importance: Importance.high,
        priority: Priority.high,
        largeIcon: avatar == null ? null : FilePathAndroidBitmap(avatar),
        // 收起时正文只有一行，展开后显示完整的直播间标题
        styleInformation: BigTextStyleInformation(body),
      ),
      iOS: DarwinNotificationDetails(
        threadIdentifier: "live_notify",
        attachments:
            avatar == null ? null : [DarwinNotificationAttachment(avatar)],
      ),
      macOS: DarwinNotificationDetails(
        threadIdentifier: "live_notify",
        attachments:
            avatar == null ? null : [DarwinNotificationAttachment(avatar)],
      ),
      linux: LinuxNotificationDetails(
        icon: avatar == null ? null : FilePathLinuxIcon(avatar),
      ),
      windows: WindowsNotificationDetails(
        images: avatar == null
            ? const []
            : [
                WindowsImage(
                  Uri.file(avatar, windows: true),
                  altText: message.name,
                  placement: WindowsImagePlacement.appLogoOverride,
                  crop: WindowsImageCrop.circle,
                ),
              ],
      ),
    );
  }

  /// 测试通知：用第一个订阅了的（没有就用第一个关注的）主播的名字和头像
  Future<void> sendTest() async {
    if (!supported) {
      SmartDialog.showToast("Windows 7 不支持系统通知，开播时不会提醒".t);
      return;
    }
    if (!await ensurePermission()) {
      SmartDialog.showToast("没有通知权限，请在系统设置中开启".t);
      return;
    }
    var follows = DBService.instance.getFollowList();
    var item = follows.where((e) => e.notify).firstOrNull ?? follows.firstOrNull;
    var message = item == null
        ? const LiveNotifyMessage(
            siteId: "",
            roomId: "",
            followId: "test",
            name: "Simple Live",
            title: "",
            avatar: "",
          )
        : LiveNotifyMessage.of(item, null);
    try {
      await send(LiveNotifyMessage(
        siteId: message.siteId,
        roomId: message.roomId,
        followId: "test",
        name: message.name,
        title: "这是测试通知，开播时会这样提醒你".t,
        avatar: message.avatar,
      ));
    } catch (e, stackTrace) {
      Log.e("测试通知发送失败：$e", stackTrace);
      SmartDialog.showToast("通知发送失败：{e}".tf({"e": e}));
    }
  }

  // ---------------------------------------------------------------------
  // 头像：下载后转成 192×192 的 PNG（各系统的通知都认 PNG；有的平台给的是 WebP）
  // ---------------------------------------------------------------------

  Future<Directory> _avatarDir() async {
    var dir = Directory(p.join((await getTemporaryDirectory()).path, "live_notify"));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  int _avatarSeq = 0;

  Future<String?> _avatarFile(LiveNotifyMessage message) async {
    var url = message.avatar.trim();
    if (url.startsWith("//")) {
      url = "https:$url";
    }
    if (!url.startsWith("http")) {
      return null;
    }
    try {
      var client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      List<int> bytes;
      try {
        var request = await client.getUrl(Uri.parse(url));
        var response =
            await request.close().timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) {
          return null;
        }
        bytes = await consolidateHttpClientResponseBytes(response)
            .timeout(const Duration(seconds: 15));
      } finally {
        client.close(force: true);
      }
      var png = await compute(avatarPng, Uint8List.fromList(bytes));
      if (png == null) {
        return null;
      }
      // iOS 会把附件文件挪走，每条通知用一个新文件
      var file = File(p.join(
        (await _avatarDir()).path,
        "${message.id}_${DateTime.now().millisecondsSinceEpoch}_${_avatarSeq++}.png",
      ));
      await file.writeAsBytes(png);
      return file.path;
    } catch (e) {
      Log.logPrint("开播通知头像读取失败：$e");
      return null;
    }
  }

  /// 任意格式的图片 → 居中裁成正方形、192×192 的 PNG；不是图片时返回 null
  static Uint8List? avatarPng(Uint8List bytes) {
    var image = img.decodeImage(bytes);
    if (image == null) {
      return null;
    }
    var square = img.copyResizeCropSquare(image, size: 192);
    return img.encodePng(square);
  }

  /// 删掉一天前的头像文件
  Future<void> _cleanAvatars() async {
    try {
      var dir = await _avatarDir();
      var old = DateTime.now().subtract(const Duration(days: 1));
      for (var entry in dir.listSync()) {
        if (entry is File && entry.statSync().modified.isBefore(old)) {
          entry.deleteSync();
        }
      }
    } catch (_) {}
  }

  @override
  void onClose() {
    _timer?.cancel();
    _firstCheck?.cancel();
    for (var worker in _workers) {
      worker.dispose();
    }
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }
}
