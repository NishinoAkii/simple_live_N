import 'dart:math';

import 'package:simple_live_app/services/account_follow/account_follow_models.dart';
import 'package:simple_live_app/services/account_follow/account_follow_store.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 加入队列的结果
enum FollowEnqueueResult {
  /// 新加了一条
  queued,

  /// 已经有同样的一条，沿用它（失败的重新开始）
  merged,

  /// 和还没执行的反向操作抵消了（如刚关注就取关），什么也不用做
  cancelledOut,
}

/// 把关注/取关一条一条写到账号上
///
/// - 一个平台一个串行队列，两条之间按平台的节奏随机等待（B站、斗鱼 3–6 秒）；
/// - 连续写满一批（B站 20 条）后休息 [batchRest]；每天每个平台最多 [dailyLimit] 条，
///   超过后暂停到第二天，或等用户点“继续”；
/// - 风控（[AccountFollowRiskError]）立即停止整个平台，暂停一段时间；暂停结束后再试，
///   同一条连续被拦 [maxRiskHits] 次就标记失败，不再挡住后面的；
/// - 登录失效（[AccountFollowAuthError]）暂停，等用户处理；
/// - 平台拒绝这一条（[AccountFollowRejectedError]）不重试，标记失败；
/// - 其它错误按 30 秒、1、2、4 分钟退避，最多 [maxAttempts] 次，然后标记失败；
/// - 队列存在本机的 Hive 里，重启后继续。
///
/// 时间、等待和随机数都可以替换，测试时用假的时钟。
class AccountFollowQueue {
  final AccountFollowRepository repo;
  final LiveAccountFollowSite? Function(String siteId) siteOf;

  /// 该平台的“同步到账号”开关
  final bool Function(String siteId) isEnabled;
  final DateTime Function() now;
  final Future<void> Function(Duration) sleep;
  final Random random;
  final int maxAttempts;

  /// 同一条连续被风控拦下多少次后不再自动重发
  final int maxRiskHits;
  final int dailyLimit;
  final Duration batchRest;

  /// 队列或状态变化（界面刷新）
  void Function()? onChanged;

  /// 一条执行完：[error] 为空表示成功
  void Function(FollowWriteJob job, Object? error)? onJobFinished;

  AccountFollowQueue({
    required this.repo,
    required this.siteOf,
    required this.isEnabled,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
    Random? random,
    this.maxAttempts = 5,
    this.maxRiskHits = 3,
    this.dailyLimit = 50,
    this.batchRest = const Duration(minutes: 5),
    this.onChanged,
    this.onJobFinished,
  })  : now = now ?? DateTime.now,
        sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        random = random ?? Random();

  final Set<String> _running = {};

  /// 正在执行的任务（平台 → 任务 id）
  final Map<String, String> _inFlight = {};

  bool isRunning(String siteId) => _running.contains(siteId);

  bool isInFlight(String jobId) => _inFlight.containsValue(jobId);

  /// 第 [attempts] 次失败后等多久再试
  static Duration backoff(int attempts) =>
      Duration(seconds: 30 * (1 << (attempts - 1).clamp(0, 6)));

  Duration _interval(AccountFollowPolicy policy) {
    var min = policy.writeIntervalMin.inMilliseconds;
    var max = policy.writeIntervalMax.inMilliseconds;
    if (max <= min) {
      return policy.writeIntervalMin;
    }
    return Duration(milliseconds: min + random.nextInt(max - min + 1));
  }

  void _changed() => onChanged?.call();

  /// 去掉同一个关注还没执行的反向操作（如关注还在排队时又取关了），返回去掉的条数。
  /// 正在执行的那一条去不掉
  Future<int> cancelOpposite(
    String siteId,
    String followId,
    FollowWriteAction action,
  ) async {
    var count = 0;
    for (var old in repo.jobs(siteId: siteId)) {
      if (old.followId == followId &&
          old.action != action &&
          !isInFlight(old.id)) {
        await repo.deleteJob(old.id);
        count++;
      }
    }
    if (count > 0) {
      _changed();
    }
    return count;
  }

  /// 加入一条；同一个关注还没执行的反向操作会被抵消
  Future<FollowEnqueueResult> enqueue(FollowWriteJob job) async {
    var same = repo
        .jobs(siteId: job.siteId)
        .where((e) => e.followId == job.followId && !isInFlight(e.id))
        .toList();
    for (var old in same) {
      if (old.action != job.action) {
        await repo.deleteJob(old.id);
        _changed();
        return FollowEnqueueResult.cancelledOut;
      }
    }
    if (same.isNotEmpty) {
      var old = same.first
        ..state = FollowWriteState.pending
        ..attempts = 0
        ..riskHits = 0
        ..nextAttemptAt = null
        ..lastError = "";
      await repo.putJob(old);
      _changed();
      return FollowEnqueueResult.merged;
    }
    await repo.putJob(job);
    _changed();
    return FollowEnqueueResult.queued;
  }

