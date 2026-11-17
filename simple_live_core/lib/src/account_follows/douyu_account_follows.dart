import 'dart:math';

import 'package:simple_live_core/src/common/account_follow_http.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/douyu_login.dart';
import 'package:simple_live_core/src/interface/live_account_follow_site.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 斗鱼：账号关注列表与关注/取关
///
/// - 读：`wgapi/livenc/liveweb/follow/list?sort=1&cid1=0&page=N`，只靠主站 Cookie，
///   返回 data.list、data.pageCount、data.total（DouyuEx FollowList.js、Sign_Room.js）；
///   开播判断为 show_status==1 且 videoLoop==0（videoLoop==1 是录播轮播）；
/// - 写：`follow/add`、`follow/rm`，表单 `ctn=<acf_ccn>&rid=<房间号>`（DouyuEx Sign_Follow.js）。
///   ctn 是“双提交”式校验：表单里的值和 Cookie 里的 acf_ccn 相同即可，没有时自己生成一个；
/// - 返回格式和错误码没有公开资料：error 为 0 算成功，其它一律停止；
///   -1（未登录或令牌过期）时先续期 Cookie 再试一次。
mixin DouyuAccountFollows implements LiveAccountFollowSite {
  /// 登录 Cookie（DouyuSite.cookie）
  String get cookie;

  /// 登录 Cookie 过期时的续期回调（DouyuSite.onCookieExpired）
  Future<String?> Function()? get onCookieExpired;

  static const String _ua =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

  /// 本次运行用的 acf_ccn（Cookie 里没有时生成）
  String _ccn = "";

  String get _followUid => DouyuCookie.read(cookie, "acf_uid");

  @override
  bool get canReadAccountFollows => cookie.isNotEmpty;

  @override
  String get accountFollowOwner => _followUid;

  @override
  bool get canWriteAccountFollows => cookie.isNotEmpty;

  @override
  AccountFollowPolicy get accountFollowPolicy => const AccountFollowPolicy(
    pageInterval: Duration(milliseconds: 500),
    writeIntervalMin: Duration(seconds: 3),
    writeIntervalMax: Duration(seconds: 6),
    batchLimit: 20,
    maxPages: 200,
    needsRoomResolve: true,
  );

  /// Cookie 过期（JWT 的 exp 已过）时先续期
  Future<void> _renewIfExpired() async {
    var renew = onCookieExpired;
    if (renew != null && DouyuCookie.expired(cookie)) {
      await renew();
    }
  }

  /// 发一次请求；返回 -1（未登录或令牌过期）时续期后重试一次
  Future<dynamic> _request(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? Function()? body,
    bool write = false,
  }) async {
    // 只剩续期凭据（Cookie 为空或过期）时先续期
    await _renewIfExpired();
    if (cookie.isEmpty) {
      throw AccountFollowAuthError("请先登录斗鱼账号".t);
    }
    for (var attempt = 0; ; attempt++) {
      var response = await AccountFollowHttp.send(
        method,
        url,
        headers: {
          ...headers,
          "Cookie": write ? _cookieWithCcn() : cookie,
          "User-Agent": _ua,
          "Referer": "https://www.douyu.com/",
          "Origin": "https://www.douyu.com",
          "X-Requested-With": "XMLHttpRequest",
        },
        body: body?.call(),
      );
      if (response.statusCode == 403 || response.statusCode == 429) {
        throw AccountFollowRiskError("斗鱼拒绝了请求({statusCode})".tf({"statusCode": response.statusCode}));
      }
      if (response.statusCode != 200) {
        throw CoreError("", statusCode: response.statusCode);
      }
      var json = response.json;
      if (isDouyuNotLogin(json) && attempt == 0 && onCookieExpired != null) {
        var renewed = await onCookieExpired!();
        if (renewed != null && renewed.isNotEmpty) {
          continue;
        }
      }
      return json;
    }
  }

  String get _ccnValue {
    var existing = DouyuCookie.read(cookie, "acf_ccn");
    if (existing.isNotEmpty) {
      return existing;
    }
    if (_ccn.isEmpty) {
      var random = Random.secure();
      _ccn = List.generate(
        32,
        (_) => random.nextInt(16).toRadixString(16),
      ).join();
    }
    return _ccn;
  }

  String _cookieWithCcn() =>
      DouyuCookie.merge(cookie, "acf_ccn=$_ccnValue");

  @override
  Future<AccountFollowPage> getAccountFollows({String? cursor}) async {
    var page = int.tryParse(cursor ?? "") ?? 1;
    var json = await _request(
      "GET",
      Uri.https("www.douyu.com", "/wgapi/livenc/liveweb/follow/list", {
        "sort": "1",
        "cid1": "0",
        "page": "$page",
      }),
    );
    return parseDouyuFollowList(json, page);
  }

  @override
  Future<AccountFollowTarget> resolveAccountFollowTarget(String roomId) async {
    // 靓号要换成真实房间号（betard 接口，匿名）
    var response = await AccountFollowHttp.send(
      "GET",
      Uri.https("www.douyu.com", "/betard/$roomId"),
      headers: {"User-Agent": _ua, "Referer": "https://www.douyu.com/$roomId"},
    );
    if (response.statusCode != 200) {
      throw CoreError("", statusCode: response.statusCode);
    }
    var json = response.json;
    var room = json is Map ? json["room"] : null;
    var rid = room is Map ? room["room_id"]?.toString() ?? "" : "";
    if (rid.isEmpty || rid == "0") {
      throw AccountFollowRejectedError("没有找到斗鱼直播间 {roomId}".tf({"roomId": roomId}));
    }
    return AccountFollowTarget(roomId: roomId, accountUid: rid);
  }

  @override
  Future<void> followOnAccount(AccountFollowTarget target) =>
      _write(target, follow: true);

  @override
  Future<void> unfollowOnAccount(AccountFollowTarget target) =>
      _write(target, follow: false);

  Future<void> _write(
    AccountFollowTarget target, {
    required bool follow,
  }) async {
    var rid = target.accountUid.isNotEmpty ? target.accountUid : target.roomId;
    if (int.tryParse(rid) == null) {
      throw AccountFollowRejectedError("斗鱼房间号不对：{rid}".tf({"rid": rid}));
    }
    var json = await _request(
      "POST",
      Uri.https(
        "www.douyu.com",
        "/wgapi/livenc/liveweb/follow/${follow ? "add" : "rm"}",
      ),
      headers: {"Content-Type": "application/x-www-form-urlencoded"},
      body: () => AccountFollowHttp.form({"ctn": _ccnValue, "rid": rid}),
      write: true,
    );
    checkDouyuFollowWrite(json, follow: follow);
  }
}

