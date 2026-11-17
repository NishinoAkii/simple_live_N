import 'package:tars_dart/tars/codec/tars_displayer.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';

import 'huya_user_id.dart';

/// wupui.getExpressionEmoticonPackage 的请求（虎牙网页端直播间的表情包）
class GetExpressionEmoticonPackageReq extends TarsStruct {
  HuyaUserId tId = HuyaUserId(); //tag 0
  /// 主播 uid（网页端的 lp / lChannelId）
  int lPid = 0; //tag 1
  /// 分类 id（gid）
  int iGid = 0; //tag 2
  /// 场景：1 = 直播间
  int iSceneType = 1; //tag 3

  @override
  void readFrom(TarsInputStream input) {
    tId = input.read(tId, 0, false);
    lPid = input.read(lPid, 1, false);
    iGid = input.read(iGid, 2, false);
    iSceneType = input.read(iSceneType, 3, false);
  }

  @override
  void writeTo(TarsOutputStream output) {
    output.write(tId, 0);
    output.write(lPid, 1);
    output.write(iGid, 2);
    output.write(iSceneType, 3);
  }

  @override
  Object deepCopy() {
    return GetExpressionEmoticonPackageReq()
      ..tId = tId.deepCopy() as HuyaUserId
      ..lPid = lPid
      ..iGid = iGid
      ..iSceneType = iSceneType;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {
    var ds = TarsDisplayer(sb, level: level);
    ds.DisplayTarsStruct(tId, "tId");
    ds.DisplayInt(lPid, "lPid");
    ds.DisplayInt(iGid, "iGid");
    ds.DisplayInt(iSceneType, "iSceneType");
  }
}
