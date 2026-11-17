// iOS 系统画中画（AVPlayer）：前台仍由 mpv 播放，开小窗时改由系统播放器播同一直播间的 HLS。
// 解码和画面合成都在系统进程里，App 在后台几乎不占 CPU，
// 也不用后台 OpenGL；mpv 只暂停、不关闭（mpv 关闭音频输出时会停用整个音频会话）。
// 小窗里的弹幕用 Core Animation 图层（DanmakuLayerView，和投屏共用），两种方式：
// - 通话式小窗：系统小窗里显示我们自己的界面（画面层 + 弹幕层），没有暂停和进度按钮；
//   应用在后台时系统不往 AVPlayerLayer 上画，画面由 AvPipFramePump 从解码输出取帧显示；
// - 叠加：标准小窗，把弹幕层加到系统小窗的私有窗口上（实验，找不到窗口时没有弹幕）。
// 弹幕关闭时用标准小窗。只在主线程使用。
import AVFoundation
import AVKit
import Flutter
import UIKit

/// AVPlayerLayer 随视图大小变化
final class AvPipPlayerView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// AVSampleBufferDisplayLayer 随视图大小变化
final class AvPipFrameView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// 通话式小窗的画面：从系统播放器的解码输出（AVPlayerItemVideoOutput）取帧，
/// 送进 AVSampleBufferDisplayLayer。应用切到后台后系统不再往 AVPlayerLayer 上画，
/// 小窗里只剩弹幕在动；通话类应用的小窗就是用 AVSampleBufferDisplayLayer 显示对方画面的。
/// 帧是解码器输出的 IOSurface，不复制。取帧、送帧都在自己的队列上（后台也照常运行）
@available(iOS 15.0, *)
final class AvPipFramePump {
  private let layer: AVSampleBufferDisplayLayer
  private let queue = DispatchQueue(label: "simplelive.avpip.frames", qos: .userInteractive)
  private let lock = NSLock()
  private var output: AVPlayerItemVideoOutput?
  private weak var item: AVPlayerItem?
  private var timer: DispatchSourceTimer?
  /// 只在 queue 上用
  private var formatDescription: CMVideoFormatDescription?
  private var sent = 0

  init(layer: AVSampleBufferDisplayLayer) {
    self.layer = layer
  }

  /// 送出的帧数（诊断日志用）
  var frames: Int {
    lock.lock()
    defer { lock.unlock() }
    return sent
  }

  /// 从 [item] 取帧（直播重新拉流时播放项会变）。主线程调用
  func attach(_ item: AVPlayerItem?) {
    if let item = item, item === self.item, currentOutput != nil { return }
    detachOutput()
    guard let item = item else { return }
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
    ])
    item.add(output)
    self.item = item
    lock.lock()
    self.output = output
    lock.unlock()
  }

  func start() {
    guard timer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
    timer.setEventHandler { [weak self] in self?.tick() }
    timer.resume()
    self.timer = timer
  }

  /// 停止取帧并清掉画面。主线程调用
  func stop() {
    timer?.cancel()
    timer = nil
    detachOutput()
    let layer = self.layer
    queue.async { [weak self] in
      self?.formatDescription = nil
      layer.flushAndRemoveImage()
    }
  }

  private var currentOutput: AVPlayerItemVideoOutput? {
    lock.lock()
    defer { lock.unlock() }
    return output
  }

  private func detachOutput() {
    lock.lock()
    let old = output
    output = nil
    lock.unlock()
    if let old = old, let item = item, item.outputs.contains(old) {
      item.remove(old)
    }
    item = nil
  }

  private func tick() {
    guard let output = currentOutput else { return }
    let time = output.itemTime(forHostTime: CACurrentMediaTime())
    guard output.hasNewPixelBuffer(forItemTime: time),
      let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    else { return }
    // 锁屏一段时间后要 flush 才能继续显示，否则画面停住或变黑
    if layer.status == .failed || layer.requiresFlushToResumeDecoding {
      layer.flush()
    }
    guard layer.isReadyForMoreMediaData else { return }
    if let format = formatDescription,
      !CMVideoFormatDescriptionMatchesImageBuffer(format, imageBuffer: buffer)
    {
      formatDescription = nil
    }
    if formatDescription == nil {
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer,
        formatDescriptionOut: &formatDescription)
    }
    guard let format = formatDescription else { return }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
        sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
      let sampleBuffer = sample
    else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer, createIfNecessary: true)
    {
      let attachment = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        attachment,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    layer.enqueue(sampleBuffer)
    lock.lock()
    sent += 1
    lock.unlock()
  }
}

/// 通话式小窗的内容：底下是画面（前台用 AVPlayerLayer，上面盖一层取帧显示的画面，
/// 后台只有后者有画面），最上面是弹幕
@available(iOS 15.0, *)
private final class AvPipCallContent {
  let viewController: AVPictureInPictureVideoCallViewController
  let videoView: AvPipPlayerView
  let frameView: AvPipFrameView
  let frames: AvPipFramePump
  let danmakuView: DanmakuLayerView

  init(player: AVPlayer) {
    viewController = AVPictureInPictureVideoCallViewController()
    videoView = AvPipPlayerView()
    frameView = AvPipFrameView()
    frames = AvPipFramePump(layer: frameView.displayLayer)
    danmakuView = DanmakuLayerView(frame: .zero)
    let root: UIView = viewController.view
    root.backgroundColor = .black
    root.clipsToBounds = true
    videoView.frame = root.bounds
    videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    videoView.isUserInteractionEnabled = false
    videoView.backgroundColor = .black
    videoView.playerLayer.videoGravity = .resizeAspect
    videoView.playerLayer.player = player
    root.addSubview(videoView)
    // 还没取到帧时是透明的，露出下面的 AVPlayerLayer
    frameView.frame = root.bounds
    frameView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    frameView.isUserInteractionEnabled = false
    frameView.backgroundColor = .clear
    frameView.displayLayer.videoGravity = .resizeAspect
    root.addSubview(frameView)
    danmakuView.frame = root.bounds
    danmakuView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    danmakuView.pipSizing = true
    root.addSubview(danmakuView)
    // 小窗的宽高比；拿到画面尺寸后改成画面的
    viewController.preferredContentSize = CGSize(width: 1920, height: 1080)
  }
}

