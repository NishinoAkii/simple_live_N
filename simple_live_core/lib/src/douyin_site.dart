import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/avplayer_url.dart';
import 'package:simple_live_core/src/common/convert_helper.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/room_area.dart';
import 'package:simple_live_core/src/common/search_parser.dart';
import 'package:simple_live_core/src/scripts/douyin_sign.dart';

class DouyinSite implements LiveSite, LiveRankSite {
  @override
  String id = "douyin";

  @override
  String name = "抖音直播";

  @override
  LiveDanmaku getDanmaku() => DouyinDanmaku();

  /// 使用 QQBrowser User-Agent（参考 DouyinLiveRecorder）
  static const String kDefaultUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.5845.97 Safari/537.36 Core/1.116.567.400 QQBrowser/19.7.6764.400";

  static const String kDefaultReferer = "https://live.douyin.com";

  static const String kDefaultAuthority = "live.douyin.com";

  /// 默认 Cookie - 只需要 ttwid 字段即可获取所有画质（包括蓝光）
  /// 经过测试验证，LOGIN_STATUS=1 等其他字段都是可选的
  static const String kDefaultCookie =
      "ttwid=1%7CB1qls3GdnZhUov9o2NxOMxxYS2ff6OSvEWbv0ytbES4%7C1680522049%7C280d802d6d478e3e78d0c807f7c487e7ffec0ae4e5fdd6a0fe74c3c6af149511";

  /// 用户设置的 cookie
  String cookie = "";

  void _logDebug(String msg) {
    // 同时使用 print 和 CoreLog 确保日志输出
    print("[Douyin] $msg");
    CoreLog.d("[Douyin] $msg");
  }

  Map<String, dynamic> headers = {
    "Authority": kDefaultAuthority,
    "Referer": kDefaultReferer,
    "User-Agent": kDefaultUserAgent,
  };

  Future<Map<String, dynamic>> getRequestHeaders() async {
    try {
      // 如果用户已设置 cookie，直接使用用户的 cookie
      if (cookie.isNotEmpty) {
        headers["cookie"] = cookie;
        return headers;
      }

      // 使用默认的 ttwid cookie（只需要 ttwid 即可获取所有画质）
      headers["cookie"] = kDefaultCookie;
      return headers;
    } catch (e) {
      CoreLog.error(e);
      if (!(headers["cookie"]?.toString().isNotEmpty ?? false)) {
        headers["cookie"] = kDefaultCookie;
      }
      return headers;
    }
  }

  @override
  Future<List<LiveCategory>> getCategores() async {
    List<LiveCategory> categories = [];
    var result = await HttpClient.instance.getText(
      "https://live.douyin.com/",
      queryParameters: {},
      header: await getRequestHeaders(),
    );

    var categoryJson = douyinCategoryJson(result);
    if (categoryJson == null) {
      throw CoreError("抖音首页里没有找到分类".t);
    }
    categories.addAll(douyinCategories(json.decode(categoryJson)));
    return categories;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    var ids = category.id.split(',');
    var partitionId = ids[0];
    var partitionType = ids[1];

    String serverUrl =
        "https://live.douyin.com/webcast/web/partition/detail/room/v2/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "enter_from": "link_share",
        "cookie_enabled": "true",
        "screen_width": "1980",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Edge",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "count": '15',
        "offset": ((page - 1) * 15).toString(),
        "partition": partitionId,
        "partition_type": partitionType,
        "req_from": '2',
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);

