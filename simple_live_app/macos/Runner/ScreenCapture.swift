// 录屏和复制截图：通道 simple_live/capture（和 Windows、安卓、iOS 同一套）。
// Dart -> 原生：recordStart、recordStop、recordActive、copyImage、copyFiles、copyGif。
// 原生 -> Dart：onRecordStopped（自动停下时：窗口改大小、换到缩放不同的显示器、最小化、关窗、系统停止录制、
// 到了时长上限）。Dart 没接这个回调时，下一次 recordStop 返回这次的结果。
// 录屏用 ScreenCaptureKit（macOS 12.3 起）只录 App 自己的窗口，再裁出播放器区域，
// AVAssetWriter 写 H.264 MP4；macOS 13 起可以加上 App 自己的声音（AAC）。文件存到 Dart 给的路径（savedToAlbum 总是 false）。
// 没有“屏幕录制”权限时报 permission_denied。
// 只在主线程使用（写文件在 MacScreenRecorder 自己的队列）
import AVFoundation
import Cocoa
import CoreImage
import FlutterMacOS
import ScreenCaptureKit

final class ScreenCaptureChannel: NSObject {
  static let channelName = "simple_live/capture"
  /// 安全上限：时长由 Dart 管，原生只在 maxSeconds 之后再多等 30 秒；没设时长时 4 小时
  private static let capExtraSeconds: TimeInterval = 30
  private static let capDefaultSeconds: TimeInterval = 4 * 3600
  /// SCStreamError.userDeclined：没有屏幕录制权限
  private static let userDeclinedCode = -3801

  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  /// MacScreenRecorder：这个类型 macOS 12.3 起才有，存成 AnyObject
  private var recorder: AnyObject?
  private var starting = false
  private var stopping = false
  private var stopWaiters: [FlutterResult] = []
  /// 自动停下、Dart 没接 onRecordStopped 时留着，下一次 recordStop 返回
  private var lastResult: [String: Any]?
  private var observers: [NSObjectProtocol] = []
  private var capTimer: Timer?

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    channel = FlutterMethodChannel(
      name: ScreenCaptureChannel.channelName, binaryMessenger: messenger)
    self.window = window
    super.init()
    // 窗口改大小、换到缩放不同的显示器、最小化、关窗：播放器区域对不上了，停下
    let stops: [(Notification.Name, String)] = [
      (NSWindow.didResizeNotification, "resize"),
      (NSWindow.didChangeBackingPropertiesNotification, "resize"),
      (NSWindow.didMiniaturizeNotification, "background"),
      (NSWindow.willCloseNotification, "closed"),
    ]
    observers = stops.map { stop in
      NotificationCenter.default.addObserver(forName: stop.0, object: window, queue: .main) {
        [weak self] _ in
        self?.finish(reason: stop.1)
      }
    }
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
    case "recordStart":
      start(args, result: result)
    case "recordStop":
      stop(result)
    case "recordActive":
      result(recorder != nil && !stopping)
    case "copyImage":
      copyImage(args, result: result)
    case "copyFiles":
      copyFiles(args, result: result)
    case "copyGif":
      copyGif(args, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func int(_ args: [String: Any], _ key: String, _ fallback: Int) -> Int {
    (args[key] as? NSNumber)?.intValue ?? fallback
  }

  // MARK: - 开始

  private func start(_ args: [String: Any], result: @escaping FlutterResult) {
    guard #available(macOS 12.3, *) else {
      result(
        FlutterError(
          code: "unsupported", message: "Screen recording needs macOS 12.3 or later", details: nil))
      return
    }
    guard recorder == nil, !starting, !stopping else {
      result(FlutterError(code: "busy", message: "Already recording", details: nil))
      return
    }
    let width = Self.int(args, "width", 0)
    let height = Self.int(args, "height", 0)
    guard let path = args["path"] as? String, !path.isEmpty, width >= 2, height >= 2 else {
      result(FlutterError(code: "bad_args", message: "Missing path or empty area", details: nil))
      return
    }
    guard let window = window, let content = window.contentView,
      window.frame.width > 0, window.frame.height > 0
    else {
      result(FlutterError(code: "no_window", message: "App window is not ready", details: nil))
      return
    }
    // Dart 给的是 Flutter 画面里的物理像素：换成整个窗口（含标题栏）里的比例（0...1，左上角原点）。
    // 录窗口时 ScreenCaptureKit 不看 sourceRect，只能录整个窗口再自己裁
    let scale = window.backingScaleFactor
    let frame = window.frame.size
    let contentInWindow = content.convert(content.bounds, to: nil)
    let left = contentInWindow.minX
    let top = frame.height - contentInWindow.maxY
    let normalized = CGRect(
      x: (left + CGFloat(Self.int(args, "x", 0)) / scale) / frame.width,
      y: (top + CGFloat(Self.int(args, "y", 0)) / scale) / frame.height,
      width: CGFloat(width) / scale / frame.width,
      height: CGFloat(height) / scale / frame.height)
    let fps = min(max(Self.int(args, "fps", 30), 1), 60)
    let audio = args["audio"] as? Bool ?? false
    let maxSeconds = Self.int(args, "maxSeconds", 0)
    let cap =
      maxSeconds > 0
      ? TimeInterval(maxSeconds) + Self.capExtraSeconds : Self.capDefaultSeconds
    let pixelSize = CGSize(width: frame.width * scale, height: frame.height * scale)
    let url = URL(fileURLWithPath: path)
    lastResult = nil
    starting = true
    Self.findWindow(CGWindowID(window.windowNumber)) { [weak self] scWindow, permissionDenied in
      guard let self = self else { return }
      guard let scWindow = scWindow else {
        self.starting = false
        result(
          permissionDenied
            ? Self.permissionError()
            : FlutterError(code: "no_window", message: "App window is not capturable", details: nil))
        return
      }
      let capture = MacScreenRecorder(
        url: url, window: scWindow, pixelSize: pixelSize, normalizedRect: normalized, fps: fps,
        audio: audio)
      capture.onStopped = { [weak self] in
        DispatchQueue.main.async { self?.finish(reason: "system") }
      }
      capture.start { error in
        DispatchQueue.main.async {
          self.starting = false
          if let error = error {
            if (error as NSError).code == Self.userDeclinedCode {
              _ = CGRequestScreenCaptureAccess()
              result(Self.permissionError())
            } else {
              result(
                FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
            }
            return
          }
          self.recorder = capture
          self.capTimer?.invalidate()
          self.capTimer = Timer.scheduledTimer(withTimeInterval: cap, repeats: false) {
            [weak self] _ in
            self?.finish(reason: "limit")
          }
          result(true)
        }
      }
    }
  }

  private static func permissionError() -> FlutterError {
    FlutterError(
      code: "permission_denied",
      message:
        "Allow Simple Live in System Settings > Privacy & Security > Screen Recording, then reopen the app",
      details: nil)
  }

  /// 找到 App 自己的窗口。macOS 14.4 起先用“本进程的内容”（自己的窗口）；
  /// 找不到时走普通的列表，这要“屏幕录制”权限（没有时请求一次，系统设置里会出现 Simple Live）。主线程回调
  @available(macOS 12.3, *)
  private static func findWindow(
    _ id: CGWindowID, completion: @escaping (SCWindow?, Bool) -> Void
  ) {
    let done: (SCWindow?, Bool) -> Void = { window, denied in
      DispatchQueue.main.async { completion(window, denied) }
    }
    let searchAll = {
      DispatchQueue.main.async {
        guard CGPreflightScreenCaptureAccess() else {
          _ = CGRequestScreenCaptureAccess()
          done(nil, true)
          return
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) {
          content, error in
          if let error = error {
            NSLog("SimpleLive capture: shareable content failed %@", error.localizedDescription)
          }
          done(content?.windows.first(where: { $0.windowID == id }), content == nil)
        }
      }
    }
    if #available(macOS 14.4, *) {
      SCShareableContent.getCurrentProcessShareableContent { content, _ in
        if let match = content?.windows.first(where: { $0.windowID == id }) {
          done(match, false)
        } else {
          searchAll()
        }
      }
    } else {
      searchAll()
    }
  }

