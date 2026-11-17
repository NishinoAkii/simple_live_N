import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 账号关注列表里的一项（一个主播）
class AccountFollowItem {
  /// App 能直接打开的房间号：B站真实房间号、斗鱼 rid、Kick slug、
  /// Twitch login、YouTube 频道 ID
  final String roomId;

  /// 平台上的用户 ID，回写关注时用：B站主播 mid、斗鱼真实 rid、Kick slug、
  /// Twitch 用户数字 ID、YouTube 频道 ID
  final String accountUid;

  final String userName;
  final String face;

  /// 是否正在直播；接口不给时为 null（如 YouTube 订阅列表）
  final bool? isLive;

  /// 其它回写要用的信息，如 YouTube 的订阅 ID（subscriptionId）
  final Map<String, String> extra;

  const AccountFollowItem({
    required this.roomId,
    required this.accountUid,
    required this.userName,
    this.face = "",
    this.isLive,
    this.extra = const {},
  });

  @override
  String toString() => "AccountFollowItem($roomId, $accountUid, $userName)";
}

/// 一页账号关注
class AccountFollowPage {
  final List<AccountFollowItem> items;

  /// 下一页的游标，为 null 表示读完了
  final String? nextCursor;

  /// 平台给出的总数（不一定准，只用于显示进度）
  final int? total;

  /// 平台不让继续往下读时的说明（如 Twitch 的完整性校验）。
  /// 不为空时本页之后不再读取，已经读到的仍然有效，但列表不完整
  final String? truncatedReason;

  const AccountFollowPage({
    required this.items,
    this.nextCursor,
    this.total,
    this.truncatedReason,
  });
}

/// 回写关注时的目标
class AccountFollowTarget {
  final String roomId;
  final String accountUid;
  final Map<String, String> extra;

  const AccountFollowTarget({
    required this.roomId,
    required this.accountUid,
    this.extra = const {},
  });
}

/// 各平台读取和回写的节奏
class AccountFollowPolicy {
  /// 读取两页之间的间隔
  final Duration pageInterval;

  /// 两次回写之间的间隔：在最小值和最大值之间随机
  final Duration writeIntervalMin;
  final Duration writeIntervalMax;

  /// 连续回写多少条后休息一会
  final int batchLimit;

  /// 最多读多少页，超过时当作读不完
  final int maxPages;

  /// 账号列表是否完整可信。为 false 时（如 Kick 的两个列表接口给出的集合不同），
  /// “不在列表里”不能当作已经取关，只作为建议
  final bool listIsAuthoritative;

  /// 登录本地已有关注时，房间号可能是短号/靓号，要另外查一次才能和账号列表对上
  final bool needsRoomResolve;

  /// 每次回写消耗的 API 配额单位（YouTube 官方接口为 50），没有配额时为 0
  final int writeQuotaCost;

  const AccountFollowPolicy({
    this.pageInterval = const Duration(milliseconds: 400),
    this.writeIntervalMin = const Duration(seconds: 3),
    this.writeIntervalMax = const Duration(seconds: 6),
    this.batchLimit = 20,
    this.maxPages = 200,
    this.listIsAuthoritative = true,
    this.needsRoomResolve = false,
    this.writeQuotaCost = 0,
  });
}

/// 平台的风控或频率限制：这一批立刻停止，不重试，平台的队列暂停 [pause]
class AccountFollowRiskError extends CoreError {
  final Duration pause;
  AccountFollowRiskError(
    super.message, {
    this.pause = const Duration(minutes: 30),
  });
}

/// 登录失效或缺少权限：暂停队列，提示重新登录
class AccountFollowAuthError extends CoreError {
  AccountFollowAuthError(super.message);
}

/// 平台拒绝了这一条（对方隐私设置、拉黑、账号已注销等）：不重试，只标记这一条失败
class AccountFollowRejectedError extends CoreError {
  AccountFollowRejectedError(super.message);
}

/// 网络失败（连接失败、超时）：可以稍后重试
class AccountFollowNetworkError extends CoreError {
  AccountFollowNetworkError(super.message);
}

/// 能读取（有的还能回写）登录账号关注列表的平台
///
/// 只有用户主动操作时才调用：导入预览、手动同步、开启了“同步到账号”后的单条关注/取关。
abstract interface class LiveAccountFollowSite {
  /// 已登录、可以读取账号关注
  bool get canReadAccountFollows;

  /// 当前登录账号的标识（快照按账号分开存）；没登录或还没读到账号信息时为空
  String get accountFollowOwner;

