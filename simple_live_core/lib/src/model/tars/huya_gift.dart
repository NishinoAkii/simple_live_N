// ignore_for_file: no_leading_underscores_for_local_identifiers

import 'dart:typed_data';

import 'package:tars_dart/tars/codec/tars_displayer.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';

import 'huya_user_id.dart';

/// 送礼广播（uri 6501，SendItemSubBroadcastPacket），只读用到的字段
class HuyaSendItemPacket extends TarsStruct {
  /// 礼物 id（道具列表的 iPropsId）
  int iItemType = 0; //tag 0
  String strPayId = ""; //tag 1
  /// 这一次送出的数量
  int iItemCount = 0; //tag 2
  int lPresenterUid = 0; //tag 3
  int lSenderUid = 0; //tag 4
  String sPresenterNick = ""; //tag 5
  String sSenderNick = ""; //tag 6
  String sSendContent = ""; //tag 7
  /// 连送：这一组的数量
  int iItemCountByGroup = 0; //tag 8
  /// 连送：第几组（从 1 开始）
  int iItemGroup = 0; //tag 9
  int iSuperPupleLevel = 0; //tag 10
  int iComboScore = 0; //tag 11
  int iDisplayInfo = 0; //tag 12
  int iEffectType = 0; //tag 13
  /// 送礼人头像
  String sSenderIcon = ""; //tag 14
  String sPresenterIcon = ""; //tag 15
  int iTemplateType = 0; //tag 16
  String sExpand = ""; //tag 17
  bool bBusi = false; //tag 18
  int iColorEffectType = 0; //tag 19
  /// 礼物名称（新版才有）
  String sPropsName = ""; //tag 20
  /// 直播间号
  int lRoomId = 0; //tag 24
  /// 连击 id（毫秒时间戳），同一次连击的几条相同；旧版没有时为 0
  int lComboSeqId = 0; //tag 39
  /// 实付金额（分）：实测金话筒 1 个是 100，虎粮、超粉虎粮是 0
  int lPayTotal = 0; //tag 41

  @override
  void readFrom(TarsInputStream _is) {
    iItemType = _is.read(iItemType, 0, false);
    strPayId = _is.read(strPayId, 1, false);
    iItemCount = _is.read(iItemCount, 2, false);
    lPresenterUid = _is.read(lPresenterUid, 3, false);
    lSenderUid = _is.read(lSenderUid, 4, false);
    sPresenterNick = _is.read(sPresenterNick, 5, false);
    sSenderNick = _is.read(sSenderNick, 6, false);
    sSendContent = _is.read(sSendContent, 7, false);
    iItemCountByGroup = _is.read(iItemCountByGroup, 8, false);
    iItemGroup = _is.read(iItemGroup, 9, false);
    iSuperPupleLevel = _is.read(iSuperPupleLevel, 10, false);
    iComboScore = _is.read(iComboScore, 11, false);
    iDisplayInfo = _is.read(iDisplayInfo, 12, false);
    iEffectType = _is.read(iEffectType, 13, false);
    sSenderIcon = _is.read(sSenderIcon, 14, false);
    sPresenterIcon = _is.read(sPresenterIcon, 15, false);
    iTemplateType = _is.read(iTemplateType, 16, false);
    sExpand = _is.read(sExpand, 17, false);
    bBusi = _is.read(bBusi, 18, false);
    iColorEffectType = _is.read(iColorEffectType, 19, false);
    sPropsName = _is.read(sPropsName, 20, false);
    lRoomId = _is.read(lRoomId, 24, false);
    lComboSeqId = _is.read(lComboSeqId, 39, false);
    lPayTotal = _is.read(lPayTotal, 41, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iItemType, 0);
    _os.write(strPayId, 1);
    _os.write(iItemCount, 2);
    _os.write(lPresenterUid, 3);
    _os.write(lSenderUid, 4);
    _os.write(sPresenterNick, 5);
    _os.write(sSenderNick, 6);
    _os.write(sSendContent, 7);
    _os.write(iItemCountByGroup, 8);
    _os.write(iItemGroup, 9);
    _os.write(iSuperPupleLevel, 10);
    _os.write(iComboScore, 11);
    _os.write(iDisplayInfo, 12);
    _os.write(iEffectType, 13);
    _os.write(sSenderIcon, 14);
    _os.write(sPresenterIcon, 15);
    _os.write(iTemplateType, 16);
    _os.write(sExpand, 17);
    _os.write(bBusi, 18);
    _os.write(iColorEffectType, 19);
    _os.write(sPropsName, 20);
    _os.write(lRoomId, 24);
    _os.write(lComboSeqId, 39);
    _os.write(lPayTotal, 41);
  }

