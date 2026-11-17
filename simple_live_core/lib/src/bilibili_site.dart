import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/src/account_follows/bilibili_account_follows.dart';
import 'package:simple_live_core/src/bilibili_rank.dart';
import 'package:simple_live_core/src/common/bili_web.dart';
import 'package:simple_live_core/src/common/convert_helper.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/room_area.dart';
import 'package:simple_live_core/src/common/room_notice.dart';
import 'package:simple_live_core/src/common/search_parser.dart';
import 'package:simple_live_core/src/danmaku/bilibili_danmaku.dart';
import 'package:simple_live_core/src/danmaku/bilibili_room_stats.dart';
import 'package:simple_live_core/src/danmaku/bilibili_voice_room.dart';
import 'package:simple_live_core/src/model/live_voice_room.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_search_all_site.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_category.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_search_result.dart';
import 'package:simple_live_core/src/model/live_suggestion.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_category_result.dart';
import 'package:simple_live_core/src/common/core_text.dart';

class BiliBiliSite
    with
        BiliBiliAccountFollows,
        BiliBiliRank
    implements LiveSite, LiveSearchAllSite {
  @override
  String id = "bilibili";

  @override
  String name = "哔哩哔哩直播";

  @override
  String cookie = "";
  @override
  int userId = 0;

  /// 登录的账号是不是有效的大会员，由 [loadVipStatus] 读取（App 在登录和启动时调用）。
  bool vipActive = false;

  @override
  LiveDanmaku getDanmaku() => BiliBiliDanmaku(site: this);

  String buvid3 = "";
  String buvid4 = "";
  String accessId = "";

  /// 网页端的 LIVE_BUVID（Cookie）：直播接口第一次返回时设下，之后浏览器每次都带上。
  /// 登录 Cookie 里有就用它，没有时用 App 保存的（[savedLiveBuvid]，由 App 生成一次后一直沿用）
  String savedLiveBuvid = "";
  String get liveBuvid =>
      RegExp(r"(?:^|;\s*)LIVE_BUVID=([^;]+)").firstMatch(cookie)?.group(1) ??
      savedLiveBuvid;
  @override
  Future<Map<String, String>> getHeader() async {
    if (buvid3.isEmpty) {
      var buvidInfo = await getBuvid();
      buvid3 = buvidInfo["b_3"] ?? "";
      buvid4 = buvidInfo["b_4"] ?? "";
    }
    // 和网页端一样：同一个浏览器身份，登录时带上登录 Cookie（见 BiliWeb），
    // 浏览器有的 LIVE_BUVID 也带上
    var jar = cookie.isEmpty
        ? 'buvid3=$buvid3;buvid4=$buvid4;'
        : cookie.contains("buvid3")
        ? cookie
        : "$cookie;buvid3=$buvid3;buvid4=$buvid4;";
    if (savedLiveBuvid.isNotEmpty && !jar.contains("LIVE_BUVID=")) {
      jar = "${jar.endsWith(";") ? jar : "$jar;"}LIVE_BUVID=$savedLiveBuvid;";
    }
    return BiliWeb.apiHeaders(cookie: jar);
  }

  /// 账号关注请求用的 Cookie：登录 Cookie 里缺 buvid 时补上（见 [getHeader]）
  @override
  Future<String> biliCommentCookie() async => (await getHeader())["cookie"]!;

  @override
  Future<List<LiveCategory>> getCategores() async {
    List<LiveCategory> categories = [];
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/room/v1/Area/getList",
      queryParameters: {"need_entrance": 1, "parent_id": 0},
      header: await getHeader(),
    );
    for (var item in result["data"]) {
      List<LiveSubCategory> subs = [];
      for (var subItem in item["list"]) {
        var subCategory = LiveSubCategory(
          id: subItem["id"].toString(),
          name: asT<String?>(subItem["name"]) ?? "",
          parentId: asT<String?>(subItem["parent_id"]) ?? "",
          pic: "${asT<String?>(subItem["pic"]) ?? ""}@100w.png",
        );
        subs.add(subCategory);
      }
      var category = LiveCategory(
        children: subs,
        id: item["id"].toString(),
        name: asT<String?>(item["name"]) ?? "",
      );
      categories.add(category);
    }
    return categories;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    const baseUrl =
        "https://api.live.bilibili.com/xlive/web-interface/v1/second/getList";

    var url =
        "$baseUrl?platform=web&parent_area_id=${category.parentId}&area_id=${category.id}&sort_type=&page=$page&w_webid=${await getAccessId()}";

    var queryParams = await getWbiSign(url);

    var result = await HttpClient.instance.getJson(
      baseUrl,
      queryParameters: queryParams,
      header: await getHeader(),
    );

    var hasMore = result["data"]["has_more"] == 1;
    var items = <LiveRoomItem>[];
    for (var item in result["data"]["list"]) {
      var roomItem = LiveRoomItem(
        roomId: item["roomid"].toString(),
        title: item["title"].toString(),
        cover: "${item["cover"]}@400w.jpg",
        userName: item["uname"].toString(),
        online: int.tryParse(item["online"].toString()) ?? 0,
      );
      items.add(roomItem);
    }
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  /// 网页端直播间页面的 spm_prefix，接口参数 web_location 用它
  static const String kWebLocation = "444.8";

  /// 进房时直播间页面里带的播放信息（roomInitRes），按真实房间号存。
  /// 网页端第一次播放用页面里的这份，切换清晰度或重新加载时才调 getRoomPlayInfo；
  /// 这里也只用一次。地址约 1 小时过期，超过 50 分钟就不再用
  final Map<String, (DateTime, Map)> _pagePlayInfo = {};

  Map? _pagePlay(String roomId) {
    var entry = _pagePlayInfo[roomId];
    if (entry == null) {
      return null;
    }
    if (DateTime.now().difference(entry.$1) > const Duration(minutes: 50)) {
      _pagePlayInfo.remove(roomId);
      return null;
    }
    return entry.$2;
  }

  /// getRoomPlayInfo：参数与网页端播放器重新加载时一致（WBI 签名）
  Future<Map> _roomPlayInfo(String roomId, {Object qn = 0}) async {
    const url =
        "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo";
    var query = await getWbiSign(
      "$url?room_id=$roomId&protocol=0,1&format=0,1,2&codec=0,1,2&qn=$qn"
      "&platform=web&ptype=8&dolby=5&panorama=1&eotf=0,1,2&req_reason=0"
      "&supported_drms=0,1,2,3&web_location=$kWebLocation",
    );
    var result = await HttpClient.instance.getJson(
      url,
      queryParameters: query,
      header: await getHeader(),
    );
    if (result is Map && result["code"] != null && result["code"] != 0) {
      throw CoreError(
        result["message"]?.toString() ??
            "读取播放地址失败({result})".tf({"result": result["code"]}),
      );
    }
    var data = result is Map ? result["data"] : null;
    return data is Map ? data : const {};
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    var data = _pagePlay(detail.roomId);
    if (data == null) {
      data = await _roomPlayInfo(detail.roomId);
      // 接下来按默认清晰度播放时可以直接用这份，不用再请求一次
      _pagePlayInfo[detail.roomId] = (DateTime.now(), data);
    }
    return parseBiliQualities(data);
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    var cached = _pagePlay(detail.roomId);
    _pagePlayInfo.remove(detail.roomId);
    var data = cached != null && biliPlayInfoHasQn(cached, quality.data)
        ? cached
        : await _roomPlayInfo(detail.roomId, qn: quality.data);
    return LivePlayUrl(urls: parseBiliPlayUrls(data), headers: kPlayHeaders);
  }

  /// 播放直播流时带的请求头（mpv 和 AVPlayer 一样），与接口请求同一个浏览器身份
  static Map<String, String> get kPlayHeaders => BiliWeb.playHeaders();

  /// iOS 系统画中画（AVPlayer）用的 HLS 地址
  ///
  /// 同一接口（参数同网页端），只取 http_hls、H.264（HEVC 在 AVPlayer 里会黑屏），
  /// 清晰度和所选的一样；fMP4 在前、TS 在后，见 [parseBiliLiveHlsUrls]。
  /// 地址约 58 分钟过期，过期后 App 会重新读取
  @override
  Future<LivePlayUrl?> getAvPlayerUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    // 请求和网页端播放器一样，从返回的全部线路里挑 HLS、H.264
    var data = await _roomPlayInfo(detail.roomId, qn: quality.data);
    var urls = parseBiliLiveHlsUrls(data);
    if (urls.isEmpty) {
      return null;
    }
    return LivePlayUrl(urls: urls, headers: kPlayHeaders);
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    const baseUrl =
        "https://api.live.bilibili.com/xlive/web-interface/v1/second/getListByArea";
    var url = "$baseUrl?platform=web&sort=online&page_size=30&page=$page";

    var queryParams = await getWbiSign(url);

    var result = await HttpClient.instance.getJson(
      baseUrl,
      queryParameters: queryParams,
      header: await getHeader(),
    );

    var hasMore = (result["data"]["list"] as List).isNotEmpty;
    var items = <LiveRoomItem>[];
    for (var item in result["data"]["list"]) {
      var roomItem = LiveRoomItem(
        roomId: item["roomid"].toString(),
        title: item["title"].toString(),
        cover: "${item["cover"]}@400w.jpg",
        userName: item["uname"].toString(),
        online: int.tryParse(item["online"].toString()) ?? 0,
      );
      items.add(roomItem);
    }
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  /// 登录 Cookie 里的账号（DedeUserID）。弹幕认证包的 uid 必须和取弹幕 token 的账号一致
  int get cookieUid =>
      int.tryParse(
        RegExp(r"(?:^|;\s*)DedeUserID=(\d+)").firstMatch(cookie)?.group(1) ??
            "",
      ) ??
      0;

  /// 打开直播间页面，取出页面里的房间信息和播放信息（网页端进房时这两份都不另调接口）。
  /// 页面打不开或格式变了时返回 null，改用接口
  Future<BiliRoomPage?> _loadRoomPage(String roomId) async {
    try {
      var html = await HttpClient.instance.getText(
        "https://live.bilibili.com/$roomId",
        header: BiliWeb.pageHeaders(cookie: (await getHeader())["cookie"] ?? ""),
      );
      return parseBiliRoomPage(html);
    } catch (e) {
      CoreLog.error(e);
      return null;
    }
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    var page = await _loadRoomPage(roomId);
    var roomInfo = page != null
        ? Map<String, dynamic>.from(page.info)
        : await getRoomInfo(roomId: roomId);
    var realRoomId = roomInfo["room_info"]["room_id"].toString();
    if (page?.play != null) {
      _pagePlayInfo[realRoomId] = (DateTime.now(), page!.play!);
    }

    const danmuInfoBaseUrl =
        "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo";
    var danmuInfoUrl =
        "$danmuInfoBaseUrl?id=$realRoomId&type=0&web_location=$kWebLocation";
    var queryParams = await getWbiSign(danmuInfoUrl);
    var roomDanmakuResult = await HttpClient.instance.getJson(
      danmuInfoBaseUrl,
      queryParameters: queryParams,
      header: await getHeader(),
    );
    List<String> serverHosts = (roomDanmakuResult["data"]["host_list"] as List)
        .map<String>((e) => e["host"].toString())
        .toList();

    //var buvid = await getBuvid();
    // 从 roomInfo 中提取 live_start_time
    String? liveStartTime = roomInfo["room_info"]?["live_start_time"]
        ?.toString();

    // 计算开播时长并打印到控制台 (参考斗鱼的实现)
    if (liveStartTime != null &&
        liveStartTime.isNotEmpty &&
        liveStartTime != "0") {
      // 检查是否为0，0可能表示未开播或无此信息
      try {
        int startTimeStamp = int.parse(liveStartTime);
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        print('Bilibili直播间 $roomId 开播时长: $formattedDuration');
      } catch (e) {
        print('计算 Bilibili 开播时长出错: $e');
      }
    }

    return LiveRoomDetail(
      roomId: realRoomId,
      title: roomInfo["room_info"]["title"].toString(),
      cover: roomInfo["room_info"]["cover"].toString(),
      userName: roomInfo["anchor_info"]["base_info"]["uname"].toString(),
      userAvatar: "${roomInfo["anchor_info"]["base_info"]["face"]}@100w.jpg",
      online: asT<int?>(roomInfo["room_info"]["online"]) ?? 0,
      status: (asT<int?>(roomInfo["room_info"]["live_status"]) ?? 0) == 1,
      url: "https://live.bilibili.com/$roomId",
      introduction: roomInfo["room_info"]["description"].toString(),
      // 主播公告就在房间信息里（news_info），不用另外请求
      notice: parseBiliRoomNews(roomInfo),
      danmakuData: BiliBiliDanmakuArgs(
        roomId: int.tryParse(realRoomId) ?? 0,
        uid: cookie.isEmpty ? 0 : (cookieUid > 0 ? cookieUid : userId),
        token: roomDanmakuResult["data"]["token"].toString(),
        serverHost: serverHosts.isNotEmpty
            ? serverHosts.first
            : "broadcastlv.chat.bilibili.com",
        buvid: buvid3,
        // 浏览器连弹幕服务器时带着全部 .bilibili.com 的 Cookie（含 buvid3）
        cookie: (await getHeader())["cookie"] ?? cookie,
        anchorUid: asT<int?>(roomInfo["room_info"]["uid"]) ?? 0,
        parentAreaId: asT<int?>(roomInfo["room_info"]["parent_area_id"]) ?? 0,
        areaId: asT<int?>(roomInfo["room_info"]["area_id"]) ?? 0,
      ),
      showTime: liveStartTime, // 将 liveStartTime 赋值给 showTime 字段
      stats: BiliRoomStats.fromRoomInfo(roomInfo),
      voiceRoom: BiliVoiceRoom.fromRoomInfo(roomInfo),
      area: LiveRoomArea.bilibili(roomInfo),
    );
  }

  /// 语聊房现在的房主和麦位（重新读一次房间信息）；不是语聊房时为 null。
  /// 麦位变化没有单独的推送，App 隔一会儿调一次
  Future<LiveVoiceRoom?> getVoiceRoom(String roomId) async =>
      BiliVoiceRoom.fromRoomInfo(await getRoomInfo(roomId: roomId));

  @override
  Future<Map<String, dynamic>> getRoomInfo({required String roomId}) async {
    var url =
        "https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom"
        "?room_id=$roomId&web_location=$kWebLocation";
    var queryParams = await getWbiSign(url);
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom",
      queryParameters: queryParams,
      header: await getHeader(),
    );
    print("【B站接口返回】roomId=$roomId, result=$result");
    return result["data"];
  }

  /// 搜索接口（非 wbi 版，带 buvid3 匿名可用）
  Future<dynamic> _search(String type, String keyword, int page) async {
    return await HttpClient.instance.getJson(
      "https://api.bilibili.com/x/web-interface/search/type?context=&search_type=$type&cover_type=user_cover",
      queryParameters: {
        "order": "",
        "keyword": keyword,
        "category_id": "",
        "__refresh__": "",
        "_extra": "",
        "highlight": 0,
        "single_column": 0,
        "page": page,
      },
      header: await getHeader(),
    );
  }

  /// 只有在播的直播间；分页看 data.pageinfo.live_room.numPages
  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    var result = await _search("live", keyword, page);
    return parseBiliRoomSearch(result, page);
  }

  /// 有直播间的用户，包括未开播的；每页 30 个，分页看 data.numPages
  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    var result = await _search("live_user", keyword, page);
    return parseBiliAnchorSearch(result, page);
  }

  /// 综合搜索：search_type=live 一次就有在播的直播间和主播（每页约 6 个，含未开播）
  @override
  Future<LiveSearchAllResult> searchAll(String keyword, {int page = 1}) async {
    var result = await _search("live", keyword, page);
    return parseBiliLiveSearch(result, page);
  }

  /// 用户 UID 对应的直播间号，没有开通直播间时返回 null
  Future<String?> getRoomIdByUid(String uid) async {
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/room/v1/Room/getRoomInfoOld",
      queryParameters: {"mid": uid},
      header: await getHeader(),
    );
    return parseBiliRoomIdByUid(result);
  }

  /// 搜索联想：只要主播。全站联想词（main/suggest）大多是视频词，不用；
  /// 改成主播搜索（live_user，包括未开播的）的前 5 个。和搜索用同一个接口，
  /// 请求太频繁会 -412，App 输入时要放慢（防抖更久、每秒最多一次）
  @override
  Future<List<LiveSuggestion>> getSearchSuggestions(String keyword) async {
    var result = await _search("live_user", keyword, 1);
    return anchorSuggestions(parseBiliAnchorSearch(result, 1).items);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/room/v1/Room/get_info",
      queryParameters: {"room_id": roomId},
      header: await getHeader(),
    );
    return (asT<int?>(result["data"]["live_status"]) ?? 0) == 1;
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) async {
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/av/v1/SuperChat/getMessageList",
      queryParameters: {"room_id": roomId},
      header: await getHeader(),
    );
    List<LiveSuperChatMessage> ls = [];
    for (var item in result["data"]?["list"] ?? []) {
      var message = LiveSuperChatMessage(
        id: item["id"]?.toString(),
        backgroundBottomColor: item["background_bottom_color"].toString(),
        backgroundColor: item["background_color"].toString(),
        endTime: DateTime.fromMillisecondsSinceEpoch(item["end_time"] * 1000),
        face: "${item["user_info"]["face"]}@200w.jpg",
        message: item["message"].toString(),
        price: item["price"],
        startTime: DateTime.fromMillisecondsSinceEpoch(
          item["start_time"] * 1000,
        ),
        userName: item["user_info"]["uname"].toString(),
        userId: liveUserId(item["uid"]),
      );
      ls.add(message);
    }
    return ls;
  }

  /// 获取 buvid3 和 buvid4
  /// 返回buvid3和buvid4
  /// ``` json
  /// {
  ///   "b_3": "buvid3",
  ///   "b_4": "buvid4",
  /// }
  /// ```
  Future<Map> getBuvid() async {
    try {
      if (cookie.contains("buvid3")) {
        return {
          "b_3": RegExp(r"buvid3=(.*?);").firstMatch(cookie)?.group(1) ?? "",
          "b_4": RegExp(r"buvid4=(.*?);").firstMatch(cookie)?.group(1) ?? "",
        };
      }

      var result = await HttpClient.instance.getJson(
        "https://api.bilibili.com/x/frontend/finger/spi",
        queryParameters: {},
        header: BiliWeb.apiHeaders(cookie: cookie),
      );
      return result["data"];
    } catch (e) {
      return {"b_3": "", "b_4": ""};
    }
  }

  static String kImgKey = '';
  static String kSubKey = '';
  static const List<int> mixinKeyEncTab = [
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
    37,
    48,
    7,
    16,
    24,
    55,
    40,
    61,
    26,
    17,
    0,
    1,
    60,
    51,
    30,
    4,
    22,
    25,
    54,
    21,
    56,
    59,
    6,
    63,
    57,
    62,
    11,
    36,
    20,
    34,
    44,
    52,
  ];
  Future<(String, String)> getWbiKeys() async {
    if (kImgKey.isNotEmpty && kSubKey.isNotEmpty) {
      return (kImgKey, kSubKey);
    }
    // 获取最新的 img_key 和 sub_key
    var resp = await HttpClient.instance.getJson(
      'https://api.bilibili.com/x/web-interface/nav',
      header: await getHeader(),
    );
    // 带着登录 Cookie 时顺便更新大会员状态
    if (cookie.isNotEmpty) {
      vipActive = parseBiliNavVip(resp);
    }

    var imgUrl = resp["data"]["wbi_img"]["img_url"].toString();
    var subUrl = resp["data"]["wbi_img"]["sub_url"].toString();
    var imgKey = imgUrl.substring(imgUrl.lastIndexOf('/') + 1).split('.').first;
    var subKey = subUrl.substring(subUrl.lastIndexOf('/') + 1).split('.').first;

    kImgKey = imgKey;
    kSubKey = subKey;

    return (imgKey, subKey);
  }

  /// 读取登录账号的大会员状态（x/web-interface/nav），结果同时写入 [vipActive]。
  /// 没登录时为 false，不发请求
  Future<bool> loadVipStatus() async {
    if (cookie.isEmpty) {
      vipActive = false;
      return false;
    }
    var resp = await HttpClient.instance.getJson(
      'https://api.bilibili.com/x/web-interface/nav',
      header: await getHeader(),
    );
    vipActive = parseBiliNavVip(resp);
    return vipActive;
  }

  String getMixinKey(String origin) {
    // 对 imgKey 和 subKey 进行字符顺序打乱编码
    return mixinKeyEncTab.fold("", (s, i) => s + origin[i]).substring(0, 32);
  }

  Future<Map<String, String>> getWbiSign(String url) async {
    var (imgKey, subKey) = await getWbiKeys();

    // 为请求参数进行 wbi 签名
    var mixinKey = getMixinKey(imgKey + subKey);
    var currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    var queryParams = Map<String, String>.from(Uri.parse(url).queryParameters);

    queryParams["wts"] = currentTime.toString(); // 添加 wts 字段

    //按照 key 重排参数
    Map<String, String> map = {};
    var sortedKeys = queryParams.keys.toList()..sort();
    for (var key in sortedKeys) {
      var value = queryParams[key]!;
      // 过滤 value 中的 "!'()*" 字符
      map[key] = value
          .toString()
          .split('')
          .where((c) => "!'()*".contains(c) == false)
          .join('');
    }

    var query = map.keys
        .map((key) => "$key=${Uri.encodeQueryComponent(map[key]!)}")
        .join("&");
    var wbiSign = md5.convert(utf8.encode("$query$mixinKey")).toString();
    queryParams["w_rid"] = wbiSign;
    return queryParams;
  }

  /// 登录 Cookie 中的 csrf（bili_jct）
  String get csrf =>
      RegExp(r"bili_jct=([^;]+)").firstMatch(cookie)?.group(1) ?? "";

  Future<String> getAccessId() async {
    if (accessId.isNotEmpty) {
      return accessId;
    }

    // 获取 access_id
    var resp = await HttpClient.instance.getText(
      "https://live.bilibili.com/lol",
      queryParameters: {},
      header: await getHeader(),
    );
    var id = RegExp(
      r'"access_id":"(.*?)"',
    ).firstMatch(resp)?.group(1)?.replaceAll("\\", "");
    accessId = id ?? "";
    return accessId;
  }
}

