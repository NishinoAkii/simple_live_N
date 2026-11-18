// 录屏和复制截图：通道 simple_live/capture（和 Windows、安卓同一套）。
// Dart -> 原生：recordStart、recordStop、recordActive、copyImage、copyGif、copyFiles（iOS 不支持，返回 false）。
// 原生 -> Dart：onRecordStopped（自动停下时：切到后台、转屏、窗口大小变了、系统停止录制、到了时长上限）。
// Dart 没接这个回调时，下一次 recordStop 返回这次的结果。
// 录屏用 ReplayKit 的 App 内录制（startCapture，系统先问一次），只取播放器区域，
// AVAssetWriter 写 H.264 MP4（要录声音时加 App 自己的声音，AAC），停下后存进相册的“SimpleLive”相簿。
// 不碰音频会话和画中画；切到后台（包括开小窗）时停下。
// 只在主线程使用（写文件在 ScreenCaptureWriter 自己的队列）
import AVFoundation
import CoreImage
import Flutter
import Photos
import ReplayKit
import UIKit
import UniformTypeIdentifiers

final class ScreenCaptureController: NSObject, RPScreenRecorderDelegate {
  static let channelName = "simple_live/capture"
  private static let albumName = "Simple Live N"
  /// 安全上限：时长由 Dart 管，原生只在 maxSeconds 之后再多等 30 秒；没设时长时 4 小时
  private static let capExtraSeconds: TimeInterval = 30
  private static let capDefaultSeconds: TimeInterval = 4 * 3600

