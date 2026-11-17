// 把 media_kit 的视频帧复制（必要时缩小）到独立的缓冲，再送进 AVSampleBufferDisplayLayer。
// 画中画和投屏共用；画中画会在这里把弹幕画进帧。
// 补丁版 libmpv 的 vo_simplelive 交来的 VideoToolbox 帧也送到这里：没有弹幕时原样送出（不复制），
// 有弹幕时缩小成 NV12 再画上弹幕（见 tools/libmpv/README.md）。
// 所有状态只在自己的串行队列上访问，调用方可以在任意线程调用公开方法。
import Accelerate
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import QuartzCore

final class SampleBufferFrameSink {
  struct Stats {
    var framesIn = 0
    var framesOut = 0
    var dropped = 0
    var size = CGSize.zero
  }

  /// 弹幕合成的帧率，按设置的画中画帧率（30 帧省电，60 帧顺滑）；只在 queue 上访问
  private var danmakuFramesPerSecond = 60

  /// 解码帧里画弹幕时要复制的颜色信息（缩小后的帧不能沿用原帧的裁剪等附加信息）
  private static let colorAttachmentKeys: [CFString] = [
    kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey,
    kCVImageBufferTransferFunctionKey,
  ]

  private let queue: DispatchQueue
  /// 送出帧的最大尺寸（按设置的画中画画质）；只在 queue 上访问
  private var maxSize: CGSize
  /// 两帧之间的最短间隔（按设置的画中画帧率）；只在 queue 上访问
  private var minInterval: CFTimeInterval
  private let canvas: DanmakuCanvas?
  private let colorSpace = CGColorSpaceCreateDeviceRGB()

  /// 新尺寸的第一帧送出后在主线程回调
  var onFrameDisplayed: ((CGSize) -> Void)?

  // vo_simplelive 在 VO 线程上交来的最新一帧，等队列取走（只在 pendingLock 内访问）。
  // 队列忙时只留最新的一帧，不会积压解码器的缓冲
  private let pendingLock = NSLock()
  private var pendingDecoded: CVPixelBuffer?

  // 以下只在 queue 上访问
  private var layer: AVSampleBufferDisplayLayer?
  /// 画中画用 layer 的 controlTimebase 作显示时间；没有时用主机时钟
  private var timebase: CMTimebase?
  private var active = false
  private var playing = true
  private var size = CGSize.zero
  private var announcedSize = CGSize.zero
  private var pool: CVPixelBufferPool?
  private var formatDescription: CMVideoFormatDescription?
  private var base: UnsafeMutableRawPointer?
  private var baseRowBytes = 0
  private var hasBase = false
  private var dirty = false
  private var scaleTemp: UnsafeMutableRawPointer?
  private var scaleTempSize = 0
  private var lastEmit: CFTimeInterval = 0
  /// 弹幕合成帧的显示时间：按 1/30 秒等间隔排队，避免计时器抖动造成卡顿
  private var lastPresentation = CMTime.invalid
  private var timer: DispatchSourceTimer?
  private var stats = Stats()

  // vo_simplelive 的解码帧（只在 queue 上访问）。解码器可能还在引用这个缓冲，只读不写
  private var usingDecoded = false
  private var decoded: CVPixelBuffer?
  /// decoded 还没送出过（直出或合成）
  private var decodedChanged = false
  /// NV12 底图还不是 decoded 缩小来的：直出期间底图不更新，弹幕重新出现时要先按当前帧重做
  private var decodedNeedsScale = false
  private var decodedTarget = CGSize.zero
  // 画弹幕用：解码帧缩小到小窗尺寸的 NV12 底图（自己的内存），每次合成先复制再画弹幕
  private var nv12Size = CGSize.zero
  private var nv12Format: OSType = 0
  private var nv12Pool: CVPixelBufferPool?
  private var nv12Luma: UnsafeMutableRawPointer?
  private var nv12Chroma: UnsafeMutableRawPointer?
  private var nv12HasBase = false
  private var nv12Coefficients = YCbCrCoefficients.make(bt709: true, videoRange: true)
  private var nv12Attachments: [(CFString, AnyObject)] = []