  /// 读取和回写的节奏
  AccountFollowPolicy get accountFollowPolicy;

  /// 读一页账号关注；[cursor] 为 null 表示第一页
  Future<AccountFollowPage> getAccountFollows({String? cursor});

  /// 平台支持回写，并且凭据够用
  bool get canWriteAccountFollows;

  /// 把本地关注的房间号换成回写需要的平台 ID（只读请求，匿名即可）
  Future<AccountFollowTarget> resolveAccountFollowTarget(String roomId);

  /// 在账号上关注；已经是关注状态时正常返回
  Future<void> followOnAccount(AccountFollowTarget target);

  /// 在账号上取消关注；已经不是关注状态时正常返回
  Future<void> unfollowOnAccount(AccountFollowTarget target);
}

/// 读取全部账号关注的结果
class AccountFollowFetchResult {
  /// 去重后的关注（按房间号）
  final List<AccountFollowItem> items;

  /// 是否完整读完了全部页。为 false 时不能用“不在列表里”推断取关
  final bool complete;

  /// 没读完的原因（截断、出错或取消）
  final String? incompleteReason;

  /// 读了多少页
  final int pages;

  /// 平台给出的总数
  final int? total;

  const AccountFollowFetchResult({
    required this.items,
    required this.complete,
    this.incompleteReason,
    this.pages = 0,
    this.total,
  });
}

/// 读取被用户取消
class AccountFollowCancelled extends CoreError {
  AccountFollowCancelled() : super("已取消".t);
}

/// 逐页读取全部账号关注
///
/// - 第一页出错直接抛出；后面的页出错时返回已读到的部分，并标记为不完整；
/// - 平台截断（[AccountFollowPage.truncatedReason]）、游标重复、超过页数上限都标记为不完整；
/// - [isCancelled] 返回 true 时抛出 [AccountFollowCancelled]；
/// - [sleep] 用于页间等待，测试时可以替换。
Future<AccountFollowFetchResult> fetchAllAccountFollows(
  LiveAccountFollowSite site, {
  void Function(int page, int count, int? total)? onProgress,
  bool Function()? isCancelled,
  Future<void> Function(Duration)? sleep,
}) async {
  var policy = site.accountFollowPolicy;
  var wait = sleep ?? (d) => Future<void>.delayed(d);
  var items = <AccountFollowItem>[];
  var seen = <String>{};
  var cursors = <String>{};
  String? cursor;
  int? total;
  var pages = 0;
  while (true) {
    if (isCancelled?.call() ?? false) {
      throw AccountFollowCancelled();
    }
    if (pages >= policy.maxPages) {
      return AccountFollowFetchResult(
        items: items,
        complete: false,
        incompleteReason: "关注太多，只读了前 {pages} 页".tf({"pages": pages}),
        pages: pages,
        total: total,
      );
    }
    if (pages > 0) {
      await wait(policy.pageInterval);
      if (isCancelled?.call() ?? false) {
        throw AccountFollowCancelled();
      }
    }
    AccountFollowPage page;
    try {
      page = await site.getAccountFollows(cursor: cursor);
    } on AccountFollowCancelled {
      rethrow;
    } on CoreError catch (e) {
      if (pages == 0) {
        rethrow;
      }
      return AccountFollowFetchResult(
        items: items,
        complete: false,
        incompleteReason:
            "第 {p} 页读取失败：{p2}".tf({"p": pages + 1, "p2": e.message.isEmpty ? e : e.message}),
        pages: pages,
        total: total,
      );
    }
    pages++;
    total = page.total ?? total;
    for (var item in page.items) {
      if (item.roomId.isEmpty || !seen.add(item.roomId)) {
        continue;
      }
      items.add(item);
    }
    onProgress?.call(pages, items.length, total);
    if (page.truncatedReason != null) {
      return AccountFollowFetchResult(
        items: items,
        complete: false,
        incompleteReason: page.truncatedReason,
        pages: pages,
        total: total,
      );
    }
    var next = page.nextCursor;
    if (next == null || next.isEmpty) {
      return AccountFollowFetchResult(
        items: items,
        complete: true,
        pages: pages,
        total: total,
      );
    }
    if (!cursors.add(next)) {
      return AccountFollowFetchResult(
        items: items,
        complete: false,
        incompleteReason: "翻页出错，只读到了一部分".t,
        pages: pages,
        total: total,
      );
    }
    cursor = next;
  }
}
