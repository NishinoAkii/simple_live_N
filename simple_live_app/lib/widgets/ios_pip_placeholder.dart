import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/services/ios_pip/ios_pip_session.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// iOS 画中画开着时盖在应用内的播放器上：黑屏，提示正在小窗中播放。
/// 放在播放器的 Stack 里；没开小窗时不占位置、不挡点击
class IosPipPlaceholder extends StatelessWidget {
  final IosPipSession? session;
  const IosPipPlaceholder({required this.session, super.key});

  @override
  Widget build(BuildContext context) {
    var session = this.session;
    if (session == null) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: Obx(() {
        if (!session.active.value) {
          return const SizedBox.shrink();
        }
        return Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.picture_in_picture_alt_rounded,
                  color: Colors.white54,
                  size: 36,
                ),
                const SizedBox(height: 8),
                Text(
                  "正在小窗中播放".t,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                if (session.activeKind.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      session.activeKind,
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ),
                if (session.canExit)
                  TextButton(
                    onPressed: session.exit,
                    child: Text("回到应用内播放".t),
                  ),
              ],
            ),
          ),
        );
      }),
    );
  }
}
