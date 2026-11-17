import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 语聊房：盖在视频上（弹幕和控制栏在它上面），自己画房主和麦位，
/// 代替平台合成的低清画面。不是语聊房或切到原画面时不占地方
class VoiceRoomLayer extends StatelessWidget {
  final LiveRoomController controller;
  const VoiceRoomLayer({required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Obx(() {
        var room = controller.voiceRoom.value;
        if (room == null || !controller.voiceView.value) {
          return const SizedBox.shrink();
        }
        return VoiceRoomView(
          room: room,
          caption: controller.voiceCaption.value,
        );
      }),
    );
  }
}

/// 播放器底栏的按钮：语聊房画面 / 原画面切换。不是语聊房时不显示
class VoiceViewButton extends StatelessWidget {
  final LiveRoomController controller;
  const VoiceViewButton({required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (controller.voiceRoom.value == null) {
        return const SizedBox.shrink();
      }
      var drawn = controller.voiceView.value;
      return IconButton(
        tooltip: drawn ? "看原画面".t : "看语聊房画面".t,
        onPressed: () => controller.voiceView.value = !drawn,
        icon: Icon(
          drawn ? Icons.videocam_outlined : Icons.groups_outlined,
          color: Colors.white,
        ),
      );
    });
  }
}

/// 房主在上，嘉宾麦每排 4 个。说话的人头像外面亮一圈，最近一句话显示在底部
class VoiceRoomView extends StatefulWidget {
  final LiveVoiceRoom room;

  /// 最近一句话（语音转文字）和收到的时间
  final (LiveVoiceCaption, DateTime)? caption;
  const VoiceRoomView({required this.room, this.caption, super.key});

  /// 说完以后头像外圈还亮多久
  static const speakingFor = Duration(seconds: 3);

  /// 最近一句话显示多久
  static const captionFor = Duration(seconds: 8);

  @override
  State<VoiceRoomView> createState() => _VoiceRoomViewState();
}

class _VoiceRoomViewState extends State<VoiceRoomView> {
  Timer? _expire;

  @override
  void didUpdateWidget(covariant VoiceRoomView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleExpiry();
  }

  @override
  void initState() {
    super.initState();
    _scheduleExpiry();
  }

  /// 外圈和字幕到时间要消失：到点重画一次
  void _scheduleExpiry() {
    _expire?.cancel();
    var caption = widget.caption;
    if (caption == null) return;
    var left = VoiceRoomView.captionFor - DateTime.now().difference(caption.$2);
    if (left <= Duration.zero) return;
    var ring =
        VoiceRoomView.speakingFor - DateTime.now().difference(caption.$2);
    _expire = Timer(ring > Duration.zero ? ring : left, () {
      if (mounted) setState(_scheduleExpiry);
    });
  }

  @override
  void dispose() {
    _expire?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var room = widget.room;
    var now = DateTime.now();
    var caption = widget.caption;
    var speaking = caption != null &&
            now.difference(caption.$2) < VoiceRoomView.speakingFor
        ? caption.$1.uid
        : null;
    var showCaption = caption != null &&
        now.difference(caption.$2) < VoiceRoomView.captionFor;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xff17141f)),
        if (room.background.isNotEmpty)
          Opacity(
            opacity: 0.35,
            child: NetImage(room.background, fit: BoxFit.cover),
          ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x66000000), Color(0x22000000), Color(0x99000000)],
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, box) {
            // 头像跟着画面大小变：小窗口里也放得下房主、两排麦位和字幕
            var size = min(box.maxHeight / 5.4, box.maxWidth / 6.2)
                .clamp(26.0, 112.0)
                .toDouble();
            return Center(
              child: Padding(
                padding: EdgeInsets.all(size * 0.2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _VoiceRoomBody(
                    room: room,
                    size: size,
                    speaking: speaking,
                    caption: showCaption ? caption.$1 : null,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _VoiceRoomBody extends StatelessWidget {
  final LiveVoiceRoom room;
  final double size;
  final String? speaking;

  /// 正在显示的字幕。字幕的位置一直留着，出现和消失时麦位不会跳
  final LiveVoiceCaption? caption;
  const _VoiceRoomBody({
    required this.room,
    required this.size,
    required this.speaking,
    required this.caption,
  });

  @override
  Widget build(BuildContext context) {
    var host = room.host;
    var guests = [for (var i = 1; i <= room.guestSeats; i++) i];
    var rows = <List<int>>[
      for (var i = 0; i < guests.length; i += 4)
        guests.sublist(i, min(i + 4, guests.length)),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (host != null)
          _SeatTile(
            seat: host,
            position: 0,
            size: size * 1.3,
            speaking: host.uid == speaking,
            teams: room.teams.isNotEmpty,
          ),
        if (room.teams.length >= 2) ...[
          SizedBox(height: size * 0.18),
          _TeamScores(teams: room.teams, size: size),
        ],
        SizedBox(height: size * 0.3),
        for (var row in rows)
          Padding(
            padding: EdgeInsets.only(top: size * 0.12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var position in row)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: size * 0.16),
                    child: _SeatTile(
                      seat: room.seatAt(position),
                      position: position,
                      size: size,
                      speaking: room.seatAt(position)?.uid == speaking,
                      teams: room.teams.isNotEmpty,
                    ),
                  ),
              ],
            ),
          ),
        SizedBox(height: size * 0.2),
        SizedBox(
          width: size * 7.6,
          height: _CaptionPill.fontFor(size) * 2.6 + 14,
          child: Align(
            alignment: Alignment.topCenter,
            child: caption == null
                ? null
                : _CaptionPill(caption: caption!, size: size),
          ),
        ),
      ],
    );
  }
}