/// 进程的 CPU 时间和内存（诊断日志用）
enum AvPipStats {
  static func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    return user + system
  }

  static func memoryFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / 1_048_576
  }
}

@available(iOS 15.0, *)
final class AvPlayerPipController: NSObject, AVPictureInPictureControllerDelegate {
  static let channelName = "simple_live/ios_avpip"

  /// 小窗弹幕方式
  private enum Mode: String {
    /// 通话式小窗：自己的界面（画面层 + 弹幕层）
    case call = "通话式"
    /// 标准小窗，弹幕加到系统小窗的私有窗口上（实验）
    case overlay = "叠加"
    /// 标准小窗，没有弹幕
    case plain = "无弹幕"
  }

  /// 开小窗前等系统播放器准备好的最长时间，超过后改用 mpv 小窗
  private static let startTimeout: Double = 8
  /// 卡住这么久就重新取地址
  private static let stallTimeout: Double = 8
  /// 连续失败这么多次就关掉小窗
  private static let maxFailures = 3

  private let channel: FlutterMethodChannel
  private var player: AVPlayer?
  private var item: AVPlayerItem?
  /// 应用窗口里的小视图：预热时 2×2 点，开小窗时铺到播放器的位置（透明度 0.01，看不出来）。
  /// 标准小窗从它的 AVPlayerLayer 开始，通话式小窗以它为来源视图
  private var hostView: AvPipPlayerView?
  private var callContent: AvPipCallContent?
  private var pipController: AVPictureInPictureController?
  private var controllerMode = Mode.call
  private var overlayView: DanmakuLayerView?
  private weak var overlayWindow: UIWindow?
  private var overlayTimer: Timer?
  private var overlaySearches = 0

  private var style = DanmakuStyle()
  private var danmakuMode = Mode.call
  private var superChatEnabled = true

  private var urls: [String] = []
  private var headers: [String: String] = [:]
  private var urlIndex = 0
  private var isLive = true
  private var rate: Float = 1
  private var shouldPlay = true
  private var pendingSeek: Double?
  private var lastPosition: Double = 0
  private var sourceRect: CGRect?

  /// 直播间开着“退到后台自动小窗”：静音播放着，切到后台时系统自动开小窗
  private var prewarmWanted = false
  private var startResult: FlutterResult?
  private var startTimeoutWork: DispatchWorkItem?
  private var startRequested = false
  private var active = false
  private var restoring = false
  /// 已让 Dart 暂停 mpv、打开系统播放器的声音
  private var tookOver = false
  private var takeoverPending = false
  private var takeoverId = 0
  /// 换了播放项后，系统播放器开始播放时再让 mpv 暂停
  private var takeoverWhenPlaying = false
  private var stopForFailure = false
  /// Dart 释放了这个会话（页面关闭或被别的页面接手）：关小窗时不再回调
  private var suppressStopEvent = false
  private var startedAt: CFTimeInterval = 0
  /// 小窗正在关闭（关闭时系统会暂停播放器，不算用户暂停）
  private var stopping = false
  /// 用户在小窗里按了暂停
  private var pausedInPip = false

  private var possibleObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var itemObservations: [NSKeyValueObservation] = []
  private var itemObservers: [NSObjectProtocol] = []
  private var interruptionObserver: NSObjectProtocol?
  private var lifecycleObservers: [NSObjectProtocol] = []

  private var failures = 0
  private var recovering = false
  private var replacingItem = false
  private var stallWork: DispatchWorkItem?
  private var stableWork: DispatchWorkItem?
  private var backgroundTask = UIBackgroundTaskIdentifier.invalid
  /// 每次拆掉播放器加一，之前发出的异步回调作废
  private var generation = 0

