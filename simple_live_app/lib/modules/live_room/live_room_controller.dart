import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_share.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/capture/capture_controller.dart';
import 'package:simple_live_app/app/capture/capture_widgets.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/danmaku_dedupe.dart';
import 'package:simple_live_app/app/danmaku_delay.dart';
import 'package:simple_live_app/app/name_color.dart';
import 'package:simple_live_app/app/play_prefs.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/exit_guard.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/catch_up_policy.dart';
import 'package:simple_live_app/modules/live_room/chat_log.dart';
import 'package:simple_live_app/modules/live_room/live_gifts.dart';
import 'package:simple_live_app/modules/live_room/listen_mode.dart';
import 'package:simple_live_app/modules/live_room/live_room_capture.dart';
import 'package:simple_live_app/modules/live_room/live_room_playback.dart';
import 'package:simple_live_app/modules/live_room/live_room_tabs.dart';
import 'package:simple_live_app/modules/live_room/rank/live_rank_state.dart';
import 'package:simple_live_app/modules/live_room/room_notice.dart';
import 'package:simple_live_app/modules/live_room/player/danmaku_pacer.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/live_room/player/stream_tuning.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/account_follow_service.dart';
import 'package:simple_live_app/services/danmaku_export.dart';
import 'package:simple_live_app/services/danmaku_emotes.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/live_notify_service.dart';
import 'package:simple_live_app/app/multi_window/multi_window.dart';
import 'package:simple_live_app/app/multi_window/window_set.dart';
import 'package:simple_live_app/widgets/follow_actions_sheet.dart';
import 'package:simple_live_app/services/chat_users/room_user_blocks.dart';
import 'package:simple_live_app/services/ios_pip/ios_pip_session.dart';
import 'package:simple_live_app/services/webdav_sync_service.dart';
import 'package:simple_live_app/services/obs_bridge/ass_writer.dart';
import 'package:simple_live_app/services/obs_bridge/danmaku_recorder.dart';
import 'package:simple_live_app/services/obs_bridge/obs_bridge_service.dart';
import 'package:simple_live_app/services/obs_bridge/obs_events.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/tail_list_view.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = createDanmaku(site);
    // 抖音应该默认是竖屏的
    if (site.id == "douyin") {
      isVertical.value = true;
    }
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);

  /// 聊天区顶上的直播间公告卡片（room_notice_card.dart）
  final roomNotice = RoomNoticeState();
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;

  /// 正在显示的 SC（由 [_superChatHistory] 按显示方式筛选得到）
  RxList<LiveSuperChatMessage> superChats = RxList<LiveSuperChatMessage>();

  /// 本场收到的全部 SC（按收到的顺序，最多 [kMaxSuperChats] 条）。
  /// 显示方式只决定显示哪些，切回“一直显示”时已结束的 SC 也还在
  final List<LiveSuperChatMessage> _superChatHistory = [];

  /// [_superChatHistory] 的去重键，随列表增减，不用每来一条都整个重算
  final Set<String> _superChatKeys = {};

  /// 有 SC（醒目留言 / Super Chat）的平台：直播间显示 SC 页
  bool get supportsSuperChat =>
      site.id == Constant.kBiliBili ||
      site.id == Constant.kYouTube ||
      (site.script?.hasSuperChat ?? false);

  /// 直播间显示礼物页（内置平台都会解析礼物，直播源不支持）
  bool get supportsGifts => !site.isScript;

  /// 本场收到的礼物（连击合成一行），礼物页和导出用
  final GiftBook giftBook = GiftBook();

  /// 礼物有变化时加一，礼物页据此刷新
  var giftVersion = 0.obs;

  /// 礼物页只看付费礼物
  var giftPaidOnly = false.obs;

  /// 直播间有榜单（平台的榜单加上本场礼物榜，直播源不支持）
  bool get supportsRank => !site.isScript;

  /// 显示榜单：礼物页里的“礼物 | 榜单”、点在线人数打开榜单、全屏时的榜单按钮
  /// （设置里可以关掉）
  bool get showRank =>
      supportsRank && AppSettingsController.instance.liveRankTab.value;

  /// 礼物页现在看的是榜单（默认看礼物）
  final giftShowRank = false.obs;

  final StreamController<LiveRoomTab> _tabJumps =
      StreamController<LiveRoomTab>.broadcast();

  /// 要切到的标签页（直播间页面听着）
  Stream<LiveRoomTab> get tabJumps => _tabJumps.stream;

  /// 点在线人数：切到礼物页的“榜单”（全屏时由播放器打开弹窗，见 showLiveRank）
  void openRank() {
    if (!showRank || _tabJumps.isClosed) {
      return;
    }
    giftShowRank.value = true;
    _tabJumps.add(LiveRoomTab.gifts);
  }

  /// 榜单：平台的榜单在打开时读一次，本场礼物榜按 [giftBook] 算
  late final LiveRankState rank = LiveRankState(
    platformBoards: () {
      Object liveSite = site.liveSite;
      return liveSite is LiveRankSite ? liveSite.rankBoards : const [];
    },
    fetch: (boardId) {
      Object liveSite = site.liveSite;
      var room = detail.value;
      if (liveSite is! LiveRankSite || room == null) {
        throw CoreError("还没有读取到直播间信息".t);
      }
      return liveSite.getRank(boardId, detail: room);
    },
    giftRanking: giftBook.ranking,
    ready: () => detail.value != null,
  );

  /// 屏蔽的人：本机名单里在这个直播间生效的，加上本次进入的
  late final RoomUserBlocks userBlocks = RoomUserBlocks(
    siteId: () => site.id,
    roomId: () => roomId,
    roomLabel: () => detail.value?.userName ?? "",
  );

  /// 平台的弹幕连接；直播源没写弹幕时用空实现（不连接）
  static LiveDanmaku createDanmaku(Site site) {
    if (!site.hasDanmaku) {
      return LiveDanmaku();
    }
    try {
      return site.liveSite.getDanmaku();
    } catch (e) {
      Log.logPrint(e);
      return LiveDanmaku();
    }
  }

  /// 聊天栏列表（最新的在最下面，往上翻看时不再跟随）
  final chatList = TailListController();

  /// 收到的全部聊天消息和系统提示，一条都不删（较早的存到临时文件）
  late final chatLog = ChatLog(
    store: FileChunkStore(),
    maxCount: AppSettingsController.instance.chatKeepLimit.value,
    onTrimmed: (dropped) => chatList.dropFront(dropped),
  );

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 退出倒计时
  var countdown = 60.obs;

  Timer? autoExitTimer;

  /// 设置的自动关闭时间（分钟）
  var autoExitMinutes = 60.obs;

  ///是否延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  /// 是否处于后台
  var isBackground = false;

  /// 直播暂停（见 live_room_playback.dart）
  final livePause = LivePauseState();

  /// 听直播和后台播放（见 listen_mode.dart）
  final listen = ListenModeState();

  /// 直播间加载失败
  var loadError = false.obs;
  Error? error;

  // 开播时长状态变量
  var liveDuration = "00:00:00".obs;
  Timer? _liveDurationTimer;

  Worker? _iosDanmakuWorker;

  /// 全屏、小窗切换或弹幕大小、速度改动时，换成对应的那一套
  Worker? _danmakuModeWorker;
  Worker? _chatKeepWorker;

  /// 录屏接口（OBS 等），没有注册时（测试里）为 null
  final ObsBridgeService? _obs = ObsBridgeService.maybeInstance;

  /// 房间信息、开播状态变化时通知录屏接口
  Worker? _obsRoomWorker;

  /// 已读到房间信息的直播间（平台|房间号）：换直播间后、读到新信息之前不用旧的标题
  String? _detailKey;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    _enterRoomContext();
    _noteWindowRoom();
    if (Platform.isIOS) {
      iosPip = IosPipSession(
        player: player,
        videoController: videoController,
        videoKey: globalPlayerKey,
        isLive: true,
        onModeChanged: (active) {
          if (active) {
            // 小窗里看不到弹幕和控制栏
            showControlsState.value = false;
            clearDanmaku();
          }
        },
        avSource: _iosAvPipSource,
        reopenLive: _reopenAfterIosAvPip,
        // 听直播时不开小窗
        blocked: () => listen.active.value,
      );
      // 播放器里关掉弹幕时，小窗和电视上的弹幕也清掉
      _iosDanmakuWorker = ever<bool>(showDanmakuState, (show) {
        if (!show) iosPip?.clearDanmaku();
      });
    }
    if (FollowService.instance.followList.isEmpty) {
      FollowService.instance.loadData();
    }
    initAutoExit();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    var settings = AppSettingsController.instance;
    _chatKeepWorker = ever<int>(
      settings.chatKeepLimit,
      (value) => chatLog.maxCount = value,
    );
    _danmakuModeWorker = everAll(
      [
        fullScreenState,
        systemPipState,
        settings.danmuSize,
        settings.danmuSizeFullscreen,
        settings.danmuSpeed,
        settings.danmuPipSize,
        settings.danmuPipSpeed,
        settings.emoteSizeSeparate,
        settings.emoteScale,
      ],
      (_) => applyDanmakuViewMode(),
    );
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    // 最后打开的直播间推送到录屏接口
    _obs?.attach(this, obsRoomInfo);
    _obsRoomWorker = everAll([detail, liveStatus], (_) => _onRoomInfoChanged());
    loadData();

    initPlaybackWatchdog();
    initLivePause();
    initListenMode();
    initSuperChatTimer();
    initCatchUp();

    super.onInit();
    // 要在播放器设好音量（super.onInit）以后
    _initWindowSettings();
  }

  // ---------------- 多开：这个窗口的音量、静音、弹幕、清晰度、声音输出设备 ----------------

  /// 副窗口里只有第一次进的直播间用主窗口给的设置（之后是用户自己换的）
  static bool _launchSettingsUsed = false;

  /// 多开窗口打开上次的时，用那个窗口里选的清晰度（用一次）
  String? _preferredQuality;
  Worker? _windowSettingsWorker;
  Timer? _windowSettingsTimer;

  void _initWindowSettings() {
    if (MultiWindow.isSecondary) {
      var settings = _launchSettingsUsed ? null : MultiWindow.launchSettings;
      _launchSettingsUsed = true;
      if (settings != null) {
        if (settings.volume case var volume?) {
          AppSettingsController.instance.setPlayerVolume(volume);
          player.setVolume(volume);
        }
        if (settings.danmaku case var danmaku?) {
          showDanmakuState.value = danmaku;
        }
        if (settings.muted case var muted?) {
          setMuted(muted);
        }
        _preferredQuality = settings.quality;
        if (settings.audioDevice != null) {
          unawaited(_restoreAudioDevice(settings.audioDevice));
        }
      }
      // 之后变了告诉主窗口，记成这个直播间多开时的设置
      _windowSettingsWorker = everAll([
        AppSettingsController.instance.playerVolume,
        muted,
        showDanmakuState,
        currentQualityInfo,
        audioDevice,
      ], (_) => _scheduleWindowSettings());
      return;
    }
    // 主窗口：“每个窗口单独选声音输出设备”开着时用它自己记的
    if (MultiWindow.canOpen && MultiWindowPrefs.devicePerWindow.value) {
      var saved = MultiWindow.mainAudioDevice;
      if (saved != null) {
        unawaited(_restoreAudioDevice(saved));
      }
    }
  }

  void _scheduleWindowSettings() {
    _windowSettingsTimer?.cancel();
    _windowSettingsTimer = Timer(const Duration(milliseconds: 500), () {
      var quality = currentQualityInfo.value;
      MultiWindow.reportSettings(WindowSettings(
        volume: AppSettingsController.instance.playerVolume.value,
        muted: muted.value,
        danmaku: showDanmakuState.value,
        quality: quality.isEmpty ? null : quality,
        audioDevice:
            MultiWindowPrefs.devicePerWindow.value ? audioDevice.value : null,
      ));
    });
  }

  Future<void> _restoreAudioDevice(String? saved) async {
    if (!await restoreAudioDevice(saved)) {
      SmartDialog.showToast("上次选的声音输出设备不在了，改用默认设备".t);
    }
  }

  /// 选声音输出设备（“每个窗口单独选声音输出设备”开着时，在“更多”里）
  Future<void> showAudioDeviceSheet() async {
    var list = await audioDevices();
    if (list.isEmpty) {
      SmartDialog.showToast("没有找到声音输出设备".t);
      return;
    }
    Utils.showBottomSheet(
      title: "声音输出设备".t,
      child: Obx(
        () => RadioGroup<String>(
          groupValue: audioDevice.value,
          onChanged: (name) {
            Get.back();
            var device = list.firstWhere((e) => e.name == name,
                orElse: () => AudioDevice.auto());
            unawaited(setAudioDevice(device));
            if (!MultiWindow.isSecondary) {
              MultiWindow.mainAudioDevice = device.name;
            }
          },
          child: ListView(
            children: [
              for (var device in list)
                RadioListTile<String>(
                  value: device.name,
                  title: Text(
                    device.name == "auto"
                        ? "默认设备".t
                        : (device.description.isEmpty
                            ? device.name
                            : device.description),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// iOS 系统播放器小窗用的 HLS 地址（平台没有时为 null，改用 mpv 小窗）
  Future<LivePlayUrl?> _iosAvPipSource() async {
    var room = detail.value;
    if (room == null || !liveStatus.value || currentQuality < 0) {
      return null;
    }
    if (currentQuality >= qualites.length) {
      return null;
    }
    // 直播源没写 avPlayerUrls 时改用 mpv 小窗
    if (!(site.script?.hasAvPlayer ?? true)) {
      return null;
    }
    return site.liveSite.getAvPlayerUrls(
      detail: room,
      quality: qualites[currentQuality],
    );
  }

  /// iOS 系统播放器小窗结束：mpv 暂停期间直播已经往前走了，
  /// 重新取当前清晰度的地址（斗鱼等平台的地址只能用一次），按当前线路拉到最新画面
  Future<void> _reopenAfterIosAvPip() async {
    if (isClosed || detail.value == null || !liveStatus.value) {
      return;
    }
    if (currentQuality < 0 || currentQuality >= qualites.length) {
      await player.play();
      return;
    }
    resetPlaybackRecovery();
    try {
      var playUrl = await site.liveSite.getPlayUrls(
        detail: detail.value!,
        quality: qualites[currentQuality],
      );
      if (isClosed) {
        return;
      }
      if (playUrl.urls.isNotEmpty) {
        playUrls.value = playUrl.urls;
        playHeaders = playUrl.headers;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    if (playUrls.isEmpty) {
      await player.play();
      return;
    }
    if (currentLineIndex < 0 || currentLineIndex >= playUrls.length) {
      currentLineIndex = 0;
    }
    await openPlaylist(startIndex: currentLineIndex);
  }

  /// 初始化自动关闭倒计时
  void initAutoExit() {
    if (AppSettingsController.instance.autoExitEnable.value) {
      autoExitEnable.value = true;
      autoExitMinutes.value =
          AppSettingsController.instance.autoExitDuration.value;
      setAutoExit();
    } else {
      autoExitMinutes.value =
          AppSettingsController.instance.roomAutoExitDuration.value;
      // 这个直播间（或平台）的单独设置里开着定时关闭：进来就开始
      if (AppSettingsController.instance.roomAutoExitEnable.value) {
        autoExitEnable.value = true;
        setAutoExit();
      }
    }
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      autoExitTimer?.cancel();
      return;
    }
    autoExitTimer?.cancel();
    countdown.value = autoExitMinutes.value * 60;
    autoExitTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      countdown.value -= 1;
      if (countdown.value <= 0) {
        autoExitTimer?.cancel();
        onAutoExitDue();
      }
    });
  }

  /// 定时关闭的时间到了：问要不要延迟，10 秒没回答（比如在后台听直播）就关闭
  Future<void> onAutoExitDue() async {
    var fallback = Timer(const Duration(seconds: 10), exitApp);
    var delay = await askDelayAutoExit();
    fallback.cancel();
    if (delay) {
      delayAutoExit.value = true;
      showAutoExitSheet();
      setAutoExit();
    } else {
      delayAutoExit.value = false;
      await exitApp();
    }
  }

  Future<bool> askDelayAutoExit() => Utils.showAlertDialog("定时关闭时间到了，要延迟吗？".t,
      title: "延迟关闭".t, confirm: "延迟".t, cancel: "关闭".t, selectable: true);

  Future<void> exitApp() async {
    await WakelockPlus.disable();
    // 多开窗口：退出前把位置告诉主窗口（和点关闭按钮一样）
    await MultiWindow.reportPlacementNow();
    // 主窗口：多开的窗口一起关
    await ExitGuard.runBeforeClose();
    await WebDavSyncService.instance.flushBeforeExit();
    exit(0);
  }
  // 弹窗逻辑

  void refreshRoom() {
    resetPlaybackRecovery();
    //messages.clear();
    clearSuperChats();
    clearGifts();
    rank.reset();
    clearLinkMic();
    liveDanmaku.stop();

    loadData();
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    // 屏蔽的人：聊天、SC、礼物刚进来就拦下（不进聊天区、视频弹幕、录屏接口和弹幕记录）
    if (userBlocks.drops(msg)) {
      return;
    }
    // iOS 系统播放器小窗：醒目留言显示在小窗顶部（屏蔽检查之后）
    if (msg.type == LiveMessageType.superChat) {
      var sc = msg.data;
      if (sc is LiveSuperChatMessage) iosPip?.addSuperChat(sc);
    }
    if (msg.type == LiveMessageType.chat) {
      // 关键词屏蔽检查
      for (var keyword in AppSettingsController.instance.shieldList) {
        Pattern? pattern;
        if (Utils.isRegexFormat(keyword)) {
          String removedSlash = Utils.removeRegexFormat(keyword);
          try {
            pattern = RegExp(removedSlash);
          } catch (e) {
            // should avoid this during add keyword
            Log.d("关键词：$keyword 正则格式错误");
          }
        } else {
          pattern = keyword;
        }
        if (pattern != null && msg.message.contains(pattern)) {
          Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
          return;
        }
      }

      // 用户屏蔽已在本函数开头检查；重复过滤在关键词屏蔽之后、弹幕缓冲之前
      // 重复弹幕过滤：默认只是不上视频；开了“聊天区也去掉重复”时整条不显示
      var repeat = _dedupe.check(msg);
      if (repeat == DanmakuRepeat.all) {
        return;
      }
      // 聊天栏也匀开进；补发的历史消息不排队
      _recordChat(msg, paced: !msg.history);
      // 历史消息（进直播间时补发的之前的聊天）只进聊天区和电视侧栏：
      // 不上视频弹幕，也不进录屏接口和弹幕记录，不然会一起飞过视频
      var live = !msg.history;
      if (live) {
        // 录屏接口和弹幕记录（屏蔽检查之后）
        _obs?.publishChat(this, msg);
        _assRecorder?.addChat(msg);
        // 流录制时和视频同名的弹幕文件
        for (var sidecar in captureSidecars) {
          sidecar.addChat(msg);
        }
      }
      // iOS 画中画和投屏：弹幕画在小窗/电视上，聊天进电视侧栏（后台时也要）
      iosPip?.addMessage(
        text: msg.message,
        color: (msg.color.r << 16) | (msg.color.g << 8) | msg.color.b,
        user: msg.userName,
        onVideo: live &&
            liveStatus.value &&
            showDanmakuState.value &&
            !listen.active.value &&
            repeat == DanmakuRepeat.none,
      );

      // 听直播时视频上不出弹幕，聊天照常
      if (!live ||
          !liveStatus.value ||
          isBackground ||
          listen.active.value ||
          repeat != DanmakuRepeat.none) {
        return;
      }

      // 弹幕延迟（按平台）
      _danmakuDelay.add(msg);
    } else if (msg.type == LiveMessageType.online) {
      // 直播间里的热度显示的就是这个数，跟着推送变
      var count = msg.data;
      if (count is! int || count <= 0) {
        return;
      }
      online.value = count;
      _obs?.publishOnline(this, online.value);
    } else if (msg.type == LiveMessageType.superChat) {
      addSuperChats([msg.data], live: true);
    } else if (msg.type == LiveMessageType.linkMic) {
      var state = msg.data;
      if (state is LiveLinkMicState) {
        setLinkMic(state);
      }
    } else if (msg.type == LiveMessageType.stats) {
      var stats = msg.data;
      if (stats is LiveRoomStats) {
        roomStats.value = roomStats.value.merge(stats);
      }
    } else if (msg.type == LiveMessageType.voiceRoom) {
      var room = msg.data;
      if (room is LiveVoiceRoom) {
        setVoiceRoom(room);
      }
    } else if (msg.type == LiveMessageType.voiceCaption) {
      var caption = msg.data;
      if (caption is LiveVoiceCaption) {
        voiceCaption.value = (caption, DateTime.now());
      }
    } else if (msg.type == LiveMessageType.gift) {
      var gift = msg.data;
      if (gift is LiveGiftMessage) {
        _addGift(gift, history: msg.history);
      }
    } else if (msg.type == LiveMessageType.rank) {
      // 榜单前几名的推送：读到过这个榜单时并进去
      var update = msg.data;
      if (update is LiveRankUpdate) {
        rank.applyUpdate(update);
      }
    }
  }

  /// 在线人数、贵宾数、多少人看过、点赞数（平台有才有）：进直播间时读一次，
  /// 之后跟着弹幕连接的推送变
  final roomStats = Rx<LiveRoomStats>(LiveRoomStats.none);

  /// 语聊房的房主和麦位（哔哩哔哩分区“聊天室”）。这类直播间的视频是平台合成的
  /// 低清截图，画面上改画这些；不是语聊房时为 null
  final voiceRoom = Rxn<LiveVoiceRoom>();

  /// 语聊房画上自己画的房主和麦位（false 时看平台给的原画面）
  final voiceView = true.obs;

  /// 语聊房里最近一句话（语音转文字）和收到的时间
  final voiceCaption = Rxn<(LiveVoiceCaption, DateTime)>();

  Timer? _voiceRoomTimer;

  /// 麦位变化没有推送，开着语聊房画面时隔一会儿重新读一次
  static const voiceRoomRefresh = Duration(seconds: 30);

  void setVoiceRoom(LiveVoiceRoom? room) {
    if (room != voiceRoom.value) {
      voiceRoom.value = room;
    }
    if (room == null) {
      _voiceRoomTimer?.cancel();
      _voiceRoomTimer = null;
      return;
    }
    _voiceRoomTimer ??=
        Timer.periodic(voiceRoomRefresh, (_) => _refreshVoiceRoom());
  }

  Future<void> _refreshVoiceRoom() async {
    var site = this.site.liveSite;
    if (isBackground || !voiceView.value || site is! BiliBiliSite) {
      return;
    }
    var key = "${this.site.id}|$roomId";
    try {
      var room = await site.getVoiceRoom(roomId);
      // 读的时候换了直播间：不要
      if (key != "${this.site.id}|$roomId" || voiceRoom.value == null) {
        return;
      }
      if (room != null) {
        setVoiceRoom(room);
      }
    } catch (e) {
      Log.d("读取语聊房麦位失败：$e");
    }
  }

  void clearVoiceRoom() {
    setVoiceRoom(null);
    voiceCaption.value = null;
    voiceView.value = true;
  }

  /// 连麦状态（平台推送的完整一份）；没有在连麦时 linked 为空
  final linkMic = Rx<LiveLinkMicState>(LiveLinkMicState.none);

  /// 点了标签上的 ×；连麦的人变了会重新显示
  final linkMicHidden = false.obs;

  /// 视频左下角要不要显示连麦标签
  bool get linkMicShown => linkMic.value.active && !linkMicHidden.value;

  void setLinkMic(LiveLinkMicState state) {
    var old = linkMic.value;
    if (state == old) {
      return;
    }
    var oldNames = old.linked.map((e) => e.name).toSet();
    var newNames = state.linked.map((e) => e.name).toSet();
    if (oldNames.length != newNames.length || !oldNames.containsAll(newNames)) {
      // 连麦的人变了（或重新开始连麦）：之前关掉的标签重新显示
      linkMicHidden.value = false;
    }
    linkMic.value = state;
  }

  void hideLinkMic() => linkMicHidden.value = true;

  void clearLinkMic() {
    linkMic.value = LiveLinkMicState.none;
    linkMicHidden.value = false;
  }

  /// 记下礼物（礼物页）；付费礼物交给视频左边的礼物浮层（[giftPopups]），
  /// 不进聊天和视频弹幕。进直播间时补发的之前的礼物（[history]）只记进礼物页
  void _addGift(LiveGiftMessage gift, {bool history = false}) {
    var (record, _) = giftBook.add(gift);
    giftVersion.value++;
    if (gift.paid && !history && !isBackground && !_giftPopups.isClosed) {
      _giftPopups.add(record);
    }
  }

  final StreamController<GiftRecord> _giftPopups =
      StreamController<GiftRecord>.broadcast();

  /// 付费礼物：新的一次送礼，或连击的数量更新（同一个 [GiftRecord]）
  Stream<GiftRecord> get giftPopups => _giftPopups.stream;

  void clearGifts() {
    giftBook.clear();
    giftVersion.value++;
  }

  /// 重复弹幕过滤（见 [DanmakuDedupeFilter]）
  late final DanmakuDedupeFilter _dedupe = DanmakuDedupeFilter(
    options: () => AppSettingsController.instance.danmakuDedupeOptions,
    siteId: () => site.id,
  );

  /// 弹幕延迟（见 [DanmakuDelayQueue]）：到时间后再交给弹幕缓冲
  late final DanmakuDelayQueue<LiveMessage> _danmakuDelay = DanmakuDelayQueue(
    (msg) {
      if (isClosed || !liveStatus.value || isBackground || listen.active.value) {
        return;
      }
      _addMessageDanmaku(msg);
    },
    delayMs: () => AppSettingsController.instance.danmuDelayMs(site.id),
  );

  /// 清屏时（换直播间、切到后台、进小窗）延迟里排着的和重复过滤的记录也清掉
  @override
  void clearDanmaku() {
    _danmakuDelay.clear();
    _dedupe.clear();
    super.clearDanmaku();
  }

  /// 视频上的弹幕：表情图片已解码好时直接显示，否则等一小会儿再显示
  /// （没加载好的表情显示为文字）
  void _addMessageDanmaku(LiveMessage msg) {
    var cache = DanmakuEmotes.instance;
    // 关掉“彩色弹幕”时全部为白色。Twitch、Kick 的颜色是名字的颜色，
    // 太暗的（深蓝等）在视频上看不清，和聊天区一样提亮；其他平台用户自己选的弹幕颜色不动
    var color = !AppSettingsController.instance.danmuColorful.value
        ? Colors.white
        : chatNameColor(msg.nameColor, dark: true) ??
            Color.fromARGB(255, msg.color.r, msg.color.g, msg.color.b);
    DanmakuContentItem build() => cache.build(
          msg.message,
          emotes: msg.emotes,
          sticker: msg.sticker,
          color: color,
        );
    if (!msg.hasEmotes ||
        cache.isReady(msg.message, emotes: msg.emotes, sticker: msg.sticker)) {
      addDanmaku([build()]);
      return;
    }
    cache
        .prepare(msg.message, emotes: msg.emotes, sticker: msg.sticker)
        .then((_) {
      if (isClosed || !liveStatus.value || isBackground || listen.active.value) {
        return;
      }
      addDanmaku([build()]);
    });
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    _recordChat(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: kSysMessageUser,
        message: msg,
        color: LiveMessageColor.white,
      ),
    );
  }

  /// 系统提示的“用户名”，不参与弹幕搜索
  static const String kSysMessageUser = "LiveSysMessage";

  /// 接收到WebSocket关闭信息
  void onWSClose(String msg) {
    addSysMsg(msg);
  }

  /// WebSocket准备就绪
  void onWSReady() {
    addSysMsg("弹幕服务器已连上".t);
  }

  // ---------------- 弹幕搜索 ----------------

  /// 搜索栏是否展开（宽屏侧栏内显示）
  var chatSearchOpen = false.obs;

  /// 按用户名搜索，否则按内容
  var chatSearchByUser = false.obs;

  /// 搜索输入框
  final TextEditingController chatSearchInputController =
      TextEditingController();
  final FocusNode chatSearchFocusNode = FocusNode();

  /// 搜索结果列表（同聊天栏：停在底部时跟随新结果，上翻查看时不打扰）
  final chatSearchList = TailListController();

  /// 搜索结果与标题，标题为空表示没有在搜索
  final chatSearchResults = <LiveChatRecord>[].obs;
  var chatSearchTitle = "".obs;

  /// 正在翻查较早的记录
  var chatSearchBusy = false.obs;

  /// 当前的搜索条件，新收到的弹幕符合时追加到结果里
  bool Function(LiveChatRecord item)? _chatSearchTest;

  /// 每次搜索加一，用来放弃过时的搜索
  int _chatSearchSeq = 0;

  /// 聊天栏的消息也匀开进（和视频上的弹幕一样，见 [DanmakuPacer]）。
  /// 平台一阵一阵发消息时，原来是十几条一起插进聊天栏、接着一两秒不动，
  /// 看着一段一段的；一起排版十几行也容易顿一下
  late final DanmakuPacer<LiveChatRecord> _chatPacer = DanmakuPacer(
    _showChat,
    smoothing: () => AppSettingsController.instance.danmuBufferBoost.value,
    minRateOf: () =>
        AppSettingsController.instance.danmuBufferMinRate.value.toDouble(),
  );

  /// 记录一条聊天消息（或系统提示），显示在聊天栏。记的时间是收到的时间。
  ///
  /// [paced]：匀开进聊天栏。不排队的（系统提示、补发的历史消息、自己发的）
  /// 先把排着队的放完再进，顺序不乱；在后台时没人看，也不排队
  void _recordChat(LiveMessage msg, {bool paced = false}) {
    var record = LiveChatRecord(DateTime.now(), msg);
    if (paced && !isBackground) {
      _chatPacer.add(record);
      return;
    }
    _chatPacer.flush();
    _showChat(record);
  }

  void _showChat(LiveChatRecord record) {
    chatLog.add(record);
    chatList.setLength(chatLog.length);
    var test = _chatSearchTest;
    if (test == null || !test(record)) {
      return;
    }
    chatSearchResults.add(record);
    chatSearchList.setLength(chatSearchResults.length);
  }

  /// 按输入框的内容搜索，内容和用户名都不区分大小写
  void searchChat() {
    var text = chatSearchInputController.text.trim();
    if (text.isEmpty) {
      clearChatSearch();
      return;
    }
    var keyword = text.toLowerCase();
    if (chatSearchByUser.value) {
      _runChatSearch(
        "用户名包含“{text}”的弹幕".tf({"text": text}),
        (e) => e.message.userName.toLowerCase().contains(keyword),
      );
    } else {
      // 表情按同一种写法比较：虎牙的 /{dx 和 [大笑] 都能搜到
      var content = readableChatText(text).toLowerCase();
      _runChatSearch(
        "包含“{text}”的弹幕".tf({"text": text}),
        (e) =>
            readableChatText(e.message.message).toLowerCase().contains(content),
      );
    }
  }

  /// 弹幕内容的可读写法：虎牙的表情代码（/{dx）换成 [大笑]，其他平台原样
  String readableChatText(String text) =>
      site.id == Constant.kHuya ? huyaReadableEmotes(text) : text;

  /// 把一条弹幕的内容放进搜索框（按内容搜），不马上搜，等用户自己点搜索
  void prefillChatSearch(LiveMessage msg) {
    var text = readableChatText(msg.message).trim();
    chatSearchByUser.value = false;
    chatSearchInputController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    openChatSearch();
  }

  /// 只看某个用户的弹幕：两边都有用户 ID 时按 ID（改名前后的都找得到），
  /// 否则用户名完全一致（见 [sameLiveUser]）
  void showUserChat(String userName, {String? userId}) {
    if (userName.isEmpty) {
      return;
    }
    _runChatSearch(
        "{userName} 的弹幕".tf({"userName": userName}),
        (e) => sameLiveUser(
            userId, userName, e.message.userId, e.message.userName));
  }

  Future<void> _runChatSearch(
    String title,
    bool Function(LiveChatRecord item) test,
  ) async {
    var seq = ++_chatSearchSeq;
    // 翻查期间收到的消息也会被翻查到，这时先不追加
    _chatSearchTest = null;
    chatSearchTitle.value = title;
    chatSearchResults.clear();
    chatSearchList.jumpToLatest(0);
    chatSearchBusy.value = true;
    var found = await chatLog.where(
      (e) => e.message.userName != kSysMessageUser && test(e),
      cancelled: () => seq != _chatSearchSeq,
    );
    if (found == null || seq != _chatSearchSeq) {
      return;
    }
    chatSearchBusy.value = false;
    _chatSearchTest = (e) => e.message.userName != kSysMessageUser && test(e);
    chatSearchResults.value = found;
    chatSearchList.jumpToLatest(found.length);
  }

  /// 清除搜索结果，回到实时聊天
  void clearChatSearch() {
    _chatSearchSeq++;
    _chatSearchTest = null;
    chatSearchBusy.value = false;
    chatSearchTitle.value = "";
    chatSearchResults.clear();
    chatSearchList.jumpToLatest(0);
  }

  /// 展开搜索栏并聚焦输入框
  void openChatSearch() {
    chatSearchOpen.value = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isClosed) {
        chatSearchFocusNode.requestFocus();
      }
    });
  }

  /// 退出搜索并收起搜索栏
  void closeChatSearch() {
    clearChatSearch();
    chatSearchInputController.clear();
    chatSearchOpen.value = false;
  }

  /// 加载直播间信息
  void loadData() async {
    try {
      SmartDialog.showLoading(msg: "");
      loadError.value = false;
      error = null;
      update();
      addSysMsg("正在加载直播间信息".t);
      // 自带平台装了直播源修正（§9）：告诉用户，出问题时知道找谁
      var fix = site.activeOverride;
      if (fix != null) {
        addSysMsg("{name}正在使用直播源修正：{name2} {version}".tf({
          "name": site.name,
          "name2": fix.info.name,
          "version": fix.info.version
        }));
      }
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);
      // 设置页里显示的直播间名字换成主播名
      _enterRoomContext();

      if (site.id == Constant.kDouyin) {
        // 1.6.0之前收藏的WebRid
        // 1.6.0收藏的RoomID
        // 1.6.0之后改回WebRid
        if (detail.value!.roomId != roomId) {
          var oldId = roomId;
          rxRoomId.value = detail.value!.roomId;
          if (followed.value) {
            // 更新关注列表（开播提醒的订阅跟着换过去）
            var old = DBService.instance.followBox.get("${site.id}_$oldId");
            DBService.instance.deleteFollow("${site.id}_$oldId");
            DBService.instance.addFollow(
              FollowUser(
                id: "${site.id}_$roomId",
                roomId: roomId,
                siteId: site.id,
                userName: detail.value!.userName,
                face: detail.value!.userAvatar,
                addTime: DateTime.now(),
                notify: old?.notify ?? false,
              ),
            );
          } else {
            followed.value =
                DBService.instance.getFollowExist("${site.id}_$roomId");
          }
        }
      }

      // 直播源没写 SC 时不读取
      if (!site.isScript || supportsSuperChat) {
        getSuperChatMessage();
      }

      addHistory();
      // 确认房间关注状态
      followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
      online.value = detail.value!.online;
      roomStats.value = detail.value!.stats ?? LiveRoomStats.none;
      setVoiceRoom(detail.value!.voiceRoom);
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      _detailKey = "${site.id}|$roomId";
      _onRoomInfoChanged();
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        addSysMsg("主播没开播，正在放轮播录像".t);
      }
      initDanmau();
      if (site.hasDanmaku) {
        addSysMsg("正在连接弹幕服务器".t);
        liveDanmaku.start(detail.value?.danmakuData);
      } else {
        addSysMsg("{name}不支持弹幕".tf({"name": site.name}));
      }
      startLiveDurationTimer(); // 启动开播时长定时器
    } catch (e) {
      Log.logPrint(e);
      //SmartDialog.showToast(e.toString());
      loadError.value = true;
      // 直播源脚本的错误可能是 Exception
      error = e is Error ? e : CoreError(e.toString());
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 初始化播放器
  void getPlayQualites() async {
    qualites.clear();
    currentQuality = -1;

    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: detail.value!);

      if (playQualites.isEmpty) {
        SmartDialog.showToast("获取不到清晰度".t);
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = await getQualityLevel();
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }
      // 选了“记住上次”时用这个平台上次手动选的
      currentQuality = PlayPrefs.instance.pickQuality(
          site.id, playQualites, currentQuality,
          cellular: qualityOnCellular);
      // 多开窗口打开上次的：用那个窗口里选的清晰度
      var preferred = _preferredQuality;
      _preferredQuality = null;
      if (preferred != null) {
        var index = playQualites.indexWhere((e) => e.quality == preferred);
        if (index >= 0) {
          currentQuality = index;
        }
      }

      getPlayUrl();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("获取不到清晰度".t);
    }
  }

  /// 进直播间时用的是不是数据网络（记住上次的清晰度两种网络分开记）
  bool qualityOnCellular = false;

  Future<int> getQualityLevel() async {
    var qualityLevel = AppSettingsController.instance.qualityLevel.value;
    qualityOnCellular = false;
    try {
      var connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.first == ConnectivityResult.mobile) {
        qualityOnCellular = true;
        qualityLevel =
            AppSettingsController.instance.qualityLevelCellular.value;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return qualityLevel;
  }

  void getPlayUrl() async {
    playUrls.clear();
    currentQualityInfo.value = qualites[currentQuality].quality;
    currentLineInfo.value = "";
    currentLineIndex = -1;
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("获取不到播放地址".t);
      return;
    }
    playUrls.value = playUrl.urls;
    playHeaders = playUrl.headers;
    currentLineIndex = 0;
    currentLineInfo.value = "线路{p}".tf({"p": currentLineIndex + 1});
    //重置错误次数
    mediaErrorRetryCount = 0;
    initPlaylist();
  }

  void changePlayLine(int index) {
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    resetPlaybackRecovery();
    setPlayer();
  }

  void initPlaylist() async {
    resetPlaybackRecovery();
    await openPlaylist(startIndex: currentLineIndex < 0 ? 0 : currentLineIndex);
  }

  /// 打开当前线路列表，从 [startIndex] 开始播放
  Future<void> openPlaylist({int startIndex = 0}) async {
    currentLineInfo.value = "线路{p}".tf({"p": startIndex + 1});
    errorMsg.value = "";

    final mediaList = playUrls.map((url) {
      var finalUrl = url;
      if (AppSettingsController.instance.playerForceHttps.value) {
        finalUrl = finalUrl.replaceAll("http://", "https://");
      }
      return Media(finalUrl, httpHeaders: playHeaders);
    }).toList();

    // 初始化播放器并设置 ao 参数
    await initializePlayer();
    // HLS（Twitch、Kick 等）与 FLV 用不同的网络参数
    await StreamTuning.apply(player, mediaList.map((e) => e.uri).toList());
    _bufferFloor.clear();

    await player.open(Playlist(mediaList, index: startIndex));
  }

  void setPlayer() async {
    currentLineInfo.value = "线路{p}".tf({"p": currentLineIndex + 1});
    errorMsg.value = "";

    await player.jump(currentLineIndex);
  }

  @override
  void mediaEnd() {
    super.mediaEnd();
    recoverPlayback("直播断流了".t);
  }

  @override
  void mediaError(String error) {
    super.mediaError(error);
    Log.d("播放失败：$error");
    recoverPlayback("播放出错".t);
  }

  /// 兼容旧的重试计数，手动切换线路/清晰度时清零
  int mediaErrorRetryCount = 0;

  /// 断流恢复
  ///
  /// 直播 CDN 偶尔会断开连接，而斗鱼等平台的播放地址只能使用一次，
  /// 原地重连同一个地址必然失败，之前会因此误判为“未开播”。
  /// 这里每次都重新读取直播间信息和播放地址，并在多次失败时轮换线路；
  /// 只有直播间确实已下播才停止。
  static const int kMaxRecoverAttempts = 8;
  static const List<int> kRecoverDelays = [1, 2, 3, 5, 8, 10, 10, 10];
  int recoverAttempts = 0;
  bool _recovering = false;

  /// 正在断流重连（听直播的卡片和通知上显示“正在重新连接”）
  bool get recovering => _recovering;
  Timer? _stallTimer;
  Timer? _stableTimer;
  StreamSubscription<bool>? _bufferingSubscription;

  /// 缓冲超过该时长视为卡死
  static const Duration kStallTimeout = Duration(seconds: 20);

  /// 连续正常播放该时长后，清零失败次数
  static const Duration kStableDuration = Duration(seconds: 30);

  /// 缓冲到时间时数据还在进来（下载速度不低于 [kSlowNetworkMinSpeed]），说明网络只是慢，
  /// 没有断：每次再等 [kSlowNetworkStep]，最多再等 [kSlowNetworkGrace]。
  /// 重连会丢掉已经缓冲的内容，网络慢的时候反而越连越卡
  static const Duration kSlowNetworkGrace = Duration(seconds: 40);
  static const Duration kSlowNetworkStep = Duration(seconds: 10);
  static const double kSlowNetworkMinSpeed = 16 * 1024;

  /// 缓冲了 [waited] 还没恢复、下载速度是 [speed]（字节/秒，读不到为 null）时，要不要再等等
  static bool keepWaitingForSlowNetwork(double? speed, Duration waited) =>
      speed != null &&
      speed >= kSlowNetworkMinSpeed &&
      waited < kStallTimeout + kSlowNetworkGrace;

  Future<double?> _cacheSpeed() async {
    try {
      if (player.platform is NativePlayer) {
        var value =
            await (player.platform as NativePlayer).getProperty('cache-speed');
        return double.tryParse(value);
      }
    } catch (_) {}
    return null;
  }

  void _armStallTimer(Duration timeout, DateTime since) {
    _stallTimer?.cancel();
    _stallTimer = Timer(timeout, () async {
      // 用户主动暂停时不算卡死
      if (!(player.state.buffering && player.state.playing)) {
        return;
      }
      var speed = await _cacheSpeed();
      if (keepWaitingForSlowNetwork(speed, DateTime.now().difference(since))) {
        _armStallTimer(kSlowNetworkStep, since);
        return;
      }
      if (player.state.buffering && player.state.playing) {
        recoverPlayback("卡住太久".t);
      }
    });
  }

  void initPlaybackWatchdog() {
    _bufferingSubscription = player.stream.buffering.listen((buffering) {
      if (buffering) {
        _stableTimer?.cancel();
        _armStallTimer(kStallTimeout, DateTime.now());
      } else {
        _stallTimer?.cancel();
        _stableTimer?.cancel();
        _stableTimer = Timer(kStableDuration, () {
          if (!player.state.buffering && player.state.playing) {
            recoverAttempts = 0;
          }
        });
      }
    });
  }

  /// 手动刷新或切换直播间后，进行中的恢复流程作废
  int _recoverGeneration = 0;

  void resetPlaybackRecovery() {
    _recoverGeneration++;
    _recovering = false;
    recoverAttempts = 0;
    _stallTimer?.cancel();
    _stableTimer?.cancel();
  }

  void disposePlaybackWatchdog() {
    _bufferingSubscription?.cancel();
    _stallTimer?.cancel();
    _stableTimer?.cancel();
  }

  Future<void> recoverPlayback(String reason) async {
    if (_recovering || isClosed || detail.value == null) {
      return;
    }
    // 暂停期间断流不重连，也不算失败；继续时会重新拉流
    if (livePause.paused.value) {
      return;
    }
    // iOS 系统播放器小窗期间 mpv 暂停着，小窗结束后会重新拉流
    if (iosPip?.mpvSuspended ?? false) {
      return;
    }
    if (!liveStatus.value || qualites.isEmpty || currentQuality < 0) {
      return;
    }
    _recovering = true;
    _stallTimer?.cancel();
    _stableTimer?.cancel();
    var generation = _recoverGeneration;
    bool stale() => isClosed || generation != _recoverGeneration;
    try {
      while (!stale()) {
        if (recoverAttempts >= kMaxRecoverAttempts) {
          errorMsg.value = "播放断了，重连失败，点刷新试试".t;
          addSysMsg("重连几次都没成功，请手动刷新".t);
          return;
        }
        recoverAttempts++;
        var attempt = recoverAttempts;
        addSysMsg("{reason}，正在重新连接（{attempt}/{kMaxRecoverAttempts}）".tf({
          "reason": reason,
          "attempt": attempt,
          "kMaxRecoverAttempts": kMaxRecoverAttempts
        }));
        var delay = kRecoverDelays[min(attempt, kRecoverDelays.length) - 1];
        await Future.delayed(Duration(seconds: delay));
        if (stale()) {
          return;
        }
        try {
          // 重新读取直播间：既能确认是否已下播，也能拿到新的签名/防盗链参数
          var fresh = await site.liveSite.getRoomDetail(roomId: roomId);
          if (!fresh.status && !fresh.isRecord) {
            liveStatus.value = false;
            addSysMsg("主播已下播".t);
            await player.stop();
            return;
          }
          detail.value = fresh;
          var qualityName = qualites[currentQuality].quality;
          var freshQualities =
              await site.liveSite.getPlayQualites(detail: fresh);
          if (freshQualities.isEmpty) {
            continue;
          }
          var index =
              freshQualities.indexWhere((e) => e.quality == qualityName);
          if (index < 0) {
            index = min(currentQuality, freshQualities.length - 1);
          }
          var playUrl = await site.liveSite.getPlayUrls(
            detail: fresh,
            quality: freshQualities[index],
          );
          if (stale()) {
            return;
          }
          if (playUrl.urls.isEmpty) {
            continue;
          }
          qualites.value = freshQualities;
          currentQuality = index;
          currentQualityInfo.value = freshQualities[index].quality;
          playUrls.value = playUrl.urls;
          playHeaders = playUrl.headers;
          // 连续失败时轮换线路
          currentLineIndex = (attempt - 1) % playUrl.urls.length;
          await openPlaylist(startIndex: currentLineIndex);
          return;
        } catch (e) {
          Log.logPrint(e);
        }
      }
    } finally {
      if (generation == _recoverGeneration) {
        _recovering = false;
      }
    }
  }

  /// 读取SC
  void getSuperChatMessage() async {
    try {
      var sc =
          await site.liveSite.getSuperChatMessage(roomId: detail.value!.roomId);
      addSuperChats(sc.where(userBlocks.keepsSuperChat));
    } catch (e) {
      Log.logPrint(e);
      addSysMsg("SC 加载失败".t);
    }
  }

  /// 移除掉已到期的SC
  /// 移除已结束的 SC（按直播间时长显示时）
  void removeSuperChats() {
    trimSuperChats();
  }

  /// 当前时间（秒），每秒更新，SC 倒计时与状态都以它为准，
  /// 不依赖 SC 页面是否打开
  var scNow = (DateTime.now().millisecondsSinceEpoch ~/ 1000).obs;
  Timer? _scTimer;

  /// 本场最多保留的 SC 数量。SC 要能翻看、搜索、导出，尽量都留着；
  /// 一条只有几百字节，两万条也只有几 MB
  static const int kMaxSuperChats = 20000;

  String superChatKey(LiveSuperChatMessage sc) =>
      sc.id ??
      "${sc.userName}_${sc.startTime.millisecondsSinceEpoch}_${sc.message}";

  /// SC 在直播间里是否仍在显示（未到结束时间）
  bool isSuperChatActive(LiveSuperChatMessage sc) =>
      sc.endTime.millisecondsSinceEpoch ~/ 1000 > scNow.value;

  /// 剩余显示秒数，已结束为 0
  int superChatRemaining(LiveSuperChatMessage sc) =>
      max(0, sc.endTime.millisecondsSinceEpoch ~/ 1000 - scNow.value);

  /// 加入 SC，按 id 去重（进房时的历史列表与弹幕连接可能重复）。
  /// [live] 为 true 表示弹幕连接刚收到的（写进弹幕记录），否则是进房时读到的历史
  void addSuperChats(
    Iterable<LiveSuperChatMessage> list, {
    bool live = false,
  }) {
    var added = list.where((e) => _superChatKeys.add(superChatKey(e))).toList();
    if (added.isEmpty) {
      return;
    }
    _obs?.publishSuperChats(this, added, live: live);
    if (live) {
      _assRecorder?.addSuperChats(added);
      for (var sidecar in captureSidecars) {
        sidecar.addSuperChats(added);
      }
    }
    _superChatHistory.addAll(added);
    if (_superChatHistory.length > kMaxSuperChats) {
      var drop = _superChatHistory.length - kMaxSuperChats;
      for (var sc in _superChatHistory.take(drop)) {
        _superChatKeys.remove(superChatKey(sc));
      }
      _superChatHistory.removeRange(0, drop);
    }
    trimSuperChats();
  }

  void clearSuperChats() {
    _superChatHistory.clear();
    _superChatKeys.clear();
    superChats.clear();
  }

  void initSuperChatTimer() {
    _scTimer?.cancel();
    _scTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      scNow.value = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      trimSuperChats();
    });
  }

  /// 按显示方式从本场记录里选出要显示的：按直播间时长时只显示未结束的，一直显示时全部显示。
  /// 每秒调用一次，列表没有变化时不触发界面刷新
  void trimSuperChats() {
    var mode = AppSettingsController.instance.superChatDisplayMode.value;
    var shown = mode == 0
        ? _superChatHistory.where(isSuperChatActive).toList()
        : _superChatHistory;
    if (shown.length == superChats.length &&
        Iterable.generate(shown.length)
            .every((i) => identical(shown[i], superChats[i]))) {
      return;
    }
    superChats.assignAll(shown);
  }

  /// SC 列表的显示顺序：仍在显示的在前（先结束的在前），已结束的按时间倒序。
  /// SC 页按设置从上往下排，或者从下往上排（第一条贴着底部，和弹幕一样）
  List<LiveSuperChatMessage> get sortedSuperChats {
    var active = superChats.where(isSuperChatActive).toList()
      ..sort((a, b) => a.endTime.compareTo(b.endTime));
    var ended = superChats.where((e) => !isSuperChatActive(e)).toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    return [...active, ...ended];
  }

  /// 当前播放倍速（追帧时大于 1）
  var playbackRate = 1.0.obs;
  Timer? _catchUpTimer;
  bool _catchingUp = false;
  bool _catchUpBusy = false;
  DateTime? _catchUpHoldUntil;

  /// 最近 10 秒缓冲的最低值：HLS 按整段到达，当前值会周期性跳高
  final _bufferFloor = BufferFloor();

  /// 当前播放的是 HLS（Twitch、Kick 等分段直播流）
  bool get _playingHls => playUrls.any(StreamTuning.isHls);

  void initCatchUp() {
    _catchUpTimer?.cancel();
    _catchUpTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _catchUpTick(),
    );
  }

  /// 已缓冲但尚未播放的时长（秒），近似表示落后于最新直播画面的时间
  Future<double?> _bufferedAheadSeconds() async {
    try {
      if (player.platform is NativePlayer) {
        var value = await (player.platform as NativePlayer)
            .getProperty('demuxer-cache-duration');
        var seconds = double.tryParse(value);
        if (seconds != null) {
          return seconds;
        }
      }
    } catch (_) {}
    var ahead = player.state.buffer - player.state.position;
    if (ahead.isNegative) {
      return null;
    }
    return ahead.inMilliseconds / 1000;
  }

  Future<void> _setPlaybackRate(double rate) async {
    rate = (rate * 100).round() / 100;
    if ((playbackRate.value - rate).abs() < 0.005) {
      return;
    }
    playbackRate.value = rate;
    try {
      await player.setRate(rate);
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 追帧：缓冲比目标多 1 秒以上时开始加速（最多到设置的倍速，步长 0.01），
  /// 追到目标以内恢复 1 倍；出现卡顿加载时立即恢复 1 倍并暂停追帧 5 秒（HLS 15 秒）
  Future<void> _catchUpTick() async {
    if (_catchUpBusy || isClosed) {
      return;
    }
    _catchUpBusy = true;
    try {
      var settings = AppSettingsController.instance;
      var live = liveStatus.value && !(detail.value?.isRecord ?? false);
      if (!settings.liveCatchUp.value || !live || !player.state.playing) {
        _catchingUp = false;
        _bufferFloor.clear();
        await _setPlaybackRate(1.0);
        return;
      }
      if (player.state.buffering) {
        _catchingUp = false;
        _bufferFloor.clear();
        // HLS 卡顿后要等几段下载完，暂停追帧更久
        _catchUpHoldUntil =
            DateTime.now().add(Duration(seconds: _playingHls ? 15 : 5));
        await _setPlaybackRate(1.0);
        return;
      }
      if (_catchUpHoldUntil != null &&
          DateTime.now().isBefore(_catchUpHoldUntil!)) {
        await _setPlaybackRate(1.0);
        return;
      }
      var ahead = await _bufferedAheadSeconds();
      if (ahead == null) {
        return;
      }
      _bufferFloor.add(ahead);
      var floor = _bufferFloor.floor();
      if (floor == null) {
        // 样本还不够，先按 1 倍播放
        _catchingUp = false;
        await _setPlaybackRate(1.0);
        return;
      }
      var decision = CatchUpPolicy.decide(
        ahead: floor,
        target: CatchUpPolicy.targetFor(
          settings.liveCatchUpTarget.value,
          hls: _playingHls,
        ),
        maxRate: settings.liveCatchUpMaxRate.value,
        catchingUp: _catchingUp,
      );
      _catchingUp = decision.catchingUp;
      await _setPlaybackRate(decision.rate);
    } finally {
      _catchUpBusy = false;
    }
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var room = detail.value!;
    // 哔哩哔哩这里给的是原图，首页用的是 400 宽的
    var cover = room.cover;
    if (site.id == Constant.kBiliBili &&
        cover.isNotEmpty &&
        !cover.contains("@")) {
      cover = "$cover@400w.jpg";
    }
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history
        ..userName = room.userName
        ..face = room.userAvatar
        ..updateTime = DateTime.now()
        ..cover = cover
        ..title = room.title
        // 这次没读到分区（比如没开播）时留着上次的
        ..area = room.area ?? history.area;
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: room.userName,
      face: room.userAvatar,
      updateTime: DateTime.now(),
      cover: cover,
      title: room.title,
      area: room.area,
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  void followUser() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    // 打开了“同步到账号”的平台会同步到账号（本地马上生效）
    FollowService.instance.follow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  /// 取消关注用户
  /// 关注列表里长按后取消关注：正在看的这个直播间走 [removeFollowUser]（底栏的按钮跟着变），
  /// 其他的确认后直接取消
  Future<void> unfollowFromList(FollowUser item) async {
    if (item.siteId == site.id && item.roomId == roomId) {
      removeFollowUser();
      return;
    }
    var localOnly =
        await AccountFollowService.confirmUnfollow(item.siteId, item.userName);
    if (localOnly == null) {
      return;
    }
    await FollowService.instance.unfollow(item, localOnly: localOnly);
    EventBus.instance.emit(Constant.kUpdateFollow, item.id);
  }

  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    var localOnly = await AccountFollowService.confirmUnfollow(
      site.id,
      detail.value?.userName ?? "",
    );
    if (localOnly == null) {
      return;
    }

    var id = "${site.id}_$roomId";
    var user = DBService.instance.followBox.get(id) ??
        FollowUser(
          id: id,
          roomId: roomId,
          siteId: site.id,
          userName: detail.value?.userName ?? "",
          face: detail.value?.userAvatar ?? "",
          addTime: DateTime.now(),
        );
    await FollowService.instance.unfollow(user, localOnly: localOnly);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  void share() {
    if (detail.value == null) {
      return;
    }
    AppShare.share(ShareParams(uri: Uri.parse(detail.value!.url)));
  }

  void copyUrl() {
    if (detail.value == null) {
      return;
    }
    Utils.copyToClipboard(detail.value!.url);
    SmartDialog.showToast("已复制直播间链接".t);
  }

  /// 复制新生成的直播流
  void copyPlayUrl() async {
    // 未开播不复制
    if (!liveStatus.value) {
      return;
    }
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("获取不到播放地址".t);
      return;
    }
    Utils.copyToClipboard(playUrl.urls.first);
    SmartDialog.showToast("已复制播放直链".t);
  }

  /// 底部打开播放器设置
  void showDanmuSettingsSheet() {
    Utils.showBottomSheet(
      title: "弹幕设置".t,
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            onTapDanmuShield: () {
              Get.back();
              showDanmuShield();
            },
          ),
        ],
      ),
    );
  }

  void showVolumeSlider(BuildContext targetContext) {
    SmartDialog.showAttach(
      targetContext: targetContext,
      alignment: Alignment.topCenter,
      displayTime: const Duration(seconds: 3),
      maskColor: const Color(0x00000000),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: AppStyle.radius12,
            color: Theme.of(context).cardColor,
          ),
          padding: AppStyle.edgeInsetsA4,
          child: Obx(
            () => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 静音：不改音量，再点回到原来的音量
                IconButton(
                  tooltip: muted.value ? "取消静音".t : "静音".t,
                  onPressed: () => setMuted(!muted.value),
                  icon: Icon(muted.value ? Icons.volume_off : Icons.volume_up),
                ),
                SizedBox(
                  width: 200,
                  child: Slider(
                    min: 0,
                    max: 100,
                    value: AppSettingsController.instance.playerVolume.value,
                    onChanged: (newValue) {
                      muted.value = false;
                      player.setVolume(newValue);
                      AppSettingsController.instance.setPlayerVolume(newValue);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void showQualitySheet() {
    Utils.showBottomSheet(
      title: "切换清晰度".t,
      child: RadioGroup(
        groupValue: currentQuality,
        onChanged: (e) {
          Get.back();
          switchQualityManually(e ?? 0);
        },
        child: ListView.builder(
          itemCount: qualites.length,
          itemBuilder: (_, i) {
            var item = qualites[i];
            return RadioListTile(
              value: i,
              title: Text(item.quality.t),
            );
          },
        ),
      ),
    );
  }

  void showPlayUrlsSheet() {
    Utils.showBottomSheet(
      title: "切换线路".t,
      child: RadioGroup(
        groupValue: currentLineIndex,
        onChanged: (e) {
          Get.back();
          //currentLineIndex = i;
          //setPlayer();
          changePlayLine(e ?? 0);
        },
        child: ListView.builder(
          itemCount: playUrls.length,
          itemBuilder: (_, i) {
            return RadioListTile(
              value: i,
              title: Text("线路{p}".tf({"p": i + 1})),
              secondary: Text(
                playUrls[i].contains(".flv") ? "FLV" : "HLS",
              ),
            );
          },
        ),
      ),
    );
  }

  void showPlayerSettingsSheet() {
    Utils.showBottomSheet(
      title: "画面尺寸".t,
      child: Obx(
        () => RadioGroup(
          groupValue: AppSettingsController.instance.scaleMode.value,
          onChanged: (e) {
            AppSettingsController.instance.setScaleMode(e ?? 0);
            updateScaleMode();
          },
          child: ListView(
            padding: AppStyle.edgeInsetsV12,
            children: [
              RadioListTile(
                value: 0,
                title: Text("适应".t),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 1,
                title: Text("拉伸".t),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 2,
                title: Text("铺满".t),
                visualDensity: VisualDensity.compact,
              ),
              const RadioListTile(
                value: 3,
                title: Text("16:9"),
                visualDensity: VisualDensity.compact,
              ),
              const RadioListTile(
                value: 4,
                title: Text("4:3"),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showDanmuShield() {
    TextEditingController keywordController = TextEditingController();

    void addKeyword() {
      if (keywordController.text.isEmpty) {
        SmartDialog.showToast("请输入关键词".t);
        return;
      }

      AppSettingsController.instance
          .addShieldList(keywordController.text.trim());
      keywordController.text = "";
    }

    Utils.showBottomSheet(
      title: "关键词屏蔽".t,
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          TextField(
            controller: keywordController,
            decoration: InputDecoration(
              contentPadding: AppStyle.edgeInsetsH12,
              border: const OutlineInputBorder(),
              hintText: "请输入关键词".t,
              suffixIcon: TextButton.icon(
                onPressed: addKeyword,
                icon: const Icon(Icons.add),
                label: Text("添加".t),
              ),
            ),
            onSubmitted: (e) {
              addKeyword();
            },
          ),
          AppStyle.vGap12,
          Obx(
            () => Text(
              "已添加 {shieldListCount} 个关键词（点一下可移除）".tf({
                "shieldListCount":
                    AppSettingsController.instance.shieldList.length
              }),
              style: Get.textTheme.titleSmall,
            ),
          ),
          AppStyle.vGap12,
          Obx(
            () => Wrap(
              runSpacing: 12,
              spacing: 12,
              children: AppSettingsController.instance.shieldList
                  .map(
                    (item) => InkWell(
                      borderRadius: AppStyle.radius24,
                      onTap: () {
                        AppSettingsController.instance.removeShieldList(item);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: AppStyle.radius24,
                        ),
                        padding: AppStyle.edgeInsetsH12.copyWith(
                          top: 4,
                          bottom: 4,
                        ),
                        child: Text(
                          item,
                          style: Get.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  /// 直播间里切到“关注”、打开关注列表时：关注很多时第一次提示一下可以少查一些，
  /// 然后按“关注设置”查开播状态（全部、一个分组或者不查）
  void onFollowListShown() {
    var settings = AppSettingsController.instance;
    var count = DBService.instance.followBox.length;
    if (count > FollowService.manyFollows &&
        settings.liveRoomFollowCheck.value == "all" &&
        !settings.manyFollowsHinted.value) {
      settings.setManyFollowsHinted(true);
      unawaited(_showManyFollowsHint(count));
    }
    unawaited(FollowService.instance
        .refreshForLiveRoom(siteId: site.id, roomId: roomId));
  }

  Future<void> _showManyFollowsHint(int count) async {
    var go = await Utils.showAlertDialog(
      "你关注了 {count} 个主播，每次切换到“关注”都要逐个检查开播状态，耗时较长，请求也较多。可以在“关注设置”中改为只检查一个分组，或不检查。此提示只显示一次"
          .tf({"count": count}),
      title: "关注的主播较多".t,
      confirm: "去设置".t,
      cancel: "知道了".t,
    );
    if (go) {
      Get.toNamed(RoutePath.kSettingsFollow);
    }
  }

  void showFollowUserSheet() {
    // 打开关注列表时查一遍开播状态（看直播时定时刷新会推迟）
    onFollowListShown();
    Utils.showBottomSheet(
      title: "关注列表".t,
      child: Obx(
        () => Stack(
          children: [
            RefreshIndicator(
              onRefresh: FollowService.instance.loadData,
              child: ListView.builder(
                itemCount: FollowService.instance.liveList.length,
                itemBuilder: (_, i) {
                  var item = FollowService.instance.liveList[i];
                  return Obx(
                    () => FollowUserItem(
                      item: item,
                      playing: rxSite.value.id == item.siteId &&
                          rxRoomId.value == item.roomId,
                      onTap: () {
                        Get.back();
                        resetRoomOf(item.siteId, item.roomId);
                      },
                      onToggleNotify: () =>
                          LiveNotifyService.instance.toggleSubscription(item),
                      onLongPress: () => showFollowActions(
                        item,
                        onUnfollow: () => unfollowFromList(item),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
              Positioned(
                right: 12,
                bottom: 12,
                child: Obx(
                  () => DesktopRefreshButton(
                    refreshing: FollowService.instance.updating.value,
                    onPressed: FollowService.instance.loadData,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void showAutoExitSheet() {
    if (AppSettingsController.instance.autoExitEnable.value &&
        !delayAutoExit.value) {
      SmartDialog.showToast("设置里已经开启了定时关闭".t);
      return;
    }
    Utils.showBottomSheet(
      title: "定时关闭".t,
      child: ListView(
        children: [
          Obx(
            () => SwitchListTile(
              title: Text(
                "启用定时关闭".t,
                style: Get.textTheme.titleMedium,
              ),
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;
                // 直播间、平台单独设置打开时记下来，下次进来自动开始
                AppSettingsController.instance.setRoomAutoExitEnable(e);
                setAutoExit();
                //controller.setAutoExitEnable(e);
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                "自动关闭时间：{p}小时{p2}分钟".tf({
                  "p": autoExitMinutes.value ~/ 60,
                  "p2": autoExitMinutes.value % 60
                }),
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration =
                    Duration(hours: value.hour, minutes: value.minute);
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance
                    .setRoomAutoExitDuration(autoExitMinutes.value);
                //setAutoExitDuration(duration.inMinutes);
                setAutoExit();
              },
            ),
          ),
        ],
      ),
    );
  }

  void openNaviteAPP() async {
    var naviteUrl = "";
    var webUrl = "";
    if (site.isScript) {
      // 直播源只有网页地址
      var url = detail.value?.url ?? "";
      if (url.isEmpty) {
        SmartDialog.showToast("这个直播间没有网页地址".t);
        return;
      }
      try {
        await launchUrlString(url, mode: LaunchMode.externalApplication);
      } catch (e) {
        Log.logPrint(e);
        SmartDialog.showToast("打不开直播间网页".t);
      }
      return;
    }
    if (site.id == Constant.kBiliBili) {
      naviteUrl = "bilibili://live/${detail.value?.roomId}";
      webUrl = "https://live.bilibili.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyin &&
        detail.value?.danmakuData is DouyinDanmakuArgs) {
      // 直播间信息来自直播源修正时没有内置的弹幕参数，走最后的网页地址
      var args = detail.value?.danmakuData as DouyinDanmakuArgs;
      naviteUrl = "snssdk1128://webcast_room?room_id=${args.roomId}";
      webUrl = "https://live.douyin.com/${args.webRid}";
    } else if (site.id == Constant.kHuya &&
        detail.value?.danmakuData is HuyaDanmakuArgs) {
      var args = detail.value?.danmakuData as HuyaDanmakuArgs;
      naviteUrl =
          "yykiwi://homepage/index.html?banneraction=https%3A%2F%2Fdiy-front.cdn.huya.com%2Fzt%2Ffrontpage%2Fcc%2Fupdate.html%3Fhyaction%3Dlive%26channelid%3D${args.subSid}%26subid%3D${args.subSid}%26liveuid%3D${args.subSid}%26screentype%3D1%26sourcetype%3D0%26fromapp%3Dhuya_wap%252Fclick%252Fopen_app_guide%26&fromapp=huya_wap/click/open_app_guide";
      webUrl = "https://www.huya.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyu) {
      naviteUrl =
          "douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D${detail.value?.roomId}";
      webUrl = "https://www.douyu.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kTwitch) {
      naviteUrl = "twitch://stream/${detail.value?.roomId}";
      webUrl = "https://www.twitch.tv/${detail.value?.roomId}";
    } else if (site.id == Constant.kKick) {
      // Kick 没有公开的 App 跳转协议，直接打开网页
      await launchUrlString("https://kick.com/${detail.value?.roomId}",
          mode: LaunchMode.externalApplication);
      return;
    } else if (site.id == Constant.kYouTube) {
      // 房间号是频道 ID；网页链接在装了 YouTube App 的手机上会直接用 App 打开
      await launchUrlString(
          "https://www.youtube.com/channel/${detail.value?.roomId}/live",
          mode: LaunchMode.externalApplication);
      return;
    }
    if (naviteUrl.isEmpty) {
      // 直播间信息来自直播源修正（没有内置的参数）：打开网页
      var url = detail.value?.url ?? "";
      if (url.isEmpty) {
        SmartDialog.showToast("这个直播间没有网页地址".t);
        return;
      }
      try {
        await launchUrlString(url, mode: LaunchMode.externalApplication);
      } catch (e) {
        Log.logPrint(e);
        SmartDialog.showToast("打不开直播间网页".t);
      }
      return;
    }
    try {
      await launchUrlString(naviteUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("打不开 App，改用浏览器打开".t);
      await launchUrlString(webUrl, mode: LaunchMode.externalApplication);
    }
  }

  // ---------------- 录屏接口与弹幕记录 ----------------

  /// 当前直播间的信息（录屏接口推送、弹幕记录的备注用）
  ObsRoomInfo obsRoomInfo() {
    var room = detail.value;
    if (_detailKey != "${site.id}|$roomId") {
      room = null;
    }
    return ObsRoomInfo(
      site: site.id,
      siteName: site.name,
      roomId: roomId,
      title: room?.title ?? "",
      streamer: room?.userName ?? "",
      avatar: room?.userAvatar ?? "",
      cover: room?.cover ?? "",
      live: room != null && liveStatus.value,
      isRecord: room?.isRecord ?? false,
      url: room?.url ?? "",
      online: online.value,
    );
  }

  void _onRoomInfoChanged() {
    // 换直播间后、读到新信息之前不显示上一个直播间的公告
    roomNotice.update(_detailKey == "${site.id}|$roomId" ? detail.value : null);
    _obs?.updateRoom(this);
    _noteWindowRoom();
    var recorder = _assRecorder;
    if (recorder != null && _detailKey == "${site.id}|$roomId") {
      var info = obsRoomInfo();
      recorder.noteRoom(info.key, info.label);
    }
  }

  DanmakuAssRecorder? _assRecorder;
  bool _assStarting = false;

  /// 截图和录屏（顶栏、全屏时右边的按钮，见 app/capture）
  late final CaptureController capture =
      createCaptureController(LiveCaptureHost(this));

  /// 流录制时和视频同名的弹幕文件（见 LiveCaptureHost.startSidecar）
  final List<DanmakuAssRecorder> captureSidecars = [];

  /// ⋯ 菜单和全屏顶栏里的截图也走截图和录屏的流程（图层、保存位置、图片信息）
  @override
  Future saveScreenshot() => capture.screenshot();
  Timer? _assRecordTimer;

  /// 正在记录弹幕（ASS）
  var assRecording = false.obs;

  /// 已记录的时长，如“03:25”
  var assRecordTime = "".obs;

  /// 开始或停止记录弹幕
  Future<void> toggleAssRecording() async {
    if (_assRecorder != null) {
      await stopAssRecording();
    } else {
      await startAssRecording();
    }
  }

  /// 开始记录弹幕：之后收到的弹幕（经过关键词屏蔽）写进 ASS 文件，
  /// 时间从现在算起。不需要打开录屏接口
  Future<void> startAssRecording() async {
    if (_assRecorder != null || _assStarting) {
      return;
    }
    _assStarting = true;
    try {
      var dir = await ObsBridgeService.danmakuRecordDirectory(
          _obs?.recordDir.value ?? "");
      var info = obsRoomInfo();
      var recorder = await DanmakuAssRecorder.start(
        dir: dir,
        options: AssOptions.fromConfig(ObsBridgeService.danmakuConfig()),
        site: site.id,
        roomId: roomId,
        roomKey: info.key,
        roomLabel: info.label,
      );
      if (isClosed) {
        await recorder.stop();
        return;
      }
      _assRecorder = recorder;
      assRecording.value = true;
      _updateAssRecordTime();
      _assRecordTimer?.cancel();
      _assRecordTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _updateAssRecordTime(),
      );
      addSysMsg("开始记录弹幕（ASS）".t);
      SmartDialog.showToast(
          "开始记录弹幕，保存到 {path}".tf({"path": recorder.file.path}));
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法开始记录弹幕：{e}".tf({"e": e}));
    } finally {
      _assStarting = false;
    }
  }

  void _updateAssRecordTime() {
    var recorder = _assRecorder;
    if (recorder == null) {
      return;
    }
    var seconds = recorder.elapsed.inSeconds;
    String two(int v) => v.toString().padLeft(2, "0");
    var h = seconds ~/ 3600;
    var m = (seconds % 3600) ~/ 60;
    var s = seconds % 60;
    assRecordTime.value =
        h > 0 ? "$h:${two(m)}:${two(s)}" : "${two(m)}:${two(s)}";
  }

  /// 停止记录弹幕；[closing] 为关闭直播间时，只提示保存的位置
  Future<void> stopAssRecording({bool closing = false}) async {
    var recorder = _assRecorder;
    if (recorder == null) {
      return;
    }
    _assRecorder = null;
    _assRecordTimer?.cancel();
    assRecording.value = false;
    File file;
    try {
      file = await recorder.stop();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("保存弹幕记录失败：{e}".tf({"e": e}));
      return;
    }
    var summary = "已记录 {count} 条弹幕".tf({"count": recorder.count});
    if (recorder.dropped > 0) {
      summary += "（另有 {dropped} 条因弹幕行占满没写入）".tf({"dropped": recorder.dropped});
    }
    if (closing) {
      SmartDialog.showToast(
          "{summary}，保存在 {path}".tf({"summary": summary, "path": file.path}));
      return;
    }
    addSysMsg("停止记录弹幕（ASS）".t);
    var desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    if (desktop) {
      var open = await Utils.showAlertDialog(
        "{summary}，保存在：\n{path}".tf({"summary": summary, "path": file.path}),
        title: "记录弹幕（ASS）".t,
        confirm: "打开文件夹".t,
        cancel: "关闭".t,
        selectable: true,
      );
      if (open) {
        await DanmakuAssRecorder.reveal(file);
      }
      return;
    }
    var share = await Utils.showAlertDialog(
      "{summary}，保存在：\n{path}".tf({"summary": summary, "path": file.path}),
      title: "记录弹幕（ASS）".t,
      confirm: "分享".t,
      cancel: "关闭".t,
      selectable: true,
    );
    if (share) {
      try {
        await AppShare.share(ShareParams(files: [XFile(file.path)]));
      } catch (e) {
        Log.logPrint(e);
        SmartDialog.showToast("分享失败：{e}".tf({"e": e}));
      }
    }
  }

  /// 进直播间以来收到的弹幕条数（不含系统提示），导出窗口里显示
  int get exportableChatCount {
    var n = 0;
    for (var i = 0; i < chatLog.length; i++) {
      var msg = chatLog[i].message;
      if (!msg.history && msg.userName != kSysMessageUser) {
        n++;
      }
    }
    return n;
  }

  int get exportableSuperChatCount => _superChatHistory.length;

  /// 有开播时间（导出时可以按开播时间对齐）
  bool get hasLiveStartTime =>
      (int.tryParse(detail.value?.showTime ?? "") ?? 0) > 0;

  /// 把到现在为止收到的弹幕、SC、礼物导出成一个 ASS 文件，返回文件和说明。
  ///
  /// [alignLiveStart] 为 true 且平台给了开播时间时，0 秒是开播时间，
  /// 否则 0 秒是第一条内容的时间
  Future<(File, String)?> exportDanmakuAss({
    bool chats = true,
    bool superChats = true,
    bool gifts = true,
    bool alignLiveStart = true,
  }) async {
    var chatItems = <(DateTime, LiveMessage)>[
      if (chats)
        for (var i = 0; i < chatLog.length; i++)
          (chatLog[i].time, chatLog[i].message),
    ];
    var scItems =
        superChats ? List.of(_superChatHistory) : <LiveSuperChatMessage>[];
    var giftItems = gifts ? List.of(giftBook.records) : <GiftRecord>[];
    var earliest = earliestExportTime(
      chats: chatItems,
      superChats: scItems,
      gifts: giftItems,
      sysUser: kSysMessageUser,
    );
    if (earliest == null) {
      SmartDialog.showToast("还没有可以导出的内容".t);
      return null;
    }
    var origin = alignLiveStart
        ? LiveExportOrigin.choose(
            showTime: detail.value?.showTime, earliest: earliest)
        : LiveExportOrigin(
            earliest,
            "第一条记录 {formatExportTime}"
                .tf({"formatExportTime": formatExportTime(earliest)}));
    var count = DanmakuExportCount();
    var comments = liveExportComments(
      origin: origin.time,
      chats: chatItems,
      superChats: scItems,
      gifts: giftItems,
      sysUser: kSysMessageUser,
      count: count,
    );
    var info = obsRoomInfo();
    var content = AssDanmakuWriter.build(
      exportAssOptions(ObsBridgeService.danmakuConfig()),
      comments,
      title: info.label.isEmpty
          ? "SimpleLive 弹幕".t
          : "SimpleLive 弹幕 - {label}".tf({"label": info.label}),
      notes: [
        if (info.label.isNotEmpty) "直播间：{label}".tf({"label": info.label}),
        "时间轴：0 秒对应{label}".tf({"label": origin.label}),
        if (origin.liveStart) "按开播时间对齐".t,
        "导出时间：{formatExportTime}"
            .tf({"formatExportTime": formatExportTime(DateTime.now())}),
        "内容：{count}".tf({"count": count}),
      ],
    );
    var dir = await ObsBridgeService.danmakuRecordDirectory(
        _obs?.recordDir.value ?? "");
    var name = assFileName(site: site.id, roomId: roomId, time: DateTime.now())
        .replaceFirst(".ass", "_export.ass");
    var file = await writeAssExport(dir: dir, name: name, content: content);
    var summary =
        "已导出{count}。0 秒对应{label}".tf({"count": count, "label": origin.label});
    return (file, summary);
  }

  /// 切换到关注列表里的直播间；平台未安装（已删除的直播源）时只提示
  void resetRoomOf(String siteId, String roomId) {
    var site = Sites.allSites[siteId];
    if (site == null) {
      SmartDialog.showToast("{missingSiteText}，无法打开"
          .tf({"missingSiteText": Sites.missingSiteText(siteId)}));
      return;
    }
    resetRoom(site, roomId);
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }
    // 正在录的是原来的直播间：先停下保存
    capture.stopForLeave();

    rxSite.value = site;
    rxRoomId.value = roomId;
    // 弹幕设置按平台、直播间记忆时换成新直播间的
    _enterRoomContext();
    _noteWindowRoom();
    // 录屏接口先换成新直播间（清掉旧的弹幕），读到房间信息后再补上标题
    _obs?.updateRoom(this);

    // 清除全部消息
    resetPlaybackRecovery();
    liveDanmaku.stop();
    _chatPacer.clear();
    chatLog.clear();
    chatList.jumpToLatest(0);
    iosPip?.clearDanmaku();
    closeChatSearch();
    // 离开了这个直播间：本次进入的屏蔽解除
    userBlocks.leaveRoom();
    roomNotice.enterRoom();
    clearSuperChats();
    clearGifts();
    rank.reset();
    clearLinkMic();
    roomStats.value = LiveRoomStats.none;
    clearVoiceRoom();
    clearDanmaku();

    // 重新设置LiveDanmaku
    liveDanmaku = createDanmaku(site);

    // 停止播放
    await player.stop();

    // 刷新信息
    loadData();
  }

  /// 听直播时不开小窗（安卓画中画、iOS 画中画、电脑小窗）
  @override
  Future enablePIP() async {
    if (listen.active.value) return;
    return super.enablePIP();
  }

  @override
  void enterSmallWindow() {
    if (listen.active.value) return;
    super.enterSmallWindow();
  }

  void copyErrorDetail() {
    Utils.copyToClipboard('''直播平台：{name}
房间号：{rxRoomId}
错误信息：
{error}
----------------
{stackTrace}'''
        .tf({
      "name": rxSite.value.name,
      "rxRoomId": rxRoomId.value,
      "error": error?.toString(),
      "stackTrace": error?.stackTrace
    }));
    SmartDialog.showToast("已复制错误信息".t);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    onLifecycleForPause(state);

    if (state == AppLifecycleState.paused) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      clearDanmaku();
      // 聊天栏排着队的直接放完（后台时计时器可能停）
      _chatPacer.flush();
      isBackground = true;
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
    }
  }

  // 用于启动开播时长计算和更新的函数
  void startLiveDurationTimer() {
    // 如果不是直播状态或者 showTime 为空，则不启动定时器
    if (!(detail.value?.status ?? false) || detail.value?.showTime == null) {
      liveDuration.value = "00:00:00"; // 未开播时显示 00:00:00
      _liveDurationTimer?.cancel();
      return;
    }

    try {
      int startTimeStamp = int.parse(detail.value!.showTime!);
      // 取消之前的定时器
      _liveDurationTimer?.cancel();
      // 创建新的定时器，每秒更新一次
      _liveDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        liveDuration.value = formattedDuration;
      });
    } catch (e) {
      liveDuration.value = "--:--:--"; // 错误时显示 --:--:--
    }
  }

  /// 弹幕设置按平台、按直播间记忆：告诉设置现在看的是哪个直播间
  late final String _danmuContextId = "live:${identityHashCode(this)}";
  void _enterRoomContext() {
    var name = detail.value?.userName ?? "";
    AppSettingsController.instance.enterRoomContext(
      RoomContext(
        id: _danmuContextId,
        siteId: site.id,
        siteName: site.name,
        roomId: roomId,
        roomLabel: name.isNotEmpty ? name : roomId,
      ),
    );
  }

  /// 多开：这个窗口在看哪个直播间（副窗口告诉主窗口，主窗口自己记着），
  /// “打开上次的窗口”用。读到房间信息之前标题和主播名是空的
  void _noteWindowRoom() {
    var room = _detailKey == "${site.id}|$roomId" ? detail.value : null;
    MultiWindow.noteRoom(
      this,
      WindowRoom(
        siteId: site.id,
        roomId: roomId,
        title: room?.title ?? "",
        userName: room?.userName ?? "",
      ),
    );
  }

  @override
  void onClose() {
    _windowSettingsWorker?.dispose();
    _windowSettingsTimer?.cancel();
    _voiceRoomTimer?.cancel();
    MultiWindow.leaveRoom(this);
    AppSettingsController.instance.leaveRoomContext(_danmuContextId);
    _iosDanmakuWorker?.dispose();
    _danmakuModeWorker?.dispose();
    _chatKeepWorker?.dispose();
    _obsRoomWorker?.dispose();
    _obs?.detach(this);
    disposeListenMode();
    stopAssRecording(closing: true);
    capture.dispose();
    iosPip?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    autoExitTimer?.cancel();
    _tabJumps.close();
    _giftPopups.close();

    liveDanmaku.stop();
    _danmakuDelay.clear();
    danmakuPacer.clear();
    _chatPacer.clear();
    danmakuController = null;
    _chatSearchSeq++;
    _chatSearchTest = null;
    // 删除存聊天记录的临时文件
    chatLog.dispose();
    chatSearchInputController.dispose();
    chatSearchFocusNode.dispose();
    disposePlaybackWatchdog();
    livePause.dispose();
    _scTimer?.cancel();
    _catchUpTimer?.cancel();
    _liveDurationTimer?.cancel(); // 页面关闭时取消定时器
    super.onClose();
  }
}
