import CoreGraphics
import Foundation

#if canImport(UIKit)
  import UIKit
#endif

#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

// SimpleLive: OpenGL ES must not render while the app is inactive (iOS kills
// apps that use the GPU in the background). Closing the gate waits for an
// in-progress resize/render to finish.
final class VideoOutputRenderGate {
  private let lock = NSLock()
  private var enabled = true

  func setEnabled(_ enabled: Bool) {
    lock.lock()
    self.enabled = enabled
    lock.unlock()
  }

  @discardableResult
  func runIfEnabled(_ body: () -> Void) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard enabled else { return false }
    body()
    return true
  }
}

// This class creates and manipulates the different types of FlutterTexture,
// handles resizing, rendering calls, and notify Flutter when a new frame is
// available to render.
//
// To improve the user experience, a worker is used to execute heavy tasks on a
// dedicated thread.
public class VideoOutput: NSObject {
  // Will be called on the main thread
  public typealias TextureUpdateCallback = (Int64, CGSize) -> Void

  /// SimpleLive: software outputs keep rendering in the background only while
  /// picture in picture shows them; otherwise they stop like GPU outputs.
  static var allowsBackgroundSoftwareRendering = false

  private static let isSimulator: Bool = {
    let isSim: Bool
    #if targetEnvironment(simulator)
      isSim = true
    #else
      isSim = false
    #endif
    return isSim
  }()

  private let handle: OpaquePointer
  private let enableHardwareAcceleration: Bool
  /// Whether the GPU renderer was actually created (read on the main thread
  /// after the initialization completion).
  private(set) var usesHardwareAcceleration = false
  private let registry: FlutterTextureRegistry
  private let textureUpdateCallback: TextureUpdateCallback
  private let worker: Worker = .init()
  private var width: Int64?
  private var height: Int64?
  private var texture: ResizableTextureProtocol!
  private var textureId: Int64 = -1
  private var currentSize: CGSize = CGSize.zero
  /// Upper bound for the rendered size (aspect ratio kept); worker only.
  private var sizeLimit: CGSize?
  private var disposed: Bool = false
  private let renderGate = VideoOutputRenderGate()
  private var lifecycleObservers: [NSObjectProtocol] = []

  init(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    registry: FlutterTextureRegistry,
    textureUpdateCallback: @escaping TextureUpdateCallback,
    initializationCompletion: @escaping (Bool) -> Void = { _ in }
  ) {
    let handle = OpaquePointer(bitPattern: Int(handle))
    assert(handle != nil, "handle casting")

    self.handle = handle!
    width = configuration.width
    height = configuration.height
    enableHardwareAcceleration = configuration.enableHardwareAcceleration
    self.registry = registry
    self.textureUpdateCallback = textureUpdateCallback

    super.init()

    #if canImport(UIKit)
      renderGate.setEnabled(UIApplication.shared.applicationState == .active)
      lifecycleObservers = [
        NotificationCenter.default.addObserver(
          forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
          self?.renderGate.setEnabled(false)
        },
        NotificationCenter.default.addObserver(
          forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
          self?.renderGate.setEnabled(true)
          self?.updateCallback()
        },
      ]
    #endif

    worker.enqueue {
      self._init(completion: initializationCompletion)
    }
  }

  deinit {
    lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    worker.cancel()

    disposed = true
    disposeTextureId()
  }

  public func setSize(width: Int64?, height: Int64?) {
    worker.enqueue {
      self.width = width
      self.height = height
    }
  }

  /// Renders at most this size (picture in picture needs far fewer pixels).
  func setSizeLimit(_ limit: CGSize?) {
    worker.enqueue {
      self.sizeLimit = limit
    }
    updateCallback()
  }

  /// Frees the mpv render context on the worker (after any queued render), then
  /// unregisters the texture and calls [completion] on the main thread. Only
  /// after that may a new output be created for the same mpv core.
  public func dispose(completion: @escaping () -> Void) {
    worker.enqueue {
      self.disposed = true
      self.texture?.invalidate()
      DispatchQueue.main.async {
        self.lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        self.lifecycleObservers.removeAll()
        self.disposeTextureId()
        self.worker.cancel()
        completion()
      }
    }
  }