  init(label: String, maxSize: CGSize, maxFramesPerSecond: Double, canvas: DanmakuCanvas?) {
    queue = DispatchQueue(label: label, qos: .userInitiated)
    self.maxSize = maxSize
    minInterval = maxFramesPerSecond > 0 ? 0.9 / maxFramesPerSecond : 0
    danmakuFramesPerSecond = maxFramesPerSecond > 0 ? Int(maxFramesPerSecond.rounded()) : 60
    self.canvas = canvas
  }

  deinit {
    timer?.cancel()
    base?.deallocate()
    scaleTemp?.deallocate()
    nv12Luma?.deallocate()
    nv12Chroma?.deallocate()
  }

  // MARK: - 公开方法

  func attach(_ layer: AVSampleBufferDisplayLayer, timebase: CMTimebase? = nil) {
    queue.async {
      self.layer = layer
      self.timebase = timebase
      self.active = true
      self.size = .zero
      self.announcedSize = .zero
      self.hasBase = false
      self.lastEmit = 0
      self.lastPresentation = .invalid
      self.stats = Stats()
      self.canvas?.clear()
    }
  }

  /// 停止送帧并释放缓冲；完成后在主线程回调
  func detach(completion: @escaping () -> Void = {}) {
    takePendingDecoded()
    queue.async {
      self.active = false
      self.layer = nil
      self.timebase = nil
      self.timer?.cancel()
      self.timer = nil
      self.canvas?.clear()
      self.releaseBuffers()
      self.releaseDecoded()
      DispatchQueue.main.async(execute: completion)
    }
  }

  func submit(_ buffer: CVPixelBuffer) {
    queue.async { self.ingest(buffer) }
  }

  /// vo_simplelive 交来的 VideoToolbox 帧（mpv 的 VO 线程）
  func submitDecoded(_ buffer: CVPixelBuffer) {
    pendingLock.lock()
    let scheduled = pendingDecoded != nil
    pendingDecoded = buffer
    pendingLock.unlock()
    guard !scheduled else { return }
    queue.async {
      if let next = self.takePendingDecoded() {
        self.ingestDecoded(next)
      }
    }
  }

  /// vo_simplelive 拖动进度或关闭时：放掉手里的解码器缓冲
  func resetDecoded() {
    takePendingDecoded()
    queue.async {
      self.decoded = nil
      self.decodedChanged = false
      self.decodedNeedsScale = false
    }
  }

  func setPlaying(_ playing: Bool) {
    queue.async {
      self.playing = playing
      self.dirty = true
      self.lastPresentation = .invalid
    }
  }

  func configure(_ style: DanmakuStyle) {
    queue.async {
      self.canvas?.configure(style: style)
      self.dirty = true
    }
  }

  /// 画中画帧率和画质（设置里调整）：帧率同时限制直接送出的帧和弹幕合成，
  /// 尺寸限制缩小后的帧；改了帧率时按新帧率重建合成计时器
  func setOutput(maxSize: CGSize, framesPerSecond: Int) {
    queue.async {
      self.maxSize = maxSize
      self.minInterval = framesPerSecond > 0 ? 0.9 / Double(framesPerSecond) : 0
      let changed = self.danmakuFramesPerSecond != framesPerSecond
      self.danmakuFramesPerSecond = max(1, framesPerSecond)
      if changed, let timer = self.timer {
        timer.cancel()
        self.timer = nil
        self.updateTimer()
      }
      self.dirty = true
    }
  }

  func addDanmaku(_ messages: [DanmakuMessage]) {
    guard let canvas = canvas else { return }
    queue.async {
      guard self.active, self.hasBase || self.nv12HasBase || self.decoded != nil else { return }
      // 计时器停着时先把时钟对齐到现在
      canvas.advance(playing: self.playing, now: CACurrentMediaTime())
      messages.forEach(canvas.add)
      self.dirty = true
      self.updateTimer()
    }
  }

