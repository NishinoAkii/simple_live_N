import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/remote_sync_webdav_controller.dart';
import 'package:simple_live_app/services/webdav_addresses.dart';
import 'package:simple_live_app/widgets/none_border_circular_textfield.dart';
import 'package:simple_live_app/i18n/i18n.dart';

/// WebDAV 服务器地址的输入框，右边的下拉菜单里是用过的地址：
/// 点一下填进输入框，长按（电脑上也可以右键）写备注或删除
class WebDavAddressField extends StatefulWidget {
  final TextEditingController controller;
  final List<WebDavAddress> addresses;

  /// 正在用的地址，菜单里打勾；没登录时为空
  final String active;
  final ValueChanged<WebDavAddress> onEditNote;
  final bool autoFocus;

  const WebDavAddressField({
    required this.controller,
    required this.addresses,
    required this.onEditNote,
    this.active = "",
    this.autoFocus = false,
    super.key,
  });

  @override
  State<WebDavAddressField> createState() => _WebDavAddressFieldState();
}

class _WebDavAddressFieldState extends State<WebDavAddressField> {
  final _menu = MenuController();

  void _fill(WebDavAddress address) {
    _menu.close();
    widget.controller.value = TextEditingValue(
      text: address.uri,
      selection: TextSelection.collapsed(offset: address.uri.length),
    );
  }

  void _editNote(WebDavAddress address) {
    _menu.close();
    widget.onEditNote(address);
  }

  Widget _item(BuildContext context, WebDavAddress address, double width) {
    var theme = Theme.of(context);
    var active = widget.active.isNotEmpty &&
        address.key == WebDavAddressBook.keyOf(widget.active);
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: () => _fill(address),
        onLongPress: () => _editNote(address),
        onSecondaryTap: () => _editNote(address),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(
                active ? Icons.check : Icons.history,
                size: 18,
                color: active ? theme.colorScheme.primary : theme.hintColor,
              ),
              AppStyle.hGap12,
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (address.note.isNotEmpty)
                      Text(
                        address.note,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    Text(
                      address.uri,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: address.note.isEmpty
                          ? null
                          : theme.textTheme.bodySmall
                              ?.copyWith(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var width = constraints.maxWidth;
        var theme = Theme.of(context);
        return MenuAnchor(
          controller: _menu,
          style: MenuStyle(
            maximumSize: WidgetStatePropertyAll(Size(width, 360)),
          ),
          menuChildren: [
            for (var address in widget.addresses)
              _item(context, address, width),
            SizedBox(
              width: width,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
                child: Text(
                  "长按可编辑备注或删除".t,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
              ),
            ),
          ],
          builder: (context, menu, _) => NoneBorderCircularTextField(
            editingController: widget.controller,
            labelText: "WebDAV 服务器地址".t,
            hintText: "以 http:// 或 https:// 开头".t,
            prefixIcon: const Icon(Icons.public),
            autoFocus: widget.autoFocus,
            trailing: InkWell(
              child: const Icon(Icons.cancel, size: 20),
              onTap: () => widget.controller.clear(),
            ),
            // 输入框空着时也显示
            suffixIcon: widget.addresses.isEmpty
                ? null
                : IconButton(
                    tooltip: "历史地址".t,
                    icon: const Icon(Icons.arrow_drop_down),
                    onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                  ),
          ),
        );
      },
    );
  }
}

/// 备注对话框的结果
enum WebDavNoteAction { save, delete }

/// 给一个地址写备注；[canDelete] 为 true 时（不是正在用的地址）可以从列表里删掉
class WebDavAddressNoteDialog extends StatefulWidget {
  final WebDavAddress address;
  final bool canDelete;

  const WebDavAddressNoteDialog({
    required this.address,
    required this.canDelete,
    super.key,
  });

  @override
  State<WebDavAddressNoteDialog> createState() =>
      _WebDavAddressNoteDialogState();
}

class _WebDavAddressNoteDialogState extends State<WebDavAddressNoteDialog> {
  late final _note = TextEditingController(text: widget.address.note);

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _save() => Get.back(result: (WebDavNoteAction.save, _note.text));

  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);
    return AlertDialog(
      title: Text("地址备注".t),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              widget.address.uri,
              style:
                  theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            AppStyle.vGap12,
            TextField(
              controller: _note,
              autofocus: true,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                contentPadding: AppStyle.edgeInsetsA12,
                hintText: "例如：家里、外网".t,
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.canDelete)
          TextButton(
            onPressed: () => Get.back(result: (WebDavNoteAction.delete, "")),
            child: Text(
              "删除".t,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        TextButton(onPressed: Get.back, child: Text("取消".t)),
        TextButton(onPressed: _save, child: Text("保存".t)),
      ],
    );
  }
}

/// 已登录时换服务器地址：账号密码不变，确认后先测试连接，连得上才保存
class WebDavSwitchAddressDialog extends StatefulWidget {
  const WebDavSwitchAddressDialog({super.key});

  @override
  State<WebDavSwitchAddressDialog> createState() =>
      _WebDavSwitchAddressDialogState();
}

class _WebDavSwitchAddressDialogState extends State<WebDavSwitchAddressDialog> {
  final controller = Get.find<RemoteSyncWebDAVController>();
  late final _uri = TextEditingController(text: controller.activeUri.value);
  var _busy = false;

  @override
  void dispose() {
    _uri.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    var done = await controller.switchAddress(_uri.text);
    if (!mounted) {
      return;
    }
    if (done) {
      Get.back();
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);
    return AlertDialog(
      title: Text("切换服务器地址".t),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Obx(
              () => WebDavAddressField(
                controller: _uri,
                addresses: controller.addresses.toList(),
                active: controller.activeUri.value,
                onEditNote: controller.editAddressNote,
              ),
            ),
            Text(
              "账号和密码不变。连接测试通过则保存新地址。".t,
              style:
                  theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: Get.back, child: Text("取消".t)),
        TextButton(
          onPressed: _busy ? null : _confirm,
          child: Text("测试并保存".t),
        ),
      ],
    );
  }
}
