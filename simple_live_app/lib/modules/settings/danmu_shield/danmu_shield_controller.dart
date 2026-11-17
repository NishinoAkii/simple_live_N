import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class DanmuShieldController extends BaseController {
  final TextEditingController textEditingController = TextEditingController();
  final AppSettingsController settingsController =
      Get.find<AppSettingsController>();
  void add() {
    if (textEditingController.text.isEmpty) {
      SmartDialog.showToast("请输入关键词".t);
      return;
    }

    settingsController.addShieldList(textEditingController.text.trim());
    textEditingController.text = "";
  }

  void remove(String item) {
    settingsController.removeShieldList(item);
  }
}