  func clearDanmaku() {
    queue.async {
      self.canvas?.clear()
      self.dirty = true
    }
  }

  func snapshot(_ completion: @escaping (Stats) -> Void) {
    queue.async {
      let stats = self.stats
      DispatchQueue.main.async { completion(stats) }
    }
  }

  // MARK: - 队列内部

  @discardableResult
  private func takePendingDecoded() -> CVPixelBuffer? {
    pendingLock.lock()
    defer { pendingLock.unlock() }
    let buffer = pendingDecoded
    pendingDecoded = nil
    return buffer
  }

  private func releaseBuffers() {
    base?.deallocate()
    base = nil
    baseRowBytes = 0
    hasBase = false
    pool = nil
    formatDescription = nil
    size = .zero
  }

  private func releaseDecoded() {
    usingDecoded = false
    decoded = nil
    decodedChanged = false
    decodedNeedsScale = false
    decodedTarget = .zero
    releaseNV12()
  }

  private func releaseNV12() {
    nv12Luma?.deallocate()
    nv12Luma = nil
    nv12Chroma?.deallocate()
    nv12Chroma = nil
    nv12Pool = nil
    nv12Size = .zero
    nv12Format = 0
    nv12HasBase = false
    nv12Attachments = []
  }

  private func fit(width: Int, height: Int) -> CGSize {
    let scale = min(1, min(maxSize.width / CGFloat(width), maxSize.height / CGFloat(height)))
    let fittedWidth = max(2, Int((CGFloat(width) * scale / 2).rounded()) * 2)
    let fittedHeight = max(2, Int((CGFloat(height) * scale / 2).rounded()) * 2)
    return CGSize(width: fittedWidth, height: fittedHeight)
  }