    var result = await HttpClient.instance.getJson(
      requestUrl,
      header: await getRequestHeaders(),
    );
    return douyinCategoryRooms(result);
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    String serverUrl =
        "https://live.douyin.com/webcast/web/partition/detail/room/v2/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "enter_from": "link_share",
        "cookie_enabled": "true",
        "screen_width": "1980",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Edge",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "count": '15',
        "offset": ((page - 1) * 15).toString(),
        "partition": '720',
        "partition_type": '1',
        "req_from": '2',
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);

    var result = await HttpClient.instance.getJson(
      requestUrl,
      header: await getRequestHeaders(),
    );
    return douyinCategoryRooms(result);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    // 有两种roomId，一种是webRid，一种是roomId
    // roomId是一次性的，用户每次重新开播都会生成一个新的roomId
    // roomId一般长度为19位，例如：7376429659866598196
    // webRid是固定的，用户每次开播都是同一个webRid
    // webRid一般长度为11-12位，例如：416144012050
    // 这里简单进行判断，如果roomId长度小于15，则认为是webRid
    if (roomId.length <= 16) {
      var webRid = roomId;
      return await getRoomDetailByWebRid(webRid);
    }

    return await getRoomDetailByRoomId(roomId);
  }

  /// 通过roomId获取直播间信息
  /// - [roomId] 直播间ID
  /// - 返回直播间信息
  Future<LiveRoomDetail> getRoomDetailByRoomId(String roomId) async {
    // 读取房间信息
    var roomData = await _getRoomDataByRoomId(roomId);

    // 通过房间信息获取WebRid
    var webRid = roomData["data"]["room"]["owner"]["web_rid"].toString();

    // 读取用户唯一ID，用于弹幕连接
    // 似乎这个参数不是必须的，先随机生成一个
    //var userUniqueId = await _getUserUniqueId(webRid);
    var userUniqueId = generateRandomNumber(12).toString();

    var room = roomData["data"]["room"];
    var owner = room["owner"];

    var status = asT<int?>(room["status"]) ?? 0;

    // roomId是一次性的，用户每次重新开播都会生成一个新的roomId
    // 所以如果roomId对应的直播间状态不是直播中，就通过webRid获取直播间信息
    if (status == 4) {
      var result = await getRoomDetailByWebRid(webRid);
      return result;
    }

    var roomStatus = status == 2;
    // 主要是为了获取cookie,用于弹幕websocket连接
    var headers = await getRequestHeaders();

    return LiveRoomDetail(
      roomId: webRid,
      title: room["title"].toString(),
      cover: roomStatus ? room["cover"]["url_list"][0].toString() : "",
      userName: owner["nickname"].toString(),
      userAvatar: owner["avatar_thumb"]["url_list"][0].toString(),
      online: roomStatus
          ? asT<int?>(room["room_view_stats"]["display_value"]) ?? 0
          : 0,
      status: roomStatus,
      url: "https://live.douyin.com/$webRid",
      introduction: owner["signature"].toString(),
      notice: "",
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: roomId,
        userId: userUniqueId,
        cookie: headers["cookie"],
        // 连麦名单里去掉本直播间的主播
        anchorId: owner?["id_str"]?.toString() ?? "",
        secAnchorId: owner?["sec_uid"]?.toString() ?? "",
      ),
      data: room["stream_url"],
    );
  }

  /// 通过WebRid获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoomDetail> getRoomDetailByWebRid(String webRid) async {
    try {
      var result = await _getRoomDetailByWebRidApi(webRid);
      return result;
    } catch (e) {
      CoreLog.error(e);
    }
    return await _getRoomDetailByWebRidHtml(webRid);
  }

  /// 通过WebRid访问直播间API，从API中获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoomDetail> _getRoomDetailByWebRidApi(String webRid) async {
    // 读取房间信息
    var data = await _getRoomDataByApi(webRid);

    var roomData = data["data"][0];
    var userData = data["user"];
    var roomId = roomData["id_str"].toString();

    // 读取用户唯一ID，用于弹幕连接
    // 似乎这个参数不是必须的，先随机生成一个
    //var userUniqueId = await _getUserUniqueId(webRid);
    var userUniqueId = generateRandomNumber(12).toString();

    var owner = roomData["owner"];

    var roomStatus = (asT<int?>(roomData["status"]) ?? 0) == 2;

    // 主要是为了获取cookie,用于弹幕websocket连接
    var headers = await getRequestHeaders();
    return LiveRoomDetail(
      roomId: webRid,
      title: roomData["title"].toString(),
      cover: roomStatus ? roomData["cover"]["url_list"][0].toString() : "",
      userName: roomStatus
          ? owner["nickname"].toString()
          : userData["nickname"].toString(),
      userAvatar: roomStatus
          ? owner["avatar_thumb"]["url_list"][0].toString()
          : userData["avatar_thumb"]["url_list"][0].toString(),
      online: roomStatus
          ? asT<int?>(roomData["room_view_stats"]["display_value"]) ?? 0
          : 0,
      status: roomStatus,
      url: "https://live.douyin.com/$webRid",
      introduction: owner?["signature"]?.toString() ?? "",
      notice: "",
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: roomId,
        userId: userUniqueId,
        cookie: headers["cookie"],
        // 连麦名单里去掉本直播间的主播
        anchorId: owner?["id_str"]?.toString() ?? "",
        secAnchorId: owner?["sec_uid"]?.toString() ?? "",
      ),
      data: roomStatus ? roomData["stream_url"] : {},
      area: LiveRoomArea.douyin(data["partition_road_map"]),
    );
  }

  /// 通过WebRid访问直播间网页，从网页HTML中获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoomDetail> _getRoomDetailByWebRidHtml(String webRid) async {
    var roomData = await _getRoomDataByHtml(webRid);
    var roomId = roomData["roomStore"]["roomInfo"]["room"]["id_str"].toString();
    var userUniqueId = roomData["userStore"]["odin"]["user_unique_id"]
        .toString();

    var room = roomData["roomStore"]["roomInfo"]["room"];
    var owner = room["owner"];
    var anchor = roomData["roomStore"]["roomInfo"]["anchor"];
    var roomStatus = (asT<int?>(room["status"]) ?? 0) == 2;

    // 主要是为了获取cookie,用于弹幕websocket连接
    var headers = await getRequestHeaders();

    return LiveRoomDetail(
      roomId: webRid,
      title: room["title"].toString(),
      cover: roomStatus ? room["cover"]["url_list"][0].toString() : "",
      userName: roomStatus
          ? owner["nickname"].toString()
          : anchor["nickname"].toString(),
      userAvatar: roomStatus
          ? owner["avatar_thumb"]["url_list"][0].toString()
          : anchor["avatar_thumb"]["url_list"][0].toString(),
      online: roomStatus
          ? asT<int?>(room["room_view_stats"]["display_value"]) ?? 0
          : 0,
      status: roomStatus,
      url: "https://live.douyin.com/$webRid",
      introduction: owner?["signature"]?.toString() ?? "",
      notice: "",
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: roomId,
        userId: userUniqueId,
        cookie: headers["cookie"],
        // 连麦名单里去掉本直播间的主播
        anchorId: owner?["id_str"]?.toString() ?? "",
        secAnchorId: owner?["sec_uid"]?.toString() ?? "",
      ),
      data: roomStatus ? room["stream_url"] : {},
      // 网页里的 roomInfo 和接口的 data 是同一份
      area: LiveRoomArea.douyin(
        roomData["roomStore"]["roomInfo"]["partition_road_map"],
      ),
    );
  }

  /// 读取用户的唯一ID
  /// - [webRid] 直播间RID
  // ignore: unused_element
  Future<String> _getUserUniqueId(String webRid) async {
    try {
      var webInfo = await _getRoomDataByHtml(webRid);
      return webInfo["userStore"]["odin"]["user_unique_id"].toString();
    } catch (e) {
      return generateRandomNumber(12).toString();
    }
  }

  /// 进入直播间前需要先获取cookie
  /// - [webRid] 直播间RID
  Future<String> _getWebCookie(String webRid) async {
    var headResp = await HttpClient.instance.head(
      "https://live.douyin.com/$webRid",
      header: headers,
    );
    var dyCookie = "";
    headResp.headers["set-cookie"]?.forEach((element) {
      var cookie = element.split(";")[0];
      if (cookie.contains("ttwid")) {
        dyCookie += "$cookie;";
      }
      if (cookie.contains("__ac_nonce")) {
        dyCookie += "$cookie;";
      }
      if (cookie.contains("msToken")) {
        dyCookie += "$cookie;";
      }
    });
    return dyCookie;
  }

  /// 通过webRid获取直播间Web信息
  /// - [webRid] 直播间RID
  Future<Map> _getRoomDataByHtml(String webRid) async {
    var dyCookie = await _getWebCookie(webRid);
    var result = await HttpClient.instance.getText(
      "https://live.douyin.com/$webRid",
      queryParameters: {},
      header: {
        "Authority": kDefaultAuthority,
        "Referer": kDefaultReferer,
        "Cookie": dyCookie,
        "User-Agent": kDefaultUserAgent,
      },
    );

    var renderData =
        RegExp(
          r'\{\\"state\\":\{\\"appStore.*?\]\\n',
        ).firstMatch(result)?.group(0) ??
        "";
    var str = renderData
        .trim()
        .replaceAll('\\"', '"')
        .replaceAll(r"\\", r"\")
        .replaceAll(']\\n', "");
    var renderDataJson = json.decode(str);
    return renderDataJson["state"];
  }

  /// 通过webRid获取直播间Web信息
  /// - [webRid] 直播间RID
  Future<Map> _getRoomDataByApi(String webRid) async {
    String serverUrl = "https://live.douyin.com/webcast/room/web/enter/";

    // 提前获取 headers
    var requestHeader = await getRequestHeaders();

    // 使用动态 Referer（包含房间号，参考 DouyinLiveRecorder）
    requestHeader["Referer"] = "https://live.douyin.com/$webRid";

    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Chrome",
        "browser_version": "125.0.0.0",
        "web_rid": webRid,
        "msToken": "",
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);

    var result = await HttpClient.instance.getJson(
      requestUrl,
      header: requestHeader,
    );

    if (result is! Map) {
      throw Exception("抖音返回的数据格式不对".t);
    }

    return result["data"];
  }

  @override
  List<LiveRankBoard> get rankBoards => kDouyinRankBoards;

  /// 在线观众榜（要 a_bogus 签名）。房间号、主播的 id 和 sec_uid 进直播间时已经存在
  /// 弹幕参数里，没有时再读一次房间信息。
  @override
  Future<LiveRankList> getRank(
    String boardId, {
    required LiveRoomDetail detail,
  }) async {
    if (boardId != "online") {
      throw CoreError("不支持这个榜单".t);
    }
    var webRid = detail.roomId;
    var args = detail.danmakuData;
    var roomId = "";
    var anchorId = "";
    var secAnchorId = "";
    if (args is DouyinDanmakuArgs) {
      webRid = args.webRid.isEmpty ? webRid : args.webRid;
      roomId = args.roomId;
      anchorId = args.anchorId;
      secAnchorId = args.secAnchorId;
    }
    if (roomId.isEmpty || anchorId.isEmpty || secAnchorId.isEmpty) {
      var data = await _getRoomDataByApi(webRid);
      var rooms = data["data"];
      var room = rooms is List && rooms.isNotEmpty ? rooms.first : const {};
      var owner = room["owner"] ?? data["user"] ?? const {};
      if (roomId.isEmpty) roomId = room["id_str"]?.toString() ?? "";
      if (anchorId.isEmpty) anchorId = owner["id_str"]?.toString() ?? "";
      if (secAnchorId.isEmpty) secAnchorId = owner["sec_uid"]?.toString() ?? "";
    }
    if (roomId.isEmpty || anchorId.isEmpty || secAnchorId.isEmpty) {
      throw CoreError("没有读取到直播间信息，可能还没有开播".t);
    }
    var header = await getRequestHeaders();
    header = {...header, "Referer": "https://live.douyin.com/$webRid"};
    var uri = Uri.parse("https://live.douyin.com/webcast/ranklist/audience/")
        .replace(
          queryParameters: {
            "aid": "6383",
            "app_name": "douyin_web",
            "live_id": "1",
            "device_platform": "web",
            "language": "zh-CN",
            "enter_from": "link_share",
            "cookie_enabled": "true",
            "screen_width": "1920",
            "screen_height": "1080",
            "browser_language": "zh-CN",
            "browser_platform": "Win32",
            "browser_name": "Chrome",
            "browser_version": "125.0.0.0",
            "webcast_sdk_version": "2450",
            "room_id": roomId,
            "anchor_id": anchorId,
            "sec_anchor_id": secAnchorId,
            "rank_type": "30",
          },
        );
    var url = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);
    var result = await HttpClient.instance.getJson(url, header: header);
    return parseDouyinAudienceRank(result);
  }

  /// 通过roomId获取直播间信息
  /// - [roomId] 直播间ID
  Future<Map> _getRoomDataByRoomId(String roomId) async {
    var result = await HttpClient.instance.getJson(
      'https://webcast.amemv.com/webcast/room/reflow/info/',
      queryParameters: {
        "type_id": 0,
        "live_id": 1,
        "room_id": roomId,
        "sec_user_id": "",
        "version_code": "99.99.99",
        "app_id": 6383,
      },
      header: await getRequestHeaders(),
    );
    return result;
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    List<LivePlayQuality> qualities = [];

    try {
      var liveCoreData = detail.data["live_core_sdk_data"];

      if (liveCoreData == null) {
        return qualities;
      }

      var pullData = liveCoreData["pull_data"];

      if (pullData == null) {
        return qualities;
      }

      var options = pullData["options"];

      var qulityList = options?["qualities"];

      var streamData = pullData["stream_data"]?.toString() ?? "";

      if (!streamData.startsWith('{')) {
        var flvList = (detail.data["flv_pull_url"] as Map).values
            .cast<String>()
            .toList();
        var hlsList = (detail.data["hls_pull_url_map"] as Map).values
            .cast<String>()
            .toList();
        for (var quality in qulityList) {
          int level = quality["level"];
          List<String> urls = [];
          var flvIndex = flvList.length - level;
          if (flvIndex >= 0 && flvIndex < flvList.length) {
            urls.add(flvList[flvIndex]);
          }
          var hlsIndex = hlsList.length - level;
          if (hlsIndex >= 0 && hlsIndex < hlsList.length) {
            urls.add(hlsList[hlsIndex]);
          }
          var qualityItem = LivePlayQuality(
            quality: quality["name"],
            sort: level,
            data: urls,
          );
          if (urls.isNotEmpty) {
            qualities.add(qualityItem);
          }
        }
      } else {
        var qualityData = json.decode(streamData)["data"] as Map;

        for (var quality in qulityList) {
          List<String> urls = [];

          var flvUrl = qualityData[quality["sdk_key"]]?["main"]?["flv"]
              ?.toString();

          if (flvUrl != null && flvUrl.isNotEmpty) {
            urls.add(flvUrl);
          }
          var hlsUrl = qualityData[quality["sdk_key"]]?["main"]?["hls"]
              ?.toString();

          if (hlsUrl != null && hlsUrl.isNotEmpty) {
            urls.add(hlsUrl);
          }

          var qualityItem = LivePlayQuality(
            quality: quality["name"],
            sort: quality["level"],
            data: urls,
          );
          if (urls.isNotEmpty) {
            qualities.add(qualityItem);
          }
        }
      }
    } catch (e, stackTrace) {
      CoreLog.error(e);
      CoreLog.error(stackTrace);
    }
    // var qualityData = json.decode(
    //     detail.data["live_core_sdk_data"]["pull_data"]["stream_data"])["data"];

    qualities.sort((a, b) => b.sort.compareTo(a.sort));
    _logDebug("获取到的画质列表: ${qualities.map((q) => q.quality).toList()}");
    return qualities;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    // 返回列表的副本，防止外部 clear() 影响原始数据
    return LivePlayUrl(urls: List<String>.from(quality.data));
  }

  /// iOS 系统画中画（AVPlayer）用的 HLS 地址
  ///
  /// 直播间数据里每个清晰度都同时有 FLV 和 HLS，取所选清晰度的 HLS（见 [parseDouyinHlsUrls]）；
  /// 取不到时退回清晰度列表里记下的 m3u8 地址
  @override
  Future<LivePlayUrl?> getAvPlayerUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    var urls = parseDouyinHlsUrls(
      detail.data,
      quality: quality.quality,
      level: quality.sort,
    );
    if (urls.isEmpty && quality.data is List) {
      urls = (quality.data as List)
          .map((e) => e.toString())
          .where(isHlsPlayUrl)
          .toList();
    }
    if (urls.isEmpty) {
      return null;
    }
    return LivePlayUrl(urls: urls);
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    String serverUrl = "https://www.douyin.com/aweme/v1/web/live/search/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "device_platform": "webapp",
        "aid": "6383",
        "channel": "channel_pc_web",
        "search_channel": "aweme_live",
        "keyword": keyword,
        "search_source": "switch_tab",
        "query_correct_type": "1",
        "is_filter_search": "0",
        "from_group_id": "",
        "offset": ((page - 1) * 10).toString(),
        "count": "10",
        "pc_client_type": "1",
        "version_code": "170400",
        "version_name": "17.4.0",
        "cookie_enabled": "true",
        "screen_width": "1980",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Edge",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "engine_name": "Blink",
        "engine_version": "125.0.0.0",
        "os_name": "Windows",
        "os_version": "10",
        "cpu_core_num": "12",
        "device_memory": "8",
        "platform": "PC",
        "downlink": "10",
        "effective_type": "4g",
        "round_trip_time": "100",
        "webid": "7382872326016435738",
      },
    );
    //var requlestUrl = await getAbogusUrl(uri.toString());
    var requlestUrl = uri.toString();
    var dyCookie = await _searchCookie();

    var result = await HttpClient.instance.getJson(
      requlestUrl,
      queryParameters: {},
      header: {
        "Authority": 'www.douyin.com',
        'accept': 'application/json, text/plain, */*',
        'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'cookie': dyCookie,
        'priority': 'u=1, i',
        'referer':
            'https://www.douyin.com/search/${Uri.encodeComponent(keyword)}?type=live',
        'sec-ch-ua':
            '"Microsoft Edge";v="125", "Chromium";v="125", "Not.A/Brand";v="24"',
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': '"Windows"',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'same-origin',
        'user-agent': kDefaultUserAgent,
      },
    );
    // 没登录时抖音返回 status_code 2483（“请先登录，再继续搜索吧”），
    // 抛出 LoginRequiredError 提示去登录，不当成没有结果
    var items = parseDouyinLiveSearch(result);
    return LiveSearchRoomResult(hasMore: items.length >= 10, items: items);
  }

  /// 匿名 Cookie 和取到的时间（几分钟内复用，翻页、重搜不用每次 HEAD）
  String _anonymousCookie = "";
  DateTime? _anonymousCookieTime;

  /// 搜索用的 Cookie：用户设置了（登录后的）Cookie 时用它，缺 ttwid 时补上匿名的；
  /// 没有设置时和以前一样，用 HEAD live.douyin.com 拿到的匿名 ttwid、__ac_nonce
  Future<String> _searchCookie() async {
    var user = cookie.trim();
    if (user.isNotEmpty && user.contains("ttwid=")) {
      return user;
    }
    var time = _anonymousCookieTime;
    if (_anonymousCookie.isNotEmpty &&
        time != null &&
        DateTime.now().difference(time) < const Duration(minutes: 5)) {
      return user.isEmpty
          ? _anonymousCookie
          : (user.endsWith(";")
                ? "$user$_anonymousCookie"
                : "$user;$_anonymousCookie");
    }
    var anonymous = "";
    try {
      var headResp = await HttpClient.instance.head(
        'https://live.douyin.com',
        header: headers,
      );
      headResp.headers["set-cookie"]?.forEach((element) {
        var item = element.split(";")[0];
        if (item.contains("ttwid") || item.contains("__ac_nonce")) {
          anonymous += "$item;";
        }
      });
    } catch (e) {
      if (user.isEmpty) rethrow;
    }
    if (anonymous.isNotEmpty) {
      _anonymousCookie = anonymous;
      _anonymousCookieTime = DateTime.now();
    }
    if (user.isEmpty) {
      return anonymous;
    }
    return user.endsWith(";") ? "$user$anonymous" : "$user;$anonymous";
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    throw Exception("抖音暂不支持搜索主播，请直接搜索直播间".t);
  }

  /// 搜索联想：抖音的联想（search/sug）是全站的视频词，搜主播又要登录，所以没有联想；
  /// App 只显示本地匹配（关注、看过）
  @override
  Future<List<LiveSuggestion>> getSearchSuggestions(String keyword) async {
    return [];
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var result = await getRoomDetail(roomId: roomId);
    return result.status;
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) {
    return Future.value(<LiveSuperChatMessage>[]);
  }

  //生成指定长度的16进制随机字符串
  String generateRandomString(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(16));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item.toRadixString(16));
    }
    return stringBuffer.toString();
  }

  // 生成随机的数字
  int generateRandomNumber(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(10));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item);
    }
    return int.tryParse(stringBuffer.toString()) ??
        Random().nextInt(1000000000);
  }
}

