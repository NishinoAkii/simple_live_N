import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    NativeHttp.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
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
