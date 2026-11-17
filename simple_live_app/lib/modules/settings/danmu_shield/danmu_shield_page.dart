import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/live_room/user_card/user_block_list.dart';
import 'package:simple_live_app/modules/settings/danmu_shield/danmu_shield_controller.dart';
import 'package:simple_live_app/services/chat_users/chat_users_service.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class DanmuShieldPage extends GetView<DanmuShieldController> {
  const DanmuShieldPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("弹幕屏蔽".t),
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          TextField(
            controller: controller.textEditingController,
            decoration: InputDecoration(
              contentPadding: AppStyle.edgeInsetsH12,
              border: const OutlineInputBorder(),
              hintText: "请输入关键词或正则表达式".t,
              suffixIcon: TextButton.icon(
                onPressed: controller.add,
                icon: const Icon(Icons.add),
                label: Text("添加".t),
              ),
            ),
            onSubmitted: (e) {
              controller.add();
            },
          ),
          AppStyle.vGap4,
          Text(
            '前后加 / 算正则表达式，如 /\\d+/ 屏蔽带数字的弹幕'.t,
            style: Get.textTheme.bodySmall,
          ),
          AppStyle.vGap12,
          Obx(
            () => Text(
              "已添加 {shieldListCount} 个关键词（点一下可移除）".tf({"shieldListCount": controller.settingsController.shieldList.length}),
              style: Get.textTheme.titleSmall,
            ),
          ),
          AppStyle.vGap12,
          Obx(
            () => Wrap(
              runSpacing: 12,
              spacing: 12,
              children: controller.settingsController.shieldList
                  .map(
                    (item) => InkWell(
                      borderRadius: AppStyle.radius24,
                      onTap: () {
                        controller.remove(item);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: AppStyle.radius24,
                        ),
                        padding: AppStyle.edgeInsetsH12.copyWith(
                          top: 4,
                          bottom: 4,
                        ),
                        child: Text(
                          item,
                          style: Get.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          // 屏蔽的人（在弹幕卡片里屏蔽的）
          if (ChatUsersService.maybeInstance case var users?) ...[
            AppStyle.vGap24,
            UserBlockSection(service: users),
          ],
        ],
      ),
    );
  }
}