  private func reconfigure(_ target: CGSize) {
    releaseBuffers()
    let width = Int(target.width)
    let height = Int(target.height)
    size = target
    baseRowBytes = width * 4
    base = UnsafeMutableRawPointer.allocate(byteCount: baseRowBytes * height, alignment: 64)
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [:],
    ]
    CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    canvas?.resize(target)
    lastPresentation = .invalid
    layer?.flushAndRemoveImage()
  }

  private func ingest(_ source: CVPixelBuffer) {
    guard active, layer != nil,
      CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA
    else { return }
    let sourceWidth = CVPixelBufferGetWidth(source)
    let sourceHeight = CVPixelBufferGetHeight(source)
    guard sourceWidth > 0, sourceHeight > 0 else { return }
    stats.framesIn += 1
    let target = fit(width: sourceWidth, height: sourceHeight)
    if target != size {
      reconfigure(target)
    }
    if usingDecoded {
      // 换回了 media_kit 的输出：弹幕画布跟着软件渲染的尺寸
      usingDecoded = false
      canvas?.resize(size)
    }
    guard let base = base else { return }

    CVPixelBufferLockBaseAddress(source, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard let sourceAddress = CVPixelBufferGetBaseAddress(source) else { return }
    var src = vImage_Buffer(
      data: sourceAddress, height: vImagePixelCount(sourceHeight),
      width: vImagePixelCount(sourceWidth), rowBytes: CVPixelBufferGetBytesPerRow(source))
    var dst = vImage_Buffer(
      data: base, height: vImagePixelCount(Int(size.height)),
      width: vImagePixelCount(Int(size.width)), rowBytes: baseRowBytes)
    let error: vImage_Error
    if sourceWidth == Int(size.width) && sourceHeight == Int(size.height) {
      error = vImageCopyBuffer(&src, &dst, 4, vImage_Flags(kvImageNoFlags))
    } else {
      let temp = temporaryBuffer(
        vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageGetTempBufferSize)))
      error = vImageScale_ARGB8888(&src, &dst, temp, vImage_Flags(kvImageNoFlags))
    }
    guard error == kvImageNoError else { return }
    // mpv 的 bgr0 第四个字节不是 alpha：在底图里设为不透明（小端序 BGRA 的最高字节），
    // 之后每次合成只需复制
    let width = Int(size.width)
    for row in 0..<Int(size.height) {
      let pixels = (base + row * baseRowBytes).assumingMemoryBound(to: UInt32.self)
      for column in 0..<width {
        pixels[column] |= 0xFF00_0000
      }
    }
    hasBase = true
    dirty = true

    // 有弹幕时由计时器按固定帧率合成
    if canvas?.hasItems == true {
      updateTimer()
      return
    }
    let now = CACurrentMediaTime()
    guard now - lastEmit >= minInterval else { return }
    emit(now: now, paced: false)
  }

  /// vImage 缩放用的临时内存，按用过的最大尺寸复用；needed 是 kvImageGetTempBufferSize 的结果
  private func temporaryBuffer(_ needed: vImage_Error) -> UnsafeMutableRawPointer? {
    guard needed > 0 else { return nil }
    if needed > scaleTempSize {
      scaleTemp?.deallocate()
      scaleTemp = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 64)
      scaleTempSize = needed
    }
    return scaleTemp
  }

  private func updateTimer() {
    let needsTimer = active && canvas?.hasItems == true
    if needsTimer, timer == nil {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      // 按设置的画中画帧率：60 Hz 顺滑，30 Hz 合成的 CPU 只要一半
      let interval = 1_000_000_000 / max(1, danmakuFramesPerSecond)
      timer.schedule(
        deadline: .now(), repeating: .nanoseconds(interval), leeway: .milliseconds(2))
      timer.setEventHandler { [weak self] in
        self?.tick()
      }
      timer.resume()
      self.timer = timer
    } else if !needsTimer, let timer = timer {
      timer.cancel()
      self.timer = nil
    }
  }

  private func tick() {
    guard active else { return }
    let now = CACurrentMediaTime()
    canvas?.advance(playing: playing, now: now)
    // 暂停且没有变化时不重复送同一帧
    if playing || dirty {
      emit(now: now, paced: true)
    }
    updateTimer()
  }

  /// 能送帧时返回 layer；锁屏一段时间后需要 flush 才能继续解码，否则小窗会变黑
  private func readyLayer() -> AVSampleBufferDisplayLayer? {
    guard let layer = layer else { return nil }
    if layer.status == .failed || layer.requiresFlushToResumeDecoding {
      layer.flush()
      lastPresentation = .invalid
    }
    guard layer.isReadyForMoreMediaData else {
      stats.dropped += 1
      return nil
    }
    return layer
  }

  private func emit(now: CFTimeInterval, paced: Bool) {
    if usingDecoded {
      emitDecoded(now: now, paced: paced)
      return
    }
    guard hasBase, let base = base, let pool = pool, let layer = readyLayer() else { return }
    guard let buffer = makePooledBuffer(pool) else { return }
    let width = Int(size.width)
    let height = Int(size.height)
    CVPixelBufferLockBaseAddress(buffer, [])
    if let address = CVPixelBufferGetBaseAddress(buffer) {
      let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
      var src = vImage_Buffer(
        data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
        rowBytes: baseRowBytes)
      var dst = vImage_Buffer(
        data: address, height: vImagePixelCount(height), width: vImagePixelCount(width),
        rowBytes: rowBytes)
      vImageCopyBuffer(&src, &dst, 4, vImage_Flags(kvImageNoFlags))
      // 底图已经不透明，按预乘 alpha 叠加后仍然不透明
      if let canvas = canvas, canvas.hasItems,
        let context = CGContext(
          data: address, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: rowBytes, space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
      {
        canvas.draw(in: context)
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    enqueue(buffer, on: layer, size: size, now: now, paced: paced)
  }

  private func makePooledBuffer(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
    var output: CVPixelBuffer?
    let limits = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
    guard
      CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault, pool, limits, &output) == kCVReturnSuccess,
      let buffer = output
    else {
      stats.dropped += 1
      return nil
    }
    return buffer
  }

  private func enqueue(
    _ buffer: CVPixelBuffer, on layer: AVSampleBufferDisplayLayer, size: CGSize,
    now: CFTimeInterval, paced: Bool
  ) {
    // 直出的解码帧和合成帧尺寸、格式不同：不匹配时按这一帧重建格式描述
    if let format = formatDescription {
      let dimensions = CMVideoFormatDescriptionGetDimensions(format)
      if Int(dimensions.width) != CVPixelBufferGetWidth(buffer)
        || Int(dimensions.height) != CVPixelBufferGetHeight(buffer)
        || CMFormatDescriptionGetMediaSubType(format) != CVPixelBufferGetPixelFormatType(buffer)
      {
        formatDescription = nil
      }
    }
    if formatDescription == nil {
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer,
        formatDescriptionOut: &formatDescription)
    }
    guard formatDescription != nil else { return }
    // 计时器驱动的弹幕帧：按设置的帧率（1/60 或 1/30 秒）等间隔排好显示时间，由系统按刷新节奏显示；
    // 视频帧驱动或暂停时立即显示
    var presentation = timebase.map(CMTimebaseGetTime)
      ?? CMClockGetTime(CMClockGetHostTimeClock())
    var immediate = true
    if paced, playing, let timebase = timebase {
      let current = CMTimebaseGetTime(timebase)
      let step = CMTime(value: 1, timescale: CMTimeScale(max(1, danmakuFramesPerSecond)))
      var next = lastPresentation.isValid
        ? CMTimeAdd(lastPresentation, step) : CMTimeAdd(current, step)
      let lead = CMTimeGetSeconds(CMTimeSubtract(next, current))
      if !lead.isFinite || lead < 0 || lead > 0.1 {
        next = CMTimeAdd(current, step)
      }
      presentation = next
      lastPresentation = next
      immediate = false
    } else {
      lastPresentation = .invalid
    }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: presentation,
      decodeTimeStamp: .invalid)
    func makeSample() -> CMSampleBuffer? {
      guard let format = formatDescription else { return nil }
      var sample: CMSampleBuffer?
      guard
        CMSampleBufferCreateReadyWithImageBuffer(
          allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
          sampleTiming: &timing, sampleBufferOut: &sample) == noErr
      else { return nil }
      return sample
    }
    var sample = makeSample()
    if sample == nil {
      // 色彩等附加信息变了，格式描述不再匹配：重建一次
      formatDescription = nil
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: buffer,
        formatDescriptionOut: &formatDescription)
      sample = makeSample()
    }
    guard let sampleBuffer = sample else {
      stats.dropped += 1
      return
    }
    if immediate,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
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
    lastEmit = now
    dirty = false
    stats.framesOut += 1
    stats.size = size
    if announcedSize != size {
      announcedSize = size
      let displayed = size
      DispatchQueue.main.async { [weak self] in
        self?.onFrameDisplayed?(displayed)
      }
    }
  }

  // MARK: - vo_simplelive 的解码帧

  /// 8 位 NV12（双平面 4:2:0）才能缩小后画弹幕；其它格式（比如 10 位）只能原样送出
  private static func isBlendable(_ buffer: CVPixelBuffer) -> Bool {
    let format = CVPixelBufferGetPixelFormatType(buffer)
    return (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
      && CVPixelBufferGetPlaneCount(buffer) == 2
  }

  private func ingestDecoded(_ source: CVPixelBuffer) {
    guard active, layer != nil else { return }
    let sourceWidth = CVPixelBufferGetWidth(source)
    let sourceHeight = CVPixelBufferGetHeight(source)
    guard sourceWidth > 0, sourceHeight > 0 else { return }
    stats.framesIn += 1
    usingDecoded = true
    decoded = source
    decodedChanged = true
    decodedNeedsScale = true
    dirty = true
    // 弹幕按小窗尺寸排版（尺寸不变时什么也不做，不会清空弹幕）
    decodedTarget = fit(width: sourceWidth, height: sourceHeight)
    canvas?.resize(decodedTarget)

    // 有弹幕时由计时器按固定帧率缩小、合成
    if canvas?.hasItems == true, SampleBufferFrameSink.isBlendable(source) {
      updateTimer()
      return
    }
    let now = CACurrentMediaTime()
    guard now - lastEmit >= minInterval else { return }
    emitDecodedDirect(now: now)
  }

  /// 没有弹幕：把解码器的缓冲原样送给小窗，缩放交给系统（零拷贝）
  private func emitDecodedDirect(now: CFTimeInterval) {
    guard let source = decoded, let layer = readyLayer() else { return }
    decodedChanged = false
    let sourceSize = CGSize(
      width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
    enqueue(source, on: layer, size: sourceSize, now: now, paced: false)
  }

  private func emitDecoded(now: CFTimeInterval, paced: Bool) {
    if let source = decoded,
      canvas?.hasItems != true || !SampleBufferFrameSink.isBlendable(source)
    {
      if decodedChanged {
        emitDecodedDirect(now: now)
      }
      return
    }
    guard let layer = readyLayer() else { return }
    // 按 decodedNeedsScale 而不是 decodedChanged 判断：没有弹幕时帧已直出（decodedChanged 已清），
    // 底图还是上次有弹幕时的旧画面；暂停时也要用当前帧做底图
    if decodedNeedsScale, let source = decoded {
      guard scaleDecoded(source) else { return }
      decodedNeedsScale = false
      decodedChanged = false
    }
    // 拖动进度后还没有新帧时继续用上一张底图，弹幕照常移动
    guard nv12HasBase, let pool = nv12Pool, let lumaBase = nv12Luma,
      let chromaBase = nv12Chroma, let buffer = makePooledBuffer(pool)
    else { return }
    let width = Int(nv12Size.width)
    let height = Int(nv12Size.height)
    var composed = false
    CVPixelBufferLockBaseAddress(buffer, [])
    if CVPixelBufferGetPlaneCount(buffer) == 2,
      let outLuma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
      let outChroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
    {
      let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
      let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
      var srcLuma = vImage_Buffer(
        data: lumaBase, height: vImagePixelCount(height), width: vImagePixelCount(width),
        rowBytes: width)
      var dstLuma = vImage_Buffer(
        data: outLuma, height: vImagePixelCount(height), width: vImagePixelCount(width),
        rowBytes: lumaRowBytes)
      var srcChroma = vImage_Buffer(
        data: chromaBase, height: vImagePixelCount(height / 2),
        width: vImagePixelCount(width / 2), rowBytes: width)
      var dstChroma = vImage_Buffer(
        data: outChroma, height: vImagePixelCount(height / 2),
        width: vImagePixelCount(width / 2), rowBytes: chromaRowBytes)
      let flags = vImage_Flags(kvImageNoFlags)
      let lumaCopied = vImageCopyBuffer(&srcLuma, &dstLuma, 1, flags) == kvImageNoError
      let chromaCopied = vImageCopyBuffer(&srcChroma, &dstChroma, 2, flags) == kvImageNoError
      composed = lumaCopied && chromaCopied
      if composed, let canvas = canvas {
        canvas.blend(
          into: NV12Planes(
            luma: outLuma.assumingMemoryBound(to: UInt8.self), lumaRowBytes: lumaRowBytes,
            chroma: outChroma.assumingMemoryBound(to: UInt8.self),
            chromaRowBytes: chromaRowBytes, width: width, height: height),
          coefficients: nv12Coefficients)
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard composed else { return }
    for (key, value) in nv12Attachments {
      CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
    }
    enqueue(buffer, on: layer, size: nv12Size, now: now, paced: paced)
  }

  private func reconfigureNV12(_ target: CGSize, format: OSType) {
    releaseNV12()
    let width = Int(target.width)
    let height = Int(target.height)
    nv12Size = target
    nv12Format = format
    // 底图紧密排列：亮度每行 width 字节，色度每行 width/2 对 CbCr（也是 width 字节）
    nv12Luma = UnsafeMutableRawPointer.allocate(byteCount: width * height, alignment: 64)
    nv12Chroma = UnsafeMutableRawPointer.allocate(
      byteCount: width * (height / 2), alignment: 64)
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: format,
      kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [:],
    ]
    CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &nv12Pool)
    lastPresentation = .invalid
  }

  /// 把解码帧缩小到 NV12 底图（只读源缓冲：解码器可能还在引用它）
  private func scaleDecoded(_ source: CVPixelBuffer) -> Bool {
    let target = decodedTarget
    let width = Int(target.width)
    let height = Int(target.height)
    guard width > 0, height > 0 else { return false }
    let format = CVPixelBufferGetPixelFormatType(source)
    if nv12Size != target || nv12Format != format || nv12Pool == nil {
      reconfigureNV12(target, format: format)
    }
    guard let lumaBase = nv12Luma, let chromaBase = nv12Chroma else { return false }

    CVPixelBufferLockBaseAddress(source, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferGetPlaneCount(source) == 2,
      let sourceLuma = CVPixelBufferGetBaseAddressOfPlane(source, 0),
      let sourceChroma = CVPixelBufferGetBaseAddressOfPlane(source, 1)
    else { return false }
    var srcLuma = vImage_Buffer(
      data: sourceLuma, height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(source, 0)),
      width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(source, 0)),
      rowBytes: CVPixelBufferGetBytesPerRowOfPlane(source, 0))
    var srcChroma = vImage_Buffer(
      data: sourceChroma, height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(source, 1)),
      width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(source, 1)),
      rowBytes: CVPixelBufferGetBytesPerRowOfPlane(source, 1))
    var dstLuma = vImage_Buffer(
      data: lumaBase, height: vImagePixelCount(height), width: vImagePixelCount(width),
      rowBytes: width)
    var dstChroma = vImage_Buffer(
      data: chromaBase, height: vImagePixelCount(height / 2), width: vImagePixelCount(width / 2),
      rowBytes: width)
    let flags = vImage_Flags(kvImageNoFlags)
    let lumaError: vImage_Error
    let chromaError: vImage_Error
    if srcLuma.width == dstLuma.width && srcLuma.height == dstLuma.height
      && srcChroma.width == dstChroma.width && srcChroma.height == dstChroma.height
    {
      lumaError = vImageCopyBuffer(&srcLuma, &dstLuma, 1, flags)
      chromaError = vImageCopyBuffer(&srcChroma, &dstChroma, 2, flags)
    } else {
      let lumaTemp = temporaryBuffer(
        vImageScale_Planar8(&srcLuma, &dstLuma, nil, vImage_Flags(kvImageGetTempBufferSize)))
      lumaError = vImageScale_Planar8(&srcLuma, &dstLuma, lumaTemp, flags)
      // CbCr 交错存放，按“像素对”缩放
      let chromaTemp = temporaryBuffer(
        vImageScale_CbCr8(&srcChroma, &dstChroma, nil, vImage_Flags(kvImageGetTempBufferSize)))
      chromaError = vImageScale_CbCr8(&srcChroma, &dstChroma, chromaTemp, flags)
    }
    guard lumaError == kvImageNoError, chromaError == kvImageNoError else { return false }
    nv12HasBase = true
    nv12Attachments = colorAttachments(of: source)
    nv12Coefficients = coefficients(for: source, attachments: nv12Attachments)
    return true
  }

  private func colorAttachments(of source: CVPixelBuffer) -> [(CFString, AnyObject)] {
    guard let attachments = CVBufferCopyAttachments(source, .shouldPropagate) as? [String: Any]
    else { return [] }
    return SampleBufferFrameSink.colorAttachmentKeys.compactMap { key in
      attachments[key as String].map { (key, $0 as AnyObject) }
    }
  }

  /// 弹幕颜色按画面的 YCbCr 矩阵和取值范围换算；没有标注时高清按 BT.709、标清按 BT.601
  private func coefficients(for source: CVPixelBuffer, attachments: [(CFString, AnyObject)])
    -> YCbCrCoefficients
  {
    let videoRange =
      CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    var bt709 = CVPixelBufferGetHeight(source) >= 720
    let matrixKey = kCVImageBufferYCbCrMatrixKey as String
    if let matrix = attachments.first(where: { ($0.0 as String) == matrixKey })?.1 as? String {
      bt709 = matrix != (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
    }
    return YCbCrCoefficients.make(bt709: bt709, videoRange: videoRange)
  }
}