  private let channel: FlutterMethodChannel
  private var writer: ScreenCaptureWriter?
  private var starting = false
  private var stopping = false
  private var stopWaiters: [FlutterResult] = []
  /// 自动停下、Dart 没接 onRecordStopped 时留着，下一次 recordStop 返回
  private var lastResult: [String: Any]?
  private var observers: [NSObjectProtocol] = []
  private var watchTimer: Timer?
  private var capTimer: Timer?
  private var startOrientation: UIInterfaceOrientation = .unknown
  private var startSize: CGSize = .zero

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: ScreenCaptureController.channelName, binaryMessenger: messenger)
    super.init()
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        self?.finish(reason: "background")
      },
      // 只看主界面的场景（外接显示器的场景进后台不算）
      center.addObserver(
        forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let scene = notification.object as? UIWindowScene,
          scene.session.role == .windowApplication
        else { return }
        self?.finish(reason: "background")
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
    case "recordStart":
      start(args, result: result)
    case "recordStop":
      stop(result)
    case "recordActive":
      result(writer != nil && !stopping)
    case "copyImage":
      copyImage(args, result: result)
    case "copyGif":
      copyGif(args, result: result)
    case "copyFiles":
      result(false)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func int(_ args: [String: Any], _ key: String, _ fallback: Int) -> Int {
    (args[key] as? NSNumber)?.intValue ?? fallback
  }

  // MARK: - 开始

  private func start(_ args: [String: Any], result: @escaping FlutterResult) {
    guard writer == nil, !starting, !stopping else {
      result(FlutterError(code: "busy", message: "Already recording", details: nil))
      return
    }
    let width = Self.int(args, "width", 0)
    let height = Self.int(args, "height", 0)
    guard let path = args["path"] as? String, !path.isEmpty, width >= 2, height >= 2 else {
      result(FlutterError(code: "bad_args", message: "Missing path or empty area", details: nil))
      return
    }
    let recorder = RPScreenRecorder.shared()
    guard recorder.isAvailable, !recorder.isRecording else {
      result(
        FlutterError(code: "unavailable", message: "Screen recording is unavailable", details: nil))
      return
    }
    guard let window = Self.mainWindow(), window.bounds.width > 0, window.bounds.height > 0 else {
      result(FlutterError(code: "no_window", message: "App window is not ready", details: nil))
      return
    }
    // Dart 给的是 Flutter 画面里的物理像素（Flutter 的像素比 = 屏幕 scale），换成窗口里的比例（0...1，左上角原点）。
    // ReplayKit 给的分辨率不一定等于屏幕像素，按比例换算就不用管
    let scale = window.screen.scale
    let size = window.bounds.size
    let normalized = CGRect(
      x: CGFloat(Self.int(args, "x", 0)) / scale / size.width,
      y: CGFloat(Self.int(args, "y", 0)) / scale / size.height,
      width: CGFloat(width) / scale / size.width,
      height: CGFloat(height) / scale / size.height)
    let fps = min(max(Self.int(args, "fps", 30), 1), 60)
    let audio = args["audio"] as? Bool ?? false
    let maxSeconds = Self.int(args, "maxSeconds", 0)
    let cap =
      maxSeconds > 0
      ? TimeInterval(maxSeconds) + Self.capExtraSeconds : Self.capDefaultSeconds
    let orientation = window.windowScene?.interfaceOrientation ?? .portrait
    let capture = ScreenCaptureWriter(
      url: URL(fileURLWithPath: path),
      normalizedRect: normalized,
      windowIsLandscape: size.width > size.height,
      fallbackOrientation: ScreenCaptureWriter.bufferOrientation(for: orientation),
      fps: fps,
      audio: audio)
    capture.onSourceChanged = { [weak self] in
      DispatchQueue.main.async { self?.finish(reason: "rotation") }
    }
    lastResult = nil
    starting = true
    recorder.delegate = self
    recorder.isMicrophoneEnabled = false
    recorder.startCapture(
      handler: { [weak capture] buffer, type, error in
        guard error == nil else { return }
        capture?.append(buffer, type: type)
      },
      completionHandler: { [weak self] error in
        DispatchQueue.main.async {
          guard let self = self else { return }
          self.starting = false
          if let error = error as NSError? {
            capture.discard()
            if error.domain == RPRecordingErrorDomain
              && error.code == RPRecordingErrorCode.userDeclined.rawValue
            {
              // 用户在系统提示里点了不允许
              result(false)
            } else {
              result(
                FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
            }
            return
          }
          self.writer = capture
          self.startOrientation = orientation
          self.startSize = size
          self.startTimers(cap: cap)
          result(true)
          // 等系统提示时切到了后台：马上停
          if UIApplication.shared.applicationState == .background {
            self.finish(reason: "background")
          }
        }
      })
  }

  private func startTimers(cap: TimeInterval) {
    watchTimer?.invalidate()
    watchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.checkWindow()
    }
    capTimer?.invalidate()
    capTimer = Timer.scheduledTimer(withTimeInterval: cap, repeats: false) { [weak self] _ in
      self?.finish(reason: "limit")
    }
  }

  /// 转屏、分屏改大小以后播放器区域就对不上了：停下
  private func checkWindow() {
    guard writer != nil, !stopping, let window = Self.mainWindow() else { return }
    if let orientation = window.windowScene?.interfaceOrientation, orientation != startOrientation {
      finish(reason: "rotation")
    } else if window.bounds.size != startSize {
      finish(reason: "resize")
    }
  }

  // MARK: - RPScreenRecorderDelegate

  /// 系统中途停掉了录制（比如出错）
  func screenRecorder(
    _ screenRecorder: RPScreenRecorder, didStopRecordingWith previewViewController: RPPreviewViewController?,
    error: Error?
  ) {
    DispatchQueue.main.async { self.finish(reason: "system") }
  }

  // MARK: - 停止

  private func stop(_ result: @escaping FlutterResult) {
    guard writer != nil else {
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

  /// 停下、写完文件、存进相册，然后回复 recordStop 或通知 Dart
  private func finish(reason: String) {
    guard let capture = writer, !stopping else { return }
    stopping = true
    watchTimer?.invalidate()
    watchTimer = nil
    capTimer?.invalidate()
    capTimer = nil
    // 切到后台时向系统要一点时间把文件写完
    var task = UIBackgroundTaskIdentifier.invalid
    let endTask = {
      if task != .invalid {
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
      }
    }
    task = UIApplication.shared.beginBackgroundTask(withName: "screen-capture") { endTask() }
    RPScreenRecorder.shared().stopCapture { [weak self] _ in
      capture.finish { outcome in
        DispatchQueue.main.async {
          guard let self = self else {
            endTask()
            return
          }
          self.finished(reason: reason, outcome: outcome, done: endTask)
        }
      }
    }
  }

  private func finished(
    reason: String, outcome: ScreenCaptureWriter.Outcome, done: @escaping () -> Void
  ) {
    writer = nil
    switch outcome {
    case .failure(let message):
      stopping = false
      deliver(reason: reason, map: nil, error: message)
      done()
    case .success(let url, let durationMs, let bytes, let audio):
      saveToAlbum(url) { saved in
        if saved { try? FileManager.default.removeItem(at: url) }
        let map: [String: Any] = [
          "path": saved ? "" : url.path,
          "durationMs": durationMs,
          "bytes": bytes,
          "savedToAlbum": saved,
          "audio": audio,
        ]
        self.stopping = false
        self.deliver(reason: reason, map: map, error: nil)
        done()
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

  // MARK: - 相册

  /// 存进相册的“SimpleLive”相簿（要完整的照片权限才能找到、建相簿）；
  /// 只有“仅添加”或部分照片权限时直接存进相册；没有权限时留着文件，返回 false
  private func saveToAlbum(_ url: URL, completion: @escaping (Bool) -> Void) {
    let done: (Bool) -> Void = { saved in DispatchQueue.main.async { completion(saved) } }
    switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
    case .authorized:
      save(url, intoAlbum: true, completion: done)
    case .limited:
      save(url, intoAlbum: false, completion: done)
    case .notDetermined:
      if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized {
        save(url, intoAlbum: false, completion: done)
        return
      }
      // 在后台不弹授权框
      guard UIApplication.shared.applicationState != .background else {
        done(false)
        return
      }
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
        switch status {
        case .authorized: self.save(url, intoAlbum: true, completion: done)
        case .limited: self.save(url, intoAlbum: false, completion: done)
        default: done(false)
        }
      }
    default:
      if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized {
        save(url, intoAlbum: false, completion: done)
      } else {
        done(false)
      }
    }
  }

  private func save(_ url: URL, intoAlbum: Bool, completion: @escaping (Bool) -> Void) {
    let album = intoAlbum ? findAlbum() : nil
    PHPhotoLibrary.shared().performChanges({
      guard let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
      else { return }
      guard intoAlbum, let placeholder = request.placeholderForCreatedAsset else { return }
      if let album = album {
        PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
      } else {
        PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
          withTitle: ScreenCaptureController.albumName
        ).addAssets([placeholder] as NSArray)
      }
    }) { success, error in
      if success {
        completion(true)
        return
      }
      NSLog("SimpleLive capture: save failed %@", error?.localizedDescription ?? "")
      // 相簿不行：直接存进相册
      if intoAlbum {
        self.save(url, intoAlbum: false, completion: completion)
      } else {
        completion(false)
      }
    }
  }

  private func findAlbum() -> PHAssetCollection? {
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "title = %@", ScreenCaptureController.albumName)
    return PHAssetCollection.fetchAssetCollections(
      with: .album, subtype: .albumRegular, options: options
    ).firstObject
  }

  // MARK: - 复制截图

  private func copyImage(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let data = (args["png"] as? FlutterStandardTypedData)?.data,
      let image = UIImage(data: data)
    else {
      result(FlutterError(code: "bad_args", message: "Missing image", details: nil))
      return
    }
    UIPasteboard.general.image = image
    result(true)
  }

  /// GIF 原样放进剪贴板：只有一项、一种类型，粘贴到支持动图的 App 里会动。没有文件时返回 false，不碰剪贴板
  private func copyGif(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String, !path.isEmpty,
      let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
      !data.isEmpty
    else {
      result(false)
      return
    }
    UIPasteboard.general.setData(data, forPasteboardType: UTType.gif.identifier)
    result(true)
  }

  private static func mainWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.session.role == .windowApplication }
      .flatMap { $0.windows }
    return windows.first(where: { $0.isKeyWindow }) ?? windows.first
  }
}

