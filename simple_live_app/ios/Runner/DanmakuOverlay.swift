// 画中画和投屏（外接显示器）用的原生弹幕。
// mpv 小窗只显示视频帧，弹幕要画进每一帧（DanmakuCanvas）；
// 电视上的画面和系统播放器（AVPlayer）小窗是普通视图，弹幕用 Core Animation 图层（DanmakuLayerView）。
import CoreText
import QuartzCore
import UIKit

/// 弹幕设置（来自 Dart 的 configureOverlay）
struct DanmakuStyle {
  /// 应用里的弹幕字号（逻辑像素）
  var fontSize: CGFloat = 16
  var opacity: CGFloat = 1
  /// 弹幕区域占画面高度的比例
  var area: CGFloat = 0.8
  /// 滚动弹幕穿过画面的秒数
  var duration: Double = 10
  var strokeWidth: CGFloat = 2
  /// Flutter FontWeight 下标 0~8
  var fontWeight = 4
  var pipEnabled = true
  /// 小窗（画中画）的弹幕字号（应用里的设置，按小窗高度换算）和滚动秒数
  var pipFontSize: CGFloat = 16
  var pipDuration: Double = 10
  var pipLines = 3
  var externalEnabled = true
  var externalSidebar = false

  init() {}

  init(_ args: [String: Any]) {
    func number(_ key: String) -> Double? { (args[key] as? NSNumber)?.doubleValue }
    if let value = number("fontSize") { fontSize = CGFloat(max(6, value)) }
    if let value = number("opacity") { opacity = CGFloat(min(1, max(0.05, value))) }
    if let value = number("area") { area = CGFloat(min(1, max(0.1, value))) }
    if let value = number("duration") { duration = max(2, value) }
    if let value = number("strokeWidth") { strokeWidth = CGFloat(max(0, value)) }
    if let value = number("fontWeight") { fontWeight = Int(value) }
    if let value = args["pipEnabled"] as? Bool { pipEnabled = value }
    if let value = number("pipFontSize") { pipFontSize = CGFloat(max(4, value)) }
    if let value = number("pipDuration") { pipDuration = max(2, value) }
    if let value = number("pipLines") { pipLines = min(12, max(1, Int(value))) }
    if let value = args["externalEnabled"] as? Bool { externalEnabled = value }
    if let value = args["externalSidebar"] as? Bool { externalSidebar = value }
  }

  var uiFontWeight: UIFont.Weight {
    let weights: [UIFont.Weight] = [
      .ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black,
    ]
    return weights[min(weights.count - 1, max(0, fontWeight))]
  }
}

/// 一条弹幕或聊天消息
struct DanmakuMessage {
  let text: String
  /// RGB
  let color: UInt32
  /// 0 滚动，1 顶部，2 底部
  let mode: Int
  /// 发送者（侧栏用）
  let user: String
  /// 是否显示在画面上（播放器里关了弹幕时只进侧栏）
  let onVideo: Bool

  init?(_ value: Any) {
    guard let map = value as? [String: Any], let text = map["t"] as? String, !text.isEmpty
    else { return nil }
    self.text = text
    color = UInt32(truncatingIfNeeded: (map["c"] as? NSNumber)?.int64Value ?? 0xFFFFFF) & 0xFFFFFF
    mode = (map["m"] as? NSNumber)?.intValue ?? 0
    user = map["u"] as? String ?? ""
    onVideo = map["v"] as? Bool ?? true
  }
}

