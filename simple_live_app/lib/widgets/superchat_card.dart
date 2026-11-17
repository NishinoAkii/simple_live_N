import 'package:flutter/material.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/widgets/emote_text.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// SC 卡片
///
/// 倒计时由外部传入（直播间控制器每秒更新），卡片本身不计时，
/// 避免列表复用时把一张卡的倒计时套到另一条 SC 上。
class SuperChatCard extends StatelessWidget {
  final LiveSuperChatMessage message;

  /// 剩余显示秒数
  final int remaining;

  /// 是否显示“直播间显示中 / 已结束”
  final bool showStatus;

  /// 给这个人写的备注，名字后面灰色显示
  final String? remark;

  const SuperChatCard(
    this.message, {
    required this.remaining,
    this.showStatus = true,
    this.remark,
    Key? key,
  }) : super(key: key);

  bool get active => remaining > 0;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: active ? 1 : 0.55,
      child: ClipRRect(
        borderRadius: AppStyle.radius8,
        child: Container(
          decoration: BoxDecoration(
            color: Utils.convertHexColor(message.backgroundColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: AppStyle.edgeInsetsA8,
                child: Row(
                  children: [
                    NetImage(
                      message.face,
                      width: 48,
                      height: 48,
                      borderRadius: 36,
                    ),
                    AppStyle.hGap12,
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text.rich(
                            TextSpan(
                              text: message.userName,
                              children: [
                                if (remark != null)
                                  TextSpan(
                                    text: " ($remark)",
                                    style: const TextStyle(color: Colors.grey),
                                  ),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.black333,
                            ),
                          ),
                          Text(
                            // YouTube 等境外平台带币种（如“$5.00”），国内平台按人民币显示
                            message.priceText ?? "￥${message.price}",
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          active ? "${remaining}s" : "已结束".t,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.grey,
                          ),
                        ),
                        if (showStatus)
                          Text(
                            active ? "直播间显示中".t : "直播间已不显示".t,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: Utils.convertHexColor(message.backgroundBottomColor),
                ),
                padding: AppStyle.edgeInsetsA8,
                // 付费贴纸显示图片，留言里的表情显示为图片
                child: Text.rich(
                  emoteStickerSpan(
                        message.sticker,
                        fontSize: 14,
                        style: const TextStyle(color: Colors.white),
                      ) ??
                      emoteTextSpan(
                        message.message,
                        message.emotes,
                        fontSize: 14,
                        style: const TextStyle(color: Colors.white),
                      ),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
