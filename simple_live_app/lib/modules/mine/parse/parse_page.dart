import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/mine/parse/parse_controller.dart';
import 'package:simple_live_app/i18n/i18n.dart';

class ParsePage extends GetView<ParseController> {
  const ParsePage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("链接解析".t),
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          buildCard(
            context: context,
            child: ExpansionTile(
              title: Text("直播间跳转".t),
              childrenPadding: AppStyle.edgeInsetsH12,
              initiallyExpanded: true,
              children: [
                TextField(
                  minLines: 3,
                  maxLines: 3,
                  controller: controller.roomJumpToController,
                  textInputAction: TextInputAction.go,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText:
                        "粘贴哔哩哔哩/虎牙/斗鱼/抖音/Twitch/Kick/YouTube 直播间链接，YouTube 也可填 @频道名".t,
                    contentPadding: AppStyle.edgeInsetsA12,
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: Colors.grey.withAlpha(50),
                      ),
                    ),
                  ),
                  onSubmitted: controller.jumpToRoom,
                ),
                Container(
                  margin: AppStyle.edgeInsetsB4,
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () {
                      controller
                          .jumpToRoom(controller.roomJumpToController.text);
                    },
                    icon: const Icon(Remix.play_circle_line),
                    label: Text("打开直播间".t),
                  ),
                ),
              ],
            ),
          ),
          buildCard(
            context: context,
            child: ExpansionTile(
              title: Text("获取直链".t),
              childrenPadding: AppStyle.edgeInsetsH12,
              initiallyExpanded: true,
              children: [
                TextField(
                  minLines: 3,
                  maxLines: 3,
                  controller: controller.getUrlController,
                  textInputAction: TextInputAction.go,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText:
                        "粘贴哔哩哔哩/虎牙/斗鱼/抖音/Twitch/Kick/YouTube 直播间链接，YouTube 也可填 @频道名".t,
                    contentPadding: AppStyle.edgeInsetsA12,
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: Colors.grey.withAlpha(50),
                      ),
                    ),
                  ),
                  onSubmitted: controller.getPlayUrl,
                ),
                Container(
                  margin: AppStyle.edgeInsetsB4,
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: () {
                      controller.getPlayUrl(controller.getUrlController.text);
                    },
                    icon: const Icon(Remix.link),
                    label: Text("获取直链".t),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsV12,
            child: SelectableText('''支持这些链接：
哔哩哔哩：
https://live.bilibili.com/xxxxx
https://b23.tv/xxxxx
虎牙直播：
https://www.huya.com/xxxxx
斗鱼直播：
https://www.douyu.com/xxxxx
https://www.douyu.com/topic/xxx?rid=xxx
抖音直播：
https://v.douyin.com/xxxxx
https://live.douyin.com/xxxxx
https://webcast.amemv.com/webcast/reflow/xxxxx
'''.t, style: const TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Widget buildCard({required BuildContext context, required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: AppStyle.radius8,
        boxShadow: Get.isDarkMode
            ? []
            : [
                BoxShadow(
                  blurRadius: 8,
                  color: Colors.grey.withAlpha(50),
                )
              ],
      ),
      margin: AppStyle.edgeInsetsB12,
      child: Theme(
        data: Theme.of(context).copyWith(
          dividerColor: Colors.transparent,
        ),
        child: child,
      ),
    );
  }
}