enum DanmakuText {
  /// 渲染一条带描边的弹幕文字；scale 为像素/点
  static func render(
    _ text: String, color: UInt32, fontSize: CGFloat, weight: UIFont.Weight,
    strokeWidth: CGFloat, scale: CGFloat
  ) -> CGImage? {
    let font = UIFont.systemFont(ofSize: max(4, fontSize * scale), weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let stroke = max(0, strokeWidth * scale)
    let pixelWidth = Int((width + stroke * 2 + 2).rounded(.up))
    let pixelHeight = Int((ascent + descent + stroke * 2 + 2).rounded(.up))
    guard pixelWidth > 2, pixelHeight > 2, pixelWidth <= 8192, pixelHeight <= 1024,
      let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    let origin = CGPoint(x: stroke + 1, y: descent + stroke + 1)
    context.textMatrix = .identity
    if stroke > 0 {
      context.setTextDrawingMode(.stroke)
      // 描边以字形轮廓为中心，露在外面的是一半
      context.setLineWidth(stroke * 2)
      context.setLineJoin(.round)
      context.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 0.8)
      context.textPosition = origin
      CTLineDraw(line, context)
    }
    context.setTextDrawingMode(.fill)
    context.setFillColor(
      red: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255,
      blue: CGFloat(color & 0xFF) / 255, alpha: 1)
    context.textPosition = origin
    CTLineDraw(line, context)
    return context.makeImage()
  }
}

/// 分配弹幕行，避免重叠；时间单位为秒，坐标为画布单位
final class DanmakuTrackLayout {
  private struct Lane {
    var start: TimeInterval = -1_000_000
    var speed: CGFloat = 1
    var width: CGFloat = 0
  }

  private var scrollLanes: [Lane] = []
  private var topLanes: [TimeInterval] = []
  private var bottomLanes: [TimeInterval] = []

  var laneCount: Int { scrollLanes.count }

  func reset(laneCount: Int) {
    let count = max(1, laneCount)
    scrollLanes = Array(repeating: Lane(), count: count)
    topLanes = Array(repeating: -1_000_000, count: count)
    bottomLanes = Array(repeating: -1_000_000, count: count)
  }

  /// 滚动弹幕：从右边进入，duration 秒后完全离开左边
  func placeScroll(
    width: CGFloat, canvasWidth: CGFloat, duration: TimeInterval, now: TimeInterval, gap: CGFloat
  ) -> Int? {
    let speed = (canvasWidth + width) / CGFloat(duration)
    for index in scrollLanes.indices {
      let lane = scrollLanes[index]
      let moved = CGFloat(now - lane.start) * lane.speed
      // 前一条的尾部要完全进入画面并留出间距
      guard moved >= lane.width + gap else { continue }
      // 新弹幕更快时，不能在前一条离开画面之前追上它
      if speed > lane.speed {
        let previousExit = lane.start + TimeInterval((canvasWidth + lane.width) / lane.speed)
        let arrival = now + TimeInterval(canvasWidth / speed)
        guard arrival >= previousExit else { continue }
      }
      scrollLanes[index] = Lane(start: now, speed: speed, width: width)
      return index
    }
    return nil
  }

  /// 顶部/底部弹幕：居中停留 hold 秒
  func placeFixed(top: Bool, now: TimeInterval, hold: TimeInterval) -> Int? {
    let lanes = top ? topLanes : bottomLanes
    guard let index = lanes.firstIndex(where: { $0 <= now }) else { return nil }
    if top {
      topLanes[index] = now + hold
    } else {
      bottomLanes[index] = now + hold
    }
    return index
  }
}

/// 一条弹幕的位图。画进 NV12 帧时才取出像素（只在合成队列上使用）
final class DanmakuSprite {
  /// 预乘 alpha 的 BGRA（内存顺序 B、G、R、A），第 0 行在最上面
  struct Pixels {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let rowBytes: Int
  }

  let image: CGImage
  private var pixelsLoaded = false
  private var cachedPixels: Pixels?

  init(_ image: CGImage) {
    self.image = image
  }

