// ignore_for_file: no_leading_underscores_for_local_identifiers

import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';

// 连麦、PK、语音房、多人视频的推送。字段号按虎牙网页端 taf-signal 0.1.4 的
// 协议定义，只读用到的字段（其余的读的时候跳过）。writeTo 只在测试里拼消息用

/// 主播连麦里的一个主播（LMPresenterInfo）
class HuyaLMPresenterInfo extends TarsStruct {
  int lUid = 0; //tag 0
  int lChannelId = 0; //tag 1
  int lSubChannelId = 0; //tag 2
  String sNick = ""; //tag 3
  String sAvatarUrl = ""; //tag 4
  int lYYId = 0; //tag 7
  bool bLive = false; //tag 11
  /// 直播间号
  int iRoomId = 0; //tag 15

  @override
  void readFrom(TarsInputStream _is) {
    lUid = _is.read(lUid, 0, false);
    lChannelId = _is.read(lChannelId, 1, false);
    lSubChannelId = _is.read(lSubChannelId, 2, false);
    sNick = _is.read(sNick, 3, false);
    sAvatarUrl = _is.read(sAvatarUrl, 4, false);
    lYYId = _is.read(lYYId, 7, false);
    bLive = _is.read(bLive, 11, false);
    iRoomId = _is.read(iRoomId, 15, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lUid, 0);
    _os.write(lChannelId, 1);
    _os.write(lSubChannelId, 2);
    _os.write(sNick, 3);
    _os.write(sAvatarUrl, 4);
    _os.write(lYYId, 7);
    _os.write(bLive, 11);
    _os.write(iRoomId, 15);
  }

  @override
  Object deepCopy() => HuyaLMPresenterInfo()
    ..lUid = lUid
    ..lChannelId = lChannelId
    ..lSubChannelId = lSubChannelId
    ..sNick = sNick
    ..sAvatarUrl = sAvatarUrl
    ..lYYId = lYYId
    ..bLive = bLive
    ..iRoomId = iRoomId;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 主播连麦的状态（uri 42008，LinkMicStatusChangeNotice）。
/// 实测连麦中 iLinkMicStatus 为 2，大约每 20 秒重发一次；
/// 名单里有本直播间的主播
class HuyaLinkMicStatusNotice extends TarsStruct {
  int lLMSessionId = 0; //tag 0
  int iLinkMicStatus = 0; //tag 1
  int lOwnerUid = 0; //tag 2
  List<HuyaLMPresenterInfo> vLMPresenterInfos = []; //tag 3
  int lPid = 0; //tag 4

  @override
  void readFrom(TarsInputStream _is) {
    lLMSessionId = _is.read(lLMSessionId, 0, false);
    iLinkMicStatus = _is.read(iLinkMicStatus, 1, false);
    lOwnerUid = _is.read(lOwnerUid, 2, false);
    vLMPresenterInfos = _is.readList<HuyaLMPresenterInfo>(
      [HuyaLMPresenterInfo()],
      3,
      false,
    );
    lPid = _is.read(lPid, 4, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lLMSessionId, 0);
    _os.write(iLinkMicStatus, 1);
    _os.write(lOwnerUid, 2);
    _os.write(vLMPresenterInfos, 3);
    _os.write(lPid, 4);
  }

  @override
  Object deepCopy() => HuyaLinkMicStatusNotice()
    ..lLMSessionId = lLMSessionId
    ..iLinkMicStatus = iLinkMicStatus
    ..lOwnerUid = lOwnerUid
    ..vLMPresenterInfos = [
      for (var e in vLMPresenterInfos) e.deepCopy() as HuyaLMPresenterInfo,
    ]
    ..lPid = lPid;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// PK 里一个主播所在的直播间（PresenterChannelInfo）
class HuyaPresenterChannelInfo extends TarsStruct {
  int lYYId = 0; //tag 0
  int lTid = 0; //tag 1
  int lSid = 0; //tag 3
  int lUid = 0; //tag 6
  int iRoomId = 0; //tag 8

  @override
  void readFrom(TarsInputStream _is) {
    lYYId = _is.read(lYYId, 0, false);
    lTid = _is.read(lTid, 1, false);
    lSid = _is.read(lSid, 3, false);
    lUid = _is.read(lUid, 6, false);
    iRoomId = _is.read(iRoomId, 8, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lYYId, 0);
    _os.write(lTid, 1);
    _os.write(lSid, 3);
    _os.write(lUid, 6);
    _os.write(iRoomId, 8);
  }

