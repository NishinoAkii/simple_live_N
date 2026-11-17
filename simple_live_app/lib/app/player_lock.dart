import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// 播放器锁定（直播间全屏时的锁形按钮）
///
/// 锁定后返回键、返回手势、Esc、鼠标侧键都不退出正在看的内容；
/// 页面自己的返回由各自的 PopScope 拦截，这里给全局的快捷键（main.dart）判断用
class PlayerLock {
  static final locked = false.obs;

  static String get tip => "已锁定，点击锁形按钮解锁".t;

  static void showTip() {
    SmartDialog.showToast(tip);
  }
}