/// 从抖音直播间的 stream_url 里取出清晰度 [quality]（等级 [level]）的 HLS 地址
///
/// 对应关系和 [DouyinSite.getPlayQualites] 一样：
/// - live_core_sdk_data.pull_data.stream_data 是 JSON 时，按 options.qualities 里
///   同名清晰度的 sdk_key 取 data[sdk_key].main.hls；
/// - 否则按等级从 hls_pull_url_map 里取（第 length - level 个）。
/// 没有时返回空列表
List<String> parseDouyinHlsUrls(
  dynamic streamUrl, {
  required String quality,
  required int level,
}) {
  if (streamUrl is! Map) {
    return [];
  }
  var urls = <String>[];
  void add(dynamic url) {
    var text = url?.toString().trim() ?? "";
    if (isHlsPlayUrl(text) && !urls.contains(text)) {
      urls.add(text);
    }
  }

  var liveCoreData = streamUrl["live_core_sdk_data"];
  var pullData = liveCoreData is Map ? liveCoreData["pull_data"] : null;
  var streamData = pullData is Map
      ? pullData["stream_data"]?.toString() ?? ""
      : "";
  if (streamData.startsWith("{")) {
    Map? data;
    try {
      var decoded = json.decode(streamData);
      data = decoded is Map && decoded["data"] is Map ? decoded["data"] : null;
    } catch (_) {
      data = null;
    }
    Map? mainOf(Map item) {
      var stream = data?[item["sdk_key"]?.toString()];
      var main = stream is Map ? stream["main"] : null;
      return main is Map ? main : null;
    }

    // HEVC 的 HLS 是 TS 封装，AVPlayer 播不了（HEVC 只能用 fMP4）
    bool hevc(Map item) {
      var codec = item["v_codec"]?.toString() ?? "";
      var params = mainOf(item)?["sdk_params"];
      try {
        var decoded = params is String ? json.decode(params) : params;
        if (decoded is Map) {
          codec = "$codec ${decoded["VCodec"] ?? ""}";
        }
      } catch (_) {}
      codec = codec.toLowerCase();
      return codec.contains("265") ||
          codec.contains("hevc") ||
          codec.contains("bytevc1");
    }

    var options = pullData["options"];
    var qualities = options is Map ? options["qualities"] : null;
    var items = (qualities is List ? qualities : const [])
        .whereType<Map>()
        .toList();
    var matched = items.where((e) => e["name"]?.toString() == quality).toList()
      // 同名时用等级区分
      ..sort(
        (a, b) =>
            (asT<int?>(a["level"]) == level ? 0 : 1) -
            (asT<int?>(b["level"]) == level ? 0 : 1),
      );
    for (var item in matched.where((e) => !hevc(e))) {
      add(mainOf(item)?["hls"]);
    }
    if (urls.isEmpty && matched.isNotEmpty) {
      // 所选清晰度是 HEVC：改用 H.264 里等级最高的
      var h264 = items.where((e) => !hevc(e)).toList()
        ..sort(
          (a, b) => (asT<int?>(b["level"]) ?? 0).compareTo(
            asT<int?>(a["level"]) ?? 0,
          ),
        );
      for (var item in h264) {
        add(mainOf(item)?["hls"]);
        if (urls.isNotEmpty) {
          break;
        }
      }
    }
    return urls;
  }
  var hlsMap = streamUrl["hls_pull_url_map"];
  if (hlsMap is Map) {
    var hlsList = hlsMap.values.toList();
    var index = hlsList.length - level;
    if (index >= 0 && index < hlsList.length) {
      add(hlsList[index]);
    }
  }
  return urls;
}