  func pixels() -> Pixels? {
    if pixelsLoaded { return cachedPixels }
    pixelsLoaded = true
    let width = image.width
    let height = image.height
    let rowBytes = width * 4
    guard width > 0, height > 0 else { return nil }
    // 重画一遍到已知格式的位图，不依赖 CGImage 内部的存储方式
    var bytes = [UInt8](repeating: 0, count: rowBytes * height)
    let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
      guard
        let context = CGContext(
          data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    if drawn {
      cachedPixels = Pixels(bytes: bytes, width: width, height: height, rowBytes: rowBytes)
    }
    return cachedPixels
  }
}

/// 已锁定的 NV12（双平面 4:2:0）缓冲：亮度一个字节一像素，色度每 2x2 像素一对 Cb、Cr
struct NV12Planes {
  let luma: UnsafeMutablePointer<UInt8>
  let lumaRowBytes: Int
  let chroma: UnsafeMutablePointer<UInt8>
  let chromaRowBytes: Int
  let width: Int
  let height: Int
}

/// RGB 转 Y'CbCr 的定点系数（×1024），按画面的矩阵（BT.601/709）和取值范围
struct YCbCrCoefficients {
  let yr: Int
  let yg: Int
  let yb: Int
  /// (B - Y) 和 (R - Y) 换算成 Cb、Cr 的系数，已含有限范围（16–235）的缩放
  let cb: Int
  let cr: Int
  let videoRange: Bool

  static func make(bt709: Bool, videoRange: Bool) -> YCbCrCoefficients {
    if bt709 {
      return YCbCrCoefficients(
        yr: 218, yg: 732, yb: 74, cb: videoRange ? 485 : 552, cr: videoRange ? 571 : 650,
        videoRange: videoRange)
    }
    return YCbCrCoefficients(
      yr: 306, yg: 601, yb: 117, cb: videoRange ? 508 : 578, cr: videoRange ? 642 : 730,
      videoRange: videoRange)
  }
}

/// 画中画：把弹幕画进视频帧。只在合成队列上使用
final class DanmakuCanvas {
  private struct Item {
    let sprite: DanmakuSprite
    let width: CGFloat
    let height: CGFloat
    let mode: Int
    let lane: Int
    let start: TimeInterval
    let speed: CGFloat
  }

  static let fixedHold: TimeInterval = 4

  private var items: [Item] = []
  private let layout = DanmakuTrackLayout()
  private var style = DanmakuStyle()
  private var size = CGSize.zero
  private var fontSize: CGFloat = 0
  private var lineHeight: CGFloat = 0
  /// 只在播放时前进的时钟，暂停时弹幕停住
  private(set) var clock: TimeInterval = 0
  private var lastTick: TimeInterval?

  var hasItems: Bool { !items.isEmpty }
  var enabled: Bool { style.pipEnabled }

  func configure(style: DanmakuStyle) {
    self.style = style
    relayout()
  }

  func resize(_ size: CGSize) {
    guard size != self.size else { return }
    self.size = size
    items.removeAll()
    relayout()
  }

  private func relayout() {
    guard size.height > 0 else { return }
    // 小窗很小：字号按画面高度算，再乘小窗弹幕大小的比例
    fontSize = size.height / 11 * (style.pipFontSize / 16)
    lineHeight = fontSize * 1.3
    let maxLines = max(1, Int(size.height * 0.95 / max(1, lineHeight)))
    layout.reset(laneCount: min(style.pipLines, maxLines))
  }

  func clear() {
    items.removeAll()
    layout.reset(laneCount: max(1, layout.laneCount))
  }