// MARK: - vo_simplelive 的回调（补丁版 libmpv，见 tools/libmpv/README.md）

/// mpv 的 vo_simplelive 在 VO 线程上调用这两个导出函数；这里只转交给画中画的 sink
enum PipCustomVideoOutput {
  private static let lock = NSLock()
  private static weak var target: SampleBufferFrameSink?

  /// 补丁版 libmpv 带 vo_simplelive，并且能用 dlsym 找到本程序导出的回调
  /// （archive 构建会把全局符号剥离，这时继续用原来的软件渲染）
  static let availability: (available: Bool, reason: String) = {
    let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    guard let versionSymbol = dlsym(defaultHandle, "simplelive_vo_api_version") else {
      return (false, "libmpv 不带 vo_simplelive")
    }
    typealias VersionFunction = @convention(c) () -> Int32
    let version = unsafeBitCast(versionSymbol, to: VersionFunction.self)()
    guard version == 1 else {
      return (false, "vo_simplelive 接口版本 \(version) 不匹配")
    }
    // 引用两个导出函数，链接器才不会把它们当作没用的代码去掉
    let frame: @convention(c) (UnsafeMutableRawPointer?, Double) -> Void = simpleLivePipFrame
    let reset: @convention(c) () -> Void = simpleLivePipReset
    guard let exportedFrame = dlsym(defaultHandle, "simplelive_pip_frame"),
      let exportedReset = dlsym(defaultHandle, "simplelive_pip_reset")
    else {
      return (false, "找不到导出的 simplelive_pip_frame（符号被剥离）")
    }
    let same =
      exportedFrame == unsafeBitCast(frame, to: UnsafeMutableRawPointer.self)
      && exportedReset == unsafeBitCast(reset, to: UnsafeMutableRawPointer.self)
    return (true, same ? "可用" : "可用（导出地址与引用不同）")
  }()

  static func attach(_ sink: SampleBufferFrameSink?) {
    lock.lock()
    target = sink
    lock.unlock()
  }

  fileprivate static func deliver(_ buffer: CVPixelBuffer) {
    lock.lock()
    let sink = target
    lock.unlock()
    sink?.submitDecoded(buffer)
  }

  fileprivate static func reset() {
    lock.lock()
    let sink = target
    lock.unlock()
    sink?.resetDecoded()
  }
}

/// vo_simplelive 交来一帧 VideoToolbox 解码的画面（mpv 的 VO 线程）。
/// buffer 只在调用期间有效：交给 Swift 管理就会被 retain；不能修改它（解码器可能还在引用）
@_cdecl("simplelive_pip_frame")
public func simpleLivePipFrame(_ buffer: UnsafeMutableRawPointer?, _ pts: Double) {
  guard let buffer = buffer else { return }
  let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(buffer).takeUnretainedValue()
  PipCustomVideoOutput.deliver(pixelBuffer)
}

/// vo_simplelive 拖动进度或关闭（换回别的输出）时调用
@_cdecl("simplelive_pip_reset")
public func simpleLivePipReset() {
  PipCustomVideoOutput.reset()
}
