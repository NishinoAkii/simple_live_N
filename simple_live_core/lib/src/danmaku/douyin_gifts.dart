import 'package:fixnum/fixnum.dart';
import 'package:simple_live_core/src/model/live_message.dart';

import 'proto/douyin.pb.dart';
import 'package:simple_live_core/src/common/core_text.dart';

/// 抖音的送礼（WebcastGiftMessage），没有礼物名时返回 null。
///
/// 连击时同一次连击会推好几条（平台还可能重复推同一条）：
/// - groupId 是这次连击的标识，同一次连击的每条都一样
/// - groupCount 是每下送几个（1、10、66、520 这些“一组”的数量）
/// - repeatCount 是连击到第几下（累计），comboCount 一般和它相同
/// - repeatEnd = 1 表示连击结束（这条带最终的数量）
///
/// 所以数量是 groupCount × repeatCount（到目前为止的累计），连击用
/// 用户 id + 礼物 id + groupId 合并；没有 groupId 时用消息 id（重复推送的同一条合并）。
/// 价值是钻石：diamondCount 是一个礼物的钻石数，[LiveGiftMessage.priceText]
/// 是这一行累计的钻石（单价 × 数量），如“10 钻”；0 钻的礼物是免费的。
LiveGiftMessage? parseDouyinGift(GiftMessage msg) {
  var gift = msg.gift;
  var name = gift.name.trim();
  if (name.isEmpty) {
    return null;
  }
  var group = msg.groupCount.toInt();
  var repeat = msg.repeatCount.toInt();
  if (repeat <= 0) {
    repeat = msg.comboCount.toInt();
  }
  var count = repeat > 0
      ? (group > 0 ? group : 1) * repeat
      : (msg.totalCount > 0 ? msg.totalCount.toInt() : (group > 0 ? group : 1));

  var user = msg.user;
  var userKey = user.id > 0
      ? user.id.toString()
      : (user.idStr.isNotEmpty ? user.idStr : user.nickName);
  var giftId = msg.giftId > 0 ? msg.giftId : gift.id;
  String? comboId;
  if (msg.groupId > 0) {
    comboId = "$userKey:$giftId:${msg.groupId}";
  } else if (msg.common.msgId > 0) {
    comboId = "msg:${msg.common.msgId}";
  }

  var diamonds = gift.diamondCount;
  return LiveGiftMessage(
    comboId: comboId,
    userName: user.nickName,
    face: _firstUrl(user.avatarThumb),
    action: "送出",
    giftName: name,
    icon:
        _douyinGiftIcon(name, giftId, gift.image) ??
        _douyinGiftIcon(name, giftId, gift.icon),
    count: count,
    paid: diamonds > 0,
    priceText: diamonds > 0 ? "{p} 钻".tf({"p": diamonds * count}) : null,
    time: _douyinTime(msg.sendTime) ?? _douyinTime(msg.common.createTime),
    comboEnd: msg.repeatEnd == 1,
    userId: liveUserId(user.id > 0 ? user.id.toString() : user.idStr),
  );
}

/// 礼物图片：地址可能带签名，按图片的 uri（没有时按礼物 id）缓存
LiveEmote? _douyinGiftIcon(String name, Int64 giftId, Image image) {
  var url = _firstUrl(image);
  if (url.isEmpty) {
    return null;
  }
  var key = image.uri.isNotEmpty ? image.uri : giftId.toString();
  var width = image.width.toInt();
  var height = image.height.toInt();
  return LiveEmote(
    text: name,
    url: url,
    width: width > 0 && height > 0 ? width : 1,
    height: width > 0 && height > 0 ? height : 1,
    cacheKey: "douyin-gift:$key",
  );
}

/// 第一个 http 地址（地址列表里是同一张图的几个 CDN）
String _firstUrl(Image image) {
  for (var url in image.urlListList) {
    if (url.startsWith("http") || url.startsWith("//")) {
      return liveEmoteUrl(url);
    }
  }
  return "";
}

/// 抖音的时间有毫秒也有秒，0 时为 null
DateTime? _douyinTime(Int64 value) {
  var v = value.toInt();
  if (v <= 0) {
    return null;
  }
  if (v < 100000000000) {
    v *= 1000;
  }
  return DateTime.fromMillisecondsSinceEpoch(v);
}
