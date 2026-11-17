import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';

/// 快捷键的静音：只把这个播放器的音量调成 0，不改设置里记着的音量；
/// 取消静音、调音量时回到设置里的音量
class PlayerMute {
  static final Expando<bool> _muted = Expando("PlayerMute");

  static bool isMuted(Player player) => _muted[player] ?? false;

  /// 切换，返回切换后是否静音
  static bool toggle(Player player, {double? volume}) {
    var muted = !isMuted(player);
    _muted[player] = muted;
    player.setVolume(muted
        ? 0
        : volume ?? AppSettingsController.instance.playerVolume.value);
    return muted;
  }

  /// 调了音量：不再算静音（新音量由调用的地方设）
  static void clear(Player player) {
    _muted[player] = false;
  }

  /// 音量 ±[delta]（0–100），返回新的音量
  static double step(double current, double delta) =>
      (current + delta).clamp(0.0, 100.0).toDouble();
}
