import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/remote_sync_webdav_controller.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/webdav_address_field.dart';
import 'package:simple_live_app/widgets/none_border_circular_textfield.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class RemoteSyncWebDAVConfigPage extends StatefulWidget {
  const RemoteSyncWebDAVConfigPage({super.key});

  @override
  State<RemoteSyncWebDAVConfigPage> createState() =>
      _RemoteSyncWebDAVConfigPageState();
}

class _RemoteSyncWebDAVConfigPageState
    extends State<RemoteSyncWebDAVConfigPage> {
  late TextEditingController _urlController;
  late TextEditingController _userNameController;
  late TextEditingController _passwordController;

  @override
  void initState() {
    _urlController = TextEditingController();
    _userNameController = TextEditingController();
    _passwordController = TextEditingController();
    super.initState();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userNameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("WebDAV 账号".t),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () {
              Utils.showInformationHelpDialog(
                content: [
                  Text("可以把数据备份到 WebDAV 服务器，也可以从那里恢复。\n".t),
                  Text(
                      "服务器地址要以 http:// 或 https:// 开头，比如坚果云（点一下复制）：".t),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: InkWell(
                      onTap: () {
                        Clipboard.setData(const ClipboardData(
                            text: "https://dav.jianguoyun.com/dav/"));
                        SmartDialog.showToast("已复制".t);
                      },
                      child: const Text("https://dav.jianguoyun.com/dav/"),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: GetX<RemoteSyncWebDAVController>(
        builder: (controller) {
          return SingleChildScrollView(
            child: Padding(
              padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 用过的地址在下拉菜单里，点一下填进来
                  WebDavAddressField(
                    controller: _urlController,
                    addresses: controller.addresses.toList(),
                    onEditNote: controller.editAddressNote,
                  ),
                  NoneBorderCircularTextField(
                    editingController: _userNameController,
                    labelText: "账号".t,
                    prefixIcon: const Icon(Icons.account_circle),
                    trailing: InkWell(
                        child: const Icon(
                          Icons.cancel,
                          size: 20,
                        ),
                        onTap: () => _userNameController.clear()),
                  ),
                  NoneBorderCircularTextField(
                    editingController: _passwordController,
                    labelText: "密码".t,
                    prefixIcon: const Icon(Icons.lock),
                    obscureText: controller.passwordVisible.value,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          child: const Icon(
                            Icons.cancel,
                            size: 20,
                          ),
                          onTap: () => _passwordController.clear(),
                        ),
                        AppStyle.hGap12,
                        InkWell(
                          child: controller.passwordVisible.value
                              ? const Icon(Icons.visibility_off)
                              : const Icon(Icons.visibility),
                          onTap: () {
                            controller.changePasswordVisible();
                          },
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 5, bottom: 15),
                    child: MaterialButton(
                      minWidth: double.infinity,
                      color: Theme.of(context).primaryColor,
                      focusElevation: 0,
                      elevation: 0,
                      highlightElevation: 4,
                      height: 40,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(8.0)),
                      ),
                      child: Text(
                        "登录".t,
                        style: const TextStyle(color: Colors.white),
                      ),
                      onPressed: () {
                        controller.doWebDAVLogin(
                          _urlController.text,
                          _userNameController.text,
                          _passwordController.text,
                        );
                      },
                    ),
                  )
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