/// 直播间页面里的两份数据：[info] 与 getInfoByRoom 的 data 相同，
/// [play] 与 getRoomPlayInfo 的 data 相同（没开播时可能没有）
class BiliRoomPage {
  final Map info;
  final Map? play;
  const BiliRoomPage(this.info, this.play);
}

/// 解析直播间页面里的 `window.__NEPTUNE_IS_MY_WAIFU__ = {...}`
/// （roomInfoRes、roomInitRes）。房间信息缺失或格式不对时返回 null
BiliRoomPage? parseBiliRoomPage(String html) {
  var start = html.indexOf("window.__NEPTUNE_IS_MY_WAIFU__");
  if (start < 0) {
    return null;
  }
  var brace = html.indexOf("{", start);
  var end = brace < 0 ? -1 : html.indexOf("</script>", brace);
  if (end < 0) {
    return null;
  }
  var text = html.substring(brace, end).trim();
  if (text.endsWith(";")) {
    text = text.substring(0, text.length - 1);
  }
  dynamic obj;
  try {
    obj = json.decode(text);
  } catch (_) {
    return null;
  }
  Map? dataOf(dynamic res) =>
      res is Map && res["code"] == 0 && res["data"] is Map ? res["data"] : null;
  var info = obj is Map ? dataOf(obj["roomInfoRes"]) : null;
  if (info == null || info["room_info"] is! Map) {
    return null;
  }
  var play = dataOf(obj["roomInitRes"]);
  return BiliRoomPage(info, play?["playurl_info"] is Map ? play : null);
}

