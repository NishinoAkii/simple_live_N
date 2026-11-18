import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 直播间的快捷键
enum ShortcutAction {
  fullscreen,
  danmaku,
  mute,
  refresh,
  collapseChat,
  pause,
  volumeUp,
  volumeDown,

  /// 放在最后：以前把 S 设给别的动作的，按键表里 S 还归那个动作（见 _dropDuplicates）
  screenshot;

  String get label => switch (this) {
        ShortcutAction.fullscreen => "全屏".t,
        ShortcutAction.danmaku => "弹幕开关".t,
        ShortcutAction.mute => "静音".t,
        ShortcutAction.refresh => "刷新".t,
        ShortcutAction.collapseChat => "收起聊天".t,
        ShortcutAction.pause => "暂停和继续".t,
        ShortcutAction.volumeUp => "音量加".t,
        ShortcutAction.volumeDown => "音量减".t,
        ShortcutAction.screenshot => "截图".t,
      };

  /// 按住不放时连续触发（只有音量）；别的按住只算一次
  bool get repeats =>
      this == ShortcutAction.volumeUp || this == ShortcutAction.volumeDown;
}

/// 按键表的规则：默认值、存取、冲突、不能用的键、显示的名字，以及 Windows 虚拟键码
class ShortcutKeys {
  static final Map<ShortcutAction, LogicalKeyboardKey> defaults = {
    ShortcutAction.fullscreen: LogicalKeyboardKey.keyF,
    ShortcutAction.danmaku: LogicalKeyboardKey.keyD,
    ShortcutAction.mute: LogicalKeyboardKey.keyM,
    ShortcutAction.refresh: LogicalKeyboardKey.keyR,
    ShortcutAction.collapseChat: LogicalKeyboardKey.keyC,
    ShortcutAction.pause: LogicalKeyboardKey.space,
    ShortcutAction.volumeUp: LogicalKeyboardKey.arrowUp,
    ShortcutAction.volumeDown: LogicalKeyboardKey.arrowDown,
    ShortcutAction.screenshot: LogicalKeyboardKey.keyS,
  };

  static Map<ShortcutAction, LogicalKeyboardKey?> get defaultMap =>
      Map<ShortcutAction, LogicalKeyboardKey?>.of(defaults);

  static final Set<LogicalKeyboardKey> _modifiers = {
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.numLock,
    LogicalKeyboardKey.scrollLock,
    LogicalKeyboardKey.fn,
    LogicalKeyboardKey.fnLock,
  };

  /// 不能设成快捷键的键，返回原因；能用时为 null
  static String? reservedReason(LogicalKeyboardKey key) {
    if (_modifiers.contains(key)) {
      return "Shift、Ctrl、Alt 这类键不能单独使用".t;
    }
    if (key == LogicalKeyboardKey.escape) {
      return "Esc 用于退出全屏".t;
    }
    if (key == LogicalKeyboardKey.tab) {
      return "Tab 用于切换焦点".t;
    }
    return null;
  }

