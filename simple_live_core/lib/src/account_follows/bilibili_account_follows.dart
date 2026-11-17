import 'dart:convert';

import 'package:simple_live_core/src/common/account_follow_http.dart';
import 'package:simple_live_core/src/common/bili_web.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/interface/live_account_follow_site.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 哔哩哔哩：账号关注的主播（带直播间号）与关注/取关
///
/// - 读：`xlive/web-ucenter/user/following`，每页最多 10 个，只列出开过播的 UP，
///   返回真实房间号 roomid 和主播 uid（文档：bilibili-API-collect docs/live/follow_up_live.md）；
/// - 写：`x/relation/modify`，act=1 关注、2 取关，csrf 为 Cookie 里的 bili_jct，
///   附加参数与网页端（PiliPlus relationMod）一致；
/// - 不用批量接口 `x/relation/batch/modify`，批量最容易触发风控。
mixin BiliBiliAccountFollows implements LiveAccountFollowSite {
  /// 登录 Cookie（BiliBiliSite.cookie）
  String get cookie;

  /// 登录账号的 UID（BiliBiliSite.userId），没读到账号信息时为 0
  int get userId;

  /// 请求用的 Cookie：缺 buvid 时补上（BiliBiliSite）
  Future<String> biliCommentCookie();

  /// 与直播间其他请求同一个浏览器身份（BiliWeb）
  static String get _ua => BiliWeb.userAgent();

  String get _followCsrf =>
      RegExp(r"bili_jct=([^;]+)").firstMatch(cookie)?.group(1)?.trim() ?? "";

  @override
  bool get canReadAccountFollows => cookie.isNotEmpty;

  @override
  String get accountFollowOwner => userId > 0 ? "$userId" : "";

  @override
  bool get canWriteAccountFollows =>
      cookie.isNotEmpty && _followCsrf.isNotEmpty;

  @override
  AccountFollowPolicy get accountFollowPolicy => const AccountFollowPolicy(
    pageInterval: Duration(milliseconds: 400),
    writeIntervalMin: Duration(seconds: 3),
    writeIntervalMax: Duration(seconds: 6),
    batchLimit: 20,
    maxPages: 300,
    needsRoomResolve: true,
  );

  @override
  Future<AccountFollowPage> getAccountFollows({String? cursor}) async {
    if (!canReadAccountFollows) {
      throw AccountFollowAuthError("请先登录哔哩哔哩账号".t);
    }
    var page = int.tryParse(cursor ?? "") ?? 1;
    var url = Uri.https(
      "api.live.bilibili.com",
      "/xlive/web-ucenter/user/following",
      {
        "page": "$page",
        "page_size": "10",
        "ignoreRecord": "1",
        "hit_ab": "true",
      },
    );
    var response = await AccountFollowHttp.send(
      "GET",
      url,
      headers: BiliWeb.apiHeaders(cookie: await biliCommentCookie()),
    );
    checkBiliHttpStatus(response.statusCode);
    return parseBiliLiveFollowings(response.json, page);
  }

  @override
  Future<AccountFollowTarget> resolveAccountFollowTarget(String roomId) async {
    // 匿名接口，短号也能查，返回主播 uid 和真实房间号
    var response = await AccountFollowHttp.send(
      "GET",
      Uri.https("api.live.bilibili.com", "/room/v1/Room/get_info", {
        "room_id": roomId,
      }),
      headers: BiliWeb.apiHeaders(),
    );
    checkBiliHttpStatus(response.statusCode);
    return parseBiliRoomTarget(response.json, roomId);
  }

  @override
  Future<void> followOnAccount(AccountFollowTarget target) =>
      _modify(target, follow: true);

  @override
  Future<void> unfollowOnAccount(AccountFollowTarget target) =>
      _modify(target, follow: false);

  Future<void> _modify(
    AccountFollowTarget target, {
    required bool follow,
  }) async {
    if (!canWriteAccountFollows) {
      throw AccountFollowAuthError("请先登录哔哩哔哩账号".t);
    }
    var mid = target.accountUid;
    if (int.tryParse(mid) == null) {
      throw AccountFollowRejectedError("没有找到主播的 UID".t);
    }
    var url = Uri.https("api.bilibili.com", "/x/relation/modify", {
      "statistics": '{"appId":100,"platform":5}',
      "x-bili-device-req-json":
          '{"platform":"web","device":"pc","spmid":"333.1387"}',
    });
    var response = await AccountFollowHttp.send(
      "POST",
      url,
      headers: {
        "Cookie": await biliCommentCookie(),
        "User-Agent": _ua,
        "Content-Type": "application/x-www-form-urlencoded",
        "Origin": "https://space.bilibili.com",
        "Referer": "https://space.bilibili.com/$mid/dynamic",
      },
      body: AccountFollowHttp.form({
        "fid": mid,
        "act": follow ? "1" : "2",
        "re_src": "11",
        "gaia_source": "web_main",
        "spmid": "333.1387",
        "extend_content": jsonEncode({
          "entity": "user",
          "entity_id": int.parse(mid),
          "fp": _ua,
        }),
        "csrf": _followCsrf,
      }),
    );
    checkBiliHttpStatus(response.statusCode);
    checkBiliRelationModify(response.json, follow: follow);
  }
}