List<Map> _biliMaps(dynamic value) =>
    value is List ? value.whereType<Map>().toList() : const [];

/// getRoomPlayInfo 的 codec 列表（按 stream、format 的顺序）
Iterable<(String, String, Map)> _biliCodecs(dynamic data) sync* {
  var playurlInfo = data is Map ? data["playurl_info"] : null;
  var playurl = playurlInfo is Map ? playurlInfo["playurl"] : null;
  for (var stream in _biliMaps(playurl is Map ? playurl["stream"] : null)) {
    for (var format in _biliMaps(stream["format"])) {
      for (var codec in _biliMaps(format["codec"])) {
        yield (
          stream["protocol_name"]?.toString() ?? "",
          format["format_name"]?.toString() ?? "",
          codec,
        );
      }
    }
  }
}

/// 可选清晰度：名称取 g_qn_desc，列表取第一个 H.264 编码的 accept_qn（没有 H.264 时取第一个编码）
List<LivePlayQuality> parseBiliQualities(dynamic data) {
  var playurlInfo = data is Map ? data["playurl_info"] : null;
  var playurl = playurlInfo is Map ? playurlInfo["playurl"] : null;
  var names = <int, String>{};
  for (var item in _biliMaps(playurl is Map ? playurl["g_qn_desc"] : null)) {
    names[int.tryParse(item["qn"].toString()) ?? 0] = item["desc"].toString();
  }
  var codecs = _biliCodecs(data).map((e) => e.$3).toList();
  var codec = codecs.firstWhere(
    (e) => e["codec_name"] == "avc",
    orElse: () => codecs.isEmpty ? const {} : codecs.first,
  );
  var accept = codec["accept_qn"];
  return [
    for (var qn in accept is List ? accept : const [])
      LivePlayQuality(quality: names[qn] ?? "未知清晰度", data: qn),
  ];
}

