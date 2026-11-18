import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/desktop_shortcuts.dart';
import 'package:simple_live_app/app/gpu_preference.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/multi_window_widgets.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';
import 'package:simple_live_app/app/window_memory.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_menu.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';

/// 电脑端设置：快捷键、记住窗口、多开窗口、显卡偏好
class DesktopSettingsPage extends StatelessWidget {
  const DesktopSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("电脑端设置".t)),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: const [
          ShortcutSettingsSection(),
          WindowSettingsSection(),
          MultiWindowSettingsSection(),
          GpuSettingsSection(),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppStyle.edgeInsetsA12.copyWith(top: 8),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

/// 快捷键：开关、每个动作的按键、恢复默认
class ShortcutSettingsSection extends StatelessWidget {
  const ShortcutSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    var shortcuts = DesktopShortcuts.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle("快捷键".t),
        SettingsCard(
          child: Obx(
            () => Column(
              children: [
                SettingsSwitch(
                  value: shortcuts.enabled.value,
                  title: "启用快捷键".t,
                  subtitle: "在直播间使用，在输入框里打字时不生效".t,
                  onChanged: shortcuts.setEnabled,
                ),
                for (var action in ShortcutAction.values) ...[
                  AppStyle.divider,
                  _ShortcutRow(
                    action: action,
                    keyName: shortcuts.bindings.value[action],
                  ),
                ],
                AppStyle.divider,
                SettingsAction(
                  title: "恢复默认按键".t,
                  onTap: shortcuts.resetKeys,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  final ShortcutAction action;
  final LogicalKeyboardKey? keyName;
  const _ShortcutRow({required this.action, required this.keyName});

  @override
  Widget build(BuildContext context) {
    var key = keyName;
    return ListTile(
      title: Text(action.label, style: Theme.of(context).textTheme.bodyLarge),
      shape: RoundedRectangleBorder(borderRadius: AppStyle.radius8),
      contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 8),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (key == null)
            Text(
              "未设置".t,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium!
                  .copyWith(color: Colors.grey),
            )
          else
            ShortcutKeyCap(label: ShortcutKeys.label(key)),
          AppStyle.hGap4,
          const Icon(Icons.chevron_right, color: Colors.grey),
        ],
      ),
      onTap: () => editShortcut(context, action),
    );
  }
}

/// 打开改键的对话框，选好后保存
Future<void> editShortcut(BuildContext context, ShortcutAction action) async {
  var shortcuts = DesktopShortcuts.instance;
  var choice = await showDialog<ShortcutKeyChoice>(
    context: context,
    builder: (_) => ShortcutKeyDialog(
      action: action,
      bindings: shortcuts.bindings.value,
    ),
  );
  if (choice != null) {
    shortcuts.setKey(action, choice.key);
  }
}

/// 键帽样式的按键名
class ShortcutKeyCap extends StatelessWidget {
  final String label;
  final double fontSize;
  const ShortcutKeyCap({required this.label, this.fontSize = 13, super.key});

  @override
  Widget build(BuildContext context) {
    var color = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 28),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.outlineVariant),
        color: color.surfaceContainerHighest,
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w500),
      ),
    );
  }
}

/// 改键对话框的结果；[key] 为 null 时是关闭这个快捷键
class ShortcutKeyChoice {
  final LogicalKeyboardKey? key;
  const ShortcutKeyChoice(this.key);
}

/// 改键：按一个键，有冲突或者这个键不能用时给出提示。Esc 取消
class ShortcutKeyDialog extends StatefulWidget {
  final ShortcutAction action;
  final Map<ShortcutAction, LogicalKeyboardKey?> bindings;

  /// 一打开就当作已经按了这个键（布局检查用）
  final LogicalKeyboardKey? pressed;
  const ShortcutKeyDialog({
    required this.action,
    required this.bindings,
    this.pressed,
    super.key,
  });

  @override
  State<ShortcutKeyDialog> createState() => _ShortcutKeyDialogState();
}

class _ShortcutKeyDialogState extends State<ShortcutKeyDialog> {
  late LogicalKeyboardKey? _pressed = widget.pressed;

  @override
  void initState() {
    super.initState();
    // Windows：等按键时也断开输入法，不然字母键会被输入法拿走
    DesktopShortcuts.instance.beginRecording();
  }