  private var diagnosticsTimer: Timer?
  private var lastCpuTime: Double = 0
  private var lastWallTime: CFTimeInterval = 0

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: AvPlayerPipController.channelName, binaryMessenger: messenger)
    super.init()
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] notification in
      self?.audioInterrupted(notification)
    }
    // 通话式小窗：后台时让播放器只给取帧输出解码（见 AvPipFramePump）
    lifecycleObservers = [
      NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        self?.updateCallLayers()
      },
      NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        self?.updateCallLayers()
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
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  // MARK: - 通道

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isSupported":
      result(AVPictureInPictureController.isPictureInPictureSupported())
    case "configure":
      configure(args)
      result(nil)
    case "prewarm":
      result(prewarm(args))
    case "stopPrewarm":
      stopPrewarm()
      result(nil)
    case "start":
      start(args, result: result)
    case "stop":
      stop(reason: args["reason"] as? String ?? "应用关闭小窗")
      result(nil)
    case "dispose":
      dispose()
      result(nil)
    case "state":
      result(playbackState())
    case "danmaku":
      let messages = (args["items"] as? [Any] ?? []).compactMap(DanmakuMessage.init)
      if let view = danmakuView {
        for message in messages {
          view.add(message)
        }
      }
      result(nil)
    case "superChat":
      if superChatEnabled, let view = danmakuView, let text = args["t"] as? String {
        let color =
          UInt32(truncatingIfNeeded: (args["c"] as? NSNumber)?.int64Value ?? 0xE54D4D) & 0xFFFFFF
        view.addSuperChat(text, background: color)
      }
      result(nil)
    case "clearDanmaku":
      callContent?.danmakuView.clear()
      overlayView?.clear()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 小窗正在显示的弹幕层（弹幕关闭、没在小窗时为空）
  private var danmakuView: DanmakuLayerView? {
    guard active, style.pipEnabled else { return nil }
    switch controllerMode {
    case .call: return callContent?.danmakuView
    case .overlay: return overlayView
    case .plain: return nil
    }
  }

  private var wantedMode: Mode { style.pipEnabled ? danmakuMode : .plain }

  private func configure(_ args: [String: Any]) {
    style = DanmakuStyle(args)
    superChatEnabled = args["superChat"] as? Bool ?? true
    danmakuMode = (args["danmakuMode"] as? NSNumber)?.intValue == 1 ? .overlay : .call
    callContent?.danmakuView.apply(style)
    overlayView?.apply(style)
    if !style.pipEnabled {
      callContent?.danmakuView.clear()
      overlayView?.clear()
    }
    // 弹幕方式改了：没在小窗里时换一个画中画控制器
    if pipController != nil, !active, startResult == nil, controllerMode != wantedMode {
      releaseController()
      if ensureController() {
        updateAutoStart()
      } else {
        teardown()
      }
    }
  }

  // MARK: - 预热（直播间开着“退到后台自动小窗”时）

  private func prewarm(_ args: [String: Any]) -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported(), !active,
      startResult == nil, applySource(args)
    else { return false }
    sourceRect = rect(from: args["sourceRect"]) ?? sourceRect
    let player = ensurePlayer()
    player.isMuted = true
    guard let host = ensureHostView() else {
      sendLog("找不到应用窗口，不能预热")
      teardown()
      return false
    }
    // 自动开小窗要求播放器在页面上可见：预热时也铺到播放器的位置（透明度 1%，不挡操作）
    placeHost(host, expanded: true)
    failures = 0
    guard loadItem(urls[0], at: nil), ensureController() else {
      teardown()
      return false
    }
    prewarmWanted = true
    updateAutoStart()
    sendLog("静音预热（直播），切到后台时自动开小窗；弹幕：\(controllerMode.rawValue)")
    return true
  }

  private func stopPrewarm() {
    prewarmWanted = false
    updateAutoStart()
    if !active && startResult == nil && player != nil {
      sendLog("停止预热")
      teardown()
    }
  }

  /// 预热或小窗里才允许切到后台时自动开小窗（只有直播）
  private func updateAutoStart() {
    guard let pip = pipController, !active else { return }
    let enabled = prewarmWanted && isLive && item?.status == .readyToPlay
    if pip.canStartPictureInPictureAutomaticallyFromInline != enabled {
      pip.canStartPictureInPictureAutomaticallyFromInline = enabled
      sendLog(enabled ? "已允许切到后台时自动开小窗" : "切到后台时不自动开小窗")
    }
  }

  // MARK: - 开小窗（播放器上的按钮）

  private func start(_ args: [String: Any], result: @escaping FlutterResult) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      result(FlutterError(code: "av_unsupported", message: "设备不支持画中画", details: nil))
      return
    }
    if active {
      result(true)
      return
    }
    guard startResult == nil else {
      result(FlutterError(code: "av_busy", message: "正在开小窗", details: nil))
      return
    }
    let newSource = applySource(args)
    if !newSource && item == nil {
      result(FlutterError(code: "av_no_source", message: "没有播放地址", details: nil))
      return
    }
    if let value = args["playing"] as? Bool {
      shouldPlay = value
    }
    sourceRect = rect(from: args["sourceRect"]) ?? sourceRect
    let player = ensurePlayer()
    player.isMuted = true
    guard let host = ensureHostView() else {
      result(FlutterError(code: "av_no_window", message: "找不到应用窗口", details: nil))
      teardown()
      return
    }
    placeHost(host, expanded: true)
    if newSource {
      failures = 0
      let position = (args["positionMillis"] as? NSNumber).map { $0.doubleValue / 1000 }
      guard loadItem(urls[0], at: isLive ? nil : position) else {
        result(FlutterError(code: "av_bad_url", message: "播放地址无效", details: nil))
        teardown()
        return
      }
    }
    guard ensureController(), let pip = pipController else {
      result(FlutterError(code: "av_controller", message: "不能创建画中画控制器", details: nil))
      teardown()
      return
    }
    if controllerMode != .call {
      pip.requiresLinearPlayback = isLive
    }
    activateAudioSession()
    startResult = result
    startRequested = false
    tookOver = false
    takeoverWhenPlaying = false
    sendLog(
      "开小窗：\(newSource ? "新开播放器" : "用预热的播放器")，直播，弹幕：\(controllerMode.rawValue)"
    )
    possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
      [weak self] _, _ in
      DispatchQueue.main.async { self?.startIfReady() }
    }
    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self, self.startResult != nil else { return }
      self.failStart(
        code: "av_timeout",
        message: "等了 \(Int(AvPlayerPipController.startTimeout)) 秒还没准备好")
    }
    startTimeoutWork = timeout
    DispatchQueue.main.asyncAfter(
      deadline: .now() + AvPlayerPipController.startTimeout, execute: timeout)
    startIfReady()
  }

  /// 系统播放器已经在播（或停在对的位置）、系统允许时开始画中画
  private func startIfReady() {
    guard startResult != nil, !startRequested, let pip = pipController,
      pip.isPictureInPicturePossible, let player = player, let item = item,
      item.status == .readyToPlay, pendingSeek == nil
    else { return }
    if shouldPlay && player.timeControlStatus != .playing {
      return
    }
    startRequested = true
    sendLog("系统播放器准备好了，开始画中画")
    pip.startPictureInPicture()
  }

  private func finishStart() {
    startTimeoutWork?.cancel()
    startTimeoutWork = nil
    possibleObservation = nil
    startResult = nil
  }

  /// 没开起来：告诉 Dart 原因（Dart 改用 mpv 小窗），拆掉播放器
  private func failStart(code: String, message: String) {
    guard let result = startResult else { return }
    let details = readinessDetails()
    sendLog("小窗没开起来：\(message) \(details)")
    finishStart()
    result(FlutterError(code: code, message: message, details: details))
    if pipController?.isPictureInPictureActive == true {
      pipController?.stopPictureInPicture()
    }
    teardown()
  }

  // MARK: - 关闭

  private func stop(reason: String) {
    if startResult != nil {
      failStart(code: "av_cancelled", message: reason)
      return
    }
    if active {
      sendLog("关闭小窗：\(reason)")
      pipController?.stopPictureInPicture()
    }
  }

  /// 页面关闭：关掉小窗和预热
  private func dispose() {
    prewarmWanted = false
    if startResult != nil {
      failStart(code: "av_cancelled", message: "页面关闭")
    }
    if active, let pip = pipController {
      suppressStopEvent = true
      pip.stopPictureInPicture()
      // 正常情况下 didStop 里会拆掉；系统没回调时兜底
      let gen = generation
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
        guard let self = self, gen == self.generation, self.active else { return }
        self.sendLog("小窗没有按时关闭，直接拆掉播放器")
        self.teardown()
      }
    } else {
      teardown()
    }
  }

  /// 拆掉播放器和画中画控制器
  private func teardown() {
    generation += 1
    if let result = startResult {
      finishStart()
      result(FlutterError(code: "av_cancelled", message: "已取消", details: nil))
    }
    stallWork?.cancel()
    stallWork = nil
    stableWork?.cancel()
    stableWork = nil
    endBackgroundTask()
    clearItemObservers()
    timeControlObservation?.invalidate()
    timeControlObservation = nil
    releaseController()
    detachOverlay()
    stopDiagnostics()
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    hostView?.playerLayer.player = nil
    hostView?.removeFromSuperview()
    hostView = nil
    player = nil
    item = nil
    pendingSeek = nil
    active = false
    restoring = false
    tookOver = false
    takeoverPending = false
    takeoverWhenPlaying = false
    recovering = false
    replacingItem = false
    failures = 0
    prewarmWanted = false
    suppressStopEvent = false
    stopping = false
    pausedInPip = false
  }

  // MARK: - 播放器

  /// 新的播放地址；没给时沿用现在的（预热的播放器）
  private func applySource(_ args: [String: Any]) -> Bool {
    guard let list = args["urls"] as? [String], !list.isEmpty else { return false }
    urls = list
    headers = args["headers"] as? [String: String] ?? [:]
    urlIndex = 0
    isLive = args["live"] as? Bool ?? true
    if let value = (args["rate"] as? NSNumber)?.floatValue, value > 0 {
      rate = value
    } else {
      rate = 1
    }
    shouldPlay = isLive || (args["playing"] as? Bool ?? true)
    return true
  }

  private func ensurePlayer() -> AVPlayer {
    if let existing = self.player { return existing }
    let player = AVPlayer()
    player.automaticallyWaitsToMinimizeStalling = true
    player.isMuted = true
    // 小窗的画面不要投到电视（投屏另有处理）
    player.allowsExternalPlayback = false
    player.preventsDisplaySleepDuringVideoPlayback = false
    // 通话式小窗不是系统播放器自己的小窗：切到后台时不要因为画面层在应用窗口里而自动暂停
    player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
      [weak self] _, _ in
      DispatchQueue.main.async { self?.timeControlChanged() }
    }
    self.player = player
    return player
  }

  private func keyWindowRootView() -> UIView? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.session.role == .windowApplication }
      .flatMap { $0.windows }
    let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
    return window?.rootViewController?.view
  }

  private func ensureHostView() -> AvPipPlayerView? {
    if let host = hostView, host.window != nil {
      if let player = player, host.playerLayer.player !== player {
        host.playerLayer.player = player
      }
      return host
    }
    guard let root = keyWindowRootView(), root.window != nil else { return nil }
    let host = hostView ?? AvPipPlayerView()
    host.isUserInteractionEnabled = false
    host.backgroundColor = .clear
    host.alpha = 0.01
    host.playerLayer.videoGravity = .resizeAspect
    host.playerLayer.player = player
    root.addSubview(host)
    hostView = host
    return host
  }

  /// expanded：铺到播放器的位置（开小窗的动画从这里开始）；否则在播放器中间占 2×2 点
  private func placeHost(_ host: UIView, expanded: Bool) {
    guard let bounds = host.superview?.bounds, bounds.width > 4, bounds.height > 4 else {
      return
    }
    let fallback = CGRect(x: bounds.midX - 1, y: bounds.midY - 1, width: 2, height: 2)
    var target = sourceRect.map { $0.intersection(bounds) } ?? fallback
    if target.isNull || target.width < 2 || target.height < 2 {
      target = fallback
    }
    if !expanded {
      target = CGRect(x: target.midX - 1, y: target.midY - 1, width: 2, height: 2)
    }
    host.frame = target
  }

  private func loadItem(_ urlString: String, at position: Double?) -> Bool {
    guard let url = URL(string: urlString) else {
      sendLog("地址无效")
      return false
    }
    let player = ensurePlayer()
    clearItemObservers()
    var options: [String: Any] = [:]
    if !headers.isEmpty {
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    let asset = AVURLAsset(url: url, options: options)
    let newItem = AVPlayerItem(asset: asset)
    if isLive {
      // 直播：多缓冲几秒，CDN 慢一下不会马上卡住
      newItem.preferredForwardBufferDuration = 6
    }
    observeItem(newItem)
    item = newItem
    if let position = position, position > 0.5 {
      pendingSeek = position
      lastPosition = position
    } else {
      pendingSeek = nil
    }
    player.replaceCurrentItem(with: newItem)
    if active {
      callContent?.frames.attach(newItem)
    }
    if pendingSeek == nil {
      if shouldPlay {
        resumePlayback()
      } else {
        player.pause()
      }
    }
    return true
  }

  private func resumePlayback() {
    guard let player = player else { return }
    if #available(iOS 16.0, *) {
      player.defaultRate = isLive ? 1 : rate
    }
    if isLive || rate == 1 {
      player.play()
    } else {
      player.rate = rate
    }
  }

  private func observeItem(_ newItem: AVPlayerItem) {
    itemObservations = [
      newItem.observe(\.status, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.itemStatusChanged() }
      },
      newItem.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.presentationSizeChanged() }
      },
    ]
    let center = NotificationCenter.default
    itemObservers = [
      center.addObserver(
        forName: .AVPlayerItemFailedToPlayToEndTime, object: newItem, queue: .main
      ) { [weak self] notification in
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        self?.playbackFailed("播放中断：\(AvPlayerPipController.describeError(error))")
      },
      center.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime, object: newItem, queue: .main
      ) { [weak self] _ in
        self?.itemEnded()
      },
      center.addObserver(
        forName: .AVPlayerItemPlaybackStalled, object: newItem, queue: .main
      ) { [weak self] _ in
        self?.sendLog("缓冲不够，卡住了")
      },
    ]
  }

  private func clearItemObservers() {
    itemObservations.forEach { $0.invalidate() }
    itemObservations.removeAll()
    itemObservers.forEach { NotificationCenter.default.removeObserver($0) }
    itemObservers.removeAll()
  }

  private func itemStatusChanged() {
    guard let item = item, let player = player, player.currentItem === item else { return }
    switch item.status {
    case .readyToPlay:
      sendLog("系统播放器已就绪（直播）")
      if let seek = pendingSeek {
        let time = CMTime(seconds: seek, preferredTimescale: 1000)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 1000)
        let gen = generation
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) {
          [weak self] _ in
          DispatchQueue.main.async {
            guard let self = self, gen == self.generation else { return }
            self.pendingSeek = nil
            if self.shouldPlay {
              self.resumePlayback()
            }
            self.startIfReady()
          }
        }
      }
      updateAutoStart()
      startIfReady()
    case .failed:
      playbackFailed("加载失败：\(AvPlayerPipController.describeError(item.error))")
    default:
      break
    }
  }

  private func presentationSizeChanged() {
    guard let size = item?.presentationSize, size.width > 0, size.height > 0 else { return }
    callContent?.viewController.preferredContentSize = size
    sendLog("画面 \(Int(size.width))x\(Int(size.height))")
  }

  private func timeControlChanged() {
    guard let player = player else { return }
    let status = player.timeControlStatus
    if active || startResult != nil {
      var text = "播放状态：\(AvPlayerPipController.describeStatus(status))"
      if status == .waitingToPlayAtSpecifiedRate, let reason = player.reasonForWaitingToPlay {
        text += "（\(reason.rawValue)）"
      }
      sendLog(text)
    }
    switch status {
    case .playing:
      stallWork?.cancel()
      stallWork = nil
      if active && !stopping {
        pausedInPip = false
      }
      if replacingItem {
        replacingItem = false
        sendLog("换了地址后恢复播放")
      }
      endBackgroundTask()
      scheduleStableReset()
      setDanmakuPlaying(true)
      if takeoverWhenPlaying && active {
        takeoverWhenPlaying = false
        takeOver(auto: false)
      }
      startIfReady()
    case .waitingToPlayAtSpecifiedRate:
      stableWork?.cancel()
      stableWork = nil
      scheduleStallCheck()
    case .paused:
      stallWork?.cancel()
      stallWork = nil
      stableWork?.cancel()
      stableWork = nil
      if active && !stopping {
        pausedInPip = true
      }
      setDanmakuPlaying(false)
      startIfReady()
    @unknown default:
      break
    }
  }

  private func scheduleStallCheck() {
    guard stallWork == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.stallWork = nil
      guard let player = self.player, player.timeControlStatus == .waitingToPlayAtSpecifiedRate
      else { return }
      let reason = player.reasonForWaitingToPlay?.rawValue ?? "未知"
      self.playbackFailed("卡住超过 \(Int(AvPlayerPipController.stallTimeout)) 秒（\(reason)）")
    }
    stallWork = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + AvPlayerPipController.stallTimeout, execute: work)
  }

  private func scheduleStableReset() {
    stableWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, self.player?.timeControlStatus == .playing else { return }
      if self.failures > 0 {
        self.sendLog("已稳定播放 30 秒，失败次数清零")
      }
      self.failures = 0
    }
    stableWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
  }

  private func itemEnded() {
    if isLive {
      playbackFailed("直播流结束")
      return
    }
  }

  // MARK: - 断流恢复：重新取地址，换掉播放项，小窗不关

  private func playbackFailed(_ reason: String) {
    guard player != nil, !recovering else { return }
    if startResult != nil {
      failStart(code: "av_failed", message: reason)
      return
    }
    failures += 1
    sendLog("出错（连续第 \(failures) 次）：\(reason)")
    if failures >= AvPlayerPipController.maxFailures {
      sendLog("连续 \(failures) 次失败，关闭系统播放器小窗")
      if active, let pip = pipController {
        prewarmWanted = false
        stopForFailure = true
        pip.stopPictureInPicture()
      } else {
        teardown()
        channel.invokeMethod("onPrewarmEnded", arguments: ["reason": reason])
      }
      return
    }
    recover(reason)
  }

  private func recover(_ reason: String) {
    recovering = true
    // 取地址、缓冲新地址期间可能没有声音，申请一段后台时间保住进程
    beginBackgroundTask()
    let gen = generation
    let resumeAt: Double? = isLive ? nil : currentSeconds()
    channel.invokeMethod("requestUrl", arguments: ["reason": reason, "live": isLive]) {
      [weak self] reply in
      guard let self = self, gen == self.generation else { return }
      self.recovering = false
      guard let map = reply as? [String: Any], let list = map["urls"] as? [String],
        !list.isEmpty
      else {
        self.sendLog("没有拿到新地址")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
          guard let self = self, gen == self.generation else { return }
          self.playbackFailed("取地址失败")
        }
        return
      }
      self.urls = list
      self.headers = map["headers"] as? [String: String] ?? self.headers
      self.urlIndex = max(0, self.failures - 1) % list.count
      self.sendLog("换新地址（第 \(self.urlIndex + 1)/\(list.count) 个）")
      self.replacingItem = true
      if !self.loadItem(list[self.urlIndex], at: resumeAt) {
        self.replacingItem = false
        self.playbackFailed("新地址无效")
      }
    }
  }

  private func beginBackgroundTask() {
    guard backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SimpleLiveAvPip") {
      [weak self] in
      self?.sendLog("后台时间用完")
      self?.endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  // MARK: - 交接：小窗开始时让 Dart 暂停 mpv，再打开系统播放器的声音

  private func takeOver(auto: Bool) {
    guard !tookOver, player != nil else { return }
    tookOver = true
    takeoverPending = true
    takeoverId += 1
    let id = takeoverId
    channel.invokeMethod("onTakeOver", arguments: ["auto": auto, "live": isLive]) {
      [weak self] reply in
      self?.finishTakeOver(id: id, reply: reply)
    }
    // Dart 没有回应时也要有声音
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      self?.finishTakeOver(id: id, reply: nil)
    }
  }

  private func finishTakeOver(id: Int, reply: Any?) {
    guard id == takeoverId, takeoverPending, let player = player else { return }
    takeoverPending = false
    let map = reply as? [String: Any]
    if map == nil {
      sendLog("mpv 暂停没有回应，直接打开系统播放器的声音")
    }
    activateAudioSession()
    player.isMuted = false
    sendLog("mpv 已暂停，声音交给系统播放器")
  }

  // MARK: - 画中画控制器

  private func ensureController() -> Bool {
    guard let player = player, let host = hostView else { return false }
    let mode = wantedMode
    if pipController != nil && (controllerMode == mode || active || startResult != nil) {
      return true
    }
    releaseController()
    host.playerLayer.player = player
    let controller: AVPictureInPictureController?
    switch mode {
    case .call:
      let content = AvPipCallContent(player: player)
      content.danmakuView.apply(style)
      if let size = item?.presentationSize, size.width > 0, size.height > 0 {
        content.viewController.preferredContentSize = size
      }
      callContent = content
      let source = AVPictureInPictureController.ContentSource(
        activeVideoCallSourceView: host, contentViewController: content.viewController)
      controller = AVPictureInPictureController(contentSource: source)
    case .overlay, .plain:
      controller = AVPictureInPictureController(playerLayer: host.playerLayer)
    }
    guard let pip = controller else {
      sendLog("不能创建画中画控制器（\(mode.rawValue)）")
      callContent = nil
      return false
    }
    pip.delegate = self
    pip.canStartPictureInPictureAutomaticallyFromInline = false
    if mode != .call {
      pip.requiresLinearPlayback = isLive
    }
    pipController = pip
    controllerMode = mode
    sendLog("画中画控制器：弹幕\(mode.rawValue)")
    return true
  }

  private func releaseController() {
    possibleObservation = nil
    pipController?.canStartPictureInPictureAutomaticallyFromInline = false
    pipController?.delegate = nil
    pipController = nil
    callContent?.danmakuView.clear()
    callContent?.frames.stop()
    callContent?.videoView.playerLayer.player = nil
    callContent = nil
  }

  // MARK: - 通话式小窗的画面

  /// 小窗开始：从解码输出取帧，盖在 AVPlayerLayer 上
  private func startCallFrames() {
    guard controllerMode == .call, let content = callContent else { return }
    content.frames.attach(item)
    content.frames.start()
    updateCallLayers()
  }

  private func stopCallFrames() {
    callContent?.frames.stop()
    updateCallLayers()
  }

  /// 通话式小窗开着且应用在后台时，把播放器从 AVPlayerLayer 上拿下来：系统在后台
  /// 停掉 AVPlayerLayer 的画面，只剩取帧输出时播放器照常为它解码。回到前台再接上
  private func updateCallLayers() {
    guard let player = player else { return }
    let detach = active && controllerMode == .call
      && UIApplication.shared.applicationState == .background
    let target: AVPlayer? = detach ? nil : player
    if let content = callContent, content.videoView.playerLayer.player !== target {
      content.videoView.playerLayer.player = target
    }
    if let host = hostView, host.playerLayer.player !== target {
      host.playerLayer.player = target
    }
  }

  // MARK: - 叠加方式：弹幕层加到系统小窗的私有窗口上（实验）

  private func attachOverlay() {
    guard controllerMode == .overlay, style.pipEnabled else { return }
    overlaySearches = 0
    findOverlayWindow()
  }

  private func findOverlayWindow() {
    guard active, controllerMode == .overlay, overlayView == nil else { return }
    if let window = AvPlayerPipController.pipWindow() {
      let view = DanmakuLayerView(frame: window.bounds)
      view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      view.pipSizing = true
      view.apply(style)
      window.addSubview(view)
      overlayView = view
      overlayWindow = window
      sendLog(
        "找到系统小窗的窗口（\(NSStringFromClass(type(of: window)))，\(Int(window.bounds.width))x\(Int(window.bounds.height))），弹幕叠加上去"
      )
      startOverlayTracking()
      return
    }
    overlaySearches += 1
    guard overlaySearches < 8 else {
      sendLog("没找到系统小窗的窗口，这次小窗没有弹幕")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.findOverlayWindow()
    }
  }

  private static func pipWindow() -> UIWindow? {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows
      where NSStringFromClass(type(of: window)).contains("PGHostedWindow") {
        return window
      }
    }
    // 小窗的窗口可能不属于任何场景：再在应用的全部窗口里找一遍
    for window in UIApplication.shared.windows
    where NSStringFromClass(type(of: window)).contains("PGHostedWindow") {
      return window
    }
    return nil
  }

  /// 小窗缩放时跟着窗口大小，并保持在最上面
  private func startOverlayTracking() {
    overlayTimer?.invalidate()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      self?.trackOverlay()
    }
    RunLoop.main.add(timer, forMode: .common)
    overlayTimer = timer
  }

  private func trackOverlay() {
    guard let view = overlayView else { return }
    guard let window = overlayWindow else {
      sendLog("系统小窗的窗口不见了，弹幕层移除")
      detachOverlay()
      return
    }
    if view.frame != window.bounds {
      view.frame = window.bounds
    }
    if window.subviews.last !== view {
      window.bringSubviewToFront(view)
    }
  }

  private func detachOverlay() {
    overlayTimer?.invalidate()
    overlayTimer = nil
    overlayView?.clear()
    overlayView?.removeFromSuperview()
    overlayView = nil
    overlayWindow = nil
  }

  private func setDanmakuPlaying(_ playing: Bool) {
    callContent?.danmakuView.setPlaying(playing)
    overlayView?.setPlaying(playing)
  }

  // MARK: - AVPictureInPictureControllerDelegate

  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    guard pictureInPictureController === pipController else { return }
    let auto = startResult == nil
    sendLog(auto ? "切到后台，系统自动开小窗" : "小窗即将开始")
    takeOver(auto: auto)
    // 先接上取帧输出，开始时就有帧
    if controllerMode == .call {
      callContent?.frames.attach(item)
    }
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    guard pictureInPictureController === pipController else { return }
    active = true
    stopping = false
    pausedInPip = false
    startedAt = CACurrentMediaTime()
    let auto = startResult == nil
    takeOver(auto: auto)
    let result = startResult
    finishStart()
    channel.invokeMethod(
      "onPipStateChanged", arguments: ["state": "started", "mode": controllerMode.rawValue])
    result?(true)
    sendLog(
      "小窗已开始（直播，弹幕：\(controllerMode.rawValue)\(auto ? "，自动" : "")）")
    callContent?.danmakuView.apply(style)
    startCallFrames()
    attachOverlay()
    startDiagnostics()
    activateAudioSession()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    guard pictureInPictureController === pipController else { return }
    let message = "系统没让开小窗：\(AvPlayerPipController.describeError(error))"
    if startResult != nil {
      failStart(code: "av_start_failed", message: message)
      return
    }
    // 切到后台自动开小窗失败：mpv 已暂停时让 Dart 恢复
    sendLog(message)
    let hadTakenOver = tookOver
    tookOver = false
    takeoverPending = false
    player?.isMuted = true
    if hadTakenOver {
      var state = playbackState()
      state["state"] = "stopped"
      state["restored"] = false
      state["tookOver"] = true
      state["prewarmed"] = player != nil
      state["failed"] = true
      channel.invokeMethod("onPipStateChanged", arguments: state)
    }
  }

  func pictureInPictureControllerWillStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    guard pictureInPictureController === pipController else { return }
    stopping = true
    _ = currentSeconds()
    sendLog("小窗即将关闭")
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    guard pictureInPictureController === pipController else { return }
    let restored = restoring
    restoring = false
    var state = playbackState()
    // 关小窗时系统会暂停播放器：只有用户在小窗里按了暂停才算暂停
    state["playing"] = !pausedInPip
    stopping = false
    pausedInPip = false
    let hadTakenOver = tookOver
    let failed = stopForFailure
    stopForFailure = false
    let notify = !suppressStopEvent
    suppressStopEvent = false
    active = false
    tookOver = false
    takeoverPending = false
    takeoverWhenPlaying = false
    detachOverlay()
    stopDiagnostics()
    stopCallFrames()
    callContent?.danmakuView.clear()
    let minutes = (CACurrentMediaTime() - startedAt) / 60
    // 直播间还开着“退到后台自动小窗”：静音接着预热，下次切到后台还能自动开
    let keep = prewarmWanted && isLive && failures == 0 && item?.status == .readyToPlay
    var kept = false
    if keep, let host = hostView {
      player?.isMuted = true
      placeHost(host, expanded: true)
      // 关小窗时系统可能暂停了播放器；在播放才能自动开小窗
      resumePlayback()
      updateAutoStart()
      kept = true
    } else {
      teardown()
    }
    state["state"] = "stopped"
    state["restored"] = restored
    state["tookOver"] = hadTakenOver
    state["prewarmed"] = kept
    state["failed"] = failed
    if notify {
      channel.invokeMethod("onPipStateChanged", arguments: state)
    }
    let minutesText = String(format: "%.1f", minutes)
    let what = restored ? "小窗已返回应用" : "小窗已关闭"
    let tail = kept ? "，继续预热" : ""
    sendLog("\(what)（开了 \(minutesText) 分钟\(tail)）")
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    guard pictureInPictureController === pipController else {
      completionHandler(false)
      return
    }
    restoring = true
    channel.invokeMethod("onRestore", arguments: nil) { [weak self] result in
      let restored = result as? Bool ?? false
      self?.restoring = restored
      completionHandler(restored)
    }
  }

  // MARK: - 状态与音频会话

  private func currentSeconds() -> Double {
    guard let player = player else { return lastPosition }
    let seconds = CMTimeGetSeconds(player.currentTime())
    if seconds.isFinite && seconds > 0 {
      lastPosition = seconds
    }
    return lastPosition
  }

  private func playbackState() -> [String: Any] {
    guard let player = player else { return ["available": false] }
    let seconds = currentSeconds()
    let currentRate = player.rate > 0 ? player.rate : rate
    return [
      "available": true,
      "active": active,
      "playing": player.timeControlStatus != .paused,
      "positionMillis": Int64(seconds * 1000),
      "rate": Double(currentRate),
    ]
  }

  private func activateAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      if session.category != .playback || session.mode != .moviePlayback {
        try session.setCategory(.playback, mode: .moviePlayback)
      }
      try session.setActive(true)
    } catch {
      sendLog("音频会话激活失败：\(AvPlayerPipController.describeError(error))")
    }
  }

  private func audioInterrupted(_ notification: Notification) {
    guard active,
      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    if type == .ended {
      let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
        .contains(.shouldResume)
      // 电话、闹钟等结束后重新激活并接着播，否则没有声音的应用会被系统挂起
      activateAudioSession()
      if isLive || shouldResume {
        resumePlayback()
      }
      sendLog("音频中断结束，已重新激活音频会话\(isLive || shouldResume ? "并继续播放" : "")")
    } else {
      sendLog("音频被其他应用中断")
    }
  }

  private func rect(from value: Any?) -> CGRect? {
    guard let map = value as? [String: Any],
      let width = (map["width"] as? NSNumber)?.doubleValue,
      let height = (map["height"] as? NSNumber)?.doubleValue, width > 0, height > 0
    else { return nil }
    let left = (map["left"] as? NSNumber)?.doubleValue ?? 0
    let top = (map["top"] as? NSNumber)?.doubleValue ?? 0
    return CGRect(x: left, y: top, width: width, height: height)
  }

  // MARK: - 诊断日志（写进应用日志，“iOS 画中画：系统播放器：…”）

  private func sendLog(_ message: String) {
    NSLog("SimpleLive AVPiP: %@", message)
    channel.invokeMethod("onDiagnostics", arguments: ["message": "系统播放器：" + message])
  }

  private static func describeError(_ error: Error?) -> String {
    guard let error = error else { return "无错误信息" }
    let failure = error as NSError
    return "\(failure.domain) \(failure.code) \(failure.localizedDescription)"
  }

  private static func describeStatus(_ status: AVPlayer.TimeControlStatus) -> String {
    switch status {
    case .paused: return "暂停"
    case .waitingToPlayAtSpecifiedRate: return "缓冲中"
    case .playing: return "播放中"
    @unknown default: return "未知"
    }
  }

  private static func describeItem(_ status: AVPlayerItem.Status) -> String {
    switch status {
    case .unknown: return "未就绪"
    case .readyToPlay: return "就绪"
    case .failed: return "失败"
    @unknown default: return "未知"
    }
  }

  private func readinessDetails() -> [String: Any] {
    var details: [String: Any] = [
      "mode": controllerMode.rawValue,
      "possible": pipController?.isPictureInPicturePossible ?? false,
      "live": isLive,
    ]
    if let item = item {
      details["item"] = AvPlayerPipController.describeItem(item.status)
      if let error = item.error {
        details["error"] = AvPlayerPipController.describeError(error)
      }
    }
    if let player = player {
      details["timeControl"] = AvPlayerPipController.describeStatus(player.timeControlStatus)
      if let reason = player.reasonForWaitingToPlay {
        details["waiting"] = reason.rawValue
      }
    }
    return details
  }

  private func startDiagnostics() {
    guard diagnosticsTimer == nil else { return }
    lastCpuTime = AvPipStats.cpuSeconds()
    lastWallTime = CACurrentMediaTime()
    let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
      self?.reportDiagnostics()
    }
    RunLoop.main.add(timer, forMode: .common)
    diagnosticsTimer = timer
  }

  private func stopDiagnostics() {
    diagnosticsTimer?.invalidate()
    diagnosticsTimer = nil
  }

  private func reportDiagnostics() {
    guard active, let player = player else {
      stopDiagnostics()
      return
    }
    let cpu = AvPipStats.cpuSeconds()
    let wall = CACurrentMediaTime()
    let cpuPercent = wall > lastWallTime ? (cpu - lastCpuTime) / (wall - lastWallTime) * 100 : 0
    lastCpuTime = cpu
    lastWallTime = wall
    let event = item?.accessLog()?.events.last
    let indicated = (event?.indicatedBitrate ?? 0) / 1_000_000
    let observed = (event?.observedBitrate ?? 0) / 1_000_000
    let size = item?.presentationSize ?? .zero
    let status = AvPlayerPipController.describeStatus(player.timeControlStatus)
    let itemStatus = item.map { AvPlayerPipController.describeItem($0.status) } ?? "无"
    let keepUp = item?.isPlaybackLikelyToKeepUp == true ? "够" : "不够"
    let background = UIApplication.shared.applicationState == .background ? "后台" : "前台"
    let shown = danmakuView?.visibleCount ?? 0
    let queued = danmakuView?.waitingCount ?? 0
    let minutes = (wall - startedAt) / 60
    let thermal = ProcessInfo.processInfo.thermalState.rawValue
    let indicatedText = String(format: "%.2f", indicated)
    let observedText = String(format: "%.2f", observed)
    let cpuText = String(format: "%.0f", cpuPercent)
    let memoryText = String(format: "%.0f", AvPipStats.memoryFootprintMB())
    let minutesText = String(format: "%.1f", minutes)
    var parts: [String] = []
    parts.append("状态（\(background)）：\(status)")
    parts.append("播放项\(itemStatus)")
    parts.append("缓冲\(keepUp)")
    parts.append("码率 \(indicatedText)/\(observedText) Mbps（标称/实测）")
    parts.append("画面 \(Int(size.width))x\(Int(size.height))")
    parts.append("CPU \(cpuText)%")
    parts.append("内存 \(memoryText)MB")
    parts.append("温度等级 \(thermal)")
    parts.append("弹幕：\(controllerMode.rawValue) \(shown) 条（排队 \(queued)）")
    if controllerMode == .call, let content = callContent {
      parts.append("取帧 \(content.frames.frames) 帧")
    }
    parts.append("已开 \(minutesText) 分钟")
    parts.append("连续失败 \(failures) 次")
    sendLog(parts.joined(separator: "，"))
  }
}
