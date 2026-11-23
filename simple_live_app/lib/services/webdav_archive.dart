import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/live_source_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/sync_backup_format.dart';
import 'package:simple_live_app/services/sync_compat.dart';
import 'package:simple_live_app/services/sync_vault.dart';
import 'package:simple_live_app/services/webdav_auto_sync.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// WebDAV 同步选项，手动恢复和自动同步共用，只在本机保存
class WebDavSyncOptions {
  static const String follows = "follows";
  static const String histories = "histories";
  static const String blockWord = "blockWord";
  static const String bilibiliAccount = "bilibiliAccount";
  static const String platformAccounts = "platformAccounts";
  static const String liveSources = "liveSources";

  static Set<String> get _off => LocalStorageService.instance
      .getValue(LocalStorageService.kWebDAVSyncOff, "")
      .split(",")
      .where((e) => e.isNotEmpty)
      .toSet();

  static bool isOn(String name) => !_off.contains(name);

  static void set(String name, bool on) {
    var off = _off;
    if (on) {
      off.remove(name);
    } else {
      off.add(name);
    }
    LocalStorageService.instance
        .setValue(LocalStorageService.kWebDAVSyncOff, off.join(","));
  }

  /// 自动同步时要不要也同步设置（弹幕大小、播放方式等）。
  /// 手机和电脑常常不一样，默认不同步；手动恢复不看这一项
  static bool get autoSettings => LocalStorageService.instance
      .getValue(LocalStorageService.kWebDAVAutoSyncSettings, false);
}