/// 哔哩哔哩风控类的返回码：整批停止
const Set<int> kBiliFollowRiskCodes = {-352, -412, -509, -799, 22009};

/// 登录失效类：-101 未登录、-102 账号被封停、-111 csrf 校验失败
const Set<int> kBiliFollowAuthCodes = {-101, -102, -111};

/// 这一条不能关注：不能对自己操作、对方隐私设置、在黑名单、账号已注销、用户不存在
const Set<int> kBiliFollowRejectCodes = {22001, 22002, 22003, 22013, 40061};

/// HTTP 状态：412 是风控拦截，其余非 200 当作普通错误
void checkBiliHttpStatus(int statusCode) {
  if (statusCode == 412) {
    throw AccountFollowRiskError("哔哩哔哩提示请求太频繁(412)".t);
  }
  if (statusCode != 200) {
    throw CoreError("", statusCode: statusCode);
  }
}

/// 把哔哩哔哩的返回码转成对应的错误；0 时什么也不做
void _throwBiliCode(dynamic json, String fallback) {
  if (json is! Map) {
    throw CoreError(fallback);
  }
  var code = (json["code"] as num?)?.toInt() ?? -1;
  if (code == 0) {
    return;
  }
  var message = (json["message"] ?? json["msg"] ?? "").toString();
  var text = message.isEmpty || message == "$code"
      ? "$fallback($code)"
      : "$message($code)";
  if (kBiliFollowRiskCodes.contains(code)) {
    throw AccountFollowRiskError("哔哩哔哩风控：{text}".tf({"text": text}));
  }
  if (kBiliFollowAuthCodes.contains(code)) {
    throw AccountFollowAuthError(
      code == -101 ? "哔哩哔哩登录已失效，请重新登录".t : "哔哩哔哩：{text}".tf({"text": text}),
    );
  }
  if (kBiliFollowRejectCodes.contains(code)) {
    throw AccountFollowRejectedError(text);
  }
  throw CoreError(text);
}

/// 解析一页“关注的主播”（xlive/web-ucenter/user/following）
///
/// 没开过播的 UP 不在列表里（never_lived_count），正好不需要。
/// [page] 从 1 开始，读到 totalPage 为止
AccountFollowPage parseBiliLiveFollowings(dynamic json, int page) {
  _throwBiliCode(json, "读取关注失败".t);
  var data = json["data"];
  if (data is! Map) {
    throw CoreError("读取关注失败：返回内容不对".t);
  }
  var list = data["list"] is List ? data["list"] as List : const [];
  var items = <AccountFollowItem>[];
  for (var item in list.whereType<Map>()) {
    var roomId = item["roomid"]?.toString() ?? "";
    var uid = item["uid"]?.toString() ?? "";
    if (roomId.isEmpty || roomId == "0") {
      continue;
    }
    var face = item["face"]?.toString() ?? "";
    items.add(
      AccountFollowItem(
        roomId: roomId,
        accountUid: uid,
        userName: item["uname"]?.toString() ?? roomId,
        face: face.isEmpty ? "" : "$face@100w.jpg",
        isLive: (item["live_status"] as num?)?.toInt() == 1,
      ),
    );
  }
  var totalPage = (data["totalPage"] as num?)?.toInt() ?? 0;
  var hasMore = page < totalPage && list.isNotEmpty;
  return AccountFollowPage(
    items: items,
    nextCursor: hasMore ? "${page + 1}" : null,
    total: (data["count"] as num?)?.toInt(),
    // 还没到最后一页却是空的：可能没读完，不能当作完整列表
    truncatedReason: page < totalPage && list.isEmpty
        ? "第 {page} 页是空的，可能没读完".tf({"page": page})
        : null,
  );
}

/// 解析 room/v1/Room/get_info：主播 uid 与真实房间号
AccountFollowTarget parseBiliRoomTarget(dynamic json, String roomId) {
  _throwBiliCode(json, "读取直播间信息失败".t);
  var data = json["data"];
  var uid = data is Map ? data["uid"]?.toString() ?? "" : "";
  var realRoomId = data is Map ? data["room_id"]?.toString() ?? "" : "";
  if (uid.isEmpty || uid == "0") {
    throw AccountFollowRejectedError("没有找到直播间 {roomId} 的主播".tf({"roomId": roomId}));
  }
  return AccountFollowTarget(
    roomId: realRoomId.isEmpty || realRoomId == "0" ? roomId : realRoomId,
    accountUid: uid,
  );
}

/// 检查关注/取关（x/relation/modify）的返回。22014（已经关注）当作关注成功
void checkBiliRelationModify(dynamic json, {required bool follow}) {
  var code = json is Map ? (json["code"] as num?)?.toInt() : null;
  if (follow && code == 22014) {
    return;
  }
  _throwBiliCode(json, follow ? "关注失败".t : "取消关注失败".t);
}
