// 包装插件注册：只给 media_kit_video 换一个纹理注册表，用来拿到每一帧画面；
// 渲染方式的切换走 media_kit_video 公开的接口（见 third_party/media_kit_video）。
// Adapted from Kazumi (GPL-3.0), Predidit/Kazumi PR #2646.
import CoreVideo
import Flutter
import UIKit
import media_kit_video

protocol PipRendering: AnyObject {
  var softwareRenderingHandles: [Int64] { get }
  func setSoftwareRenderingForNewOutputs(_ enabled: Bool)
  func setSoftwareRendering(
    handle: Int64, enabled: Bool,
    completion: @escaping (VideoOutputRenderingResult) -> Void)
  func setRenderSizeLimit(_ limit: CGSize?)
  func setBackgroundSoftwareRenderingAllowed(_ allowed: Bool)
}

extension MediaKitVideoPlugin: PipRendering {}

private final class PipTextureRegistry: NSObject, FlutterTextureRegistry {
  private let registry: FlutterTextureRegistry
  private let frameHandler: (CVPixelBuffer, Int64) -> Void
  private let onRegistered: () -> Void
  private var textures: [Int64: FlutterTexture] = [:]

  init(
    registry: FlutterTextureRegistry, frameHandler: @escaping (CVPixelBuffer, Int64) -> Void,
    onRegistered: @escaping () -> Void
  ) {
    self.registry = registry
    self.frameHandler = frameHandler
    self.onRegistered = onRegistered
    super.init()
  }

  func register(_ texture: FlutterTexture) -> Int64 {
    let textureId = registry.register(texture)
    textures[textureId] = texture
    // 插件在 register 返回后才完成初始化；之后重试之前因忙碌而推迟的恢复
    DispatchQueue.main.async(execute: onRegistered)
    return textureId
  }

  func unregisterTexture(_ textureId: Int64) {
    textures.removeValue(forKey: textureId)
    registry.unregisterTexture(textureId)
  }

  func copyPixelBuffer(forTexture textureId: Int64) -> CVPixelBuffer? {
    // FlutterTexture 返回已 retain 的缓冲，交给 ARC 管理
    textures[textureId]?.copyPixelBuffer()?.takeRetainedValue()
  }

  func textureFrameAvailable(_ textureId: Int64) {
    // media_kit 每渲染完一帧都会在主线程调用这里；后台时 Flutter 不会再取帧，
    // 所以在这里把帧交给画中画
    if let buffer = copyPixelBuffer(forTexture: textureId) {
      frameHandler(buffer, textureId)
    }
    registry.textureFrameAvailable(textureId)
  }
}

// 只有 media_kit_video 的 registrar 换成了上面的纹理注册表，其他插件不受影响
private final class PipRegistrar: NSObject, FlutterPluginRegistrar {
  private let registrar: FlutterPluginRegistrar
  let textureRegistry: PipTextureRegistry

  init(registrar: FlutterPluginRegistrar, textureRegistry: PipTextureRegistry) {
    self.registrar = registrar
    self.textureRegistry = textureRegistry
    super.init()
  }

  // Flutter 3.50 起 FlutterBaseRegistrar 多了这一项
  var engineIdentifier: Int64 { registrar.engineIdentifier }
  func messenger() -> FlutterBinaryMessenger { registrar.messenger() }
  func textures() -> FlutterTextureRegistry { textureRegistry }
  var viewController: UIViewController? { registrar.viewController }
  func publish(_ value: NSObject) { registrar.publish(value) }

  func addMethodCallDelegate(_ delegate: FlutterPlugin, channel: FlutterMethodChannel) {
    registrar.addMethodCallDelegate(delegate, channel: channel)
  }

  func addApplicationDelegate(_ delegate: FlutterPlugin) {
    registrar.addApplicationDelegate(delegate)
  }

  func addSceneDelegate(_ delegate: FlutterSceneLifeCycleDelegate) {
    registrar.addSceneDelegate(delegate)
  }