  /// 读存着的按键表。没存过的动作用默认键；存成 0 的是关掉了
  static Map<ShortcutAction, LogicalKeyboardKey?> decode(String? text) {
    var map = defaultMap;
    if (text == null || text.isEmpty) {
      return map;
    }
    try {
      var json = jsonDecode(text);
      if (json is! Map) {
        return map;
      }
      for (var action in ShortcutAction.values) {
        var value = json[action.name];
        if (value is! int) {
          continue;
        }
        if (value == 0) {
          map[action] = null;
          continue;
        }
        var key = LogicalKeyboardKey(value);
        // 存着的键后来变成不能用了（或者数据坏了）：退回默认
        if (reservedReason(key) == null) {
          map[action] = key;
        }
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return _dropDuplicates(map);
  }

  static String encode(Map<ShortcutAction, LogicalKeyboardKey?> map) {
    return jsonEncode({
      for (var action in ShortcutAction.values)
        action.name: map[action]?.keyId ?? 0,
    });
  }

  /// 同一个键给了两个动作（比如手改了备份）：后面的关掉
  static Map<ShortcutAction, LogicalKeyboardKey?> _dropDuplicates(
      Map<ShortcutAction, LogicalKeyboardKey?> map) {
    var used = <LogicalKeyboardKey>{};
    for (var action in ShortcutAction.values) {
      var key = map[action];
      if (key != null && !used.add(key)) {
        map[action] = null;
      }
    }
    return map;
  }

  /// [key] 已经给了哪个别的动作
  static ShortcutAction? conflict(Map<ShortcutAction, LogicalKeyboardKey?> map,
      ShortcutAction action, LogicalKeyboardKey key) {
    for (var other in ShortcutAction.values) {
      if (other != action && map[other] == key) {
        return other;
      }
    }
    return null;
  }

  /// 把 [action] 设成 [key]（null 为关掉）。和别的动作冲突时，别的动作的键关掉
  static Map<ShortcutAction, LogicalKeyboardKey?> assign(
      Map<ShortcutAction, LogicalKeyboardKey?> map,
      ShortcutAction action,
      LogicalKeyboardKey? key) {
    var result = Map<ShortcutAction, LogicalKeyboardKey?>.of(map);
    if (key != null) {
      var other = conflict(result, action, key);
      if (other != null) {
        result[other] = null;
      }
    }
    result[action] = key;
    return result;
  }

  static ShortcutAction? actionOf(
      Map<ShortcutAction, LogicalKeyboardKey?> map, LogicalKeyboardKey key) {
    for (var action in ShortcutAction.values) {
      if (map[action] == key) {
        return action;
      }
    }
    return null;
  }

  /// 按键显示的名字，如 F、空格、↑
  static String label(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.space) return "空格".t;
    if (key == LogicalKeyboardKey.arrowUp) return "↑";
    if (key == LogicalKeyboardKey.arrowDown) return "↓";
    if (key == LogicalKeyboardKey.arrowLeft) return "←";
    if (key == LogicalKeyboardKey.arrowRight) return "→";
    var text = key.keyLabel;
    if (text.trim().isEmpty) {
      return "0x${key.keyId.toRadixString(16)}";
    }
    return text;
  }

  static final Map<int, int> _virtualKeys = () {
    var map = <int, int>{};
    for (var e in kWindowsToLogicalKey.entries) {
      map.putIfAbsent(e.value.keyId, () => e.key);
    }
    return map;
  }();

  /// Windows 的虚拟键码（VK_*）；没有对应的为 null
  static int? windowsVirtualKey(LogicalKeyboardKey key) =>
      _virtualKeys[key.keyId];

  static LogicalKeyboardKey? fromWindowsVirtualKey(int vk) =>
      kWindowsToLogicalKey[vk];
}

/// 一个能响应快捷键的页面（直播间的播放器）
class ShortcutTarget {
  /// 页面现在是不是显示在最上面
  final bool Function() isActive;

  /// 执行，返回是否处理了这个键；[repeat] 为按住不放时的连续触发
  final bool Function(ShortcutAction action, bool repeat) perform;

  ShortcutTarget({required this.isActive, required this.perform});
}

/// 快捷键：设置、匹配按键，以及 Windows 上在直播间里临时断开输入法
///
/// 页面把按键事件交给 [handle]。Windows 上中文输入法会吞掉字母键，所以在直播间里、
/// 又没在输入框里打字时，原生端断开输入法，并在输入法处理之前截下设好的键，
/// 经 [channel] 的 keyDown 发回来（参考 A 的做法）
class DesktopShortcuts {
  static DesktopShortcuts instance = DesktopShortcuts();

  /// 开关（默认开）
  static const String kEnabled = "ShortcutsEnabled";

  /// 按键表，见 [ShortcutKeys.encode]
  static const String kBindings = "ShortcutBindings";

  static const List<String> storageKeys = [kEnabled, kBindings];

  static const MethodChannel channel =
      MethodChannel("simple_live/desktop_shortcuts");

  final enabled = true.obs;
  final bindings =
      Rx<Map<ShortcutAction, LogicalKeyboardKey?>>(ShortcutKeys.defaultMap);

  final List<ShortcutTarget> _targets = [];

  /// 设置页正在等用户按键：输入法也要断开，不然字母键被输入法拿走
  int _recording = 0;

  bool _native = false;
  String _sent = "";

  static LocalStorageService? get _storage =>
      Get.isRegistered<LocalStorageService>()
          ? LocalStorageService.instance
          : null;

  /// 启动时调用
  void init() {
    load();
    if (Platform.isWindows) {
      _native = true;
      channel.setMethodCallHandler(_onNativeCall);
      FocusManager.instance.addListener(sync);
    }
  }

  void load() {
    var s = _storage;
    if (s == null) return;
    enabled.value = s.getValue<bool>(kEnabled, true);
    bindings.value = ShortcutKeys.decode(s.getValue<String>(kBindings, ""));
  }

  void setEnabled(bool value) {
    enabled.value = value;
    _storage?.setValue<bool>(kEnabled, value);
    sync();
  }