  // MARK: - 停止

  private func stop(_ result: @escaping FlutterResult) {
    guard recorder != nil else {
      if let last = lastResult {
        lastResult = nil
        result(last)
      } else {
        result(FlutterError(code: "not_recording", message: "Not recording", details: nil))
      }
      return
    }
    stopWaiters.append(result)
    finish(reason: "user")
  }

  /// 停下、写完文件，然后回复 recordStop 或通知 Dart
  private func finish(reason: String) {
    guard #available(macOS 12.3, *), let capture = recorder as? MacScreenRecorder, !stopping else {
      return
    }
    stopping = true
    capTimer?.invalidate()
    capTimer = nil
    capture.stop { outcome in
      DispatchQueue.main.async {
        self.recorder = nil
        self.stopping = false
        switch outcome {
        case .failure(let message):
          self.deliver(reason: reason, map: nil, error: message)
        case .success(let url, let durationMs, let bytes, let audio):
          self.deliver(
            reason: reason,
            map: [
              "path": url.path,
              "durationMs": durationMs,
              "bytes": bytes,
              "savedToAlbum": false,
              "audio": audio,
            ], error: nil)
        }
      }
    }
  }

  private func deliver(reason: String, map: [String: Any]?, error: String?) {
    let waiters = stopWaiters
    stopWaiters.removeAll()
    if !waiters.isEmpty {
      for waiter in waiters {
        if let map = map {
          waiter(map)
        } else {
          waiter(FlutterError(code: "stop_failed", message: error, details: nil))
        }
      }
      return
    }
    lastResult = map
    var args: [String: Any] = map ?? [:]
    args["reason"] = reason
    if let error = error { args["error"] = error }
    channel.invokeMethod("onRecordStopped", arguments: args) { [weak self] response in
      if response is FlutterError { return }
      if let object = response as? NSObject, object === FlutterMethodNotImplemented { return }
      // Dart 接了：不再留给 recordStop
      self?.lastResult = nil
    }
  }

  // MARK: - 剪贴板

  private func copyImage(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let data = (args["png"] as? FlutterStandardTypedData)?.data, !data.isEmpty else {
      result(FlutterError(code: "bad_args", message: "Missing image", details: nil))
      return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    var copied = pasteboard.setData(data, forType: .png)
    // 有些应用只认 TIFF
    if let tiff = NSImage(data: data)?.tiffRepresentation {
      copied = pasteboard.setData(tiff, forType: .tiff) || copied
    }
    result(copied)
  }

  private func copyFiles(_ args: [String: Any], result: @escaping FlutterResult) {
    let paths = (args["paths"] as? [Any])?.compactMap { $0 as? String } ?? []
    let urls = paths.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) as NSURL }
    guard !urls.isEmpty else {
      result(false)
      return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    result(pasteboard.writeObjects(urls))
  }

  /// GIF：原样的数据（粘贴出动图）和文件地址（访达里粘贴出文件）放在同一项里，
  /// 分成两项时有的应用会粘贴出两份。没有文件时返回 false，不碰剪贴板
  private func copyGif(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String, !path.isEmpty else {
      result(false)
      return
    }
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else {
      result(false)
      return
    }
    let item = NSPasteboardItem()
    item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
    item.setString(url.absoluteString, forType: .fileURL)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    result(pasteboard.writeObjects([item]))
  }
}