  func register(_ factory: FlutterPlatformViewFactory, withId factoryId: String) {
    registrar.register(factory, withId: factoryId)
  }

  func register(
    _ factory: FlutterPlatformViewFactory, withId factoryId: String,
    gestureRecognizersBlockingPolicy policy: FlutterPlatformViewGestureRecognizersBlockingPolicy
  ) {
    registrar.register(factory, withId: factoryId, gestureRecognizersBlockingPolicy: policy)
  }

  func lookupKey(forAsset asset: String) -> String { registrar.lookupKey(forAsset: asset) }
  func lookupKey(forAsset asset: String, fromPackage package: String) -> String {
    registrar.lookupKey(forAsset: asset, fromPackage: package)
  }

  func valuePublished(byPlugin pluginKey: String) -> NSObject? {
    registrar.valuePublished(byPlugin: pluginKey)
  }
}

final class PipPluginRegistry: NSObject, FlutterPluginRegistry {
  /// 画中画期间 mpv 软件渲染的最大尺寸，小窗用不到原画分辨率。
  /// 按设置的画中画画质（默认 540p），由 IosPictureInPictureController 更新，只在主线程访问
  static var pipRenderSizeLimit = CGSize(width: 960, height: 540)

  private let registry: FlutterPluginRegistry
  private let frameHandler: (CVPixelBuffer, Int64) -> Void
  private var videoRegistrar: PipRegistrar?
  private var recreatingHandles: Set<Int64> = []
  private var waitingForRegistration: Set<Int64> = []
  private var registrationGeneration: UInt = 0
  private var restorationCompletions: [() -> Void] = []
  private var softwareRendering = false

  var videoOutputWillChange: ((Int64, @escaping (Bool) -> Void) -> Void)?
  var videoOutputDidChange: ((Int64, Bool, @escaping (Bool) -> Void) -> Void)?

  private var renderer: PipRendering? {
    registry.valuePublished(byPlugin: "MediaKitVideoPlugin") as? MediaKitVideoPlugin
  }

  private var isForeground: Bool { UIApplication.shared.applicationState == .active }

