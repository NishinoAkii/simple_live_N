import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 带“撤销”的提示（屏蔽一个人以后）。样子和普通提示一样，右边多一个按钮
void showUndoToast(String text, VoidCallback onUndo) {
  SmartDialog.showToast(
    text,
    displayTime: const Duration(seconds: 4),
    consumeEvent: true,
    builder: (_) => UndoToast(
      text: text,
      onUndo: () {
        SmartDialog.dismiss(status: SmartStatus.toast);
        onUndo();
      },
    ),
  );
}

class UndoToast extends StatelessWidget {
  final String text;
  final VoidCallback onUndo;
  const UndoToast({required this.text, required this.onUndo, super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 30, vertical: 50),
      padding: const EdgeInsets.only(left: 20, right: 4),
      constraints: const BoxConstraints(maxWidth: 480),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(220),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
          TextButton(
            onPressed: onUndo,
            style: TextButton.styleFrom(
              foregroundColor: Colors.lightBlueAccent,
              minimumSize: const Size(56, 40),
            ),
            child: Text("撤销".t),
          ),
        ],
      ),
    );
  }
}
