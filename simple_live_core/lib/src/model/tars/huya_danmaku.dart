// ignore_for_file: no_leading_underscores_for_local_identifiers

import 'dart:typed_data';

import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';

class HYPushMessage extends TarsStruct {
  int pushType = 0;
  int uri = 0;
  List<int> msg = <int>[];
  int protocolType = 0;

  @override
  void readFrom(TarsInputStream _is) {
    pushType = _is.read(pushType, 0, false);
    uri = _is.read(uri, 1, false);
    msg = _is.readBytes(2, false);
    protocolType = _is.read(protocolType, 3, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {}

  @override
  Object deepCopy() {
    return HYPushMessage()
      ..pushType = pushType
      ..uri = uri
      ..msg = List<int>.from(msg)
      ..protocolType = protocolType;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

class HYSender extends TarsStruct {
  int uid = 0;
  int lMid = 0;
  String nickName = "";
  int gender = 0;

  @override
  void readFrom(TarsInputStream _is) {
    uid = _is.read(uid, 0, false);
    lMid = _is.read(lMid, 0, false);
    nickName = _is.read(nickName, 2, false);
    gender = _is.read(gender, 3, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {}

  @override
  Object deepCopy() {
    return HYSender()
      ..uid = uid
      ..lMid = lMid
      ..nickName = nickName
      ..gender = gender;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

class HYMessage extends TarsStruct {
  HYSender userInfo = HYSender();
  String content = "";
  HYBulletFormat bulletFormat = HYBulletFormat();

  @override
  void readFrom(TarsInputStream _is) {
    userInfo = _is.readTarsStruct(userInfo, 0, false) as HYSender;
    content = _is.read(content, 3, false);
    bulletFormat = _is.readTarsStruct(bulletFormat, 6, false) as HYBulletFormat;
  }

  @override
  void writeTo(TarsOutputStream _os) {}

  @override
  Object deepCopy() {
    return HYMessage()
      ..userInfo = userInfo.deepCopy() as HYSender
      ..content = content
      ..bulletFormat = bulletFormat.deepCopy() as HYBulletFormat;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

class HYBulletFormat extends TarsStruct {
  int fontColor = 0;
  int fontSize = 4;
  int textSpeed = 0;
  int transitionType = 1;

  @override
  void readFrom(TarsInputStream _is) {
    fontColor = _is.read(fontColor, 0, false);
    fontSize = _is.read(fontSize, 1, false);
    textSpeed = _is.read(textSpeed, 2, false);
    transitionType = _is.read(transitionType, 3, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {}

  @override
  Object deepCopy() {
    return HYBulletFormat()
      ..fontColor = fontColor
      ..fontSize = fontSize
      ..textSpeed = textSpeed
      ..transitionType = transitionType;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

// 以下是聊天（MessageNotice）里发言人身份用到的结构，字段号按虎牙网页端的协议定义。
// writeTo 只在测试里拼消息用

/// 贵族等级（NobleLevelInfo）
class HuyaNobleLevelInfo extends TarsStruct {
  int iNobleLevel = 0; // tag 0
  int iAttrType = 0; // tag 1

  @override
  void readFrom(TarsInputStream _is) {
    iNobleLevel = _is.read(iNobleLevel, 0, false);
    iAttrType = _is.read(iAttrType, 1, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iNobleLevel, 0);
    _os.write(iAttrType, 1);
  }

  @override
  Object deepCopy() => HuyaNobleLevelInfo()
    ..iNobleLevel = iNobleLevel
    ..iAttrType = iAttrType;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 发送人（SenderInfo）里的贵族字段：tag 5 iNobleLevel、tag 6 tNobleLevelInfo
class HuyaSenderNoble extends TarsStruct {
  int lUid = 0; // tag 0
  int iNobleLevel = 0; // tag 5
  HuyaNobleLevelInfo tNobleLevelInfo = HuyaNobleLevelInfo(); // tag 6

  @override
  void readFrom(TarsInputStream _is) {
    lUid = _is.read(lUid, 0, false);
    iNobleLevel = _is.read(iNobleLevel, 5, false);
    tNobleLevelInfo =
        _is.readTarsStruct(tNobleLevelInfo, 6, false) as HuyaNobleLevelInfo;
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lUid, 0);
    _os.write(iNobleLevel, 5);
    _os.write(tNobleLevelInfo, 6);
  }

  @override
  Object deepCopy() => HuyaSenderNoble()
    ..lUid = lUid
    ..iNobleLevel = iNobleLevel
    ..tNobleLevelInfo = tNobleLevelInfo.deepCopy() as HuyaNobleLevelInfo;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 聊天（MessageNotice）里和发言人身份有关的字段：tag 0 发送人的贵族、
/// tag 8 前缀装饰、tag 9 后缀装饰。和 [HYMessage] 分开读，读不了不影响消息本身
class HuyaMessageNoticeBadges extends TarsStruct {
  HuyaSenderNoble tUserInfo = HuyaSenderNoble(); // tag 0
  List<HuyaDecorationInfo> vDecorationPrefix = []; // tag 8
  List<HuyaDecorationInfo> vDecorationSuffix = []; // tag 9

  @override
  void readFrom(TarsInputStream _is) {
    tUserInfo = _is.readTarsStruct(tUserInfo, 0, false) as HuyaSenderNoble;
    vDecorationPrefix = _is.readList<HuyaDecorationInfo>(
      [HuyaDecorationInfo()],
      8,
      false,
    );
    vDecorationSuffix = _is.readList<HuyaDecorationInfo>(
      [HuyaDecorationInfo()],
      9,
      false,
    );
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(tUserInfo, 0);
    _os.write(vDecorationPrefix, 8);
    _os.write(vDecorationSuffix, 9);
  }

  @override
  Object deepCopy() => HuyaMessageNoticeBadges()
    ..tUserInfo = tUserInfo.deepCopy() as HuyaSenderNoble
    ..vDecorationPrefix = [
      for (var e in vDecorationPrefix) e.deepCopy() as HuyaDecorationInfo,
    ]
    ..vDecorationSuffix = [
      for (var e in vDecorationSuffix) e.deepCopy() as HuyaDecorationInfo,
    ];

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 消息的装饰（DecorationInfo）：MessageNotice 的 tag 8（前缀）、tag 9（后缀）。
/// [vData] 按 [iAppId] 是不同的结构，如 10400 粉丝牌是 [HuyaBadgeInfo]
class HuyaDecorationInfo extends TarsStruct {
  int iAppId = 0; // tag 0
  int iViewType = 0; // tag 1
  Uint8List vData = Uint8List(0); // tag 2
  int lSourceId = 0; // tag 3
  int iType = 0; // tag 4

  @override
  void readFrom(TarsInputStream _is) {
    iAppId = _is.read(iAppId, 0, false);
    iViewType = _is.read(iViewType, 1, false);
    vData = _is.readBytes(2, false);
    lSourceId = _is.read(lSourceId, 3, false);
    iType = _is.read(iType, 4, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iAppId, 0);
    _os.write(iViewType, 1);
    _os.write(vData, 2);
    _os.write(lSourceId, 3);
    _os.write(iType, 4);
  }

  @override
  Object deepCopy() => HuyaDecorationInfo()
    ..iAppId = iAppId
    ..iViewType = iViewType
    ..vData = Uint8List.fromList(vData)
    ..lSourceId = lSourceId
    ..iType = iType;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 粉丝牌（BadgeInfo，装饰 10400），只读前面用到的字段
class HuyaBadgeInfo extends TarsStruct {
  int lUid = 0; // tag 0
  int lBadgeId = 0; // tag 1
  String sPresenterNickName = ""; // tag 2
  String sBadgeName = ""; // tag 3
  int iBadgeLevel = 0; // tag 4

  @override
  void readFrom(TarsInputStream _is) {
    lUid = _is.read(lUid, 0, false);
    lBadgeId = _is.read(lBadgeId, 1, false);
    sPresenterNickName = _is.read(sPresenterNickName, 2, false);
    sBadgeName = _is.read(sBadgeName, 3, false);
    iBadgeLevel = _is.read(iBadgeLevel, 4, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lUid, 0);
    _os.write(lBadgeId, 1);
    _os.write(sPresenterNickName, 2);
    _os.write(sBadgeName, 3);
    _os.write(iBadgeLevel, 4);
  }

  @override
  Object deepCopy() => HuyaBadgeInfo()
    ..lUid = lUid
    ..lBadgeId = lBadgeId
    ..sPresenterNickName = sPresenterNickName
    ..sBadgeName = sBadgeName
    ..iBadgeLevel = iBadgeLevel;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 贵族（NobleBase，装饰 10200）：tag 2 等级、tag 3 名称（实测为空），
/// tag 22 是 [HuyaNobleLevelInfo]
class HuyaNobleBase extends TarsStruct {
  int lUid = 0; // tag 0
  String sNickName = ""; // tag 1
  int iLevel = 0; // tag 2
  String sName = ""; // tag 3
  HuyaNobleLevelInfo tLevelInfo = HuyaNobleLevelInfo(); // tag 22

  @override
  void readFrom(TarsInputStream _is) {
    lUid = _is.read(lUid, 0, false);
    sNickName = _is.read(sNickName, 1, false);
    iLevel = _is.read(iLevel, 2, false);
    sName = _is.read(sName, 3, false);
    tLevelInfo =
        _is.readTarsStruct(tLevelInfo, 22, false) as HuyaNobleLevelInfo;
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lUid, 0);
    _os.write(sNickName, 1);
    _os.write(iLevel, 2);
    _os.write(sName, 3);
    _os.write(tLevelInfo, 22);
  }

  @override
  Object deepCopy() => HuyaNobleBase()
    ..lUid = lUid
    ..sNickName = sNickName
    ..iLevel = iLevel
    ..sName = sName
    ..tLevelInfo = tLevelInfo.deepCopy() as HuyaNobleLevelInfo;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 消费等级（ConsumeLevelBadgeInfo，装饰 11200）
class HuyaConsumeLevelBadgeInfo extends TarsStruct {
  int lUid = 0; // tag 0
  int iLevel = 0; // tag 1
  int iBadgeStyle = 0; // tag 2
  int iIsPolished = 0; // tag 3

  @override
  void readFrom(TarsInputStream _is) {
    lUid = _is.read(lUid, 0, false);
    iLevel = _is.read(iLevel, 1, false);
    iBadgeStyle = _is.read(iBadgeStyle, 2, false);
    iIsPolished = _is.read(iIsPolished, 3, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lUid, 0);
    _os.write(iLevel, 1);
    _os.write(iBadgeStyle, 2);
    _os.write(iIsPolished, 3);
  }

  @override
  Object deepCopy() => HuyaConsumeLevelBadgeInfo()
    ..lUid = lUid
    ..iLevel = iLevel
    ..iBadgeStyle = iBadgeStyle
    ..iIsPolished = iIsPolished;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 房管（GetUserTypeRsp，装饰 10100），只读用到的字段：tag 6 是房管图标
class HuyaUserTypeInfo extends TarsStruct {
  int lUid = 0; // tag 0
  int lPresenterUid = 0; // tag 1
  int iType = 0; // tag 3
  String sManagerDecorationUrl = ""; // tag 6

  @override
  void readFrom(TarsInputStream _is) {
    lUid = _is.read(lUid, 0, false);
    lPresenterUid = _is.read(lPresenterUid, 1, false);
    iType = _is.read(iType, 3, false);
    sManagerDecorationUrl = _is.read(sManagerDecorationUrl, 6, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lUid, 0);
    _os.write(lPresenterUid, 1);
    _os.write(iType, 3);
    _os.write(sManagerDecorationUrl, 6);
  }

  @override
  Object deepCopy() => HuyaUserTypeInfo()
    ..lUid = lUid
    ..lPresenterUid = lPresenterUid
    ..iType = iType
    ..sManagerDecorationUrl = sManagerDecorationUrl;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 公会管理（装饰 10090）。网页端没有这个结构的名字，字段名是按实抓的内容起的：
/// tag 3 是图标
class HuyaGuildAdminInfo extends TarsStruct {
  int lGuildId = 0; // tag 0
  int lPresenterUid = 0; // tag 1
  int iType = 0; // tag 2
  String sIconUrl = ""; // tag 3

  @override
  void readFrom(TarsInputStream _is) {
    lGuildId = _is.read(lGuildId, 0, false);
    lPresenterUid = _is.read(lPresenterUid, 1, false);
    iType = _is.read(iType, 2, false);
    sIconUrl = _is.read(sIconUrl, 3, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lGuildId, 0);
    _os.write(lPresenterUid, 1);
    _os.write(iType, 2);
    _os.write(sIconUrl, 3);
  }

  @override
  Object deepCopy() => HuyaGuildAdminInfo()
    ..lGuildId = lGuildId
    ..lPresenterUid = lPresenterUid
    ..iType = iType
    ..sIconUrl = sIconUrl;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 文字装饰（如装饰 10900 主播的“【主播】”）：tag 0 文字、tag 1 颜色 0xRRGGBB
class HuyaTextDecoration extends TarsStruct {
  String sText = ""; // tag 0
  int iColor = -1; // tag 1

  @override
  void readFrom(TarsInputStream _is) {
    sText = _is.read(sText, 0, false);
    iColor = _is.read(iColor, 1, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(sText, 0);
    _os.write(iColor, 1);
  }

  @override
  Object deepCopy() => HuyaTextDecoration()
    ..sText = sText
    ..iColor = iColor;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}