  init(
    registry: FlutterPluginRegistry,
    frameHandler: @escaping (CVPixelBuffer, Int64) -> Void
  ) {
    self.registry = registry
    self.frameHandler = frameHandler
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(restoreIfForeground),
      name: UIApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(restoreIfForeground),
      name: UIScene.didActivateNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(protectBackgroundOutputs),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(protectBackgroundOutputs),
      name: UIScene.didEnterBackgroundNotification, object: nil)
  }

  func registrar(forPlugin pluginKey: String) -> FlutterPluginRegistrar? {
    guard let registrar = registry.registrar(forPlugin: pluginKey) else { return nil }
    guard pluginKey == "MediaKitVideoPlugin" else { return registrar }
    let textures = PipTextureRegistry(
      registry: registrar.textures(), frameHandler: frameHandler
    ) { [weak self] in
      self?.textureRegistered()
    }
    let adapter = PipRegistrar(registrar: registrar, textureRegistry: textures)
    videoRegistrar = adapter
    return adapter
  }

  func hasPlugin(_ pluginKey: String) -> Bool { registry.hasPlugin(pluginKey) }
  func valuePublished(byPlugin pluginKey: String) -> NSObject? {
    registry.valuePublished(byPlugin: pluginKey)
  }

  func copyPixelBuffer(forTexture textureId: Int64) -> CVPixelBuffer? {
    videoRegistrar?.textureRegistry.copyPixelBuffer(forTexture: textureId)
  }

  private func changeRendering(
    _ handle: Int64, software: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    guard !recreatingHandles.contains(handle), let renderer = renderer,
      let willChange = videoOutputWillChange,
      let didChange = videoOutputDidChange
    else {
      completion(false)
      return
    }
    recreatingHandles.insert(handle)
    var retryGeneration: UInt?
    let finish: (Bool) -> Void = { ready in
      self.recreatingHandles.remove(handle)
      completion(ready)
      // 关闭小窗可能和进入同时发生：轨道恢复后再处理前台恢复
      if software && !self.softwareRendering && self.isForeground {
        self.restoreIfForeground()
      } else if let generation = retryGeneration,
        generation != self.registrationGeneration
      {
        self.retryRegisteredOutputs()
      }
      self.finishRestorationIfIdle()
    }
    willChange(handle) { suspended in
      guard suspended else {
        finish(false)
        return
      }
      // 暂停视频轨道要经过 Dart，期间可能已切到后台或开始了新的画中画
      guard software || (!self.softwareRendering && self.isForeground) else {
        renderer.setSoftwareRenderingForNewOutputs(true)
        didChange(handle, false) { _ in finish(false) }
        return
      }
      renderer.setSoftwareRendering(handle: handle, enabled: software) { result in
        if !software && result == .notReady {
          self.waitingForRegistration.insert(handle)
          retryGeneration = self.registrationGeneration
        } else {
          self.waitingForRegistration.remove(handle)
        }
        // 无论成功与否都要恢复视频轨道
        didChange(handle, result == .changed) { resumed in
          finish((result == .changed || result == .unchanged) && resumed)
        }
      }
    }
  }

  func useSoftwareRendering(forHandle handle: Int64, completion: @escaping (Bool) -> Void) {
    guard let renderer = renderer else {
      completion(false)
      return
    }
    softwareRendering = true
    // 画中画期间新建的播放器输出也不能用 OpenGL
    renderer.setSoftwareRenderingForNewOutputs(true)
    // 软件渲染很耗 CPU：限制尺寸，后台只在画中画时继续渲染
    renderer.setRenderSizeLimit(PipPluginRegistry.pipRenderSizeLimit)
    renderer.setBackgroundSoftwareRenderingAllowed(true)
    changeRendering(handle, software: true, completion: completion)
  }

  /// 画中画画质改了：正在软件渲染时立即按新的尺寸限制渲染
  func applyRenderSizeLimit() {
    guard softwareRendering, let renderer = renderer else { return }
    renderer.setRenderSizeLimit(PipPluginRegistry.pipRenderSizeLimit)
  }

  func restoreRendering(completion: @escaping () -> Void) {
    softwareRendering = false
    // 小窗关了：后台不再渲染没人看的画面（回到前台后再恢复原画）
    renderer?.setBackgroundSoftwareRenderingAllowed(false)
    restorationCompletions.append(completion)
    restoreIfForeground()
    finishRestorationIfIdle()
  }

  private func finishRestorationIfIdle() {
    guard recreatingHandles.isEmpty else { return }
    let completions = restorationCompletions
    restorationCompletions.removeAll()
    completions.forEach { $0() }
  }

  @objc private func restoreIfForeground() {
    guard !softwareRendering, isForeground, let renderer = renderer else { return }
    renderer.setSoftwareRenderingForNewOutputs(false)
    renderer.setRenderSizeLimit(nil)
    for handle in renderer.softwareRenderingHandles where !recreatingHandles.contains(handle) {
      changeRendering(handle, software: false) { _ in }
    }
  }

  private func textureRegistered() {
    registrationGeneration &+= 1
    retryRegisteredOutputs()
  }

  private func retryRegisteredOutputs() {
    guard !softwareRendering, isForeground, let renderer = renderer else { return }
    let liveHandles = Set(renderer.softwareRenderingHandles)
    waitingForRegistration.formIntersection(liveHandles)
    for handle in waitingForRegistration where !recreatingHandles.contains(handle) {
      waitingForRegistration.remove(handle)
      changeRendering(handle, software: false) { _ in }
    }
  }

  @objc private func protectBackgroundOutputs() {
    guard let renderer = renderer,
      softwareRendering || !renderer.softwareRenderingHandles.isEmpty
        || !recreatingHandles.isEmpty
    else { return }
    renderer.setSoftwareRenderingForNewOutputs(true)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
