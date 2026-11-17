import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/src/account_follows/douyu_account_follows.dart';
import 'package:simple_live_core/src/common/avplayer_url.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/room_area.dart';
import 'package:simple_live_core/src/common/search_parser.dart';
import 'package:simple_live_core/src/danmaku/douyu_danmaku.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_rank_site.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_rank.dart';
import 'package:simple_live_core/src/rank_parsers.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_text.dart';
import 'package:simple_live_core/src/model/live_category.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_search_result.dart';
import 'package:simple_live_core/src/model/live_suggestion.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_category_result.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:simple_live_core/src/scripts/douyu_sign.dart';

class DouyuSite with DouyuAccountFollows implements LiveSite, LiveRankSite {
  @override
  String id = "douyu";

  @override
  String name = "斗鱼直播";

  /// 登录 Cookie（扫码登录后经 safeAuth 换取，含 acf_uid、acf_ltkid、acf_stk 等），
  /// 用于读写账号关注
  @override
  String cookie = "";

  /// 登录时使用的设备号（dy_did），与登录凭据绑定
  String deviceId = "";

  /// 登录 Cookie 过期时的续期回调，返回新的 Cookie，失败返回 null
  @override
  Future<String?> Function()? onCookieExpired;

  @override
  LiveDanmaku getDanmaku() => DouyuDanmaku(site: this);

  @override
  Future<List<LiveCategory>> getCategores() async {
    List<LiveCategory> categories = [];
    var result = await HttpClient.instance.getJson(
      "https://m.douyu.com/api/cate/list",
    );
    var subCateList = result["data"]["cate2Info"] as List;
    for (var item in result["data"]["cate1Info"]) {
      var cate1Id = item["cate1Id"];
      var cate1Name = item["cate1Name"];
      List<LiveSubCategory> subCategories = [];
      subCateList.where((x) => x["cate1Id"] == cate1Id).forEach((element) {
        subCategories.add(
          LiveSubCategory(
            pic: element["icon"],
            id: element["cate2Id"].toString(),
            parentId: cate1Id.toString(),
            name: element["cate2Name"].toString(),
          ),
        );
      });
      categories.add(
        LiveCategory(
          id: cate1Id.toString(),
          name: cate1Name.toString(),
          children: subCategories,
        ),
      );
    }
    // 根据ID排序
    categories.sort((a, b) => int.parse(a.id).compareTo(int.parse(b.id)));

    return categories;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/gapi/rkc/directory/mixList/2_${category.id}/$page",
      queryParameters: {},
    );

    var items = <LiveRoomItem>[];
    for (var item in result['data']['rl']) {
      if (item["type"] != 1) {
        continue;
      }
      var roomItem = LiveRoomItem(
        cover: item['rs16'].toString(),
        online: item['ol'],
        roomId: item['rid'].toString(),
        title: item['rn'].toString(),
        userName: item['nn'].toString(),
      );
      items.add(roomItem);
    }
    var hasMore = page < result['data']['pgcnt'];
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    var data = detail.data.toString();
    data += "&cdn=&rate=-1&ver=Douyu_223061205&iar=1&ive=1&hevc=0&fa=0";
    List<LivePlayQuality> qualities = [];
    var result = await HttpClient.instance.postJson(
      "https://www.douyu.com/lapi/live/getH5Play/${detail.roomId}",
      data: data,
      formUrlEncoded: true,
    );

    var cdns = <String>[];
    for (var item in result["data"]["cdnsWithName"]) {
      cdns.add(item["cdn"].toString());
    }

    // 如果cdn以scdn开头，将其放到最后
    cdns.sort((a, b) {
      if (a.startsWith("scdn") && !b.startsWith("scdn")) {
        return 1;
      } else if (!a.startsWith("scdn") && b.startsWith("scdn")) {
        return -1;
      }
      return 0;
    });

    for (var item in result["data"]["multirates"]) {
      qualities.add(
        LivePlayQuality(
          quality: item["name"].toString(),
          data: DouyuPlayData(item["rate"], cdns),
        ),
      );
    }
    return qualities;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    var args = detail.data.toString();
    var data = quality.data as DouyuPlayData;

