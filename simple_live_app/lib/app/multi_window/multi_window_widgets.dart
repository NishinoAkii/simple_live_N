import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/i18n/i18n.dart';
import 'package:simple_live_app/routes/app_navigation.dart';

/// 副窗口：主窗口不在了时，整个窗口顶上加一条提示（推开内容，不盖住）
class MultiWindowFrame extends StatelessWidget {
  const MultiWindowFrame({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!MultiWindow.isSecondary) {
      return child;
    }
    return Column(
      children: [
        Obx(
          () => MultiWindow.mainGone.value && !MultiWindow.noticeDismissed.value
              ? const MainGoneNotice()
              : const SizedBox.shrink(),
        ),
        Expanded(child: child),
      ],
    );
  }
}

/// “主窗口已关闭，改动不会保存”
class MainGoneNotice extends StatelessWidget {
  const MainGoneNotice({super.key});

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Icon(Icons.info_outline,
                  size: 18, color: scheme.onErrorContainer),
              AppStyle.hGap8,
              Expanded(
                child: Text(
                  "主窗口已关闭，这个窗口里对关注、观看记录、屏蔽和备注的修改都不会保存".t,
                  style:
                      TextStyle(fontSize: 13, color: scheme.onErrorContainer),
                ),
              ),
              TextButton(
                onPressed: () => MultiWindow.noticeDismissed.value = true,
                child: Text("知道了".t),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 副窗口里设置、同步这些页面只能看：点不了、拖不了，滚轮照常能滚，
/// 标题栏（返回按钮）照常能点；底下一条提示去主窗口改
class MultiWindowRoutes {
  MultiWindowRoutes._();

  static const readOnlyPrefixes = [
    "/settings",
    "/sync",
    "/local_sync",
    "/remote_sync",
  ];

  static bool isReadOnly(String name) => readOnlyPrefixes
      .any((prefix) => name == prefix || name.startsWith("$prefix/"));

  /// 副窗口里把这些页面换成只读的；主窗口原样返回
  static List<GetPage> guard(List<GetPage> routes) {
    if (!MultiWindow.isSecondary) {
      return routes;
    }
    return [
      for (var route in routes)
        isReadOnly(route.name)
            ? route.copy(page: () => ReadOnlySettings(child: route.page()))
            : route,
    ];
  }
}

class ReadOnlySettings extends StatelessWidget {
  const ReadOnlySettings({required this.child, super.key});
  final Widget child;

  static DateTime? _lastToast;

  static void _onBlocked() {
    var now = DateTime.now();
    if (_lastToast != null &&
        now.difference(_lastToast!) < const Duration(seconds: 2)) {
      return;
    }
    _lastToast = now;
    SmartDialog.showToast("多开窗口里的设置只能查看，请在主窗口中修改".t);
  }

  @override
  Widget build(BuildContext context) {
    var top = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return Column(
      children: [
        Expanded(
          child: RawGestureDetector(
            gestures: {
              _BlockRecognizer:
                  GestureRecognizerFactoryWithHandlers<_BlockRecognizer>(
                () => _BlockRecognizer(),
                (recognizer) => recognizer
                  ..topInset = top
                  ..onBlocked = _onBlocked,
              ),
            },
            child: child,
          ),
        ),
        const ReadOnlySettingsHint(),
      ],
    );
  }
}

class ReadOnlySettingsHint extends StatelessWidget {
  const ReadOnlySettingsHint({super.key});

  @override
  Widget build(BuildContext context) {
    var scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.lock_outline,
                  size: 18, color: scheme.onSecondaryContainer),
              AppStyle.hGap8,
              Expanded(
                child: Text(
                  "多开窗口里的设置只能查看，请在主窗口中修改".t,
                  style: TextStyle(
                      fontSize: 13, color: scheme.onSecondaryContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一按下就赢下手势：下面的按钮、开关、拖动都收不到。滚轮不走手势竞争，照常能滚。
/// 标题栏那一截（[topInset] 以上）不管
class _BlockRecognizer extends OneSequenceGestureRecognizer {
  double topInset = 0;
  VoidCallback? onBlocked;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      event.localPosition.dy >= topInset && super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }

  @override
  void acceptGesture(int pointer) {
    super.acceptGesture(pointer);
    onBlocked?.call();
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => "read-only settings";
}

/// 「在新窗口打开」和「关闭全部多开窗口」（只有电脑上的主窗口有）。
/// [close] 先关掉所在的弹出卡片；[afterOpen] 新窗口开好以后调用；
/// [userName]、[title] 是知道的主播名和标题（记在“上次的一组”里显示用）
List<Widget> multiWindowTiles(
  Site site,
  String roomId, {
  required VoidCallback close,
  VoidCallback? afterOpen,
  String userName = "",
  String title = "",
}) {
  if (!MultiWindow.canOpen) {
    return const [];
  }
  var count = MultiWindow.openCount.value;
  return [
    ListTile(
      leading: const Icon(Icons.add_to_queue),
      title: Text("在新窗口打开".t),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        close();
        if (await MultiWindow.openRoom(site, roomId,
            title: title, userName: userName)) {
          afterOpen?.call();
        }
      },
    ),
    if (count > 0)
      ListTile(
        leading: const Icon(Icons.cancel_presentation),
        title: Text("关闭全部多开窗口（{count}）".tf({"count": count})),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          close();
          var closed = await MultiWindow.closeAll();
          SmartDialog.showToast("已关闭 {count} 个多开窗口".tf({"count": closed}));
        },
      ),
  ];
}

/// 首页、分类、搜索里长按（或右键）直播间卡片：在新窗口打开
Future<void> showRoomWindowSheet(Site site, String roomId, String userName) {
  return showModalBottomSheet(
    context: Get.context!,
    constraints: const BoxConstraints(maxWidth: 600),
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    userName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  AppStyle.vGap8,
                  Text(site.name),
                ],
              ),
            ),
            const Divider(height: 1),
            ...multiWindowTiles(
              site,
              roomId,
              close: () => Navigator.of(sheetContext).pop(),
              userName: userName,
            ),
          ],
        ),
      ),
    ),
  );
}