private struct ScreenCaptureError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// 把 ReplayKit 的画面（裁出播放器区域）和 App 声音写进 MP4。状态只在 queue 上用
final class ScreenCaptureWriter {
  enum Outcome {
    case success(url: URL, durationMs: Int, bytes: Int, audio: Bool)
    case failure(String)
  }

  /// 画面大小或方向变了（转屏）。在 queue 上回调
  var onSourceChanged: (() -> Void)?

  private let queue = DispatchQueue(label: "simple_live.capture.writer")
  private let url: URL
  private let normalizedRect: CGRect
  private let windowIsLandscape: Bool
  private let fallbackOrientation: CGImagePropertyOrientation
  private let fps: Int
  private let wantAudio: Bool
  /// 比 1/fps 稍短一点，ReplayKit 时间戳有抖动
  private let minInterval: Double
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var orientation: CGImagePropertyOrientation = .up
  private var sourceSize: CGSize = .zero
  private var sourceAttachment: UInt32?
  private var cropRect: CGRect = .zero
  private var outputSize: CGSize = .zero
  private var firstTime = CMTime.invalid
  private var lastTime = CMTime.invalid
  private var audioWritten = false
  private var closed = false
  private var failed = false
  private var changeReported = false

  init(
    url: URL, normalizedRect: CGRect, windowIsLandscape: Bool,
    fallbackOrientation: CGImagePropertyOrientation, fps: Int, audio: Bool
  ) {
    self.url = url
    self.normalizedRect = normalizedRect
    self.windowIsLandscape = windowIsLandscape
    self.fallbackOrientation = fallbackOrientation
    self.fps = fps
    self.wantAudio = audio
    self.minInterval = 0.75 / Double(fps)
  }

