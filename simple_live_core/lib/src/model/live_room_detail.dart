import 'dart:convert';

import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_voice_room.dart';

class LiveRoomDetail {
  /// 房间ID
  final String roomId;

  /// 房间标题
  final String title;

  /// 封面
  final String cover;

  /// 用户名
  final String userName;

  /// 头像
  final String userAvatar;

  /// 在线
  final int online;

  /// 介绍
  final String? introduction;

  /// 公告
  final String? notice;

  /// 状态
  final bool status;

  /// 附加信息
  final dynamic data;

  /// 弹幕附加信息
  final dynamic danmakuData;

  /// 是否录播
  final bool isRecord;

  /// 链接
  final String url;

  /// 显示时间
  final String? showTime;

  /// 进直播间时的看过人数、点赞数；平台没有时为 null
  final LiveRoomStats? stats;

  /// 语聊房的房主和麦位（App 用它代替低清的合成画面）；不是语聊房时为 null
  final LiveVoiceRoom? voiceRoom;

  /// 直播分区（平台显示的最细一级，如“主机游戏”），是平台的原文；平台没给时为 null
  final String? area;

  LiveRoomDetail({
    required this.roomId,
    required this.title,
    required this.cover,
    required this.userName,
    required this.userAvatar,
    required this.online,
    this.introduction,
    this.notice,
    required this.status,
    this.data,
    this.danmakuData,
    required this.url,
    this.isRecord = false,
    this.showTime,
    this.stats,
    this.voiceRoom,
    this.area,
  });

  @override
  String toString() {
    return json.encode({
      "roomId": roomId,
      "title": title,
      "cover": cover,
      "userName": userName,
      "userAvatar": userAvatar,
      "online": online,
      "introduction": introduction,
      "notice": notice,
      "status": status,
      "data": data.toString(),
      "danmakuData": danmakuData.toString(),
      "url": url,
      "isRecord": isRecord,
      "showTime": showTime,
    });
  }
}