/// 斗鱼返回的 error（有的接口用 code），读不到时为 null
int? _douyuError(dynamic json) {
  if (json is! Map) {
    return null;
  }
  var value = json["error"] ?? json["code"];
  return value is num ? value.toInt() : int.tryParse("$value");
}

/// 未登录或令牌已过期（error/code 为 -1）
bool isDouyuNotLogin(dynamic json) => _douyuError(json) == -1;

/// 解析一页关注列表，[page] 从 1 开始，读到 pageCount 为止
AccountFollowPage parseDouyuFollowList(dynamic json, int page) {
  var error = _douyuError(json);
  if (error == -1) {
    throw AccountFollowAuthError("斗鱼登录已失效，请重新扫码登录".t);
  }
  if (error != 0) {
    var msg = json is Map ? json["msg"]?.toString() ?? "" : "";
    throw CoreError(msg.isEmpty ? "读取斗鱼关注失败({error})".tf({"error": error}) : "读取斗鱼关注失败：{msg}".tf({"msg": msg}));
  }
  var data = json["data"];
  var list = data is Map && data["list"] is List
      ? data["list"] as List
      : const [];
  var items = <AccountFollowItem>[];
  for (var item in list.whereType<Map>()) {
    var rid = item["room_id"]?.toString() ?? "";
    if (rid.isEmpty || rid == "0") {
      continue;
    }
    items.add(
      AccountFollowItem(
        roomId: rid,
        accountUid: rid,
        userName: item["nickname"]?.toString() ?? rid,
        face: item["avatar_small"]?.toString() ?? "",
        isLive:
            item["show_status"]?.toString() == "1" &&
            item["videoLoop"]?.toString() != "1",
      ),
    );
  }
  var pageCount = data is Map ? int.tryParse("${data["pageCount"]}") ?? 0 : 0;
  var hasMore = page < pageCount && list.isNotEmpty;
  return AccountFollowPage(
    items: items,
    nextCursor: hasMore ? "${page + 1}" : null,
    total: data is Map ? int.tryParse("${data["total"]}") : null,
    // 还没到最后一页却是空的：可能没读完，不能当作完整列表
    truncatedReason: page < pageCount && list.isEmpty
        ? "第 {page} 页是空的，可能没读完".tf({"page": page})
        : null,
  );
}

/// 检查关注/取关的返回：error 为 0 才算成功；没有资料的其它错误码一律当作风控，整批停止
void checkDouyuFollowWrite(dynamic json, {required bool follow}) {
  var error = _douyuError(json);
  if (error == 0) {
    return;
  }
  if (error == -1) {
    throw AccountFollowAuthError("斗鱼登录已失效，请重新扫码登录".t);
  }
  var msg = json is Map ? json["msg"]?.toString() ?? "" : "";
  var action = follow ? "关注##verb".t : "取消关注##verb".t;
  throw AccountFollowRiskError(
    msg.isEmpty ? "斗鱼{action}失败({error})，已暂停同步".tf({"action": action, "error": error}) : "斗鱼{action}失败：{msg}".tf({"action": action, "msg": msg}),
  );
}
