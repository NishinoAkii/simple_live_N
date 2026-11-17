import 'package:simple_live_core/src/model/live_message.dart';

/// 直播间的一种榜单（在线贡献榜、大航海、亲密榜……）
class LiveRankBoard {
  /// 平台内唯一，如 "online"、"guard"、"fans"
  final String id;

  /// 名字（简体中文原文，界面上再翻译）
  final String title;

  /// 按钮上的短名字（如“贡献榜”），没有时用 [title]
  final String? shortTitle;

  /// 分数是什么，如“贡献值”“亲密度”
  final String scoreLabel;

  /// 显示在榜单上方的说明（灰字），没有时为 null
  final String? note;

  /// 前几名跟着弹幕连接的推送实时变化（[LiveMessageType.rank]）
  final bool live;

  const LiveRankBoard({
    required this.id,
    required this.title,
    this.shortTitle,
    this.scoreLabel = "贡献值",
    this.note,
    this.live = false,
  });

  /// 按钮上显示的名字（简体中文原文）
  String get label => shortTitle ?? title;

  @override
  bool operator ==(Object other) => other is LiveRankBoard && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => "LiveRankBoard($id)";
}

/// 榜单上的一个人
class LiveRankItem {
  /// 名次，从 1 开始
  final int rank;

  final String userName;

  /// 用户 ID（同 [LiveMessage.userId]），平台没给时为 null
  final String? userId;

  /// 头像，没有时为空
  final String face;

  /// 分数（贡献值、亲密度、送出的订阅数等），平台没给数字时为 null
  final num? score;

  /// 平台给的分数写法（如抖音的“1.2万”），为 null 时界面按 [score] 显示
  final String? scoreText;

  /// 第二行的说明（如“陪伴 36 天”），没有时为 null
  final String? detail;

  /// 粉丝牌、大航海、等级等身份
  final List<LiveBadge> badges;

  const LiveRankItem({
    required this.rank,
    required this.userName,
    this.userId,
    this.face = "",
    this.score,
    this.scoreText,
    this.detail,
    this.badges = const [],
  });

  /// 戴着粉丝牌（或在粉丝团里）
  bool get hasMedal => badges.any((e) => e.kind == LiveBadgeKind.medal);

  /// 同一个人：有 ID 比 ID，否则比名字（规则同 [sameLiveUser]）
  bool sameUser(LiveRankItem other) =>
      sameLiveUser(userId, userName, other.userId, other.userName);

  LiveRankItem withRank(int value) => value == rank
      ? this
      : LiveRankItem(
          rank: value,
          userName: userName,
          userId: userId,
          face: face,
          score: score,
          scoreText: scoreText,
          detail: detail,
          badges: badges,
        );

  @override
  String toString() =>
      "LiveRankItem($rank, $userName${userId == null ? "" : "#$userId"}, "
      "${scoreText ?? score})";
}

/// 读一次榜单的结果
class LiveRankList {
  final String boardId;
  final List<LiveRankItem> items;

  /// 榜上一共多少人（在线人数、大航海人数、粉丝团人数），平台没给时为 null
  final int? total;

  const LiveRankList(this.boardId, this.items, {this.total});
}

/// 弹幕连接推送的前几名（[LiveMessageType.rank] 的 data）
class LiveRankUpdate {
  final String boardId;
  final List<LiveRankItem> items;
  const LiveRankUpdate(this.boardId, this.items);

  /// 发给直播间的一条消息（不进聊天区）
  LiveMessage toMessage() => LiveMessage(
    type: LiveMessageType.rank,
    userName: "",
    message: "",
    color: LiveMessageColor.white,
    data: this,
  );

  @override
  String toString() => "LiveRankUpdate($boardId, $items)";
}

/// 把推送的前几名 [top] 并进已经读到的榜单 [list]：前面换成 [top]，
/// 后面的人去掉已经在 [top] 里的，按原来的顺序接着排名次
List<LiveRankItem> mergeRankTop(
  List<LiveRankItem> list,
  List<LiveRankItem> top,
) {
  if (top.isEmpty) {
    return list;
  }
  var head = [...top]..sort((a, b) => a.rank.compareTo(b.rank));
  var rest = [
    for (var item in list)
      if (!head.any(item.sameUser)) item,
  ];
  var merged = <LiveRankItem>[
    for (var i = 0; i < head.length; i++) head[i].withRank(i + 1),
  ];
  // 原来排在推送名单之后的人保持顺序；原来排在前面、这次没推送的人往后挪
  for (var item in rest) {
    merged.add(item.withRank(merged.length + 1));
  }
  return merged;
}