/// 从抖音直播首页取出分类数组（categoryData）的 JSON 文本，找不到时返回 null。
///
/// 数据在页面脚本的字符串里，多了一层转义（\"、\\），后面紧接着别的组件数据，
/// 位置和结构常变。这里找到 categoryData 后去掉一层转义，再按括号配对截出整个数组
String? douyinCategoryJson(String html) {
  const escapedKey = r'\"categoryData\":';
  const plainKey = '"categoryData":';
  var escaped = true;
  var at = html.indexOf(escapedKey);
  var keyLength = escapedKey.length;
  if (at < 0) {
    escaped = false;
    at = html.indexOf(plainKey);
    keyLength = plainKey.length;
  }
  if (at < 0) {
    return null;
  }
  var start = html.indexOf('[', at + keyLength);
  if (start < 0) {
    return null;
  }
  // 1. 去掉一层转义：\" → "，\\ → \，其它（\n、& 等）原样保留
  var end = min(html.length, start + 2000000);
  var text = html.substring(start, end);
  if (escaped) {
    var out = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      var c = text[i];
      if (c == r'\' && i + 1 < text.length) {
        var next = text[i + 1];
        if (next == '"' || next == r'\') {
          out.write(next);
          i++;
          continue;
        }
      }
      out.write(c);
    }
    text = out.toString();
  }
  // 2. 按括号配对截出整个数组，字符串里的括号不算
  var depth = 0;
  var inString = false;
  for (var i = 0; i < text.length; i++) {
    var c = text[i];
    if (inString) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '[' || c == '{') {
      depth++;
    } else if (c == ']' || c == '}') {
      depth--;
      if (depth == 0) {
        return text.substring(0, i + 1);
      }
    }
  }
  return null;
}

