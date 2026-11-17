// 听直播：锁屏和控制中心的“正在播放”、远程控制（耳机线控、锁屏按钮），
// 音频中断（来电、Siri、别的应用）和拔耳机，“与其他应用同时播放”的音频会话设置。
// 播放还是 mpv（它自己把音频会话设成 .playback）；这里只管系统界面和事件，
// 事件交给 Dart 决定怎么办。通道和安卓同名：simple_live/background_playback。
// Dart -> 原生：startService、updateService、stopService、audioActive。
// 原生 -> Dart：onAction（play、pause、toggle、stop）、onFocus（gain、ended、lossTransient、noisy）。
// 只在主线程使用
import AVFoundation
import Flutter
import MediaPlayer
import UIKit

final class BackgroundAudioController: NSObject {
  static let channelName = "simple_live/background_playback"

  private let channel: FlutterMethodChannel
  private var observers: [NSObjectProtocol] = []
  private var commandTargets: [(MPRemoteCommand, Any)] = []
  /// 锁屏卡片显示着（听直播）
  private var nowPlayingActive = false
  /// 直播间在播（Dart 告诉的）：这时才把中断和拔耳机转给 Dart
  private var audioActive = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: BackgroundAudioController.channelName, binaryMessenger: messenger)
    super.init()
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] notification in
        self?.interrupted(notification)
      },
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
      ) { [weak self] notification in
        self?.routeChanged(notification)
      },
    ]
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      self.handle(call, result: result)
    }
  }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  // MARK: - 通道

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "startService":
      start(args)
      result(true)
    case "updateService":
      if nowPlayingActive {
        updateNowPlaying(args)
      }
      result(nil)
    case "stopService":
      stop()
      result(nil)
    case "audioActive":
      audioActive = (args["active"] as? Bool) ?? false
      if audioActive {
        applyCategory(mix: (args["mix"] as? Bool) ?? false)
      }
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func send(_ method: String, _ arguments: [String: Any]) {
    channel.invokeMethod(method, arguments: arguments)
  }

  // MARK: - 音频会话

  /// mpv 把会话设成 .playback（会让别的应用停下）；“与其他应用同时播放”时加上 .mixWithOthers。
  /// 和现在一样就不动（画中画也在用这个会话）
  private func applyCategory(mix: Bool) {
    let session = AVAudioSession.sharedInstance()
    let options: AVAudioSession.CategoryOptions = mix ? [.mixWithOthers] : []
    if session.category == .playback && session.categoryOptions == options {
      return
    }
    do {
      try session.setCategory(.playback, mode: .moviePlayback, options: options)
    } catch {
      NSLog("SimpleLive background audio: setCategory failed %@", error.localizedDescription)
    }
  }

  private func interrupted(_ notification: Notification) {
    guard audioActive || nowPlayingActive,
      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    switch type {
    case .began:
      send("onFocus", ["event": "lossTransient"])
    case .ended:
      let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
        .contains(.shouldResume)
      // 来电等结束后重新激活，再让 Dart 重新拉流
      try? AVAudioSession.sharedInstance().setActive(true)
      send("onFocus", ["event": shouldResume ? "gain" : "ended"])
    @unknown default:
      break
    }
  }

  /// 拔掉耳机（或断开蓝牙耳机）：暂停
  private func routeChanged(_ notification: Notification) {
    guard audioActive,
      let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
      reason == .oldDeviceUnavailable
    else { return }
    send("onFocus", ["event": "noisy"])
  }

  // MARK: - 锁屏卡片

  private func start(_ args: [String: Any]) {
    let session = AVAudioSession.sharedInstance()
    do {
      if session.category != .playback {
        try session.setCategory(.playback, mode: .moviePlayback, options: [])
      }
      try session.setActive(true)
    } catch {
      NSLog("SimpleLive background audio: session failed %@", error.localizedDescription)
    }
    if !nowPlayingActive {
      nowPlayingActive = true
      registerCommands()
      UIApplication.shared.beginReceivingRemoteControlEvents()
    }
    updateNowPlaying(args)
  }

  private func stop() {
    guard nowPlayingActive else { return }
    nowPlayingActive = false
    unregisterCommands()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    UIApplication.shared.endReceivingRemoteControlEvents()
  }

  private func updateNowPlaying(_ args: [String: Any]) {
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: (args["title"] as? String) ?? "",
      MPMediaItemPropertyArtist: (args["subtitle"] as? String) ?? "",
      MPNowPlayingInfoPropertyIsLiveStream: true,
    ]
    let playing = ((args["state"] as? String) ?? "playing") != "paused"
    info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
    if let data = args["artwork"] as? FlutterStandardTypedData,
      let image = UIImage(data: data.data)
    {
      info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in
        image
      }
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func registerCommands() {
    let center = MPRemoteCommandCenter.shared()
    let commands: [(MPRemoteCommand, String)] = [
      (center.playCommand, "play"),
      (center.pauseCommand, "pause"),
      (center.togglePlayPauseCommand, "toggle"),
      (center.stopCommand, "stop"),
    ]
    for (command, action) in commands {
      command.isEnabled = true
      let target = command.addTarget { [weak self] _ in
        self?.send("onAction", ["action": action])
        return .success
      }
      commandTargets.append((command, target))
    }
  }

  private func unregisterCommands() {
    for (command, target) in commandTargets {
      command.removeTarget(target)
      command.isEnabled = false
    }
    commandTargets.removeAll()
  }
}
