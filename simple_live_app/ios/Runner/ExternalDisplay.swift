// 投屏（AirPlay 屏幕镜像或有线外接显示器）：打开直播间时，电视上只显示画面和弹幕，
// 可选右侧聊天栏；手机上照常操作。没有播放页时不创建窗口，系统照常镜像手机屏幕。
import AVFoundation
import UIKit

private final class ExternalVideoView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// Info.plist 里外接显示器场景的代理
@objc(SLExternalDisplaySceneDelegate)
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    ExternalDisplayController.shared.connect(windowScene, delegate: self)
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    ExternalDisplayController.shared.disconnect(scene)
  }
}

/// 只在主线程使用
final class ExternalDisplayController {
  static let shared = ExternalDisplayController()

  var onConnectionChanged: ((Bool) -> Void)?
  private weak var scene: UIWindowScene?
  private weak var sceneDelegate: ExternalDisplaySceneDelegate?
  private var window: UIWindow?
  private var playerController: ExternalPlayerViewController?
  private var style = DanmakuStyle()
  private var textureId: Int64?
  private var playing = true

  var isConnected: Bool { scene != nil }
  var isShowing: Bool { window != nil }

  func connect(_ scene: UIWindowScene, delegate: ExternalDisplaySceneDelegate) {
    self.scene = scene
    sceneDelegate = delegate
    updateWindow()
    onConnectionChanged?(true)
  }

  func disconnect(_ scene: UIScene) {
    guard let current = self.scene, current === scene else { return }
    removeWindow()
    self.scene = nil
    sceneDelegate = nil
    onConnectionChanged?(false)
  }

  func configure(_ style: DanmakuStyle) {
    self.style = style
    playerController?.apply(style)
    updateWindow()
  }

  /// 当前播放页的画面；Dart 端每秒同步一次
  func update(textureId: Int64?, playing: Bool) {
    self.textureId = textureId
    self.playing = playing
    updateWindow()
    playerController?.setPlaying(playing)
  }

  /// 播放页关闭：恢复系统镜像
  func detach() {
    textureId = nil
    updateWindow()
  }

  func onVideoFrame(_ buffer: CVPixelBuffer, textureId: Int64) {
    guard textureId == self.textureId, let controller = playerController else { return }
    controller.sink.submit(buffer)
  }

  func add(_ messages: [DanmakuMessage]) {
    playerController?.add(messages)
  }

  func clearDanmaku() {
    playerController?.clearDanmaku()
  }

  private func updateWindow() {
    let shouldShow = scene != nil && style.externalEnabled && textureId != nil
    if shouldShow {
      guard window == nil, let scene = scene else { return }
      let controller = ExternalPlayerViewController(style: style)
      let window = UIWindow(windowScene: scene)
      window.rootViewController = controller
      // 外接屏不接收输入，不要抢手机上的键盘焦点
      window.isHidden = false
      self.window = window
      playerController = controller
      sceneDelegate?.window = window
      controller.setPlaying(playing)
    } else {
      removeWindow()
    }
  }

  private func removeWindow() {
    guard let window = window else { return }
    playerController?.stop()
    window.isHidden = true
    window.rootViewController = nil
    self.window = nil
    playerController = nil
    sceneDelegate?.window = nil
  }
}

final class ExternalPlayerViewController: UIViewController {
  let sink = SampleBufferFrameSink(
    label: "simple_live.external.frames", maxSize: CGSize(width: 1920, height: 1080),
    maxFramesPerSecond: 0, canvas: nil)
  private let videoView = ExternalVideoView()
  private let danmakuView = DanmakuLayerView(frame: .zero)
  private let sidebar = ChatSidebarView(frame: .zero)
  private var style: DanmakuStyle

  init(style: DanmakuStyle) {
    self.style = style
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    videoView.backgroundColor = .black
    videoView.displayLayer.videoGravity = .resizeAspect
    view.addSubview(videoView)
    view.addSubview(danmakuView)
    view.addSubview(sidebar)
    danmakuView.apply(style)
    sidebar.isHidden = !style.externalSidebar
    sink.attach(videoView.displayLayer)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let bounds = view.bounds
    let sidebarWidth = style.externalSidebar ? (bounds.width * 0.26).rounded() : 0
    let videoFrame = CGRect(
      x: 0, y: 0, width: bounds.width - sidebarWidth, height: bounds.height)
    videoView.frame = videoFrame
    danmakuView.frame = videoFrame
    sidebar.frame = CGRect(
      x: bounds.width - sidebarWidth, y: 0, width: sidebarWidth, height: bounds.height)
    sidebar.fontSize = max(16, (bounds.height / 40).rounded())
  }

  func apply(_ style: DanmakuStyle) {
    let sidebarChanged = style.externalSidebar != self.style.externalSidebar
    self.style = style
    guard isViewLoaded else { return }
    danmakuView.apply(style)
    sidebar.isHidden = !style.externalSidebar
    if sidebarChanged {
      view.setNeedsLayout()
    }
  }

  func add(_ messages: [DanmakuMessage]) {
    guard isViewLoaded else { return }
    for message in messages {
      danmakuView.add(message)
      sidebar.add(message)
    }
  }

  func clearDanmaku() {
    guard isViewLoaded else { return }
    danmakuView.clear()
  }

  func setPlaying(_ playing: Bool) {
    guard isViewLoaded else { return }
    danmakuView.setPlaying(playing)
  }

  func stop() {
    sink.detach()
  }
}

/// 电视右侧的聊天栏：最新的在最下面
final class ChatSidebarView: UIView {
  private var labels: [UILabel] = []
  private var messages: [DanmakuMessage] = []
  private let maxCount = 80

  var fontSize: CGFloat = 20 {
    didSet {
      guard fontSize != oldValue else { return }
      for (label, message) in zip(labels, messages) {
        label.attributedText = text(for: message)
      }
      setNeedsLayout()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = UIColor(white: 0.07, alpha: 1)
    clipsToBounds = true
    isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func add(_ message: DanmakuMessage) {
    let label = UILabel()
    label.numberOfLines = 0
    label.attributedText = text(for: message)
    addSubview(label)
    labels.append(label)
    messages.append(message)
    if labels.count > maxCount {
      labels.removeFirst().removeFromSuperview()
      messages.removeFirst()
    }
    setNeedsLayout()
  }

  private func text(for message: DanmakuMessage) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let body = UIFont.systemFont(ofSize: fontSize)
    if !message.user.isEmpty {
      result.append(
        NSAttributedString(
          string: message.user + "：",
          attributes: [.font: body, .foregroundColor: UIColor(white: 0.62, alpha: 1)]))
    }
    result.append(
      NSAttributedString(
        string: message.text, attributes: [.font: body, .foregroundColor: UIColor.white]))
    return result
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let inset = max(12, fontSize * 0.6)
    let width = bounds.width - inset * 2
    guard width > 0 else { return }
    var bottom = bounds.height - inset
    for label in labels.reversed() {
      guard bottom > 0 else {
        label.isHidden = true
        continue
      }
      let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
      label.frame = CGRect(x: inset, y: bottom - size.height, width: width, height: size.height)
      label.isHidden = false
      bottom -= size.height + fontSize * 0.45
    }
  }
}
