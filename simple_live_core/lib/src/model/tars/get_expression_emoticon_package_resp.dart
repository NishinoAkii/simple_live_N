import 'package:tars_dart/tars/codec/tars_displayer.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';

/// 表情包里的一个表情（ExpressionEmoticon）
class HuyaExpressionEmoticon extends TarsStruct {
  String sId = ""; //tag 0
  /// 名称，如“[大笑]”
  String sName = ""; //tag 1
  /// 转义，如“/{dx”
  String sEscape = ""; //tag 2
  /// 小表情的图片（png）
  String sUrl = ""; //tag 3
  /// 小表情的动图（APNG）
  String sExtraUrl = ""; //tag 4
  /// 类型：0 小表情、1 Frame、2 Flexi（横长的梗表情）、3 大表情
  int iType = 0; //tag 5
  int iFrameSize = 0; //tag 6
  /// Flexi / 大表情的图片，网页端用它的“_3.png”版本
  String sFlexiUrl = ""; //tag 7
  int iPrice = 0; //tag 8
  /// Flexi / 大表情的 webp，网页端用它的“_3.webp”版本
  String sExtraFlexiUrl = ""; //tag 9
  int lPackageId = 0; //tag 10

  @override
  void readFrom(TarsInputStream input) {
    sId = input.read(sId, 0, false);
    sName = input.read(sName, 1, false);
    sEscape = input.read(sEscape, 2, false);
    sUrl = input.read(sUrl, 3, false);
    sExtraUrl = input.read(sExtraUrl, 4, false);
    iType = input.read(iType, 5, false);
    iFrameSize = input.read(iFrameSize, 6, false);
    sFlexiUrl = input.read(sFlexiUrl, 7, false);
    iPrice = input.read(iPrice, 8, false);
    sExtraFlexiUrl = input.read(sExtraFlexiUrl, 9, false);
    lPackageId = input.read(lPackageId, 10, false);
  }

  @override
  void writeTo(TarsOutputStream output) {
    output.write(sId, 0);
    output.write(sName, 1);
    output.write(sEscape, 2);
    output.write(sUrl, 3);
    output.write(sExtraUrl, 4);
    output.write(iType, 5);
    output.write(iFrameSize, 6);
    output.write(sFlexiUrl, 7);
    output.write(iPrice, 8);
    output.write(sExtraFlexiUrl, 9);
    output.write(lPackageId, 10);
  }

  @override
  Object deepCopy() {
    return HuyaExpressionEmoticon()
      ..sId = sId
      ..sName = sName
      ..sEscape = sEscape
      ..sUrl = sUrl
      ..sExtraUrl = sExtraUrl
      ..iType = iType
      ..iFrameSize = iFrameSize
      ..sFlexiUrl = sFlexiUrl
      ..iPrice = iPrice
      ..sExtraFlexiUrl = sExtraFlexiUrl
      ..lPackageId = lPackageId;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {
    var ds = TarsDisplayer(sb, level: level);
    ds.DisplayString(sId, "sId");
    ds.DisplayString(sName, "sName");
    ds.DisplayString(sEscape, "sEscape");
    ds.DisplayString(sUrl, "sUrl");
    ds.DisplayString(sExtraUrl, "sExtraUrl");
    ds.DisplayInt(iType, "iType");
    ds.DisplayInt(iFrameSize, "iFrameSize");
    ds.DisplayString(sFlexiUrl, "sFlexiUrl");
    ds.DisplayInt(iPrice, "iPrice");
    ds.DisplayString(sExtraFlexiUrl, "sExtraFlexiUrl");
    ds.DisplayInt(lPackageId, "lPackageId");
  }
}

/// 一个表情包（ExpressionEmoticonPackage）
class HuyaExpressionEmoticonPackage extends TarsStruct {
  String sPackageId = ""; //tag 0
  String sName = ""; //tag 1
  /// 类型：0 小表情、1 Frame、2 Flexi、3 大表情
  int iType = 0; //tag 2
  String sCoverUrl = ""; //tag 3
  /// 包里的全部表情（当前用户用不了的也在里面，别人发的消息里照样会有）
  List<HuyaExpressionEmoticon> vEmoticon = []; //tag 4
  // tag 5 vUnavailEmoticon 是“用不了”的说明（vUnAvailableId、sToast、跳转），
  // 不是表情，用不到
  int iIsLocked = 0; //tag 6
  String sLockedMsg = ""; //tag 7
  List<String> vUnDisplayableId = []; //tag 8