  @override
  void dispose() {
    DesktopShortcuts.instance.endRecording();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    // Esc 交给对话框，关掉它
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    setState(() => _pressed = event.logicalKey);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    var pressed = _pressed;
    var current = widget.bindings[widget.action];
    var reserved =
        pressed == null ? null : ShortcutKeys.reservedReason(pressed);
    var conflict = pressed == null || reserved != null
        ? null
        : ShortcutKeys.conflict(widget.bindings, widget.action, pressed);
    var canSave = pressed != null && reserved == null && pressed != current;
    var theme = Theme.of(context);
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: AlertDialog(
        // 小窗口、字放大时内容能滚动
        scrollable: true,
        title: Text("设置「{action}」的按键".tf({"action": widget.action.label})),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text("请按下要使用的键".t, style: theme.textTheme.bodyMedium),
              AppStyle.vGap12,
              Center(
                child: pressed == null
                    ? Text(
                        current == null
                            ? "当前：未设置".t
                            : "当前：{key}"
                                .tf({"key": ShortcutKeys.label(current)}),
                        style: const TextStyle(color: Colors.grey),
                      )
                    : ShortcutKeyCap(
                        label: ShortcutKeys.label(pressed),
                        fontSize: 18,
                      ),
              ),
              if (reserved != null) ...[
                AppStyle.vGap12,
                Text(
                  reserved,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ] else if (conflict != null) ...[
                AppStyle.vGap12,
                Text(
                  "这个键已用于「{other}」，确定后「{other}」将不再有快捷键。"
                      .tf({"other": conflict.label}),
                  style: TextStyle(color: theme.colorScheme.tertiary),
                ),
              ],
              // 放在内容里：底部只留两个按钮，矮窗口里也放得下
              if (current != null) ...[
                AppStyle.vGap8,
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context)
                        .pop(const ShortcutKeyChoice(null)),
                    icon: const Icon(Icons.block, size: 18),
                    label: Text("关闭此快捷键".t),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text("取消".t),
          ),
          TextButton(
            onPressed: canSave
                ? () => Navigator.of(context).pop(ShortcutKeyChoice(pressed))
                : null,
            child: Text("确定".t),
          ),
        ],
      ),
    );
  }
}

/// 记住窗口
class WindowSettingsSection extends StatelessWidget {
  const WindowSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    var memory = WindowMemory.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppStyle.vGap12,
        _SectionTitle("窗口".t),
        SettingsCard(
          child: Obx(
            () => SettingsSwitch(
              value: memory.enabled.value,
              title: "记住窗口位置和大小".t,
              subtitle: "主窗口和小窗分别记住。保存的位置不在任何屏幕上时，窗口居中显示".t,
              onChanged: memory.setEnabled,
            ),
          ),
        ),
      ],
    );
  }
}

/// 多开窗口（只有 Windows 的主窗口）：启动时要不要恢复上次的多开窗口、
/// 打开上次的多开窗口、关闭全部多开窗口
class MultiWindowSettingsSection extends StatelessWidget {
  final bool? visible;
  const MultiWindowSettingsSection({this.visible, super.key});

  @override
  Widget build(BuildContext context) {
    if (!(visible ?? MultiWindow.canOpen)) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppStyle.vGap12,
        _SectionTitle("多开窗口".t),
        SettingsCard(
          child: Obx(() {
            var setting = StartupRestoreSetting.value.value;
            var saved = MultiWindow.restorableSet?.windows.length ?? 0;
            var open = MultiWindow.openCount.value;
            return Column(
              children: [
                SettingsMenu<StartupRestore>(
                  title: "启动时恢复上次的多开窗口".t,
                  value: setting,
                  valueMap: {
                    StartupRestore.ask: "询问".t,
                    StartupRestore.open: "直接打开".t,
                    StartupRestore.off: "不打开".t,
                  },
                  onChanged: StartupRestoreSetting.set,
                ),
                AppStyle.divider,
                SettingsAction(
                  title: saved > 0
                      ? "打开上次的多开窗口（{count} 个）".tf({"count": saved})
                      : "打开上次的多开窗口".t,
                  enabled: saved > 0,
                  onTap: saved > 0 ? restoreLastWindows : null,
                ),
                AppStyle.divider,
                SettingsAction(
                  title: open > 0
                      ? "关闭全部多开窗口（{count}）".tf({"count": open})
                      : "关闭全部多开窗口".t,
                  enabled: open > 0,
                  onTap: open > 0
                      ? () async {
                          var closed = await MultiWindow.closeAll();
                          SmartDialog.showToast(
                              "已关闭 {count} 个多开窗口".tf({"count": closed}));
                        }
                      : null,
                ),
              ],
            );
          }),
        ),
      ],
    );
  }
}

/// 显卡偏好（只有 Windows）
class GpuSettingsSection extends StatelessWidget {
  final bool? visible;
  const GpuSettingsSection({this.visible, super.key});

  @override
  Widget build(BuildContext context) {
    if (!(visible ?? GpuPreferenceSetting.supported)) {
      return const SizedBox.shrink();
    }
    var gpu = GpuPreferenceSetting.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppStyle.vGap12,
        _SectionTitle("显卡".t),
        SettingsCard(
          child: Obx(
            () => SettingsMenu<String>(
              title: "显卡偏好".t,
              subtitle: gpu.value.value == gpu.applied
                  ? "省电使用集成显卡，高性能使用独立显卡，视频也使用同一块显卡。更改后重启应用生效".t
                  : "重启应用后生效".t,
              value: gpu.value.value,
              valueMap: {
                GpuPreferenceSetting.auto: "自动".t,
                GpuPreferenceSetting.lowPower: "省电".t,
                GpuPreferenceSetting.highPerformance: "高性能".t,
              },
              onChanged: (value) => gpu.set(value),
            ),
          ),
        ),
      ],
    );
  }
}