  /// 失败的重新开始
  Future<void> retry(String jobId) async {
    var job = repo.job(jobId);
    if (job == null) {
      return;
    }
    job
      ..state = FollowWriteState.pending
      ..attempts = 0
      ..riskHits = 0
      ..nextAttemptAt = null
      ..lastError = "";
    await repo.putJob(job);
    _changed();
  }

  /// 放弃一条（不在账号上执行）
  Future<void> discard(String jobId) async {
    if (isInFlight(jobId)) {
      return;
    }
    await repo.deleteJob(jobId);
    _changed();
  }

  /// 用户点“继续”：取消暂停，今天不再受条数限制
  Future<void> resumeSite(String siteId) async {
    var state = repo.siteState(siteId);
    if (state.pauseKind == FollowPauseKind.daily) {
      state.dailyOverride = followDayKey(now());
    }
    state.clearPause();
    await repo.putSiteState(state);
    _changed();
  }

  /// 下次需要醒来的时间：暂停结束或等待重试的任务到点；没有时为 null
  DateTime? nextWakeUp() {
    DateTime? result;
    void consider(DateTime? time) {
      if (time != null && (result == null || time.isBefore(result!))) {
        result = time;
      }
    }

    var sites = repo.jobs().map((e) => e.siteId).toSet();
    for (var siteId in sites) {
      // 正在执行的平台由它自己的循环处理，结束后会再算一次
      if (!isEnabled(siteId) || isRunning(siteId)) {
        continue;
      }
      var state = repo.siteState(siteId);
      if (state.pauseKind != null) {
        // 登录失效时一直暂停，等用户处理
        consider(state.pausedUntil);
        continue;
      }
      for (var job in repo.jobs(siteId: siteId)) {
        if (job.state == FollowWriteState.pending) {
          consider(job.nextAttemptAt ?? now());
        }
      }
    }
    return result;
  }

  Future<void> _pause(
    AccountFollowSiteState state,
    FollowPauseKind kind,
    DateTime? until,
    String message,
  ) async {
    state
      ..pauseKind = kind
      ..pausedUntil = until
      ..message = message;
    await repo.putSiteState(state);
    _changed();
  }

