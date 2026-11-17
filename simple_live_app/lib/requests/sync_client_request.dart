import 'package:simple_live_app/models/sync_client_info_model.dart';
import 'dart:convert';

import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/sync_lan_crypto.dart';
import 'package:simple_live_app/services/sync_service.dart';

class SyncClientRequest {
  SyncClientRequest({this.peerKey});

  /// 对方的公钥（见 [SyncClientInfoModel.encKey]）；为 null 时发明文
  final String? peerKey;

  /// 发给对方的同步接口：有公钥时把内容加密，官方版和旧版照常发明文
  Future<dynamic> _post(
    SyncClinet client,
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
  }) {
    var key = peerKey;
    if (key != null) {
      data = LanSyncCrypto.seal(
          key, path, data is String ? data : jsonEncode(data ?? {}));
    }
    return HttpClient.instance.postJson(
      "http://${client.address}:${client.port}$path",
      data: data,
      queryParameters: queryParameters,
    );
  }

  Future<SyncClientInfoModel> getClientInfo(SyncClinet client) async {
    var url = "http://${client.address}:${client.port}/info";
    var data = await HttpClient.instance.getJson(url);

    return SyncClientInfoModel.fromJson(data);
  }

  Future<bool> syncFollow(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
    bool ext = false,
    bool js = false,
  }) async {
    var data = await _post(
      client,
      "/sync/follow",
      data: body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
        if (ext) 'ext': '1',
        if (js) 'js': '1',
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncTag(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
    bool ext = false,
    bool js = false,
  }) async {
    var data = await _post(
      client,
      "/sync/tag",
      data: body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
        if (ext) 'ext': '1',
        if (js) 'js': '1',
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncHistory(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
    bool ext = false,
    bool js = false,
  }) async {
    var data = await _post(
      client,
      "/sync/history",
      data: body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
        if (ext) 'ext': '1',
        if (js) 'js': '1',
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  /// 直播源（仅本版本之间）：对方补上订阅，从地址安装没有的源
  Future<bool> syncLiveSources(SyncClinet client, dynamic body) async {
    var data = await _post(
      client,
      "/sync/live_sources",
      data: body,
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncBlockedWord(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) async {
    var data = await _post(
      client,
      "/sync/blocked_word",
      data: body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  /// 屏蔽的人（永久的）和备注，只发给声明了 chat_users 的设备
  Future<bool> syncChatUsers(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) async {
    var data = await _post(
      client,
      "/sync/chat_users",
      data: body,
      queryParameters: {'overlay': overlay ? '1' : '0'},
    );
    if (data["status"]) {
      return true;
    }
    throw data["message"];
  }

  /// 账号只发给能解密的设备
  Future<bool> syncBiliAccount(SyncClinet client, String cookie) async {
    if (peerKey == null) {
      throw "对方是官方版或旧版本，不能加密，账号不会发送".t;
    }
    var data = await _post(
      client,
      "/sync/account/bilibili",
      data: {
        "cookie": cookie,
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }
}
