import 'package:simple_live_app/services/sync_backup_format.dart';

/// 本机存档的下一个时间戳：一般是现在。设备时钟比云端慢时也要比之前的大，
/// 不然刚改的内容会被当成旧的
int nextWebDavDataTime(int current, int now) =>
    now > current ? now : current + 1;

/// 观看记录合并的结果
class WebDavRecordMerge<T> {
  /// 要写进本机的（云端新增的、云端更新的）
  final List<T> put;

  /// 要从本机删掉的（别的设备删了的）
  final List<String> delete;

  /// 本机有云端没有的内容（刚看过的、刚删掉的），合并后还要传上去
  final bool localKept;

  const WebDavRecordMerge(this.put, this.delete, this.localKept);
}

/// 合并观看记录。关注列表可以整份用新的，观看记录不行：两台设备都在看时，
/// 整份覆盖会丢掉另一台刚看过的。每条记录有更新时间，[base] 是上次和云端对齐的时间：
/// - 两边都有：用更新时间新的；
/// - 只有云端有：比 [base] 新是别的设备刚看的，收下；否则是本机后来删掉的，不要；
/// - 只有本机有：比 [base] 新是本机刚看的，留着；否则是别的设备后来删掉的，删掉。
WebDavRecordMerge<T> mergeWebDavRecords<T>(
  Iterable<T> local,
  Iterable<T> remote, {
  required String Function(T) id,
  required DateTime Function(T) time,
  required int base,
}) {
  bool afterBase(T item) => time(item).millisecondsSinceEpoch > base;
  var localById = {for (var item in local) id(item): item};
  var remoteIds = <String>{};
  var put = <T>[];
  var delete = <String>[];
  var localKept = false;
  for (var item in remote) {
    remoteIds.add(id(item));
    var mine = localById[id(item)];
    if (mine == null) {
      if (afterBase(item)) {
        put.add(item);
      } else {
        localKept = true;
      }
    } else if (time(item).isAfter(time(mine))) {
      put.add(item);
    } else if (time(mine).isAfter(time(item))) {
      localKept = true;
    }
  }
  for (var item in local) {
    if (remoteIds.contains(id(item))) {
      continue;
    }
    if (afterBase(item)) {
      localKept = true;
    } else {
      delete.add(id(item));
    }
  }
  return WebDavRecordMerge(put, delete, localKept);
}

/// 云端的存档和它的时间戳
class WebDavRemoteArchive {
  final SyncBackupFormat backup;
  final int time;
  const WebDavRemoteArchive(this.backup, this.time);
}

enum WebDavPullResult {
  /// 云端还没有存档
  noRemote,

  /// 两边一样新
  same,

  /// 本机更新，退出时上传
  localNewer,

  /// 云端更新，已经拉取
  pulled,

  /// 云端更新，但它的关注列表是空的，没有覆盖本机
  remoteEmpty,
}

enum WebDavPushResult {
  /// 上次同步之后本机没有变化
  nothingNew,

  /// 云端更新（别的设备传的），不覆盖，下次启动时拉取
  remoteNewer,

  /// 本机的关注列表是空的而云端不是，不覆盖
  localEmpty,

  /// 已经上传
  uploaded,
}

/// 自动同步要用到的外部操作：存档时间戳的存取、云端读写、备份打包和恢复
abstract class WebDavAutoSyncHost {
  /// 本机存档的时间戳：关注、观看记录等最后一次变化的时间
  int get dataTime;
  set dataTime(int value);

  /// 上次和云端对齐时的时间戳，比 [dataTime] 小说明本机有新内容要上传
  int get syncedTime;
  set syncedTime(int value);

  /// 云端文件的版本，读不到时为 null；连不上时抛出异常。
  /// 和 Venera 一样先看文件列表，没变就不用下载
  Future<String?> remoteVersion();

  /// 上次和云端对齐时看到的版本
  String? get seenRemoteVersion;
  set seenRemoteVersion(String? value);

  /// 读取云端存档，云端没有时返回 null；连不上时抛出异常
  Future<WebDavRemoteArchive?> fetchRemote();

  /// 上传，返回传上去的这份的版本。读不到、或者这时已经被别的设备换掉了就返回 null
  /// （这时不能当作看过，下次要下载比较）
  Future<String?> uploadRemote(List<int> zip);

  /// 打包本机存档，[dataTime] 写进备份
  Future<List<int>> buildArchive(int dataTime);

  /// 用云端的存档覆盖本机，观看记录是合并的。
  /// 返回本机有没有云端没有的内容（还要传上去）
  Future<bool> restoreArchive(SyncBackupFormat backup);

  /// 覆盖本机之前留一份
  Future<void> keepSafetyCopy();

  /// 这台设备同步关注列表时才检查“空列表不覆盖”
  bool get guardFollows;
  int get localFollowCount;
}

/// 按时间戳决定用哪边的存档：哪边新用哪边
class WebDavAutoSync {
  final WebDavAutoSyncHost host;
  WebDavAutoSync(this.host);

  /// 启动时：云端更新就拉取，本机更新就留着（退出时上传）
  Future<WebDavPullResult> pullIfNewer() async {
    var version = await host.remoteVersion();
    if (version != null && version == host.seenRemoteVersion) {
      return host.dataTime > host.syncedTime
          ? WebDavPullResult.localNewer
          : WebDavPullResult.same;
    }
    var remote = await host.fetchRemote();
    if (remote == null) {
      host.syncedTime = 0;
      host.seenRemoteVersion = null;
      return WebDavPullResult.noRemote;
    }
    // 新设备关注是空的，只要先看过直播间，时间戳就比云端新。不能因此把它当成“本机更新”：
    // 那样它永远拉不到关注列表，传上去还会盖掉云端的。观看记录是合并的，刚看的不会丢
    var localIsEmpty = host.guardFollows &&
        host.localFollowCount == 0 &&
        remote.backup.followCount > 0;
    if (remote.time <= host.dataTime && !localIsEmpty) {
      host.syncedTime = remote.time;
      host.seenRemoteVersion = version;
      return remote.time == host.dataTime
          ? WebDavPullResult.same
          : WebDavPullResult.localNewer;
    }
    if (host.guardFollows &&
        remote.backup.followCount == 0 &&
        host.localFollowCount > 0) {
      return WebDavPullResult.remoteEmpty;
    }
    await host.keepSafetyCopy();
    var keptLocal = await host.restoreArchive(remote.backup);
    host.syncedTime = remote.time;
    host.seenRemoteVersion = version;
    host.dataTime = keptLocal
        ? nextWebDavDataTime(remote.time, DateTime.now().millisecondsSinceEpoch)
        : remote.time;
    return WebDavPullResult.pulled;
  }

  /// 退出时：本机有新内容才上传；这期间别的设备传了更新的就不覆盖
  Future<WebDavPushResult> pushIfNewer() async {
    var stamp = host.dataTime;
    if (stamp <= host.syncedTime) {
      return WebDavPushResult.nothingNew;
    }
    var version = await host.remoteVersion();
    if (version == null || version != host.seenRemoteVersion) {
      var remote = await host.fetchRemote();
      if (remote != null) {
        if (remote.time > stamp) {
          return WebDavPushResult.remoteNewer;
        }
        if (host.guardFollows &&
            host.localFollowCount == 0 &&
            remote.backup.followCount > 0) {
          return WebDavPushResult.localEmpty;
        }
      }
    }
    host.seenRemoteVersion =
        await host.uploadRemote(await host.buildArchive(stamp));
    host.syncedTime = stamp;
    return WebDavPushResult.uploaded;
  }
}