  func add(_ message: DanmakuMessage) {
    guard style.pipEnabled, message.onVideo, size.width > 0, fontSize > 0 else { return }
    // 太多时直接丢弃，避免小窗里堆满
    guard items.count < 120 else { return }
    guard
      let image = DanmakuText.render(
        message.text, color: message.color, fontSize: fontSize, weight: style.uiFontWeight,
        strokeWidth: max(1, style.strokeWidth * fontSize / 16), scale: 1)
    else { return }
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let mode = message.mode == 1 || message.mode == 2 ? message.mode : 0
    let placedLane: Int?
    var speed: CGFloat = 0
    if mode == 0 {
      placedLane = layout.placeScroll(
        width: width, canvasWidth: size.width, duration: style.pipDuration, now: clock,
        gap: fontSize)
      speed = (size.width + width) / CGFloat(style.pipDuration)
    } else {
      placedLane = layout.placeFixed(top: mode == 1, now: clock, hold: DanmakuCanvas.fixedHold)
    }
    guard let lane = placedLane else { return }
    items.append(
      Item(
        sprite: DanmakuSprite(image), width: width, height: height, mode: mode, lane: lane,
        start: clock, speed: speed))
  }

  /// 推进时钟并移除已离开画面的弹幕
  func advance(playing: Bool, now: TimeInterval) {
    if let last = lastTick, playing {
      clock += min(0.5, max(0, now - last))
    }
    lastTick = now
    items.removeAll { item in
      let elapsed = clock - item.start
      if item.mode == 0 {
        return CGFloat(elapsed) * item.speed > size.width + item.width
      }
      return elapsed > DanmakuCanvas.fixedHold
    }
  }

  /// 弹幕左上角的位置（原点在画面左上角）
  private func position(of item: Item) -> CGPoint {
    let top = size.height * 0.02
    switch item.mode {
    case 1:
      return CGPoint(
        x: (size.width - item.width) / 2, y: top + CGFloat(item.lane) * lineHeight)
    case 2:
      return CGPoint(
        x: (size.width - item.width) / 2,
        y: size.height - top - CGFloat(item.lane + 1) * lineHeight)
    default:
      let elapsed = clock - item.start
      return CGPoint(
        x: size.width - CGFloat(elapsed) * item.speed, y: top + CGFloat(item.lane) * lineHeight)
    }
  }

  /// 画到帧上（CGContext 原点在左下角）
  func draw(in context: CGContext) {
    guard !items.isEmpty else { return }
    context.saveGState()
    context.setAlpha(style.opacity)
    context.interpolationQuality = .low
    for item in items {
      let point = position(of: item)
      // 对齐到整像素，缩小显示时不发虚
      let rect = CGRect(
        x: point.x.rounded(), y: (size.height - point.y - item.height).rounded(),
        width: item.width, height: item.height)
      context.draw(item.sprite.image, in: rect)
    }
    context.restoreGState()
  }

  /// 画进 NV12 帧（vo_simplelive 直出时）：按预乘 alpha 在 Y'CbCr 里混合，
  /// 只处理弹幕覆盖的像素，不用整帧转成 RGB。planes 是我们自己的缓冲，尺寸与画布相同
  func blend(into planes: NV12Planes, coefficients: YCbCrCoefficients) {
    guard !items.isEmpty else { return }
    // 透明度按 0–256 定点
    let opacity = Int((min(1, max(0, style.opacity)) * 256).rounded())
    for item in items {
      guard let pixels = item.sprite.pixels() else { continue }
      let point = position(of: item)
      DanmakuCanvas.blend(
        pixels, left: Int(point.x.rounded()), top: Int(point.y.rounded()), opacity: opacity,
        into: planes, coefficients: coefficients)
    }
  }

