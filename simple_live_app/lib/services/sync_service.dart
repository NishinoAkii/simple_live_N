import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/live_source_service.dart';
import 'package:udp/udp.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:simple_live_app/services/sync_lan_crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 局域网同步：支持直播源（订阅与已安装的源）
const kSyncFeatureLiveSources = "live_sources";

/// 局域网同步：支持屏蔽的人（永久的）和备注（只在本版本之间）
const kSyncFeatureChatUsers = "chat_users";

class SyncService extends GetxService {
  static SyncService get instance => Get.find<SyncService>();

  UDP? udp;
  RxList<SyncClinet> scanClients = <SyncClinet>[].obs;
  static const int udpPort = 23235;
  static const int httpPort = 23234;
  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  NetworkInfo networkInfo = NetworkInfo();
  HttpServer? server;
  var ipAddress = "".obs;
  var httpRunning = false.obs;

  /// 这次启动同步服务用的密钥（见 [LanSyncCrypto]）
  LanSyncCrypto? _lanCrypto;
  var httpErrorMsg = "".obs;

  var deviceId = "";

  @override
  void onInit() {
    // 多开的副窗口不开局域网同步（端口只能一个进程用）
    if (MultiWindow.skips(BackgroundTask.lanSync)) {
      super.onInit();
      return;
    }
    Log.d('TVService init');
    deviceId = (const Uuid().v4()).split('-').first;
    listenUDP();
    initServer();
    super.onInit();
  }

  /// 监听其他端UDP广播的回复
  void listenUDP() async {
    udp = await UDP.bind(Endpoint.any(port: const Port(udpPort)));
    udp!.asStream().listen(listenUdp);
  }

  void listenUdp(Datagram? datagram) {
    var str = String.fromCharCodes(datagram!.data);
    Log.i("Received: $str from ${datagram.address}:${datagram.port}");
    if (str.startsWith('{') && str.endsWith('}')) {
      var data = json.decode(str);
      //如果是自己的广播，就不处理
      if (data['id'] == deviceId) {
        return;
      }
      //处理Hello的广播
      if (data["type"] == "hello") {
        //如果http服务已经启动，就回复自己的信息
        if (httpRunning.value) {
          sendInfo();
        }
        return;
      }
      // 处理其他端的广播
      // 地址直接从datagram中获取，能收到回复说明地址是可以连通的
      var address = datagram.address.address;
      //检查是否已经存在
      var index =
          scanClients.indexWhere((element) => element.address == address);
      if (index == -1) {
        scanClients.add(
          SyncClinet(
            id: data['id'],
            name: data['name'],
            address: address,
            port: httpPort,
            type: data['type'],
          ),
        );
      }
    }
  }

  /// 发送UDP广播至其他端
  void sendHello() async {
    if (udp == null) {
      return;
    }
    await udp!.send(
      json.encode({
        "id": deviceId,
        "type": "hello",
      }).codeUnits,
      Endpoint.broadcast(
        port: const Port(udpPort),
      ),
    );
    Log.i("send udp: hello");
  }

  /// UDP广播自身信息
  void sendInfo() async {
    //var ip = await getLocalIP();

    var name = await getDeviceName();

    var data = {
      "id": deviceId,
      "type": Platform.operatingSystem,
      //'version': Utils.packageInfo.version,
      "name": name,
      //"address": ip,
      //"port": httpPort,
    };

    await udp!.send(
      json.encode(data).codeUnits,
      Endpoint.broadcast(
        port: const Port(udpPort),
      ),
    );
    Log.i("send udp info: $data");
  }

  Future<String> getDeviceName() async {
    var name = "SimpleLive-${Platform.operatingSystem}";
    if (Platform.isAndroid) {
      var info = await deviceInfo.androidInfo;
      name = info.model;
    } else if (Platform.isIOS) {
      var info = await deviceInfo.iosInfo;
      name = info.name;
    } else if (Platform.isMacOS) {
      var info = await deviceInfo.macOsInfo;
      name = info.computerName;
    } else if (Platform.isLinux) {
      var info = await deviceInfo.linuxInfo;
      name = info.name;
    } else if (Platform.isWindows) {
      var info = await deviceInfo.windowsInfo;
      name = info.userName;
    }
    return name;
  }

  void refreshClients() {
    scanClients.clear();
    sendHello();
  }