  @override
  Object deepCopy() => HuyaPresenterChannelInfo()
    ..lYYId = lYYId
    ..lTid = lTid
    ..lSid = lSid
    ..lUid = lUid
    ..iRoomId = iRoomId;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// PK 的一个主播（PKUserInfo）
class HuyaPKUserInfo extends TarsStruct {
  int lPid = 0; //tag 0
  String sNickName = ""; //tag 1
  String sAvatarUrl = ""; //tag 2
  int lScore = 0; //tag 3
  HuyaPresenterChannelInfo tLiveInfo = HuyaPresenterChannelInfo(); //tag 4

  @override
  void readFrom(TarsInputStream _is) {
    lPid = _is.read(lPid, 0, false);
    sNickName = _is.read(sNickName, 1, false);
    sAvatarUrl = _is.read(sAvatarUrl, 2, false);
    lScore = _is.read(lScore, 3, false);
    tLiveInfo =
        _is.readTarsStruct(tLiveInfo, 4, false) as HuyaPresenterChannelInfo;
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lPid, 0);
    _os.write(sNickName, 1);
    _os.write(sAvatarUrl, 2);
    _os.write(lScore, 3);
    _os.write(tLiveInfo, 4);
  }

  @override
  Object deepCopy() => HuyaPKUserInfo()
    ..lPid = lPid
    ..sNickName = sNickName
    ..sAvatarUrl = sAvatarUrl
    ..lScore = lScore
    ..tLiveInfo = tLiveInfo.deepCopy() as HuyaPresenterChannelInfo;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// PK 的一方（PKTeamInfo）
class HuyaPKTeamInfo extends TarsStruct {
  List<HuyaPKUserInfo> vMemberInfo = []; //tag 0
  String sTeamName = ""; //tag 1
  int lTeamScore = 0; //tag 2