  private static func blend(
    _ sprite: DanmakuSprite.Pixels, left: Int, top: Int, opacity: Int, into planes: NV12Planes,
    coefficients k: YCbCrCoefficients
  ) {
    // 与画面相交的范围，起点对齐到 2x2 色度块
    let startX = max(0, left) & ~1
    let startY = max(0, top) & ~1
    let endX = min(planes.width, left + sprite.width)
    let endY = min(planes.height, top + sprite.height)
    guard startX < endX, startY < endY else { return }
    sprite.bytes.withUnsafeBufferPointer { source in
      for blockY in stride(from: startY, to: endY, by: 2) {
        let chromaRow = planes.chroma + (blockY / 2) * planes.chromaRowBytes
        for blockX in stride(from: startX, to: endX, by: 2) {
          var alphaSum = 0
          var cbSum = 0
          var crSum = 0
          for dy in 0..<2 {
            let y = blockY + dy
            let spriteY = y - top
            guard y < planes.height, spriteY >= 0, spriteY < sprite.height else { continue }
            let lumaRow = planes.luma + y * planes.lumaRowBytes
            for dx in 0..<2 {
              let x = blockX + dx
              let spriteX = x - left
              guard x < planes.width, spriteX >= 0, spriteX < sprite.width else { continue }
              let offset = spriteY * sprite.rowBytes + spriteX * 4
              let alpha = (Int(source[offset + 3]) * opacity) >> 8
              guard alpha > 0 else { continue }
              let red = (Int(source[offset + 2]) * opacity) >> 8
              let green = (Int(source[offset + 1]) * opacity) >> 8
              let blue = (Int(source[offset]) * opacity) >> 8
              // 预乘后的亮度；有限范围再加 16·alpha 的偏移
              let fullLuma = (k.yr * red + k.yg * green + k.yb * blue + 512) >> 10
              let luma =
                k.videoRange ? (alpha * 64 + fullLuma * 879 + 512) >> 10 : fullLuma
              let blended = DanmakuCanvas.divide255(Int(lumaRow[x]) * (255 - alpha)) + luma
              lumaRow[x] = UInt8(clamping: blended)
              alphaSum += alpha
              cbSum += (blue - fullLuma) * k.cb
              crSum += (red - fullLuma) * k.cr
            }
          }
          guard alphaSum > 0 else { continue }
          // 色度：2x2 块里按覆盖率平均（没盖到的像素 alpha 为 0）
          let alpha = (alphaSum + 2) >> 2
          let offset128 = (alpha * 514 + 512) >> 10
          let cb = offset128 + cbSum / 4096
          let cr = offset128 + crSum / 4096
          let keep = 255 - alpha
          chromaRow[blockX] = UInt8(
            clamping: DanmakuCanvas.divide255(Int(chromaRow[blockX]) * keep) + cb)
          chromaRow[blockX + 1] = UInt8(
            clamping: DanmakuCanvas.divide255(Int(chromaRow[blockX + 1]) * keep) + cr)
        }
      }
    }
  }

  /// x / 255 四舍五入（x 不超过 255·255）
  private static func divide255(_ value: Int) -> Int {
    ((value + 128) * 257) >> 16
  }
}

/// 电视画面和系统播放器小窗上的弹幕：每条一个 CALayer，由 Core Animation 负责移动。只在主线程使用
final class DanmakuLayerView: UIView {
  private struct Entry {
    let layer: CALayer
    let end: CFTimeInterval
  }

  /// 排好版的一条弹幕；小窗里没有空行时先排队
  private struct Prepared {
    let image: CGImage
    let size: CGSize
    let mode: Int
    let since: CFTimeInterval
  }

  private struct PendingSuperChat {
    let text: String
    let background: UInt32
    let since: CFTimeInterval
  }

  /// 醒目留言在小窗顶部停留的秒数
  static let superChatHold: CFTimeInterval = 10
  /// 小窗里没有空行时最多排队的条数和秒数（等有空行再显示，不直接丢掉）
  private static let waitLimit = 80
  private static let waitSeconds: CFTimeInterval = 4
  private static let superChatWaitLimit = 20
  private static let superChatWaitSeconds: CFTimeInterval = 30

  private let layout = DanmakuTrackLayout()
  private var style = DanmakuStyle()
  private var entries: [Entry] = []
  private var cleanupTimer: Timer?
  private var retryTimer: Timer?
  private var waiting: [Prepared] = []
  private var waitingSuperChats: [PendingSuperChat] = []
  private var paused = false
  private var laidOutSize = CGSize.zero