  void setKey(ShortcutAction action, LogicalKeyboardKey? key) {
    _save(ShortcutKeys.assign(bindings.value, action, key));
  }

  void resetKeys() => _save(ShortcutKeys.defaultMap);

  void _save(Map<ShortcutAction, LogicalKeyboardKey?> map) {
    bindings.value = map;
    _storage?.setValue<String>(kBindings, ShortcutKeys.encode(map));
    sync();
  }

  /// 焦点在输入框里（搜索等）
  static bool typingText() {
    var context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        (context.widget is EditableText ||
            context.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  /// 按键事件对应的动作。没开快捷键、松开按键、在打字、按着 Ctrl/Alt/Win 时为 null
  ShortcutAction? actionFor(KeyEvent event) {
    if (!enabled.value || event is KeyUpEvent || typingText()) {
      return null;
    }
    var keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return null;
    }
    return ShortcutKeys.actionOf(bindings.value, event.logicalKey);
  }

  /// 页面的 onKeyEvent 调用
  KeyEventResult handle(KeyEvent event, ShortcutTarget target) {
    var action = actionFor(event);
    if (action == null) {
      return KeyEventResult.ignored;
    }
    var repeat = event is KeyRepeatEvent;
    if (repeat && !action.repeats) {
      return KeyEventResult.handled;
    }
    return target.perform(action, repeat)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  /// 页面在 initState、dispose 里调用；那时还在构建，等这一帧完了再看焦点
  void attach(ShortcutTarget target) {
    _targets.add(target);
    scheduleMicrotask(sync);
  }

  void detach(ShortcutTarget target) {
    _targets.remove(target);
    scheduleMicrotask(sync);
  }

  /// 最上面那个页面
  ShortcutTarget? get activeTarget {
    for (var target in _targets.reversed) {
      if (target.isActive()) {
        return target;
      }
    }
    return null;
  }

  void beginRecording() {
    _recording++;
    sync();
  }

  void endRecording() {
    if (_recording > 0) _recording--;
    sync();
  }

  /// 原生端现在该怎样：断不断开输入法、截哪些键
  @visibleForTesting
  Map<String, Object> captureState() {
    var capture = enabled.value && activeTarget != null && !typingText();
    var keys = <int>[];
    if (capture) {
      for (var key in bindings.value.values) {
        var vk = key == null ? null : ShortcutKeys.windowsVirtualKey(key);
        if (vk != null) keys.add(vk);
      }
      keys.sort();
    }
    return {"imeOff": capture || _recording > 0, "keys": keys};
  }

  /// 页面、焦点、设置变了以后告诉原生端
  void sync() {
    if (!_native) return;
    var state = captureState();
    var text = jsonEncode(state);
    if (text == _sent) return;
    _sent = text;
    channel.invokeMethod("setCapture", state).catchError((e) {
      Log.logPrint(e);
    });
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method != "keyDown") return null;
    var args = call.arguments;
    if (args is! Map) return null;
    var vk = args["vk"];
    var repeat = args["repeat"] == true;
    var key = vk is int ? ShortcutKeys.fromWindowsVirtualKey(vk) : null;
    var target = activeTarget;
    if (key == null || target == null || !enabled.value || typingText()) {
      // 状态刚变（比如刚点进输入框），按键已经被截下来了：这个键作废，重新告诉原生端
      _sent = "";
      sync();
      return null;
    }
    var action = ShortcutKeys.actionOf(bindings.value, key);
    if (action == null || (repeat && !action.repeats)) return null;
    target.perform(action, repeat);
    return null;
  }
}

/// 把一个页面变成快捷键的目标：在最上面显示时响应快捷键。
///
/// 包一层 FocusScope：输入框失去焦点后，焦点落在这里，按键还能传到这一层
class ShortcutArea extends StatefulWidget {
  final bool Function(ShortcutAction action, bool repeat) onAction;
  final Widget child;
  const ShortcutArea({required this.onAction, required this.child, super.key});

  @override
  State<ShortcutArea> createState() => _ShortcutAreaState();
}

class _ShortcutAreaState extends State<ShortcutArea> {
  late final ShortcutTarget _target = ShortcutTarget(
    isActive: () => mounted && (_route?.isCurrent ?? true),
    perform: (action, repeat) => widget.onAction(action, repeat),
  );
  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    DesktopShortcuts.instance.attach(_target);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    DesktopShortcuts.instance.detach(_target);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      autofocus: true,
      onKeyEvent: (_, event) =>
          DesktopShortcuts.instance.handle(event, _target),
      child: widget.child,
    );
  }
}