    List<String> urls = [];
    for (var item in data.cdns) {
      var url = await getPlayUrl(detail.roomId, args, data.rate, item);
      if (url.isNotEmpty) {
        urls.add(url);
      }
    }
    return LivePlayUrl(urls: urls);
  }

  Future<String> getPlayUrl(
    String roomId,
    String args,
    int rate,
    String cdn,
  ) async {
    args += "&cdn=$cdn&rate=$rate";
    var result = await HttpClient.instance.postJson(
      "https://www.douyu.com/lapi/live/getH5Play/$roomId",
      data: args,
      header: {
        'referer': 'https://www.douyu.com/$roomId',
        'user-agent':
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43",
      },
      formUrlEncoded: true,
    );

    return "${result["data"]["rtmp_url"]}/${HtmlUnescape().convert(result["data"]["rtmp_live"].toString())}";
  }

  /// 手机网页（iPhone Safari）的 User-Agent，斗鱼手机网页接口和它给的 HLS 地址都用这个
  static const String kMobileUserAgent =
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

  /// iOS 系统画中画（AVPlayer）用的 HLS 地址
  ///
  /// 网页端接口（getH5Play）只给 FLV；手机网页（m.douyu.com）的取流接口给 HLS
  /// （H.264 + AAC，3 秒一片）。HLS 最高约 720P，原画只有 FLV：
  /// 按所选清晰度请求，接口给哪一档就播哪一档。
  @override
  Future<LivePlayUrl?> getAvPlayerUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    var rate = quality.data is DouyuPlayData
        ? (quality.data as DouyuPlayData).rate
        : -1;
    var roomId = detail.roomId;
    var referer = "https://m.douyu.com/$roomId";
    // 参数放在查询串里，请求体为空（和手机网页一致）
    var result = await HttpClient.instance.postJson(
      "https://m.douyu.com/api/room/ratestream?${detail.data}&ver=219032101&rid=$roomId&rate=$rate",
      header: {'referer': referer, 'user-agent': kMobileUserAgent},
      formUrlEncoded: true,
    );
    var url = parseDouyuRateStream(result);
    if (url == null) {
      return null;
    }
    return LivePlayUrl(
      urls: [url],
      headers: {'referer': referer, 'user-agent': kMobileUserAgent},
    );
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/weblist/apinc/allpage/6/$page",
      queryParameters: {},
    );

    var items = <LiveRoomItem>[];
    for (var item in result['data']['rl']) {
      if (item["type"] != 1) {
        continue;
      }
      var roomItem = LiveRoomItem(
        cover: item['rs16'].toString(),
        online: item['ol'],
        roomId: item['rid'].toString(),
        title: item['rn'].toString(),
        userName: item['nn'].toString(),
      );
      items.add(roomItem);
    }
    var hasMore = page < result['data']['pgcnt'];
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    Map roomInfo = await _getRoomInfo(roomId);

    Map h5RoomInfo = await HttpClient.instance.getJson(
      "https://www.douyu.com/swf_api/h5room/$roomId",
      queryParameters: {},
      header: {
        'referer': 'https://www.douyu.com/$roomId',
        'user-agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43',
      },
    );
    String? showTime = h5RoomInfo["data"]?["show_time"]?.toString();

    var jsEncResult = await HttpClient.instance.getText(
      "https://www.douyu.com/swf_api/homeH5Enc?rids=$roomId",
      queryParameters: {},
      header: {
        'referer': 'https://www.douyu.com/$roomId',
        'user-agent':
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43",
      },
    );
    var crptext = json.decode(jsEncResult)["data"]["room$roomId"].toString();

    if (showTime != null && showTime.isNotEmpty) {
      try {
        int startTimeStamp = int.parse(showTime);
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        print('斗鱼直播间 $roomId 开播时长: $formattedDuration');
      } catch (e) {
        print('计算开播时长出错: $e');
      }
    }

    return LiveRoomDetail(
      cover: roomInfo["room_pic"].toString(),
      online: int.tryParse(roomInfo["room_biz_all"]["hot"].toString()) ?? 0,
      roomId: roomInfo["room_id"].toString(),
      title: roomInfo["room_name"].toString(),
      userName: roomInfo["owner_name"].toString(),
      userAvatar: roomInfo["owner_avatar"].toString(),
      introduction: roomInfo["show_details"].toString(),
      notice: "",
      status: roomInfo["show_status"] == 1 && roomInfo["videoLoop"] != 1,
      danmakuData: roomInfo["room_id"].toString(),
      data: DouyuSign.getSign(crptext, roomInfo["room_id"].toString()),
      url: "https://www.douyu.com/$roomId",
      isRecord: roomInfo["videoLoop"] == 1,
      showTime: showTime,
      area: LiveRoomArea.douyu(roomInfo, h5RoomInfo["data"]),
    );
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    var did = generateRandomString(32);
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/search/api/searchShow",
      queryParameters: {"kw": keyword, "page": page, "pageSize": 20},
      header: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.51',
        'referer': 'https://www.douyu.com/search/',
        'Cookie': 'dy_did=$did;acf_did=$did',
      },
    );
    if (result['error'] != 0) {
      throw Exception(result['msg']);
    }
    var items = <LiveRoomItem>[];
    var list = (result["data"]?["relateShow"] as List?) ?? const [];
    for (var item in list) {
      var roomItem = LiveRoomItem(
        roomId: item["rid"].toString(),
        title: item["roomName"].toString(),
        cover: item["roomSrc"].toString(),
        userName: item["nickName"].toString(),
        online: parseHotNum(item["hot"].toString()),
      );
      items.add(roomItem);
    }
    var total = int.tryParse(result["data"]?["total"]?.toString() ?? "") ?? 0;
    var hasMore = total > 0 ? page * 20 < total : list.isNotEmpty;
    return LiveSearchRoomResult(hasMore: hasMore, items: items);
  }

  Future<Map> _getRoomInfo(String roomId) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/betard/$roomId",
      queryParameters: {},
      header: {
        'referer': 'https://www.douyu.com/$roomId',
        'user-agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43',
      },
    );
    Map roomInfo;
    if (result is String) {
      roomInfo = json.decode(result)["room"];
    } else {
      roomInfo = result["room"];
    }
    return roomInfo;
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

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    var did = generateRandomString(32);
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/search/api/searchUser",
      queryParameters: {
        "kw": keyword,
        "page": page,
        "pageSize": 20,
        "filterType": 1,
      },
      header: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.51',
        'referer': 'https://www.douyu.com/search/',
        'Cookie': 'dy_did=$did;acf_did=$did',
      },
    );

    // isLoop 为 1 显示“轮播”，isLive 为 1 是直播中（和网页一样，不看 roomType）；
    // 不是主播的项没有 anchorInfo，跳过
    return parseDouyuAnchorSearch(result, page, 20);
  }

  /// 搜索联想：主播卡片（含未开播，可以直接打开）和分类等词；不支持拼音首字母
  @override
  Future<List<LiveSuggestion>> getSearchSuggestions(String keyword) async {
    var did = generateRandomString(32);
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/search/api/getSearchRecV2",
      queryParameters: {"kw": keyword},
      header: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.51',
        'referer': 'https://www.douyu.com/search/',
        'Cookie': 'dy_did=$did;acf_did=$did',
      },
    );
    return parseDouyuSuggestions(result);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var roomInfo = await _getRoomInfo(roomId);
    return roomInfo["show_status"] == 1 && roomInfo["videoLoop"] != 1;
  }

  int parseHotNum(String hn) {
    try {
      var num = double.parse(hn.replaceAll("万", ""));
      if (hn.contains("万")) {
        num *= 10000;
      }
      return num.round();
    } catch (_) {
      return -999;
    }
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) {
    //尚不支持
    return Future.value([]);
  }

  @override
  List<LiveRankBoard> get rankBoards => kDouyuRankBoards;

  /// 亲密榜（粉丝团页的接口，没有公开文档）
  @override
  Future<LiveRankList> getRank(
    String boardId, {
    required LiveRoomDetail detail,
  }) async {
    if (boardId != "intimacy") {
      throw CoreError("不支持这个榜单".t);
    }
    var roomId = detail.roomId;
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/interact/comm/fanshome/rank/top10",
      queryParameters: {"rid": roomId},
      header: {
        'referer': 'https://www.douyu.com/$roomId',
        'user-agent':
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43",
      },
    );
    return parseDouyuIntimacyRank(result);
  }
}

class DouyuPlayData {
  final int rate;
  final List<String> cdns;
  DouyuPlayData(this.rate, this.cdns);
}

/// 解析手机网页取流接口（m.douyu.com/api/room/ratestream）的返回，得到 HLS 地址
///
/// 返回形如 `{code: 0, data: {url: "http://openhls-....m3u8?...", settings: [...], rate: 0}}`；
/// code 不为 0（未开播、签名过期等）或没有 m3u8 地址时返回 null
String? parseDouyuRateStream(dynamic result) {
  if (result is String) {
    try {
      result = json.decode(result);
    } catch (_) {
      return null;
    }
  }
  if (result is! Map || result["code"]?.toString() != "0") {
    return null;
  }
  var data = result["data"];
  var url = data is Map ? data["url"]?.toString().trim() ?? "" : "";
  url = url.replaceAll("&amp;", "&");
  return isHlsPlayUrl(url) ? url : null;
}
