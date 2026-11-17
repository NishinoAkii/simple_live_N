import 'dart:async';

import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 搜索框里的文字可能就是房间号：和搜索同时试着打开，成功时在结果最上面放一张“直达”卡片
/// （不自动跳转，数字也可能就是想搜的关键词）
class SearchDirectResult {
  final LiveRoomDetail detail;

  /// 卡片上的说明，如“房间号 21852”“UID 546195 的直播间”
  final String label;

  SearchDirectResult(this.detail, this.label);

  String get roomId => detail.roomId;
}

final RegExp _digits = RegExp(r"^\d{1,12}$");
final RegExp _vanity = RegExp(r"^[A-Za-z][A-Za-z0-9_]{2,29}$");
final RegExp _douyinId = RegExp(r"^(\d{11,12}|\d{19})$");
final RegExp _twitchLogin = RegExp(r"^[A-Za-z0-9_]{3,25}$");
final RegExp _kickSlug = RegExp(r"^[A-Za-z0-9_-]{3,25}$");

/// 输入在这个平台上像不像房间号（或 login、slug）；像的话返回要试的房间号，不像返回 null
///
/// - 哔哩哔哩：纯数字（房间号，含短号；打不开时再当 UID 试）
/// - 斗鱼、虎牙：纯数字，或字母开头的靓号、房间名
/// - 抖音：11～12 位 web_rid 或 19 位 room_id
/// - Twitch：login（字母数字下划线 3～25 位）；Kick：slug（另可带连字符）
/// - YouTube 的 @名称、频道 ID 在搜索前已经直接打开，这里不试；直播源要实现 resolve
String? searchDirectInput(String siteId, String input) {
  var s = input.trim();
  if (s.isEmpty || s.length > 40) return null;
  switch (siteId) {
    case Constant.kBiliBili:
      return _digits.hasMatch(s) ? s : null;
    case Constant.kDouyu:
    case Constant.kHuya:
      return _digits.hasMatch(s) || _vanity.hasMatch(s) ? s : null;
    case Constant.kDouyin:
      return _douyinId.hasMatch(s) ? s : null;
    case Constant.kTwitch:
      return _twitchLogin.hasMatch(s) ? s.toLowerCase() : null;
    case Constant.kKick:
      return _kickSlug.hasMatch(s) ? s.toLowerCase() : null;
  }
  return null;
}

/// 试着按房间号打开；打不开（不存在、出错、超时）时返回 null，不提示
///
/// 直播源要实现可选的 resolve(input)（[resolve] 默认用它），由脚本把输入换成房间号；
/// 没有时不试（不拿任意关键词调用 room()）
Future<SearchDirectResult?> resolveSearchDirect(
  Site site,
  String input, {
  Duration timeout = const Duration(seconds: 10),
  Future<String?> Function(String input)? resolve,
}) async {
  var liveSite = site.liveSite;
  var script = site.script;
  if (resolve == null && script != null && script.hasResolve) {
    resolve = script.resolveRoomId;
  }
  // 自带平台的直播源修正替换了 resolve：用脚本认，出错时（允许的话）用下面的内置规则
  if (resolve == null &&
      liveSite is OverridableLiveSite &&
      liveSite.isOverridden("resolve")) {
    OverridableLiveSite overridable = liveSite;
    resolve = (text) => overridable.overrideResolveRoomId(
          text,
          (t) async => searchDirectInput(site.id, t),
        );
  }
  String? roomId;
  if (resolve != null) {
    var text = input.trim();
    if (text.isEmpty || text.length > 100) return null;
    try {
      roomId = await resolve(text).timeout(timeout);
    } catch (_) {
      return null;
    }
  } else {
    roomId = searchDirectInput(site.id, input);
  }
  if (roomId == null || roomId.isEmpty) return null;
  Future<LiveRoomDetail?> open(String id) async {
    try {
      var detail = await liveSite.getRoomDetail(roomId: id).timeout(timeout);
      if (detail.roomId.isEmpty && detail.userName.isEmpty) return null;
      return detail;
    } catch (_) {
      return null;
    }
  }

  var detail = await open(roomId);
  if (detail != null) {
    var label = switch (site.id) {
      Constant.kTwitch || Constant.kKick => "频道 {roomId}".tf({"roomId": roomId}),
      _ => "房间号 {roomId}".tf({"roomId": roomId}),
    };
    return SearchDirectResult(detail, label);
  }
  // 哔哩哔哩的纯数字也可能是 UID
  if (liveSite is BiliBiliSite) {
    try {
      var room = await liveSite.getRoomIdByUid(roomId).timeout(timeout);
      if (room != null) {
        detail = await open(room);
        if (detail != null) {
          return SearchDirectResult(detail, "UID {roomId} 的直播间".tf({"roomId": roomId}));
        }
      }
    } catch (_) {}
  }
  return null;
}
