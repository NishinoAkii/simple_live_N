import 'package:simple_live_core/simple_live_core.dart';

/// 录屏接口推送的 JSON 的版本（字段只增不改；改动不兼容时加一）
const int kObsSchemaVersion = 1;

/// 当前直播间
class ObsRoomInfo {
  /// 平台 id（如 bilibili、douyu、js:acfun）
  final String site;

  /// 平台名称（如“哔哩哔哩”）
  final String siteName;
  final String roomId;
  final String title;

  /// 主播名
  final String streamer;
  final String avatar;
  final String cover;

  /// 正在直播（轮播录像也算）
  final bool live;

  /// 轮播录像
  final bool isRecord;

  /// 直播间网页地址
  final String url;

  /// 人气 / 在线人数
  final int online;

  const ObsRoomInfo({
    required this.site,
    required this.roomId,
    this.siteName = "",
    this.title = "",
    this.streamer = "",
    this.avatar = "",
    this.cover = "",
    this.live = false,
    this.isRecord = false,
    this.url = "",
    this.online = 0,
  });

  /// 同一个直播间（平台和房间号相同）
  String get key => "$site|$roomId";

  ObsRoomInfo copyWith({int? online}) => ObsRoomInfo(
        site: site,
        roomId: roomId,
        siteName: siteName,
        title: title,
        streamer: streamer,
        avatar: avatar,
        cover: cover,
        live: live,
        isRecord: isRecord,
        url: url,
        online: online ?? this.online,
      );

  Map<String, dynamic> toJson() => {
        "site": site,
        "siteName": siteName,
        "roomId": roomId,
        "title": title,
        "streamer": streamer,
        "avatar": avatar,
        "cover": cover,
        "live": live,
        "isRecord": isRecord,
        "url": url,
        "online": online,
      };

  /// 备注用的一行说明，如“哔哩哔哩 6 标题 - 主播”
  String get label {
    var parts = [
      siteName.isEmpty ? site : siteName,
      roomId,
      if (title.isNotEmpty) title,
      if (streamer.isNotEmpty) "- $streamer",
    ];
    return parts.join(" ");
  }
}

/// 录屏接口的事件 JSON。每个事件都有：
/// - `v`：版本 [kObsSchemaVersion]
/// - `type`：chat / superchat / online / room / clear
/// - `time`：时间（Unix 毫秒）
///
/// chat、superchat 还有 `id`（本次开启接口以来递增）、`site`、`roomId`。
class ObsEvents {
  ObsEvents._();

  static Map<String, dynamic> emote(LiveEmote e) => {
        "text": e.text,
        "url": e.url,
        "width": e.width,
        "height": e.height,
      };

  static List<Map<String, dynamic>> _emotes(List<LiveEmote>? emotes) =>
      (emotes ?? const <LiveEmote>[])
          .where((e) => e.url.isNotEmpty)
          .map(emote)
          .toList();

  /// 聊天：
  /// `{"v":1,"type":"chat","id":1,"time":1730000000000,"site":"bilibili",
  /// "roomId":"6","user":"名字","text":"你好[doge]","color":"#ffffff",
  /// "face":null,"emotes":[{"text":"[doge]","url":"https://…","width":0,"height":0}],
  /// "sticker":null}`
  static Map<String, dynamic> chat(
    LiveMessage msg, {
    required int id,
    required int time,
    required String site,
    required String roomId,
  }) {
    var face = msg.face;
    var sticker = msg.sticker;
    return {
      "v": kObsSchemaVersion,
      "type": "chat",
      "id": id,
      "time": time,
      "site": site,
      "roomId": roomId,
      "user": msg.userName,
      "text": msg.message,
      "color": msg.color.toString(),
      "face": face == null || face.isEmpty ? null : face,
      "emotes": _emotes(msg.emotes),
      "sticker": sticker == null || sticker.url.isEmpty ? null : emote(sticker),
    };
  }

  /// 醒目留言：`price` 为人民币金额（境外平台为 0 或换算值），
  /// `priceText` 为显示用的金额（如“￥30”“$5.00”），`start`/`end` 为显示的起止时间（Unix 毫秒），
  /// `color`/`colorBottom` 为卡片上下两部分的背景色
  static Map<String, dynamic> superChat(
    LiveSuperChatMessage sc, {
    required int id,
    required int time,
    required String site,
    required String roomId,
  }) {
    var sticker = sc.sticker;
    return {
      "v": kObsSchemaVersion,
      "type": "superchat",
      "id": id,
      "time": time,
      "site": site,
      "roomId": roomId,
      "scId": sc.id,
      "user": sc.userName,
      "face": sc.face.isEmpty ? null : sc.face,
      "text": sc.message,
      "price": sc.price,
      "priceText": sc.priceText ?? "￥${sc.price}",
      "start": sc.startTime.millisecondsSinceEpoch,
      "end": sc.endTime.millisecondsSinceEpoch,
      "color": cssColor(sc.backgroundColor) ?? "#edf5ff",
      "colorBottom": cssColor(sc.backgroundBottomColor) ?? "#2a60b2",
      "emotes": _emotes(sc.emotes),
      "sticker": sticker == null || sticker.url.isEmpty ? null : emote(sticker),
    };
  }

  /// 人气 / 在线人数
  static Map<String, dynamic> online(
    int online, {
    required int time,
    required String site,
    required String roomId,
  }) =>
      {
        "v": kObsSchemaVersion,
        "type": "online",
        "time": time,
        "site": site,
        "roomId": roomId,
        "online": online,
      };

  /// 当前直播间（关闭直播间时 room 为 null）
  static Map<String, dynamic> room(ObsRoomInfo? room, {required int time}) => {
        "v": kObsSchemaVersion,
        "type": "room",
        "time": time,
        "room": room?.toJson(),
      };

  /// 换了直播间（或关闭了），页面清掉已显示的内容
  static Map<String, dynamic> clear({required int time}) => {
        "v": kObsSchemaVersion,
        "type": "clear",
        "time": time,
      };

  /// 平台给的颜色（“#EDF5FF”“EDF5FF”“FFEDF5FF”）转成 CSS 的 #rrggbb，无法识别时为 null
  static String? cssColor(String? value) {
    var hex = (value ?? "").trim().replaceAll("#", "");
    if (hex.length == 8) {
      hex = hex.substring(2);
    }
    if (hex.length == 4) {
      hex = "00$hex";
    }
    if (hex.length != 6 || int.tryParse(hex, radix: 16) == null) {
      return null;
    }
    return "#${hex.toLowerCase()}";
  }
}