  @override
  void readFrom(TarsInputStream _is) {
    vMemberInfo = _is.readList<HuyaPKUserInfo>([HuyaPKUserInfo()], 0, false);
    sTeamName = _is.read(sTeamName, 1, false);
    lTeamScore = _is.read(lTeamScore, 2, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(vMemberInfo, 0);
    _os.write(sTeamName, 1);
    _os.write(lTeamScore, 2);
  }

  @override
  Object deepCopy() => HuyaPKTeamInfo()
    ..vMemberInfo = [for (var e in vMemberInfo) e.deepCopy() as HuyaPKUserInfo]
    ..sTeamName = sTeamName
    ..lTeamScore = lTeamScore;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// PK 面板（uri 1090009，MultiPKPanelInfo）
class HuyaMultiPKPanelInfo extends TarsStruct {
  HuyaPKTeamInfo tLeftTeam = HuyaPKTeamInfo(); //tag 0
  HuyaPKTeamInfo tRightTeam = HuyaPKTeamInfo(); //tag 1
  int iPKStatus = 0; //tag 2
  int iPKResult = 0; //tag 3
  /// 这一阶段还剩的秒数
  int iRemainSeconds = 0; //tag 4

  @override
  void readFrom(TarsInputStream _is) {
    tLeftTeam = _is.readTarsStruct(tLeftTeam, 0, false) as HuyaPKTeamInfo;
    tRightTeam = _is.readTarsStruct(tRightTeam, 1, false) as HuyaPKTeamInfo;
    iPKStatus = _is.read(iPKStatus, 2, false);
    iPKResult = _is.read(iPKResult, 3, false);
    iRemainSeconds = _is.read(iRemainSeconds, 4, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(tLeftTeam, 0);
    _os.write(tRightTeam, 1);
    _os.write(iPKStatus, 2);
    _os.write(iPKResult, 3);
    _os.write(iRemainSeconds, 4);
  }

  @override
  Object deepCopy() => HuyaMultiPKPanelInfo()
    ..tLeftTeam = tLeftTeam.deepCopy() as HuyaPKTeamInfo
    ..tRightTeam = tRightTeam.deepCopy() as HuyaPKTeamInfo
    ..iPKStatus = iPKStatus
    ..iPKResult = iPKResult
    ..iRemainSeconds = iRemainSeconds;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 语音房排队上麦的人（ApplyUser）
class HuyaMeetingApplyUser extends TarsStruct {
  int lUid = 0; //tag 0
  String sNick = ""; //tag 1
  String sAvatarUrl = ""; //tag 2

  @override
  void readFrom(TarsInputStream _is) {
    lUid = _is.read(lUid, 0, false);
    sNick = _is.read(sNick, 1, false);
    sAvatarUrl = _is.read(sAvatarUrl, 2, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lUid, 0);
    _os.write(sNick, 1);
    _os.write(sAvatarUrl, 2);
  }

  @override
  Object deepCopy() => HuyaMeetingApplyUser()
    ..lUid = lUid
    ..sNick = sNick
    ..sAvatarUrl = sAvatarUrl;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 语音房的状态（MeetingStat）
class HuyaMeetingStat extends TarsStruct {
  int lPresenterUid = 0; //tag 0
  String sPresenterNick = ""; //tag 1
  int lSessionId = 0; //tag 8
  List<HuyaMeetingApplyUser> vApplyList = []; //tag 9
  int iState = 0; //tag 10

  @override
  void readFrom(TarsInputStream _is) {
    lPresenterUid = _is.read(lPresenterUid, 0, false);
    sPresenterNick = _is.read(sPresenterNick, 1, false);
    lSessionId = _is.read(lSessionId, 8, false);
    vApplyList = _is.readList<HuyaMeetingApplyUser>(
      [HuyaMeetingApplyUser()],
      9,
      false,
    );
    iState = _is.read(iState, 10, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lPresenterUid, 0);
    _os.write(sPresenterNick, 1);
    _os.write(lSessionId, 8);
    _os.write(vApplyList, 9);
    _os.write(iState, 10);
  }

  @override
  Object deepCopy() => HuyaMeetingStat()
    ..lPresenterUid = lPresenterUid
    ..sPresenterNick = sPresenterNick
    ..lSessionId = lSessionId
    ..vApplyList = [
      for (var e in vApplyList) e.deepCopy() as HuyaMeetingApplyUser,
    ]
    ..iState = iState;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 语音房的一个麦位（MeetingSeat），没人时 lUid 为 0
class HuyaMeetingSeat extends TarsStruct {
  int iPos = 0; //tag 1
  int iLocked = 0; //tag 2
  int lUid = 0; //tag 3
  String sNick = ""; //tag 4
  String sAvatarUrl = ""; //tag 5
  int iMute = 0; //tag 7

  @override
  void readFrom(TarsInputStream _is) {
    iPos = _is.read(iPos, 1, false);
    iLocked = _is.read(iLocked, 2, false);
    lUid = _is.read(lUid, 3, false);
    sNick = _is.read(sNick, 4, false);
    sAvatarUrl = _is.read(sAvatarUrl, 5, false);
    iMute = _is.read(iMute, 7, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iPos, 1);
    _os.write(iLocked, 2);
    _os.write(lUid, 3);
    _os.write(sNick, 4);
    _os.write(sAvatarUrl, 5);
    _os.write(iMute, 7);
  }

  @override
  Object deepCopy() => HuyaMeetingSeat()
    ..iPos = iPos
    ..iLocked = iLocked
    ..lUid = lUid
    ..sNick = sNick
    ..sAvatarUrl = sAvatarUrl
    ..iMute = iMute;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 语音房（uri 1025601，LiveMeetingSyncNotice）：麦位和排队上麦的人
class HuyaLiveMeetingSyncNotice extends TarsStruct {
  HuyaMeetingStat tStat = HuyaMeetingStat(); //tag 0
  List<HuyaMeetingSeat> vSeats = []; //tag 1

  @override
  void readFrom(TarsInputStream _is) {
    tStat = _is.readTarsStruct(tStat, 0, false) as HuyaMeetingStat;
    vSeats = _is.readList<HuyaMeetingSeat>([HuyaMeetingSeat()], 1, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(tStat, 0);
    _os.write(vSeats, 1);
  }

  @override
  Object deepCopy() => HuyaLiveMeetingSyncNotice()
    ..tStat = tStat.deepCopy() as HuyaMeetingStat
    ..vSeats = [for (var e in vSeats) e.deepCopy() as HuyaMeetingSeat];

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 多人视频的房间（MultiVideoRoomInfo）
class HuyaMultiVideoRoomInfo extends TarsStruct {
  int lUid = 0; //tag 1
  String sNick = ""; //tag 2
  int lSessionId = 0; //tag 7
  int iState = 0; //tag 8

  @override
  void readFrom(TarsInputStream _is) {
    lUid = _is.read(lUid, 1, false);
    sNick = _is.read(sNick, 2, false);
    lSessionId = _is.read(lSessionId, 7, false);
    iState = _is.read(iState, 8, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lUid, 1);
    _os.write(sNick, 2);
    _os.write(lSessionId, 7);
    _os.write(iState, 8);
  }

  @override
  Object deepCopy() => HuyaMultiVideoRoomInfo()
    ..lUid = lUid
    ..sNick = sNick
    ..lSessionId = lSessionId
    ..iState = iState;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 多人视频的一个座位（MultiVideoSeatInfo），没人时 lUid 为 0
class HuyaMultiVideoSeatInfo extends TarsStruct {
  int lUid = 0; //tag 1
  String sNick = ""; //tag 2
  String sAvatarUrl = ""; //tag 3
  int iPos = 0; //tag 5

  @override
  void readFrom(TarsInputStream _is) {
    lUid = _is.read(lUid, 1, false);
    sNick = _is.read(sNick, 2, false);
    sAvatarUrl = _is.read(sAvatarUrl, 3, false);
    iPos = _is.read(iPos, 5, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lUid, 1);
    _os.write(sNick, 2);
    _os.write(sAvatarUrl, 3);
    _os.write(iPos, 5);
  }

  @override
  Object deepCopy() => HuyaMultiVideoSeatInfo()
    ..lUid = lUid
    ..sNick = sNick
    ..sAvatarUrl = sAvatarUrl
    ..iPos = iPos;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 多人视频排队的人（MultiVideoApplyInfo）
class HuyaMultiVideoApplyInfo extends TarsStruct {
  int lUid = 0; //tag 1
  String sNick = ""; //tag 2
  String sAvatarUrl = ""; //tag 3

  @override
  void readFrom(TarsInputStream _is) {
    lUid = _is.read(lUid, 1, false);
    sNick = _is.read(sNick, 2, false);
    sAvatarUrl = _is.read(sAvatarUrl, 3, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lUid, 1);
    _os.write(sNick, 2);
    _os.write(sAvatarUrl, 3);
  }

  @override
  Object deepCopy() => HuyaMultiVideoApplyInfo()
    ..lUid = lUid
    ..sNick = sNick
    ..sAvatarUrl = sAvatarUrl;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 多人视频（uri 2400001，MultiVideoSyncNotice）：座位和排队的人
class HuyaMultiVideoSyncNotice extends TarsStruct {
  HuyaMultiVideoRoomInfo tRoom = HuyaMultiVideoRoomInfo(); //tag 0
  List<HuyaMultiVideoSeatInfo> vSeat = []; //tag 1
  List<HuyaMultiVideoApplyInfo> vApply = []; //tag 2

  @override
  void readFrom(TarsInputStream _is) {
    tRoom = _is.readTarsStruct(tRoom, 0, false) as HuyaMultiVideoRoomInfo;
    vSeat = _is.readList<HuyaMultiVideoSeatInfo>(
      [HuyaMultiVideoSeatInfo()],
      1,
      false,
    );
    vApply = _is.readList<HuyaMultiVideoApplyInfo>(
      [HuyaMultiVideoApplyInfo()],
      2,
      false,
    );
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(tRoom, 0);
    _os.write(vSeat, 1);
    _os.write(vApply, 2);
  }

  @override
  Object deepCopy() => HuyaMultiVideoSyncNotice()
    ..tRoom = tRoom.deepCopy() as HuyaMultiVideoRoomInfo
    ..vSeat = [for (var e in vSeat) e.deepCopy() as HuyaMultiVideoSeatInfo]
    ..vApply = [for (var e in vApply) e.deepCopy() as HuyaMultiVideoApplyInfo];

  @override
  void displayAsString(StringBuffer sb, int level) {}
}