/// 抖音的分类数组（[douyinCategoryJson] 解码后的）转成分类，一层套一层不限层数。
///
/// 每个一级分类的第一项是它自己（看这一类的全部直播），这一项的下一层是一级分类下面的各项，
/// 分类页据此在房间上方显示一排「全部」和下一层
List<LiveCategory> douyinCategories(List<dynamic> data) {
  var categories = <LiveCategory>[];
  for (var item in data) {
    if (item is! Map || item["partition"] is! Map) {
      continue;
    }
    var partition = item["partition"] as Map;
    var id = _douyinPartitionId(partition);
    var name = partition["title"]?.toString() ?? "";
    var subs = _douyinSubCategories(item["sub_partition"], id);
    categories.add(
      LiveCategory(
        id: id,
        name: name,
        children: [
          LiveSubCategory(
            id: id,
            name: name,
            parentId: id,
            pic: _douyinPartitionPic(partition),
            children: subs,
          ),
          ...subs,
        ],
      ),
    );
  }
  return categories;
}

List<LiveSubCategory> _douyinSubCategories(dynamic list, String parentId) {
  if (list is! List) {
    return const [];
  }
  var result = <LiveSubCategory>[];
  for (var item in list) {
    if (item is! Map || item["partition"] is! Map) {
      continue;
    }
    var partition = item["partition"] as Map;
    var id = _douyinPartitionId(partition);
    result.add(
      LiveSubCategory(
        id: id,
        name: partition["title"]?.toString() ?? "",
        parentId: parentId,
        pic: _douyinPartitionPic(partition),
        children: _douyinSubCategories(item["sub_partition"], id),
      ),
    );
  }
  return result;
}