  /// 执行一个平台的队列，直到做完、暂停或剩下的都在等待重试
  Future<void> runSite(String siteId) async {
    if (!_running.add(siteId)) {
      return;
    }
    try {
      var written = 0;
      while (true) {
        if (!isEnabled(siteId)) {
          return;
        }
        var site = siteOf(siteId);
        if (site == null) {
          return;
        }
        var state = repo.siteState(siteId);
        var time = now();
        if (state.isPaused(time)) {
          return;
        }
        if (state.pauseKind != null) {
          // 暂停到点了
          state.clearPause();
          await repo.putSiteState(state);
          _changed();
        }
        var ready = repo
            .jobs(siteId: siteId)
            .where(
              (e) =>
                  e.state == FollowWriteState.pending &&
                  (e.nextAttemptAt == null || !e.nextAttemptAt!.isAfter(time)),
            )
            .toList();
        if (ready.isEmpty) {
          return;
        }
        if (!site.canWriteAccountFollows) {
          await _pause(state, FollowPauseKind.auth, null, "请先登录账号，再点继续".t);
          return;
        }
        var today = followDayKey(time);
        if (state.dayKey != today) {
          state
            ..dayKey = today
            ..dayCount = 0;
        }
        if (state.dayCount >= dailyLimit && state.dailyOverride != today) {
          var tomorrow = DateTime(time.year, time.month, time.day + 1);
          await _pause(
            state,
            FollowPauseKind.daily,
            tomorrow,
            "今天已同步 {dailyLimit} 条，明天自动继续，也可以点继续".tf({"dailyLimit": dailyLimit}),
          );
          return;
        }
        var policy = site.accountFollowPolicy;
        if (written >= policy.batchLimit) {
          await _pause(
            state,
            FollowPauseKind.batch,
            time.add(batchRest),
            "已连续同步 {written} 条，休息 {batchRest} 分钟后继续".tf({"written": written, "batchRest": batchRest.inMinutes}),
          );
          return;
        }
        var last = state.lastWriteAt;
        if (last != null) {
          var wait = last.add(_interval(policy)).difference(time);
          if (wait > Duration.zero) {
            await sleep(wait);
          }
        }
        // 等待期间可能被放弃或关掉了开关
        var job = repo.job(ready.first.id);
        if (job == null || job.state != FollowWriteState.pending) {
          continue;
        }
        if (!isEnabled(siteId)) {
          return;
        }
        _inFlight[siteId] = job.id;
        _changed();
        AccountFollowTarget target;
        try {
          target = await _target(site, job);
          if (job.action == FollowWriteAction.follow) {
            await site.followOnAccount(target);
          } else {
            await site.unfollowOnAccount(target);
          }
        } on AccountFollowRiskError catch (e) {
          state = repo.siteState(siteId)..lastWriteAt = now();
          // 同一条连续被拦几次就不再自动重发（可能是关注数到上限之类的长期原因），
          // 免得一直挡住后面的；平台照样暂停
          job
            ..riskHits = job.riskHits + 1
            ..lastError = e.message;
          if (job.riskHits >= maxRiskHits) {
            job.state = FollowWriteState.failed;
          }
          await repo.putJob(job);
          await _pause(
              state, FollowPauseKind.risk, now().add(e.pause), e.message);
          onJobFinished?.call(job, e);
          return;
        } on AccountFollowAuthError catch (e) {
          state = repo.siteState(siteId);
          job.lastError = e.message;
          await repo.putJob(job);
          await _pause(state, FollowPauseKind.auth, null, e.message);
          onJobFinished?.call(job, e);
          return;
        } on AccountFollowRejectedError catch (e) {
          state = repo.siteState(siteId)..lastWriteAt = now();
          await repo.putSiteState(state);
          job
            ..state = FollowWriteState.failed
            ..lastError = e.message;
          await repo.putJob(job);
          onJobFinished?.call(job, e);
          continue;
        } catch (e) {
          state = repo.siteState(siteId)..lastWriteAt = now();
          await repo.putSiteState(state);
          job
            ..attempts = job.attempts + 1
            ..lastError = e is CoreError && e.message.isNotEmpty
                ? e.message
                : e.toString();
          if (job.attempts >= maxAttempts) {
            job
              ..state = FollowWriteState.failed
              ..nextAttemptAt = null;
          } else {
            job.nextAttemptAt = now().add(backoff(job.attempts));
          }
          await repo.putJob(job);
          onJobFinished?.call(job, e);
          continue;
        } finally {
          _inFlight.remove(siteId);
          _changed();
        }
        // 成功：先删掉任务，后面记录出错时也不会重复写到账号
        await repo.deleteJob(job.id);
        written++;
        try {
          state = repo.siteState(siteId);
          var count = state.dayKey == today ? state.dayCount + 1 : 1;
          state
            ..lastWriteAt = now()
            ..dayKey = today
            ..dayCount = count;
          await repo.putSiteState(state);
          await _afterSuccess(site, job, target);
        } catch (_) {
          // 只影响快照和计数，下次同步时会重新比对
        }
        _changed();
        try {
          onJobFinished?.call(job, null);
        } catch (_) {}
      }
    } finally {
      _running.remove(siteId);
    }
  }

  /// 回写的目标：有对应关系就用，没有时查一次并记下
  Future<AccountFollowTarget> _target(
    LiveAccountFollowSite site,
    FollowWriteJob job,
  ) async {
    var link = repo.link(job.followId);
    if (link != null && link.accountUid.isNotEmpty) {
      return link.target;
    }
    var target = await site.resolveAccountFollowTarget(job.roomId);
    await repo.putLink(
      AccountFollowLink(
        siteId: job.siteId,
        roomId: job.roomId,
        accountUid: target.accountUid,
        accountRoomId: target.roomId,
        extra: target.extra,
        linkedAt: now(),
      ),
    );
    return target;
  }

  /// 成功后更新基准：账号上多了/少了这一个；取关成功后取关记录也不需要了
  Future<void> _afterSuccess(
    LiveAccountFollowSite site,
    FollowWriteJob job,
    AccountFollowTarget target,
  ) async {
    var snapshot = repo.snapshot(job.siteId);
    var owner = site.accountFollowOwner;
    if (snapshot != null && owner.isNotEmpty && snapshot.owner == owner) {
      snapshot = job.action == FollowWriteAction.follow
          ? snapshot.added(target.roomId, target.accountUid, now())
          : snapshot.removed(target.roomId, target.accountUid, now());
      await repo.putSnapshot(snapshot);
    }
    if (job.action == FollowWriteAction.unfollow) {
      await repo.deleteTombstone(job.followId);
      var link = repo.link(job.followId);
      if (link != null && link.extra.containsKey("subscriptionId")) {
        // 订阅 ID 已经失效
        await repo.putLink(
          AccountFollowLink(
            siteId: link.siteId,
            roomId: link.roomId,
            accountUid: link.accountUid,
            accountRoomId: link.accountRoomId,
            linkedAt: link.linkedAt,
          ),
        );
      }
    }
  }
}
