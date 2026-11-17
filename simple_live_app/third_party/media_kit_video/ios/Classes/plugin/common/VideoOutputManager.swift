import Foundation

#if canImport(UIKit)
  import UIKit
#endif

#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

/// Result of a native rendering-mode request. Callbacks run on the main thread.
public enum VideoOutputRenderingResult {
  /// Already in the requested mode (or GPU rendering was never enabled).
  case unchanged
  /// The output was recreated; its new texture ID has been sent to Dart.
  case changed
  /// The output is still initializing or another switch is in progress.
  case notReady
  case failed
}

public class VideoOutputManager: NSObject {
  private final class Entry {
    let configuration: VideoOutputConfiguration
    let textureUpdateCallback: VideoOutput.TextureUpdateCallback
    var width: Int64?
    var height: Int64?
    var softwareRendering: Bool
    var output: VideoOutput?
    var busy = true
    var ready = false
    var destroyed = false

    init(
      configuration: VideoOutputConfiguration,
      softwareRendering: Bool,
      textureUpdateCallback: @escaping VideoOutput.TextureUpdateCallback
    ) {
      self.configuration = configuration
      self.textureUpdateCallback = textureUpdateCallback
      width = configuration.width
      height = configuration.height
      self.softwareRendering = softwareRendering
    }

    func makeConfiguration(softwareRendering: Bool) -> VideoOutputConfiguration {
      VideoOutputConfiguration(
        width: width,
        height: height,
        enableHardwareAcceleration: configuration.enableHardwareAcceleration
          && !softwareRendering
      )
    }
  }

