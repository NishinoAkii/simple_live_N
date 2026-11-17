import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 斗鱼账号。
///
/// 存三样东西：登录 Cookie、续期用的 LTP0 和设备号 dy_did。登录 Cookie 大约一周过期，
/// 斗鱼站点发现过期时调用 [renewCookie] 换一份新的，用户不用重新扫码。
class DouyuAccountService extends GetxService {
  static DouyuAccountService get instance => Get.find<DouyuAccountService>();

  final logined = false.obs;
  final name = "未登录".obs;

  String cookie = "";
  String ltp0 = "";
  String dyDid = "";

  /// 正在进行的续期，同时来的请求共用这一次
  Future<String?>? _renewal;

  /// 续期失败后，这个时间之前不再试
  DateTime? _retryAfter;

  DouyuSite get site => Sites.allSites[Constant.kDouyu]!.liveSite as DouyuSite;

  LocalStorageService get _store => LocalStorageService.instance;

  @override
  void onInit() {
    reload();
    super.onInit();
  }

  /// 从本地存储重新读一遍（同步恢复设置以后也调用）
  void reload() {
    cookie = _store.getValue(LocalStorageService.kDouyuCookie, "");
    ltp0 = _store.getValue(LocalStorageService.kDouyuLtp0, "");
    dyDid = _store.getValue(LocalStorageService.kDouyuPassportDid, "");
    _publish();
  }

  /// 扫码确认以后：记下凭据，再换一份登录 Cookie
  Future<void> signIn(DouyuCredentials credentials) async {
    _keep(
      cookie: credentials.cookie,
      ltp0: credentials.ltp0,
      dyDid: credentials.deviceId,
    );
    var fresh = await renewDouyuCookie(deviceId: dyDid, ltp0: ltp0);
    // 确认登录时拿到的字段，续期结果里不一定都有，两份合在一起
    _keep(cookie: DouyuCookie.merge(cookie, fresh));
  }

  /// 登录 Cookie 过期时换一份新的；没有凭据、或者 5 分钟内刚失败过时返回 null
  Future<String?> renewCookie() {
    if (ltp0.isEmpty || dyDid.isEmpty) {
      return Future.value(null);
    }
    var wait = _retryAfter;
    if (wait != null && DateTime.now().isBefore(wait)) {
      return Future.value(null);
    }
    return _renewal ??= _renew().whenComplete(() => _renewal = null);
  }

  Future<String?> _renew() async {
    try {
      var fresh = await renewDouyuCookie(deviceId: dyDid, ltp0: ltp0);
      _keep(cookie: DouyuCookie.merge(cookie, fresh));
      Log.i("斗鱼登录 Cookie 已自动续期");
      return cookie;
    } catch (e) {
      _retryAfter = DateTime.now().add(const Duration(minutes: 5));
      Log.w("斗鱼 Cookie 续期没成功：$e");
      return null;
    }
  }

  void logout() => _keep(cookie: "", ltp0: "", dyDid: "");

  /// 改了哪项存哪项，再更新界面和斗鱼站点
  void _keep({String? cookie, String? ltp0, String? dyDid}) {
    if (cookie != null) {
      this.cookie = cookie;
      _store.setValue(LocalStorageService.kDouyuCookie, cookie);
    }
    if (ltp0 != null) {
      this.ltp0 = ltp0;
      _store.setValue(LocalStorageService.kDouyuLtp0, ltp0);
    }
    if (dyDid != null) {
      this.dyDid = dyDid;
      _store.setValue(LocalStorageService.kDouyuPassportDid, dyDid);
    }
    _publish();
  }

  void _publish() {
    logined.value = cookie.isNotEmpty || ltp0.isNotEmpty;
    name.value = logined.value ? (_nickname() ?? "已登录") : "未登录";
    site
      ..cookie = cookie
      ..deviceId = dyDid
      ..onCookieExpired = renewCookie;
  }

  /// Cookie 里的昵称（acf_nickname，没有时用 acf_username），是 URL 编码的
  String? _nickname() {
    for (var key in const ["acf_nickname", "acf_username"]) {
      var raw = DouyuCookie.read(cookie, key);
      if (raw.isEmpty) {
        continue;
      }
      try {
        return Uri.decodeComponent(raw);
      } catch (_) {
        return raw;
      }
    }
    return null;
  }
}