  @override
  Object deepCopy() {
    return HuyaSendItemPacket()
      ..iItemType = iItemType
      ..strPayId = strPayId
      ..iItemCount = iItemCount
      ..lPresenterUid = lPresenterUid
      ..lSenderUid = lSenderUid
      ..sPresenterNick = sPresenterNick
      ..sSenderNick = sSenderNick
      ..sSendContent = sSendContent
      ..iItemCountByGroup = iItemCountByGroup
      ..iItemGroup = iItemGroup
      ..iSuperPupleLevel = iSuperPupleLevel
      ..iComboScore = iComboScore
      ..iDisplayInfo = iDisplayInfo
      ..iEffectType = iEffectType
      ..sSenderIcon = sSenderIcon
      ..sPresenterIcon = sPresenterIcon
      ..iTemplateType = iTemplateType
      ..sExpand = sExpand
      ..bBusi = bBusi
      ..iColorEffectType = iColorEffectType
      ..sPropsName = sPropsName
      ..lRoomId = lRoomId
      ..lComboSeqId = lComboSeqId
      ..lPayTotal = lPayTotal;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 道具的图片（PropsIdentity），只读用到的字段
class HuyaPropsIdentity extends TarsStruct {
  int iPropsIdType = 0; //tag 1
  String sPropsPic18 = ""; //tag 2
  String sPropsPic24 = ""; //tag 3
  String sPropsPicGif = ""; //tag 4
  /// 网页端礼物栏的图片，格式如“&id:…&url&…”或直接是地址
  String sPropsWeb = ""; //tag 17
  String sPropsPic108 = ""; //tag 23

  @override
  void readFrom(TarsInputStream _is) {
    iPropsIdType = _is.read(iPropsIdType, 1, false);
    sPropsPic18 = _is.read(sPropsPic18, 2, false);
    sPropsPic24 = _is.read(sPropsPic24, 3, false);
    sPropsPicGif = _is.read(sPropsPicGif, 4, false);
    sPropsWeb = _is.read(sPropsWeb, 17, false);
    sPropsPic108 = _is.read(sPropsPic108, 23, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iPropsIdType, 1);
    _os.write(sPropsPic18, 2);
    _os.write(sPropsPic24, 3);
    _os.write(sPropsPicGif, 4);
    _os.write(sPropsWeb, 17);
    _os.write(sPropsPic108, 23);
  }

  @override
  Object deepCopy() {
    return HuyaPropsIdentity()
      ..iPropsIdType = iPropsIdType
      ..sPropsPic18 = sPropsPic18
      ..sPropsPic24 = sPropsPic24
      ..sPropsPicGif = sPropsPicGif
      ..sPropsWeb = sPropsWeb
      ..sPropsPic108 = sPropsPic108;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 一个道具（PropsItem），只读用到的字段
class HuyaPropsItem extends TarsStruct {
  int iPropsId = 0; //tag 1
  String sPropsName = ""; //tag 2
  /// 价格，单位是 1/100 虎牙币（= 分）
  int iPropsYb = 0; //tag 3
  int iPropsGreenBean = 0; //tag 4
  /// 银豆价格：银豆礼物是免费的
  int iPropsWhiteBean = 0; //tag 5
  /// 金豆价格
  int iPropsGoldenBean = 0; //tag 6
  List<HuyaPropsIdentity> vPropsIdentity = []; //tag 16

  @override
  void readFrom(TarsInputStream _is) {
    iPropsId = _is.read(iPropsId, 1, false);
    sPropsName = _is.read(sPropsName, 2, false);
    iPropsYb = _is.read(iPropsYb, 3, false);
    iPropsGreenBean = _is.read(iPropsGreenBean, 4, false);
    iPropsWhiteBean = _is.read(iPropsWhiteBean, 5, false);
    iPropsGoldenBean = _is.read(iPropsGoldenBean, 6, false);
    vPropsIdentity = _is.readList<HuyaPropsIdentity>(
      [HuyaPropsIdentity()],
      16,
      false,
    );
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iPropsId, 1);
    _os.write(sPropsName, 2);
    _os.write(iPropsYb, 3);
    _os.write(iPropsGreenBean, 4);
    _os.write(iPropsWhiteBean, 5);
    _os.write(iPropsGoldenBean, 6);
    _os.write(vPropsIdentity, 16);
  }

  @override
  Object deepCopy() {
    return HuyaPropsItem()
      ..iPropsId = iPropsId
      ..sPropsName = sPropsName
      ..iPropsYb = iPropsYb
      ..iPropsGreenBean = iPropsGreenBean
      ..iPropsWhiteBean = iPropsWhiteBean
      ..iPropsGoldenBean = iPropsGoldenBean
      ..vPropsIdentity = vPropsIdentity
          .map((e) => e.deepCopy() as HuyaPropsIdentity)
          .toList();
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// PropsUIServer.getPropsList 的请求
class HuyaGetPropsListReq extends TarsStruct {
  HuyaUserId tUserId = HuyaUserId(); //tag 1
  String sMd5 = ""; //tag 2
  /// 64 = PC 端
  int iTemplateType = 64; //tag 3
  String sVersion = ""; //tag 4
  int iAppId = 0; //tag 5
  int lPresenterUid = 0; //tag 6
  int lSid = 0; //tag 7
  int lSubSid = 0; //tag 8

  @override
  void readFrom(TarsInputStream _is) {
    tUserId = _is.read(tUserId, 1, false);
    sMd5 = _is.read(sMd5, 2, false);
    iTemplateType = _is.read(iTemplateType, 3, false);
    sVersion = _is.read(sVersion, 4, false);
    iAppId = _is.read(iAppId, 5, false);
    lPresenterUid = _is.read(lPresenterUid, 6, false);
    lSid = _is.read(lSid, 7, false);
    lSubSid = _is.read(lSubSid, 8, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(tUserId, 1);
    _os.write(sMd5, 2);
    _os.write(iTemplateType, 3);
    _os.write(sVersion, 4);
    _os.write(iAppId, 5);
    _os.write(lPresenterUid, 6);
    _os.write(lSid, 7);
    _os.write(lSubSid, 8);
  }

  @override
  Object deepCopy() {
    return HuyaGetPropsListReq()
      ..tUserId = tUserId.deepCopy() as HuyaUserId
      ..sMd5 = sMd5
      ..iTemplateType = iTemplateType
      ..sVersion = sVersion
      ..iAppId = iAppId
      ..lPresenterUid = lPresenterUid
      ..lSid = lSid
      ..lSubSid = lSubSid;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {
    var ds = TarsDisplayer(sb, level: level);
    ds.DisplayTarsStruct(tUserId, "tUserId");
    ds.DisplayInt(lPresenterUid, "lPresenterUid");
  }
}

/// PropsUIServer.getPropsList 的返回
class HuyaGetPropsListRsp extends TarsStruct {
  List<HuyaPropsItem> vPropsItemList = []; //tag 1
  String sMd5 = ""; //tag 2

  @override
  void readFrom(TarsInputStream _is) {
    vPropsItemList = _is.readList<HuyaPropsItem>([HuyaPropsItem()], 1, false);
    sMd5 = _is.read(sMd5, 2, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(vPropsItemList, 1);
    _os.write(sMd5, 2);
  }

  @override
  Object deepCopy() {
    return HuyaGetPropsListRsp()
      ..vPropsItemList = vPropsItemList
          .map((e) => e.deepCopy() as HuyaPropsItem)
          .toList()
      ..sMd5 = sMd5;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 订阅直播间的消息组（WSRegisterGroupReq，命令 16）：
/// “live:主播uid”是礼物等直播间广播，“chat:主播uid”是聊天
class HuyaRegisterGroupReq extends TarsStruct {
  List<String> vGroupId = []; //tag 0
  String sToken = ""; //tag 1

  @override
  void readFrom(TarsInputStream _is) {
    vGroupId = _is.readList<String>([""], 0, false);
    sToken = _is.read(sToken, 1, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(vGroupId, 0);
    _os.write(sToken, 1);
  }

  @override
  Object deepCopy() {
    return HuyaRegisterGroupReq()
      ..vGroupId = List<String>.from(vGroupId)
      ..sToken = sToken;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 新版推送里的一条消息（WSMsgItem）
class HuyaWSMsgItem extends TarsStruct {
  int lUri = 0; //tag 0
  Uint8List sMsg = Uint8List(0); //tag 1
  int lMsgId = 0; //tag 2
  int iMsgTag = 0; //tag 3

  @override
  void readFrom(TarsInputStream _is) {
    lUri = _is.read(lUri, 0, false);
    sMsg = _is.readBytes(1, false);
    lMsgId = _is.read(lMsgId, 2, false);
    iMsgTag = _is.read(iMsgTag, 3, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lUri, 0);
    _os.write(sMsg, 1);
    _os.write(lMsgId, 2);
    _os.write(iMsgTag, 3);
  }

  @override
  Object deepCopy() {
    return HuyaWSMsgItem()
      ..lUri = lUri
      ..sMsg = Uint8List.fromList(sMsg)
      ..lMsgId = lMsgId
      ..iMsgTag = iMsgTag;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 新版推送（WSPushMessage_V2，命令 22）：按消息组推送，一次可能有几条
class HuyaWSPushMessageV2 extends TarsStruct {
  String sGroupId = ""; //tag 0
  List<HuyaWSMsgItem> vMsgItem = []; //tag 1

  @override
  void readFrom(TarsInputStream _is) {
    sGroupId = _is.read(sGroupId, 0, false);
    vMsgItem = _is.readList<HuyaWSMsgItem>([HuyaWSMsgItem()], 1, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(sGroupId, 0);
    _os.write(vMsgItem, 1);
  }

  @override
  Object deepCopy() {
    return HuyaWSPushMessageV2()
      ..sGroupId = sGroupId
      ..vMsgItem = vMsgItem.map((e) => e.deepCopy() as HuyaWSMsgItem).toList();
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}
