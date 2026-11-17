#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

public protocol ResizableTextureProtocol: NSObject, FlutterTexture {
  func resize(_ size: CGSize)
  func render(_ size: CGSize)
  /// Frees the mpv render context immediately (idempotent). Afterwards render
  /// is a no-op, so a new context can be created for the same mpv core.
  func invalidate()
}