  /// 缓冲区没带方向信息、又和窗口方向对不上时，按界面方向把竖着的画面转正
  static func bufferOrientation(for interface: UIInterfaceOrientation) -> CGImagePropertyOrientation {
    switch interface {
    case .landscapeRight: return .left
    case .landscapeLeft: return .right
    case .portraitUpsideDown: return .down
    default: return .up
    }
  }

  private static func size(_ size: CGSize, orientedBy orientation: CGImagePropertyOrientation)
    -> CGSize
  {
    switch orientation {
    case .left, .right, .leftMirrored, .rightMirrored:
      return CGSize(width: size.height, height: size.width)
    default:
      return size
    }
  }

  /// ReplayKit 的回调线程
  func append(_ sample: CMSampleBuffer, type: RPSampleBufferType) {
    queue.sync {
      guard !closed, !failed, CMSampleBufferDataIsReady(sample) else { return }
      switch type {
      case .video:
        appendVideo(sample)
      case .audioApp:
        appendAudio(sample)
      default:
        break
      }
    }
  }

  private func appendVideo(_ sample: CMSampleBuffer) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
    let time = CMSampleBufferGetPresentationTimeStamp(sample)
    let attached = (CMGetAttachment(
      sample, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?
      .uint32Value
    let rawSize = CGSize(
      width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    if writer == nil {
      guard setUp(rawSize: rawSize, attached: attached) else { return }
    } else if rawSize != sourceSize || attached != sourceAttachment {
      // 转屏了：裁剪位置对不上，停下
      if !changeReported {
        changeReported = true
        onSourceChanged?()
      }
      return
    }
    if lastTime.isValid && CMTimeGetSeconds(CMTimeSubtract(time, lastTime)) < minInterval { return }
    guard let adaptor = adaptor, let input = videoInput, input.isReadyForMoreMediaData,
      let pool = adaptor.pixelBufferPool
    else { return }
    var output: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
      let target = output
    else { return }
    let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
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

  /// 第一帧画面来了：定方向、裁剪区域和输出尺寸，开始写文件
  private func setUp(rawSize: CGSize, attached: UInt32?) -> Bool {
    sourceSize = rawSize
    sourceAttachment = attached
    var chosen = attached.flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
    var upright = Self.size(rawSize, orientedBy: chosen)
    if (upright.width > upright.height) != windowIsLandscape {
      chosen = fallbackOrientation
      upright = Self.size(rawSize, orientedBy: chosen)
    }
    orientation = chosen
    // 播放器区域（比例，左上角原点）换成 Core Image 坐标（像素，左下角原点）
    let width = normalizedRect.width * upright.width
    let height = normalizedRect.height * upright.height
    let rect = CGRect(
      x: normalizedRect.minX * upright.width,
      y: upright.height - normalizedRect.minY * upright.height - height,
      width: width, height: height
    ).integral.intersection(CGRect(origin: .zero, size: upright))
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
      guard writer.canAdd(video) else { throw ScreenCaptureError(message: "Cannot add video track") }
      writer.add(video)
      if wantAudio {
        let audio = AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 128_000,
          ])
        audio.expectsMediaDataInRealTime = true
        if writer.canAdd(audio) {
          writer.add(audio)
          audioInput = audio
        }
      }
      guard writer.startWriting() else {
        throw writer.error ?? ScreenCaptureError(message: "Cannot start writing")
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

  /// 写完文件。在 queue 上回调
  func finish(_ completion: @escaping (Outcome) -> Void) {
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
      let seconds = CMTimeGetSeconds(CMTimeSubtract(self.lastTime, self.firstTime)) + 1 / Double(self.fps)
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

  /// 没开始成功：丢掉
  func discard() {
    queue.async {
      self.closed = true
      self.writer?.cancelWriting()
      try? FileManager.default.removeItem(at: self.url)
    }
  }
}