/// 播放地址：只取 FLV 和 fMP4 格式的 H.264（与以前只请求 format=0,2、codec=0 时相同），
/// 每路为 url_info.host + base_url + url_info.extra，mcdn 线路排在后面
List<String> parseBiliPlayUrls(dynamic data) {
  var urls = <String>[];
  for (var (_, format, codec) in _biliCodecs(data)) {
    if (codec["codec_name"] != "avc" || (format != "flv" && format != "fmp4")) {
      continue;
    }
    var baseUrl = codec["base_url"]?.toString() ?? "";
    for (var info in _biliMaps(codec["url_info"])) {
      var url = "${info["host"] ?? ""}$baseUrl${info["extra"] ?? ""}";
      if (baseUrl.isNotEmpty && url.startsWith("http") && !urls.contains(url)) {
        urls.add(url);
      }
    }
  }
  return [
    ...urls.where((e) => !e.contains("mcdn")),
    ...urls.where((e) => e.contains("mcdn")),
  ];
}

/// 这份播放信息里的地址是不是 [qn] 这个清晰度的（看 H.264 编码的 current_qn）
bool biliPlayInfoHasQn(dynamic data, Object? qn) => _biliCodecs(data).any(
  (e) => e.$3["codec_name"] == "avc" && "${e.$3["current_qn"]}" == "$qn",
);