private struct MacCaptureError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// 一次录制：ScreenCaptureKit 的窗口画面裁出播放器区域，和 App 声音一起写进 MP4。
/// start、stop 在主线程调用；写文件的状态只在 queue 上用（也是 ScreenCaptureKit 的回调队列）
@available(macOS 12.3, *)
final class MacScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
  enum Outcome {
    case success(url: URL, durationMs: Int, bytes: Int, audio: Bool)
    case failure(String)
  }

  /// 系统停掉了录制（出错、权限被收回等）。在 queue 上回调
  var onStopped: (() -> Void)?

  private let queue = DispatchQueue(label: "simple_live.capture.stream")
  private let url: URL
  private let window: SCWindow
  private let pixelSize: CGSize
  private let normalizedRect: CGRect
  private let fps: Int
  private let wantAudio: Bool
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
  private var activeStream: SCStream?
  private var capturesAudio = false

  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var sourceSize: CGSize = .zero
  private var cropRect: CGRect = .zero
  private var outputSize: CGSize = .zero
  private var firstTime = CMTime.invalid
  private var lastTime = CMTime.invalid
  private var audioWritten = false
  private var closed = false
  private var failed = false

  init(
    url: URL, window: SCWindow, pixelSize: CGSize, normalizedRect: CGRect, fps: Int, audio: Bool
  ) {
    self.url = url
    self.window = window
    self.pixelSize = pixelSize
    self.normalizedRect = normalizedRect
    self.fps = fps
    self.wantAudio = audio
    super.init()
  }

  func start(_ completion: @escaping (Error?) -> Void) {
    let config = SCStreamConfiguration()
    // 输出就是窗口的像素大小：不缩放
    config.width = max(2, Int(pixelSize.width))
    config.height = max(2, Int(pixelSize.height))
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    config.showsCursor = false
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.queueDepth = 5
    if #available(macOS 14.0, *) {
      config.ignoreShadowsSingleWindow = true
    }
    var audio = false
    if wantAudio, #available(macOS 13.0, *) {
      config.capturesAudio = true
      config.excludesCurrentProcessAudio = false
      config.sampleRate = 48_000
      config.channelCount = 2
      audio = true
    }
    capturesAudio = audio
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    do {
      try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
      if audio, #available(macOS 13.0, *) {
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
      }
    } catch {
      completion(error)
      return
    }
    activeStream = stream
    stream.startCapture { [weak self] error in
      if error != nil {
        self?.activeStream = nil
        self?.discard()
      }
      completion(error)
    }
  }

  /// 停下并写完文件。在 queue 上回调
  func stop(_ completion: @escaping (Outcome) -> Void) {
    guard let stream = activeStream else {
      finishWriting(completion)
      return
    }
    activeStream = nil
    stream.stopCapture { [weak self] _ in
      guard let self = self else {
        completion(.failure("Recording was released"))
        return
      }
      self.finishWriting(completion)
    }
  }

  // MARK: - SCStreamOutput、SCStreamDelegate

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard !closed, !failed, CMSampleBufferIsValid(sampleBuffer) else { return }
    if type == .screen {
      appendVideo(sampleBuffer)
      return
    }
    if #available(macOS 13.0, *), type == .audio, capturesAudio {
      appendAudio(sampleBuffer)
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    NSLog("SimpleLive capture: stream stopped %@", error.localizedDescription)
    onStopped?()
  }

  // MARK: - 写文件（queue）

  private func appendVideo(_ sample: CMSampleBuffer) {
    // 只要完整的帧（画面没变时 ScreenCaptureKit 会送不带图像的 idle 帧）
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let statusRaw = attachments.first?[.status] as? Int,
      let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
      let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
    else { return }
    let time = CMSampleBufferGetPresentationTimeStamp(sample)
    let size = CGSize(
      width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    if writer == nil {
      guard setUp(size) else { return }
    } else if size != sourceSize {
      // 窗口大小变了：通道那边会收到窗口通知并停下
      return
    }
    guard let adaptor = adaptor, let input = videoInput, input.isReadyForMoreMediaData,
      let pool = adaptor.pixelBufferPool
    else { return }
    var output: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
      let target = output
    else { return }
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    let origin = image.extent.origin
    let source = cropRect.offsetBy(dx: origin.x, dy: origin.y)
    let cropped =
      image
      .cropped(to: source)
      .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
      .transformed(
        by: CGAffineTransform(
          scaleX: outputSize.width / cropRect.width, y: outputSize.height / cropRect.height))
    context.render(
      cropped, to: target, bounds: CGRect(origin: .zero, size: outputSize), colorSpace: colorSpace)
    if !firstTime.isValid {
      writer?.startSession(atSourceTime: time)
      firstTime = time
    }
    if adaptor.append(target, withPresentationTime: time) {
      lastTime = time
    } else if writer?.status == .failed {
      NSLog(
        "SimpleLive capture: video append failed %@", writer?.error?.localizedDescription ?? "")
      failed = true
    }
  }

  private func appendAudio(_ sample: CMSampleBuffer) {
    guard let input = audioInput, firstTime.isValid, input.isReadyForMoreMediaData else { return }
    // 第一帧画面之前的声音不要
    guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), firstTime) >= 0 else {
      return
    }
    if input.append(sample) { audioWritten = true }
  }

  /// 第一帧画面来了：定裁剪区域和输出尺寸，开始写文件
  private func setUp(_ size: CGSize) -> Bool {
    sourceSize = size
    // 播放器区域（比例，左上角原点）换成 Core Image 坐标（像素，左下角原点）
    let width = normalizedRect.width * size.width
    let height = normalizedRect.height * size.height
    let rect = CGRect(
      x: normalizedRect.minX * size.width,
      y: size.height - normalizedRect.minY * size.height - height,
      width: width, height: height
    ).integral.intersection(CGRect(origin: .zero, size: size))
    guard !rect.isNull, rect.width >= 2, rect.height >= 2 else {
      failed = true
      return false
    }
    cropRect = rect
    // H.264 要偶数宽高；太大时缩到 4096 以内
    let shrink = min(1, 4096 / max(rect.width, rect.height))
    let outWidth = max(2, Int(rect.width * shrink) / 2 * 2)
    let outHeight = max(2, Int(rect.height * shrink) / 2 * 2)
    outputSize = CGSize(width: outWidth, height: outHeight)
    do {
      let manager = FileManager.default
      try manager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? manager.removeItem(at: url)
      let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
      let bitRate = min(max(Int(Double(outWidth * outHeight * fps) * 0.15), 2_000_000), 20_000_000)
      let video = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.h264,
          AVVideoWidthKey: outWidth,
          AVVideoHeightKey: outHeight,
          AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
          ],
          AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
          ],
        ])
      video.expectsMediaDataInRealTime = true
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: video,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: outWidth,
          kCVPixelBufferHeightKey as String: outHeight,
          kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
      guard writer.canAdd(video) else { throw MacCaptureError(message: "Cannot add video track") }
      writer.add(video)
      if capturesAudio {
        let audio = AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 128_000,
          ])
        audio.expectsMediaDataInRealTime = true
        if writer.canAdd(audio) {
          writer.add(audio)
          audioInput = audio
        }
      }
      guard writer.startWriting() else {
        throw writer.error ?? MacCaptureError(message: "Cannot start writing")
      }
      self.writer = writer
      self.videoInput = video
      self.adaptor = adaptor
      return true
    } catch {
      NSLog("SimpleLive capture: writer setup failed %@", error.localizedDescription)
      failed = true
      return false
    }
  }

  private func finishWriting(_ completion: @escaping (Outcome) -> Void) {
    queue.async {
      self.closed = true
      guard let writer = self.writer, writer.status == .writing, self.firstTime.isValid,
        self.lastTime.isValid
      else {
        self.writer?.cancelWriting()
        try? FileManager.default.removeItem(at: self.url)
        completion(.failure(self.failed ? "Recording failed" : "No video was recorded"))
        return
      }
      self.videoInput?.markAsFinished()
      self.audioInput?.markAsFinished()
      let frame = CMTime(value: 1, timescale: CMTimeScale(self.fps))
      writer.endSession(atSourceTime: CMTimeAdd(self.lastTime, frame))
      let seconds =
        CMTimeGetSeconds(CMTimeSubtract(self.lastTime, self.firstTime)) + 1 / Double(self.fps)
      let durationMs = Int(seconds * 1000)
      let audio = self.audioWritten
      let url = self.url
      writer.finishWriting {
        if writer.status == .completed {
          let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
          let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
          completion(.success(url: url, durationMs: durationMs, bytes: bytes, audio: audio))
        } else {
          try? FileManager.default.removeItem(at: url)
          completion(.failure(writer.error?.localizedDescription ?? "Writing failed"))
        }
      }
    }
  }

  private func discard() {
    queue.async {
      self.closed = true
      self.writer?.cancelWriting()
      try? FileManager.default.removeItem(at: self.url)
    }
  }
}