  /// 系统播放器小窗：字号按窗口高度算（和 mpv 小窗一样），行数按画中画设置，没有空行时排队
  var pipSizing = false {
    didSet {
      if pipSizing != oldValue { resetLanes() }
    }
  }

  /// 屏幕上的弹幕条数（诊断日志用）
  var visibleCount: Int { entries.count }
  /// 排队等空行的条数（诊断日志用）
  var waitingCount: Int { waiting.count + waitingSuperChats.count }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true
    backgroundColor = .clear
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    cleanupTimer?.invalidate()
    retryTimer?.invalidate()
  }

  /// 以 390pt 高的手机横屏为基准按画面高度放大
  private var ratio: CGFloat { max(1, bounds.height / 390) }

  private var fontSize: CGFloat {
    if pipSizing {
      // 小窗很小时按小窗高度缩小（一行约占高度的 1/11）；iPad 上小窗可以很大，
      // 这时不再跟着放大：小窗弹幕大小为 16 时一行最高 16 点，其它大小按比例
      return max(4, min(bounds.height / 11, 16) * (style.pipFontSize / 16))
    }
    return style.fontSize * ratio
  }

  private var lineHeight: CGFloat { fontSize * 1.3 }

  /// 滚动弹幕穿过画面的秒数：小窗用小窗的设置，电视和全屏一样
  private var scrollDuration: Double { pipSizing ? style.pipDuration : style.duration }

  private var textStrokeWidth: CGFloat {
    if pipSizing {
      return max(0.5, style.strokeWidth * fontSize / 16)
    }
    return style.strokeWidth * ratio
  }

  private var renderScale: CGFloat {
    let scale = traitCollection.displayScale
    return scale > 0 ? scale : 1
  }

  private var localTime: CFTimeInterval {
    layer.convertTime(CACurrentMediaTime(), from: nil)
  }

  func apply(_ style: DanmakuStyle) {
    self.style = style
    resetLanes()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if bounds.size != laidOutSize {
      laidOutSize = bounds.size
      clear()
    }
  }

  private func resetLanes() {
    guard bounds.height > 0 else { return }
    if pipSizing {
      let maxLines = max(1, Int(bounds.height * 0.95 / max(1, lineHeight)))
      layout.reset(laneCount: min(max(1, style.pipLines), maxLines))
    } else {
      layout.reset(laneCount: Int(bounds.height * style.area / max(1, lineHeight)))
    }
  }

  func clear() {
    entries.forEach { $0.layer.removeFromSuperlayer() }
    entries.removeAll()
    waiting.removeAll()
    waitingSuperChats.removeAll()
    stopRetry()
    resetLanes()
  }

  func add(_ message: DanmakuMessage) {
    guard message.onVideo, bounds.width > 0, bounds.height > 0, !paused else { return }
    if layout.laneCount == 0 { resetLanes() }
    if !pipSizing && entries.count >= 300 { return }
    guard let prepared = prepare(message) else { return }
    if place(prepared) { return }
    // 电视上没有空行时直接丢掉；小窗里排队等空行
    guard pipSizing else { return }
    waiting.append(prepared)
    if waiting.count > DanmakuLayerView.waitLimit {
      waiting.removeFirst(waiting.count - DanmakuLayerView.waitLimit)
    }
    startRetry()
  }

  private func prepare(_ message: DanmakuMessage) -> Prepared? {
    let scale = renderScale
    guard
      let image = DanmakuText.render(
        message.text, color: message.color, fontSize: fontSize, weight: style.uiFontWeight,
        strokeWidth: textStrokeWidth, scale: scale)
    else { return nil }
    let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    let mode = message.mode == 1 || message.mode == 2 ? message.mode : 0
    return Prepared(image: image, size: size, mode: mode, since: CACurrentMediaTime())
  }