/// WebDAV 备份的打包和恢复
class WebDavArchive {
  // 备份所有数据
  //
  // 每个文件的 data 只含官方版支持的内容（官方版可直接恢复），
  // 本版本的补充内容放在同一文件的 ext 中，官方版会忽略。
  //
  // 账号加密后放进设置文件的 vault，明文部分里没有账号和 WebDAV 密码（见 SyncVault）；
  // [key] 为空（WebDAV 没有密码）时不放账号。
  //
  // 全程在内存里，不写临时文件
  static List<int> build(int dataTime, {SyncVaultKey? key}) {
    final archive = Archive();
    var kept = savedUnknownExtras();
    void write(String name, Map<String, dynamic> content) {
      // 上次恢复时本版本不认识的附加项原样带回去；本版本自己写的同名项为准
      if (kept[name] case Map extras) {
        content = {...Map<String, dynamic>.from(extras), ...content};
      }
      var bytes = utf8.encode(jsonEncode(content));
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    // 直播源平台（js:xxx）的数据都放在 scripts 里，不放进 ext：
    // 还不支持直播源的本版本旧版读 ext 时遇到不认识的平台会出错
    // follows
    var follows = DBService.instance.getFollowList();
    write(
      SyncBackupFormat.followsFile,
      SyncBackupFormat.pack(
        SyncCompat.upstreamFollows(follows).map((e) => e.toJson()).toList(),
        SyncCompat.extFollows(follows).map((e) => e.toJson()).toList(),
        {
          SyncBackupFormat.scriptsKey:
              SyncCompat.scriptFollows(follows).map((e) => e.toJson()).toList(),
        },
      ),
    );
    // 用户自定义标签：data 去掉新平台关注，ext 为完整标签（直播源平台的关注除外）
    var tags = DBService.instance.getFollowTagList();
    write(
      SyncBackupFormat.tagsFile,
      SyncBackupFormat.pack(
        SyncCompat.upstreamTags(tags).map((e) => e.toJson()).toList(),
        SyncCompat.extTags(tags).map((e) => e.toJson()).toList(),
        {
          SyncBackupFormat.scriptsKey: SyncCompat.scriptTagMembers(tags),
        },
      ),
    );
    // histories
    var histories = DBService.instance.getHistores();
    write(
      SyncBackupFormat.historiesFile,
      SyncBackupFormat.pack(
        SyncCompat.upstreamHistories(histories).map((e) => e.toJson()).toList(),
        SyncCompat.extHistories(histories).map((e) => e.toJson()).toList(),
        {
          SyncBackupFormat.scriptsKey: SyncCompat.scriptHistories(histories)
              .map((e) => e.toJson())
              .toList(),
        },
      ),
    );
    // blocked_word：data 是全局的关键词（开着直播间单独设置时也不用那个直播间的）；
    // ext 是本版本的永久屏蔽的人和备注，官方版和旧版只读 data
    write(
      SyncBackupFormat.blockedWordFile,
      SyncBackupFormat.pack(
        AppSettingsController.instance.globalShieldList,
        ChatUsersService.maybeInstance?.exportSync(),
      ),
    );
    // 哔哩哔哩账号不再单独放一个文件，Cookie 和其它账号一起加密进设置文件。
    // 官方版和旧版找不到这个文件时保留本机登录
    // settings：data 为官方版设置，ext 为本版本专用设置与完整平台排序，
    // liveSources 为直播源的订阅与已安装的源（只有地址），vault 为加密的账号，
    // webdavAddresses 为加密的用过的 WebDAV 地址
    var all = LocalStorageService.instance.plainSettings();
    var (settings, accounts) = SyncVault.split(all);
    var bilibili = BiliBiliAccountService.instance.cookie;
    if (bilibili.isNotEmpty) {
      accounts[LocalStorageService.kBilibiliCookie] = bilibili;
    }
    write(
      SyncBackupFormat.settingsFile,
      SyncBackupFormat.pack(
        SyncCompat.upstreamSettings(settings),
        SyncCompat.extSettings(settings),
        {
          SyncBackupFormat.scriptsKey: SyncCompat.scriptSettings(settings),
          SyncBackupFormat.liveSourcesKey: LiveSourceService.registered
              ? LiveSourceService.instance.exportSyncData()
              : const LiveSourceSyncData().toJson(),
          SyncBackupFormat.dataTimeKey: dataTime,
          if (I18n.exportSync() case var languages when languages.isNotEmpty)
            SyncBackupFormat.languagesKey: languages,
          if (key != null)
            SyncVault.extraKey: SyncVault.seal(
              accounts,
              key,
              SyncVault.webDavContext(dataTime),
            ),
          if (SyncVault.sealAddresses(
                all,
                key,
                SyncVault.webDavContext(dataTime),
              )
              case var addresses?)
            SyncVault.addressesKey: addresses,
        },
      ),
    );
    return ZipEncoder().encode(archive);
  }

  /// 本版本写进备份的文件，和每个文件里本版本自己读写的键
  static const Set<String> _ownFiles = {
    SyncBackupFormat.followsFile,
    SyncBackupFormat.tagsFile,
    SyncBackupFormat.historiesFile,
    SyncBackupFormat.blockedWordFile,
    SyncBackupFormat.settingsFile,
  };
  static const Set<String> _knownKeys = {
    "data",
    SyncBackupFormat.extKey,
    SyncBackupFormat.liveSourcesKey,
    SyncBackupFormat.liveSourcesKeyR14,
    SyncBackupFormat.scriptsKey,
    SyncBackupFormat.dataTimeKey,
    SyncBackupFormat.languagesKey,
    SyncVault.extraKey,
  };

  /// 备份里本版本不认识的附加项（文件名 → 键 → 原样的值），比如别的版本加的数据。
  /// 恢复时记下，打包时原样写回去：经过这台设备上传，别的设备的这部分数据也不会丢
  static Map<String, Map<String, dynamic>> unknownExtras(
      SyncBackupFormat backup) {
    var result = <String, Map<String, dynamic>>{};
    for (var name in _ownFiles) {
      var file = backup.files[name];
      if (file is! Map) {
        continue;
      }
      var extras = <String, dynamic>{
        for (var e in file.entries)
          if (!_knownKeys.contains(e.key)) e.key.toString(): e.value,
      };
      if (extras.isNotEmpty) {
        result[name] = extras;
      }
    }
    return result;
  }

  static Map<String, dynamic> savedUnknownExtras() {
    String raw = LocalStorageService.instance
        .getValue(LocalStorageService.kWebDAVPassThrough, "");
    if (raw.isEmpty) {
      return const {};
    }
    try {
      var value = jsonDecode(raw);
      return value is Map ? Map<String, dynamic>.from(value) : const {};
    } catch (_) {
      return const {};
    }
  }

  /// 恢复备份，兼容官方版、早期单独扩展文件与同文件 ext 三种格式。
  ///
  /// [auto] 是自动同步：屏蔽词以云端为准；观看记录按 [baseTime]（上次和云端对齐的时间）
  /// 合并，看过的不丢，别的设备删掉的也删掉；账号不因为别的设备没登录而退出；
  /// 设置默认不动，见 [WebDavSyncOptions.autoSettings]。
  ///
  /// 加密的账号用 [vaultUser]、[vaultPassword]（本机的 WebDAV 账号密码）解开；
  /// 解不开时保留本机登录，并通过 [onWarning] 提示。
  ///
  /// 返回本机有没有云端没有的观看记录（自动同步时还要传上去）。
  static Future<bool> restore(
    SyncBackupFormat source, {
    bool auto = false,
    int baseTime = 0,
    String vaultUser = "",
    String vaultPassword = "",
    void Function(String message)? onWarning,
  }) async {
    // 先放回加密的账号，后面和明文的旧存档一样恢复
    var (backup, opened) = await SyncVault.openBackup(
      source,
      user: vaultUser,
      password: vaultPassword,
      localSettings: LocalStorageService.instance.plainSettings(),
    );
    if (!opened) {
      Log.w(SyncVault.openFailedText);
      onWarning?.call(SyncVault.openFailedText);
    }
    var unknown = unknownExtras(backup);
    await LocalStorageService.instance.setValue(
      LocalStorageService.kWebDAVPassThrough,
      unknown.isEmpty ? "" : jsonEncode(unknown),
    );
    const followsFile = SyncBackupFormat.followsFile;
    const tagsFile = SyncBackupFormat.tagsFile;
    const historiesFile = SyncBackupFormat.historiesFile;
    const blockedWordFile = SyncBackupFormat.blockedWordFile;
    const bilibiliAccountFile = SyncBackupFormat.bilibiliAccountFile;
    const settingsFile = SyncBackupFormat.settingsFile;
    var syncFollows = WebDavSyncOptions.isOn(WebDavSyncOptions.follows);

    var keptLocal = false;
    var errors = <String>[];
    Future<void> step(String label, Future<void> Function() action) async {
      try {
        await action();
        Log.i('已同步$label');
      } catch (e, stackTrace) {
        Log.e('同步$label失败：$e', stackTrace);
        errors.add(label);
      }
    }

    // 备份来自支持直播源的版本时才有直播源一项；
    // 来自旧版时保留本地直播源平台（js:xxx）的关注
    var liveSources = backup.liveSources(settingsFile);
    // 导入的界面翻译：本机没有的加上，不一样的换成云端的
    var languages = backup.extraMap(
      settingsFile,
      SyncBackupFormat.languagesKey,
    );
    if (languages != null) {
      await I18n.restoreSync(languages);
    }
    var includeScripts = liveSources != null;
    if (syncFollows && backup.has(followsFile)) {
      await step('关注列表'.t, () async {
        var ext = backup.extList(followsFile, 'follows');
        // 直播源平台的关注在 scripts 里（旧版本的备份在 ext 里，两种都认）
        var scripts =
            backup.extraList(followsFile, SyncBackupFormat.scriptsKey);
        // 先解析再清空：备份有问题时本地的关注还在
        var users = [
          ...backup.mainList(followsFile),
          ...?ext,
          ...?scripts,
        ].map((item) => FollowUser.fromJson(item)).toList();
        // 没有 ext（来自官方版）时保留本地新平台的关注
        await SyncCompat.clearFollows(
          includeExt: ext != null,
          includeScripts: includeScripts,
        );
        for (var user in users) {
          await DBService.instance.followBox.put(user.id, user);
        }
        // 官方版传的存档没有新平台和直播源的关注，本机留着的要再传回云端，
        // 不然新设备这时拉取就拿不到
        if (auto &&
            DBService.instance.followBox.values.any(
              (e) => !SyncCompat.shouldClearSite(
                e.siteId,
                includeExt: ext != null,
                includeScripts: includeScripts,
              ),
            )) {
          keptLocal = true;
        }
      });
    }
    if (syncFollows && backup.has(tagsFile)) {
      // 标签功能和关注具有依赖关系，必须同时同步
      await step('标签'.t, () async {
        var ext = backup.extList(tagsFile, 'tags');
        var extMembers = ext == null
            ? SyncCompat.snapshotExtTagMembers()
            : includeScripts
                ? <String, List<String>>{}
                : SyncCompat.snapshotExtTagMembers(scriptsOnly: true);
        await DBService.instance.tagBox.clear();
        for (var item in ext ?? backup.mainList(tagsFile)) {
          var tag = FollowUserTag.fromJson(item);
          await DBService.instance.tagBox.put(tag.id, tag);
        }
        await SyncCompat.restoreExtTagMembers(extMembers);
        var scripts = backup.extraMap(tagsFile, SyncBackupFormat.scriptsKey);
        if (scripts != null) {
          await SyncCompat.restoreExtTagMembers({
            for (var entry in scripts.entries)
              if (entry.value is List)
                entry.key: [for (var id in entry.value as List) id.toString()],
          });
        }
      });
    }
    if (syncFollows) {
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
    }
    if (WebDavSyncOptions.isOn(WebDavSyncOptions.histories) &&
        backup.has(historiesFile)) {
      await step('观看记录'.t, () async {
        var ext = backup.extList(historiesFile, 'histories');
        var items = [
          ...backup.mainList(historiesFile),
          ...?ext,
          ...?backup.extraList(historiesFile, SyncBackupFormat.scriptsKey),
        ].map((item) => History.fromJson(item)).toList();
        if (auto) {
          var merged = await _mergeHistories(
            items,
            baseTime: baseTime,
            includeExt: ext != null,
            includeScripts: includeScripts,
          );
          keptLocal = keptLocal || merged;
          return;
        }
        for (var history in items) {
          var old = DBService.instance.historyBox.get(history.id);
          // 如果本地的更新时间比较新，就不更新
          if (old != null && old.updateTime.isAfter(history.updateTime)) {
            continue;
          }
          await DBService.instance.addOrUpdateHistory(history);
        }
      });
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
    }
    if (WebDavSyncOptions.isOn(WebDavSyncOptions.blockWord) &&
        backup.has(blockedWordFile)) {
      await step('屏蔽词'.t, () async {
        var words = backup
            .mainList(blockedWordFile)
            .map((keyword) => keyword.toString().trim())
            .toSet();
        var settings = AppSettingsController.instance;
        // 恢复到全局的关键词（开着直播间单独设置时也一样）
        await settings.updateGlobalShieldList(
          add: words,
          remove: auto
              ? settings.globalShieldList.where((e) => !words.contains(e))
              : const [],
        );
      });
    }
    // 屏蔽的人（永久的）和备注，在 blocked_word 的 ext 里；旧版和官方版的备份没有
    var people = backup.extMap(blockedWordFile, 'chatUsers');
    var users = ChatUsersService.maybeInstance;
    if (people != null && users != null) {
      await step('屏蔽的人和备注'.t, () async {
        users.importSync(
          people,
          replace: auto,
          includeBlocks: WebDavSyncOptions.isOn(WebDavSyncOptions.blockWord),
        );
      });
    }
    if (WebDavSyncOptions.isOn(WebDavSyncOptions.bilibiliAccount) &&
        backup.main(bilibiliAccountFile) is Map) {
      await step('哔哩哔哩账号'.t, () async {
        var account = backup.main(bilibiliAccountFile) as Map;
        var cookie = (account['cookie'] ?? '').toString();
        var service = BiliBiliAccountService.instance;
        // 别的设备没登录不等于这台要退出；账号没变时也不用再读一次账号信息
        if (auto && (cookie.isEmpty || cookie == service.cookie)) {
          return;
        }
        service.setCookie(cookie);
        await service.loadUserInfo();
      });
    }
    if (backup.main(settingsFile) is Map) {
      await step('设置'.t, () async {
        var main = Map<String, dynamic>.from(backup.main(settingsFile));
        var ext = backup.extMap(settingsFile, 'settings');
        // 含直播源平台的完整平台排序在 scripts 里
        var scripts =
            backup.extraMap(settingsFile, SyncBackupFormat.scriptsKey);
        if (ext != null && scripts != null) {
          ext = {...ext, ...scripts};
        }
        var syncAccounts =
            WebDavSyncOptions.isOn(WebDavSyncOptions.platformAccounts);
        if (auto) {
          var accountsChanged = await SyncCompat.restoreAutoSettings(
            main,
            ext,
            syncSettings: WebDavSyncOptions.autoSettings,
            syncAccounts: syncAccounts,
            syncBilibili:
                WebDavSyncOptions.isOn(WebDavSyncOptions.bilibiliAccount),
          );
          if (accountsChanged) {
            SyncCompat.reloadAccounts();
          }
          return;
        }
        await SyncCompat.restoreSettings(
          main,
          ext,
          syncAccounts: syncAccounts,
        );
        SyncCompat.reloadAccounts();
      });
    }
    // 直播源要联网下载，在后台安装，完成后另外提示
    if (WebDavSyncOptions.isOn(WebDavSyncOptions.liveSources) &&
        liveSources != null &&
        LiveSourceService.registered &&
        !LiveSourceSyncData.fromJson(liveSources).isEmpty) {
      LiveSourceService.instance.restoreSyncDataInBackground(liveSources);
    }
    if (errors.isNotEmpty) {
      throw "其中{errors}没能恢复".tf({"errors": errors.join("、".t)});
    }
    return keptLocal;
  }

  static Future<bool> _mergeHistories(
    List<History> items, {
    required int baseTime,
    required bool includeExt,
    required bool includeScripts,
  }) async {
    var db = DBService.instance;
    // 备份来自官方版或旧版时，它不认识的平台不算“云端没有”，不动本机的
    var histories = mergeWebDavRecords<History>(
      db.historyBox.values.where(
        (e) => SyncCompat.shouldClearSite(
          e.siteId,
          includeExt: includeExt,
          includeScripts: includeScripts,
        ),
      ),
      items,
      id: (e) => e.id,
      time: (e) => e.updateTime,
      base: baseTime,
    );
    await db.historyBox.deleteAll(histories.delete);
    for (var history in histories.put) {
      await db.addOrUpdateHistory(history);
    }
    return histories.localKept;
  }
}