  private let registry: FlutterTextureRegistry
  private var videoOutputs = [Int64: Entry]()
  private var softwareRenderingForNewOutputs = false
  private var renderSizeLimit: CGSize?

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
  }

  private var canUseHardwareRendering: Bool {
    #if canImport(UIKit)
      return UIApplication.shared.applicationState == .active
    #else
      return true
    #endif
  }

  /// Applies to outputs created afterwards (e.g. a new stream while PiP is on).
  public func setSoftwareRenderingForNewOutputs(_ enabled: Bool) {
    softwareRenderingForNewOutputs = enabled
  }

  /// Caps the rendered size of every output (aspect ratio kept); nil removes it.
  public func setRenderSizeLimit(_ limit: CGSize?) {
    renderSizeLimit = limit
    for entry in videoOutputs.values where !entry.destroyed {
      entry.output?.setSizeLimit(limit)
    }
  }

  /// Lets software outputs keep rendering while the app is in the background.
  public func setBackgroundSoftwareRenderingAllowed(_ allowed: Bool) {
    VideoOutput.allowsBackgroundSoftwareRendering = allowed
  }

  /// Outputs whose original GPU preference is currently overridden.
  public var softwareRenderingHandles: [Int64] {
    return videoOutputs.compactMap { handle, entry in
      !entry.destroyed && entry.configuration.enableHardwareAcceleration
        && entry.softwareRendering ? handle : nil
    }
  }

  public func create(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    textureUpdateCallback: @escaping VideoOutput.TextureUpdateCallback
  ) {
    if let previous = videoOutputs[handle] {
      // A second render context for the same mpv core is invalid: drop the old
      // output first (matches the previous overwrite behaviour).
      previous.destroyed = true
      previous.output?.dispose {}
      previous.output = nil
    }
    let entry = Entry(
      configuration: configuration,
      softwareRendering: softwareRenderingForNewOutputs,
      textureUpdateCallback: textureUpdateCallback
    )
    videoOutputs[handle] = entry
    makeOutput(entry: entry, handle: handle, softwareRendering: entry.softwareRendering) {
      ready in
      entry.busy = false
      entry.ready = ready
      entry.softwareRendering =
        entry.configuration.enableHardwareAcceleration
        && !(entry.output?.usesHardwareAcceleration ?? false)
      if entry.destroyed {
        self.finishDestroy(handle: handle, entry: entry)
      }
    }
  }

  public func setSize(
    handle: Int64,
    width: Int64?,
    height: Int64?
  ) {
    guard let entry = videoOutputs[handle], !entry.destroyed else { return }
    entry.width = width
    entry.height = height
    entry.output?.setSize(width: width, height: height)
  }

  /// The caller must disable the player's video track (vid=no) before calling
  /// and restore it after completion, including on failure.
  public func setSoftwareRendering(
    handle: Int64,
    enabled: Bool,
    completion: @escaping (VideoOutputRenderingResult) -> Void
  ) {
    guard let entry = videoOutputs[handle], !entry.destroyed else {
      completion(.failed)
      return
    }
    guard !entry.busy else {
      completion(.notReady)
      return
    }
    guard entry.ready, let output = entry.output else {
      completion(.failed)
      return
    }
    let previous = entry.softwareRendering
    guard entry.configuration.enableHardwareAcceleration && previous != enabled else {
      entry.softwareRendering = enabled && entry.configuration.enableHardwareAcceleration
      completion(.unchanged)
      return
    }
    // GPU rendering cannot be restored in the background; retry when active.
    guard enabled || canUseHardwareRendering else {
      completion(.failed)
      return
    }
    entry.busy = true
    entry.output = nil
    output.dispose {
      guard !entry.destroyed else {
        self.finishTransition(handle: handle, entry: entry, result: .failed, completion: completion)
        return
      }
      let targetSoftware = enabled || !self.canUseHardwareRendering
      self.makeOutput(entry: entry, handle: handle, softwareRendering: targetSoftware) { ready in
        if ready && !entry.destroyed {
          entry.ready = true
          entry.softwareRendering =
            entry.configuration.enableHardwareAcceleration
            && !(entry.output?.usesHardwareAcceleration ?? false)
          self.finishTransition(
            handle: handle, entry: entry,
            result: entry.softwareRendering == enabled ? .changed : .failed,
            completion: completion)
          return
        }
        guard !entry.destroyed else {
          self.finishTransition(handle: handle, entry: entry, result: .failed, completion: completion)
          return
        }
        // Recreate the previous renderer so the player is not left without output.
        let failed = entry.output
        entry.output = nil
        let rollback = {
          let rollbackSoftware = previous || !self.canUseHardwareRendering
          self.makeOutput(entry: entry, handle: handle, softwareRendering: rollbackSoftware) {
            recovered in
            entry.ready = recovered
            entry.softwareRendering =
              entry.configuration.enableHardwareAcceleration
              && !(entry.output?.usesHardwareAcceleration ?? false)
            self.finishTransition(handle: handle, entry: entry, result: .failed, completion: completion)
          }
        }
        if let failed = failed {
          failed.dispose(completion: rollback)
        } else {
          rollback()
        }
      }
    }
  }

  private func makeOutput(
    entry: Entry, handle: Int64, softwareRendering: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    entry.output = VideoOutput(
      handle: handle,
      configuration: entry.makeConfiguration(softwareRendering: softwareRendering),
      registry: registry,
      textureUpdateCallback: { [weak entry] textureId, size in
        guard let entry = entry, !entry.destroyed else { return }
        entry.textureUpdateCallback(textureId, size)
      },
      initializationCompletion: { ready in
        // A size update may have arrived while the old output was draining.
        entry.output?.setSize(width: entry.width, height: entry.height)
        completion(ready)
      }
    )
    if let limit = renderSizeLimit {
      entry.output?.setSizeLimit(limit)
    }
  }

  private func finishTransition(
    handle: Int64, entry: Entry,
    result: VideoOutputRenderingResult,
    completion: @escaping (VideoOutputRenderingResult) -> Void
  ) {
    entry.busy = false
    if entry.destroyed {
      finishDestroy(handle: handle, entry: entry)
      completion(.failed)
    } else {
      completion(result)
    }
  }

  public func destroy(
    handle: Int64
  ) {
    guard let entry = videoOutputs[handle] else { return }
    entry.destroyed = true
    finishDestroy(handle: handle, entry: entry)
  }

  private func finishDestroy(handle: Int64, entry: Entry) {
    guard entry.destroyed && !entry.busy else { return }
    if videoOutputs[handle] === entry {
      videoOutputs.removeValue(forKey: handle)
    }
    if let output = entry.output {
      entry.output = nil
      // Free the render context promptly, before the mpv core is destroyed.
      output.dispose {}
    }
  }
}
