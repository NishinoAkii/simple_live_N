import 'package:simple_live_core/src/model/live_message.dart';

/// 语聊房（多人语音聊天室）里的一个麦位
class LiveVoiceSeat {
  /// 麦位号：0 是房主，1 起是嘉宾麦
  final int position;
  final String uid;
  final String name;

  /// 头像地址，没有时为空
  final String avatar;

  /// 房主（房主麦）
  final bool host;

  /// 闭麦了
  final bool muted;

  /// 平台给的魅力值，已经是显示用的文字（如“1455”）；没有时为空
  final String score;

  /// PK 时所在的队，没有 PK 时为空
  final String team;

  const LiveVoiceSeat({
    required this.position,
    required this.uid,
    required this.name,
    this.avatar = "",
    this.host = false,
    this.muted = false,
    this.score = "",
    this.team = "",
  });

  @override
  bool operator ==(Object other) =>
      other is LiveVoiceSeat &&
      other.position == position &&
      other.uid == uid &&
      other.name == name &&
      other.avatar == avatar &&
      other.host == host &&
      other.muted == muted &&
      other.score == score &&
      other.team == team;

  @override
  int get hashCode =>
      Object.hash(position, uid, name, avatar, host, muted, score, team);

  @override
  String toString() => "LiveVoiceSeat($position $name${muted ? " muted" : ""})";
}

/// 语聊房 PK 时一队的分数
class LiveVoiceTeam {
  final String id;
  final String score;
  const LiveVoiceTeam(this.id, this.score);

  @override
  bool operator ==(Object other) =>
      other is LiveVoiceTeam && other.id == id && other.score == score;

  @override
  int get hashCode => Object.hash(id, score);
}

/// 语聊房：直播画面只是平台合成的低清截图（房主卡片加一圈麦位头像），
/// App 改用这里的数据自己画。房主麦和嘉宾麦都在 [seats] 里，空着的麦位不在
class LiveVoiceRoom {
  /// 已经有人的麦位，按麦位号排好
  final List<LiveVoiceSeat> seats;

  /// 嘉宾麦一共有几个（不含房主麦）
  final int guestSeats;

  /// 平台给的背景图，没有时为空
  final String background;

  /// 正在 PK 的队伍，没有 PK 时为空
  final List<LiveVoiceTeam> teams;

  const LiveVoiceRoom({
    required this.seats,
    this.guestSeats = 8,
    this.background = "",
    this.teams = const [],
  });

  LiveVoiceSeat? get host => seats.where((e) => e.host).firstOrNull;

  /// 第 [position] 号麦位上的人，空着时为 null
  LiveVoiceSeat? seatAt(int position) =>
      seats.where((e) => e.position == position).firstOrNull;

  static bool _same<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is LiveVoiceRoom &&
      other.guestSeats == guestSeats &&
      other.background == background &&
      _same(other.seats, seats) &&
      _same(other.teams, teams);

  @override
  int get hashCode => Object.hash(
    guestSeats,
    background,
    Object.hashAll(seats),
    Object.hashAll(teams),
  );

  /// 麦位变了：整份新的
  LiveMessage toMessage() => LiveMessage(
    type: LiveMessageType.voiceRoom,
    userName: "",
    message: "",
    color: LiveMessageColor.white,
    data: this,
  );
}

/// 语聊房里有人在说话：平台的语音转文字，一句一条
class LiveVoiceCaption {
  final String uid;
  final String name;
  final String text;
  const LiveVoiceCaption({
    required this.uid,
    required this.name,
    required this.text,
  });

  LiveMessage toMessage() => LiveMessage(
    type: LiveMessageType.voiceCaption,
    userName: name,
    message: text,
    color: LiveMessageColor.white,
    data: this,
  );

  @override
  String toString() => "LiveVoiceCaption($name: $text)";
}