  @override
  void readFrom(TarsInputStream input) {
    sPackageId = input.read(sPackageId, 0, false);
    sName = input.read(sName, 1, false);
    iType = input.read(iType, 2, false);
    sCoverUrl = input.read(sCoverUrl, 3, false);
    vEmoticon = input.readList<HuyaExpressionEmoticon>(
      [HuyaExpressionEmoticon()],
      4,
      false,
    );
    iIsLocked = input.read(iIsLocked, 6, false);
    sLockedMsg = input.read(sLockedMsg, 7, false);
    vUnDisplayableId = input.readList<String>([""], 8, false);
  }

  @override
  void writeTo(TarsOutputStream output) {
    output.write(sPackageId, 0);
    output.write(sName, 1);
    output.write(iType, 2);
    output.write(sCoverUrl, 3);
    output.write(vEmoticon, 4);
    output.write(iIsLocked, 6);
    output.write(sLockedMsg, 7);
    output.write(vUnDisplayableId, 8);
  }

  @override
  Object deepCopy() {
    return HuyaExpressionEmoticonPackage()
      ..sPackageId = sPackageId
      ..sName = sName
      ..iType = iType
      ..sCoverUrl = sCoverUrl
      ..vEmoticon = [
        for (var e in vEmoticon) e.deepCopy() as HuyaExpressionEmoticon,
      ]
      ..iIsLocked = iIsLocked
      ..sLockedMsg = sLockedMsg
      ..vUnDisplayableId = [...vUnDisplayableId];
  }

  @override
  void displayAsString(StringBuffer sb, int level) {
    var ds = TarsDisplayer(sb, level: level);
    ds.DisplayString(sPackageId, "sPackageId");
    ds.DisplayString(sName, "sName");
    ds.DisplayInt(iType, "iType");
    ds.DisplayString(sCoverUrl, "sCoverUrl");
    ds.DisplayInt(vEmoticon.length, "vEmoticon");
    ds.DisplayInt(iIsLocked, "iIsLocked");
  }
}

/// wupui.getExpressionEmoticonPackage 的返回
class GetExpressionEmoticonPackageResp extends TarsStruct {
  String sMessage = ""; //tag 0
  List<HuyaExpressionEmoticonPackage> vPackage = []; //tag 1
  List<String> vAvailable = []; //tag 2
  // tag 3 vTabInfo（分页标签）用不到，不解析

  @override
  void readFrom(TarsInputStream input) {
    sMessage = input.read(sMessage, 0, false);
    vPackage = input.readList<HuyaExpressionEmoticonPackage>(
      [HuyaExpressionEmoticonPackage()],
      1,
      false,
    );
    vAvailable = input.readList<String>([""], 2, false);
  }

  @override
  void writeTo(TarsOutputStream output) {
    output.write(sMessage, 0);
    output.write(vPackage, 1);
    output.write(vAvailable, 2);
  }

  @override
  Object deepCopy() {
    return GetExpressionEmoticonPackageResp()
      ..sMessage = sMessage
      ..vPackage = [
        for (var p in vPackage) p.deepCopy() as HuyaExpressionEmoticonPackage,
      ]
      ..vAvailable = [...vAvailable];
  }

  @override
  void displayAsString(StringBuffer sb, int level) {
    var ds = TarsDisplayer(sb, level: level);
    ds.DisplayString(sMessage, "sMessage");
    ds.DisplayInt(vPackage.length, "vPackage");
  }
}
