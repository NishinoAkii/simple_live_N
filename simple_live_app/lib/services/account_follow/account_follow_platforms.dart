import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 各平台能不能从账号导入、能不能同步到账号
///
/// 名字、原因、说法在这里写的是简体中文（常量），读的时候按界面语言给
class AccountFollowPlatform {
  final String siteId;
  final String _name;
  String get name => _name.t;

  /// 能从账号导入关注
  final bool canImport;

  /// 不能导入时的原因
  final String? _importUnsupportedReason;
  String? get importUnsupportedReason => _importUnsupportedReason?.t;

  /// 能同步到账号（在 App 里关注/取关时）
  final bool canWriteBack;

  /// 不能同步到账号时的原因
  final String? _writeBackUnsupportedReason;
  String? get writeBackUnsupportedReason => _writeBackUnsupportedReason?.t;

  /// 开关的设置项（不能同步到账号时为空）
  final String? writeBackKey;

  /// 账号的说法（订阅 / 关注）
  final String _followWord;
  /// 句子里当动词用（“取消关注”“已订阅”），和标签页的“关注”分开译，见 [CoreText.text]
  String get followWord => "$_followWord##verb".t;

  const AccountFollowPlatform({
    required this.siteId,
    required String name,
    this.canImport = true,
    String? importUnsupportedReason,
    this.canWriteBack = false,
    String? writeBackUnsupportedReason,
    this.writeBackKey,
    String followWord = "关注",
  }) : _name = name,
       _importUnsupportedReason = importUnsupportedReason,
       _writeBackUnsupportedReason = writeBackUnsupportedReason,
       _followWord = followWord;
}

class AccountFollowPlatforms {
  /// 回写开关默认关闭
  static const bool writeBackDefault = false;

  static const List<AccountFollowPlatform> all = [
    AccountFollowPlatform(
      siteId: Constant.kBiliBili,
      name: "哔哩哔哩",
    ),
    AccountFollowPlatform(
      siteId: Constant.kDouyu,
      name: "斗鱼",
    ),
    AccountFollowPlatform(
      siteId: Constant.kKick,
      name: "Kick",
    ),
    AccountFollowPlatform(
      siteId: Constant.kYouTube,
      name: "YouTube",
      followWord: "订阅",
    ),
    AccountFollowPlatform(
      siteId: Constant.kTwitch,
      name: "Twitch",
    ),
    AccountFollowPlatform(
      siteId: Constant.kHuya,
      name: "虎牙",
      canImport: false,
      importUnsupportedReason: "App 还不能登录虎牙账号，暂不支持",
    ),
    AccountFollowPlatform(
      siteId: Constant.kDouyin,
      name: "抖音",
      canImport: false,
      importUnsupportedReason: "要另外登录抖音网页版，风控也严，暂不支持",
    ),
  ];

  static AccountFollowPlatform? of(String siteId) =>
      all.where((e) => e.siteId == siteId).firstOrNull;

  /// 全部回写开关（只在本机，不同步）
  static List<String> get writeBackKeys =>
      all.map((e) => e.writeBackKey).whereType<String>().toList();

  /// 读取回写开关；没设置过时为 [writeBackDefault]（关闭）
  static bool writeBackEnabled(
    String siteId,
    T Function<T>(String key, T defaultValue) read,
  ) {
    var platform = of(siteId);
    var key = platform?.writeBackKey;
    if (platform == null || !platform.canWriteBack || key == null) {
      return false;
    }
    return read<bool>(key, writeBackDefault);
  }
}