  private func _init(completion: @escaping (Bool) -> Void) {
    let enableHardwareAcceleration =
      VideoOutput.isSimulator ? false : enableHardwareAcceleration

    NSLog(
      "VideoOutput: enableHardwareAcceleration: \(enableHardwareAcceleration)"
    )

    if VideoOutput.isSimulator {
      NSLog(
        "VideoOutput: warning: hardware rendering is disabled in the iOS simulator, due to an incompatibility with OpenGL ES"
      )
    }

    // Use `weak self` to prevent memory leaks
    let update: () -> Void = { [weak self] in
      self?.updateCallback()
    }

    var hardwareTexture: ResizableTextureProtocol?
    if enableHardwareAcceleration {
      #if canImport(UIKit)
        // Keep the state check and GL initialization in one main-thread turn
        // so an activation change cannot slip between them.
        DispatchQueue.main.sync {
          guard UIApplication.shared.applicationState == .active else { return }
          renderGate.runIfEnabled {
            hardwareTexture = TextureHW(handle: handle, updateCallback: update)
          }
        }
      #else
        hardwareTexture = TextureHW(handle: handle, updateCallback: update)
      #endif
    }

    if let hardwareTexture = hardwareTexture {
      usesHardwareAcceleration = true
      texture = SafeResizableTexture(hardwareTexture)
    } else {
      if enableHardwareAcceleration {
        NSLog("VideoOutput: hardware rendering unavailable; using software rendering")
      }
      guard let softwareTexture = TextureSW(handle: handle, updateCallback: update) else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      texture = SafeResizableTexture(softwareTexture)
    }

    DispatchQueue.main.sync { [weak self]() in
      guard let that = self else {
        return
      }
      that.registerTextureId()
      completion(true)
    }
  }

  // Must be run on the main thread
  private func registerTextureId() {
    // Textures must be registered on the platform thread.
    textureId = registry.register(texture)
    // textureUpdateCallback must run on the main thread
    textureUpdateCallback(textureId, CGSize(width: 0, height: 0))
  }

  private func disposeTextureId() {
    let textureId_ = self.textureId
    guard textureId_ >= 0 else { return }
    let registry_ = self.registry
    textureId = -1
    if Thread.isMainThread {
      registry_.unregisterTexture(textureId_)
    } else {
      DispatchQueue.main.async {
        // Textures must be unregistered on the platform thread
        registry_.unregisterTexture(textureId_)
      }
    }
  }

  public func updateCallback() {
    worker.enqueue {
      self._updateCallback()
    }
  }

  private func _updateCallback() {
    guard !disposed, texture != nil else { return }
    let size = videoSize

    if size.width == 0 || size.height == 0 {
      return
    }

    let resized = currentSize != size
    let render = {
      if resized {
        self.currentSize = size
        self.texture.resize(size)
      }
      self.texture.render(size)
    }
    if usesHardwareAcceleration || !VideoOutput.allowsBackgroundSoftwareRendering {
      // Keep main-thread notifications and mpv property reads outside the gate.
      guard renderGate.runIfEnabled(render) else { return }
    } else {
      render()
    }

    DispatchQueue.main.sync { [weak self] in
      guard let that = self, !that.disposed, that.textureId >= 0 else { return }
      if resized {
        // textureUpdateCallback must run on the main thread
        that.textureUpdateCallback(that.textureId, size)
      }
      // Textures must be marked as available from the main thread
      that.registry.textureFrameAvailable(that.textureId)
    }
  }

  private var videoSize: CGSize {
    return limited(unlimitedVideoSize)
  }

  private func limited(_ size: CGSize) -> CGSize {
    guard let limit = sizeLimit, size.width > 0, size.height > 0,
      size.width > limit.width || size.height > limit.height
    else { return size }
    let scale = min(limit.width / size.width, limit.height / size.height)
    return CGSize(
      width: max(2, (size.width * scale / 2).rounded() * 2),
      height: max(2, (size.height * scale / 2).rounded() * 2)
    )
  }

  private var unlimitedVideoSize: CGSize {
    // fixed size
    if width != nil && height != nil {
      return CGSize(
        width: Double(width!),
        height: Double(height!)
      )
    }

    let params = MPVHelpers.getVideoOutParams(handle)
    return CGSize(
      width: Double(
        width
          ?? (params.rotate == 0 || params.rotate == 180
            ? params.dw
            : params.dh)),
      height: Double(
        height
          ?? (params.rotate == 0 || params.rotate == 180
            ? params.dh
            : params.dw))
    )
  }
}
