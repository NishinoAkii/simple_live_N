import 'dart:convert';
import 'dart:isolate';

import 'package:archive/archive.dart';

/// 同步备份的文件格式
///
/// 每个文件形如 `{"data": ..., "ext": ...}`：
/// - `data` 只含官方版支持的内容，官方版只读这一项，可以直接恢复；
/// - `ext` 是本版本的补充（新平台的关注、历史、完整标签、新平台账号与完整平台排序），
///   官方版会忽略。
///
/// 读取时兼容三种来源：官方版（没有 ext）、本版本早期的单独扩展文件
/// `SimpleLive_ext.json`、以及现在的同文件 ext。
///
/// 后来新增的数据（如直播源）放在同一文件的其他键里，
/// 官方版和本版本的旧版都只读 data/ext，不受影响。
class SyncBackupFormat {
  static const String extKey = "ext";

  /// 设置文件里的直播源：订阅地址与已安装的源（地址、版本），
  /// 有这一项说明备份来自支持直播源的版本，直播源平台的数据在 [scriptsKey] 里
  static const String liveSourcesKey = "liveSourceSync";

  /// 旧版本写的同一项。那时直播源平台的关注等放在 ext 里；旧版本看到这一项
  /// 会先清掉本机直播源平台的关注再从 ext 恢复，所以新格式换了名字，
  /// 让它把新备份当作旧版的、保留本机的直播源关注
  static const String liveSourcesKeyR14 = "liveSources";

  /// 直播源平台（js:xxx）的关注、历史、标签成员和完整平台排序。
  /// 不放进 ext：还不支持直播源的本版本旧版会读 ext，遇到不认识的平台会出错。
  /// （旧版本的备份把它们放在 ext 里，读取时两种都认）
  static const String scriptsKey = "scripts";

  /// 设置文件里的存档时间戳（毫秒），自动同步按它判断哪边新。
  /// 旧版和官方版的备份没有这一项，这时按云端文件的修改时间算
  static const String dataTimeKey = "dataTime";

  /// 设置文件里的附加项：导入的界面翻译（语言代码 → 翻译文件的内容）。
  /// 官方版和旧版不认识这一项，会忽略
  static const String languagesKey = "languages";

  /// 备份里的各个文件
  static const String followsFile = "SimpleLive_follows.json";
  static const String historiesFile = "SimpleLive_histories.json";
  static const String blockedWordFile = "SimpleLive_blocked_word.json";
  static const String bilibiliAccountFile = "SimpleLive_bilibili_account.json";
  static const String settingsFile = "SimpleLive_Settings.json";
  static const String tagsFile = "SimpleLive_Tags.json";

  /// 备份里的直播源（两种格式都认）；没有时返回 null，说明来自不支持直播源的版本
  Map<String, dynamic>? liveSources(String settingsFile) =>
      extraMap(settingsFile, liveSourcesKey) ??
      extraMap(settingsFile, liveSourcesKeyR14);

  /// 早期版本单独存放扩展数据的文件
  static const String legacyExtFile = "SimpleLive_ext.json";

  static Map<String, dynamic> pack(
    dynamic data, [
    dynamic ext,
    Map<String, dynamic>? extra,
  ]) =>
      {
        "data": data,
        if (ext != null) extKey: ext,
        ...?extra,
      };

  /// 在后台 isolate 解压备份并解析为 文件名 → JSON
  ///
  /// 必须是静态方法：在实例方法里创建的闭包可能捕获 this（如带 DAVClient 的控制器），
  /// 无法发送到 isolate。
  static Future<Map<String, dynamic>> decodeZip(List<int> data) {
    return Isolate.run(() => decodeZipSync(data));
  }

  static Map<String, dynamic> decodeZipSync(List<int> data) {
    var archive = ZipDecoder().decodeBytes(data);
    var result = <String, dynamic>{};
    for (var file in archive) {
      if (!file.isFile) {
        continue;
      }
      var name = file.name.split('/').last;
      if (!name.endsWith('.json')) {
        continue;
      }
      try {
        result[name] = json.decode(utf8.decode(file.content));
      } catch (_) {}
    }
    return result;
  }

  /// 解析后的备份：文件名 → JSON
  final Map<String, dynamic> files;
  SyncBackupFormat(this.files);

  Map? get _legacyExt {
    var file = files[legacyExtFile];
    var data = file is Map ? file["data"] : null;
    return data is Map ? data : null;
  }

  bool has(String name) => files[name] is Map;

  /// 备份的存档时间戳；旧版和官方版的备份没有，返回 null
  int? get dataTime {
    var value = extraValue(settingsFile, dataTimeKey);
    return value is num && value > 0 ? value.toInt() : null;
  }

  /// 备份里一共有多少个关注（官方平台、新平台、直播源平台）
  int get followCount =>
      mainList(followsFile).length +
      (extList(followsFile, 'follows')?.length ?? 0) +
      (extraList(followsFile, scriptsKey)?.length ?? 0);

  dynamic extraValue(String name, String key) {
    var file = files[name];
    return file is Map ? file[key] : null;
  }

  /// 官方版可读的部分
  dynamic main(String name) {
    var file = files[name];
    return file is Map ? file["data"] : null;
  }

  /// 本版本的补充部分；返回 null 表示备份里没有（来自官方版）
  dynamic ext(String name, String legacyKey) {
    var file = files[name];
    if (file is Map && file.containsKey(extKey)) {
      return file[extKey];
    }
    return _legacyExt?[legacyKey];
  }

  List mainList(String name) {
    var value = main(name);
    return value is List ? value : const [];
  }

  List? extList(String name, String legacyKey) {
    var value = ext(name, legacyKey);
    return value is List ? value : null;
  }

  /// 同一文件里 data/ext 之外的附加列表；没有时返回 null
  List? extraList(String name, String key) {
    var file = files[name];
    var value = file is Map ? file[key] : null;
    return value is List ? value : null;
  }

  /// 同一文件里 data/ext 之外的附加对象；没有时返回 null
  Map<String, dynamic>? extraMap(String name, String key) {
    var file = files[name];
    var value = file is Map ? file[key] : null;
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  Map<String, dynamic>? extMap(String name, String legacyKey) {
    var value = ext(name, legacyKey);
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }
}