/// 历史页标题栏左边、刷新按钮旁边的“打开上次的窗口”（电脑上的主窗口、记着上次的一组时才有，
/// 见 [MultiWindow.restorableSet]）。提示里是几个窗口和主播名
class RestoreWindowsButton extends StatelessWidget {
  const RestoreWindowsButton({required this.windows, super.key});
  final WindowSet windows;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: "${"打开上次的 {count} 个窗口".tf({
            "count": windows.windows.length
          })}\n${windows.labels}",
      icon: const Icon(Icons.filter_none),
      onPressed: restoreLastWindows,
    );
  }
}

bool _startupChecked = false;

/// 主窗口启动后调用一次：第一帧出来、窗口显示以后，上次开着多开窗口时按设置
/// 问要不要都打开（应用里的对话框）、直接打开或者不管
void scheduleStartupRestore() {
  if (!MultiWindow.canOpen || _startupChecked) {
    return;
  }
  _startupChecked = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Future.delayed(const Duration(milliseconds: 1500), runStartupRestore);
  });
}

/// 按“启动时恢复上次的多开窗口”的设置做。选“不用”时上次的一组留着，历史页还能打开
Future<void> runStartupRestore() async {
  var set = MultiWindow.restorableSet;
  var action = StartupRestoreSetting.decide(
    StartupRestoreSetting.value.value,
    canOpen: MultiWindow.canOpen,
    last: set,
    // 已经在直播间里（带着链接启动、点了通知进来的）时不打扰
    forRoom: MultiWindow.startedForRoom || MultiWindow.mainRoom != null,
  );
  switch (action) {
    case StartupAction.none:
      return;
    case StartupAction.open:
      await restoreLastWindows();
    case StartupAction.ask:
      var yes = await Utils.showAlertDialog(
        "上次开着 {count} 个窗口，要都打开吗？".tf({"count": set!.windows.length}),
        title: "多开窗口".t,
        confirm: "都打开".t,
        cancel: "不用".t,
      );
      if (yes) {
        await restoreLastWindows();
      }
  }
}

/// 打开上次的一组，提示开了几个；主窗口不在直播间里时，在主窗口打开它上次在看的直播间
Future<void> restoreLastWindows() async {
  var result = await MultiWindow.restoreLast();
  if (result == null) {
    return;
  }
  SmartDialog.showToast(result.message);
  var room = result.mainRoom;
  var site = room == null ? null : Sites.allSites[room.siteId];
  if (room != null && site != null) {
    AppNavigator.toLiveRoomDetail(site: site, roomId: room.roomId);
  }
}