/// 从直播间 getRoomPlayInfo 返回的 data 里取出 AVPlayer 能播的 HLS 地址
///
/// 只看 http_hls 协议、H.264（avc）编码：fMP4 格式在前，TS 在后；
/// 每路地址为 url_info.host + base_url + url_info.extra，同一格式里 mcdn 线路排在后面。
/// 没开播或没有 HLS 时返回空列表
List<String> parseBiliLiveHlsUrls(dynamic data) {
  List maps(dynamic value) =>
      value is List ? value.whereType<Map>().toList() : const [];
  var playurlInfo = data is Map ? data["playurl_info"] : null;
  var playurl = playurlInfo is Map ? playurlInfo["playurl"] : null;
  var byFormat = <String, List<String>>{"fmp4": [], "ts": []};
  for (var stream in maps(playurl is Map ? playurl["stream"] : null)) {
    var protocol = stream["protocol_name"]?.toString() ?? "";
    if (protocol.isNotEmpty && protocol != "http_hls") {
      continue;
    }
    for (var format in maps(stream["format"])) {
      var urls = byFormat[format["format_name"]?.toString()];
      if (urls == null) {
        continue;
      }
      for (var codec in maps(format["codec"])) {
        if (codec["codec_name"] != "avc") {
          continue;
        }
        var baseUrl = codec["base_url"]?.toString() ?? "";
        for (var info in maps(codec["url_info"])) {
          if (baseUrl.isEmpty) {
            continue;
          }
          var url = "${info["host"] ?? ""}$baseUrl${info["extra"] ?? ""}";
          if (url.startsWith("http") && !urls.contains(url)) {
            urls.add(url);
          }
        }
      }
    }
  }
  List<String> mcdnLast(List<String> urls) => [
    ...urls.where((e) => !e.contains("mcdn")),
    ...urls.where((e) => e.contains("mcdn")),
  ];
  return [...mcdnLast(byFormat["fmp4"]!), ...mcdnLast(byFormat["ts"]!)];
}