/// 房间列表接口要的是“分类号,类型”
String _douyinPartitionId(Map partition) =>
    '${partition["id_str"]},${partition["type"]}';

/// 抖音给了图标时用它（现在网页数据里没有，留着以后有了能用）；没有时返回空，App 按名字配图标
String _douyinPartitionPic(Map partition) {
  for (var key in const [
    "icon",
    "icon_url",
    "image",
    "image_url",
    "cover",
    "pic",
  ]) {
    var value = partition[key];
    if (value is Map) {
      value = value["url_list"];
    }
    if (value is List && value.isNotEmpty) {
      value = value.first;
    }
    if (value is String &&
        (value.startsWith("http") || value.startsWith("//"))) {
      return value;
    }
  }
  return "";
}

/// 分类（和推荐）的房间列表。抖音访问太频繁时回 444（HTTP 状态码或者 status_code），
/// 这时报 444，App 提示请稍后再试
LiveCategoryResult douyinCategoryRooms(dynamic result) {
  if (result is Map && result["status_code"] == 444) {
    throw CoreError("", statusCode: 444);
  }
  var list = result["data"]["data"] as List;
  var hasMore = list.length >= 15;
  var items = <LiveRoomItem>[];
  for (var item in list) {
    var roomItem = LiveRoomItem(
      roomId: item["web_rid"],
      title: item["room"]["title"].toString(),
      cover: item["room"]["cover"]["url_list"][0].toString(),
      userName: item["room"]["owner"]["nickname"].toString(),
      online:
          int.tryParse(
            item["room"]["room_view_stats"]["display_value"].toString(),
          ) ??
          0,
    );
    items.add(roomItem);
  }
  return LiveCategoryResult(hasMore: hasMore, items: items);
}
