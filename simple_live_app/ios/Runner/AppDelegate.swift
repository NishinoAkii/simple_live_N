import AVKit
import UIKit
import Flutter
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pipController: NSObject?
  private var avPipController: NSObject?
  private var pipPluginRegistry: PipPluginRegistry?
  private var backgroundAudio: BackgroundAudioController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 开播提醒（flutter_local_notifications）：App 在前台时也显示通知、点通知能回到 App
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    if #available(iOS 15.0, *),
      let pipRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "SimpleLiveIosPip")
    {
      // 画中画：media_kit_video 通过包装后的注册表把每一帧交给画中画控制器
      let pip = IosPictureInPictureController(messenger: pipRegistrar.messenger())
      let registry = PipPluginRegistry(registry: engineBridge.pluginRegistry) {
        [weak pip] buffer, textureId in
        pip?.onVideoFrame(buffer, textureId: textureId)
        // 投屏：电视上的画面
        ExternalDisplayController.shared.onVideoFrame(buffer, textureId: textureId)
      }
      ExternalDisplayController.shared.onConnectionChanged = { [weak pip] connected in
        pip?.notifyExternalDisplay(connected)
      }
      pip.copyPixelBuffer = { [weak registry] textureId in
        registry?.copyPixelBuffer(forTexture: textureId)
      }
      pip.useSoftwareRendering = { [weak registry] handle, completion in
        guard let registry = registry else {
          completion(false)
          return
        }
        registry.useSoftwareRendering(forHandle: handle, completion: completion)
      }
      pip.renderSizeLimitChanged = { [weak registry] in
        registry?.applyRenderSizeLimit()
      }
      pip.restoreRendering = { [weak registry] completion in
        guard let registry = registry else {
          completion()
          return
        }
        registry.restoreRendering(completion: completion)
      }
      registry.videoOutputWillChange = { [weak pip] handle, completion in
        guard let pip = pip else {
          completion(false)
          return
        }
        pip.videoOutputWillChange(handle, completion: completion)
      }
      registry.videoOutputDidChange = { [weak pip] handle, waitForTexture, completion in
        guard let pip = pip else {
          completion(false)
          return
        }
        pip.videoOutputDidChange(handle, waitForTexture: waitForTexture, completion: completion)
      }
      pipController = pip
      // 系统播放器（AVPlayer）小窗：前台仍是 mpv，开小窗时交给系统播放器
      avPipController = AvPlayerPipController(messenger: pipRegistrar.messenger())
      pipPluginRegistry = registry
      GeneratedPluginRegistrant.register(with: registry)
    } else {
      GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NativeHttp") {
      NativeHttp.register(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BackgroundTask") {
      BackgroundTask.register(messenger: registrar.messenger())
    }
    // 听直播：锁屏卡片、音频中断和拔耳机（BackgroundAudio.swift）
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BackgroundAudio") {
      backgroundAudio = BackgroundAudioController(messenger: registrar.messenger())
    }
  }

}

/// 切到后台后向系统要一段时间，让 WebDAV 自动同步把存档传完
enum BackgroundTask {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "simple_live/background_task", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "begin":
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "webdav-sync") {
          // 时间到了还没传完：结束它，不然系统会杀掉 App。没传完的下次补上
          UIApplication.shared.endBackgroundTask(task)
          task = .invalid
        }
        result(task == .invalid ? nil : task.rawValue)
      case "end":
        if let raw = call.arguments as? Int {
          UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// 系统网络栈请求：Kick 会按 TLS 指纹拦截 Dart 自带的 HTTP 客户端
enum NativeHttp {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "simple_live/native_http", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "request",
            let args = call.arguments as? [String: Any],
            let urlString = args["url"] as? String,
            let url = URL(string: urlString) else {
        result(FlutterMethodNotImplemented)
        return
      }
      var request = URLRequest(url: url, timeoutInterval: 20)
      request.httpMethod = args["method"] as? String ?? "GET"
      (args["headers"] as? [String: String])?.forEach { key, value in
        request.setValue(value, forHTTPHeaderField: key)
      }
      if let body = args["body"] as? String {
        request.httpBody = body.data(using: .utf8)
      }
      URLSession.shared.dataTask(with: request) { data, response, error in
        DispatchQueue.main.async {
          if let error = error {
            result(FlutterError(code: "HTTP_ERROR", message: error.localizedDescription, details: nil))
            return
          }
          let status = (response as? HTTPURLResponse)?.statusCode ?? 0
          let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
          result(["status": status, "body": text])
        }
      }.resume()
    }
  }
}