  /// 读取本地IP
  /// - 如果是wifi，直接获取wifi的IP
  /// - 如果是有线，获取所有的IP，找到全部的IP
  Future<String> getLocalIP() async {
    String? ip = "";
    try {
      ip = await networkInfo.getWifiIP();
    } catch (e) {
      Log.logPrint(e);
    }
    try {
      if (ip == null || ip.isEmpty) {
        var interfaces = await NetworkInterface.list();
        var ipList = <String>[];
        for (var interface in interfaces) {
          for (var addr in interface.addresses) {
            if (addr.type.name == 'IPv4' &&
                !addr.address.startsWith('127') &&
                !addr.isMulticast &&
                !addr.isLoopback) {
              ipList.add(addr.address);
              break;
            }
          }
        }
        ip = ipList.join(';');
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return ip ?? "";
  }

  /// 初始化HTTP服务
  void initServer() async {
    try {
      var serverRouter = Router();
      serverRouter.get('/', _helloRequest);
      serverRouter.get('/info', _infoRequest);
      serverRouter.post('/sync/follow', _syncFollowUserReuqest);
      serverRouter.post('/sync/tag', _syncFollowUserTagRequest);
      serverRouter.post('/sync/history', _syncHistoryReuqest);
      serverRouter.post('/sync/live_sources', _syncLiveSourcesRequest);
      serverRouter.post('/sync/blocked_word', _syncBlockedWordReuqest);
      serverRouter.post('/sync/chat_users', _syncChatUsersRequest);
      serverRouter.post('/sync/account/bilibili', _syncBiliAccountReuqest);

      _lanCrypto = LanSyncCrypto();
      var server = await shelf_io.serve(
        const shelf.Pipeline()
            .addMiddleware(_decryptBodies)
            .addHandler(serverRouter.call),
        InternetAddress.anyIPv4,
        httpPort,
      );

      // Enable content compression
      server.autoCompress = true;

      httpRunning.value = true;

      var ip = await getLocalIP();
      ipAddress.value = ip;

      Log.d('Serving at http://$ip:${server.port}');
    } catch (e) {
      httpErrorMsg.value = e.toString();
      Log.logPrint(e);
    }
  }

  /// 加密发来的内容先解开，后面各接口照常处理；官方版发来的明文直接放行
  shelf.Handler _decryptBodies(shelf.Handler inner) {
    return (shelf.Request request) async {
      var crypto = _lanCrypto;
      if (request.method != 'POST' || crypto == null) {
        return inner(request);
      }
      var body = await request.readAsString();
      String? plain;
      try {
        plain = crypto.open(request.requestedUri.path, body);
      } catch (e) {
        Log.w("局域网同步：内容解不开：$e");
        return toJsonResponse({
          'status': false,
          'message': "对方没能解开内容，请刷新设备列表后重试".t,
        });
      }
      return inner(request.change(body: plain ?? body));
    };
  }

  /// 测试服务能否正常访问
  shelf.Response _helloRequest(shelf.Request request) {
    return toJsonResponse({
      'status': true,
      'message': 'http server is running...',
      "version":
          'SimpeLive ${Platform.operatingSystem} v${Utils.packageInfo.version}',
    });
  }

  /// 发送自己的信息
  Future<shelf.Response> _infoRequest(shelf.Request request) async {
    var name = await getDeviceName();
    return toJsonResponse({
      "id": deviceId,
      'type': Platform.operatingSystem,
      'name': name,
      'version': Utils.packageInfo.version,
      'address': ipAddress.value,
      'port': httpPort,
      // 声明支持新平台数据；官方版没有这个字段，发送方据此决定是否过滤。
      // 直播源平台用 js:* 一项声明（没装的源也能接收，灰色显示）
      SyncCompat.kInfoExtKey: SyncCompat.localExtSites(Sites.builtInSites.keys),
      // 支持的附加同步内容
      'features': [
        kSyncFeatureLiveSources,
        if (ChatUsersService.maybeInstance != null) kSyncFeatureChatUsers,
        if (_lanCrypto != null) LanSyncCrypto.feature,
      ],
      if (_lanCrypto != null) LanSyncCrypto.infoKey: _lanCrypto!.publicKey,
    });
  }

  /// 同步关注用户列表
  Future<shelf.Response> _syncFollowUserReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');

      var body = await request.readAsString();
      Log.d('_syncFollowUserReuqest: $body');
      var jsonBody = json.decode(body);
      // 发送方是官方版（没有 ext=1）时保留本地新平台的关注，
      // 是不支持直播源的旧版（没有 js=1）时保留本地直播源平台的关注
      var ext = request.requestedUri.queryParameters['ext'] == '1';
      var js = request.requestedUri.queryParameters['js'] == '1';
      if (overlay == 1) {
        await SyncCompat.clearFollows(includeExt: ext, includeScripts: js);
      }
      for (var item in jsonBody) {
        var user = FollowUser.fromJson(item);
        await DBService.instance.followBox.put(user.id, user);
      }

      SmartDialog.showToast('已同步关注列表'.t);
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步标签列表
  Future<shelf.Response> _syncFollowUserTagRequest(
      shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');

      var body = await request.readAsString();
      Log.d('_syncFollowUserTagRequest: $body');
      var jsonBody = json.decode(body);
      var ext = request.requestedUri.queryParameters['ext'] == '1';
      var js = request.requestedUri.queryParameters['js'] == '1';
      var extMembers = !ext
          ? SyncCompat.snapshotExtTagMembers()
          : js
              ? <String, List<String>>{}
              : SyncCompat.snapshotExtTagMembers(scriptsOnly: true);
      if (overlay == 1) {
        await DBService.instance.tagBox.clear();
      }
      for (var item in jsonBody) {
        var tag = FollowUserTag.fromJson(item);
        await DBService.instance.tagBox.put(tag.id, tag);
      }
      await SyncCompat.restoreExtTagMembers(extMembers);

      SmartDialog.showToast('已同步标签'.t);
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步观看记录
  Future<shelf.Response> _syncHistoryReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');
      var body = await request.readAsString();
      Log.d('_syncFollowUserReuqest: $body');
      var jsonBody = json.decode(body);
      var ext = request.requestedUri.queryParameters['ext'] == '1';
      var js = request.requestedUri.queryParameters['js'] == '1';
      if (overlay == 1) {
        await SyncCompat.clearHistories(includeExt: ext, includeScripts: js);
      }
      for (var item in jsonBody) {
        var history = History.fromJson(item);
        if (DBService.instance.historyBox.containsKey(history.id)) {
          var old = DBService.instance.historyBox.get(history.id);
          //如果本地的更新时间比较新，就不更新
          if (old!.updateTime.isAfter(history.updateTime)) {
            continue;
          }
        }
        await DBService.instance.addOrUpdateHistory(history);
      }

      SmartDialog.showToast('已同步观看记录'.t);
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步直播源（仅本版本之间）：补上订阅，从地址安装本机没有的源。
  /// 要联网下载，先回复再在后台安装，完成后在本机提示
  Future<shelf.Response> _syncLiveSourcesRequest(shelf.Request request) async {
    try {
      var jsonBody = json.decode(await request.readAsString());
      if (jsonBody is! Map) {
        throw "数据格式不对".t;
      }
      if (!LiveSourceService.registered ||
          !LiveSourceService.instance.available.value) {
        throw "对方设备的直播源功能不可用".t;
      }
      if (LiveSourceSyncData.fromJson(jsonBody).isEmpty) {
        return toJsonResponse({'status': true, 'message': 'success'});
      }
      SmartDialog.showToast('正在同步直播源'.t);
      LiveSourceService.instance.restoreSyncDataInBackground(jsonBody);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步弹幕屏蔽词
  Future<shelf.Response> _syncBlockedWordReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');
      var body = await request.readAsString();
      Log.d('_syncBlockedWordReuqest: $body');
      var jsonBody = json.decode(body);
      // 存到全局的关键词（开着直播间单独设置时也一样）
      await AppSettingsController.instance.updateGlobalShieldList(
        clear: overlay == 1,
        add: [for (var keyword in jsonBody) keyword.toString().trim()],
      );
      SmartDialog.showToast('已同步弹幕屏蔽词'.t);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步屏蔽的人（永久的）和备注（仅本版本之间）
  Future<shelf.Response> _syncChatUsersRequest(shelf.Request request) async {
    try {
      var overlay = request.requestedUri.queryParameters['overlay'] == '1';
      var jsonBody = json.decode(await request.readAsString());
      var users = ChatUsersService.maybeInstance;
      if (jsonBody is! Map || users == null) {
        throw "数据格式不对".t;
      }
      users.importSync(jsonBody, replace: overlay);
      return toJsonResponse({'status': true, 'message': 'success'});
    } catch (e) {
      return toJsonResponse({'status': false, 'message': e.toString()});
    }
  }

  /// 同步哔哩哔哩账号
  Future<shelf.Response> _syncBiliAccountReuqest(shelf.Request request) async {
    try {
      var body = await request.readAsString();
      Log.d('_syncBiliAccountReuqest: 收到 ${body.length} 字');
      var jsonBody = json.decode(body);
      var cookie = jsonBody['cookie'];
      BiliBiliAccountService.instance.setCookie(cookie);
      BiliBiliAccountService.instance.loadUserInfo();
      SmartDialog.showToast('已同步哔哩哔哩账号'.t);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  shelf.Response toJsonResponse(Map<String, dynamic> data) {
    return shelf.Response.ok(
      json.encode(data),
      headers: {
        'Content-Type': 'application/json',
      },
      encoding: Encoding.getByName('utf-8'),
    );
  }

  @override
  void onClose() {
    Log.d('SyncService close');
    udp?.close();
    server?.close(force: true);
    super.onClose();
  }
}

class SyncClinet {
  final String id;
  final String name;
  final String address;
  final int port;
  final String type;
  SyncClinet({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.type,
  });
}
