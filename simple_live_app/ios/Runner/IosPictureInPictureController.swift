// iOS 画中画：把 media_kit 软件渲染的视频帧复制到 AVSampleBufferDisplayLayer，
// 交给系统 AVPictureInPictureController 显示。复用同一个 mpv 播放器，不重新拉流。
// 弹幕画进送给小窗的帧里；投屏（外接显示器）相关的调用也走这个通道。
// 用补丁版 libmpv 时，小窗在后台改用 vo_simplelive：解码帧不复制、不软件渲染，
// 后台 CPU 低很多（见 tools/libmpv/README.md）；原版 libmpv 时照旧走软件渲染。
// Adapted from Kazumi (GPL-3.0), Predidit/Kazumi PR #2646.
import AVKit
import Flutter
import UIKit

@available(iOS 15.0, *)
private final class PipVideoView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

@available(iOS 15.0, *)
final class IosPictureInPictureController: NSObject,
  AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate
{
  static let channelName = "simple_live/ios_pip"

  /// 小窗画面的最大尺寸：mpv 按这个尺寸软件渲染，CPU 占用比原画小很多
  static let renderSizeLimit = PipPluginRegistry.pipRenderSizeLimit

  private let channel: FlutterMethodChannel
  var copyPixelBuffer: ((Int64) -> CVPixelBuffer?)?
  var useSoftwareRendering: ((Int64, @escaping (Bool) -> Void) -> Void)?
  /// 画中画画质改了，让播放器按新的尺寸限制渲染（AppDelegate 接到 PipPluginRegistry）
  var renderSizeLimitChanged: (() -> Void)?
  var restoreRendering: ((@escaping () -> Void) -> Void)?
  private var sessionGeneration = 0
  private var videoView: PipVideoView?
  private var controller: AVPictureInPictureController?
  private var possibleObservation: NSKeyValueObservation?
  private var renderingObservation: NSKeyValueObservation?
  private var readyForDisplayObserver: NSObjectProtocol?
  private var interruptionObserver: NSObjectProtocol?
  private var hasEnqueuedFrame = false
  private var entryTimeout: DispatchWorkItem?
  private var entryResult: FlutterResult?
  private var startRequested = false
  private var restoring = false
  private var textureId: Int64?
  private var playing = false
  /// 0 表示直播（没有时长、不能拖动）
  private var duration: Double = 0
  private var timebase: CMTimebase?
  private var frameSize = CGSize.zero
  /// 小窗最多 30 帧：窗口很小，60 帧多出的复制和合成只是白白耗电
  private let sink = SampleBufferFrameSink(
    label: "simple_live.pip.frames", maxSize: IosPictureInPictureController.renderSizeLimit,
    maxFramesPerSecond: 60, canvas: DanmakuCanvas())
  private var style = DanmakuStyle()
  private var diagnosticsTimer: Timer?
  private var lastCpuTime: Double = 0
  private var lastWallTime: CFTimeInterval = 0
  private var lifecycleObservers: [NSObjectProtocol] = []

  // vo_simplelive：后台小窗直接显示 VideoToolbox 解码的画面
  private enum CustomOutputState {
    case off, enabling, on, disabling
  }

  private var customOutputState = CustomOutputState.off
  /// 这次会话里切换失败过：不再重试，继续用软件渲染
  private var customOutputFailed = false
  private var customOutputWaiters: [() -> Void] = []
  /// 当前会话的 mpv 句柄（prepare 时更新；会话结束后换回输出还要用）
  private var playerHandle: Int64?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: IosPictureInPictureController.channelName, binaryMessenger: messenger)
    super.init()
    sink.onFrameDisplayed = { [weak self] size in
      self?.frameDisplayed(size)
    }
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] notification in
      self?.audioInterrupted(notification)
    }
    // 小窗进后台改用 vo_simplelive，回到前台换回原来的输出
    lifecycleObservers = [
      UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification,
    ].map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in
        self?.updateCustomOutput()
      }
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(false)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "isSupported":
        result(AVPictureInPictureController.isPictureInPictureSupported())
      case "prepare":
        self.prepare(args, result: result)
      case "updatePlaybackState":
        self.updatePlaybackState(args)
        result(nil)
      case "enter":
        self.enter(result)
      case "dispose":
        self.finishEntry(false)
        self.controller?.stopPictureInPicture()
        self.cleanUp { result(nil) }
      case "configureOverlay":
        self.style = DanmakuStyle(args)
        self.sink.configure(self.style)
        self.applyOutputSettings(args)
        ExternalDisplayController.shared.configure(self.style)
        result(nil)
      case "danmaku":
        let messages = (args["items"] as? [Any] ?? []).compactMap(DanmakuMessage.init)
        if self.controller != nil {
          self.sink.addDanmaku(messages)
        }
        ExternalDisplayController.shared.add(messages)
        result(nil)
      case "clearDanmaku":
        self.sink.clearDanmaku()
        ExternalDisplayController.shared.clearDanmaku()
        result(nil)
      case "updateExternal":
        ExternalDisplayController.shared.update(
          textureId: (args["textureId"] as? NSNumber)?.int64Value,
          playing: args["playing"] as? Bool ?? true)
        if ExternalDisplayController.shared.isShowing {
          self.startDiagnostics()
        }
        result(nil)
      case "detachExternal":
        ExternalDisplayController.shared.detach()
        result(nil)
      case "externalStatus":
        result(ExternalDisplayController.shared.isConnected)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  func videoOutputWillChange(_ handle: Int64, completion: @escaping (Bool) -> Void) {
    channel.invokeMethod("onVideoOutputWillChange", arguments: ["handle": handle]) {
      completion($0 as? Bool ?? false)
    }
  }

  func videoOutputDidChange(
    _ handle: Int64, waitForTexture: Bool, completion: @escaping (Bool) -> Void
  ) {
    channel.invokeMethod(
      "onVideoOutputDidChange", arguments: ["handle": handle, "waitForTexture": waitForTexture]
    ) {
      completion($0 as? Bool ?? false)
    }
  }

  /// 外接显示器（屏幕镜像）连上或断开
  func notifyExternalDisplay(_ connected: Bool) {
    channel.invokeMethod("onExternalDisplayChanged", arguments: ["connected": connected])
    sendLog(connected ? "外接显示器已连接" : "外接显示器已断开")
  }

  private func prepare(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let handle = args["handle"] as? NSNumber,
      let useSoftwareRendering = useSoftwareRendering
    else {
      result(false)
      return
    }
    let generation = sessionGeneration
    playerHandle = handle.int64Value
    customOutputFailed = false
    useSoftwareRendering(handle.int64Value) { [weak self] ready in
      guard let self = self, self.sessionGeneration == generation else {
        result(false)
        return
      }
      let prepared = ready && self.prepareSource(args)
      if !prepared { self.cleanUp() }
      result(prepared)
    }
  }

  private func prepareSource(_ args: [String: Any]) -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported(),
      let id = args["textureId"] as? NSNumber,
      let rootView = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController?.view,
      rootView.window != nil
    else { return false }

    if controller == nil {
      let view = PipVideoView()
      view.isUserInteractionEnabled = false
      view.displayLayer.videoGravity = .resizeAspect
      CMTimebaseCreateWithSourceClock(
        allocator: kCFAllocatorDefault,
        sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
      view.displayLayer.controlTimebase = timebase
      rootView.addSubview(view)
      videoView = view
      let content = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
      let pip = AVPictureInPictureController(contentSource: content)
      pip.delegate = self
      // 只通过播放器上的按钮进入
      pip.canStartPictureInPictureAutomaticallyFromInline = false
      controller = pip
      sink.configure(style)
      sink.attach(view.displayLayer, timebase: timebase)
      if let timebase = timebase {
        CMTimebaseSetTime(timebase, time: .zero)
      }
    }
    textureId = id.int64Value
    updatePlaybackState(args)
    if let buffer = copyPixelBuffer?(id.int64Value) {
      onVideoFrame(buffer, textureId: id.int64Value)
    }
    return true
  }

  private func updatePlaybackState(_ args: [String: Any]) {
    let oldTextureId = textureId
    if let id = args["textureId"] as? NSNumber { textureId = id.int64Value }
    playing = args["playing"] as? Bool ?? false
    duration = max(0, (args["durationMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000
    let position = max(0, (args["positionMillis"] as? NSNumber)?.doubleValue ?? 0) / 1000
    let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 1
    if let timebase = timebase {
      // 直播没有进度：只控制走停，不要每秒把时间拨回 0。
      // 有时长时只在偏差超过 1 秒（拖动进度）时校正，频繁校正会打乱已排好的帧
      if duration > 0 {
        let current = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
        if !current.isFinite || abs(current - position) > 1 {
          CMTimebaseSetTime(timebase, time: CMTime(seconds: position, preferredTimescale: 1000))
        }
      }
      CMTimebaseSetRate(timebase, rate: playing ? rate : 0)
    }
    sink.setPlaying(playing)
    if let rect = args["sourceRect"] as? [String: NSNumber] {
      videoView?.frame = CGRect(
        x: rect["left"]?.doubleValue ?? 0,
        y: rect["top"]?.doubleValue ?? 0,
        width: rect["width"]?.doubleValue ?? 0,
        height: rect["height"]?.doubleValue ?? 0)
    }
    controller?.requiresLinearPlayback = duration <= 0
    controller?.invalidatePlaybackState()
    // 切换渲染后会换新的纹理；暂停时可能只渲染一帧，拿到新 ID 时主动取一次
    if oldTextureId != textureId, let id = textureId,
      let buffer = copyPixelBuffer?(id)
    {
      onVideoFrame(buffer, textureId: id)
    }
  }

  private func enter(_ result: @escaping FlutterResult) {
    guard let pip = controller, textureId != nil, entryResult == nil else {
      result(false)
      return
    }
    if pip.isPictureInPictureActive {
      result(true)
      return
    }
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      let failure = error as NSError
      NSLog("SimpleLive PiP: audio activation failed %@ (%ld)", failure.domain, failure.code)
      cleanUp()
      result(
        FlutterError(
          code: "pip_audio_session", message: "Audio session activation failed",
          details: ["domain": failure.domain, "code": failure.code]))
      return
    }
    entryResult = result
    startRequested = false
    possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
      [weak self] _, _ in
      DispatchQueue.main.async { self?.startIfPossible() }
    }
    if let layer = videoView?.displayLayer {
      renderingObservation = layer.observe(\.status, options: [.initial, .new]) {
        [weak self] _, _ in
        DispatchQueue.main.async { self?.startIfPossible() }
      }
      if #available(iOS 17.4, *) {
        // readyForDisplay 不支持 KVO，系统改为发通知
        readyForDisplayObserver = NotificationCenter.default.addObserver(
          forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
          object: layer, queue: .main
        ) { [weak self] _ in
          self?.startIfPossible()
        }
      }
    }
    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self, self.entryResult != nil else { return }
      let ready = self.hasDisplayableFrame
      let details = self.entryDiagnostics()
      NSLog("SimpleLive PiP: entry timeout %@", details.description)
      self.sendLog("画中画进入超时 \(details)")
      self.finishEntry(
        false,
        error: FlutterError(
          code: ready ? "pip_start_timeout" : "pip_not_ready",
          message: ready ? "Picture in Picture start timed out" : "Video frame is not ready",
          details: details))
      self.controller?.stopPictureInPicture()
      self.cleanUp()
    }
    entryTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
  }

  private var hasDisplayableFrame: Bool {
    guard hasEnqueuedFrame, frameSize.width > 0, frameSize.height > 0,
      let layer = videoView?.displayLayer, layer.status == .rendering
    else { return false }
    if #available(iOS 17.4, *) { return layer.isReadyForDisplay }
    return true
  }

  private func entryDiagnostics() -> [String: Any] {
    [
      "textureId": textureId ?? -1, "hasVideoFrame": hasEnqueuedFrame,
      "width": frameSize.width, "height": frameSize.height,
      "layerStatus": videoView?.displayLayer.status.rawValue ?? -1,
      "displayable": hasDisplayableFrame,
      "possible": controller?.isPictureInPicturePossible ?? false,
      "audioCategory": AVAudioSession.sharedInstance().category.rawValue,
    ]
  }

  private func startIfPossible() {
    // isPictureInPicturePossible 可能在新纹理出第一帧之前就变为 true，
    // 那时开始会让系统拿到 0 尺寸的画面
    guard entryResult != nil, !startRequested, hasDisplayableFrame,
      let pip = controller, pip.isPictureInPicturePossible
    else { return }
    startRequested = true
    pip.startPictureInPicture()
  }

  private func clearEntryObservations() {
    possibleObservation = nil
    renderingObservation = nil
    if let observer = readyForDisplayObserver { NotificationCenter.default.removeObserver(observer) }
    readyForDisplayObserver = nil
  }

  private func finishEntry(_ entered: Bool, error: FlutterError? = nil) {
    clearEntryObservations()
    entryTimeout?.cancel()
    entryTimeout = nil
    let result = entryResult
    entryResult = nil
    if let error = error { result?(error) } else { result?(entered) }
  }

  private func cleanUp(completion: @escaping () -> Void = {}) {
    sessionGeneration += 1
    clearEntryObservations()
    hasEnqueuedFrame = false
    controller?.delegate = nil
    controller = nil
    textureId = nil
    sink.detach()
    videoView?.displayLayer.flushAndRemoveImage()
    videoView?.removeFromSuperview()
    videoView = nil
    timebase = nil
    frameSize = .zero
    restoring = false
    startRequested = false
    // 先把 mpv 换回 media_kit 的输出（用过 vo_simplelive 时；没用过时立即继续），
    // 再等进行中的渲染切换（以及回到前台后的恢复）结束后回调
    PipCustomVideoOutput.attach(nil)
    stopCustomOutput { [weak self] in
      if let restoreRendering = self?.restoreRendering {
        restoreRendering(completion)
      } else {
        completion()
      }
    }
  }

  func onVideoFrame(_ source: CVPixelBuffer, textureId: Int64) {
    guard self.textureId == textureId, controller != nil else { return }
    sink.submit(source)
  }

  private func frameDisplayed(_ size: CGSize) {
    guard controller != nil else { return }
    frameSize = size
    hasEnqueuedFrame = true
    if entryResult != nil {
      startIfPossible()
    }
  }

  // MARK: - vo_simplelive（补丁版 libmpv，见 tools/libmpv/README.md）

  /// 只在小窗开着、应用在后台时用：前台不受后台 CPU 限制，而且应用里的画面
  /// 还要靠原来的输出更新（vo_simplelive 不渲染 Flutter 纹理）
  private var wantsCustomOutput: Bool {
    guard PipCustomVideoOutput.availability.available, !customOutputFailed,
      playerHandle != nil, controller?.isPictureInPictureActive == true
    else { return false }
    return UIApplication.shared.applicationState == .background
  }

  /// 按当前状态开关 vo_simplelive；切换进行中时等它完成后再判断一次
  private func updateCustomOutput() {
    switch customOutputState {
    case .off:
      if wantsCustomOutput {
        switchCustomOutput(enabled: true)
      } else {
        finishCustomOutputWaiters()
      }
    case .on:
      if !wantsCustomOutput {
        switchCustomOutput(enabled: false)
      }
    case .enabling, .disabling:
      break
    }
  }

  /// mpv 的属性由 Dart 端修改（停用视频轨道 → 改 hwdec 和 vo → 恢复轨道）
  private func switchCustomOutput(enabled: Bool) {
    guard let handle = playerHandle else {
      customOutputState = .off
      finishCustomOutputWaiters()
      return
    }
    customOutputState = enabled ? .enabling : .disabling
    if enabled {
      // 切换完成前就可能来第一帧
      PipCustomVideoOutput.attach(sink)
    }
    channel.invokeMethod(
      "onCustomOutput", arguments: ["handle": handle, "enabled": enabled]
    ) { [weak self] result in
      guard let self = self else { return }
      let succeeded = result as? Bool ?? false
      if enabled && succeeded {
        self.customOutputState = .on
        self.sendLog("后台小窗改用 vo_simplelive 直出")
      } else {
        self.customOutputState = .off
        PipCustomVideoOutput.attach(nil)
        if enabled {
          // 切换失败时 Dart 端已换回原来的输出；这次会话不再重试
          self.customOutputFailed = true
          self.sendLog("vo_simplelive 切换失败，继续用软件渲染")
        } else {
          self.sendLog(succeeded ? "小窗换回软件渲染" : "换回软件渲染时出错")
        }
      }
      self.updateCustomOutput()
    }
  }

  /// 等 vo_simplelive 换回原来的输出后再继续；没在用时立即继续
  private func stopCustomOutput(then completion: @escaping () -> Void) {
    guard customOutputState != .off else {
      completion()
      return
    }
    customOutputWaiters.append(completion)
    updateCustomOutput()
  }

  private func finishCustomOutputWaiters() {
    guard !customOutputWaiters.isEmpty else { return }
    let waiters = customOutputWaiters
    customOutputWaiters.removeAll()
    waiters.forEach { $0() }
  }

  private func audioInterrupted(_ notification: Notification) {
    guard controller?.isPictureInPictureActive == true,
      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    if type == .ended {
      // 电话、闹钟等结束后重新激活，否则没有声音的应用会被系统挂起
      try? AVAudioSession.sharedInstance().setActive(true)
      sendLog("音频中断结束，已重新激活音频会话")
    } else {
      sendLog("音频被其他应用中断")
    }
  }

  // MARK: - 诊断日志（写进应用日志，方便排查被系统结束的原因）

  private func sendLog(_ message: String) {
    channel.invokeMethod("onDiagnostics", arguments: ["message": message])
  }

  /// 画中画帧率（30 / 60）和画质（540p / 720p / 1080p，按 16:9 取最大尺寸），在设置里调整
  private func applyOutputSettings(_ args: [String: Any]) {
    let framesPerSecond = ((args["pipFrameRate"] as? NSNumber)?.intValue ?? 60) >= 60 ? 60 : 30
    var height = (args["pipQuality"] as? NSNumber)?.intValue ?? 540
    if ![540, 720, 1080].contains(height) {
      height = 540
    }
    let size = CGSize(width: CGFloat(height) * 16 / 9, height: CGFloat(height))
    sink.setOutput(maxSize: size, framesPerSecond: framesPerSecond)
    if PipPluginRegistry.pipRenderSizeLimit != size {
      PipPluginRegistry.pipRenderSizeLimit = size
      renderSizeLimitChanged?()
    }
  }

  private func startDiagnostics() {
    guard diagnosticsTimer == nil else { return }
    lastCpuTime = cpuSeconds()
    lastWallTime = CACurrentMediaTime()
    let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
      self?.reportDiagnostics()
    }
    RunLoop.main.add(timer, forMode: .common)
    diagnosticsTimer = timer
  }

  private func reportDiagnostics() {
    let pipActive = controller?.isPictureInPictureActive == true
    let external = ExternalDisplayController.shared.isShowing
    guard pipActive || external else {
      diagnosticsTimer?.invalidate()
      diagnosticsTimer = nil
      return
    }
    let cpu = cpuSeconds()
    let wall = CACurrentMediaTime()
    let cpuPercent = wall > lastWallTime ? (cpu - lastCpuTime) / (wall - lastWallTime) * 100 : 0
    lastCpuTime = cpu
    lastWallTime = wall
    let memory = memoryFootprintMB()
    let thermal = ProcessInfo.processInfo.thermalState.rawValue
    let background = UIApplication.shared.applicationState == .background
    let output = customOutputState == .on ? "vo_simplelive" : "软件渲染"
    sink.snapshot { [weak self] stats in
      let summary = String(
        format: "状态：%@%@，内存 %.0fMB，CPU %.0f%%，温度等级 %ld，小窗帧 进%ld/出%ld/丢%ld，%ldx%ld，%@",
        pipActive ? "画中画" : "", external ? " 投屏" : "", memory, cpuPercent, thermal,
        stats.framesIn, stats.framesOut, stats.dropped, Int(stats.size.width),
        Int(stats.size.height), output)
      self?.sendLog(summary + (background ? "（后台）" : ""))
    }
  }

  private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    return user + system
  }

  private func memoryFootprintMB() -> Double {
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

  // MARK: - AVPictureInPictureControllerDelegate

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    guard controller === pictureInPictureController else { return }
    channel.invokeMethod("onModeChanged", arguments: ["isInPipMode": true])
    finishEntry(true)
    sendLog("画中画已开始（vo_simplelive：\(PipCustomVideoOutput.availability.reason)）")
    startDiagnostics()
    updateCustomOutput()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    guard controller === pictureInPictureController else { return }
    let failure = error as NSError
    var details = entryDiagnostics()
    details["domain"] = failure.domain
    details["code"] = failure.code
    NSLog("SimpleLive PiP: start failed %@", details.description)
    sendLog("画中画启动失败 \(details)")
    finishEntry(
      false,
      error: FlutterError(
        code: "pip_start_failed",
        message: "\(failure.domain) (\(failure.code))", details: details))
    cleanUp()
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    guard controller === pictureInPictureController else { return }
    let restored = restoring
    finishEntry(false)
    cleanUp()
    channel.invokeMethod("onModeChanged", arguments: ["isInPipMode": false, "restored": restored])
    sendLog(restored ? "画中画已返回应用" : "画中画已关闭")
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    restoring = true
    channel.invokeMethod("onRestore", arguments: nil) { [weak self] result in
      let restored = result as? Bool ?? false
      self?.restoring = restored
      completionHandler(restored)
    }
  }

  // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool
  ) {
    channel.invokeMethod("onAction", arguments: ["action": playing ? "play" : "pause"])
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    // 直播：时长无穷，系统按直播显示、没有进度条。起点必须是 0：
    // 负无穷起点会让 iOS 16.1+ 的小窗不停创建线程、CPU 飙高，后台时被系统结束
    if duration <= 0 {
      return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 1000))
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    !playing
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void
  ) {
    guard duration > 0 else {
      completionHandler()
      return
    }
    let current = timebase.map { CMTimeGetSeconds(CMTimebaseGetTime($0)) } ?? 0
    let target = max(0, min(duration, current + CMTimeGetSeconds(skipInterval)))
    channel.invokeMethod(
      "onAction", arguments: ["action": "seek", "positionMillis": Int64(target * 1000)]
    ) { _ in
      completionHandler()
    }
  }
}