  /// 有空行时显示出来；没有空行时返回 false
  private func place(_ prepared: Prepared) -> Bool {
    guard entries.count < 300 else { return false }
    let size = prepared.size
    let mode = prepared.mode
    let now = localTime
    let placedLane: Int?
    if mode == 0 {
      placedLane = layout.placeScroll(
        width: size.width, canvasWidth: bounds.width, duration: scrollDuration, now: now,
        gap: fontSize)
    } else {
      placedLane = layout.placeFixed(top: mode == 1, now: now, hold: DanmakuCanvas.fixedHold)
    }
    guard let lane = placedLane else { return false }

    let item = CALayer()
    item.contents = prepared.image
    item.contentsScale = renderScale
    item.opacity = Float(style.opacity)
    let top = bounds.height * 0.02
    let y: CGFloat
    switch mode {
    case 1: y = top + CGFloat(lane) * lineHeight
    case 2: y = bounds.height - top - CGFloat(lane + 1) * lineHeight
    default: y = top + CGFloat(lane) * lineHeight
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if mode == 0 {
      item.frame = CGRect(x: -size.width, y: y, width: size.width, height: size.height)
      layer.addSublayer(item)
      let animation = CABasicAnimation(keyPath: "position.x")
      animation.fromValue = bounds.width + size.width / 2
      animation.toValue = -size.width / 2
      animation.duration = scrollDuration
      animation.beginTime = item.convertTime(CACurrentMediaTime(), from: nil)
      animation.fillMode = .backwards
      item.add(animation, forKey: "move")
      entries.append(Entry(layer: item, end: now + scrollDuration))
    } else {
      item.frame = CGRect(
        x: (bounds.width - size.width) / 2, y: y, width: size.width, height: size.height)
      layer.addSublayer(item)
      entries.append(Entry(layer: item, end: now + DanmakuCanvas.fixedHold))
    }
    CATransaction.commit()
    startCleanup()
    return true
  }

  /// 醒目留言：顶部居中，按它的背景色显示 superChatHold 秒；没有空行时排队
  func addSuperChat(_ text: String, background: UInt32) {
    guard !text.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
    if layout.laneCount == 0 { resetLanes() }
    if !paused && placeSuperChat(text, background: background) { return }
    waitingSuperChats.append(
      PendingSuperChat(text: text, background: background, since: CACurrentMediaTime()))
    if waitingSuperChats.count > DanmakuLayerView.superChatWaitLimit {
      waitingSuperChats.removeFirst(
        waitingSuperChats.count - DanmakuLayerView.superChatWaitLimit)
    }
    startRetry()
  }

  /// 显示一条醒目留言；顶部没有空行时返回 false（窗口太小、排版失败时直接放弃，也返回 true）
  private func placeSuperChat(_ text: String, background: UInt32) -> Bool {
    guard entries.count < 300 else { return false }
    let scale = renderScale
    let padding = max(2, fontSize * 0.4)
    let maxTextWidth = bounds.width * 0.96 - padding * 2
    guard maxTextWidth > fontSize, let image = fittedImage(text, maxWidth: maxTextWidth, scale: scale)
    else { return true }
    let now = localTime
    guard
      let lane = layout.placeFixed(top: true, now: now, hold: DanmakuLayerView.superChatHold)
    else { return false }
    let textSize = CGSize(
      width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    let boxWidth = textSize.width + padding * 2
    let boxHeight = max(textSize.height, lineHeight - 1)
    let top = bounds.height * 0.02
    let box = CALayer()
    box.frame = CGRect(
      x: ((bounds.width - boxWidth) / 2).rounded(), y: top + CGFloat(lane) * lineHeight,
      width: boxWidth, height: boxHeight)
    box.backgroundColor =
      UIColor(
        red: CGFloat((background >> 16) & 0xFF) / 255,
        green: CGFloat((background >> 8) & 0xFF) / 255,
        blue: CGFloat(background & 0xFF) / 255, alpha: 0.9
      ).cgColor
    box.cornerRadius = min(boxHeight / 2, fontSize * 0.5)
    box.opacity = Float(max(0.6, style.opacity))
    let textLayer = CALayer()
    textLayer.contents = image
    textLayer.contentsScale = scale
    textLayer.frame = CGRect(
      x: padding, y: (boxHeight - textSize.height) / 2, width: textSize.width,
      height: textSize.height)
    box.addSublayer(textLayer)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.addSublayer(box)
    CATransaction.commit()
    entries.append(Entry(layer: box, end: now + DanmakuLayerView.superChatHold))
    startCleanup()
    return true
  }

  /// 白字；太长时截短加省略号，放得进一行
  private func fittedImage(_ text: String, maxWidth: CGFloat, scale: CGFloat) -> CGImage? {
    var visible = text.count
    var candidate = text
    for _ in 0..<4 {
      guard
        let image = DanmakuText.render(
          candidate, color: 0xFFFFFF, fontSize: fontSize, weight: style.uiFontWeight,
          strokeWidth: textStrokeWidth * 0.5, scale: scale)
      else { return nil }
      let width = CGFloat(image.width) / scale
      if width <= maxWidth || visible <= 1 { return image }
      visible = max(1, min(visible - 1, Int(CGFloat(visible) * maxWidth / width) - 1))
      candidate = String(text.prefix(visible)) + "…"
    }
    return DanmakuText.render(
      candidate, color: 0xFFFFFF, fontSize: fontSize, weight: style.uiFontWeight,
      strokeWidth: textStrokeWidth * 0.5, scale: scale)
  }

  private func startRetry() {
    guard retryTimer == nil else { return }
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.retryWaiting()
    }
    RunLoop.main.add(timer, forMode: .common)
    retryTimer = timer
  }

  private func stopRetry() {
    retryTimer?.invalidate()
    retryTimer = nil
  }

  /// 有空行了就按顺序显示排队的弹幕；排太久的不再显示
  private func retryWaiting() {
    let now = CACurrentMediaTime()
    waitingSuperChats.removeAll { now - $0.since > DanmakuLayerView.superChatWaitSeconds }
    waiting.removeAll { now - $0.since > DanmakuLayerView.waitSeconds }
    if !paused && bounds.width > 0 && bounds.height > 0 {
      while let first = waitingSuperChats.first,
        placeSuperChat(first.text, background: first.background)
      {
        waitingSuperChats.removeFirst()
      }
      // 同一种弹幕（滚动/顶部/底部）放不下一条时，后面的也不再试，保持先后顺序
      var blocked = Set<Int>()
      var remaining: [Prepared] = []
      for prepared in waiting {
        if blocked.contains(prepared.mode) || !place(prepared) {
          blocked.insert(prepared.mode)
          remaining.append(prepared)
        }
      }
      waiting = remaining
    }
    if waiting.isEmpty && waitingSuperChats.isEmpty {
      stopRetry()
    }
  }

  private func startCleanup() {
    guard cleanupTimer == nil else { return }
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.removeFinished()
    }
    RunLoop.main.add(timer, forMode: .common)
    cleanupTimer = timer
  }

  private func removeFinished() {
    let now = localTime
    entries.removeAll { entry in
      guard entry.end <= now else { return false }
      entry.layer.removeFromSuperlayer()
      return true
    }
    if entries.isEmpty {
      cleanupTimer?.invalidate()
      cleanupTimer = nil
    }
  }

  /// 暂停时弹幕停住
  func setPlaying(_ playing: Bool) {
    if !playing, !paused {
      let time = layer.convertTime(CACurrentMediaTime(), from: nil)
      layer.speed = 0
      layer.timeOffset = time
      paused = true
    } else if playing, paused {
      let pausedTime = layer.timeOffset
      layer.speed = 1
      layer.timeOffset = 0
      layer.beginTime = 0
      layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
      paused = false
    }
  }
}