/// 从 x/web-interface/nav 的返回判断是不是有效的大会员
///
/// 要求已登录（isLogin），会员开通状态为 1（vipStatus，新字段 vip.status），
/// 会员类型不为 0（vipType / vip.type：1 月度、2 年度及以上）；
/// 到期时间（vipDueDate / vip.due_date，毫秒）已过时也算无效。
/// 未登录时接口返回 code -101，data 里只有 isLogin=false 和 wbi_img。
bool parseBiliNavVip(dynamic resp, {DateTime? now}) {
  var data = resp is Map ? resp["data"] : null;
  if (data is! Map || data["isLogin"] != true) {
    return false;
  }
  var vip = data["vip"] is Map ? data["vip"] as Map : const {};
  int value(dynamic v) => v is num ? v.toInt() : int.tryParse("$v") ?? 0;
  var status = value(data["vipStatus"] ?? vip["status"]);
  var type = value(data["vipType"] ?? vip["type"]);
  if (status != 1 || type == 0) {
    return false;
  }
  var due = value(data["vipDueDate"] ?? vip["due_date"]);
  // 个别字段（如 tv_due_date）是秒，按数量级兼容
  if (due > 0 && due < 100000000000) {
    due *= 1000;
  }
  var nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  return due <= 0 || due > nowMs;
}