/// PK 时的两队颜色
Color _teamColor(String team) => switch (team) {
      "1" => const Color(0xff4f8ef7),
      "2" => const Color(0xffef5a6f),
      _ => const Color(0x66ffffff),
    };

class _SeatTile extends StatelessWidget {
  /// 空麦位为 null
  final LiveVoiceSeat? seat;
  final int position;
  final double size;
  final bool speaking;

  /// 正在 PK：头像外圈用队伍颜色
  final bool teams;
  const _SeatTile({
    required this.seat,
    required this.position,
    required this.size,
    required this.speaking,
    required this.teams,
  });

  @override
  Widget build(BuildContext context) {
    var seat = this.seat;
    var fontSize = (size * 0.2).clamp(10.0, 18.0).toDouble();
    var ring = speaking
        ? const Color(0xff6ee7a8)
        : teams && seat != null
            ? _teamColor(seat.team)
            : const Color(0x33ffffff);
    Widget avatar = Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(speaking ? 3 : 2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: speaking ? 3 : 1.5),
        boxShadow: speaking
            ? const [BoxShadow(color: Color(0x886ee7a8), blurRadius: 10)]
            : null,
      ),
      child: seat == null || seat.avatar.isEmpty
          ? Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0x1fffffff),
              ),
              alignment: Alignment.center,
              child: Text(
                "$position",
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: fontSize * 1.2,
                ),
              ),
            )
          : NetImage(
              seat.avatar,
              width: size,
              height: size,
              borderRadius: size,
            ),
    );
    if (seat != null && seat.muted) {
      avatar = Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Color(0xcc000000),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.mic_off,
                size: max(10, size * 0.2),
                color: Colors.white70,
              ),
            ),
          ),
        ],
      );
    }
    return SizedBox(
      width: size * 1.7,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          avatar,
          SizedBox(height: size * 0.08),
          Text(
            seat == null ? "空麦位".t : seat.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: seat == null ? Colors.white38 : Colors.white,
              fontSize: fontSize,
            ),
          ),
          if (seat != null && (seat.host || seat.score.isNotEmpty))
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (seat.host)
                  Container(
                    margin: const EdgeInsets.only(right: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: const Color(0x33ffffff),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      "房主".t,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: fontSize * 0.8,
                      ),
                    ),
                  ),
                if (seat.score.isNotEmpty) ...[
                  Icon(
                    Icons.favorite,
                    size: fontSize * 0.8,
                    color: const Color(0xffff7aa2),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    seat.score,
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: fontSize * 0.85,
                    ),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _TeamScores extends StatelessWidget {
  final List<LiveVoiceTeam> teams;
  final double size;
  const _TeamScores({required this.teams, required this.size});

  @override
  Widget build(BuildContext context) {
    var fontSize = (size * 0.2).clamp(11.0, 18.0).toDouble();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < teams.length; i++) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                "PK",
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: fontSize * 0.8,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: _teamColor(teams[i].id).withAlpha(70),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _teamColor(teams[i].id)),
            ),
            child: Text(
              teams[i].score,
              style: TextStyle(color: Colors.white, fontSize: fontSize),
            ),
          ),
        ],
      ],
    );
  }
}

class _CaptionPill extends StatelessWidget {
  final LiveVoiceCaption caption;
  final double size;
  const _CaptionPill({required this.caption, required this.size});

  static double fontFor(double size) =>
      (size * 0.17).clamp(11.0, 17.0).toDouble();

  @override
  Widget build(BuildContext context) {
    var fontSize = fontFor(size);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(fontSize + 2),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: "${caption.name}${"：".t}",
              style: const TextStyle(color: Color(0xff9fd3ff)),
            ),
            TextSpan(text: caption.text),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white, fontSize: fontSize, height: 1.3),
      ),
    );
  }
}
